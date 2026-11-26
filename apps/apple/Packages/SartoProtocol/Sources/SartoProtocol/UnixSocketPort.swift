#if os(macOS)
import Darwin
import Foundation
import Synchronization

public enum UnixSocketError: Error, LocalizedError, Sendable, Equatable {
    case pathTooLong
    case connectFailed(Int32)
    case writeFailed(Int32)
    case closed
    case frameTooLarge
    case malformedFrame

    public var errorDescription: String? {
        switch self {
        case .pathTooLong:
            return "Unix socket path exceeds sun_path capacity"
        case .connectFailed(let code):
            return "Unix socket connect failed (errno \(code))"
        case .writeFailed(let code):
            return "Unix socket write failed (errno \(code))"
        case .closed:
            return "Unix socket closed"
        case .frameTooLarge:
            return "Unix socket frame exceeds 256 MiB limit"
        case .malformedFrame:
            return "Malformed Unix socket frame"
        }
    }
}

/// Coordinates POSIX descriptor shutdown and single-close semantics across reader, writer, and close()
/// so `Darwin.close(fd)` never races against an active `Darwin.read` or `Darwin.write` (avoiding FD reuse UB).
private final class UnixSocketDescriptorState: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    private var readerActive = true
    private var activeWriters = 0
    private var closeRequested = false

    init(fd: Int32) {
        self.fd = fd
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closeRequested || fd < 0
    }

    func currentReadFD() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard !closeRequested, fd >= 0 else { return nil }
        return fd
    }

    func beginWrite() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard !closeRequested, fd >= 0 else { return nil }
        activeWriters += 1
        return fd
    }

    func endWrite() {
        var toClose: Int32 = -1
        lock.lock()
        activeWriters -= 1
        if closeRequested && !readerActive && activeWriters == 0 && fd >= 0 {
            toClose = fd
            fd = -1
        }
        lock.unlock()
        if toClose >= 0 {
            Darwin.close(toClose)
        }
    }

    func readerDidExit() {
        var toClose: Int32 = -1
        var toShutdown: Int32 = -1
        lock.lock()
        readerActive = false
        closeRequested = true
        if activeWriters == 0 && fd >= 0 {
            toClose = fd
            fd = -1
        } else if fd >= 0 {
            toShutdown = fd
        }
        lock.unlock()
        if toShutdown >= 0 {
            Darwin.shutdown(toShutdown, SHUT_RDWR)
        }
        if toClose >= 0 {
            Darwin.close(toClose)
        }
    }

    func requestClose() {
        var toShutdown: Int32 = -1
        var toClose: Int32 = -1
        lock.lock()
        if !closeRequested {
            closeRequested = true
            if fd >= 0 {
                toShutdown = fd
            }
        }
        if !readerActive && activeWriters == 0 && fd >= 0 {
            toClose = fd
            fd = -1
        }
        lock.unlock()
        if toShutdown >= 0 {
            Darwin.shutdown(toShutdown, SHUT_RDWR)
        }
        if toClose >= 0 {
            Darwin.close(toClose)
        }
    }

    deinit {
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
    }
}

/// Native POSIX AF_UNIX stream transport implementing Sarto's 4-byte big-endian length-prefixed
/// socket-port framing (src/shared/socket-port.ts) for talking directly to local Sarto daemon
/// control.sock and agent-host sockets on macOS.
public actor UnixSocketPortTransport: SartoBinaryPortTransport {
    /// Matches MAX_MESSAGE_BYTES in src/shared/socket-port.ts:15 (256 MiB).
    public static let maxMessageBytes = 256 * 1024 * 1024
    private static let withBuffersBit: UInt32 = 0x8000_0000

    private let socketState: UnixSocketDescriptorState
    private let writeQueue = DispatchQueue(label: "dev.sarto.unix-socket.write", qos: .userInitiated)
    private var closed = false
    private let incomingStream: AsyncThrowingStream<PortInboundMessage, Error>
    private let incomingContinuation: AsyncThrowingStream<PortInboundMessage, Error>.Continuation
    private let legacyMessages = Mutex<AsyncThrowingStream<Data, Error>?>(nil)

    public init(socketPath: String) throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < maxLen else { throw UnixSocketError.pathTooLong }

        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            for (i, byte) in pathBytes.enumerated() {
                rawBuf[i] = byte
            }
            rawBuf[pathBytes.count] = 0
        }

        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw UnixSocketError.connectFailed(errno) }

        // Prevent SIGPIPE from killing the app on abrupt daemon exit.
        var noSigPipe: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(sock, sockPtr, addrLen)
            }
        }
        if rc != 0 {
            let err = errno
            Darwin.close(sock)
            throw UnixSocketError.connectFailed(err)
        }

        self.init(connectedFD: sock)
    }

    /// Initializes the transport from an already-connected POSIX AF_UNIX stream file descriptor,
    /// taking exclusive ownership of closing `connectedFD`.
    public init(connectedFD sock: Int32) {
        var noSigPipe: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let state = UnixSocketDescriptorState(fd: sock)
        self.socketState = state

        var cont: AsyncThrowingStream<PortInboundMessage, Error>.Continuation!
        self.incomingStream = AsyncThrowingStream { cont = $0 }
        self.incomingContinuation = cont

        let continuation = cont!
        DispatchQueue.global(qos: .userInitiated).async {
            Self.readLoop(state: state, continuation: continuation)
        }
    }

    deinit {
        socketState.requestClose()
    }

    public nonisolated var inboundMessages: AsyncThrowingStream<PortInboundMessage, Error> {
        incomingStream
    }

    public nonisolated var messages: AsyncThrowingStream<Data, Error> {
        legacyMessages.withLock { cached in
            if let cached { return cached }
            let stream = PortInboundSource.inlined(incomingStream)
            cached = stream
            return stream
        }
    }

    public func sendJSON(_ data: Data) async throws {
        try await sendJSON(data, buffers: [])
    }

    /// Identifies this local Unix socket port to `agent-host` (`identifyPort`) as a desktop browser
    /// client (`browser: true`, `imageRefs: true`) so MCP `browser_*` tool calls route directly here.
    /// The first frame on the daemon's hosts socket: which other host this connection speaks to
    /// (`src/remote-host/host-sockets.ts`).
    public func sendHostsConnect(hostId: String) async throws {
        let frame = try JSONEncoder().encode(["type": "hosts:connect", "hostId": hostId])
        try await sendJSON(frame)
    }

    public func sendLocalBrowserConnect(deviceId: String? = nil, name: String = "Sarto") async throws {
        let frame = try LocalBrowserPortIdentity.connectFrameData(deviceId: deviceId, name: name)
        try await sendJSON(frame)
    }

    public func sendJSON(_ data: Data, buffers: [PortBuffer]) async throws {
        guard !closed && !socketState.isClosed else { throw UnixSocketError.closed }

        let frame: Data
        if buffers.isEmpty {
            guard data.count <= Self.maxMessageBytes else { throw UnixSocketError.frameTooLarge }
            var out = Data(capacity: 4 + data.count)
            var lenBE = UInt32(data.count).bigEndian
            withUnsafeBytes(of: &lenBE) { out.append(contentsOf: $0) }
            out.append(data)
            frame = out
        } else {
            // Wire format matches src/shared/socket-port.ts encodeMessage():
            // [header (WITH_BUFFERS | bodyLen)][jsonLen][[message, paths]][bufLen + bufBytes]...
            let paths = buffers.map(\.path)
            let pathsData = try JSONEncoder().encode(paths)
            var wrappedJSON = Data(capacity: 3 + data.count + pathsData.count)
            wrappedJSON.append(0x5B) // '['
            wrappedJSON.append(data)
            wrappedJSON.append(0x2C) // ','
            wrappedJSON.append(pathsData)
            wrappedJSON.append(0x5D) // ']'

            let totalBufferBytes = buffers.reduce(0) { $0 + 4 + $1.data.count }
            let bodyLength = 4 + wrappedJSON.count + totalBufferBytes
            guard bodyLength <= Self.maxMessageBytes else { throw UnixSocketError.frameTooLarge }

            var out = Data(capacity: 4 + bodyLength)
            var headerBE = (Self.withBuffersBit | UInt32(bodyLength)).bigEndian
            withUnsafeBytes(of: &headerBE) { out.append(contentsOf: $0) }
            var jsonLenBE = UInt32(wrappedJSON.count).bigEndian
            withUnsafeBytes(of: &jsonLenBE) { out.append(contentsOf: $0) }
            out.append(wrappedJSON)
            for buf in buffers {
                var bufLenBE = UInt32(buf.data.count).bigEndian
                withUnsafeBytes(of: &bufLenBE) { out.append(contentsOf: $0) }
                out.append(buf.data)
            }
            frame = out
        }

        let state = self.socketState
        let queue = self.writeQueue
        // Offload blocking POSIX writes onto a dedicated serial DispatchQueue so large frames never
        // starve Swift's cooperative concurrency pool while preserving strict FIFO write order.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let writeFD = state.beginWrite() else {
                    continuation.resume(throwing: UnixSocketError.closed)
                    return
                }
                defer { state.endWrite() }

                do {
                    try frame.withUnsafeBytes { rawBuf in
                        guard let base = rawBuf.baseAddress else { return }
                        var totalSent = 0
                        while totalSent < frame.count {
                            if state.isClosed {
                                throw UnixSocketError.closed
                            }
                            let n = Darwin.write(writeFD, base.advanced(by: totalSent), frame.count - totalSent)
                            if n <= 0 {
                                if n < 0 && errno == EINTR { continue }
                                throw state.isClosed ? UnixSocketError.closed : UnixSocketError.writeFailed(errno)
                            }
                            totalSent += n
                        }
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        socketState.requestClose()
        incomingContinuation.finish()
    }

    private static func readLoop(
        state: UnixSocketDescriptorState,
        continuation: AsyncThrowingStream<PortInboundMessage, Error>.Continuation
    ) {
        defer { state.readerDidExit() }

        func readExact(_ count: Int) -> Data? {
            if count == 0 { return Data() }
            var buf = Data(count: count)
            var received = 0
            let ok = buf.withUnsafeMutableBytes { rawBuf -> Bool in
                guard let base = rawBuf.baseAddress else { return false }
                while received < count {
                    guard let readFD = state.currentReadFD() else { return false }
                    let n = Darwin.read(readFD, base.advanced(by: received), count - received)
                    if n == 0 { return false }
                    if n < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    received += n
                }
                return true
            }
            return ok ? buf : nil
        }

        while !state.isClosed {
            guard let header = readExact(4) else {
                continuation.finish()
                return
            }
            let rawHeader = Self.readUInt32BE(header, at: 0)
            let hasBuffers = (rawHeader & withBuffersBit) != 0
            let length = Int(rawHeader & ~withBuffersBit)
            if length > maxMessageBytes {
                state.requestClose()
                continuation.finish(throwing: UnixSocketError.frameTooLarge)
                return
            }
            guard let body = readExact(length) else {
                continuation.finish()
                return
            }
            if !hasBuffers {
                continuation.yield(PortInboundMessage(json: body))
            } else {
                guard let unwrapped = Self.decodeInbound(body) else {
                    state.requestClose()
                    continuation.finish(throwing: UnixSocketError.malformedFrame)
                    return
                }
                continuation.yield(unwrapped)
            }
        }
        continuation.finish()
    }

    /// Strictly decodes a WITH_BUFFERS frame matching decodeWithBuffers() in src/shared/socket-port.ts,
    /// keeping each buffer as `Data` beside the message's JSON.
    static func decodeInbound(_ body: Data) -> PortInboundMessage? {
        guard body.count >= 4 else { return nil }
        let jsonLenU32 = readUInt32BE(body, at: 0)
        guard jsonLenU32 <= UInt32(body.count - 4) else { return nil }
        let jsonLen = Int(jsonLenU32)

        let start = body.startIndex
        let wrapped = body[(start + 4)..<(start + 4 + jsonLen)]
        guard case .array(let arr)? = try? JSONValue(jsonData: Data(wrapped)),
              arr.count == 2,
              let paths = arr[1].arrayValue
        else { return nil }

        let message = arr[0]
        var buffers: [PortInboundBuffer] = []
        buffers.reserveCapacity(paths.count)
        var offset = 4 + jsonLen
        for pathVal in paths {
            guard let pathKeys = pathVal.arrayValue,
                  pathKeys.allSatisfy({ $0.stringValue != nil || $0.doubleValue != nil })
            else { return nil }
            guard offset + 4 <= body.count else { return nil }
            let bufLenU32 = readUInt32BE(body, at: offset)
            offset += 4
            guard bufLenU32 <= UInt32(body.count - offset) else { return nil }
            let bufLen = Int(bufLenU32)
            let bufSlice = body[(start + offset)..<(start + offset + bufLen)]
            offset += bufLen

            if pathKeys.isEmpty && message != .null {
                return nil
            }
            buffers.append(PortInboundBuffer(path: pathKeys, data: Data(bufSlice)))
        }

        guard offset == body.count, let json = try? message.jsonData() else { return nil }
        return PortInboundMessage(json: json, buffers: buffers)
    }

    /// The WITH_BUFFERS frame as `messages` delivers it: each buffer a base64 string at its path.
    static func decodeWithBuffers(_ body: Data) -> Data? {
        try? decodeInbound(body)?.inlinedJSON()
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        let b0 = UInt32(data[base]) << 24
        let b1 = UInt32(data[base + 1]) << 16
        let b2 = UInt32(data[base + 2]) << 8
        let b3 = UInt32(data[base + 3])
        return b0 | b1 | b2 | b3
    }
}

/// The Sarto daemon's data folder and control socket (src/daemon/paths.ts, src/daemon/control.ts).
public enum SartoDaemonPaths {
    public static func defaultDataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["SARTO_DAEMON_DATA"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Sarto Daemon"
    }

    public static func controlSocketPath(dataDirectory: String = defaultDataDirectory()) -> String {
        "\(dataDirectory)/control.sock"
    }
}
#endif

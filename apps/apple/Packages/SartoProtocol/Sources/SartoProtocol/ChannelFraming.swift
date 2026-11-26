import Compression
import Foundation

public enum ChannelError: Error, Sendable, Equatable {
    case messageTooLong
    case malformedFrame
    case unknownFlags
    case nonZeroPadding
    case decompressionFailed
    case invalidStreamFrame
    case invalidUTF8
}

public enum ChannelMessage: Sendable, Equatable {
    case json(Data)
    case bytes(stream: UInt32, data: Data)
}

/// Implements Sarto's padded & chunked Noise transport framing (src/shared/remote/channel.ts).
public final class SartoChannel: @unchecked Sendable {
    // Independent send and receive locks so sealing never contends with opening.
    private let sendLock = NSLock()
    private let receiveLock = NSLock()

    public static let maxMessageBytes = 32 * 1024 * 1024
    public static let minFrameBytes = 256
    public static let maxFrameBytes = NoiseConstants.maxMessage - NoiseConstants.tagLen
    public static let headerBytes = 3
    public static let maxPayloadBytes = maxFrameBytes - headerBytes
    public static let compressThreshold = 1024

    private static let kindMask: UInt8 = 0b11
    private static let jsonKind: UInt8 = 0
    private static let deflatedJSONKind: UInt8 = 1
    private static let bytesKind: UInt8 = 2
    private static let rekeyFlag: UInt8 = 0x40
    private static let moreFlag: UInt8 = 0x80
    private static let knownFlags: UInt8 = kindMask | rekeyFlag | moreFlag
    private static let maxPartialChunks = 4096

    private let ciphers: NoiseTransportCiphers
    public let handshakeHash: Data
    private let rekeyBytes: Int
    private let rekeyInterval: TimeInterval
    private var sentOnKey = 0
    private var keySince = Date()

    private var partialKind: UInt8?
    private var partialChunks: [Data] = []
    private var partialLength = 0

    public init(
        ciphers: NoiseTransportCiphers,
        handshakeHash: Data = Data(),
        rekeyBytes: Int = 1024 * 1024 * 1024,
        rekeyInterval: TimeInterval = 3600
    ) {
        self.ciphers = ciphers
        self.handshakeHash = handshakeHash
        self.rekeyBytes = rekeyBytes
        self.rekeyInterval = rekeyInterval
    }

    /// Encodes and encrypts one channel message into one or more Noise transport frames.
    public func seal(_ message: ChannelMessage) throws -> [Data] {
        var kind: UInt8
        var body: Data

        switch message {
        case .json(let data):
            guard data.count <= Self.maxMessageBytes else { throw ChannelError.messageTooLong }
            // Only emit deflated JSON when compression strictly shrinks the payload, so
            // incompressible JSON near 32 MiB never expands past maxMessageBytes.
            if data.count > Self.compressThreshold,
               let deflated = Self.deflateRaw(data),
               deflated.count < data.count {
                kind = Self.deflatedJSONKind
                body = deflated
            } else {
                kind = Self.jsonKind
                body = data
            }
        case .bytes(let stream, let data):
            guard 4 + data.count <= Self.maxMessageBytes else { throw ChannelError.messageTooLong }
            kind = Self.bytesKind
            var buf = Data(capacity: 4 + data.count)
            var beStream = stream.bigEndian
            withUnsafeBytes(of: &beStream) { buf.append(contentsOf: $0) }
            buf.append(data)
            body = buf
        }

        sendLock.lock()
        defer { sendLock.unlock() }

        let estimatedFrames = max(1, (body.count + Self.maxPayloadBytes - 1) / Self.maxPayloadBytes)
        var frames: [Data] = []
        frames.reserveCapacity(estimatedFrames)

        var offset = body.startIndex
        repeat {
            let remaining = body.distance(from: offset, to: body.endIndex)
            let chunkLen = min(remaining, Self.maxPayloadBytes)
            let nextOffset = body.index(offset, offsetBy: chunkLen)
            let payloadSlice = body[offset..<nextOffset]
            offset = nextOffset
            let hasMore = offset < body.endIndex
            let flags = kind | (hasMore ? Self.moreFlag : 0)
            frames.append(try sealFrame(flags: flags, payload: payloadSlice))
        } while offset < body.endIndex

        return frames
    }

    /// Decrypts one incoming Noise transport frame; returns a complete ChannelMessage when assembled.
    public func open(frame sealedFrame: Data) throws -> ChannelMessage? {
        receiveLock.lock()
        defer { receiveLock.unlock() }

        let plain = try ciphers.receive.decrypt(sealedFrame)
        guard plain.count >= Self.headerBytes else { throw ChannelError.malformedFrame }

        let flags = plain[plain.startIndex]
        guard (flags & ~Self.knownFlags) == 0 else { throw ChannelError.unknownFlags }

        let kind = flags & Self.kindMask
        guard kind <= Self.bytesKind else { throw ChannelError.unknownFlags }

        let length = (Int(plain[plain.startIndex + 1]) << 8) | Int(plain[plain.startIndex + 2])
        let payloadOffset = Self.headerBytes
        guard payloadOffset + length <= plain.count else { throw ChannelError.malformedFrame }

        // Verify zero padding per Sarto channel security contract without copying slices.
        let paddingOffset = payloadOffset + length
        if paddingOffset < plain.count {
            let validPadding = plain.withUnsafeBytes { rawBuf -> Bool in
                guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return true
                }
                for i in paddingOffset..<plain.count where base[i] != 0 {
                    return false
                }
                return true
            }
            guard validPadding else { throw ChannelError.nonZeroPadding }
        }

        if (flags & Self.rekeyFlag) != 0 {
            try ciphers.receive.rekey()
        }

        let payloadStart = plain.startIndex + payloadOffset
        let payloadSlice = plain[payloadStart..<(payloadStart + length)]
        let hasMore = (flags & Self.moreFlag) != 0

        if hasMore && length == 0 {
            clearPartial()
            throw ChannelError.malformedFrame
        }

        if let activeKind = partialKind {
            guard activeKind == kind else {
                clearPartial()
                throw ChannelError.malformedFrame
            }
            partialLength += length
            guard partialLength <= Self.maxMessageBytes, partialChunks.count < Self.maxPartialChunks else {
                clearPartial()
                throw ChannelError.messageTooLong
            }
            partialChunks.append(Data(payloadSlice))
            if hasMore { return nil }
            var merged = Data(capacity: partialLength)
            for chunk in partialChunks { merged.append(chunk) }
            clearPartial()
            return try decode(kind: kind, body: merged[merged.startIndex..<merged.endIndex])
        } else if hasMore {
            guard length <= Self.maxMessageBytes else { throw ChannelError.messageTooLong }
            partialKind = kind
            partialChunks = [Data(payloadSlice)]
            partialLength = length
            return nil
        } else {
            return try decode(kind: kind, body: payloadSlice)
        }
    }

    private func clearPartial() {
        partialKind = nil
        partialChunks.removeAll(keepingCapacity: false)
        partialLength = 0
    }

    private func sealFrame(flags: UInt8, payload: Data.SubSequence) throws -> Data {
        let payloadCount = payload.count
        let frameSize = Self.paddedSize(Self.headerBytes + payloadCount)
        sentOnKey += frameSize
        let shouldRekey = sentOnKey >= rekeyBytes || Date().timeIntervalSince(keySince) >= rekeyInterval

        var frame = Data(count: frameSize)
        frame[0] = flags | (shouldRekey ? Self.rekeyFlag : 0)
        frame[1] = UInt8((payloadCount >> 8) & 0xff)
        frame[2] = UInt8(payloadCount & 0xff)
        if payloadCount > 0 {
            frame.replaceSubrange(Self.headerBytes..<(Self.headerBytes + payloadCount), with: payload)
        }

        let sealed = try ciphers.send.encrypt(frame)
        if shouldRekey {
            try ciphers.send.rekey()
            sentOnKey = 0
            keySince = Date()
        }
        return sealed
    }

    private func decode(kind: UInt8, body: Data.SubSequence) throws -> ChannelMessage {
        switch kind {
        case Self.jsonKind:
            return .json(Data(body))
        case Self.deflatedJSONKind:
            guard let inflated = Self.inflateRaw(body, limit: Self.maxMessageBytes) else {
                throw ChannelError.decompressionFailed
            }
            return .json(inflated)
        case Self.bytesKind:
            guard body.count >= 4 else { throw ChannelError.invalidStreamFrame }
            let start = body.startIndex
            let b0 = UInt32(body[start]) << 24
            let b1 = UInt32(body[start + 1]) << 16
            let b2 = UInt32(body[start + 2]) << 8
            let b3 = UInt32(body[start + 3])
            let stream = b0 | b1 | b2 | b3
            return .bytes(stream: stream, data: Data(body[(start + 4)..<body.endIndex]))
        default:
            throw ChannelError.unknownFlags
        }
    }

    private static func paddedSize(_ length: Int) -> Int {
        var size = minFrameBytes
        while size < length && size < maxFrameBytes {
            size *= 2
        }
        return min(size, maxFrameBytes)
    }

    /// Raw RFC 1951 deflate via Apple Compression (COMPRESSION_ZLIB is raw deflate).
    /// Returns nil when compression does not strictly shrink `input`.
    static func deflateRaw(_ input: Data) -> Data? {
        guard !input.isEmpty else { return Data() }
        var dst = Data(count: input.count)
        let written: Int = input.withUnsafeBytes { srcPtr in
            dst.withUnsafeMutableBytes { dstPtr in
                guard let srcBase = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let dstBase = dstPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return 0 }
                return compression_encode_buffer(
                    dstBase, input.count,
                    srcBase, input.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0, written < input.count else { return nil }
        dst.count = written
        return dst
    }

    /// Raw RFC 1951 inflate with strict output size bound and forward-progress guard.
    static func inflateRaw(_ input: Data.SubSequence, limit: Int) -> Data? {
        guard !input.isEmpty else { return Data() }
        let chunkSize = 16 * 1024
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { scratch.deallocate() }

        var stream = compression_stream(
            dst_ptr: scratch,
            dst_size: 0,
            src_ptr: UnsafePointer(scratch),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        return input.withUnsafeBytes { srcBuf -> Data? in
            guard let srcBase = srcBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            stream.src_ptr = srcBase
            stream.src_size = srcBuf.count

            while true {
                let prevSrcSize = stream.src_size
                stream.dst_ptr = scratch
                stream.dst_size = chunkSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - stream.dst_size
                if produced > 0 {
                    if output.count + produced > limit { return nil }
                    output.append(scratch, count: produced)
                }
                if status == COMPRESSION_STATUS_END {
                    return output
                }
                if status == COMPRESSION_STATUS_ERROR {
                    return nil
                }
                // Truncated raw deflate streams return COMPRESSION_STATUS_OK with 0 produced
                // bytes once src_size hits 0; bail out instead of spinning forever.
                if produced == 0 && (stream.src_size == 0 || stream.src_size == prevSrcSize) {
                    return nil
                }
            }
        }
    }
}

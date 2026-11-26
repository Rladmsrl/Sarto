import CryptoKit
import Foundation
import SartoProtocol
import Observation
import PrismDesign
#if os(macOS)
import AppKit
import Darwin
#endif

public enum WorkbenchTab: String, CaseIterable, Identifiable, Sendable {
    case git
    case files
    case terminal
    case preview

    public var id: String { rawValue }

    public func localizedTitle(_ l10n: PrismL10n) -> String {
        l10n.tr("workbench.tab.\(rawValue)")
    }

    public var title: String {
        localizedTitle(PrismL10n())
    }

    public var iconName: String {
        switch self {
        case .git: return "arrow.triangle.branch"
        case .files: return "folder"
        case .terminal: return "terminal"
        case .preview: return "macwindow.on.rectangle"
        }
    }
}

public struct TerminalRenderedLine: Identifiable, Sendable, Equatable {
    public let id: Int
    public var spans: [ANSISpan]

    public init(id: Int, spans: [ANSISpan] = []) {
        self.id = id
        self.spans = spans
    }
}

public struct TerminalTabBuffer: Identifiable, Sendable {
    private static let maxRawCharacters = 120_000
    private static let trimRawCharacters = 96_000
    private static let maxRenderedLines = 2_000
    private static let trimRenderedLines = 1_600
    private static let maxPendingEscapeScalars = 512

    public let id: String
    public var info: TerminalInfo
    public var rawOutput: String
    public var isRemote: Bool
    public private(set) var renderedLines: [TerminalRenderedLine] = []
    public private(set) var outputRevision: Int = 0

    private var activeFgCode: Int? = nil
    private var activeBold: Bool = false
    private var nextLineID: Int = 1
    private var nextSpanID: Int = 1
    private var pendingEscape: String = ""
    private var pendingCarriageReturn: Bool = false

    public init(id: String, info: TerminalInfo, rawOutput: String = "", isRemote: Bool = false) {
        self.id = id
        self.info = info
        self.rawOutput = ""
        self.isRemote = isRemote
        resetOutput(with: rawOutput)
    }

    public mutating func resetOutput(with initialText: String = "") {
        rawOutput = ""
        activeFgCode = nil
        activeBold = false
        pendingEscape = ""
        pendingCarriageReturn = false
        let firstID = allocateLineID()
        renderedLines = [TerminalRenderedLine(id: firstID, spans: [])]
        if !initialText.isEmpty {
            appendChunk(initialText)
        } else {
            outputRevision &+= 1
        }
    }

    /// Incrementally parses only `chunk` onto `renderedLines`, preserving ANSI SGR state and
    /// partial escape sequences across chunks so keystrokes and stream chunks stay O(delta).
    public mutating func appendChunk(_ chunk: String) {
        guard !chunk.isEmpty else { return }

        rawOutput.append(chunk)
        if rawOutput.count > Self.maxRawCharacters {
            rawOutput = String(rawOutput.suffix(Self.trimRawCharacters))
        }

        if renderedLines.isEmpty {
            renderedLines.append(TerminalRenderedLine(id: allocateLineID(), spans: []))
        }

        let combined: String
        if pendingEscape.isEmpty {
            combined = chunk
        } else {
            combined = pendingEscape + chunk
            pendingEscape = ""
        }

        let scalars = Array(combined.unicodeScalars)
        var i = 0
        var runBuffer = ""

        func flushRun() {
            guard !runBuffer.isEmpty else { return }
            let lastIdx = renderedLines.count - 1
            if let tail = renderedLines[lastIdx].spans.last,
               tail.fgCode == activeFgCode,
               tail.isBold == activeBold {
                let merged = ANSISpan(
                    id: tail.id,
                    text: tail.text + runBuffer,
                    fgCode: tail.fgCode,
                    isBold: tail.isBold
                )
                renderedLines[lastIdx].spans[renderedLines[lastIdx].spans.count - 1] = merged
            } else {
                let spanID = nextSpanID
                nextSpanID &+= 1
                renderedLines[lastIdx].spans.append(ANSISpan(
                    id: spanID,
                    text: runBuffer,
                    fgCode: activeFgCode,
                    isBold: activeBold
                ))
            }
            // Refresh line identity when mutated so Equatable row views re-render only the active line.
            renderedLines[lastIdx] = TerminalRenderedLine(
                id: allocateLineID(),
                spans: renderedLines[lastIdx].spans
            )
            runBuffer.removeAll(keepingCapacity: true)
        }

        while i < scalars.count {
            let s = scalars[i]

            if s.value == 0x1B { // ESC
                flushRun()
                if i + 1 >= scalars.count {
                    pendingEscape = "\u{001B}"
                    break
                }
                let next = scalars[i + 1]
                if next == "[" {
                    var j = i + 2
                    var paramStr = ""
                    while j < scalars.count && !(scalars[j].value >= 0x40 && scalars[j].value <= 0x7E) {
                        paramStr.unicodeScalars.append(scalars[j])
                        j += 1
                    }
                    if j >= scalars.count {
                        if scalars.count - i <= Self.maxPendingEscapeScalars {
                            var tail = ""
                            tail.unicodeScalars.append(contentsOf: scalars[i..<scalars.count])
                            pendingEscape = tail
                        }
                        break
                    }
                    let finalByte = scalars[j]
                    if finalByte == "m" {
                        Self.applySGR(paramStr, fg: &activeFgCode, bold: &activeBold)
                    } else if finalByte == "J" && (paramStr == "2" || paramStr == "3") {
                        renderedLines = [TerminalRenderedLine(id: allocateLineID(), spans: [])]
                    } else if finalByte == "K" && (paramStr.isEmpty || paramStr == "2") {
                        let lastIdx = renderedLines.count - 1
                        renderedLines[lastIdx] = TerminalRenderedLine(id: allocateLineID(), spans: [])
                    }
                    i = j + 1
                    continue
                } else if next == "]" {
                    var j = i + 2
                    var terminated = false
                    while j < scalars.count {
                        if scalars[j].value == 0x07 {
                            j += 1
                            terminated = true
                            break
                        }
                        if scalars[j].value == 0x1B && j + 1 < scalars.count && scalars[j + 1] == "\\" {
                            j += 2
                            terminated = true
                            break
                        }
                        j += 1
                    }
                    if !terminated {
                        if scalars.count - i <= Self.maxPendingEscapeScalars {
                            var tail = ""
                            tail.unicodeScalars.append(contentsOf: scalars[i..<scalars.count])
                            pendingEscape = tail
                        }
                        break
                    }
                    i = j
                    continue
                } else {
                    i += 2
                    continue
                }
            }

            if s == "\n" {
                flushRun()
                pendingCarriageReturn = false
                renderedLines.append(TerminalRenderedLine(id: allocateLineID(), spans: []))
                i += 1
                continue
            }

            if s == "\r" {
                flushRun()
                pendingCarriageReturn = true
                i += 1
                continue
            }

            if s.value == 0x07 { // BEL
                i += 1
                continue
            }

            if s.value == 0x08 { // BS
                if !runBuffer.isEmpty {
                    runBuffer.removeLast()
                } else {
                    let lastIdx = renderedLines.count - 1
                    if var lastSpan = renderedLines[lastIdx].spans.last {
                        var updatedText = lastSpan.text
                        if !updatedText.isEmpty { updatedText.removeLast() }
                        if updatedText.isEmpty {
                            renderedLines[lastIdx].spans.removeLast()
                        } else {
                            lastSpan = ANSISpan(
                                id: lastSpan.id,
                                text: updatedText,
                                fgCode: lastSpan.fgCode,
                                isBold: lastSpan.isBold
                            )
                            renderedLines[lastIdx].spans[renderedLines[lastIdx].spans.count - 1] = lastSpan
                        }
                        renderedLines[lastIdx] = TerminalRenderedLine(
                            id: allocateLineID(),
                            spans: renderedLines[lastIdx].spans
                        )
                    }
                }
                i += 1
                continue
            }

            if pendingCarriageReturn {
                pendingCarriageReturn = false
                let lastIdx = renderedLines.count - 1
                renderedLines[lastIdx] = TerminalRenderedLine(id: allocateLineID(), spans: [])
            }

            runBuffer.unicodeScalars.append(s)
            i += 1
        }

        flushRun()

        if renderedLines.count > Self.maxRenderedLines {
            renderedLines.removeFirst(renderedLines.count - Self.trimRenderedLines)
        }
        outputRevision &+= 1
    }

    private mutating func allocateLineID() -> Int {
        defer { nextLineID &+= 1 }
        return nextLineID
    }

    private static func applySGR(_ rawParams: String, fg: inout Int?, bold: inout Bool) {
        if rawParams.isEmpty {
            fg = nil
            bold = false
            return
        }
        let normalized = rawParams.replacingOccurrences(of: ":", with: ";")
        let codes = normalized.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        if codes.isEmpty {
            fg = nil
            bold = false
            return
        }
        var idx = 0
        while idx < codes.count {
            let code = codes[idx]
            switch code {
            case 0:
                fg = nil
                bold = false
                idx += 1
            case 1:
                bold = true
                idx += 1
            case 22:
                bold = false
                idx += 1
            case 30...37, 90...97:
                fg = code
                idx += 1
            case 39:
                fg = nil
                idx += 1
            case 38, 48, 58:
                guard idx + 1 < codes.count else {
                    idx = codes.count
                    break
                }
                let mode = codes[idx + 1]
                if mode == 5 {
                    idx += min(3, codes.count - idx)
                } else if mode == 2 {
                    idx += min(5, codes.count - idx)
                } else {
                    idx += 2
                }
            default:
                idx += 1
            }
        }
    }
}

#if os(macOS)
/// Real native macOS POSIX PTY interactive shell (`/bin/zsh`) used when no external Sarto
/// `terminal-host` socket is attached yet. All PTY IO runs on a private queue with a non-blocking
/// master fd, so a large paste into a busy shell never stalls the caller.
final class LocalPTYProcess: @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    private var process: Process?
    private var channel: PTYChannel?

    init(id: String) {
        self.id = id
    }

    func start(
        cwd: String,
        cols: UInt16 = 96,
        rows: UInt16 = 26,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &ws) == 0 else {
            throw PortRPCError(code: "internal", message: "openpty failed (errno \(errno))")
        }

        // Set close-on-exec on master fd so child doesn't inherit it.
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        let flags = fcntl(master, F_GETFL)
        if flags >= 0 {
            _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
        }

        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)

        let proc = Process()
        let shellPath = FileManager.default.isExecutableFile(atPath: "/bin/zsh") ? "/bin/zsh" : "/bin/sh"
        proc.executableURL = URL(fileURLWithPath: shellPath)
        proc.arguments = ["-i"]
        if FileManager.default.fileExists(atPath: cwd) {
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["CLICOLOR"] = "1"
        env["PROMPT_EOL_MARK"] = ""
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        proc.environment = env

        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle
        proc.terminationHandler = { terminated in
            onExit(terminated.terminationStatus)
        }

        do {
            try proc.run()
        } catch {
            try? slaveHandle.close()
            _ = Darwin.close(master)
            throw error
        }

        // Close slave fd in the parent immediately so child exit delivers clean EOF on master fd.
        try? slaveHandle.close()

        let channel = PTYChannel(fd: master, label: "dev.sarto.pty.\(id)", onOutput: onOutput)
        lock.withLock {
            self.process = proc
            self.channel = channel
        }
        channel.start()
    }

    func write(_ text: String) {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return }
        lock.withLock { channel }?.write(bytes)
    }

    func resize(cols: UInt16, rows: UInt16) {
        lock.withLock { channel }?.resize(cols: cols, rows: rows)
    }

    func terminate() {
        let (proc, channel): (Process?, PTYChannel?) = lock.withLock {
            let taken = (process, self.channel)
            process = nil
            self.channel = nil
            return taken
        }
        if let proc {
            let pid = proc.processIdentifier
            if pid > 0 {
                _ = Darwin.kill(-pid, SIGHUP)
            }
            if proc.isRunning {
                proc.terminate()
            }
        }
        channel?.close()
    }

    deinit {
        terminate()
    }
}

/// Owns a PTY master fd. Every member below is touched only on `queue`.
private final class PTYChannel: @unchecked Sendable {
    private static let readChunkBytes = 65_536

    private let queue: DispatchQueue
    private let onOutput: @Sendable (String) -> Void
    private var fd: Int32
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writeSourceSuspended = false
    private var liveSources = 0
    private var outbox: [UInt8] = []
    private var outboxOffset = 0
    private var pendingUTF8Bytes = Data()
    private var readBuffer = [UInt8](repeating: 0, count: PTYChannel.readChunkBytes)
    private var closed = false

    init(fd: Int32, label: String, onOutput: @escaping @Sendable (String) -> Void) {
        self.fd = fd
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.onOutput = onOutput
    }

    func start() {
        queue.async { [self] in
            guard !closed else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in readAvailable() }
            source.setCancelHandler { [self] in sourceDidCancel() }
            readSource = source
            liveSources += 1
            source.resume()
        }
    }

    func write(_ bytes: [UInt8]) {
        queue.async { [self] in
            guard !closed else { return }
            outbox.append(contentsOf: bytes)
            flushOutbox()
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        queue.async { [self] in
            guard !closed else { return }
            var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(fd, TIOCSWINSZ, &ws)
        }
    }

    func close() {
        queue.async { [self] in shutdown() }
    }

    private func readAvailable() {
        guard !closed else { return }
        let count = readBuffer.withUnsafeMutableBytes { raw in
            Darwin.read(fd, raw.baseAddress, raw.count)
        }
        if count > 0 {
            emit(Data(readBuffer[0..<count]))
            return
        }
        if count < 0 && (errno == EAGAIN || errno == EINTR) {
            return
        }
        // 0 or EIO: the shell side of the PTY has closed.
        if !pendingUTF8Bytes.isEmpty {
            let flushed = String(decoding: pendingUTF8Bytes, as: UTF8.self)
            pendingUTF8Bytes.removeAll()
            if !flushed.isEmpty { onOutput(flushed) }
        }
        shutdown()
    }

    private func emit(_ chunk: Data) {
        var combined = chunk
        if !pendingUTF8Bytes.isEmpty {
            combined = pendingUTF8Bytes + chunk
        }
        let (complete, trailing) = Self.splitTrailingIncompleteUTF8(combined)
        pendingUTF8Bytes = trailing
        guard !complete.isEmpty else { return }
        let decoded = String(decoding: complete, as: UTF8.self)
        if !decoded.isEmpty {
            onOutput(decoded)
        }
    }

    private func flushOutbox() {
        guard !closed else { return }
        while outboxOffset < outbox.count {
            let written = outbox.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress! + outboxOffset, outbox.count - outboxOffset)
            }
            if written > 0 {
                outboxOffset += written
                continue
            }
            if written < 0 && errno == EINTR {
                continue
            }
            if written < 0 && errno == EAGAIN {
                armWriteSource()
                return
            }
            // EIO or EBADF: nothing reads the PTY any more, so the input has nowhere to go.
            outbox.removeAll()
            outboxOffset = 0
            break
        }
        outbox.removeAll(keepingCapacity: outbox.count <= 65_536)
        outboxOffset = 0
        disarmWriteSource()
    }

    private func armWriteSource() {
        if let writeSource {
            if writeSourceSuspended {
                writeSourceSuspended = false
                writeSource.resume()
            }
            return
        }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in flushOutbox() }
        source.setCancelHandler { [self] in sourceDidCancel() }
        writeSource = source
        liveSources += 1
        source.resume()
    }

    private func disarmWriteSource() {
        guard let writeSource, !writeSourceSuspended else { return }
        writeSourceSuspended = true
        writeSource.suspend()
    }

    private func shutdown() {
        guard !closed else { return }
        closed = true
        outbox.removeAll()
        outboxOffset = 0
        pendingUTF8Bytes.removeAll()
        if let writeSource {
            // A suspended source never runs its cancel handler.
            if writeSourceSuspended {
                writeSourceSuspended = false
                writeSource.resume()
            }
            writeSource.cancel()
        }
        readSource?.cancel()
        writeSource = nil
        readSource = nil
        if liveSources == 0 {
            closeDescriptor()
        }
    }

    private func sourceDidCancel() {
        liveSources -= 1
        if liveSources == 0 && closed {
            closeDescriptor()
        }
    }

    private func closeDescriptor() {
        guard fd >= 0 else { return }
        _ = Darwin.close(fd)
        fd = -1
    }

    /// Splits off `1..3` trailing incomplete UTF-8 lead/continuation bytes at a `read()` chunk boundary.
    private static func splitTrailingIncompleteUTF8(_ data: Data) -> (complete: Data, trailing: Data) {
        guard !data.isEmpty else { return (data, Data()) }
        var contCount = 0
        var cursor = data.endIndex
        while contCount < 3 && cursor > data.startIndex {
            let prev = data.index(before: cursor)
            let byte = data[prev]
            if (byte & 0xC0) == 0x80 {
                contCount += 1
                cursor = prev
            } else {
                break
            }
        }
        guard cursor > data.startIndex else {
            return (data, Data())
        }
        let leadIndex = data.index(before: cursor)
        let leadByte = data[leadIndex]
        let expectedLen: Int
        switch leadByte {
        case 0xC2...0xDF: expectedLen = 2
        case 0xE0...0xEF: expectedLen = 3
        case 0xF0...0xF4: expectedLen = 4
        default: return (data, Data())
        }
        let availableLen = 1 + contCount
        if availableLen < expectedLen {
            return (Data(data[..<leadIndex]), Data(data[leadIndex...]))
        }
        return (data, Data())
    }
}
#endif

/// M2 Unified Workspace Controller powering Git Diff, File Browser/Editor, and Embedded PTY Terminals.
/// Automatically routes through Sarto's live `agent-host` & `terminal-host` RPC ports when connected,
/// and seamlessly falls back to native macOS Git / Filesystem / POSIX PTY when running standalone.
@MainActor
@Observable
public final class WorkspaceController {
    private static let maxDiffOrFileBytes = 1_048_576

    private static var defaultProjectPath: String {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser.path
        #else
        NSHomeDirectory()
        #endif
    }

    public var activeProjectPath: String = WorkspaceController.defaultProjectPath

    // MARK: - Git Diff State
    public var gitStatus: GitStatusInfo?
    public var changedFiles: [ChangedFileInfo] = []
    public var selectedDiffPath: String?
    public var activeFileDiff: FileDiffInfo?
    public var computedDiff: ComputedDiff = ComputedDiff(hunks: [], insertions: 0, deletions: 0)
    public var selectedForCommit: Set<String> = []
    public var commitMessage: String = ""
    public var gitNotice: String?
    /// Why the last git refresh failed; nil once a refresh succeeds.
    public var gitLoadError: String?
    public var isLoadingGit: Bool = false

    // MARK: - Git Sync & Pull Request State (see WorkspaceController+GitFlow.swift)
    /// The checked-out branch's pull request, when the host's gh knows one.
    public var currentPullRequest: GitPullRequestInfo?
    public var gitTools: GitToolsInfo?
    /// The git write running now, such as a push.
    public var runningGitActivity: GitFlowActivity?
    /// Why the last sync or pull request action failed, shown with the next step.
    public var gitFlowError: String?
    /// The pull request being drafted; it outlives the sheet so a draft that lands late still shows.
    public var pullRequestForm: PullRequestDraftForm?
    public var isPullRequestDraftPresented: Bool = false
    public var pullRequestBaseChoices: [String] = []
    /// Told every status the host reports, so other views' caches of it stay current.
    @ObservationIgnored public var onGitStatusLoaded: ((GitStatusInfo) -> Void)?

    // MARK: - File Browser & Editor State
    private static let showIgnoredStorageKey = "sarto.files.showIgnored"

    public var filePaths: [String] = []
    public var folderPaths: [String] = []
    public var ignoredPaths: Set<String> = []
    public var ignoredFolders: Set<String> = []
    public var loadedIgnoredFolders: [String: ProjectFolderList] = [:]
    public var loadingIgnoredFolders: Set<String> = []
    public var showIgnoredFiles: Bool = UserDefaults.standard.object(forKey: WorkspaceController.showIgnoredStorageKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showIgnoredFiles, forKey: Self.showIgnoredStorageKey)
        }
    }
    public var isUploadingFiles: Bool = false
    public var fileFilter: String = ""
    public var selectedFilePath: String?
    public var openFileText: String = "" {
        didSet { openFileTextRevision &+= 1 }
    }
    /// Changes whenever `openFileText` does, so views can redo derived work without diffing the text.
    public private(set) var openFileTextRevision: UInt64 = 0
    public var openFileVersion: String?
    public var openFileEditable: Bool = true
    public var openFileStatusNote: String?
    /// Authenticated per-session agent folder (from `files.agentFolder`) when the open file lives there.
    public private(set) var openFileAgentFolder: String?
    /// Verified local image bytes for image files opened in the Files pane (local hosts only).
    public private(set) var openFileImageData: Data?
    /// Verified local disk URL for the currently open file (local hosts only, for Reveal in Finder).
    public private(set) var openFileLocalURL: URL?
    /// True when the selected local file lies outside both the project and the session's agent folder.
    public private(set) var openFileIsExternal: Bool = false
    /// The file changed on disk (or on the host) after it was opened, so the last save was refused.
    public private(set) var openFileHasSaveConflict: Bool = false
    public var isFileDirty: Bool = false
    public var isEditingFile: Bool = false
    public var isLoadingFiles: Bool = false
    /// Unsaved edits of files that are not open, keyed by absolute path, so switching never loses them.
    private var fileDrafts: [String: FileDraft] = [:]
    /// Cached `files.agentFolder` responses keyed by session ID.
    private var agentFolderBySessionID: [String: String] = [:]

    /// True when the currently selected file was read from the active session's agent-owned folder.
    public var isOpenFileFromAgentFolder: Bool {
        openFileAgentFolder != nil
    }

    /// Clean label for the open file header: relative to the agent folder when applicable.
    public var openFileDisplayName: String? {
        guard let selected = selectedFilePath else { return nil }
        if let folder = openFileAgentFolder, !folder.isEmpty {
            let prefix = folder.hasSuffix("/") ? folder : (folder + "/")
            if selected.hasPrefix(prefix) {
                return String(selected.dropFirst(prefix.count))
            }
            return (selected as NSString).lastPathComponent
        }
        if openFileIsExternal || selected.hasPrefix("/") {
            return (selected as NSString).lastPathComponent
        }
        return selected
    }

    // MARK: - Embedded Terminal State
    public var terminals: [TerminalTabBuffer] = []
    public var activeTerminalID: String?
    public var activeSessionID: String?
    public var isGeneratingCommitMessage: Bool = false

    private(set) var projectGeneration: UInt64 = 0
    /// True while the workspace belongs to a remote host: its paths name that host's disk, never this one.
    public private(set) var isRemoteWorkspace: Bool = false
    private(set) weak var hostSession: SartoHostSession?
    private var terminalSession: SartoTerminalSession?
    private var terminalEventTask: Task<Void, Never>?
    @ObservationIgnored private var watchedFilesProjectPath: String?
    @ObservationIgnored private weak var watchedFilesHostSession: SartoHostSession?
    @ObservationIgnored private var filesChangedDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var pendingTerminalAcks: [String: Int] = [:]
    @ObservationIgnored private var terminalAckTask: Task<Void, Never>?
    @ObservationIgnored private var terminalGrid = TerminalGridSize(cols: 96, rows: 26)
    @ObservationIgnored private var appliedTerminalGrids: [String: TerminalGridSize] = [:]

    #if os(macOS)
    private var localPTYs: [String: LocalPTYProcess] = [:]
    #endif

    private struct FileDraft {
        var text: String
        var baseVersion: String?
    }

    private struct TerminalGridSize: Equatable {
        var cols: Int
        var rows: Int
    }

    var l10n: PrismL10n {
        PrismL10n(language: PrismLanguage.loadSaved())
    }

    /// Only a workspace on this Mac may fall back to reading git and files straight from disk.
    private var allowsLocalFallback: Bool {
        #if os(macOS)
        !isRemoteWorkspace
        #else
        false
        #endif
    }

    public init() {}

    private var workspaceHostID = SartoState.localHostID

    public func attach(
        host: SartoHostSession?,
        terminal: SartoTerminalSession?,
        projectPath: String,
        hostId: String = SartoState.localHostID,
        isRemote: Bool = false
    ) {
        let changedConnection = self.hostSession !== host || self.workspaceHostID != hostId
        self.hostSession = host
        self.isRemoteWorkspace = isRemote
        resetGitFlowState(keepTools: false)
        let resolvedPath = projectPath.isEmpty
            ? Self.defaultProjectPath
            : projectPath
        if changedConnection || resolvedPath != self.activeProjectPath {
            stashOpenFileDraftIfDirty()
            self.workspaceHostID = hostId
            self.projectGeneration &+= 1
            self.isUploadingFiles = false
            self.activeProjectPath = resolvedPath
            self.selectedForCommit.removeAll()
            self.selectedDiffPath = nil
            self.activeFileDiff = nil
            self.computedDiff = ComputedDiff(hunks: [], insertions: 0, deletions: 0)
            resetProjectFilesState()
            resetOpenFileState()
        }

        syncFileWatcher(host: host, projectPath: projectPath)

        pendingTerminalAcks.removeAll()
        terminalAckTask?.cancel()
        terminalAckTask = nil
        appliedTerminalGrids.removeAll()
        if let terminal {
            self.terminalSession = terminal
            startTerminalEventLoop(terminal)
            Task { @MainActor [weak self] in
                await self?.syncRemoteTerminals()
            }
        } else {
            terminalEventTask?.cancel()
            terminalEventTask = nil
            terminalSession = nil
        }
    }

    public func setProjectPath(_ path: String) async {
        guard !path.isEmpty else { return }
        if path != activeProjectPath {
            stashOpenFileDraftIfDirty()
            projectGeneration &+= 1
            isUploadingFiles = false
            activeProjectPath = path
            selectedForCommit.removeAll()
            selectedDiffPath = nil
            activeFileDiff = nil
            computedDiff = ComputedDiff(hunks: [], insertions: 0, deletions: 0)
            resetProjectFilesState()
            resetOpenFileState()
            gitNotice = nil
            resetGitFlowState(keepTools: true)
            syncFileWatcher(host: hostSession, projectPath: path)
        }
        async let gitTask: Void = refreshGit()
        async let filesTask: Void = refreshFiles()
        _ = await (gitTask, filesTask)
    }

    private func resetProjectFilesState() {
        filePaths.removeAll()
        folderPaths.removeAll()
        ignoredPaths.removeAll()
        ignoredFolders.removeAll()
        loadedIgnoredFolders.removeAll()
        loadingIgnoredFolders.removeAll()
    }

    private func resetOpenFileState() {
        selectedFilePath = nil
        isFileDirty = false
        isEditingFile = false
        openFileText = ""
        openFileVersion = nil
        openFileAgentFolder = nil
        openFileImageData = nil
        openFileLocalURL = nil
        openFileIsExternal = false
        openFileStatusNote = nil
        openFileHasSaveConflict = false
    }

    var notConnectedNote: String {
        l10n.tr("workbench.notice.hostNotConnected")
    }

    // MARK: - Git Operations

    public func refreshGit() async {
        let gen = projectGeneration
        let projectPath = activeProjectPath
        isLoadingGit = true
        gitNotice = nil
        defer {
            if projectGeneration == gen {
                isLoadingGit = false
            }
        }

        if let host = hostSession {
            do {
                async let st = host.gitStatus(projectPath: projectPath)
                async let ch = host.gitChanges(projectPath: projectPath)
                let loadedStatus = try await st
                let loadedChanges = try await ch
                guard projectGeneration == gen else { return }
                self.gitStatus = loadedStatus
                self.changedFiles = loadedChanges
                self.gitLoadError = nil
                onGitStatusLoaded?(loadedStatus)
                schedulePullRequestRefresh(for: loadedStatus, generation: gen)
                syncSelectionAfterGitLoad()
                if let path = selectedDiffPath {
                    await loadDiff(for: path)
                } else {
                    activeFileDiff = nil
                    computedDiff = ComputedDiff(hunks: [], insertions: 0, deletions: 0)
                }
                return
            } catch {
                guard projectGeneration == gen else { return }
                if !allowsLocalFallback {
                    showGitLoadFailure(error.localizedDescription)
                    return
                }
                gitNotice = error.localizedDescription
            }
        } else if !allowsLocalFallback {
            guard projectGeneration == gen else { return }
            showGitLoadFailure(notConnectedNote)
            return
        }

        #if os(macOS)
        await refreshGitLocalMac(generation: gen, projectPath: projectPath)
        #endif
    }

    private func showGitLoadFailure(_ message: String) {
        gitStatus = nil
        currentPullRequest = nil
        changedFiles = []
        selectedDiffPath = nil
        activeFileDiff = nil
        computedDiff = ComputedDiff(hunks: [], insertions: 0, deletions: 0)
        gitLoadError = message
    }

    public func loadDiff(for path: String) async {
        let gen = projectGeneration
        let projectPath = activeProjectPath
        selectedDiffPath = path
        if let host = hostSession {
            do {
                let entry = changedFiles.first { $0.path == path }
                let diff = try await host.gitFileDiff(
                    projectPath: projectPath,
                    path: path,
                    oldPath: entry?.oldPath,
                    ref: nil
                )
                guard projectGeneration == gen, selectedDiffPath == path else { return }
                await applyLoadedDiff(diff, generation: gen, expectedPath: path)
                return
            } catch {
                guard projectGeneration == gen else { return }
                gitNotice = error.localizedDescription
                if !allowsLocalFallback { return }
            }
        } else if !allowsLocalFallback {
            gitNotice = notConnectedNote
            return
        }

        #if os(macOS)
        await loadDiffLocalMac(path: path, generation: gen, projectPath: projectPath)
        #endif
    }

    public func generateCommitMessage() async {
        guard let host = hostSession else {
            gitNotice = l10n.tr("workbench.commitAiOffline")
            return
        }
        let targets = selectedForCommit.isEmpty ? changedFiles.map(\.path) : Array(selectedForCommit)
        guard !targets.isEmpty else { return }
        isGeneratingCommitMessage = true
        gitNotice = nil
        defer { isGeneratingCommitMessage = false }
        do {
            let generated = try await host.gitCommitMessage(projectPath: activeProjectPath, paths: targets)
            let trimmed = generated.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                commitMessage = trimmed
            }
        } catch {
            gitNotice = error.localizedDescription
        }
    }

    /// Whether the commit was made.
    @discardableResult
    public func commitSelectedChanges() async -> Bool {
        let msg = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let targets = selectedForCommit.isEmpty ? changedFiles.map(\.path) : Array(selectedForCommit)
        guard !msg.isEmpty, !targets.isEmpty else { return false }

        if let host = hostSession {
            do {
                _ = try await host.gitCommitChanges(projectPath: activeProjectPath, message: msg, paths: targets)
                commitMessage = ""
                selectedForCommit.removeAll()
                gitNotice = l10n.tr("workbench.notice.committed", targets.count)
                await refreshGit()
                return true
            } catch {
                gitNotice = error.localizedDescription
                return false
            }
        }
        guard allowsLocalFallback else {
            gitNotice = notConnectedNote
            return false
        }

        #if os(macOS)
        let cwd = activeProjectPath
        let result = await Task.detached { () -> (Int32, String) in
            let addRes = Self.runProcess("/usr/bin/git", args: ["add", "--"] + targets, cwd: cwd)
            guard addRes.code == 0 else { return (addRes.code, addRes.stderr) }
            let commitRes = Self.runProcess("/usr/bin/git", args: ["commit", "-m", msg, "--"] + targets, cwd: cwd)
            return (commitRes.code, commitRes.code == 0 ? commitRes.stdout : commitRes.stderr)
        }.value

        if result.0 == 0 {
            commitMessage = ""
            selectedForCommit.removeAll()
            gitNotice = l10n.tr("workbench.notice.committedLocal", targets.count)
            await refreshGit()
            return true
        }
        gitNotice = result.1.trimmingCharacters(in: .whitespacesAndNewlines)
        return false
        #else
        return false
        #endif
    }

    public func discardChanges(paths: [String]) async {
        guard !paths.isEmpty else { return }
        if let host = hostSession {
            do {
                _ = try await host.gitDiscardChanges(projectPath: activeProjectPath, paths: paths)
                gitNotice = l10n.tr("workbench.notice.discarded", paths.count)
                await refreshGit()
                return
            } catch {
                gitNotice = error.localizedDescription
                return
            }
        }
        guard allowsLocalFallback else {
            gitNotice = notConnectedNote
            return
        }

        #if os(macOS)
        let cwd = activeProjectPath
        let res = await Task.detached { () -> (Int32, String) in
            let r = Self.runProcess("/usr/bin/git", args: ["checkout", "--"] + paths, cwd: cwd)
            return (r.code, r.stderr)
        }.value
        gitNotice = res.0 == 0 ? l10n.tr("workbench.notice.discarded", paths.count) : res.1
        await refreshGit()
        #endif
    }

    private func applyLoadedDiff(_ diff: FileDiffInfo, generation: UInt64, expectedPath: String) async {
        if diff.binary || diff.tooLarge {
            guard projectGeneration == generation, selectedDiffPath == expectedPath else { return }
            activeFileDiff = diff
            computedDiff = ComputedDiff(hunks: [], insertions: 0, deletions: 0)
            return
        }
        let oldText = diff.oldText
        let newText = diff.newText
        let computed = await Task.detached(priority: .userInitiated) {
            UnifiedDiffEngine.compute(oldText: oldText, newText: newText, contextLines: 3)
        }.value
        guard projectGeneration == generation, selectedDiffPath == expectedPath else { return }
        activeFileDiff = diff
        computedDiff = computed
    }

    private func syncSelectionAfterGitLoad() {
        let validPaths = Set(changedFiles.map(\.path))
        selectedForCommit.formIntersection(validPaths)
        if let current = selectedDiffPath, validPaths.contains(current) {
            return
        }
        selectedDiffPath = changedFiles.first?.path
    }

    // MARK: - Files Operations

    private func syncFileWatcher(host: SartoHostSession?, projectPath: String) {
        let normalizedTarget = Self.normalizeProjectPath(projectPath)
        guard let host, !normalizedTarget.isEmpty else {
            filesChangedDebounceTask?.cancel()
            filesChangedDebounceTask = nil
            if let oldPath = watchedFilesProjectPath, let oldHost = watchedFilesHostSession {
                watchedFilesProjectPath = nil
                watchedFilesHostSession = nil
                Task {
                    try? await oldHost.unwatchFiles(projectPath: oldPath)
                }
            } else {
                watchedFilesProjectPath = nil
                watchedFilesHostSession = nil
            }
            return
        }

        let previousPath = watchedFilesProjectPath
        let previousHost = watchedFilesHostSession
        if previousHost === host,
           let previousPath,
           Self.normalizeProjectPath(previousPath) == normalizedTarget {
            return
        }

        filesChangedDebounceTask?.cancel()
        filesChangedDebounceTask = nil
        watchedFilesProjectPath = projectPath
        watchedFilesHostSession = host

        Task { @MainActor [weak self] in
            if let previousPath, let previousHost {
                try? await previousHost.unwatchFiles(projectPath: previousPath)
            }
            guard let self,
                  self.hostSession === host,
                  self.watchedFilesHostSession === host,
                  self.watchedFilesProjectPath == projectPath else {
                return
            }
            try? await host.watchFiles(projectPath: projectPath)
        }
    }

    /// Handles a host `files.changed` notification for `projectPath` with a 250ms debounce,
    /// reloading the project tree and silently refreshing the open file if it has no unsaved edits.
    public func handleFilesChanged(projectPath: String) {
        let normalizedIncoming = Self.normalizeProjectPath(projectPath)
        guard !normalizedIncoming.isEmpty,
              normalizedIncoming == Self.normalizeProjectPath(activeProjectPath) else {
            return
        }

        filesChangedDebounceTask?.cancel()
        filesChangedDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            guard Self.normalizeProjectPath(self.activeProjectPath) == normalizedIncoming else {
                self.filesChangedDebounceTask = nil
                return
            }
            let gen = self.projectGeneration
            await self.refreshFiles()
            guard !Task.isCancelled, self.projectGeneration == gen else {
                if !Task.isCancelled { self.filesChangedDebounceTask = nil }
                return
            }
            if let openPath = self.selectedFilePath, !self.isFileDirty {
                await self.silentlyRefreshOpenFile(path: openPath, generation: gen)
            }
            if !Task.isCancelled {
                self.filesChangedDebounceTask = nil
            }
        }
    }

    private func silentlyRefreshOpenFile(path: String, generation gen: UInt64) async {
        let projectPath = activeProjectPath
        if let host = hostSession {
            let content: ProjectFileContent?
            if path.hasPrefix("/"), let sessionId = activeSessionID {
                content = try? await host.filesReadAgentFile(sessionId: sessionId, path: path)
            } else {
                content = try? await host.filesRead(projectPath: projectPath, path: path)
            }
            guard let content else { return }
            guard projectGeneration == gen, selectedFilePath == path, !isFileDirty else { return }
            applySilentlyRefreshedContent(content)
            return
        }
        guard allowsLocalFallback else { return }
        #if os(macOS)
        let maxBytes = Self.maxDiffOrFileBytes
        let result = await Task.detached { () -> ProjectFileContent? in
            guard let fullURL = Self.safeProjectFileURL(rootPath: projectPath, relativePath: path) else { return nil }
            if let size = (try? fullURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maxBytes {
                return .tooLarge(path: path, size: size, limit: maxBytes)
            }
            guard let data = try? Data(contentsOf: fullURL) else { return nil }
            if data.count > maxBytes {
                return .tooLarge(path: path, size: data.count, limit: maxBytes)
            }
            if !data.prefix(8000).contains(0), let text = String(data: data, encoding: .utf8) {
                return .text(path: path, size: data.count, text: text, version: Self.contentVersion(data), editable: true)
            }
            return .binary(path: path, size: data.count)
        }.value
        guard projectGeneration == gen, selectedFilePath == path, !isFileDirty, let result else { return }
        applySilentlyRefreshedContent(result)
        #endif
    }

    private func applySilentlyRefreshedContent(_ content: ProjectFileContent) {
        switch content {
        case .text(_, _, let text, let version, let editable):
            if text != openFileText || version != openFileVersion || editable != openFileEditable {
                openFileText = text
                openFileVersion = version
                openFileEditable = editable
                openFileHasSaveConflict = false
            }
        case .binary, .tooLarge, .media:
            applyFileContent(content)
        }
    }

    /// Returns true when `path` names an HTML file (`.html` or `.htm`, case-insensitive).
    public nonisolated static func isHTMLPath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "html" || ext == "htm"
    }

    /// Returns true when `path` names a Markdown document (`.md`, `.markdown`, or `.mdx`).
    public nonisolated static func isMarkdownPath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown" || ext == "mdx"
    }

    /// Returns true when `path` names a raster image file supported by native preview.
    public nonisolated static func isImagePath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "bmp", "tiff", "tif":
            return true
        default:
            return false
        }
    }

    /// Resolves `path` (relative or absolute) ONLY when its symlink-canonicalized path lies inside `rootPath`.
    public nonisolated static func safeContainedFileURL(rootPath: String, path: String) -> URL? {
        guard !rootPath.isEmpty, !path.isEmpty else { return nil }
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : (rootURL.path + "/")
        let candidate: URL = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : rootURL.appendingPathComponent(path)
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(rootPrefix),
              FileManager.default.fileExists(atPath: resolved.path)
        else { return nil }
        return resolved
    }

    /// Serves a session-relative HTML file on the local host's loopback preview server and returns
    /// its preview URL.
    public func previewHTMLFile(sessionId: String, relativePath: String) async throws -> String {
        guard !isRemoteWorkspace else {
            throw PortRPCError(code: "forbidden", message: l10n.tr("files.previewFailed"))
        }
        guard let host = hostSession else {
            throw PortRPCError(code: "not_connected", message: notConnectedNote)
        }
        return try await host.previewFile(sessionId: sessionId, path: relativePath)
    }

    /// Formats a file passage quote for the composer, computing 1-based line numbers when `passage`
    /// is found in `fullContent`, or falling back to `@path` when no passage is selected.
    public nonisolated static func formatPassageQuote(
        path: String,
        passage: String,
        fullContent: String?
    ) -> String {
        let normalizedPassage = normalizeLineEndings(passage)
        let (stripped, leadingNewlines) = stripEdgeNewlines(normalizedPassage)
        guard !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "@\(displayRelativePath(path))"
        }

        var lineRange: ClosedRange<Int>? = nil
        if let fullContent {
            let normalizedFull = normalizeLineEndings(fullContent)
            if let match = normalizedFull.range(of: normalizedPassage) {
                let before = normalizedFull[..<match.lowerBound]
                let startLine = countNewlines(before) + 1 + leadingNewlines
                let endLine = startLine + countNewlines(stripped)
                lineRange = startLine...endLine
            } else if let match = normalizedFull.range(of: stripped) {
                let before = normalizedFull[..<match.lowerBound]
                let startLine = countNewlines(before) + 1
                let endLine = startLine + countNewlines(stripped)
                lineRange = startLine...endLine
            }
        }
        return formatPassageQuote(path: path, passage: stripped, lineRange: lineRange)
    }

    /// Formats a file passage quote using an already-known 1-based line range.
    public nonisolated static func formatPassageQuote(
        path: String,
        passage: String,
        lineRange: ClosedRange<Int>?
    ) -> String {
        let cleanPath = displayRelativePath(path)
        let normalizedPassage = normalizeLineEndings(passage)
        let (stripped, _) = stripEdgeNewlines(normalizedPassage)
        guard !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "@\(cleanPath)"
        }

        let header: String
        if let lineRange {
            if lineRange.lowerBound == lineRange.upperBound {
                header = "@\(cleanPath):\(lineRange.lowerBound)"
            } else {
                header = "@\(cleanPath):\(lineRange.lowerBound)-\(lineRange.upperBound)"
            }
        } else {
            header = "@\(cleanPath)"
        }

        let body = clipPassage(stripped, limit: 2000)
        let fence = backtickFence(for: body)
        let language = fenceLanguage(for: cleanPath)
        return "\(header)\n\(fence)\(language)\n\(body)\n\(fence)"
    }

    private nonisolated static func displayRelativePath(_ path: String) -> String {
        let normalized = normalizeRelativePath(path)
        return normalized.isEmpty ? path : normalized
    }

    private nonisolated static func normalizeProjectPath(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    private nonisolated static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private nonisolated static func stripEdgeNewlines(_ text: String) -> (String, Int) {
        var start = text.startIndex
        var leading = 0
        while start < text.endIndex && text[start] == "\n" {
            start = text.index(after: start)
            leading += 1
        }
        var end = text.endIndex
        while end > start && text[text.index(before: end)] == "\n" {
            end = text.index(before: end)
        }
        return (String(text[start..<end]), leading)
    }

    private nonisolated static func countNewlines<S: StringProtocol>(_ slice: S) -> Int {
        slice.utf8.reduce(0) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) }
    }

    private nonisolated static func clipPassage(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let prefix = String(text.prefix(limit))
        if let lastNewline = prefix.lastIndex(of: "\n"), lastNewline > prefix.startIndex {
            return String(prefix[..<lastNewline]) + "\n..."
        }
        return prefix + "..."
    }

    private nonisolated static func backtickFence(for text: String) -> String {
        var longest = 0
        var run = 0
        for ch in text {
            if ch == "`" {
                run += 1
                if run > longest { longest = run }
            } else {
                run = 0
            }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    private nonisolated static func fenceLanguage(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return "" }
        if ext == "svg" { return "xml" }
        if ext == "mermaid" || ext == "math" { return "" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789+#-")
        return ext.unicodeScalars.allSatisfy { allowed.contains($0) } ? ext : ""
    }

    /// Returns true if `path` or any of its ancestor folders is gitignored.
    public func isIgnored(path: String) -> Bool {
        let normalized = Self.normalizeRelativePath(path)
        guard !normalized.isEmpty else { return false }
        if ignoredPaths.contains(normalized) || ignoredFolders.contains(normalized) {
            return true
        }
        var current = normalized
        while let slash = current.lastIndex(of: "/") {
            current = String(current[..<slash])
            if ignoredFolders.contains(current) || ignoredPaths.contains(current) {
                return true
            }
        }
        return false
    }

    public var filteredFilePaths: [String] {
        let allPaths: [String]
        if showIgnoredFiles && !ignoredPaths.isEmpty {
            let known = Set(filePaths)
            let extraIgnored = ignoredPaths.filter { !known.contains($0) }.sorted()
            allPaths = (filePaths + extraIgnored).sorted()
        } else {
            allPaths = filePaths
        }
        let q = fileFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return Array(allPaths.prefix(250)) }
        return Array(allPaths.filter { $0.lowercased().contains(q) }.prefix(200))
    }

    public func refreshFiles() async {
        let gen = projectGeneration
        let projectPath = activeProjectPath
        isLoadingFiles = true
        defer {
            if projectGeneration == gen {
                isLoadingFiles = false
            }
        }

        if let host = hostSession {
            do {
                let list = try await host.filesList(projectPath: projectPath)
                guard projectGeneration == gen else { return }
                filePaths = list.paths
                folderPaths = list.folders
                ignoredPaths = Set(list.ignored)
                ignoredFolders = Set(list.ignoredFolders)
                loadedIgnoredFolders.removeAll()
                loadingIgnoredFolders.removeAll()
                if selectedFilePath == nil, let first = filePaths.first {
                    await openFile(path: first)
                }
                return
            } catch {
                guard projectGeneration == gen else { return }
                openFileStatusNote = error.localizedDescription
                if !allowsLocalFallback {
                    resetProjectFilesState()
                    return
                }
            }
        } else if !allowsLocalFallback {
            guard projectGeneration == gen else { return }
            resetProjectFilesState()
            openFileStatusNote = notConnectedNote
            return
        }

        #if os(macOS)
        let collected = await Task.detached { () -> [String] in
            Self.scanLocalProjectFiles(rootPath: projectPath, limit: 1500)
        }.value
        guard projectGeneration == gen else { return }
        filePaths = collected
        folderPaths = []
        ignoredPaths.removeAll()
        ignoredFolders.removeAll()
        loadedIgnoredFolders.removeAll()
        loadingIgnoredFolders.removeAll()
        if selectedFilePath == nil,
           let first = collected.first(where: { $0.hasSuffix(".swift") || $0.hasSuffix(".ts") || $0 == "README.md" }) ?? collected.first {
            await openFile(path: first)
        }
        #endif
    }

    /// Lazily lists one gitignored folder's immediate children once, merging them into the tree
    /// and marking every returned file and subfolder as ignored.
    public func loadIgnoredFolder(_ folderPath: String, force: Bool = false) async {
        let normalized = Self.normalizeRelativePath(folderPath)
        guard !normalized.isEmpty else { return }
        if !force && loadedIgnoredFolders[normalized] != nil { return }
        guard !loadingIgnoredFolders.contains(normalized) else { return }

        let gen = projectGeneration
        let projectPath = activeProjectPath
        loadingIgnoredFolders.insert(normalized)
        defer {
            if projectGeneration == gen {
                loadingIgnoredFolders.remove(normalized)
            }
        }

        if let host = hostSession {
            do {
                let listing = try await host.filesListFolder(projectPath: projectPath, path: normalized)
                guard projectGeneration == gen else { return }
                loadedIgnoredFolders[normalized] = listing
                ignoredPaths.formUnion(listing.paths)
                ignoredFolders.formUnion(listing.folders)
                return
            } catch {
                guard projectGeneration == gen else { return }
                openFileStatusNote = error.localizedDescription
                return
            }
        }

        #if os(macOS)
        guard allowsLocalFallback else {
            openFileStatusNote = notConnectedNote
            return
        }
        let localListing = await Task.detached(priority: .userInitiated) { () -> ProjectFolderList? in
            Self.listLocalFolderChildren(rootPath: projectPath, relativeFolder: normalized)
        }.value
        guard projectGeneration == gen, let localListing else { return }
        loadedIgnoredFolders[normalized] = localListing
        ignoredPaths.formUnion(localListing.paths)
        ignoredFolders.formUnion(localListing.folders)
        #endif
    }

    /// Uploads local files (picked via Open panel or dropped from Finder) into `folder`
    /// (empty string for the project root), prompting to replace or skip on conflict.
    public func uploadFiles(urls: [URL], intoFolder folder: String, generation gen: UInt64) async {
        guard !urls.isEmpty, projectGeneration == gen, !isUploadingFiles else { return }
        let host = hostSession
        let projectPath = activeProjectPath
        let cleanFolder = Self.normalizeRelativePath(folder)
        isUploadingFiles = true
        defer {
            if projectGeneration == gen {
                isUploadingFiles = false
            }
        }

        var uploadedAny = false

        for url in urls {
            guard projectGeneration == gen else { return }
            let item: PreparedUploadFile
            do {
                item = try await Task.detached(priority: .userInitiated) {
                    try Self.readLocalUploadFile(url)
                }.value
            } catch {
                guard projectGeneration == gen else { return }
                openFileStatusNote = l10n.tr("files.uploadFailed", error.localizedDescription)
                continue
            }
            guard projectGeneration == gen else { return }
            let targetPath = cleanFolder.isEmpty ? item.name : "\(cleanFolder)/\(item.name)"

            if let host {
                do {
                    try await host.filesUpload(
                        projectPath: projectPath,
                        path: targetPath,
                        bytes: item.data,
                        replace: false
                    )
                    uploadedAny = true
                } catch let rpcError as PortRPCError where Self.isUploadConflict(rpcError) {
                    guard projectGeneration == gen else { return }
                    if confirmReplaceUploadedFile(named: item.name) {
                        do {
                            try await host.filesUpload(
                                projectPath: projectPath,
                                path: targetPath,
                                bytes: item.data,
                                replace: true
                            )
                            uploadedAny = true
                        } catch {
                            openFileStatusNote = l10n.tr("files.uploadFailed", error.localizedDescription)
                        }
                    }
                } catch {
                    openFileStatusNote = l10n.tr("files.uploadFailed", error.localizedDescription)
                }
            } else if allowsLocalFallback {
                #if os(macOS)
                let outcome = await Task.detached(priority: .userInitiated) { () -> LocalUploadOutcome in
                    Self.writeLocalUploadedFile(
                        rootPath: projectPath,
                        relativePath: targetPath,
                        data: item.data,
                        replace: false
                    )
                }.value
                switch outcome {
                case .written:
                    uploadedAny = true
                case .conflict:
                    guard projectGeneration == gen else { return }
                    if confirmReplaceUploadedFile(named: item.name) {
                        let retryOutcome = await Task.detached(priority: .userInitiated) { () -> LocalUploadOutcome in
                            Self.writeLocalUploadedFile(
                                rootPath: projectPath,
                                relativePath: targetPath,
                                data: item.data,
                                replace: true
                            )
                        }.value
                        switch retryOutcome {
                        case .written:
                            uploadedAny = true
                        case .conflict:
                            break
                        case .failed(let message):
                            openFileStatusNote = l10n.tr("files.uploadFailed", message)
                        }
                    }
                case .failed(let message):
                    openFileStatusNote = l10n.tr("files.uploadFailed", message)
                }
                #endif
            } else {
                openFileStatusNote = notConnectedNote
                return
            }
        }

        guard projectGeneration == gen, uploadedAny else { return }
        await refreshFiles()
    }

    private func confirmReplaceUploadedFile(named name: String) -> Bool {
        #if os(macOS)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = l10n.tr("files.uploadConflictTitle")
        alert.informativeText = l10n.tr("files.uploadConflictMessage", name)
        alert.addButton(withTitle: l10n.tr("files.uploadReplace"))
        alert.addButton(withTitle: l10n.tr("files.uploadSkip"))
        return alert.runModal() == .alertFirstButtonReturn
        #else
        return false
        #endif
    }

    private static func isUploadConflict(_ error: PortRPCError) -> Bool {
        error.code == "conflict" || error.message.localizedCaseInsensitiveContains("already exists")
    }

    private nonisolated static func normalizeRelativePath(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    private struct PreparedUploadFile: Sendable {
        let name: String
        let data: Data
    }

    private nonisolated static func readLocalUploadFile(_ url: URL) throws -> PreparedUploadFile {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        let limit = AttachmentLimits.maxAttachmentBytes
        guard (values.fileSize ?? 0) <= limit else { throw CocoaError(.fileReadTooLarge) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var bytes = Data()
        while let chunk = try handle.read(upToCount: min(256 * 1024, limit + 1 - bytes.count)), !chunk.isEmpty {
            bytes.append(chunk)
            guard bytes.count <= limit else { throw CocoaError(.fileReadTooLarge) }
        }
        return PreparedUploadFile(name: url.lastPathComponent, data: bytes)
    }

    /// Whether `relativePath` (in the active project) has edits that are not saved yet.
    public func isFileModified(_ relativePath: String) -> Bool {
        if relativePath == selectedFilePath && isFileDirty { return true }
        guard !fileDrafts.isEmpty else { return false }
        return fileDrafts[draftKey(for: relativePath, in: activeProjectPath)] != nil
    }

    /// Re-reads the open file, dropping its unsaved edits.
    public func reloadOpenFile() async {
        guard let path = selectedFilePath else { return }
        await openFile(path: path, force: true)
    }

    /// Opens `path`. Unsaved edits of the file being left are kept in memory and come back when it is
    /// reopened; `force` drops the edits of `path` itself and reads it again.
    public func openFile(path: String, force: Bool = false) async {
        // Never overwrite unsaved editor contents when re-selecting or refreshing the same file.
        if !force && isFileDirty && selectedFilePath == path {
            return
        }

        let gen = projectGeneration
        let projectPath = activeProjectPath
        if selectedFilePath != path {
            stashOpenFileDraftIfDirty()
        }
        let key = draftKey(for: path, in: projectPath)
        if force {
            fileDrafts.removeValue(forKey: key)
        }
        selectedFilePath = path
        isFileDirty = false
        isEditingFile = false
        openFileAgentFolder = nil
        openFileImageData = nil
        openFileLocalURL = nil
        openFileIsExternal = false
        openFileStatusNote = nil
        openFileHasSaveConflict = false

        if let draft = fileDrafts.removeValue(forKey: key) {
            openFileText = draft.text
            openFileVersion = draft.baseVersion
            openFileEditable = true
            isFileDirty = true
            openFileStatusNote = l10n.tr("workbench.notice.draftRestored")
            if !isRemoteWorkspace {
                openFileLocalURL = Self.safeContainedFileURL(rootPath: projectPath, path: path)
            }
            return
        }

        if let host = hostSession {
            if path.hasPrefix("/"), let sessionId = activeSessionID {
                do {
                    let content = try await host.filesReadAgentFile(sessionId: sessionId, path: path)
                    let folder: String?
                    if let cached = agentFolderBySessionID[sessionId] {
                        folder = cached
                    } else if let fetched = try? await host.filesAgentFolder(sessionId: sessionId), !fetched.isEmpty {
                        agentFolderBySessionID[sessionId] = fetched
                        folder = fetched
                    } else {
                        folder = nil
                    }
                    guard projectGeneration == gen, selectedFilePath == path else { return }
                    if isFileDirty { return }
                    openFileAgentFolder = folder
                    applyFileContent(content)
                    await attachLocalPreviewIfAllowed(path: path, rootPath: folder, generation: gen)
                    return
                } catch {
                    guard projectGeneration == gen, selectedFilePath == path else { return }
                    openFileText = ""
                    openFileVersion = nil
                    openFileEditable = false
                    openFileAgentFolder = nil
                    openFileImageData = nil
                    openFileLocalURL = nil
                    openFileStatusNote = error.localizedDescription
                    await attachExternalLocalFileOnUserClick(path: path, generation: gen)
                    return
                }
            }
            do {
                let content = try await host.filesRead(projectPath: projectPath, path: path)
                guard projectGeneration == gen, selectedFilePath == path else { return }
                if isFileDirty { return }
                applyFileContent(content)
                await attachLocalPreviewIfAllowed(path: path, rootPath: projectPath, generation: gen)
                return
            } catch {
                guard projectGeneration == gen, selectedFilePath == path else { return }
                openFileText = ""
                openFileVersion = nil
                openFileEditable = false
                openFileImageData = nil
                openFileLocalURL = nil
                openFileStatusNote = error.localizedDescription
                if path.hasPrefix("/") {
                    await attachExternalLocalFileOnUserClick(path: path, generation: gen)
                }
                return
            }
        }
        guard allowsLocalFallback else {
            openFileText = ""
            openFileVersion = nil
            openFileEditable = false
            openFileStatusNote = notConnectedNote
            return
        }

        #if os(macOS)
        let maxBytes = Self.maxDiffOrFileBytes
        let result = await Task.detached { () -> ProjectFileContent? in
            guard let fullURL = Self.safeProjectFileURL(rootPath: projectPath, relativePath: path) else { return nil }
            if let size = (try? fullURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maxBytes {
                return .tooLarge(path: path, size: size, limit: maxBytes)
            }
            guard let data = try? Data(contentsOf: fullURL) else { return nil }
            if data.count > maxBytes {
                return .tooLarge(path: path, size: data.count, limit: maxBytes)
            }
            if !data.prefix(8000).contains(0), let text = String(data: data, encoding: .utf8) {
                return .text(path: path, size: data.count, text: text, version: Self.contentVersion(data), editable: true)
            }
            return .binary(path: path, size: data.count)
        }.value

        guard projectGeneration == gen, selectedFilePath == path else { return }
        if isFileDirty { return }
        if let result {
            applyFileContent(result)
            await attachLocalPreviewIfAllowed(path: path, rootPath: projectPath, generation: gen)
        } else {
            openFileText = ""
            openFileEditable = false
            openFileImageData = nil
            openFileLocalURL = nil
            openFileStatusNote = l10n.tr("workbench.notice.readFailed", path)
        }
        #endif
    }

    private func attachLocalPreviewIfAllowed(path: String, rootPath: String?, generation gen: UInt64) async {
        guard !isRemoteWorkspace, let rootPath, !rootPath.isEmpty else { return }
        let safeURL = Self.safeContainedFileURL(rootPath: rootPath, path: path)
        guard projectGeneration == gen, selectedFilePath == path else { return }
        openFileLocalURL = safeURL
        guard let safeURL, Self.isImagePath(path) else { return }
        let bytes = await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let data = try? Data(contentsOf: safeURL), data.count <= 20 * 1024 * 1024 else {
                return nil
            }
            return data
        }.value
        guard projectGeneration == gen, selectedFilePath == path else { return }
        if let bytes {
            openFileImageData = bytes
            openFileStatusNote = nil
        }
    }

    /// When the user explicitly clicks a local file link outside the project/agent folder (e.g. a PNG
    /// saved to Desktop), expose Reveal-in-Finder and in-app raster image preview without ever
    /// executing the file or sending its bytes to the daemon/agent.
    private func attachExternalLocalFileOnUserClick(path: String, generation gen: UInt64) async {
        guard !isRemoteWorkspace, path.hasPrefix("/") else { return }
        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard projectGeneration == gen, selectedFilePath == path else { return }
        openFileLocalURL = fileURL
        openFileIsExternal = true
        guard Self.isImagePath(path) else {
            openFileStatusNote = nil
            return
        }
        let bytes = await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let data = try? Data(contentsOf: fileURL), data.count <= 20 * 1024 * 1024 else {
                return nil
            }
            return data
        }.value
        guard projectGeneration == gen, selectedFilePath == path else { return }
        if let bytes {
            openFileImageData = bytes
            openFileStatusNote = nil
        }
    }

    /// Saves the open file. Unless `overwrite` is set, the save is refused when the file changed since
    /// it was read (`openFileHasSaveConflict` turns on); `overwrite` writes over those changes.
    public func saveOpenFile(overwrite: Bool = false) async {
        guard let path = selectedFilePath, openFileEditable else { return }
        let gen = projectGeneration
        let projectPath = activeProjectPath
        let key = draftKey(for: path, in: projectPath)
        let textToWrite = openFileText
        let expectedVersion = overwrite ? nil : openFileVersion
        if let host = hostSession {
            do {
                let written = try await host.filesWrite(
                    projectPath: projectPath,
                    path: path,
                    text: textToWrite,
                    version: expectedVersion
                )
                finishSave(
                    key: key,
                    generation: gen,
                    path: path,
                    savedText: textToWrite,
                    version: written.version,
                    note: l10n.tr("workbench.notice.savedBytes", written.size)
                )
                await refreshGit()
            } catch let error as PortRPCError where error.code == "conflict" {
                guard projectGeneration == gen, selectedFilePath == path else { return }
                openFileHasSaveConflict = true
                openFileStatusNote = l10n.tr("workbench.notice.saveConflict")
            } catch {
                guard projectGeneration == gen, selectedFilePath == path else { return }
                openFileStatusNote = error.localizedDescription
            }
            return
        }
        guard allowsLocalFallback else {
            openFileStatusNote = notConnectedNote
            return
        }

        #if os(macOS)
        let outcome = await Task.detached { () -> LocalSaveOutcome in
            Self.writeLocalFile(
                rootPath: projectPath,
                relativePath: path,
                text: textToWrite,
                expectedVersion: expectedVersion
            )
        }.value

        switch outcome {
        case .saved(let version):
            finishSave(
                key: key,
                generation: gen,
                path: path,
                savedText: textToWrite,
                version: version,
                note: l10n.tr("workbench.notice.savedDisk")
            )
            await refreshGit()
        case .conflict:
            guard projectGeneration == gen, selectedFilePath == path else { return }
            openFileHasSaveConflict = true
            openFileStatusNote = l10n.tr("workbench.notice.saveConflict")
        case .failed:
            guard projectGeneration == gen, selectedFilePath == path else { return }
            openFileStatusNote = l10n.tr("workbench.notice.writeFailed")
        }
        #endif
    }

    private func finishSave(
        key: String,
        generation: UInt64,
        path: String,
        savedText: String,
        version: String,
        note: String
    ) {
        if projectGeneration == generation && selectedFilePath == path {
            openFileVersion = version
            openFileHasSaveConflict = false
            // Edits typed while the write was in flight are still unsaved.
            isFileDirty = openFileText != savedText
            openFileStatusNote = note
            return
        }
        // The user moved on while saving: the stashed draft now sits on top of the version just written.
        guard var draft = fileDrafts[key] else { return }
        if draft.text == savedText {
            fileDrafts.removeValue(forKey: key)
        } else {
            draft.baseVersion = version
            fileDrafts[key] = draft
        }
    }

    private func stashOpenFileDraftIfDirty() {
        guard isFileDirty, openFileEditable, let path = selectedFilePath else { return }
        fileDrafts[draftKey(for: path, in: activeProjectPath)] = FileDraft(text: openFileText, baseVersion: openFileVersion)
    }

    private func draftKey(for relativePath: String, in projectPath: String) -> String {
        workspaceHostID + "\0" + URL(fileURLWithPath: projectPath).appendingPathComponent(relativePath).standardizedFileURL.path
    }

    private func applyFileContent(_ content: ProjectFileContent) {
        switch content {
        case .text(_, _, let text, let version, let editable):
            openFileText = text
            openFileVersion = version
            openFileEditable = editable
        case .binary(_, let size):
            openFileText = ""
            openFileEditable = false
            openFileStatusNote = l10n.tr("workbench.notice.binaryFile", size)
        case .tooLarge(_, let size, let limit):
            openFileText = ""
            openFileEditable = false
            openFileStatusNote = l10n.tr("workbench.notice.tooLargeFile", size / 1024, limit / 1024)
        case .media:
            openFileText = ""
            openFileEditable = false
            openFileStatusNote = l10n.tr("workbench.notice.mediaPreview")
        }
    }

    // MARK: - Terminal Operations

    public var activeTerminal: TerminalTabBuffer? {
        terminals.first(where: { $0.id == activeTerminalID }) ?? terminals.first
    }

    public func ensureDefaultTerminal() async {
        await syncRemoteTerminals()
        if !terminals.isEmpty { return }
        await createTerminal(sessionId: activeSessionID)
    }

    public func syncRemoteTerminals() async {
        guard let term = terminalSession else { return }
        guard let list = try? await term.listTerminals(projectPath: activeProjectPath) else { return }
        for info in list {
            if let idx = terminals.firstIndex(where: { $0.id == info.id }) {
                terminals[idx].info = info
            } else {
                let replay = (try? await term.attach(id: info.id)) ?? ""
                terminals.append(TerminalTabBuffer(id: info.id, info: info, rawOutput: replay, isRemote: true))
            }
        }
        if activeTerminalID == nil || !terminals.contains(where: { $0.id == activeTerminalID }) {
            activeTerminalID = terminals.first?.id
        }
    }

    public func renameTerminal(id: String, name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let idx = terminals.firstIndex(where: { $0.id == id }) else { return }
        if terminals[idx].isRemote, let term = terminalSession {
            if let updated = try? await term.rename(id: id, name: trimmed) {
                if let currentIdx = terminals.firstIndex(where: { $0.id == id }) {
                    terminals[currentIdx].info = updated
                }
            }
            return
        }
        let old = terminals[idx].info
        terminals[idx].info = TerminalInfo(
            id: old.id,
            projectPath: old.projectPath,
            sessionId: old.sessionId,
            shell: old.shell,
            title: old.title,
            name: trimmed.isEmpty ? nil : trimmed,
            namedBy: trimmed.isEmpty ? nil : "user",
            busy: old.busy,
            exitCode: old.exitCode,
            createdAt: old.createdAt,
            owner: old.owner,
            agentAllowed: old.agentAllowed,
            agentAsks: old.agentAsks,
            control: old.control,
            waiting: old.waiting
        )
    }

    public func takeOverTerminal(id: String? = nil) async {
        guard let targetID = id ?? activeTerminal?.id,
              let tab = terminals.first(where: { $0.id == targetID }),
              tab.isRemote,
              let term = terminalSession
        else { return }
        _ = try? await term.takeOver(id: targetID)
    }

    public func handBackTerminal(id: String? = nil) async {
        guard let targetID = id ?? activeTerminal?.id,
              let tab = terminals.first(where: { $0.id == targetID }),
              tab.isRemote,
              let term = terminalSession
        else { return }
        _ = try? await term.handBack(id: targetID)
    }

    public func revokeTerminalAccess(id: String? = nil) async {
        guard let targetID = id ?? activeTerminal?.id,
              let tab = terminals.first(where: { $0.id == targetID }),
              let host = hostSession,
              let sid = tab.info.sessionId ?? activeSessionID
        else { return }
        try? await host.revokeTerminalAccess(sessionId: sid, terminalId: targetID)
    }

    public func restartTerminal(id: String? = nil) async {
        guard let targetID = id ?? activeTerminal?.id,
              let tab = terminals.first(where: { $0.id == targetID }),
              tab.isRemote,
              let term = terminalSession
        else { return }
        if let restarted = try? await term.restart(id: targetID),
           let idx = terminals.firstIndex(where: { $0.id == targetID }) {
            terminals[idx].info = restarted
            terminals[idx].resetOutput()
        }
    }

    public func createTerminal(
        sessionId: String? = nil,
        command: String? = nil,
        runCommand: Bool = false
    ) async {
        let resolvedSession = sessionId ?? activeSessionID
        let grid = terminalGrid
        let targetPath = activeProjectPath.isEmpty ? NSHomeDirectory() : activeProjectPath
        if let term = terminalSession {
            do {
                let info = try await term.createTerminal(
                    projectPath: targetPath,
                    sessionId: resolvedSession,
                    cols: grid.cols,
                    rows: grid.rows,
                    command: command,
                    runCommand: runCommand
                )
                let replay = (try? await term.attach(id: info.id)) ?? ""
                let tab = TerminalTabBuffer(id: info.id, info: info, rawOutput: replay, isRemote: true)
                terminals.append(tab)
                appliedTerminalGrids[info.id] = grid
                activeTerminalID = info.id
                return
            } catch {
                if !allowsLocalFallback {
                    appendTerminalNotice(error.localizedDescription)
                    return
                }
            }
        } else if !allowsLocalFallback {
            appendTerminalNotice(l10n.tr("workbench.terminal.remoteUnavailable"))
            return
        }

        #if os(macOS)
        let id = "pty-\(UUID().uuidString.prefix(6))"
        let info = TerminalInfo(
            id: id,
            projectPath: targetPath,
            sessionId: sessionId,
            shell: "zsh",
            title: "zsh · \((targetPath as NSString).lastPathComponent)"
        )
        let tab = TerminalTabBuffer(
            id: id,
            info: info,
            rawOutput: "\u{001B}[36mSarto Local PTY\u{001B}[0m · \(targetPath)\n",
            isRemote: false
        )
        terminals.append(tab)
        activeTerminalID = id

        let pty = LocalPTYProcess(id: id)
        localPTYs[id] = pty
        appliedTerminalGrids[id] = grid
        do {
            try pty.start(
                cwd: targetPath,
                cols: UInt16(grid.cols),
                rows: UInt16(grid.rows),
                onOutput: { [weak self] chunk in
                    Task { @MainActor [weak self] in
                        self?.appendTerminalOutput(id: id, chunk: chunk)
                    }
                },
                onExit: { [weak self] code in
                    Task { @MainActor [weak self] in
                        self?.appendTerminalOutput(id: id, chunk: "\n\u{001B}[90m[process exited with status \(code)]\u{001B}[0m\n")
                    }
                }
            )
            if let command, !command.isEmpty {
                let text = runCommand ? command + "\n" : command
                pty.write(text)
            }
        } catch {
            appendTerminalOutput(id: id, chunk: "\u{001B}[31mFailed to launch local PTY: \(error.localizedDescription)\u{001B}[0m\n")
        }
        #endif
    }

    /// Shows why no shell could be opened as a tab of its own, since there is no shell to print into.
    private func appendTerminalNotice(_ message: String) {
        let id = "notice-\(UUID().uuidString.prefix(6))"
        let info = TerminalInfo(id: id, projectPath: activeProjectPath, shell: "", title: l10n.tr("workbench.tab.terminal"))
        terminals.append(TerminalTabBuffer(
            id: id,
            info: info,
            rawOutput: "\u{001B}[31m\(message)\u{001B}[0m\n",
            isRemote: false
        ))
        activeTerminalID = id
    }

    /// Sizes the PTY behind a terminal tab to the pane. New terminals start at the last size seen.
    public func resizeTerminal(id: String? = nil, cols: Int, rows: Int) async {
        let grid = TerminalGridSize(cols: min(max(cols, 20), 500), rows: min(max(rows, 4), 300))
        terminalGrid = grid
        guard let targetID = id ?? activeTerminal?.id,
              let tab = terminals.first(where: { $0.id == targetID }),
              appliedTerminalGrids[targetID] != grid
        else { return }
        appliedTerminalGrids[targetID] = grid
        if tab.isRemote {
            guard let term = terminalSession else { return }
            do {
                try await term.resize(id: targetID, cols: grid.cols, rows: grid.rows)
            } catch {
                appliedTerminalGrids.removeValue(forKey: targetID)
            }
            return
        }
        #if os(macOS)
        localPTYs[targetID]?.resize(cols: UInt16(grid.cols), rows: UInt16(grid.rows))
        #endif
    }

    public func sendTerminalInput(_ text: String, id: String? = nil) async {
        guard let targetID = id ?? activeTerminal?.id,
              let tab = terminals.first(where: { $0.id == targetID })
        else { return }

        if tab.isRemote, let term = terminalSession {
            try? await term.sendInput(id: targetID, data: text)
            return
        }

        #if os(macOS)
        localPTYs[targetID]?.write(text)
        #endif
    }

    public func clearTerminal(id: String? = nil) {
        guard let targetID = id ?? activeTerminal?.id,
              let idx = terminals.firstIndex(where: { $0.id == targetID })
        else { return }
        terminals[idx].resetOutput()
    }

    public func closeTerminal(id: String) async {
        if let tab = terminals.first(where: { $0.id == id }), tab.isRemote, let term = terminalSession {
            try? await term.kill(id: id)
        }
        #if os(macOS)
        localPTYs[id]?.terminate()
        localPTYs.removeValue(forKey: id)
        #endif
        terminals.removeAll { $0.id == id }
        appliedTerminalGrids.removeValue(forKey: id)
        pendingTerminalAcks.removeValue(forKey: id)
        if activeTerminalID == id {
            activeTerminalID = terminals.first?.id
        }
    }

    private func startTerminalEventLoop(_ session: SartoTerminalSession) {
        terminalEventTask?.cancel()
        terminalEventTask = Task { [weak self] in
            for await event in session.events {
                guard let self, !Task.isCancelled else { break }
                switch event {
                case .data(let id, let chunk):
                    self.appendTerminalOutput(id: id, chunk: chunk)
                    // Sarto's pty-manager.ts counts JS string `.length` in UTF-16 code units!
                    self.queueTerminalAck(id: id, chars: chunk.utf16.count, session: session)
                case .replay(let id, let replay):
                    if let idx = self.terminals.firstIndex(where: { $0.id == id }) {
                        self.terminals[idx].resetOutput(with: replay)
                    }
                case .info(let info):
                    if let idx = self.terminals.firstIndex(where: { $0.id == info.id }) {
                        self.terminals[idx].info = info
                    } else if info.projectPath == self.activeProjectPath || info.sessionId == self.activeSessionID {
                        self.terminals.append(TerminalTabBuffer(id: info.id, info: info, isRemote: true))
                        if info.owner != nil || self.activeTerminalID == nil {
                            self.activeTerminalID = info.id
                        }
                        Task { @MainActor [weak self] in
                            guard let self, let replay = try? await session.attach(id: info.id) else { return }
                            if let idx = self.terminals.firstIndex(where: { $0.id == info.id }), !replay.isEmpty {
                                self.terminals[idx].resetOutput(with: replay)
                            }
                        }
                    }
                case .removed(let id):
                    self.terminals.removeAll { $0.id == id }
                case .unknown:
                    break
                }
            }
        }
    }

    private func appendTerminalOutput(id: String, chunk: String) {
        guard let idx = terminals.firstIndex(where: { $0.id == id }) else { return }
        terminals[idx].appendChunk(chunk)
    }

    /// Acknowledges output without holding up the event loop: awaiting each ack's round trip capped a
    /// relayed terminal at a few chunks per second. Counts are summed per terminal and sent in order.
    private func queueTerminalAck(id: String, chars: Int, session: SartoTerminalSession) {
        guard chars > 0 else { return }
        pendingTerminalAcks[id, default: 0] += chars
        guard terminalAckTask == nil else { return }
        terminalAckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(15))
            while let self, !Task.isCancelled, self.terminalSession === session, !self.pendingTerminalAcks.isEmpty {
                let batch = self.pendingTerminalAcks
                self.pendingTerminalAcks.removeAll()
                for (terminalID, count) in batch {
                    try? await session.ack(id: terminalID, chars: count)
                }
            }
            if !Task.isCancelled {
                self?.terminalAckTask = nil
            }
        }
    }

    // MARK: - Local macOS Git & Filesystem Helpers

    #if os(macOS)
    private func refreshGitLocalMac(generation: UInt64, projectPath: String) async {
        let snapshot = await Task.detached { () -> (GitStatusInfo?, [ChangedFileInfo]) in
            let branchRes = Self.runProcess("/usr/bin/git", args: ["--no-optional-locks", "rev-parse", "--abbrev-ref", "HEAD"], cwd: projectPath)
            guard branchRes.code == 0 else { return (nil, []) }
            let branch = branchRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let oid = Self.runProcess("/usr/bin/git", args: ["--no-optional-locks", "rev-parse", "--short", "HEAD"], cwd: projectPath)
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let porcelain = Self.runProcess("/usr/bin/git", args: ["--no-optional-locks", "status", "--porcelain=v1"], cwd: projectPath).stdout
            let numstat = Self.runProcess("/usr/bin/git", args: ["--no-optional-locks", "diff", "--numstat", "HEAD"], cwd: projectPath).stdout

            var statsByPath: [String: (Int, Int)] = [:]
            for line in numstat.split(separator: "\n") {
                let parts = line.split(separator: "\t")
                if parts.count >= 3, let ins = Int(parts[0]), let del = Int(parts[1]) {
                    statsByPath[String(parts[2])] = (ins, del)
                }
            }

            var files: [ChangedFileInfo] = []
            var staged = 0, unstaged = 0, untracked = 0, totalIns = 0, totalDel = 0

            for rawLine in porcelain.split(separator: "\n") {
                let line = String(rawLine)
                guard line.count >= 4 else { continue }
                let x = line[line.startIndex]
                let y = line[line.index(after: line.startIndex)]
                let rawPath = String(line.dropFirst(3))
                let parts = rawPath.components(separatedBy: " -> ")
                let oldPath = parts.count > 1 ? parts.first : nil
                let path = parts.last ?? rawPath

                let status: GitChangeStatus
                if x == "?" && y == "?" {
                    status = .untracked
                    untracked += 1
                } else {
                    if x != " " { staged += 1 }
                    if y != " " { unstaged += 1 }
                    if x == "D" || y == "D" { status = .deleted }
                    else if x == "A" || y == "A" { status = .added }
                    else if x == "R" || y == "R" { status = .renamed }
                    else if x == "U" || y == "U" { status = .conflicted }
                    else { status = .modified }
                }

                let st = statsByPath[path]
                totalIns += st?.0 ?? 0
                totalDel += st?.1 ?? 0
                files.append(ChangedFileInfo(path: path, oldPath: oldPath, status: status, insertions: st?.0, deletions: st?.1))
            }

            let statusInfo = GitStatusInfo(
                projectPath: projectPath,
                repo: GitRepoRef(root: projectPath, gitDir: "\(projectPath)/.git"),
                head: GitHeadInfo(branch: branch, oid: oid, detached: branch == "HEAD"),
                changes: GitChangesSummary(
                    staged: staged,
                    unstaged: unstaged,
                    untracked: untracked,
                    conflicted: 0,
                    insertions: totalIns,
                    deletions: totalDel
                )
            )
            return (statusInfo, files)
        }.value

        guard projectGeneration == generation else { return }
        self.gitStatus = snapshot.0
        self.changedFiles = snapshot.1
        self.gitLoadError = nil
        syncSelectionAfterGitLoad()
        if let path = selectedDiffPath {
            await loadDiffLocalMac(path: path, generation: generation, projectPath: projectPath)
        } else {
            activeFileDiff = nil
            computedDiff = ComputedDiff(hunks: [], insertions: 0, deletions: 0)
        }
    }

    private func loadDiffLocalMac(path: String, generation: UInt64, projectPath: String) async {
        let entry = changedFiles.first { $0.path == path }
        let maxBytes = Self.maxDiffOrFileBytes
        let diff = await Task.detached(priority: .userInitiated) { () -> FileDiffInfo in
            Self.computeFileDiffLocal(
                cwd: projectPath,
                path: path,
                oldPath: entry?.oldPath,
                status: entry?.status,
                maxBytes: maxBytes
            )
        }.value

        guard projectGeneration == generation, selectedDiffPath == path else { return }
        await applyLoadedDiff(diff, generation: generation, expectedPath: path)
    }

    private nonisolated static func computeFileDiffLocal(
        cwd: String,
        path: String,
        oldPath: String?,
        status: GitChangeStatus?,
        maxBytes: Int
    ) -> FileDiffInfo {
        var oldText: String? = nil
        if status != .untracked {
            let headTarget = oldPath ?? path
            let sizeRes = runProcess("/usr/bin/git", args: ["--no-optional-locks", "cat-file", "-s", "HEAD:\(headTarget)"], cwd: cwd)
            if sizeRes.code == 0 {
                if let blobSize = Int(sizeRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
                   blobSize > maxBytes {
                    return FileDiffInfo(path: path, oldText: nil, newText: nil, binary: false, tooLarge: true)
                }
                let showRes = runProcess("/usr/bin/git", args: ["--no-optional-locks", "show", "HEAD:\(headTarget)"], cwd: cwd)
                if showRes.code == 0 {
                    oldText = showRes.stdout
                }
            }
        }

        var newText: String? = nil
        if status != .deleted {
            guard let url = safeProjectFileURL(rootPath: cwd, relativePath: path) else {
                return FileDiffInfo(path: path, oldText: oldText, newText: nil)
            }
            if let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
               fileSize > maxBytes {
                return FileDiffInfo(path: path, oldText: nil, newText: nil, binary: false, tooLarge: true)
            }
            if let data = try? Data(contentsOf: url) {
                if data.count > maxBytes {
                    return FileDiffInfo(path: path, oldText: nil, newText: nil, binary: false, tooLarge: true)
                }
                if data.prefix(8000).contains(0) {
                    return FileDiffInfo(path: path, oldText: nil, newText: nil, binary: true, tooLarge: false)
                }
                if let str = String(data: data, encoding: .utf8) {
                    newText = str
                } else {
                    return FileDiffInfo(path: path, oldText: nil, newText: nil, binary: true, tooLarge: false)
                }
            }
        }
        return FileDiffInfo(path: path, oldText: oldText, newText: newText)
    }

    private enum LocalSaveOutcome: Sendable {
        case saved(version: String)
        case conflict
        case failed
    }

    private enum LocalUploadOutcome: Sendable {
        case written
        case conflict
        case failed(String)
    }

    private nonisolated static func writeLocalUploadedFile(
        rootPath: String,
        relativePath: String,
        data: Data,
        replace: Bool
    ) -> LocalUploadOutcome {
        guard let url = safeProjectFileURL(rootPath: rootPath, relativePath: relativePath) else {
            return .failed("Invalid destination path")
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            if !replace { return .conflict }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return .failed("Destination is a folder")
            }
        }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return .written
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private nonisolated static func listLocalFolderChildren(
        rootPath: String,
        relativeFolder: String
    ) -> ProjectFolderList? {
        guard let folderURL = safeProjectFileURL(rootPath: rootPath, relativePath: relativeFolder) else {
            return nil
        }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        ) else {
            return nil
        }
        var paths: [String] = []
        var folders: [String] = []
        for entry in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            if name == ".git" { continue }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let rel = "\(relativeFolder)/\(name)"
            if values?.isDirectory == true {
                folders.append(rel)
            } else if values?.isRegularFile == true {
                paths.append(rel)
            }
        }
        return ProjectFolderList(paths: paths, folders: folders, truncated: false)
    }

    /// Same scheme as the host's `files.read` version: the SHA-256 of the file's bytes.
    private nonisolated static func contentVersion(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes `text` unless the file no longer has `expectedVersion` (the host's `files.write` rule).
    private nonisolated static func writeLocalFile(
        rootPath: String,
        relativePath: String,
        text: String,
        expectedVersion: String?
    ) -> LocalSaveOutcome {
        guard let url = safeProjectFileURL(rootPath: rootPath, relativePath: relativePath) else { return .failed }
        if let expectedVersion {
            guard let current = try? Data(contentsOf: url), contentVersion(current) == expectedVersion else {
                return .conflict
            }
        }
        let data = Data(text.utf8)
        do {
            try data.write(to: url, options: .atomic)
            return .saved(version: contentVersion(data))
        } catch {
            return .failed
        }
    }

    private final class PipeDataBox: @unchecked Sendable {
        var data = Data()
    }

    /// Drains stdout and stderr concurrently via DispatchGroup *before* `waitUntilExit()` so >64 KiB outputs never deadlock.
    private nonisolated static func runProcess(
        _ executable: String,
        args: [String],
        cwd: String
    ) -> (code: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        if FileManager.default.fileExists(atPath: cwd) {
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()

            let outBox = PipeDataBox()
            let errBox = PipeDataBox()
            let outRead = outPipe.fileHandleForReading
            let errRead = errPipe.fileHandleForReading
            let group = DispatchGroup()

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                outBox.data = outRead.readDataToEndOfFile()
                group.leave()
            }

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                errBox.data = errRead.readDataToEndOfFile()
                group.leave()
            }

            group.wait()
            proc.waitUntilExit()
            return (
                proc.terminationStatus,
                String(decoding: outBox.data, as: UTF8.self),
                String(decoding: errBox.data, as: UTF8.self)
            )
        } catch {
            return (-1, "", error.localizedDescription)
        }
    }

    /// Resolves symlinks on BOTH `rootURL` and `candidate` (or parent directory when `candidate` does not exist yet)
    /// to prevent symlink escape outside the active project folder.
    private nonisolated static func safeProjectFileURL(rootPath: String, relativePath: String) -> URL? {
        guard !rootPath.isEmpty, !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            return nil
        }
        let fm = FileManager.default
        let resolvedRootURL = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
        let rootResolvedPath = resolvedRootURL.path
        let rawCandidate = resolvedRootURL.appendingPathComponent(relativePath).standardizedFileURL

        let resolvedCandidate: URL
        if fm.fileExists(atPath: rawCandidate.path)
            || (try? fm.destinationOfSymbolicLink(atPath: rawCandidate.path)) != nil {
            resolvedCandidate = rawCandidate.resolvingSymlinksInPath()
        } else {
            resolvedCandidate = rawCandidate
                .deletingLastPathComponent()
                .resolvingSymlinksInPath()
                .appendingPathComponent(rawCandidate.lastPathComponent)
                .standardizedFileURL
        }

        let resolvedPath = resolvedCandidate.path
        let rootPrefix = rootResolvedPath.hasSuffix("/") ? rootResolvedPath : (rootResolvedPath + "/")
        guard resolvedPath == rootResolvedPath || resolvedPath.hasPrefix(rootPrefix) else {
            return nil
        }
        return resolvedCandidate
    }

    private nonisolated static func scanLocalProjectFiles(rootPath: String, limit: Int) -> [String] {
        let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        let skipDirs: Set<String> = [".git", "node_modules", ".build", "DerivedData", "out", "dist", ".DS_Store"]
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var results: [String] = []
        let prefixLen = rootURL.path.count + 1
        while let url = enumerator.nextObject() as? URL {
            let name = url.lastPathComponent
            if skipDirs.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values?.isDirectory == true { continue }
            if url.path.count > prefixLen {
                results.append(String(url.path.dropFirst(prefixLen)))
            }
            if results.count >= limit { break }
        }
        return results.sorted()
    }
    #endif
}

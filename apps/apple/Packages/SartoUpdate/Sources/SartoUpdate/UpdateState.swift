import Foundation

/// Install replaces the app; Link only offers the release's disk image. The packaging writes the
/// mode into Info.plist: Install for a Developer ID build, Link for an ad-hoc one, which macOS
/// would refuse to run in place of a signed one.
public enum UpdateMode: String, Codable, Sendable {
    case install
    case link

    /// The mode Info.plist names, or nil for a build without one, as from Xcode.
    public static func configured(_ value: Any?) -> UpdateMode? {
        guard let text = value as? String else { return nil }
        return UpdateMode(rawValue: text.trimmingCharacters(in: .whitespaces))
    }
}

/// When new versions download, and when they install.
public enum UpdateChoice: String, CaseIterable, Codable, Sendable {
    /// Download, install when the user clicks Install and Restart, or on quit. The default.
    case download
    /// Download, then install on its own (`AutoInstall`): at once when only the app changes, after
    /// ten quiet minutes when the daemon does.
    case automatic
    /// Download, install only when the user clicks Install and Restart.
    case restart
    /// Ask before downloading.
    case notify
    /// Check only when asked.
    case off
}

/// Who started a download: the updater, as the choice says, or the user with Update.
public enum StartedBy: String, Codable, Sendable {
    case auto
    case user
}

public enum OffReason: String, Codable, Sendable {
    case development
}

public enum UpdateState: Equatable, Sendable {
    case off(OffReason)
    /// Up to date, or not checked yet.
    case idle(checkedAt: Date?)
    case checking(manual: Bool)
    /// Found, not downloading. In Link mode `downloadURL` is the disk image for this Mac.
    case available(version: String, mode: UpdateMode, downloadURL: URL?)
    /// `manual`: the user started it with Update.
    case downloading(version: String, percent: Int, manual: Bool)
    /// Downloaded, verified and staged; `notes` are the release's highlights by language.
    case ready(version: String, notes: [String: [String]])
    case error(message: String, manual: Bool)

    public var version: String? {
        switch self {
        case .available(let version, _, _), .downloading(let version, _, _), .ready(let version, _):
            return version
        default:
            return nil
        }
    }
}

public enum UpdaterEvent: Equatable, Sendable {
    case checking(manual: Bool)
    case available(version: String)
    case notAvailable(at: Date)
    case downloadStarted(version: String, manual: Bool)
    case progress(percent: Double)
    case downloaded(version: String, notes: [String: [String]])
    case downloadCancelled
    case error(message: String, manual: Bool)
}

public struct TransitionContext: Equatable, Sendable {
    public var mode: UpdateMode
    /// The updater starts the download itself after a check.
    public var autoDownload: Bool
    public var lastCheckedAt: Date?
    /// The version found last, to fall back to after a failed automatic download.
    public var lastAvailable: String?
    /// In Link mode, the disk image to open for `lastAvailable`.
    public var downloadURL: URL?

    public init(
        mode: UpdateMode,
        autoDownload: Bool,
        lastCheckedAt: Date? = nil,
        lastAvailable: String? = nil,
        downloadURL: URL? = nil
    ) {
        self.mode = mode
        self.autoDownload = autoDownload
        self.lastCheckedAt = lastCheckedAt
        self.lastAvailable = lastAvailable
        self.downloadURL = downloadURL
    }
}

public enum UpdateMachine {
    static func available(_ version: String, _ context: TransitionContext) -> UpdateState {
        .available(version: version, mode: context.mode, downloadURL: context.mode == .link ? context.downloadURL : nil)
    }

    public static func next(_ state: UpdateState, _ event: UpdaterEvent, _ context: TransitionContext) -> UpdateState {
        if case .off = state { return state }
        switch event {
        case .checking(let manual):
            // Keep an available update visible while a background check runs.
            if !manual, case .available = state { return state }
            return .checking(manual: manual)
        case .available(let version):
            if context.mode == .install, context.autoDownload {
                return .downloading(version: version, percent: 0, manual: false)
            }
            return available(version, context)
        case .notAvailable(let at):
            return .idle(checkedAt: at)
        case .downloadStarted(let version, let manual):
            return .downloading(version: version, percent: 0, manual: manual)
        case .progress(let percent):
            guard case .downloading(let version, let current, let manual) = state, percent.isFinite else { return state }
            // A download that moves on to another source starts that file again; the bar holds.
            let next = Int(max(0, min(100, percent.rounded(.down))))
            return next > current ? .downloading(version: version, percent: next, manual: manual) : state
        case .downloaded(let version, let notes):
            return .ready(version: version, notes: notes)
        case .downloadCancelled:
            if case .downloading(let version, _, _) = state { return available(version, context) }
            return state
        case .error(let message, let manual):
            if manual { return .error(message: message, manual: true) }
            // Automatic failures are only logged and retried at the next check, so the state
            // falls back to what was known before.
            switch state {
            case .ready:
                return .error(message: message, manual: false)
            case .downloading(let version, _, _):
                return available(version, context)
            case .checking:
                if let last = context.lastAvailable { return available(last, context) }
                return .idle(checkedAt: context.lastCheckedAt)
            default:
                return state
            }
        }
    }

    /// Whether a downloaded update installs when the app quits without a restart for it.
    public static func installOnQuit(choice: UpdateChoice, startedBy: StartedBy) -> Bool {
        !(choice == .restart && startedBy == .auto)
    }

    /// Whether a check that found `version` starts its download by itself.
    public static func autoDownload(choice: UpdateChoice, mode: UpdateMode, canInstall: Bool) -> Bool {
        mode == .install && canInstall && (choice == .automatic || choice == .download || choice == .restart)
    }

    /// Whether the updater checks on its own schedule.
    public static func checksAutomatically(choice: UpdateChoice) -> Bool {
        choice != .off
    }

    /// The version a dismissal hides: the notice on screen, or the "Updated to" one.
    public static func dismissTarget(state: UpdateState, current: String, updatedFrom: String?) -> String? {
        switch state {
        case .ready(let version, _), .available(let version, _, _):
            return version
        default:
            return updatedFrom == nil ? nil : current
        }
    }

    /// What the updater's requests say they are.
    public static func userAgent(version: String, arch: String) -> String {
        "Sarto/\(version) (darwin; \(arch))"
    }

    /// The first line of an error, short enough for Settings.
    public static func shortMessage(_ text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: false).first.map {
            $0.trimmingCharacters(in: .whitespaces)
        } ?? ""
        let message = line.isEmpty ? "Unknown error" : line
        return message.count > 300 ? String(message.prefix(299)) + "…" : message
    }
}

/// An update downloaded, verified and unpacked, waiting to be installed.
public struct StagedUpdate: Codable, Equatable, Sendable {
    public let version: String
    /// The verified Sarto.app to install.
    public let appPath: String
    public let startedBy: StartedBy
    public let notes: [String: [String]]
    /// The fingerprint of the daemon runtime the update bundles; nil when the update file named none.
    public let runtime: String?

    public init(version: String, appPath: String, startedBy: StartedBy, notes: [String: [String]], runtime: String? = nil) {
        self.version = version
        self.appPath = appPath
        self.startedBy = startedBy
        self.notes = notes
        self.runtime = runtime
    }
}

import Foundation

/// The fingerprint of a daemon runtime: the SHA-256, in lowercase hex, of its files' paths, modes
/// and contents, taken before the release's version is stamped into the daemon and before signing,
/// so two releases whose daemon did not change share it (tools/sarto/runtime-fingerprint.mjs).
public enum RuntimeFingerprint {
    public static func isValid(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }
    }

    /// The name of the folder an installed runtime lives in.
    public static func folderName(_ fingerprint: String) -> String {
        String(fingerprint.prefix(16))
    }

    /// The fingerprint folder name in the path of a runtime's Node.js, as
    /// `…/runtimes/<folder>/node/bin/node`; nil for any other path, as a runtime inside an app.
    public static func folderName(inNodePath path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 5,
              parts[parts.count - 1] == "node", parts[parts.count - 2] == "bin", parts[parts.count - 3] == "node",
              parts[parts.count - 5] == "runtimes"
        else { return nil }
        let folder = String(parts[parts.count - 4])
        return folder.count == 16 && folder.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) })
            ? folder
            : nil
    }

    /// Whether Node.js at `path` runs a daemon a Sarto app started: from a runtime copy, or from the
    /// runtime inside the app, as apps did before the copies. A daemon the user runs from an install
    /// of their own is neither, and the app leaves it alone.
    public static func startedByApp(nodePath path: String) -> Bool {
        folderName(inNodePath: path) != nil || path.contains(".app/Contents/Resources/runtime/")
    }
}

/// When a downloaded update installs by itself, with the automatic choice: one that only changes
/// the app installs as soon as the user is away from it, since the daemon and its sessions keep
/// running; one that changes the daemon waits until nothing has run for ten minutes as well, and
/// then replaces both, so a new app never talks to an old daemon. A daemon left from another
/// runtime, with no update waiting, is restarted on the same terms.
public enum AutoInstall {
    /// How long the daemon must have been without tasks before it is restarted.
    public static let quietPeriod: TimeInterval = 10 * 60
    /// How long without keyboard or mouse input counts as the user being away while Sarto is in front.
    public static let awayAfter: TimeInterval = 2 * 60

    public enum Action: Equatable, Sendable {
        case wait
        /// Swap the app and open it again; the daemon keeps running.
        case installApp
        /// Stop the daemon, swap the app and open it again.
        case installAppAndDaemon
        /// Restart the daemon from the app's own runtime.
        case restartDaemon
    }

    public struct Situation: Equatable, Sendable {
        public var choice: UpdateChoice
        /// An update is downloaded and staged.
        public var staged: Bool
        /// Installing the staged update would replace the running daemon.
        public var stagedRestartsDaemon: Bool
        /// The running daemon is from another runtime than the app's.
        public var daemonOutdated: Bool
        /// Sarto is not in front, or there has been no input for `awayAfter`.
        public var userAway: Bool
        /// How long the daemon has been without running tasks; nil while it has some.
        public var quietFor: TimeInterval?

        public init(
            choice: UpdateChoice,
            staged: Bool,
            stagedRestartsDaemon: Bool,
            daemonOutdated: Bool,
            userAway: Bool,
            quietFor: TimeInterval?
        ) {
            self.choice = choice
            self.staged = staged
            self.stagedRestartsDaemon = stagedRestartsDaemon
            self.daemonOutdated = daemonOutdated
            self.userAway = userAway
            self.quietFor = quietFor
        }
    }

    public static func decide(_ situation: Situation, quietPeriod: TimeInterval = quietPeriod) -> Action {
        guard situation.userAway else { return .wait }
        let quiet = (situation.quietFor ?? -1) >= quietPeriod
        if situation.staged, situation.choice == .automatic {
            if !situation.stagedRestartsDaemon { return .installApp }
            return quiet ? .installAppAndDaemon : .wait
        }
        if !situation.staged, situation.daemonOutdated, quiet { return .restartDaemon }
        return .wait
    }

    /// Whether installing an update with `updateRuntime` replaces the running daemon, whose runtime
    /// folder is `runningFolder`: nil for a daemon the app does not manage or none at all.
    public static func restartsDaemon(updateRuntime: String?, runningFolder: String?, daemonManaged: Bool) -> Bool {
        guard daemonManaged else { return false }
        guard let updateRuntime, let runningFolder else { return true }
        return RuntimeFingerprint.folderName(updateRuntime) != runningFolder
    }
}

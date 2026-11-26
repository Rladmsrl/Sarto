import Foundation

/// The app's own folder, `~/Library/Application Support/<bundle id>`, apart from the daemon's data
/// folder: the app writes here before the daemon starts, so the daemon is the first to make its own
/// folder and can move an older one into its place (src/daemon/migrate.ts).
enum SartoAppPaths {
    static func support() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.sarto.mac", isDirectory: true)
    }

    /// The lock one app holds per daemon data folder, so a second copy opened on the same folder
    /// wakes the first instead. It lies beside that folder, not in it or in an app's own folder, so
    /// apps of any bundle id share it.
    static func instanceLock(dataDirectory: String) -> URL {
        let data = URL(fileURLWithPath: dataDirectory, isDirectory: true).standardizedFileURL
        return data.deletingLastPathComponent().appendingPathComponent(".\(data.lastPathComponent).app.lock")
    }

    /// Where a daemon the app starts writes its output.
    static func daemonOutput() -> URL {
        support().appendingPathComponent("logs", isDirectory: true).appendingPathComponent("daemon-output.log")
    }

    /// Written on launch and removed only on clean termination so an unexpected exit is detected next run.
    static func crashMarker() -> URL {
        support().appendingPathComponent("running")
    }
}

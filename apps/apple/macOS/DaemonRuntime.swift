import Darwin
import Foundation
import SartoUpdate

/// The daemon runtime a packaged app carries in Contents/Resources/runtime, as packaging described
/// it in runtime.json.
struct BundledRuntime: Sendable, Equatable {
    let fingerprint: String
    let version: String
    let build: String?
    let channel: String?
    let commit: String?
    let source: URL

    var folderName: String { RuntimeFingerprint.folderName(fingerprint) }
}

/// Where the daemon runs from: a copy of the app's runtime in Application Support, one folder per
/// fingerprint, never the app bundle itself. An update then swaps the bundle while the daemon keeps
/// running from its copy, so only an update that changes the runtime restarts the daemon.
enum DaemonRuntime {
    private static let marker = ".installed"

    /// The runtime this app carries; nil for a build without one, as from Xcode.
    static func bundled(in bundle: Bundle = .main) -> BundledRuntime? {
        guard let source = bundle.resourceURL?.appendingPathComponent("runtime", isDirectory: true),
              let data = try? Data(contentsOf: source.appendingPathComponent("runtime.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fingerprint = object["fingerprint"] as? String, RuntimeFingerprint.isValid(fingerprint),
              let version = object["version"] as? String
        else { return nil }
        return BundledRuntime(
            fingerprint: fingerprint,
            version: version,
            build: object["build"] as? String,
            channel: object["channel"] as? String,
            commit: object["commit"] as? String,
            source: source
        )
    }

    /// One folder per app, by bundle identifier, so a test build never deletes the runtime the
    /// installed app's daemon runs.
    static func root() throws -> URL {
        SartoAppPaths.support().appendingPathComponent("runtimes", isDirectory: true)
    }

    /// The installed copy of `runtime`, copied from the bundle first when there is none. On APFS
    /// the copy is a clone, which takes no space of its own until a file changes.
    static func install(_ runtime: BundledRuntime) throws -> URL {
        let fm = FileManager.default
        let root = try root()
        let destination = root.appendingPathComponent(runtime.folderName, isDirectory: true)
        if fm.fileExists(atPath: destination.appendingPathComponent(marker).path) {
            // Counts as just installed for `removeUnused` in another copy of the app, until the
            // daemon about to start from it shows among the live processes.
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            try? restamp(destination, from: runtime)
            return destination
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let temporary = root.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.copyItem(at: runtime.source, to: temporary)
            try Data(runtime.fingerprint.utf8).write(to: temporary.appendingPathComponent(marker))
            // A folder without the marker is a copy that never finished.
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: temporary, to: destination)
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
        return destination
    }

    /// Releases whose daemon did not change share a fingerprint, and so the installed copy, yet each
    /// stamps its own version, build and channel into the daemon's scripts and runtime.json (see
    /// tools/sarto/runtime-fingerprint.mjs). The copy takes the bundle's stamps when they differ, so a
    /// daemon started from it reports the version the app carries, as when a beta becomes a release.
    /// Each script is replaced whole with a rename, so a host starting meanwhile reads one or the
    /// other, and the scripts only differ in those stamps.
    private static func restamp(_ destination: URL, from runtime: BundledRuntime) throws {
        let fm = FileManager.default
        let metadata = try Data(contentsOf: runtime.source.appendingPathComponent("runtime.json"))
        let installedMetadata = destination.appendingPathComponent("runtime.json")
        guard (try? Data(contentsOf: installedMetadata)) != metadata else { return }
        let daemon = runtime.source.appendingPathComponent("daemon", isDirectory: true)
        guard let files = fm.enumerator(atPath: daemon.path) else { return }
        while let relative = files.nextObject() as? String {
            // stampBuildInfo leaves node_modules alone and writes only scripts.
            if (relative as NSString).lastPathComponent == "node_modules" {
                files.skipDescendants()
                continue
            }
            guard relative.hasSuffix(".js") || relative.hasSuffix(".cjs"),
                  files.fileAttributes?[.type] as? FileAttributeType == .typeRegular
            else { continue }
            let script = try Data(contentsOf: daemon.appendingPathComponent(relative))
            let installed = destination.appendingPathComponent("daemon").appendingPathComponent(relative)
            if (try? Data(contentsOf: installed)) != script {
                try script.write(to: installed, options: .atomic)
            }
        }
        try metadata.write(to: installedMetadata, options: .atomic)
    }

    /// The program the process `pid` runs, as Node.js at its path.
    static func programPath(pid: Int32) -> String? {
        guard pid > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Deletes installed runtimes other than those in `keeping`, and copies that never finished.
    /// Another copy of the app with the same bundle identifier shares this folder, with a daemon of
    /// its own on another data folder, so a runtime any live process runs from stays, and so does
    /// one installed or being installed in the last `recent`, which a daemon may be about to run.
    /// Blocks while it lists processes and deletes files: never call it on the main actor.
    static func removeUnused(keeping: Set<String>, recent: TimeInterval = 10 * 60) {
        let fm = FileManager.default
        guard let root = try? root(),
              let entries = try? fm.contentsOfDirectory(
                  at: root,
                  includingPropertiesForKeys: [.contentModificationDateKey]
              )
        else { return }
        // Without the list of processes nothing tells which runtimes are in use, so none is deleted.
        guard let live = liveRuntimeFolders() else { return }
        let inUse = keeping.union(live)
        let now = Date()
        for entry in entries where !inUse.contains(entry.lastPathComponent) {
            let name = entry.lastPathComponent
            let isRuntime = name.count == 16 && name.allSatisfy { $0.isHexDigit }
            guard isRuntime || name.hasPrefix(".install-") else { continue }
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, now.timeIntervalSince(modified) < recent { continue }
            try? fm.removeItem(at: entry)
        }
    }

    /// The runtime folders the processes running now run Node.js from, whichever app or data
    /// folder they belong to; nil when the processes cannot be listed.
    static func liveRuntimeFolders() -> Set<String>? {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return nil }
        // Room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 256)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return nil }
        var folders = Set<String>()
        for pid in pids.prefix(min(Int(count), pids.count)) {
            if let path = programPath(pid: pid), let folder = RuntimeFingerprint.folderName(inNodePath: path) {
                folders.insert(folder)
            }
        }
        return folders
    }
}

/// A process as it was when the app attached to it, so a signal never reaches another process that
/// took its pid after it exited.
struct DaemonProcessIdentity: Sendable, Equatable {
    let pid: Int32
    let programPath: String
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    /// The process `pid` is now; nil when there is none.
    static func current(pid: Int32) -> DaemonProcessIdentity? {
        guard pid > 1, let path = DaemonRuntime.programPath(pid: pid) else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return DaemonProcessIdentity(
            pid: pid,
            programPath: path,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
    }

    /// Whether `pid` still belongs to this process.
    var isRunning: Bool { Self.current(pid: pid) == self }

    /// SIGTERM, then SIGKILL once `patience` has passed, each only while `pid` is still this
    /// process. Blocks the calling thread, as the app's last moments on quit need.
    func stopBlocking(patience: TimeInterval) {
        guard isRunning, Darwin.kill(pid, SIGTERM) == 0 else { return }
        let deadline = Date().addingTimeInterval(patience)
        while isRunning, Date() < deadline {
            usleep(40_000)
        }
        killAndWait()
    }

    /// `stopBlocking` that sleeps instead of blocking; call it off the main actor.
    func stop(patience: Duration) async {
        guard isRunning, Darwin.kill(pid, SIGTERM) == 0 else { return }
        let deadline = ContinuousClock.now + patience
        while isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        await killAndWaitAsync()
    }

    /// SIGKILL while `pid` is still this process, then a short wait for it to be gone.
    private func killAndWait() {
        guard isRunning, Darwin.kill(pid, SIGKILL) == 0 else { return }
        let deadline = Date().addingTimeInterval(0.5)
        while isRunning, Date() < deadline {
            usleep(20_000)
        }
    }

    private func killAndWaitAsync() async {
        guard isRunning, Darwin.kill(pid, SIGKILL) == 0 else { return }
        let deadline = ContinuousClock.now + .milliseconds(500)
        while isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

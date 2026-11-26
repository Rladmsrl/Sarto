import Foundation
import Testing
@testable import SartoUpdate

@Suite struct UpdateStateTests {
    let install = TransitionContext(mode: .install, autoDownload: true)
    let ask = TransitionContext(mode: .install, autoDownload: false)

    @Test func comparesVersions() {
        #expect(SartoVersion.compare("0.3.0", "0.2.9")! > 0)
        #expect(SartoVersion.compare("0.10.0", "0.9.0")! > 0)
        #expect(SartoVersion.compare("1.0.0-beta.2", "1.0.0-beta.10")! < 0)
        #expect(SartoVersion.compare("1.0.0-beta", "1.0.0")! < 0)
        #expect(SartoVersion.compare("v1.2.3", "1.2.3") == 0)
        #expect(SartoVersion.compare("1.2", "1.2.0") == nil)
        #expect(SartoVersion.compare("0.0.0", "x") == nil)
        #expect(SartoVersion.isRelease("0.3.0"))
        #expect(!SartoVersion.isRelease("0.3.0-beta.1"))
        #expect(!SartoVersion.isRelease("v0.3.0"))
        #expect(SartoVersion.isBeta("0.4.0-beta.261125143512"))
        #expect(!SartoVersion.isBeta("0.4.0-beta.01"))
        #expect(!SartoVersion.isBeta("0.4.0-dev.261125143512"))
        #expect(SartoVersion.isDev("0.4.0-dev.261125143512"))
        #expect(SartoVersion.compare("0.4.0-beta.261125143512", "0.4.0-beta.261125143600")! < 0)
        #expect(SartoVersion.compare("0.4.0-beta.261125143600", "0.4.0")! < 0)
        #expect(SartoVersion.compare("0.4.0", "0.5.0-beta.261125143512")! < 0)
        #expect(SartoVersion.isValidBuildNumber("261125143512"))
        #expect(!SartoVersion.isValidBuildNumber("061125143512"))
        #expect(SartoVersion.bundleVersion(info: ["CFBundleShortVersionString": "0.4.0", "SartoVersion": "0.4.0-beta.261125143512"]) == "0.4.0-beta.261125143512")
        #expect(SartoVersion.bundleVersion(info: ["CFBundleShortVersionString": "0.4.0", "SartoVersion": ""]) == "0.4.0")
        #expect(SartoVersion.buildChannel(version: "0.4.0-beta.261125143512", configured: nil) == .beta)
        #expect(SartoVersion.buildChannel(version: "0.4.0", configured: "dev") == .dev)
        #expect(SartoVersion.updatedFrom(lastRunVersion: "0.2.0", current: "0.3.0") == "0.2.0")
        #expect(SartoVersion.updatedFrom(lastRunVersion: "0.3.0", current: "0.3.0") == nil)
        #expect(SartoVersion.updatedFrom(lastRunVersion: nil, current: "0.3.0") == nil)
    }

    @Test func downloadsByItselfOnlyWhereItCanInstall() {
        #expect(UpdateMachine.next(.checking(manual: false), .available(version: "0.3.0"), install)
            == .downloading(version: "0.3.0", percent: 0, manual: false))
        #expect(UpdateMachine.next(.checking(manual: false), .available(version: "0.3.0"), ask)
            == .available(version: "0.3.0", mode: .install, downloadURL: nil))
        let link = TransitionContext(mode: .link, autoDownload: true, downloadURL: URL(string: "https://x.example/a.dmg"))
        #expect(UpdateMachine.next(.checking(manual: true), .available(version: "0.3.0"), link)
            == .available(version: "0.3.0", mode: .link, downloadURL: URL(string: "https://x.example/a.dmg")))
        #expect(UpdateMachine.autoDownload(choice: .download, mode: .install, canInstall: true))
        #expect(UpdateMachine.autoDownload(choice: .restart, mode: .install, canInstall: true))
        #expect(!UpdateMachine.autoDownload(choice: .notify, mode: .install, canInstall: true))
        #expect(!UpdateMachine.autoDownload(choice: .download, mode: .link, canInstall: true))
        #expect(!UpdateMachine.autoDownload(choice: .download, mode: .install, canInstall: false))
    }

    @Test func keepsWhatWasKnownAfterAnAutomaticFailure() {
        let available = UpdateState.available(version: "0.3.0", mode: .install, downloadURL: nil)
        #expect(UpdateMachine.next(available, .checking(manual: false), ask) == available)
        #expect(UpdateMachine.next(available, .checking(manual: true), ask) == .checking(manual: true))
        #expect(UpdateMachine.next(.downloading(version: "0.3.0", percent: 40, manual: false), .error(message: "x", manual: false), ask) == available)
        var context = ask
        context.lastAvailable = "0.3.0"
        #expect(UpdateMachine.next(.checking(manual: false), .error(message: "x", manual: false), context) == available)
        let checked = Date(timeIntervalSince1970: 100)
        context = TransitionContext(mode: .install, autoDownload: false, lastCheckedAt: checked)
        #expect(UpdateMachine.next(.checking(manual: false), .error(message: "x", manual: false), context) == .idle(checkedAt: checked))
        #expect(UpdateMachine.next(.checking(manual: true), .error(message: "x", manual: true), context) == .error(message: "x", manual: true))
        #expect(UpdateMachine.next(.off(.development), .checking(manual: true), context) == .off(.development))
    }

    @Test func movesTheBarOnlyForward() {
        let state = UpdateState.downloading(version: "0.3.0", percent: 40, manual: true)
        #expect(UpdateMachine.next(state, .progress(percent: 12), ask) == state)
        #expect(UpdateMachine.next(state, .progress(percent: 55.9), ask) == .downloading(version: "0.3.0", percent: 55, manual: true))
        #expect(UpdateMachine.next(state, .progress(percent: .nan), ask) == state)
        #expect(UpdateMachine.next(state, .downloadCancelled, ask) == .available(version: "0.3.0", mode: .install, downloadURL: nil))
    }

    @Test func installsOnQuitUnlessWaitingForARestart() {
        #expect(UpdateMachine.installOnQuit(choice: .download, startedBy: .auto))
        #expect(!UpdateMachine.installOnQuit(choice: .restart, startedBy: .auto))
        #expect(UpdateMachine.installOnQuit(choice: .restart, startedBy: .user))
        #expect(UpdateMachine.installOnQuit(choice: .notify, startedBy: .user))
        #expect(UpdateMachine.userAgent(version: "0.3.0", arch: "arm64") == "Sarto/0.3.0 (darwin; arm64)")
        #expect(UpdateMachine.shortMessage("first\nsecond") == "first")
        #expect(UpdateMachine.shortMessage("  ") == "Unknown error")
    }

    @Test func swapsBundlesInOneRename() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sarto-swap-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Applications/Sarto.app")
        let staged = root.appendingPathComponent("Updates/0.3.0/Sarto.app")
        for (dir, marker) in [(app, "old"), (staged, "new")] {
            try fm.createDirectory(at: dir.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: dir.appendingPathComponent("Contents/marker"))
        }
        let replaced = try BundleSwap.install(staged: staged, over: app)
        #expect(replaced == staged)
        #expect(try String(contentsOf: app.appendingPathComponent("Contents/marker"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: staged.appendingPathComponent("Contents/marker"), encoding: .utf8) == "old")
        #expect(throws: POSIXError.self) {
            try BundleSwap.exchange(root.appendingPathComponent("missing"), app)
        }
    }

    /// Two bundles as `swapsBundlesInOneRename` makes them, and an exchange that refuses the first
    /// call as a rename across volumes does.
    private func crossVolume(_ root: URL) throws -> (app: URL, staged: URL) {
        let fm = FileManager.default
        let app = root.appendingPathComponent("Applications/Sarto.app")
        let staged = root.appendingPathComponent("Updates/0.3.0/Sarto.app")
        for (dir, marker) in [(app, "old"), (staged, "new")] {
            try fm.createDirectory(at: dir.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: dir.appendingPathComponent("Contents/marker"))
        }
        return (app, staged)
    }

    @Test func leavesNoBundleBehindAfterASwapAcrossVolumes() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sarto-swap-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let (app, staged) = try crossVolume(root)
        var calls = 0
        let replaced = try BundleSwap.install(staged: staged, over: app) { a, b in
            calls += 1
            if calls == 1 { throw POSIXError(.EXDEV) }
            try BundleSwap.exchange(a, b)
        }
        #expect(replaced == nil)
        #expect(calls == 2)
        #expect(try String(contentsOf: app.appendingPathComponent("Contents/marker"), encoding: .utf8) == "new")
        #expect(try fm.contentsOfDirectory(atPath: app.deletingLastPathComponent().path) == ["Sarto.app"])
        #expect(!fm.fileExists(atPath: staged.path))
    }

    @Test func keepsTheAppWhenASwapAcrossVolumesFails() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sarto-swap-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let (app, staged) = try crossVolume(root)
        var calls = 0
        #expect(throws: POSIXError.self) {
            try BundleSwap.install(staged: staged, over: app) { _, _ in
                calls += 1
                throw POSIXError(calls == 1 ? .EXDEV : .EIO)
            }
        }
        #expect(try String(contentsOf: app.appendingPathComponent("Contents/marker"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: staged.appendingPathComponent("Contents/marker"), encoding: .utf8) == "new")
        #expect(try fm.contentsOfDirectory(atPath: app.deletingLastPathComponent().path) == ["Sarto.app"])
    }

    @Test func removesOnlyWhatAnEarlierSwapLeftBesideTheApp() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sarto-swap-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent("Applications")
        let app = folder.appendingPathComponent("Sarto.app")
        let kept = [
            "Sarto.app", ".Sarto-update-notes.app", ".Sarto-update-\(UUID().uuidString)", ".Other-update-\(UUID().uuidString).app",
            "Sarto-update-\(UUID().uuidString).app",
        ]
        let left = ".Sarto-update-\(UUID().uuidString).app"
        for name in kept + [left] {
            try fm.createDirectory(at: folder.appendingPathComponent(name).appendingPathComponent("Contents"), withIntermediateDirectories: true)
        }
        BundleSwap.removeLeftovers(beside: app)
        #expect(try Set(fm.contentsOfDirectory(atPath: folder.path)) == Set(kept))
    }
}

@Suite struct UpdateRequirementTests {
    @Test func namesTheBundleAndTheTeam() {
        #expect(UpdateRequirement.text(bundleIdentifier: "dev.sarto.mac", teamIdentifier: "5V5ZAW53N4")
            == #"identifier "dev.sarto.mac" and anchor apple generic and certificate leaf[subject.OU] = "5V5ZAW53N4""#)
    }

    @Test func leavesAnAppWithoutATeamToItsDesignatedRequirement() {
        #expect(UpdateRequirement.text(bundleIdentifier: "dev.sarto.mac", teamIdentifier: nil) == nil)
        // Nothing that could close the string or the expression passes.
        for team in ["", "5V5ZAW53N", "5V5ZAW53N4X", "5v5zaw53n4", "5V5ZAW53\"4", "ABCDE FGHI"] {
            #expect(UpdateRequirement.text(bundleIdentifier: "dev.sarto.mac", teamIdentifier: team) == nil, "\(team)")
        }
        for bundle in ["", "dev.sarto.mac\" or anchor apple", "dev.sarto.mac or true", "dev/sarto"] {
            #expect(UpdateRequirement.text(bundleIdentifier: bundle, teamIdentifier: "5V5ZAW53N4") == nil, "\(bundle)")
        }
    }
}

@Suite struct AutoInstallTests {
    let fingerprint = String(repeating: "ab", count: 32)

    func situation(
        choice: UpdateChoice = .automatic,
        staged: Bool = true,
        restarts: Bool = false,
        outdated: Bool = false,
        away: Bool = true,
        quiet: TimeInterval? = nil
    ) -> AutoInstall.Situation {
        AutoInstall.Situation(
            choice: choice, staged: staged, stagedRestartsDaemon: restarts,
            daemonOutdated: outdated, userAway: away, quietFor: quiet
        )
    }

    @Test func installsAnAppOnlyUpdateOnceTheUserIsAway() {
        #expect(AutoInstall.decide(situation()) == .installApp)
        #expect(AutoInstall.decide(situation(away: false)) == .wait)
        // Tasks running in the daemon do not hold an update it survives.
        #expect(AutoInstall.decide(situation(quiet: nil)) == .installApp)
        for choice in [UpdateChoice.download, .restart, .notify, .off] {
            #expect(AutoInstall.decide(situation(choice: choice)) == .wait)
        }
    }

    @Test func waitsTenQuietMinutesForAnUpdateThatRestartsTheDaemon() {
        #expect(AutoInstall.decide(situation(restarts: true, quiet: nil)) == .wait)
        #expect(AutoInstall.decide(situation(restarts: true, quiet: 599)) == .wait)
        #expect(AutoInstall.decide(situation(restarts: true, quiet: 600)) == .installAppAndDaemon)
        #expect(AutoInstall.decide(situation(restarts: true, away: false, quiet: 3600)) == .wait)
    }

    @Test func restartsAnOutdatedDaemonOnTheSameTerms() {
        #expect(AutoInstall.decide(situation(staged: false, outdated: true, quiet: 600)) == .restartDaemon)
        #expect(AutoInstall.decide(situation(choice: .off, staged: false, outdated: true, quiet: 600)) == .restartDaemon)
        #expect(AutoInstall.decide(situation(staged: false, outdated: true, quiet: 30)) == .wait)
        #expect(AutoInstall.decide(situation(staged: false, outdated: false, quiet: 6000)) == .wait)
    }

    @Test func comparesRuntimesByFolder() {
        let folder = RuntimeFingerprint.folderName(fingerprint)
        #expect(folder == "abababababababab")
        #expect(!AutoInstall.restartsDaemon(updateRuntime: fingerprint, runningFolder: folder, daemonManaged: true))
        #expect(AutoInstall.restartsDaemon(updateRuntime: fingerprint, runningFolder: "0123456789abcdef", daemonManaged: true))
        #expect(AutoInstall.restartsDaemon(updateRuntime: nil, runningFolder: folder, daemonManaged: true))
        #expect(AutoInstall.restartsDaemon(updateRuntime: fingerprint, runningFolder: nil, daemonManaged: true))
        // A service the user installed, or no daemon at all, is not the app's to restart.
        #expect(!AutoInstall.restartsDaemon(updateRuntime: nil, runningFolder: nil, daemonManaged: false))
    }

    @Test func findsTheRuntimeOfARunningDaemon() {
        #expect(RuntimeFingerprint.folderName(inNodePath: "/Users/a/Library/Application Support/Sarto/runtimes/abababababababab/node/bin/node") == "abababababababab")
        #expect(RuntimeFingerprint.folderName(inNodePath: "/Applications/Sarto.app/Contents/Resources/runtime/node/bin/node") == nil)
        #expect(RuntimeFingerprint.folderName(inNodePath: "/x/runtimes/ABABABABABABABAB/node/bin/node") == nil)
        #expect(RuntimeFingerprint.folderName(inNodePath: "/x/runtimes/abab/node/bin/node") == nil)
        // Only a daemon an app started is the app's to restart, not one the user runs from an install.
        #expect(RuntimeFingerprint.startedByApp(nodePath: "/Users/a/Library/Application Support/Sarto/runtimes/abababababababab/node/bin/node"))
        #expect(RuntimeFingerprint.startedByApp(nodePath: "/Applications/Sarto.app/Contents/Resources/runtime/node/bin/node"))
        #expect(!RuntimeFingerprint.startedByApp(nodePath: "/Users/a/.local/share/sarto/versions/0.4.1/node/bin/node"))
        #expect(!RuntimeFingerprint.startedByApp(nodePath: "/opt/homebrew/bin/node"))
        #expect(RuntimeFingerprint.isValid(fingerprint))
        #expect(!RuntimeFingerprint.isValid(String(fingerprint.dropLast())))
    }
}

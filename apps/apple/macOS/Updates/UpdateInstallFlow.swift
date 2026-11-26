import AppKit
import PrismDesign
import SartoProtocol
import SartoUpdate

/// How Sarto installs a staged update, when the user restarts for it or when `AutoInstall` decides:
/// an update that keeps the daemon's runtime hands the running daemon to the app that opens next,
/// so its sessions carry on; one that replaces the runtime stops the daemon first.
@MainActor
enum UpdateInstallFlow {
    struct Parts {
        let delegate: PrismMacAppDelegate
        let daemon: LocalDaemonManager
        let state: SartoState
        let updater: SartoUpdater
    }

    /// Restart to update, as the user asked: it asks first only when the daemon's tasks would end.
    static func restart(_ parts: Parts) async {
        let restartsDaemon = parts.updater.stagedRestartsDaemon
        if restartsDaemon, parts.state.hasRunningTurns, !confirmRestart(parts) { return }
        await install(parts, restartsDaemon: restartsDaemon, background: false, hidden: false)
    }

    /// Headless restart triggered remotely from another paired computer.
    static func restartFromRemote(_ parts: Parts) async {
        let hidden = !parts.delegate.showsWindows
        await parts.state.reportLocalAppUpdateState(parts.updater.statusSnapshot(overrideState: "restarting"))
        await install(parts, restartsDaemon: parts.updater.stagedRestartsDaemon, background: true, hidden: hidden)
    }

    /// What `AutoInstall` decided, done without taking the user away from what they do.
    static func auto(_ action: AutoInstall.Action, _ parts: Parts) async {
        let hidden = !parts.delegate.showsWindows
        switch action {
        case .wait:
            parts.updater.autoInstallFinished()
        case .installApp:
            await install(parts, restartsDaemon: false, background: true, hidden: hidden)
        case .installAppAndDaemon:
            await install(parts, restartsDaemon: true, background: true, hidden: hidden)
        case .restartDaemon:
            guard parts.daemon.canRestartBoundDaemon(daemonEntryPath: SartoState.resolveDaemonBundlePath()) else {
                parts.updater.autoInstallFinished()
                return
            }
            await parts.daemon.stopForUpdate()
            await reconnect(parts)
            parts.updater.autoInstallFinished()
        }
    }

    private static func install(_ parts: Parts, restartsDaemon: Bool, background: Bool, hidden: Bool) async {
        parts.state.flushDraftsNow()
        if restartsDaemon {
            await parts.daemon.stopForUpdate()
        } else {
            await parts.daemon.releaseForAppRestart()
        }
        if await parts.updater.installForRestart() {
            parts.delegate.quitForUpdate {
                parts.updater.relaunchAfterExit(background: background, hidden: hidden)
            }
            return
        }
        // The update stays staged and its error shows; Sarto carries on with its daemon.
        parts.daemon.cancelReleaseForAppRestart()
        await reconnect(parts)
        parts.updater.autoInstallFinished()
    }

    private static func reconnect(_ parts: Parts) async {
        let onRemoteHost = parts.state.connectionMode.isRemote
        guard let hosts = try? await parts.daemon.connectOrStartHosts(
            daemonEntryPath: SartoState.resolveDaemonBundlePath(),
            relayOrigin: parts.state.relayOrigin
        ) else { return }
        // The daemon runs again for this Mac's devices; the window stays on the host it shows.
        if onRemoteHost {
            await hosts.agent.close()
            await hosts.terminal?.close()
            return
        }
        await parts.state.attachLiveSession(
            hosts.agent,
            terminal: hosts.terminal,
            mode: .localDaemon(socketPath: parts.daemon.controlSocketPath)
        )
    }

    private static func confirmRestart(_ parts: Parts) -> Bool {
        let l10n = parts.state.l10n
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = l10n.tr("settings.updates.restartConfirmTitle")
        alert.informativeText = l10n.tr("settings.updates.restartConfirmBody", parts.updater.state.version ?? "")
        alert.addButton(withTitle: l10n.tr("settings.updates.restartConfirm"))
        alert.addButton(withTitle: l10n.tr("thread.entry.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

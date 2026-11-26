import AppKit
import PrismDesign
import SartoProtocol
import SwiftUI

/// Presents an Apple-ID-style floating confirmation modal on macOS whenever another device
/// (such as iPhone or another Mac) requests end-to-end encrypted sync authorization from this Mac.
@MainActor
final class SyncApprovalPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var currentDeviceId: String?
    private var dismissedDeviceIds: Set<String> = []
    private var isSubmitting = false
    private var errorText: String?

    func sync(
        pendingApprovals: [SyncPendingApprovalInfo],
        state: SartoState,
        daemon: LocalDaemonManager
    ) {
        let activeIds = Set(pendingApprovals.map(\.deviceId))
        dismissedDeviceIds = dismissedDeviceIds.intersection(activeIds)

        if let currentId = currentDeviceId, !activeIds.contains(currentId) {
            closePanel()
        }

        guard let next = pendingApprovals.first(where: { !dismissedDeviceIds.contains($0.deviceId) }) else {
            return
        }

        if currentDeviceId == next.deviceId, panel != nil {
            updatePanelContent(request: next, state: state, daemon: daemon)
            return
        }

        currentDeviceId = next.deviceId
        isSubmitting = false
        errorText = nil
        showPanel(request: next, state: state, daemon: daemon)
    }

    private func showPanel(
        request: SyncPendingApprovalInfo,
        state: SartoState,
        daemon: LocalDaemonManager
    ) {
        let contentView = makeContentView(request: request, state: state, daemon: daemon)
        let hosting = NSHostingController(rootView: contentView)

        let p: NSPanel
        if let existing = panel {
            existing.contentViewController = hosting
            p = existing
        } else {
            let created = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 396, height: 340),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            created.titleVisibility = .hidden
            created.titlebarAppearsTransparent = true
            created.isMovableByWindowBackground = true
            created.isReleasedWhenClosed = false
            created.level = .floating
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            created.standardWindowButton(.miniaturizeButton)?.isHidden = true
            created.standardWindowButton(.zoomButton)?.isHidden = true
            created.delegate = self
            created.contentViewController = hosting
            panel = created
            p = created
        }

        let fitting = hosting.view.fittingSize
        let size = NSSize(width: max(396, fitting.width), height: max(310, fitting.height))
        p.setContentSize(size)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            let origin = NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.midY - size.height / 2 + 40
            )
            p.setFrameOrigin(origin)
        } else {
            p.center()
        }

        if NSApp.activationPolicy() != .regular {
            _ = NSApp.setActivationPolicy(.regular)
        }
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updatePanelContent(
        request: SyncPendingApprovalInfo,
        state: SartoState,
        daemon: LocalDaemonManager
    ) {
        guard let panel, let hosting = panel.contentViewController as? NSHostingController<SyncApprovalModalView> else {
            return
        }
        hosting.rootView = makeContentView(request: request, state: state, daemon: daemon)
    }

    private func makeContentView(
        request: SyncPendingApprovalInfo,
        state: SartoState,
        daemon: LocalDaemonManager
    ) -> SyncApprovalModalView {
        SyncApprovalModalView(
            request: request,
            tokens: state.tokens,
            l10n: state.l10n,
            colorScheme: state.palette.colorScheme,
            isSubmitting: isSubmitting,
            errorText: errorText,
            onApprove: { [weak self] in
                guard let self, !self.isSubmitting else { return }
                self.isSubmitting = true
                self.errorText = nil
                self.updatePanelContent(request: request, state: state, daemon: daemon)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        _ = try await daemon.approveSyncDevice(deviceId: request.deviceId)
                        self.closePanel()
                    } catch {
                        self.isSubmitting = false
                        self.errorText = error.localizedDescription
                        self.updatePanelContent(request: request, state: state, daemon: daemon)
                    }
                }
            },
            onReject: { [weak self] in
                guard let self, !self.isSubmitting else { return }
                self.isSubmitting = true
                self.errorText = nil
                self.updatePanelContent(request: request, state: state, daemon: daemon)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        _ = try await daemon.rejectSyncDevice(deviceId: request.deviceId)
                        self.closePanel()
                    } catch {
                        self.isSubmitting = false
                        self.errorText = error.localizedDescription
                        self.updatePanelContent(request: request, state: state, daemon: daemon)
                    }
                }
            }
        )
    }

    private func closePanel() {
        currentDeviceId = nil
        isSubmitting = false
        errorText = nil
        panel?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let id = currentDeviceId {
            dismissedDeviceIds.insert(id)
        }
        currentDeviceId = nil
        isSubmitting = false
        errorText = nil
    }
}

private struct SyncApprovalModalView: View {
    let request: SyncPendingApprovalInfo
    let tokens: PrismTokens
    let l10n: PrismL10n
    let colorScheme: ColorScheme
    let isSubmitting: Bool
    let errorText: String?
    let onApprove: () -> Void
    let onReject: () -> Void

    private var deviceSymbol: String {
        let lower = request.platform.lowercased()
        let nameLower = request.deviceName.lowercased()
        if lower.contains("ipad") || nameLower.contains("ipad") {
            return "ipad"
        }
        if lower.contains("ios") || nameLower.contains("iphone") {
            return "iphone"
        }
        return "laptopcomputer"
    }

    private var platformBadge: String {
        let lower = request.platform.lowercased()
        if lower == "ios" { return "iOS" }
        if lower == "darwin" { return "macOS" }
        return request.platform
    }

    var body: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(tokens.primarySoft)
                    .frame(width: 62, height: 62)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(tokens.primaryBorder, lineWidth: 1)
                    )
                    .overlay(
                        Image(systemName: deviceSymbol)
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(tokens.primary)
                    )

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(tokens.success)
                    .padding(3)
                    .background(Circle().fill(tokens.background))
                    .offset(x: 5, y: 5)
            }
            .padding(.top, 8)

            VStack(spacing: 6) {
                Text(l10n.tr("sync.approvalModal.title", request.deviceName))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                    .multilineTextAlignment(.center)

                Text(l10n.tr("sync.approvalModal.body"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(tokens.secondaryForeground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 6) {
                Text(l10n.tr("sync.approvalModal.codeLabel"))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
                    .kerning(1.2)

                Text(request.code)
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .kerning(2.0)
                    .foregroundStyle(tokens.primary)
                    .textSelection(.enabled)

                Text(platformBadge)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tokens.surface2))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous)
                    .fill(tokens.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous)
                    .strokeBorder(tokens.borderEtched, lineWidth: 1)
            )

            if let errorText {
                Text(errorText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(tokens.danger)
                    .multilineTextAlignment(.center)
            }

            if isSubmitting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(l10n.tr("sync.approvalModal.working"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(tokens.secondaryForeground)
                }
                .padding(.vertical, 6)
            } else {
                HStack(spacing: 10) {
                    Button(action: onReject) {
                        Text(l10n.tr("sync.approvalModal.denyBtn"))
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(tokens.foreground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                    .fill(tokens.surface2)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                    .strokeBorder(tokens.borderEtched, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)

                    Button(action: onApprove) {
                        Text(l10n.tr("sync.approvalModal.allowBtn"))
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(tokens.onPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                    .fill(tokens.primary)
                            )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(width: 396)
        .background(tokens.background)
        .preferredColorScheme(colorScheme)
    }
}

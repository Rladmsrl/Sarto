import SartoProtocol
import PrismDesign
import SwiftUI

// MARK: - 1. In-Flight Message Queue Stack (Item 2 — mirrors src/renderer/src/features/session/queue-stack.tsx)

public struct QueueStackView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let items: [QueuedPrompt]
    public let isPaused: Bool
    public let onSendNow: (String) -> Void
    public let onEdit: (QueuedPrompt) -> Void
    public let onRemove: (QueuedPrompt) -> Void
    public let onResume: () -> Void
    public let onOpenSession: ((String) -> Void)?
    public let resolveSessionTitle: ((String) -> String?)?

    public init(
        items: [QueuedPrompt],
        isPaused: Bool,
        onSendNow: @escaping (String) -> Void,
        onEdit: @escaping (QueuedPrompt) -> Void,
        onRemove: @escaping (QueuedPrompt) -> Void,
        onResume: @escaping () -> Void,
        onOpenSession: ((String) -> Void)? = nil,
        resolveSessionTitle: ((String) -> String?)? = nil
    ) {
        self.items = items
        self.isPaused = isPaused
        self.onSendNow = onSendNow
        self.onEdit = onEdit
        self.onRemove = onRemove
        self.onResume = onResume
        self.onOpenSession = onOpenSession
        self.resolveSessionTitle = resolveSessionTitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: isPaused ? "pause.circle.fill" : "text.line.first.and.arrowtriangle.forward")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isPaused ? tokens.warning : tokens.prismCobalt)

                Text(isPaused ? l10n.tr("queue.pausedBanner") : l10n.tr("queue.header", items.count))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isPaused ? tokens.warning : tokens.secondaryForeground)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if isPaused {
                    Button {
                        onResume()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8.5))
                            Text(l10n.tr("queue.resume"))
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(tokens.inverseInk)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(tokens.warning))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isPaused ? tokens.warningSoft.opacity(0.65) : tokens.codeHeaderBackground)

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    QueueItemRowView(
                        index: idx + 1,
                        item: item,
                        resolvedTitle: item.from.flatMap { resolvedSessionTitle(for: $0) },
                        onSendNow: { onSendNow(item.id) },
                        onEdit: { onEdit(item) },
                        onRemove: { onRemove(item) },
                        onOpenSession: onOpenSession
                    )

                    if idx + 1 < items.count {
                        Rectangle().fill(tokens.borderEtched.opacity(0.55)).frame(height: 1)
                    }
                }
            }
            .background(tokens.surface1.opacity(0.82))
        }
        .clipShape(RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous)
                .strokeBorder(isPaused ? tokens.warning.opacity(0.4) : tokens.borderEtched, lineWidth: 1)
        )
    }

    private func resolvedSessionTitle(for from: FromSession) -> String {
        if let live = resolveSessionTitle?(from.sessionId)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !live.isEmpty {
            return live
        }
        let fallback = from.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fallback.isEmpty {
            return fallback
        }
        return String(from.sessionId.prefix(8))
    }
}

private struct QueueItemRowView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @State private var isRowHovered = false

    let index: Int
    let item: QueuedPrompt
    let resolvedTitle: String?
    let onSendNow: () -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void
    let onOpenSession: ((String) -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(tokens.placeholder)
                .frame(width: 14)

            if let from = item.from, let ended = from.ended {
                sessionReportContent(from: from, ended: ended)
            } else if let from = item.from {
                crossSessionContent(from: from)
            } else {
                standardContent
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                queueActionButton(
                    icon: "arrow.up.circle",
                    label: l10n.tr("queue.sendNow"),
                    tint: tokens.prismCobalt,
                    action: onSendNow
                )

                if item.isUserEditable {
                    queueActionButton(
                        icon: "pencil",
                        label: l10n.tr("queue.edit"),
                        tint: tokens.secondaryForeground,
                        action: onEdit
                    )
                }

                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(tokens.hoverWash.opacity(0.7)))
                }
                .buttonStyle(.plain)
                .help(l10n.tr("queue.remove"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isRowHovered ? tokens.hoverWash.opacity(0.35) : Color.clear)
        .onHover { isRowHovered = $0 }
    }

    @ViewBuilder
    private func sessionReportContent(from: FromSession, ended: FromSessionEnded) -> some View {
        let style = SessionReportStyle.resolve(stopReason: ended.stopReason, tokens: tokens)
        let title = resolvedTitle ?? (from.title.isEmpty ? String(from.sessionId.prefix(8)) : from.title)
        let summary = l10n.tr(style.queueSummaryKey, title)

        let label = HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: style.icon)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(ended.agent)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(style.tint)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 2)
            .background(Capsule().fill(style.softFill))
            .overlay(Capsule().strokeBorder(style.tint.opacity(0.24), lineWidth: 0.75))
            .fixedSize(horizontal: true, vertical: false)

            Text(summary)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tokens.foreground.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            if onOpenSession != nil {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isRowHovered ? tokens.prismCobalt : tokens.placeholder)
            }
        }

        if let onOpenSession {
            Button {
                onOpenSession(from.sessionId)
            } label: {
                label.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(l10n.tr("queue.sessionReport.tooltip", title))
        } else {
            label.help(l10n.tr("queue.sessionReport.tooltip", title))
        }
    }

    @ViewBuilder
    private func crossSessionContent(from: FromSession) -> some View {
        let title = resolvedTitle ?? (from.title.isEmpty ? String(from.sessionId.prefix(8)) : from.title)
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "envelope.open")
                    .font(.system(size: 9.5, weight: .medium))
                Text(l10n.tr("queue.fromSessionBadge", title))
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(tokens.prismCobalt)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 2)
            .background(Capsule().fill(tokens.primarySoft))
            .overlay(Capsule().strokeBorder(tokens.prismCobalt.opacity(0.22), lineWidth: 0.75))

            Text(queuePreviewText(item))
                .font(.system(size: 12))
                .foregroundStyle(tokens.foreground.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var standardContent: some View {
        HStack(spacing: 6) {
            if item.sarto == true {
                Text(l10n.tr("queue.sartoBadge"))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tokens.prismIris)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tokens.hoverWash))
                    .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 0.75))
            } else if let device = item.device,
                      !device.name.isEmpty,
                      device.id != LocalBrowserPortIdentity.stableDeviceID() {
                HStack(spacing: 3.5) {
                    Image(systemName: "iphone")
                        .font(.system(size: 9.5, weight: .medium))
                    Text(device.name)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(tokens.secondaryForeground)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(tokens.hoverWash))
                .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 0.75))
            } else if let comments = item.comments, comments.count > 0 {
                Text(l10n.tr("queue.commentsBadge", comments.count))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tokens.prismCobalt)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tokens.primarySoft))
            }

            Text(queuePreviewText(item))
                .font(.system(size: 12))
                .foregroundStyle(tokens.foreground.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func queuePreviewText(_ item: QueuedPrompt) -> String {
        if let comments = item.comments {
            let summary = comments.text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty {
                return summary
            }
        }
        let single = item.textBody
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let attCount = item.attachmentCount
        if single.isEmpty && attCount > 0 {
            return String(l10n.tr("queue.attachmentsSuffix", attCount).dropFirst(3))
        }
        if attCount > 0 {
            return single + l10n.tr("queue.attachmentsSuffix", attCount)
        }
        return single
    }

    private func queueActionButton(
        icon: String,
        label: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3.5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tokens.hoverWash))
            .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Shared visual mapping for child-session turn-ended reports in both the queue and the thread.
enum SessionReportStyle {
    struct Spec {
        let icon: String
        let tint: Color
        let softFill: Color
        let queueSummaryKey: String
        let threadStatusKey: String
    }

    static func resolve(stopReason: String?, tokens: PrismTokens) -> Spec {
        switch stopReason {
        case "end_turn":
            return Spec(
                icon: "checkmark.circle.fill",
                tint: tokens.success,
                softFill: tokens.successSoft,
                queueSummaryKey: "queue.sessionReport.ended",
                threadStatusKey: "thread.sessionReport.ended"
            )
        case "cancelled":
            return Spec(
                icon: "stop.circle.fill",
                tint: tokens.mutedForeground,
                softFill: tokens.hoverWash,
                queueSummaryKey: "queue.sessionReport.stopped",
                threadStatusKey: "thread.sessionReport.stopped"
            )
        case "refusal":
            return Spec(
                icon: "exclamationmark.triangle.fill",
                tint: tokens.danger,
                softFill: tokens.dangerSoft,
                queueSummaryKey: "queue.sessionReport.refused",
                threadStatusKey: "thread.sessionReport.refused"
            )
        case nil:
            return Spec(
                icon: "exclamationmark.triangle.fill",
                tint: tokens.danger,
                softFill: tokens.dangerSoft,
                queueSummaryKey: "queue.sessionReport.failed",
                threadStatusKey: "thread.sessionReport.failed"
            )
        default:
            return Spec(
                icon: "exclamationmark.circle.fill",
                tint: tokens.warning,
                softFill: tokens.warningSoft,
                queueSummaryKey: "queue.sessionReport.limit",
                threadStatusKey: "thread.sessionReport.limit"
            )
        }
    }
}

// MARK: - 2. Mid-Session Agent Switch Strip, Cache Notice & History Header

public struct AgentSwitchStripView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let targetAgentName: String
    public let settingsSummary: String?
    @Binding public var summarize: Bool
    public let onConfigure: (() -> Void)?
    public let onCancel: () -> Void

    public init(
        targetAgentName: String,
        settingsSummary: String? = nil,
        summarize: Binding<Bool>,
        onConfigure: (() -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.targetAgentName = targetAgentName
        self.settingsSummary = settingsSummary
        self._summarize = summarize
        self.onConfigure = onConfigure
        self.onCancel = onCancel
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tokens.prismIris)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(l10n.tr("composer.switchStrip", targetAgentName))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(1)

                if let settingsSummary, !settingsSummary.isEmpty {
                    Button {
                        onConfigure?()
                    } label: {
                        HStack(spacing: 4) {
                            Text(settingsSummary)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(tokens.mutedForeground)
                                .lineLimit(1)
                            if onConfigure != nil {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 9))
                                    .foregroundStyle(tokens.prismIris.opacity(0.85))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(onConfigure == nil)
                }
            }

            Spacer(minLength: 6)

            Button {
                summarize.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: summarize ? "checkmark.square.fill" : "square")
                        .font(.system(size: 11))
                        .foregroundStyle(summarize ? tokens.prismIris : tokens.mutedForeground)
                    Text(l10n.tr("composer.switchSummarize"))
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.secondaryForeground)
                }
            }
            .buttonStyle(.plain)

            Button {
                onCancel()
            } label: {
                Text(l10n.tr("composer.switchCancel"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(tokens.mutedForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(tokens.hoverWash))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .prismSurface(elevation: .raised, cornerRadius: tokens.rSM)
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(tokens.prismIris.opacity(0.45), lineWidth: 1)
        )
    }
}

public struct ComposerCacheNoticeView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let usedTokens: Double
    public let onDismiss: () -> Void

    public init(usedTokens: Double, onDismiss: @escaping () -> Void) {
        self.usedTokens = usedTokens
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "timer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tokens.warning)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(l10n.tr("composer.cacheExpiredTitle"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                Text(l10n.tr("composer.cacheExpiredBody", PrismTelemetryFormat.compactTokens(usedTokens)))
                    .font(.system(size: 10.5))
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(2)
            }

            Spacer(minLength: 6)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(tokens.hoverWash))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7.5)
        .prismSurface(elevation: .raised, cornerRadius: tokens.rSM)
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(tokens.warning.opacity(0.42), lineWidth: 1)
        )
    }
}

public struct ComposerHistoryHeaderView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let index: Int
    public let count: Int
    public let onRestoreDraft: () -> Void

    public init(index: Int, count: Int, onRestoreDraft: @escaping () -> Void) {
        self.index = index
        self.count = count
        self.onRestoreDraft = onRestoreDraft
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tokens.prismCobalt)
            Text(l10n.tr("composer.historyIndicator", index, count))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(tokens.secondaryForeground)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(action: onRestoreDraft) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(tokens.hoverWash))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                .fill(tokens.primarySoft.opacity(0.55))
        )
    }
}

// MARK: - 2b. Edit From a Sent Message: Rewound Header, Edit Button & Confirmation

/// The row on the composer's upper edge after an edit from a message: how many turns went, and Put back,
/// which returns them and the draft the composer held. It stays until the next message goes.
public struct ComposerRewoundHeaderView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let turns: Int
    public let isBusy: Bool
    public let onPutBack: () -> Void

    public init(turns: Int, isBusy: Bool, onPutBack: @escaping () -> Void) {
        self.turns = turns
        self.isBusy = isBusy
        self.onPutBack = onPutBack
    }

    public var body: some View {
        HStack(spacing: 6) {
            Group {
                if isBusy {
                    PrismTurnDotsView(phase: .working, size: 10.5)
                } else {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(tokens.prismIris)
                }
            }
            .frame(width: 14)
            Text(turns == 1 ? l10n.tr("composer.rewound.turnsOne") : l10n.tr("composer.rewound.turns", turns))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(tokens.secondaryForeground)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button(action: onPutBack) {
                Text(l10n.tr("composer.rewound.putBack"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(tokens.prismIris)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(tokens.prismIris.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(tokens.prismIris.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .opacity(isBusy ? 0.5 : 1)
            .help(l10n.tr("composer.rewound.putBackHelp"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                .fill(tokens.prismIris.opacity(0.08))
        )
    }
}

/// What the confirmation of an edit from a message says: the facts of the thread, and the prompt cache
/// as it was when Edit was clicked.
public struct RewindConfirmationModel: Equatable {
    public let facts: RewindFacts
    public let cache: PromptCacheInfo?
    public let rewindFiles: Bool
    public let nowMs: Double

    public init(
        facts: RewindFacts,
        cache: PromptCacheInfo?,
        rewindFiles: Bool = false,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) {
        self.facts = facts
        self.cache = cache
        self.rewindFiles = rewindFiles
        self.nowMs = nowMs
    }
}

/// Edit from here on a sent message: goes back at once when nothing needs saying, and otherwise asks
/// in a popover what goes and what stops.
public struct UserMessageEditButton: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismMotionTier) private var motionTier

    public let prepare: () -> RewindConfirmationModel?
    public let onEdit: () -> Void
    public let onAskingChange: (Bool) -> Void

    @State private var asking: RewindConfirmationModel?

    public init(
        prepare: @escaping () -> RewindConfirmationModel?,
        onEdit: @escaping () -> Void,
        onAskingChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.prepare = prepare
        self.onEdit = onEdit
        self.onAskingChange = onAskingChange
    }

    public var body: some View {
        Button {
            guard let model = prepare() else { return }
            if model.facts.needsConfirmation || model.rewindFiles {
                asking = model
            } else {
                onEdit()
            }
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(asking != nil ? tokens.prismIris : tokens.placeholder)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(l10n.tr("thread.editFrom.action"))
        .accessibilityLabel(l10n.tr("thread.editFrom.action"))
        .popover(
            isPresented: Binding(
                get: { asking != nil },
                set: { if !$0 { asking = nil } }
            ),
            arrowEdge: .bottom
        ) {
            if let model = asking {
                RewindConfirmationView(
                    model: model,
                    onCancel: { asking = nil },
                    onEdit: {
                        asking = nil
                        onEdit()
                    }
                )
                .focusEffectDisabled()
                .presentationBackground(tokens.popoverBackground)
                .environment(\.prismTokens, tokens)
                .environment(\.prismL10n, l10n)
                .environment(\.prismMotionTier, motionTier)
                .preferredColorScheme(tokens.palette.colorScheme)
            }
        }
        .onChange(of: asking != nil) { _, open in
            onAskingChange(open)
        }
    }
}

/// Edit from here's confirmation: what goes, and only the rows that apply of what stops.
public struct RewindConfirmationView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let model: RewindConfirmationModel
    public let onCancel: () -> Void
    public let onEdit: () -> Void

    public init(model: RewindConfirmationModel, onCancel: @escaping () -> Void, onEdit: @escaping () -> Void) {
        self.model = model
        self.onCancel = onCancel
        self.onEdit = onEdit
    }

    private struct FactRow: Identifiable {
        let id: String
        let icon: String
        let text: String
        let warn: Bool
    }

    private var factRows: [FactRow] {
        let facts = model.facts
        var rows: [FactRow] = []
        if facts.running {
            rows.append(FactRow(id: "turn", icon: "stop.circle", text: l10n.tr("thread.editFrom.stopsTurn"), warn: false))
        }
        if facts.tasks > 0 {
            let text = facts.tasks == 1
                ? l10n.tr("thread.editFrom.stopsTasksOne")
                : l10n.tr("thread.editFrom.stopsTasks", facts.tasks)
            rows.append(FactRow(id: "tasks", icon: "terminal", text: text, warn: false))
        }
        if facts.files > 0 {
            let text = facts.files == 1
                ? l10n.tr("thread.editFrom.filesOne")
                : l10n.tr("thread.editFrom.files", facts.files)
            rows.append(FactRow(id: "files", icon: "doc", text: text, warn: false))
        }
        if model.rewindFiles {
            rows.append(FactRow(
                id: "rewindFiles",
                icon: "arrow.uturn.backward.circle",
                text: l10n.tr("thread.rewind.filesNote"),
                warn: true
            ))
        }
        if let cache = model.cache, let expiresAt = cache.expiresAt {
            if model.nowMs < expiresAt {
                let left = Duration.seconds(max(1, (expiresAt - model.nowMs) / 1000))
                    .formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated, maximumUnitCount: 1)
                        .locale(l10n.language.resolvedLocale))
                rows.append(FactRow(id: "cache", icon: "timer", text: l10n.tr("thread.editFrom.cacheKept", left), warn: false))
            } else if let kept = model.facts.kept, kept > 0 {
                let sent = PrismTelemetryFormat.compactTokens(kept)
                rows.append(FactRow(id: "cache", icon: "timer", text: l10n.tr("thread.editFrom.cacheExpired", sent), warn: true))
            } else {
                rows.append(FactRow(id: "cache", icon: "timer", text: l10n.tr("thread.editFrom.cacheExpiredOnly"), warn: true))
            }
        }
        return rows
    }

    public var body: some View {
        let turns = model.facts.turns
        let rows = factRows
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.tr("thread.editFrom.title"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tokens.foreground)

            Text(turns == 1 ? l10n.tr("thread.editFrom.bodyOne") : l10n.tr("thread.editFrom.body", turns))
                .font(.system(size: 11.5))
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)

            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: row.icon)
                                .font(.system(size: 10.5, weight: .medium))
                                .frame(width: 14)
                            Text(row.text)
                                .font(.system(size: 11))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(row.warn ? tokens.warning : tokens.secondaryForeground)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous).fill(tokens.surface2.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))
            }

            HStack(spacing: 8) {
                Spacer()
                Button(action: onCancel) {
                    Text(l10n.tr("thread.editFrom.cancel"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5.5)
                        .background(Capsule().fill(tokens.hoverWash))
                        .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button(action: onEdit) {
                    Text(l10n.tr("thread.editFrom.confirm"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tokens.inverseInk)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5.5)
                        .background(Capsule().fill(tokens.inverseFill))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}

/// Which messages of a thread can be edited from, worked out once per change of the thread rather than
/// once per bubble.
@MainActor
final class EditableMessageMemo {
    static let shared = EditableMessageMemo()

    private struct Key: Equatable {
        let sessionId: String
        let seq: Int
        let count: Int
        let first: String?
        let last: String?
    }

    private var key: Key?
    private var ids: Set<String> = []

    func ids(for replica: ThreadReplica) -> Set<String> {
        let next = Key(
            sessionId: replica.session.id,
            seq: replica.seq,
            count: replica.order.count,
            first: replica.order.first,
            last: replica.order.last
        )
        if next != key {
            key = next
            ids = replica.editableEntryIDs
        }
        return ids
    }
}

// MARK: - 3. Composer @ Mention & / Slash Autocomplete (Item 6)

public enum ComposerCompletionKind: Sendable, Equatable {
    case file(path: String)
    case slash(name: String, description: String, hint: String?)
}

public struct ComposerCompletionItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: ComposerCompletionKind

    public init(id: String, kind: ComposerCompletionKind) {
        self.id = id
        self.kind = kind
    }
}

public struct ComposerAutocompleteView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let title: String
    public let items: [ComposerCompletionItem]
    public let selectedIndex: Int
    public let onSelect: (ComposerCompletionItem) -> Void

    public init(
        title: String,
        items: [ComposerCompletionItem],
        selectedIndex: Int,
        onSelect: @escaping (ComposerCompletionItem) -> Void
    ) {
        self.title = title
        self.items = items
        self.selectedIndex = selectedIndex
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tokens.placeholder)
                Spacer()
                Text("↑↓ · ↵")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(tokens.placeholder)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(tokens.codeHeaderBackground)

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                            let isSelected = idx == selectedIndex
                            Button {
                                onSelect(item)
                            } label: {
                                HStack(spacing: 8) {
                                    switch item.kind {
                                    case .file(let path):
                                        let fileName = (path as NSString).lastPathComponent
                                        Image(systemName: PrismImageDecoder.symbolName(for: fileName, mimeType: nil, type: "file"))
                                            .font(.system(size: 11))
                                            .foregroundStyle(tokens.prismCobalt)
                                            .frame(width: 16)
                                        Text(path)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(tokens.foreground)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()

                                    case .slash(let name, let desc, let hint):
                                        Text("/\(name)")
                                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(tokens.prismCobalt)
                                        if let hint, !hint.isEmpty {
                                            Text(hint)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(tokens.placeholder)
                                        }
                                        Text(desc)
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(tokens.mutedForeground)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Spacer()
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                                        .fill(isSelected ? tokens.activeWash : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                        }
                    }
                    .padding(5)
                }
                .frame(maxHeight: 220)
                .background(tokens.surface1)
                .onChange(of: selectedIndex) { _, index in
                    // Keyboard selection moves past the visible rows; keep it in view without animating.
                    guard items.indices.contains(index) else { return }
                    proxy.scrollTo(items[index].id)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous)
                .strokeBorder(tokens.borderStrong, lineWidth: 1)
        )
    }
}

// MARK: - 4. Floating In-Session Find Bar (Item 7 — Cmd+F)

public struct SessionFindBarView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    @Binding public var query: String
    public let matchCount: Int
    public let currentIndex: Int
    public let onPrev: () -> Void
    public let onNext: () -> Void
    public let onClose: () -> Void

    @FocusState private var fieldFocused: Bool

    public init(
        query: Binding<String>,
        matchCount: Int,
        currentIndex: Int,
        onPrev: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self._query = query
        self.matchCount = matchCount
        self.currentIndex = currentIndex
        self.onPrev = onPrev
        self.onNext = onNext
        self.onClose = onClose
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tokens.mutedForeground)

            TextField(l10n.tr("find.placeholder"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(tokens.foreground)
                .focused($fieldFocused)
                .onSubmit { onNext() }
                .frame(minWidth: 160)

            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(matchCount > 0 ? l10n.tr("find.count", currentIndex + 1, matchCount) : l10n.tr("find.noMatches"))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(matchCount > 0 ? tokens.secondaryForeground : tokens.warning)
                    .padding(.horizontal, 6)
            }

            HStack(spacing: 2) {
                Button(action: onPrev) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(matchCount > 0 ? tokens.secondaryForeground : tokens.placeholder)
                        .frame(width: 24, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(tokens.hoverWash.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .disabled(matchCount == 0)

                Button(action: onNext) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(matchCount > 0 ? tokens.secondaryForeground : tokens.placeholder)
                        .frame(width: 24, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(tokens.hoverWash.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .disabled(matchCount == 0)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(tokens.hoverWash.opacity(0.7)))
            }
            .buttonStyle(.plain)
            .help(l10n.tr("find.close"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .prismSurface(elevation: .floating, cornerRadius: tokens.rMD)
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous)
                .strokeBorder(tokens.borderStrong, lineWidth: 1)
        )
        .onAppear {
            fieldFocused = true
        }
    }
}

// MARK: - 5. Message Outline Popover (Item 7)

public struct SessionOutlinePopoverView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let entries: [OutlineEntryInfo]
    public let onSelect: (OutlineEntryInfo) -> Void

    public init(entries: [OutlineEntryInfo], onSelect: @escaping (OutlineEntryInfo) -> Void) {
        self.entries = entries
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tokens.prismCobalt)
                Text(l10n.tr("outline.title"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                Spacer()
                Text("\(entries.count)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(tokens.placeholder)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(tokens.codeHeaderBackground)

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            if entries.isEmpty {
                Text(l10n.tr("outline.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(tokens.mutedForeground)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { idx, item in
                            Button {
                                onSelect(item)
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(idx + 1)")
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(tokens.placeholder)
                                        .frame(width: 18, alignment: .trailing)
                                        .padding(.top, 2)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title ?? item.text)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(tokens.foreground)
                                            .lineLimit(2)
                                        if item.title != nil, !item.text.isEmpty, item.title != item.text {
                                            Text(item.text)
                                                .font(.system(size: 10.5))
                                                .foregroundStyle(tokens.mutedForeground)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(5)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 300)
        .background(tokens.surface1)
        .clipShape(RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous)
                .strokeBorder(tokens.borderStrong, lineWidth: 1)
        )
    }
}

// MARK: - 6. Plan Approval Card (Item 4 — mirrors src/renderer/src/features/session/entries/plan-card.tsx)

public struct PlanApprovalCardView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let tool: ToolEntryData
    public let permission: PendingPermission
    public let plan: PendingPlanApproval
    public let onRespond: (String, String?, String?, [QuestionAnswer]?) -> Void

    @State private var showFullPlan = false
    @State private var showDiff = false
    @State private var feedbackText = ""
    @State private var planPreview = PlanPreview(source: "")
    /// The request this card already answered; its buttons stay disabled until the host clears it.
    @State private var answeredRequestID: String?

    public init(
        tool: ToolEntryData,
        permission: PendingPermission,
        plan: PendingPlanApproval,
        onRespond: @escaping (String, String?, String?, [QuestionAnswer]?) -> Void
    ) {
        self.tool = tool
        self.permission = permission
        self.plan = plan
        self.onRespond = onRespond
    }

    private struct PlanPreview {
        let source: String
        let isLong: Bool
        let preview: String

        init(source: String) {
            self.source = source
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            isLong = lines.count > 18
            preview = isLong ? lines.prefix(16).joined(separator: "\n") + "\n…" : source
        }
    }

    public var body: some View {
        let hasPrev = plan.previous != nil && plan.previous != plan.markdown
        let layout = planPreview.source == plan.markdown ? planPreview : PlanPreview(source: plan.markdown)
        let isLong = layout.isLong
        let inFlight = answeredRequestID == permission.requestId
        let rejectOption = permission.options.first(where: { $0.note == true })
            ?? permission.options.first(where: { $0.kind.contains("reject") })
        let allowOptions = permission.options.filter { $0.id != rejectOption?.id }

        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "map")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(tokens.warning)

                Text(tool.planVersion.map { l10n.tr("thread.plan.version", $0) } ?? l10n.tr("thread.plan.title"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(tokens.foreground)

                Spacer()

                if hasPrev {
                    Button {
                        showDiff.toggle()
                    } label: {
                        Text(showDiff ? l10n.tr("thread.plan.hideDiff") : l10n.tr("thread.plan.showDiff"))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(tokens.prismCobalt)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(tokens.primarySoft))
                    }
                    .buttonStyle(.plain)
                }

                Text(l10n.tr("thread.awaitingApproval"))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tokens.warning)
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.warningSoft))
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(tokens.codeHeaderBackground)

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            // Plan body or Diff vs previous
            VStack(alignment: .leading, spacing: 10) {
                if showDiff, let prev = plan.previous {
                    let computed = ThreadDiffCache.shared.compute(path: "plan.md", oldText: prev, newText: plan.markdown)
                    let diffLines = computed.hunks.flatMap(\.lines)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(diffLines) { line in
                                HStack(spacing: 8) {
                                    Text(line.kind == .added ? "+" : (line.kind == .deleted ? "-" : " "))
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(line.kind == .added ? tokens.success : (line.kind == .deleted ? tokens.danger : tokens.placeholder))
                                        .frame(width: 10)
                                    Text(line.text)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(tokens.foreground.opacity(0.9))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 1.5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(line.kind == .added ? tokens.successSoft : (line.kind == .deleted ? tokens.dangerSoft : Color.clear))
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                    .background(tokens.surface1)
                    .clipShape(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous))
                } else {
                    let displayText = (isLong && !showFullPlan) ? layout.preview : plan.markdown
                    ScrollView {
                        OverlayMarkdownView(markdown: displayText, fontSize: 13, lineSpacing: 4.5, textOpacity: 0.93)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: showFullPlan ? 420 : 260)

                    if isLong {
                        Button {
                            showFullPlan.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showFullPlan ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9.5, weight: .semibold))
                                Text(showFullPlan ? l10n.tr("thread.plan.showLess") : l10n.tr("thread.plan.showMore"))
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(tokens.mutedForeground)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Optional feedback note for requesting changes (only when reject option supports a note)
                if rejectOption?.note == true {
                    TextField(l10n.tr("thread.plan.feedbackPlaceholder"), text: $feedbackText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(tokens.foreground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous).fill(tokens.surface1))
                        .overlay(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))
                }

                // Actions
                HStack(spacing: 8) {
                    if let rej = rejectOption {
                        Button {
                            let trimmed = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
                            let noteToSend = (rej.note == true && !trimmed.isEmpty) ? trimmed : nil
                            respondOnce(optionID: rej.id, note: noteToSend)
                        } label: {
                            Text(rej.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(tokens.danger)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(tokens.dangerSoft))
                                .overlay(Capsule().strokeBorder(tokens.danger.opacity(0.32), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    ForEach(allowOptions) { opt in
                        let isPrimary = opt.preferred == true || opt.id == allowOptions.first?.id
                        Button {
                            respondOnce(optionID: opt.id, note: nil)
                        } label: {
                            Text(opt.name)
                                .font(.system(size: 12, weight: isPrimary ? .semibold : .medium))
                                .foregroundStyle(
                                    isPrimary
                                        ? tokens.inverseInk
                                        : tokens.secondaryForeground
                                )
                                .padding(.horizontal, 13)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(
                                        isPrimary
                                            ? tokens.inverseFill
                                            : tokens.hoverWash
                                    )
                                )
                                .overlay(
                                    Capsule().strokeBorder(isPrimary ? Color.clear : tokens.border, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .disabled(inFlight)
                .opacity(inFlight ? 0.55 : 1)
            }
            .padding(12)
            .background(tokens.codeBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(tokens.warning.opacity(0.48), lineWidth: 1)
        )
        .prismSemanticAura(.waiting, cornerRadius: tokens.rSM)
        .onChange(of: plan.markdown, initial: true) { _, markdown in
            if planPreview.source != markdown {
                planPreview = PlanPreview(source: markdown)
            }
        }
        .task(id: answeredRequestID) {
            await releaseAnswerLockAfterTimeout(answeredRequestID) { answeredRequestID = nil }
        }
    }

    private func respondOnce(optionID: String, note: String?) {
        guard answeredRequestID != permission.requestId else { return }
        answeredRequestID = permission.requestId
        onRespond(permission.requestId, optionID, note, nil)
    }
}

/// How long an answered card waits for the host to clear its request before accepting another
/// answer, so a request that failed to send does not stay locked.
private let answerLockTimeout: Duration = .seconds(10)

@MainActor
private func releaseAnswerLockAfterTimeout(_ lockedID: String?, release: () -> Void) async {
    guard lockedID != nil else { return }
    do {
        try await Task.sleep(for: answerLockTimeout)
    } catch {
        return
    }
    release()
}

/// Agent markdown laid out as headings, paragraphs, lists, quotes and code, which a single
/// `Text(AttributedString(markdown:))` collapses into one block. Parses once per text change.
private struct OverlayMarkdownView: View {
    @Environment(\.prismTokens) private var tokens

    let markdown: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let textOpacity: Double

    @State private var parsed: (source: String, blocks: [MarkdownBlock]) = ("", [])

    var body: some View {
        let blocks = parsed.source == markdown ? parsed.blocks : MarkdownBlockParser.parse(markdown)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .onChange(of: markdown, initial: true) { _, text in
            if parsed.source != text {
                parsed = (text, MarkdownBlockParser.parse(text))
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(_, let level, let text):
            inlineText(text)
                .font(.system(size: fontSize + (level == 1 ? 4 : (level == 2 ? 2.5 : 1)), weight: .semibold))
                .foregroundStyle(tokens.foreground)
                .padding(.top, level <= 2 ? 4 : 2)
                .textSelection(.enabled)

        case .paragraph(_, let text):
            bodyText(text)

        case .bulletList(_, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle()
                            .fill(tokens.mutedForeground.opacity(0.7))
                            .frame(width: 4, height: 4)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + fontSize * 0.3 }
                        bodyText(item)
                    }
                }
            }
            .padding(.leading, 3)

        case .orderedList(_, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(item.number).")
                            .font(.system(size: fontSize - 0.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                            .frame(minWidth: 18, alignment: .trailing)
                        bodyText(item.text)
                    }
                }
            }

        case .blockquote(_, let text):
            inlineText(text)
                .font(.system(size: fontSize - 0.5))
                .lineSpacing(lineSpacing)
                .foregroundStyle(tokens.secondaryForeground)
                .textSelection(.enabled)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(tokens.prismCobalt.opacity(0.45))
                        .frame(width: 2)
                }

        case .alert(_, let kind, let text):
            GitHubAlertCardView(kind: kind, text: text)

        case .table(_, let headers, let rows):
            tableView(headers: headers, rows: rows)

        case .codeBlock(_, _, _, let code, _):
            codeText(code)

        case .mermaid(_, let source):
            OfflineDiagramCardView(kind: .mermaid(source))

        case .svg(_, let source):
            OfflineDiagramCardView(kind: .svg(source))

        case .mathBlock(_, let latex):
            OfflineDiagramCardView(kind: .math(latex))

        case .image(_, let alt, let url):
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.mutedForeground)
                Text(alt.isEmpty ? url : alt)
                    .font(.system(size: fontSize - 1))
                    .foregroundStyle(tokens.secondaryForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

        case .divider:
            Rectangle()
                .fill(tokens.borderEtched)
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func bodyText(_ raw: String) -> some View {
        inlineText(raw)
            .font(.system(size: fontSize))
            .lineSpacing(lineSpacing)
            .foregroundStyle(tokens.foreground.opacity(textOpacity))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func codeText(_ code: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(size: fontSize - 1.5, design: .monospaced))
                .foregroundStyle(tokens.foreground.opacity(0.9))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.surface1)
        .clipShape(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                .strokeBorder(tokens.borderEtched, lineWidth: 1)
        )
    }

    private func tableView(headers: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        inlineText(header)
                            .font(.system(size: fontSize - 1, weight: .semibold))
                            .foregroundStyle(tokens.foreground)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                    }
                }
                .background(tokens.codeHeaderBackground)

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Rectangle()
                        .fill(tokens.borderEtched)
                        .frame(height: 1)
                        .gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            inlineText(cell)
                                .font(.system(size: fontSize - 1))
                                .foregroundStyle(tokens.foreground.opacity(textOpacity))
                                .textSelection(.enabled)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                .strokeBorder(tokens.borderEtched, lineWidth: 1)
        )
    }

    private func inlineText(_ raw: String) -> Text {
        if let attr = InlineMarkdownEngine.render(raw, isDark: tokens.palette.isDark) {
            return Text(attr)
        }
        return Text(raw)
    }
}

// MARK: - 8. Multi-Question / Multi-Select / Custom-Text / Secret Question Card (Item 4)

public struct MultiQuestionCardView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let requestId: String
    public let questions: [PendingQuestion]
    public let onSubmit: ([QuestionAnswer]) -> Void
    public let onCancel: (() -> Void)?

    @State private var activeIndex = 0
    @State private var selectedChoices: [Int: Set<Int>] = [:]
    @State private var customTexts: [Int: String] = [:]
    /// The request this card already answered; it stays disabled until the host clears it.
    @State private var answeredRequestID: String?

    public init(
        requestId: String,
        questions: [PendingQuestion],
        onSubmit: @escaping ([QuestionAnswer]) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        self.requestId = requestId
        self.questions = questions
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    private var clampedIndex: Int {
        min(max(0, activeIndex), max(0, questions.count - 1))
    }

    private func isQuestionAnswered(_ idx: Int) -> Bool {
        let choices = selectedChoices[idx] ?? []
        let text = (customTexts[idx] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !choices.isEmpty || !text.isEmpty
    }

    private var hasAnyAnswer: Bool {
        (0..<questions.count).contains { isQuestionAnswered($0) }
    }

    private var inFlight: Bool {
        answeredRequestID == requestId
    }

    public var body: some View {
        let q = questions[clampedIndex]
        let chosen = selectedChoices[clampedIndex] ?? []

        VStack(alignment: .leading, spacing: 10) {
            if questions.count > 1 {
                HStack(spacing: 6) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { idx, item in
                        let isCur = idx == clampedIndex
                        let answered = isQuestionAnswered(idx)
                        Button {
                            activeIndex = idx
                        } label: {
                            HStack(spacing: 4) {
                                if answered {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8.5, weight: .bold))
                                }
                                Text(item.header.isEmpty ? "\(idx + 1)" : item.header)
                                    .font(.system(size: 10.5, weight: isCur ? .semibold : .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(isCur ? tokens.foreground : (answered ? tokens.success : tokens.mutedForeground))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Capsule().fill(isCur ? tokens.primarySoft : (answered ? tokens.successSoft : tokens.surface2)))
                            .overlay(Capsule().strokeBorder(isCur ? tokens.primaryBorder : tokens.borderEtched, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Text(l10n.tr("thread.question.step", clampedIndex + 1, questions.count))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                }
            }

            HStack(spacing: 6) {
                Text(q.question)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tokens.foreground)
                if q.multiSelect {
                    Text(l10n.tr("thread.question.multiHint"))
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tokens.prismCobalt)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(tokens.primarySoft))
                }
            }

            VStack(spacing: 6) {
                ForEach(Array(q.options.enumerated()), id: \.offset) { oIdx, opt in
                    let isSelected = chosen.contains(oIdx)
                    Button {
                        toggleChoice(questionIdx: clampedIndex, optionIdx: oIdx, multiSelect: q.multiSelect)
                    } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: q.multiSelect
                                ? (isSelected ? "checkmark.square.fill" : "square")
                                : (isSelected ? "largecircle.fill.circle" : "circle"))
                                .font(.system(size: 13))
                                .foregroundStyle(isSelected ? tokens.prismCobalt : tokens.mutedForeground)
                                .padding(.top, 1)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(opt.label)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(tokens.foreground)
                                if let desc = opt.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(.system(size: 11))
                                        .foregroundStyle(tokens.mutedForeground)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7.5)
                        .background(
                            RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                                .fill(isSelected ? tokens.primarySoft : tokens.surface2)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                                .strokeBorder(isSelected ? tokens.primaryBorder : tokens.borderEtched, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if q.allowsText || q.options.isEmpty {
                let idx = clampedIndex
                let textBinding = Binding<String>(
                    get: { customTexts[idx] ?? "" },
                    set: { newText in
                        customTexts[idx] = newText
                        // A single-choice question takes one answer: an option or the typed text.
                        if !q.multiSelect,
                           !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            selectedChoices[idx] = []
                        }
                    }
                )
                Group {
                    if q.secret {
                        SecureField(l10n.tr("thread.question.secretPlaceholder"), text: textBinding)
                    } else {
                        TextField(l10n.tr("thread.question.otherPlaceholder"), text: textBinding)
                    }
                }
                .onSubmit { submitFromTextField() }
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(tokens.foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous).fill(tokens.surface1))
                .overlay(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))
            }

            HStack(spacing: 8) {
                if let onCancel {
                    Button {
                        answerOnce(onCancel)
                    } label: {
                        Text(l10n.tr("newSession.cancel"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(tokens.mutedForeground)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5.5)
                            .background(Capsule().fill(tokens.hoverWash))
                            .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                if questions.count > 1 && clampedIndex > 0 {
                    Button {
                        activeIndex = clampedIndex - 1
                    } label: {
                        Text(l10n.tr("thread.question.prev"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(tokens.secondaryForeground)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5.5)
                            .background(Capsule().fill(tokens.hoverWash))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                if questions.count > 1 && clampedIndex + 1 < questions.count {
                    Button {
                        activeIndex = clampedIndex + 1
                    } label: {
                        Text(l10n.tr("thread.question.next"))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(tokens.foreground)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5.5)
                            .background(Capsule().fill(tokens.primarySoft))
                            .overlay(Capsule().strokeBorder(tokens.primaryBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        submitAll()
                    } label: {
                        Text(l10n.tr("thread.question.submit"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(
                                hasAnyAnswer
                                    ? tokens.inverseInk
                                    : tokens.placeholder
                            )
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(
                                    hasAnyAnswer
                                        ? tokens.inverseFill
                                        : tokens.surface2
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasAnyAnswer)
                }
            }
            .padding(.top, 2)
        }
        .disabled(inFlight)
        .opacity(inFlight ? 0.55 : 1)
        .task(id: answeredRequestID) {
            await releaseAnswerLockAfterTimeout(answeredRequestID) { answeredRequestID = nil }
        }
    }

    private func answerOnce(_ send: () -> Void) {
        guard !inFlight else { return }
        answeredRequestID = requestId
        send()
    }

    private func toggleChoice(questionIdx: Int, optionIdx: Int, multiSelect: Bool) {
        var set = selectedChoices[questionIdx] ?? []
        if multiSelect {
            if set.contains(optionIdx) { set.remove(optionIdx) } else { set.insert(optionIdx) }
            selectedChoices[questionIdx] = set
        } else {
            selectedChoices[questionIdx] = [optionIdx]
            customTexts[questionIdx] = nil
            // Single question without custom text: submit immediately for 1-click speed!
            let q = questions[questionIdx]
            if questions.count == 1 && !q.allowsText {
                answerOnce { onSubmit([QuestionAnswer(question: 0, choices: [optionIdx], text: nil)]) }
            } else if questions.count > 1 && questionIdx + 1 < questions.count && !q.allowsText {
                activeIndex = questionIdx + 1
            }
        }
    }

    private func submitAll() {
        var answers: [QuestionAnswer] = []
        for idx in 0..<questions.count {
            let choices = (selectedChoices[idx] ?? []).sorted()
            let txt = (customTexts[idx] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !choices.isEmpty || !txt.isEmpty {
                answers.append(QuestionAnswer(
                    question: idx,
                    choices: choices,
                    text: txt.isEmpty ? nil : txt
                ))
            }
        }
        guard !answers.isEmpty else { return }
        answerOnce { onSubmit(answers) }
    }

    /// Return in the answer field moves on, or on the last question submits: a question with no choices
    /// has only that field, so the answer goes from the keyboard too.
    private func submitFromTextField() {
        guard !inFlight else { return }
        if questions.count > 1 && clampedIndex + 1 < questions.count {
            if isQuestionAnswered(clampedIndex) { activeIndex = clampedIndex + 1 }
        } else if hasAnyAnswer {
            submitAll()
        }
    }
}

// MARK: - 9. Switch Agent Popover & Rename Session Sheet (Items 7 & 10)

public struct SwitchAgentPickerView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let currentAgentID: String
    public let agents: [AgentStatusInfo]
    public let onPick: (String) -> Void

    public init(currentAgentID: String, agents: [AgentStatusInfo], onPick: @escaping (String) -> Void) {
        self.currentAgentID = currentAgentID
        self.agents = agents
        self.onPick = onPick
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n.tr("switchAgent.title"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                Text(l10n.tr("switchAgent.subtitle"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(tokens.mutedForeground)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tokens.codeHeaderBackground)

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            VStack(spacing: 2) {
                ForEach(agents.filter { $0.state != "not-installed" }) { agent in
                    let isCurrent = agent.id == currentAgentID
                    Button {
                        if !isCurrent { onPick(agent.id) }
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(isCurrent ? tokens.success : tokens.prismIris)
                                .frame(width: 6.5, height: 6.5)
                            Text(agent.id == "antigravity" ? "Antigravity" : agent.name)
                                .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                                .foregroundStyle(isCurrent ? tokens.mutedForeground : tokens.foreground)
                            Spacer()
                            if isCurrent {
                                Text(l10n.tr("switchAgent.current"))
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(tokens.placeholder)
                            } else {
                                Image(systemName: "arrow.triangle.swap")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(tokens.prismIris)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isCurrent)
                }
            }
            .padding(6)
            .background(tokens.surface1)
        }
        .frame(width: 280)
        .clipShape(RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous)
                .strokeBorder(tokens.borderStrong, lineWidth: 1)
        )
    }
}

public struct RenameSessionSheetView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    @State private var text: String
    public let onSave: (String?) -> Void
    public let onCancel: () -> Void

    public init(initialTitle: String?, onSave: @escaping (String?) -> Void, onCancel: @escaping () -> Void) {
        self._text = State(initialValue: initialTitle ?? "")
        self.onSave = onSave
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.tr("rename.title"))
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(tokens.foreground)

            TextField(l10n.tr("rename.placeholder"), text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(tokens.foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.codeBackground))
                .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(tokens.borderStrong, lineWidth: 1))
                .onSubmit {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(trimmed.isEmpty ? nil : trimmed)
                }

            HStack {
                Spacer()
                Button(l10n.tr("rename.cancel"), action: onCancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tokens.mutedForeground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(tokens.hoverWash))

                Button {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(trimmed.isEmpty ? nil : trimmed)
                } label: {
                    Text(l10n.tr("rename.save"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tokens.inverseInk)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(tokens.inverseFill))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .frame(width: 360)
        .background(tokens.background)
    }
}

// MARK: - 10. Session Board Drawer (Background Tasks & Subagents)

public struct SessionBoardDrawerView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let subagents: [SessionSummary]
    public let tasks: [BackgroundTaskInfo]
    public let onOpenSubagent: (String) -> Void
    public let onStopTask: (String) -> Void
    public let onReadTaskOutput: (String) async -> BackgroundTaskOutput?
    public let onClose: () -> Void

    @State private var expandedTaskIDs: Set<String> = []
    @State private var taskOutputs: [String: BackgroundTaskOutput] = [:]
    @State private var loadingTaskIDs: Set<String> = []
    @State private var showEndedSubagents = false
    @State private var showEndedTasks = false

    public init(
        subagents: [SessionSummary],
        tasks: [BackgroundTaskInfo],
        onOpenSubagent: @escaping (String) -> Void,
        onStopTask: @escaping (String) -> Void,
        onReadTaskOutput: @escaping (String) async -> BackgroundTaskOutput?,
        onClose: @escaping () -> Void
    ) {
        self.subagents = subagents
        self.tasks = tasks
        self.onOpenSubagent = onOpenSubagent
        self.onStopTask = onStopTask
        self.onReadTaskOutput = onReadTaskOutput
        self.onClose = onClose
    }

    private func isSubagentWaiting(_ child: SessionSummary) -> Bool {
        child.permissionCount > 0 || child.attention == "permission" || child.status == .awaitingPermission
    }

    private func isSubagentLive(_ child: SessionSummary) -> Bool {
        isSubagentWaiting(child) || child.status == .running || child.status == .starting
    }

    private var liveSubagents: [SessionSummary] {
        subagents.filter(isSubagentLive)
    }

    private var endedSubagents: [SessionSummary] {
        subagents.filter { !isSubagentLive($0) }
    }

    private var liveTasks: [BackgroundTaskInfo] {
        tasks.filter { $0.status == "running" }
    }

    private var endedTasks: [BackgroundTaskInfo] {
        tasks.filter { $0.status != "running" }
    }

    public var body: some View {
        let waitingCount = liveSubagents.filter(isSubagentWaiting).count
        let runningCount = (liveSubagents.count - waitingCount) + liveTasks.count
        let isEmpty = subagents.isEmpty && tasks.isEmpty

        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(waitingCount > 0 ? tokens.warning : tokens.prismCobalt)

                Text(l10n.tr("board.title"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(tokens.foreground)

                if runningCount == 0 && waitingCount == 0 {
                    Text(l10n.tr("board.idle"))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                } else {
                    if runningCount > 0 {
                        Text(l10n.tr("board.runningCount", runningCount))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(tokens.prismCobalt)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tokens.primarySoft))
                    }
                    if waitingCount > 0 {
                        Text(l10n.tr("board.needsCount", waitingCount))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(tokens.warning)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tokens.warningSoft))
                    }
                }

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(tokens.hoverWash.opacity(0.75)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(tokens.codeHeaderBackground)

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            if isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 24))
                        .foregroundStyle(tokens.placeholder)
                    Text(l10n.tr("board.emptyTitle"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tokens.secondaryForeground)
                    Text(l10n.tr("board.emptyBody"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.mutedForeground)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !liveSubagents.isEmpty || !liveTasks.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(l10n.tr("board.now"))
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .tracking(0.6)
                                    .foregroundStyle(tokens.placeholder)

                                ForEach(liveSubagents) { child in
                                    liveSubagentRow(child)
                                }

                                ForEach(liveTasks) { task in
                                    backgroundTaskRow(task, isLive: true)
                                }
                            }
                        }

                        if !endedSubagents.isEmpty || !endedTasks.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(l10n.tr("board.earlier"))
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .tracking(0.6)
                                    .foregroundStyle(tokens.placeholder)

                                if !endedSubagents.isEmpty {
                                    let isOpen = showEndedSubagents || (liveSubagents.isEmpty && liveTasks.isEmpty)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Button {
                                            showEndedSubagents.toggle()
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: "chevron.right")
                                                    .font(.system(size: 9, weight: .semibold))
                                                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                                                Image(systemName: "arrow.triangle.branch")
                                                    .font(.system(size: 10.5))
                                                Text(l10n.tr("board.subagentsGroup", endedSubagents.count))
                                                    .font(.system(size: 11.5, weight: .semibold))
                                                Spacer()
                                            }
                                            .foregroundStyle(tokens.secondaryForeground)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)

                                        if isOpen {
                                            ForEach(endedSubagents) { child in
                                                liveSubagentRow(child)
                                            }
                                        }
                                    }
                                }

                                if !endedTasks.isEmpty {
                                    let isOpen = showEndedTasks || (liveSubagents.isEmpty && liveTasks.isEmpty && endedSubagents.isEmpty)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Button {
                                            showEndedTasks.toggle()
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: "chevron.right")
                                                    .font(.system(size: 9, weight: .semibold))
                                                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                                                Image(systemName: "terminal")
                                                    .font(.system(size: 10.5))
                                                Text(l10n.tr("board.tasksGroup", endedTasks.count))
                                                    .font(.system(size: 11.5, weight: .semibold))
                                                Spacer()
                                            }
                                            .foregroundStyle(tokens.secondaryForeground)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)

                                        if isOpen {
                                            ForEach(endedTasks) { task in
                                                backgroundTaskRow(task, isLive: false)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(14)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(tokens.background)
    }

    private func liveSubagentRow(_ child: SessionSummary) -> some View {
        let waiting = isSubagentWaiting(child)
        let running = !waiting && (child.status == .running || child.status == .starting)
        let failed = child.status == .failed || child.attention == "error"

        return Button {
            if !child.id.hasPrefix("tool:") {
                onOpenSubagent(child.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    if running {
                        PrismTurnDotsView(phase: .working, size: 12)
                    } else {
                        Circle()
                            .fill(waiting ? tokens.warning : (failed ? tokens.danger : tokens.success))
                            .frame(width: 6.5, height: 6.5)
                    }

                    Text(child.title ?? child.id)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if waiting {
                        Text(l10n.tr("board.review"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(tokens.inverseInk)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(tokens.warning))
                    } else if running {
                        TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                            let sec = max(0, Int(ctx.date.timeIntervalSince1970 - child.createdAt / 1000.0))
                            Text(sec < 60 ? "\(sec)s" : "\(sec / 60)m \(sec % 60)s")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(tokens.placeholder)
                        }
                    }
                }

                if let act = child.activity, running {
                    Text(act.detail.map { "\(act.title) · \($0)" } ?? act.title)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tokens.mutedForeground)
                        .lineLimit(1)
                } else if let desc = child.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.mutedForeground)
                        .lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .prismSurface(elevation: .raised, cornerRadius: tokens.rSM)
            .overlay(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .strokeBorder(waiting ? tokens.warning.opacity(0.5) : tokens.borderEtched, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func backgroundTaskRow(_ task: BackgroundTaskInfo, isLive: Bool) -> some View {
        let isOpen = expandedTaskIDs.contains(task.id)
        let isFailed = task.status == "failed"
        let icon = task.kind == "monitor" ? "eye" : (task.kind == "workflow" ? "flowchart" : "terminal")

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if isLive {
                    PrismTurnDotsView(phase: .working, size: 12)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 10.5))
                        .foregroundStyle(isFailed ? tokens.danger : tokens.mutedForeground)
                }

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(task.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)

                    if let subtitle = task.command ?? task.summary, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                if isLive {
                    TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                        let sec = max(0, Int(ctx.date.timeIntervalSince1970 - task.startedAt / 1000.0))
                        Text(sec < 60 ? "\(sec)s" : "\(sec / 60)m \(sec % 60)s")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                    }

                    if task.supportsStop {
                        Button {
                            onStopTask(task.id)
                        } label: {
                            Text(l10n.tr("board.stopTask"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(tokens.danger)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(Capsule().fill(tokens.dangerSoft))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if task.supportsOutput {
                HStack(spacing: 8) {
                    Button {
                        if isOpen {
                            expandedTaskIDs.remove(task.id)
                        } else {
                            expandedTaskIDs.insert(task.id)
                            loadOutput(for: task.id)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8.5, weight: .semibold))
                            Text(isOpen ? l10n.tr("board.hideOutput") : l10n.tr("board.viewOutput"))
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(tokens.prismCobalt)
                    }
                    .buttonStyle(.plain)

                    if isOpen && isLive {
                        Button {
                            loadOutput(for: task.id)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                                .foregroundStyle(tokens.mutedForeground)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if isOpen {
                if loadingTaskIDs.contains(task.id) && taskOutputs[task.id] == nil {
                    Text(l10n.tr("board.loadingOutput"))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                } else if let out = taskOutputs[task.id], !out.output.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if out.truncated {
                            Text(l10n.tr("board.outputTruncated"))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(tokens.placeholder)
                        }
                        ScrollView {
                            Text(out.output)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(tokens.secondaryForeground)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(maxHeight: 160)
                        .background(tokens.codeBackground)
                        .clipShape(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous))
                    }
                } else {
                    Text(l10n.tr("board.noOutput"))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .prismSurface(elevation: .raised, cornerRadius: tokens.rSM)
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(isFailed ? tokens.danger.opacity(0.35) : tokens.borderEtched, lineWidth: 1)
        )
    }

    private func loadOutput(for taskId: String) {
        loadingTaskIDs.insert(taskId)
        Task {
            let res = await onReadTaskOutput(taskId)
            loadingTaskIDs.remove(taskId)
            if let res {
                taskOutputs[taskId] = res
            }
        }
    }
}

// MARK: - 11. Subagent Bottom Control Bar (replaces Composer inside a subagent session)

public struct SubagentBarView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let agentName: String
    public let parentTitle: String?
    public let isRunning: Bool
    public let canCancel: Bool
    public let onStop: () -> Void
    public let onBackToParent: (() -> Void)?

    public init(
        agentName: String,
        parentTitle: String?,
        isRunning: Bool,
        canCancel: Bool,
        onStop: @escaping () -> Void,
        onBackToParent: (() -> Void)?
    ) {
        self.agentName = agentName
        self.parentTitle = parentTitle
        self.isRunning = isRunning
        self.canCancel = canCancel
        self.onStop = onStop
        self.onBackToParent = onBackToParent
    }

    public var body: some View {
        HStack(spacing: 10) {
            if isRunning {
                PrismTurnDotsView(phase: .working, size: 13)
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tokens.prismCobalt)
            }

            Text(parentTitle.map { l10n.tr("subagentBar.runsFor", agentName, $0) }
                ?? l10n.tr("subagentBar.runsForParent", agentName))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(tokens.secondaryForeground)
                .lineLimit(1)

            Spacer(minLength: 8)

            if isRunning && canCancel {
                Button(action: onStop) {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9))
                        Text(l10n.tr("subagentBar.stop"))
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(tokens.danger)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(tokens.dangerSoft))
                    .overlay(Capsule().strokeBorder(tokens.danger.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            if let onBackToParent {
                Button(action: onBackToParent) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text(l10n.tr("subagentBar.back"))
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(tokens.foreground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(tokens.surface2))
                    .overlay(Capsule().strokeBorder(tokens.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 760)
        .prismSurface(elevation: .floating, cornerRadius: tokens.rLG)
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }
}

// MARK: - 12. Inline Session Activity Dock (Always-Visible Floating Strip Above Composer)

/// Floating Obsidian Prism live dock mounted directly inside the conversation stage above the composer.
/// Appears only while genuine background tasks or subagents are live:
/// - Defaults to a calm collapsed single-line bar when only 1 item is running (no permission waiting).
/// - Defaults to expanded when 2+ live items are active or any subagent awaits approval.
public struct SessionActivityDockView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismMotionTier) private var motionTier

    public let subagents: [SessionSummary]
    public let tasks: [BackgroundTaskInfo]
    @Binding public var expandedOverride: Bool?
    public let onOpenSubagent: (String) -> Void
    public let onJumpToToolEntry: ((String) -> Void)?
    public let onStopTask: (String) -> Void
    public let onReadTaskOutput: (String) async -> BackgroundTaskOutput?

    @State private var showEarlierInline = false
    @State private var expandedTaskIDs: Set<String> = []
    @State private var loadingTaskIDs: Set<String> = []
    @State private var taskOutputs: [String: BackgroundTaskOutput] = [:]

    public init(
        subagents: [SessionSummary],
        tasks: [BackgroundTaskInfo],
        expandedOverride: Binding<Bool?>,
        onOpenSubagent: @escaping (String) -> Void,
        onJumpToToolEntry: ((String) -> Void)? = nil,
        onStopTask: @escaping (String) -> Void,
        onReadTaskOutput: @escaping (String) async -> BackgroundTaskOutput?
    ) {
        self.subagents = subagents
        self.tasks = tasks
        self._expandedOverride = expandedOverride
        self.onOpenSubagent = onOpenSubagent
        self.onJumpToToolEntry = onJumpToToolEntry
        self.onStopTask = onStopTask
        self.onReadTaskOutput = onReadTaskOutput
    }

    private func isSubagentWaiting(_ s: SessionSummary) -> Bool {
        s.permissionCount > 0 || s.attention == "permission" || s.status == .awaitingPermission
    }

    private func isSubagentLive(_ s: SessionSummary) -> Bool {
        isSubagentWaiting(s) || s.status == .running || s.status == .starting
    }

    private var liveSubagents: [SessionSummary] {
        subagents.filter(isSubagentLive)
    }

    private var endedSubagents: [SessionSummary] {
        subagents.filter { !isSubagentLive($0) }
    }

    private var liveTasks: [BackgroundTaskInfo] {
        tasks.filter { $0.status == "running" }
    }

    private var endedTasks: [BackgroundTaskInfo] {
        tasks.filter { $0.status != "running" }
    }

    public var body: some View {
        let waitingCount = liveSubagents.filter(isSubagentWaiting).count
        let runningCount = (liveSubagents.count - waitingCount) + liveTasks.count
        let liveCount = liveSubagents.count + liveTasks.count
        let endedCount = endedSubagents.count + endedTasks.count

        if liveCount > 0 {
            let defaultExpanded = liveCount >= 2 || waitingCount > 0
            let isExpanded = expandedOverride ?? defaultExpanded
            let effectivelyCollapsed = !isExpanded

            VStack(alignment: .leading, spacing: 0) {
                // Header / Compact Summary Bar
                HStack(spacing: 8) {
                    if waitingCount > 0 {
                        Circle()
                            .fill(tokens.warning)
                            .frame(width: 7, height: 7)
                            .shadow(color: tokens.warning.opacity(0.65), radius: 4)
                    } else {
                        PrismTurnDotsView(phase: .working, size: 12)
                    }

                    Text(l10n.tr("board.title"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(tokens.foreground)

                    if runningCount > 0 {
                        Text(l10n.tr("board.runningCount", runningCount))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(tokens.prismCobalt)
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tokens.primarySoft))
                    }

                    if waitingCount > 0 {
                        Text(l10n.tr("board.needsCount", waitingCount))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(tokens.warning)
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tokens.warningSoft))
                    }

                    // Preview first active item title inline when collapsed
                    if effectivelyCollapsed, let previewTitle = firstActivePreviewTitle {
                        Text("· \(previewTitle)")
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    Button {
                        withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier)) {
                            expandedOverride = !isExpanded
                        }
                    } label: {
                        Image(systemName: effectivelyCollapsed ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(tokens.mutedForeground)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(tokens.hoverWash.opacity(0.65)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier)) {
                        expandedOverride = !isExpanded
                    }
                }

                if !effectivelyCollapsed {
                    Rectangle().fill(tokens.borderEtched).frame(height: 1)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(liveSubagents) { child in
                                inlineSubagentCard(child)
                            }

                            ForEach(liveTasks) { task in
                                inlineTaskCard(task, isLive: true)
                            }

                            if endedCount > 0 {
                                Button {
                                    withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier)) {
                                        showEarlierInline.toggle()
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 8.5, weight: .semibold))
                                            .rotationEffect(.degrees(showEarlierInline ? 90 : 0))
                                        Text("\(l10n.tr("board.earlier")) (\(endedCount))")
                                            .font(.system(size: 10.5, weight: .medium))
                                        Spacer()
                                    }
                                    .foregroundStyle(tokens.placeholder)
                                    .padding(.top, 2)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if showEarlierInline {
                                    ForEach(endedSubagents) { child in
                                        inlineSubagentCard(child)
                                    }
                                    ForEach(endedTasks) { task in
                                        inlineTaskCard(task, isLive: false)
                                    }
                                }
                            }
                        }
                        .padding(8)
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxHeight: 220)
                }
            }
            .prismSurface(elevation: .raised, cornerRadius: tokens.rMD)
            .overlay(
                RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous)
                    .strokeBorder(
                        waitingCount > 0 ? tokens.warning.opacity(0.5)
                            : (effectivelyCollapsed ? tokens.borderEtched : tokens.primaryBorder),
                        lineWidth: 1
                    )
            )
            .onChange(of: liveCount) { oldCount, newCount in
                if newCount == 0 {
                    expandedOverride = nil
                    showEarlierInline = false
                } else if oldCount == 0 && newCount > 0 {
                    expandedOverride = nil
                }
            }
        }
    }

    private var firstActivePreviewTitle: String? {
        if let firstSub = liveSubagents.first {
            return firstSub.title ?? firstSub.id
        }
        if let firstTask = liveTasks.first {
            return firstTask.title
        }
        if let sub = endedSubagents.first {
            return sub.title ?? sub.id
        }
        return endedTasks.first?.title
    }

    private func inlineSubagentCard(_ child: SessionSummary) -> some View {
        let waiting = isSubagentWaiting(child)
        let running = !waiting && (child.status == .running || child.status == .starting)
        let failed = child.status == .failed || child.attention == "error"

        return Button {
            if child.id.hasPrefix("tool:") {
                onJumpToToolEntry?(String(child.id.dropFirst(5)))
            } else {
                onOpenSubagent(child.id)
            }
        } label: {
            HStack(spacing: 8) {
                if running {
                    PrismTurnDotsView(phase: .working, size: 11)
                } else {
                    Circle()
                        .fill(waiting ? tokens.warning : (failed ? tokens.danger : tokens.success))
                        .frame(width: 6, height: 6)
                }

                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 5) {
                        Text(child.title ?? child.id)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(tokens.foreground)
                            .lineLimit(1)
                        Text(child.agentId)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                            .lineLimit(1)
                    }

                    if let act = child.activity, running {
                        Text(act.detail.map { "\(act.title) · \($0)" } ?? act.title)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                    } else if let desc = child.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 10.5))
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                if running {
                    TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                        let sec = max(0, Int(ctx.date.timeIntervalSince1970 - child.createdAt / 1000.0))
                        Text(sec < 60 ? "\(sec)s" : "\(sec / 60)m \(sec % 60)s")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                    }
                }

                if waiting {
                    Text(l10n.tr("board.review"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tokens.inverseInk)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(tokens.warning))
                } else {
                    HStack(spacing: 3) {
                        Text(l10n.tr("board.openSubagent"))
                            .font(.system(size: 10, weight: .medium))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8.5, weight: .semibold))
                    }
                    .foregroundStyle(tokens.prismCobalt)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(tokens.primarySoft))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .fill(tokens.surface1.opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .strokeBorder(waiting ? tokens.warning.opacity(0.45) : tokens.borderEtched, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func inlineTaskCard(_ task: BackgroundTaskInfo, isLive: Bool) -> some View {
        let isOpen = expandedTaskIDs.contains(task.id)
        let isFailed = task.status == "failed"
        let icon = task.kind == "monitor" ? "eye" : (task.kind == "workflow" ? "flowchart" : "terminal")

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if isLive {
                    PrismTurnDotsView(phase: .working, size: 11)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 10.5))
                        .foregroundStyle(isFailed ? tokens.danger : tokens.mutedForeground)
                }

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(task.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)

                    if let subtitle = task.command ?? task.summary, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                if isLive {
                    TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                        let sec = max(0, Int(ctx.date.timeIntervalSince1970 - task.startedAt / 1000.0))
                        Text(sec < 60 ? "\(sec)s" : "\(sec / 60)m \(sec % 60)s")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                    }
                }

                if task.supportsOutput {
                    Button {
                        withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier)) {
                            if isOpen {
                                expandedTaskIDs.remove(task.id)
                            } else {
                                expandedTaskIDs.insert(task.id)
                                loadTaskOutput(for: task.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: isOpen ? "chevron.up" : "terminal")
                                .font(.system(size: 8.5, weight: .semibold))
                            Text(isOpen ? l10n.tr("board.hideOutput") : l10n.tr("board.viewOutput"))
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(tokens.prismCobalt)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(tokens.primarySoft))
                    }
                    .buttonStyle(.plain)
                }

                if let entryId = task.entryId, let onJumpToToolEntry {
                    Button {
                        onJumpToToolEntry(entryId)
                    } label: {
                        HStack(spacing: 3) {
                            Text(l10n.tr("board.jumpToCall"))
                                .font(.system(size: 10, weight: .medium))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(tokens.secondaryForeground)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(tokens.surface2))
                        .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                if isLive && task.supportsStop {
                    Button {
                        onStopTask(task.id)
                    } label: {
                        Text(l10n.tr("board.stopTask"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(tokens.danger)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(tokens.dangerSoft))
                    }
                    .buttonStyle(.plain)
                }
            }

            if isOpen {
                VStack(alignment: .leading, spacing: 4) {
                    if loadingTaskIDs.contains(task.id) && taskOutputs[task.id] == nil {
                        Text(l10n.tr("board.loadingOutput"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                    } else if let out = taskOutputs[task.id], !out.output.isEmpty {
                        HStack {
                            if out.truncated {
                                Text(l10n.tr("board.outputTruncated"))
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(tokens.placeholder)
                            }
                            Spacer()
                            if isLive {
                                Button {
                                    loadTaskOutput(for: task.id)
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(tokens.mutedForeground)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        ScrollView {
                            Text(out.output)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(tokens.secondaryForeground)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(maxHeight: 140)
                        .background(tokens.codeBackground)
                        .clipShape(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous))
                    } else {
                        Text(l10n.tr("board.noOutput"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .fill(tokens.surface1.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(isFailed ? tokens.danger.opacity(0.35) : tokens.borderEtched, lineWidth: 1)
        )
    }

    private func loadTaskOutput(for taskId: String) {
        loadingTaskIDs.insert(taskId)
        Task {
            let res = await onReadTaskOutput(taskId)
            loadingTaskIDs.remove(taskId)
            if let res {
                taskOutputs[taskId] = res
            }
        }
    }
}



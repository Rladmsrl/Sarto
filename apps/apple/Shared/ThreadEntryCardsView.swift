import Foundation
import SartoProtocol
import PrismDesign
import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Unified Host Action Callbacks for Extended Sarto Protocol Cards

public struct ThreadEntryCardActions: Sendable {
    public var onAnswerMemory: (@Sendable (String, String) -> Void)?
    public var onUndoMemory: (@Sendable (String) -> Void)?
    public var onAnswerSettingsChange: (@Sendable (String, String) -> Void)?
    public var onUndoSettingsChange: (@Sendable (String) -> Void)?
    public var onAnswerBrowserOrigin: (@Sendable (String, String) -> Void)?
    public var onAnswerControlAsk: (@Sendable (String, String) -> Void)?
    public var onAnswerDeviceAccess: (@Sendable (String, String) -> Void)?
    public var onAnswerSurfaceAccess: (@Sendable (String, String) -> Void)?
    public var onAnswerComputerApp: (@Sendable (String, String) -> Void)?
    public var onDeclineComputerSetup: (@Sendable (String) -> Void)?
    public var onAnswerProjectMcp: (@Sendable (String, String) -> Void)?
    public var onAnswerProjectHooks: (@Sendable (String, String) -> Void)?
    public var onAnswerProblemReport: (@Sendable (String, String) -> Void)?
    public var onSubmitProblemReport: (@MainActor @Sendable (ProblemReportEntryPayload) async throws -> Void)?
    public var onOpenProblemReport: (@Sendable (ProblemReportEntryPayload) -> Void)?
    public var onReportTurnError: (@Sendable (String) -> Void)?
    public var onAnswerMarketPublish: (@Sendable (String, String) -> Void)?
    public var onRespondElicitation: (@Sendable (String, String?, [String: JSONValue]?) -> Void)?
    public var isCloudSignedIn: Bool

    public init(
        onAnswerMemory: (@Sendable (String, String) -> Void)? = nil,
        onUndoMemory: (@Sendable (String) -> Void)? = nil,
        onAnswerSettingsChange: (@Sendable (String, String) -> Void)? = nil,
        onUndoSettingsChange: (@Sendable (String) -> Void)? = nil,
        onAnswerBrowserOrigin: (@Sendable (String, String) -> Void)? = nil,
        onAnswerControlAsk: (@Sendable (String, String) -> Void)? = nil,
        onAnswerDeviceAccess: (@Sendable (String, String) -> Void)? = nil,
        onAnswerSurfaceAccess: (@Sendable (String, String) -> Void)? = nil,
        onAnswerComputerApp: (@Sendable (String, String) -> Void)? = nil,
        onDeclineComputerSetup: (@Sendable (String) -> Void)? = nil,
        onAnswerProjectMcp: (@Sendable (String, String) -> Void)? = nil,
        onAnswerProjectHooks: (@Sendable (String, String) -> Void)? = nil,
        onAnswerProblemReport: (@Sendable (String, String) -> Void)? = nil,
        onSubmitProblemReport: (@MainActor @Sendable (ProblemReportEntryPayload) async throws -> Void)? = nil,
        onOpenProblemReport: (@Sendable (ProblemReportEntryPayload) -> Void)? = nil,
        onReportTurnError: (@Sendable (String) -> Void)? = nil,
        onAnswerMarketPublish: (@Sendable (String, String) -> Void)? = nil,
        onRespondElicitation: (@Sendable (String, String?, [String: JSONValue]?) -> Void)? = nil,
        isCloudSignedIn: Bool = false
    ) {
        self.onAnswerMemory = onAnswerMemory
        self.onUndoMemory = onUndoMemory
        self.onAnswerSettingsChange = onAnswerSettingsChange
        self.onUndoSettingsChange = onUndoSettingsChange
        self.onAnswerBrowserOrigin = onAnswerBrowserOrigin
        self.onAnswerControlAsk = onAnswerControlAsk
        self.onAnswerDeviceAccess = onAnswerDeviceAccess
        self.onAnswerSurfaceAccess = onAnswerSurfaceAccess
        self.onAnswerComputerApp = onAnswerComputerApp
        self.onDeclineComputerSetup = onDeclineComputerSetup
        self.onAnswerProjectMcp = onAnswerProjectMcp
        self.onAnswerProjectHooks = onAnswerProjectHooks
        self.onAnswerProblemReport = onAnswerProblemReport
        self.onSubmitProblemReport = onSubmitProblemReport
        self.onOpenProblemReport = onOpenProblemReport
        self.onReportTurnError = onReportTurnError
        self.onAnswerMarketPublish = onAnswerMarketPublish
        self.onRespondElicitation = onRespondElicitation
        self.isCloudSignedIn = isCloudSignedIn
    }
}

// MARK: - 1. Git Event Row (`commit` / `push` / `branch` / `pull_request`)

public struct GitEventEntryRow: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let payload: GitEntryPayload

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tokens.prismCobalt)
                .frame(width: 16)

            switch payload.event {
            case "commit":
                if let first = payload.commits.first {
                    Text(String(first.oid.prefix(7)))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tokens.prismCobalt)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(tokens.primarySoft))
                    Text(first.subject)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tokens.foreground.opacity(0.9))
                        .lineLimit(1)
                    if payload.commits.count > 1 || payload.more > 0 {
                        let extra = (payload.commits.count - 1) + payload.more
                        Text("+\(extra)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                    }
                }
            case "push":
                Text(l10n.tr("thread.git.pushed", payload.count ?? 1, payload.upstream ?? "remote"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tokens.secondaryForeground)
                    .lineLimit(1)
            case "branch":
                Text(l10n.tr("thread.git.branch", payload.branch ?? ""))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tokens.secondaryForeground)
                    .lineLimit(1)
            case "pull_request":
                if let urlStr = payload.url,
                   let url = URL(string: urlStr),
                   let scheme = url.scheme?.lowercased(),
                   scheme == "http" || scheme == "https" {
                    Link(destination: url) {
                        HStack(spacing: 5) {
                            Text(l10n.tr("thread.git.pullRequest"))
                                .font(.system(size: 12, weight: .medium))
                            Text(urlStr)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(tokens.prismCobalt)
                    }
                }
            default:
                Text(payload.event)
                    .font(.system(size: 12))
                    .foregroundStyle(tokens.secondaryForeground)
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.surface1.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))
    }

    private var iconName: String {
        switch payload.event {
        case "commit": return "checkmark.circle"
        case "push": return "arrow.up.circle"
        case "branch": return "arrow.triangle.branch"
        case "pull_request": return "arrow.triangle.pull"
        default: return "point.topleft.down.curvedto.point.bottomright.up"
        }
    }
}

// MARK: - 2. Memory Write / Approval Card

public struct MemoryWriteEntryCardView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let payload: MemoryWriteEntryPayload
    public let actions: ThreadEntryCardActions

    public var body: some View {
        let isPending = payload.awaitsAnswer
        let isGlobal = payload.layer == "global"

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isGlobal ? "globe" : "brain")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isPending ? tokens.warning : tokens.prismIris)
                Text(headerTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(1)
                Text(isGlobal ? l10n.tr("thread.memory.global") : l10n.tr("thread.memory.project"))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(tokens.surface2))
                Spacer()
                if payload.undo != nil && payload.status == "written", let onUndo = actions.onUndoMemory {
                    Button {
                        onUndo(payload.id)
                    } label: {
                        Text(l10n.tr("thread.entry.undo"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tokens.primary)
                    }
                    .buttonStyle(.plain)
                } else if !isPending {
                    Text(statusText)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                }
            }

            if let desc = payload.draft?.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 11.5))
                    .foregroundStyle(tokens.secondaryForeground)
            }
            if let body = payload.draft?.body, !body.isEmpty, isPending {
                Text(body)
                    .font(.system(size: 11.5))
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(4)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.surface2.opacity(0.65)))
            }

            if isPending, let onAnswer = actions.onAnswerMemory {
                HStack(spacing: 8) {
                    ProtocolActionButton(title: l10n.tr("thread.memory.remember"), primary: true) {
                        onAnswer(payload.id, "remember")
                    }
                    ProtocolActionButton(title: l10n.tr("thread.memory.decline"), primary: false) {
                        onAnswer(payload.id, "skip")
                    }
                }
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.surface1.opacity(0.85)))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(isPending ? tokens.warning.opacity(0.45) : tokens.borderEtched, lineWidth: 1)
        )
    }

    private var headerTitle: String {
        let title = payload.title.isEmpty ? (payload.draft?.title ?? "") : payload.title
        switch payload.action {
        case "forget": return l10n.tr("thread.memory.forgetTitle", title)
        case "update": return l10n.tr("thread.memory.updateTitle", title)
        default: return l10n.tr("thread.memory.rememberTitle", title)
        }
    }

    private var statusText: String {
        switch payload.status {
        case "undone": return l10n.tr("thread.entry.undone")
        case "declined": return l10n.tr("thread.entry.declined")
        case "accepted", "written": return l10n.tr("thread.entry.saved")
        default: return payload.status
        }
    }
}

// MARK: - 4. Settings Change Card

public struct SettingsChangeEntryCardView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let payload: SettingsChangeEntryPayload
    public let actions: ThreadEntryCardActions

    public var body: some View {
        let isPending = payload.outcome == nil
        let canUndo = payload.outcome?.kind == "changed" && payload.outcome?.undone != true && payload.outcome?.stale != true

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.2")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isPending ? tokens.warning : tokens.prismCobalt)
                Text(l10n.tr("thread.settings.title"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                Spacer()
                if canUndo, let onUndo = actions.onUndoSettingsChange {
                    Button(l10n.tr("thread.entry.undo")) { onUndo(payload.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tokens.primary)
                } else if let outcome = payload.outcome {
                    Text(outcome.undone == true ? l10n.tr("thread.entry.undone") : outcome.kind)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                }
            }

            ForEach(payload.items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("\(item.place) › \(item.name)")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(tokens.secondaryForeground)
                        Spacer()
                        Text("\(item.from.text) → \(item.to.text)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(tokens.foreground)
                    }
                    if let warn = item.warning, !warn.isEmpty {
                        Text(warn)
                            .font(.system(size: 10.5))
                            .foregroundStyle(tokens.warning)
                    }
                }
            }

            if isPending, let onAnswer = actions.onAnswerSettingsChange {
                HStack(spacing: 8) {
                    ProtocolActionButton(title: l10n.tr("thread.settings.apply"), primary: true) {
                        onAnswer(payload.id, "change")
                    }
                    ProtocolActionButton(title: l10n.tr("thread.settings.keep"), primary: false) {
                        onAnswer(payload.id, "keep")
                    }
                }
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.surface1.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(isPending ? tokens.warning.opacity(0.45) : tokens.borderEtched, lineWidth: 1))
    }
}

// MARK: - 5. Access / Control / MCP / Hooks / Report / Publish / Task Delivery Cards

public struct ProblemReportEntryCardView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let payload: ProblemReportEntryPayload
    public let isSignedIn: Bool
    public let onSubmitDirectly: (@MainActor @Sendable (ProblemReportEntryPayload) async throws -> Void)?
    public let onEdit: (@Sendable (ProblemReportEntryPayload) -> Void)?
    public let onSkip: (@Sendable () -> Void)?

    @State private var isSubmitting = false
    @State private var submitError: String? = nil

    private var isPending: Bool { payload.outcome == nil }

    private var settledText: String? {
        guard let outcome = payload.outcome else { return nil }
        switch outcome.kind {
        case "sent":
            if let rid = outcome.reportId, !rid.isEmpty {
                return l10n.tr("thread.report.answer.sent", rid)
            }
            return l10n.tr("thread.report.answer.sentPlain")
        case "saved":
            return l10n.tr("thread.report.answer.saved")
        default:
            return l10n.tr("thread.report.answer.skipped")
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isPending ? tokens.prismCobalt : tokens.mutedForeground)
                VStack(alignment: .leading, spacing: 1) {
                    Text(l10n.tr("thread.report.action"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(tokens.mutedForeground)
                    Text(payload.title.isEmpty ? l10n.tr("thread.report.title") : payload.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if let settledText {
                    Text(settledText)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(payload.outcome?.kind == "sent" ? tokens.success : tokens.placeholder)
                }
            }

            if !payload.details.isEmpty {
                Text(payload.details)
                    .font(.system(size: 12))
                    .foregroundStyle(tokens.secondaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = payload.error, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(4)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.surface2.opacity(0.65)))
            }

            if isPending {
                VStack(alignment: .leading, spacing: 3) {
                    Text(l10n.tr("thread.report.attached.title"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(tokens.mutedForeground)
                    ForEach(
                        [
                            l10n.tr("thread.report.attached.about"),
                            l10n.tr("thread.report.attached.logs"),
                            l10n.tr("thread.report.attached.ids"),
                        ],
                        id: \.self
                    ) { line in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(tokens.mutedForeground.opacity(0.6))
                                .frame(width: 3.5, height: 3.5)
                            Text(line)
                                .font(.system(size: 11))
                                .foregroundStyle(tokens.mutedForeground)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.surface2.opacity(0.45)))

                if let submitError {
                    Text(submitError)
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    if let onSubmitDirectly {
                        Button {
                            guard !isSubmitting else { return }
                            isSubmitting = true
                            submitError = nil
                            Task { @MainActor in
                                defer { isSubmitting = false }
                                do {
                                    try await onSubmitDirectly(payload)
                                } catch {
                                    submitError = error.localizedDescription
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                if isSubmitting {
                                    ProgressView().controlSize(.mini)
                                }
                                Text(l10n.tr(isSignedIn ? "thread.report.send" : "thread.report.sendAnonymous"))
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.prismCobalt))
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting)
                    }

                    if let onSkip {
                        ProtocolActionButton(title: l10n.tr("thread.report.skip"), primary: false) {
                            onSkip()
                        }
                        .disabled(isSubmitting)
                    }

                    Spacer(minLength: 4)

                    if let onEdit {
                        Button {
                            onEdit(payload)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 10.5, weight: .medium))
                                Text(l10n.tr("thread.report.edit"))
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .foregroundStyle(tokens.secondaryForeground)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.surface2))
                            .overlay(RoundedRectangle(cornerRadius: tokens.rXS).strokeBorder(tokens.borderEtched, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting)
                    }
                }
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.surface1.opacity(0.85)))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(isPending ? tokens.prismCobalt.opacity(0.4) : tokens.borderEtched, lineWidth: 1)
        )
    }
}

public struct ProtocolApprovalEntryCardView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let icon: String
    public let title: String
    public let subtitle: String?
    public let details: [String]
    public let isPending: Bool
    public let settledBadge: String?
    public let buttons: [(title: String, primary: Bool, action: () -> Void)]

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isPending ? tokens.warning : tokens.mutedForeground)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(1)
                Spacer()
                if let settledBadge, !settledBadge.isEmpty {
                    Text(settledBadge)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                }
            }

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(tokens.secondaryForeground)
            }

            if !details.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(details.prefix(6).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.surface2.opacity(0.65)))
            }

            if isPending && !buttons.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(buttons.enumerated()), id: \.offset) { _, btn in
                        ProtocolActionButton(title: btn.title, primary: btn.primary, action: btn.action)
                    }
                }
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.surface1.opacity(0.85)))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(isPending ? tokens.warning.opacity(0.45) : tokens.borderEtched, lineWidth: 1)
        )
    }
}

public struct ControlNoteEntryRow: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let payload: ControlNoteEntryPayload

    public var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "hand.raised")
                .font(.system(size: 10.5))
                .foregroundStyle(tokens.mutedForeground)
            Text(summaryText)
                .font(.system(size: 11.5))
                .foregroundStyle(tokens.mutedForeground)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    private var summaryText: String {
        switch payload.event {
        case "handed_back":
            let dur = payload.durationMs.map { ThreadTimelineBuilder.formatDuration($0) } ?? ""
            return l10n.tr("thread.control.handedBack", payload.surface, dur)
        case "paused":
            return l10n.tr("thread.control.paused", payload.app ?? payload.surface)
        case "used":
            return l10n.tr("thread.control.used", payload.name ?? payload.surface)
        default:
            return "\(payload.surface) · \(payload.event)"
        }
    }
}

// MARK: - 6. MCP Elicitation Form / URL Card

public struct ElicitationCardView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let requestId: String
    public let elicitation: PendingElicitation
    public let options: [PermissionOption]
    public let onRespond: (String, String?, [String: JSONValue]?) -> Void

    @State private var textValues: [String: String] = [:]
    @State private var boolValues: [String: Bool] = [:]
    @State private var answeredRequestID: String?

    private var inFlight: Bool {
        answeredRequestID == requestId
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: elicitation.kind == "url" ? "safari" : "list.bullet.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tokens.warning)
                Text(elicitation.server.isEmpty ? l10n.tr("thread.elicitation.title") : elicitation.server)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                Spacer()
                Text(l10n.tr("thread.awaitingApproval"))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tokens.warning)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tokens.warningSoft))
            }

            if !elicitation.message.isEmpty {
                Text(elicitation.message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(tokens.secondaryForeground)
            }

            if elicitation.kind == "url",
               let urlStr = elicitation.url,
               let url = URL(string: urlStr),
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                Link(destination: url) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square")
                        Text(urlStr)
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(tokens.prismCobalt)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(elicitation.fields) { field in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(field.title)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(tokens.foreground)
                                if field.required {
                                    Text("*").foregroundStyle(tokens.danger)
                                }
                            }
                            if let desc = field.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(tokens.mutedForeground)
                            }
                            if field.type == "boolean" {
                                Toggle("", isOn: Binding(
                                    get: { boolValues[field.key] ?? (field.defaultValue?.boolValue ?? false) },
                                    set: { boolValues[field.key] = $0 }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                            } else if !field.choices.isEmpty {
                                Picker("", selection: Binding(
                                    get: { textValues[field.key] ?? field.defaultValue?.stringValue ?? field.choices.first?.value ?? "" },
                                    set: { textValues[field.key] = $0 }
                                )) {
                                    ForEach(field.choices) { ch in
                                        Text(ch.label).tag(ch.value)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                            } else {
                                TextField(field.title, text: Binding(
                                    get: { textValues[field.key] ?? field.defaultValue?.stringValue ?? "" },
                                    set: { textValues[field.key] = $0 }
                                ))
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.surface2))
                                .overlay(RoundedRectangle(cornerRadius: tokens.rXS).strokeBorder(tokens.borderEtched, lineWidth: 1))
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                ProtocolActionButton(title: l10n.tr("thread.elicitation.submit"), primary: true) {
                    guard !inFlight else { return }
                    answeredRequestID = requestId
                    if elicitation.kind == "form" {
                        var payload: [String: JSONValue] = [:]
                        for f in elicitation.fields {
                            if f.type == "boolean" {
                                payload[f.key] = .bool(boolValues[f.key] ?? (f.defaultValue?.boolValue ?? false))
                            } else if f.type == "number" {
                                let raw = textValues[f.key] ?? f.defaultValue?.stringValue ?? ""
                                if let num = Double(raw) { payload[f.key] = .number(num) }
                            } else {
                                let raw = textValues[f.key] ?? f.defaultValue?.stringValue ?? f.choices.first?.value ?? ""
                                if !raw.isEmpty || f.required { payload[f.key] = .string(raw) }
                            }
                        }
                        onRespond(requestId, nil, payload)
                    } else {
                        let allowOpt = options.first(where: { $0.kind.contains("allow") })?.id ?? options.first?.id
                        onRespond(requestId, allowOpt, nil)
                    }
                }
                ProtocolActionButton(title: l10n.tr("thread.entry.cancel"), primary: false) {
                    guard !inFlight else { return }
                    answeredRequestID = requestId
                    let rejectOpt = options.first(where: { $0.kind.contains("reject") })?.id
                    onRespond(requestId, rejectOpt, nil)
                }
            }
            .disabled(inFlight)
            .opacity(inFlight ? 0.55 : 1)
        }
        .task(id: answeredRequestID) {
            // A request the host never clears (a failed send) must not stay locked forever.
            guard answeredRequestID != nil else { return }
            try? await Task.sleep(for: threadAnswerLockTimeout)
            guard !Task.isCancelled else { return }
            answeredRequestID = nil
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous).fill(tokens.surface1))
        .overlay(RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous).strokeBorder(tokens.warning.opacity(0.45), lineWidth: 1))
    }
}

/// How long an answered card waits for the host to clear its request before it accepts another
/// answer, matching the overlay cards.
let threadAnswerLockTimeout: Duration = .seconds(10)

private struct ProtocolActionButton: View {
    @Environment(\.prismTokens) private var tokens
    let title: String
    let primary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(primary ? Color.white : tokens.secondaryForeground)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                        .fill(primary ? tokens.primary : tokens.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                        .strokeBorder(primary ? Color.clear : tokens.borderEtched, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

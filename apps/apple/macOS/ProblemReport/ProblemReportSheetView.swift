import AppKit
import PrismDesign
import SartoProtocol
import SwiftUI
import UniformTypeIdentifiers

struct ProblemReportSheetView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    let request: ProblemReportLaunchRequest
    @Bindable var state: SartoState
    @Bindable var daemon: LocalDaemonManager
    @Bindable var coordinator: ProblemReportCoordinator
    let onOpenSignIn: () -> Void

    private enum Mode: Equatable {
        case form
        case inspect
        case submitted(ReportSubmitResultInfo)
    }

    private enum DraftState: Equatable {
        case idle
        case writing
        case written(agent: String?)
        case unavailable(reason: String?)
    }

    @State private var mode: Mode = .form
    @State private var descriptionText: String = ""
    @State private var draftSettled = false
    @State private var hasPrefill = false
    @State private var draftState: DraftState = .idle
    @State private var rangeKind: String = "hour"
    @State private var selectedExtras: Set<String> = []

    @State private var isPreparing = false
    @State private var isSubmitting = false
    @State private var prepared: PreparedReportInfo? = nil
    @State private var preparedSignature: String = ""
    @State private var remoteSubmitRef: String? = nil

    @State private var selectedFilePath: String? = nil
    @State private var fileView: ReportFileViewInfo? = nil
    @State private var isLoadingFile = false
    @State private var cachedFileViews: [String: ReportFileViewInfo] = [:]

    @State private var errorBanner: String? = nil
    @State private var savedBanner: String? = nil
    @State private var copiedId = false
    @State private var draftTask: Task<Void, Never>? = nil

    @State private var reportTask: Task<Void, Never>?
    private var reportHostId: String { request.remoteHostId ?? SartoState.localHostID }
    private var isRemote: Bool { request.remoteHostId != nil }
    private var isSignedIn: Bool { state.cloudAccountStatus.account.isSignedIn }
    private var accountLabel: String {
        let acc = state.cloudAccountStatus.account.account
        if let email = acc?.email, !email.isEmpty { return email }
        if let name = acc?.name, !name.isEmpty { return name }
        return "Sarto"
    }
    private var hasSensitiveExtra: Bool {
        selectedExtras.contains("messages") || selectedExtras.contains("verbose") || selectedExtras.contains("dumps")
    }
    private var currentSignature: String {
        "\(descriptionText.trimmingCharacters(in: .whitespacesAndNewlines))|\(rangeKind)|\(selectedExtras.sorted().joined(separator: ","))"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            switch mode {
            case .form:
                formBody
            case .inspect:
                inspectBody
            case .submitted(let result):
                submittedBody(result)
            }

            Rectangle().fill(tokens.borderEtched).frame(height: 1)
            footerBar
        }
        .frame(minWidth: 680, idealWidth: 780, maxWidth: 880, minHeight: 540, idealHeight: 620, maxHeight: 740)
        .background(tokens.surface1)
        .onAppear {
            rangeKind = request.initialRange
            selectedExtras = request.initialExtras
            if isRemote {
                selectedExtras.remove("screenshot")
            }
            let supplied = !request.initialDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if supplied {
                descriptionText = request.initialDescription
                hasPrefill = false
                draftState = .idle
            } else {
                let agentName = request.agentId.map { id in
                    state.agents.first(where: { $0.id == id })?.name ?? id
                }
                let prefill = Self.makePrefill(
                    origin: request.origin,
                    agentName: agentName,
                    error: request.errorText,
                    l10n: l10n
                )
                descriptionText = prefill
                hasPrefill = !prefill.isEmpty
                startBackgroundDraft()
            }
        }
        .onDisappear {
            reportTask?.cancel()
            draftTask?.cancel()
            dropPreparedIfNeeded()
        }
        .onChange(of: rangeKind) { _, _ in invalidatePrepared() }
        .onChange(of: selectedExtras) { _, _ in invalidatePrepared() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .fill(tokens.prismCobalt.opacity(0.14))
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tokens.prismCobalt)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    request.remoteHostName.map { l10n.tr("report.sheet.titleHost", $0) }
                        ?? l10n.tr("report.sheet.title")
                )
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tokens.foreground)
                Text(l10n.tr("report.sheet.subtitle"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(tokens.mutedForeground)
            }

            Spacer(minLength: 8)

            accountStatusPill
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(tokens.surface2.opacity(0.45))
    }

    private var accountStatusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isSignedIn ? tokens.success : tokens.prismAmber)
                .frame(width: 6, height: 6)
            Text(
                isSignedIn
                    ? l10n.tr("report.sheet.signedInBadge", accountLabel)
                    : l10n.tr("report.sheet.anonymousBadge")
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tokens.secondaryForeground)
            .lineLimit(1)

            if !isSignedIn {
                Button(l10n.tr("report.sheet.signIn")) {
                    reportTask?.cancel()
                    dismiss()
                    onOpenSignIn()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tokens.prismCobalt)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(tokens.surface2))
        .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
    }

    // MARK: - Compose Form

    private var formBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let errorBanner {
                    bannerView(text: errorBanner, isError: true)
                }
                if let savedBanner {
                    bannerView(text: savedBanner, isError: false)
                }

                // 1. Description
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(l10n.tr("report.sheet.whatHappened"))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(tokens.foreground)
                        Spacer()
                        Text("\(descriptionText.count) / 10,000")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(descriptionText.count > 10_000 ? tokens.danger : tokens.mutedForeground)
                    }

                    ZStack(alignment: .topLeading) {
                        TextEditor(
                            text: Binding(
                                get: { descriptionText },
                                set: { next in
                                    if next != descriptionText {
                                        settleDraft(clearBadge: true)
                                        descriptionText = String(next.prefix(10_000))
                                        invalidatePrepared()
                                    }
                                }
                            )
                        )
                        .font(.system(size: 13))
                        .foregroundStyle(tokens.foreground)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 116, maxHeight: 168)
                        .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.background))
                        .overlay(
                            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                .strokeBorder(tokens.borderEtched, lineWidth: 1)
                        )

                        if descriptionText.isEmpty {
                            Text(l10n.tr("report.sheet.placeholder"))
                                .font(.system(size: 13))
                                .foregroundStyle(tokens.mutedForeground.opacity(0.75))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 10)
                                .allowsHitTesting(false)
                        }
                    }

                    if draftState != .idle || (request.errorText?.isEmpty == false) {
                        draftStatusRow
                    }

                    if let err = request.errorText, !err.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(tokens.prismCobalt)
                                .padding(.top, 1)
                            Text(err.prefix(240))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(tokens.mutedForeground)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.surface2.opacity(0.6)))
                    }
                }

                // 2. Time range
                VStack(alignment: .leading, spacing: 6) {
                    Text(l10n.tr("report.sheet.logsFrom"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                    Picker("", selection: $rangeKind) {
                        Text(l10n.tr("report.range.hour")).tag("hour")
                        Text(l10n.tr("report.range.today")).tag("today")
                        Text(l10n.tr("report.range.twoDays")).tag("twoDays")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)
                }

                // 3. Optional extras
                VStack(alignment: .leading, spacing: 8) {
                    Text(l10n.tr("report.sheet.alsoInclude"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(tokens.foreground)

                    VStack(alignment: .leading, spacing: 7) {
                        extraRow("titles", label: l10n.tr("report.extra.titles"), sensitive: false)
                        extraRow("messages", label: l10n.tr("report.extra.messages"), sensitive: true)
                        extraRow("verbose", label: l10n.tr("report.extra.verbose"), sensitive: true)
                        extraRow("dumps", label: l10n.tr("report.extra.dumps"), sensitive: true)
                        if !isRemote && request.capturedScreenshotBase64 != nil {
                            extraRow("screenshot", label: l10n.tr("report.extra.screenshot"), sensitive: false)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.background))
                    .overlay(
                        RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                            .strokeBorder(tokens.borderEtched, lineWidth: 1)
                    )
                }

                // 4. Privacy notice
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: hasSensitiveExtra ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(hasSensitiveExtra ? tokens.warning : tokens.success)
                        .padding(.top, 1)
                    Text(l10n.tr(hasSensitiveExtra ? "report.sheet.privacyWarn" : "report.sheet.privacySafe"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.secondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                        .fill((hasSensitiveExtra ? tokens.warning : tokens.success).opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                        .strokeBorder((hasSensitiveExtra ? tokens.warning : tokens.success).opacity(0.28), lineWidth: 1)
                )
            }
            .padding(18)
        }
    }

    private func extraRow(_ key: String, label: String, sensitive: Bool) -> some View {
        let isOn = Binding(
            get: { selectedExtras.contains(key) },
            set: { next in
                if next { selectedExtras.insert(key) } else { selectedExtras.remove(key) }
            }
        )
        return Toggle(isOn: isOn) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(tokens.foreground)
                if sensitive {
                    Text(l10n.tr("report.sheet.sensitiveBadge"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tokens.warning)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(tokens.warning.opacity(0.14)))
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    // MARK: - Bundle Contents Inspector

    private var inspectBody: some View {
        VStack(spacing: 0) {
            if let errorBanner {
                bannerView(text: errorBanner, isError: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }
            if let prepared {
                let files = prepared.files ?? []
                HStack(spacing: 10) {
                    Text(l10n.tr("report.sheet.bundleSummary", files.count, formatBytes(prepared.size ?? 0)))
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(tokens.secondaryForeground)

                    if let count = prepared.redactionCount, count > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 10.5))
                            Text(l10n.tr("report.sheet.redactedSummary", count))
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(tokens.success)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(tokens.success.opacity(0.12)))
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(tokens.surface2.opacity(0.35))

                Rectangle().fill(tokens.borderEtched).frame(height: 1)

                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(files) { file in
                                let isSelected = selectedFilePath == file.path
                                Button {
                                    selectFile(file)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: iconForFile(file))
                                            .font(.system(size: 11))
                                            .foregroundStyle(file.isSensitive ? tokens.warning : tokens.mutedForeground)
                                            .frame(width: 14)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(file.path)
                                                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular, design: .monospaced))
                                                .foregroundStyle(tokens.foreground)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            HStack(spacing: 5) {
                                                Text(formatBytes(file.size))
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundStyle(tokens.mutedForeground)
                                                if file.isSensitive {
                                                    Text(l10n.tr("report.sheet.sensitiveBadge"))
                                                        .font(.system(size: 9.5, weight: .semibold))
                                                        .foregroundStyle(tokens.warning)
                                                }
                                            }
                                        }
                                        Spacer(minLength: 4)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                                            .fill(isSelected ? tokens.activeWash : Color.clear)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(8)
                    }
                    .frame(width: 245)
                    .background(tokens.background.opacity(0.65))

                    Rectangle().fill(tokens.borderEtched).frame(width: 1)

                    filePreviewPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(tokens.background)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(l10n.tr("report.sheet.preparing"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(tokens.mutedForeground)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var filePreviewPane: some View {
        if isLoadingFile {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let view = fileView {
            switch view.kind {
            case "image":
                if let url = view.dataUrl, let img = decodeDataURLImage(url) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 480)
                            .clipShape(RoundedRectangle(cornerRadius: tokens.rSM))
                            .overlay(
                                RoundedRectangle(cornerRadius: tokens.rSM)
                                    .strokeBorder(tokens.borderEtched, lineWidth: 1)
                            )
                            .padding(16)
                    }
                } else {
                    Text(l10n.tr("report.sheet.imageUndecodable"))
                        .font(.system(size: 12))
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case "text":
                VStack(alignment: .leading, spacing: 0) {
                    if view.truncated == true {
                        Text(l10n.tr("report.sheet.truncated"))
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.warning)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(tokens.warning.opacity(0.1))
                    }
                    ScrollView([.horizontal, .vertical]) {
                        Text(view.text ?? "")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(tokens.foreground)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            default:
                let size = prepared?.files?.first(where: { $0.path == selectedFilePath })?.size ?? 0
                Text(l10n.tr("report.sheet.binaryNote", formatBytes(size)))
                    .font(.system(size: 12))
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            Text(l10n.tr("report.sheet.viewContents"))
                .font(.system(size: 12))
                .foregroundStyle(tokens.mutedForeground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Submitted Success Screen

    private func submittedBody(_ result: ReportSubmitResultInfo) -> some View {
        let reportId = result.id ?? "SR-??????"
        let isAnon = result.anonymous ?? !isSignedIn
        return VStack(spacing: 18) {
            Spacer(minLength: 16)
            ZStack {
                Circle()
                    .fill(tokens.success.opacity(0.14))
                    .frame(width: 56, height: 56)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(tokens.success)
            }

            VStack(spacing: 6) {
                Text(l10n.tr("report.sheet.submittedTitle"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                Text(l10n.tr("report.sheet.submittedBody"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(tokens.secondaryForeground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            HStack(spacing: 10) {
                Text(reportId)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(tokens.foreground)
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(reportId, forType: .string)
                    copiedId = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.8))
                        copiedId = false
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: copiedId ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                        Text(l10n.tr(copiedId ? "report.sheet.copied" : "report.sheet.copyId"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(copiedId ? tokens.success : tokens.foreground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(tokens.surface2))
                    .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: tokens.rMD).fill(tokens.background))
            .overlay(RoundedRectangle(cornerRadius: tokens.rMD).strokeBorder(tokens.borderEtched, lineWidth: 1))

            HStack(spacing: 10) {
                if let consoleUrl = result.consoleUrl, !isAnon, let url = URL(string: consoleUrl) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right.square")
                            Text(l10n.tr("report.sheet.openConsole"))
                        }
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: tokens.rSM).fill(tokens.prismCobalt))
                    }
                    .buttonStyle(.plain)
                }

                if let issueUrl = result.issueUrl, let url = URL(string: issueUrl) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right")
                            Text(l10n.tr("report.sheet.openGithub"))
                        }
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(tokens.foreground)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: tokens.rSM).fill(tokens.surface2))
                        .overlay(RoundedRectangle(cornerRadius: tokens.rSM).strokeBorder(tokens.borderEtched, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            if isAnon {
                Text(l10n.tr("report.sheet.submittedAnonNote"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(tokens.mutedForeground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            Spacer(minLength: 16)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer Action Bar

    private var footerBar: some View {
        HStack(spacing: 10) {
            if case .submitted = mode {
                Spacer()
                Button(l10n.tr("report.sheet.done")) {
                    reportTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(tokens.prismCobalt)
            } else {
                Button {
                    if mode == .inspect {
                        withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                            mode = .form
                        }
                    } else {
                        startReportAction { await openInspector() }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode == .inspect ? "chevron.left" : "doc.text.magnifyingglass")
                            .font(.system(size: 11.5))
                        Text(l10n.tr(mode == .inspect ? "report.sheet.backToForm" : "report.sheet.viewContents"))
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(tokens.foreground)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: tokens.rSM).fill(tokens.surface2))
                    .overlay(RoundedRectangle(cornerRadius: tokens.rSM).strokeBorder(tokens.borderEtched, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(isPreparing || isSubmitting)

                if isPreparing || isSubmitting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(l10n.tr(isSubmitting ? "report.sheet.submitting" : "report.sheet.preparing"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(tokens.mutedForeground)
                    }
                }

                Spacer()

                Button(l10n.tr("thread.entry.cancel")) {
                    reportTask?.cancel()
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(tokens.secondaryForeground)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .disabled(isSubmitting)

                Button {
                    startReportAction { await saveLocally() }
                } label: {
                    Text(l10n.tr("report.sheet.saveLocally"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(tokens.foreground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: tokens.rSM).fill(tokens.surface2))
                        .overlay(RoundedRectangle(cornerRadius: tokens.rSM).strokeBorder(tokens.borderEtched, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(isPreparing || isSubmitting)

                Button {
                    startReportAction { await submitToCloud() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 11))
                        Text(l10n.tr(isSignedIn ? "report.sheet.submit" : "report.sheet.submitAnonymous"))
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: tokens.rSM).fill(tokens.prismCobalt))
                }
                .buttonStyle(.plain)
                .disabled(isPreparing || isSubmitting)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(tokens.surface2.opacity(0.35))
    }

    // MARK: - Actions & Lifecycle

    private func bannerView(text: String, isError: Bool) -> some View {
        let accent = isError ? tokens.danger : tokens.success
        return HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(accent)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(tokens.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: tokens.rSM).fill(accent.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: tokens.rSM).strokeBorder(accent.opacity(0.32), lineWidth: 1))
    }

    @ViewBuilder
    private var draftStatusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if case .writing = draftState {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(draftStatusMessage)
                .font(.system(size: 11))
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var draftStatusMessage: String {
        var parts: [String] = []
        switch draftState {
        case .idle:
            break
        case .writing:
            parts.append(l10n.tr("report.sheet.drafting"))
        case .written(let agent):
            if let agent, !agent.isEmpty {
                parts.append(l10n.tr("report.sheet.draftedBy", agent))
            } else {
                parts.append(l10n.tr("report.sheet.draftedPlain"))
            }
        case .unavailable(let reason):
            if hasPrefill {
                parts.append(l10n.tr("report.sheet.draftUnavailableWithPrefill"))
            } else if let reason, !reason.isEmpty {
                parts.append(l10n.tr("report.sheet.draftUnavailableReason", reason))
            } else {
                parts.append(l10n.tr("report.sheet.draftUnavailable"))
            }
        }
        if let err = request.errorText, !err.isEmpty {
            parts.append(l10n.tr("report.sheet.contextIncluded"))
        }
        return parts.joined(separator: " ")
    }

    private func settleDraft(clearBadge: Bool = false) {
        draftSettled = true
        draftTask?.cancel()
        if clearBadge {
            draftState = .idle
        } else if case .writing = draftState {
            draftState = .idle
        }
    }

    private func startBackgroundDraft() {
        guard state.connectionMode.isLive else { return }
        draftTask?.cancel()
        draftState = .writing
        draftTask = Task { @MainActor in
            do {
                let result = try await state.draftProblemReport(
                    origin: request.origin,
                    sessionId: request.sessionId,
                    agentId: request.agentId,
                    error: request.errorText,
                    onHost: reportHostId
                )
                guard !Task.isCancelled, !draftSettled else { return }
                if let draft = result.draft?.trimmingCharacters(in: .whitespacesAndNewlines), !draft.isEmpty {
                    descriptionText = String(draft.prefix(10_000))
                    draftState = .written(agent: result.agent)
                    invalidatePrepared()
                } else {
                    draftState = .idle
                }
            } catch {
                guard !Task.isCancelled, !draftSettled else { return }
                let msg = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                draftState = hasPrefill || !msg.isEmpty ? .unavailable(reason: msg.isEmpty ? nil : msg) : .idle
            }
        }
    }

    private static func briefError(_ error: String) -> String {
        let lines = error
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(3)
        let joined = lines.joined(separator: "\n")
        if joined.count <= 400 { return joined }
        return String(joined.prefix(400)) + "…"
    }

    private static func makePrefill(
        origin: String?,
        agentName: String?,
        error: String?,
        l10n: PrismL10n
    ) -> String {
        let brief = error.map(briefError) ?? ""
        let what: String
        if origin == "turn" {
            if let agentName, !agentName.isEmpty {
                what = l10n.tr("report.prefill.turnOf", agentName)
            } else {
                what = l10n.tr("report.prefill.turn")
            }
        } else if let origin, ["error", "artifact", "usage", "host", "crash"].contains(origin) {
            what = l10n.tr("report.prefill.\(origin)")
        } else if !brief.isEmpty {
            what = l10n.tr("report.prefill.error")
        } else {
            what = ""
        }
        guard !brief.isEmpty else { return what }
        return "\(what)\n\n\(l10n.tr("report.prefill.shown", brief))"
    }

    private func startReportAction(_ run: @escaping @MainActor () async -> Void) {
        guard reportTask == nil else { return }
        reportTask = Task { @MainActor in
            defer { reportTask = nil }
            guard !Task.isCancelled else { return }
            await run()
        }
    }

    private func invalidatePrepared() {
        if prepared != nil {
            dropPreparedIfNeeded()
        }
        cachedFileViews.removeAll()
        fileView = nil
        selectedFilePath = nil
        remoteSubmitRef = nil
    }

    private func dropPreparedIfNeeded() {
        if let id = prepared?.id {
            prepared = nil
            preparedSignature = ""
            Task { try? await daemon.dropProblemReport(id: id) }
        }
    }

    @discardableResult
    private func ensurePrepared() async -> PreparedReportInfo? {
        settleDraft()
        errorBanner = nil
        let trimmed = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorBanner = l10n.tr("report.error.emptyDescription")
            return nil
        }
        if let existing = prepared, existing.ok, existing.id != nil, preparedSignature == currentSignature {
            return existing
        }

        dropPreparedIfNeeded()
        cachedFileViews.removeAll()
        remoteSubmitRef = nil
        isPreparing = true
        defer { isPreparing = false }

        let signature = currentSignature
        let range = rangeKind
        let extras = Array(selectedExtras).sorted()
        var submitRef: String?
        do {
            let built: PreparedReportInfo
            if isRemote {
                let remote = try await state.requestRemoteHostReport(
                    description: trimmed,
                    rangeKind: range,
                    extras: extras,
                    sessionId: request.sessionId,
                    agentId: request.agentId,
                    error: request.errorText,
                    onHost: reportHostId
                )
                guard remote.ok, let zip = remote.zip, let files = remote.files, let ref = remote.ref else {
                    errorBanner = remote.reason == "too_large"
                        ? l10n.tr("report.error.tooLarge")
                        : "Failed to build report on remote host"
                    return nil
                }
                try Task.checkCancellation()
                submitRef = ref
                built = try await daemon.adoptProblemReport(
                    zipBase64: zip,
                    files: files,
                    redactionCount: remote.redactionCount
                )
            } else {
                let client = await ProblemReportCoordinator.collectClientDiagnostics(
                    rangeKind: range,
                    includeCrashReports: extras.contains("dumps"),
                    screenshotBase64: extras.contains("screenshot") ? request.capturedScreenshotBase64 : nil,
                    recentDaemonManagerLogs: daemon.recentLogs
                )
                try Task.checkCancellation()
                built = try await daemon.prepareProblemReport(
                    description: trimmed,
                    rangeKind: range,
                    extras: extras,
                    sessionId: request.sessionId,
                    agentId: request.agentId,
                    error: request.errorText,
                    client: client
                )
            }
            guard built.ok, built.id != nil else {
                errorBanner = built.reason == "too_large"
                    ? l10n.tr("report.error.tooLarge")
                    : (built.message ?? "Failed to build problem report")
                return nil
            }
            guard !Task.isCancelled, signature == currentSignature else {
                if let id = built.id { try? await daemon.dropProblemReport(id: id) }
                return nil
            }
            remoteSubmitRef = submitRef
            prepared = built
            preparedSignature = signature
            return built
        } catch {
            errorBanner = error.localizedDescription
            return nil
        }
    }

    private func openInspector() async {
        guard let built = await ensurePrepared() else { return }
        withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
            mode = .inspect
        }
        if let first = built.files?.first {
            selectFile(first)
        }
    }

    private func selectFile(_ file: ReportFileInfo) {
        selectedFilePath = file.path
        if let cached = cachedFileViews[file.path] {
            fileView = cached
            return
        }
        guard let id = prepared?.id else { return }
        isLoadingFile = true
        let targetPath = file.path
        Task { @MainActor in
            defer {
                if selectedFilePath == targetPath { isLoadingFile = false }
            }
            do {
                let view = try await daemon.readProblemReportFile(id: id, path: targetPath)
                cachedFileViews[targetPath] = view
                if selectedFilePath == targetPath {
                    fileView = view
                }
            } catch {
                if selectedFilePath == targetPath {
                    errorBanner = error.localizedDescription
                }
            }
        }
    }

    private func saveLocally() async {
        guard let built = await ensurePrepared(), !Task.isCancelled, preparedSignature == currentSignature, let id = built.id else { return }
        let panel = NSSavePanel()
        panel.title = l10n.tr("report.sheet.savePanelTitle")
        panel.message = l10n.tr("report.sheet.savePanelMessage")
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = Self.defaultZipFilename()
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        do {
            let saved = try await daemon.saveProblemReport(id: id, destination: dest.path, overwrite: true)
            savedBanner = l10n.tr("report.sheet.savedNotice", saved.path)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: saved.path)])
            await markThreadReportAnsweredIfNeeded(outcomeKind: "saved", reportId: nil)
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    private func submitToCloud() async {
        guard let built = await ensurePrepared(), !Task.isCancelled, preparedSignature == currentSignature, let id = built.id else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        errorBanner = nil

        do {
            let result: ReportSubmitResultInfo
            if isRemote, let ref = remoteSubmitRef {
                result = try await state.submitRemoteHostReport(ref: ref, allowAnonymous: true, onHost: reportHostId)
            } else {
                result = try await daemon.submitProblemReport(id: id, allowAnonymous: true)
            }
            if result.ok {
                prepared = nil
                preparedSignature = ""
                remoteSubmitRef = nil
                coordinator.notifyReportSubmitted()
                await markThreadReportAnsweredIfNeeded(outcomeKind: "sent", reportId: result.id)
                withAnimation(PrismSpringSpec.default.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                    mode = .submitted(result)
                }
            } else {
                errorBanner = localizedSubmitError(result)
            }
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    private func markThreadReportAnsweredIfNeeded(outcomeKind: String, reportId: String?) async {
        guard let sessionId = request.sessionId, let entryId = request.threadEntryId else { return }
        await state.answerProblemReport(
            sessionId: sessionId,
            entryId: entryId,
            outcomeKind: outcomeKind,
            reportId: reportId,
            onHost: reportHostId
        )
    }

    private func localizedSubmitError(_ result: ReportSubmitResultInfo) -> String {
        switch result.reason {
        case "too_large":
            return l10n.tr("report.error.tooLarge")
        case "rate_limited":
            return l10n.tr("report.error.rateLimited", result.retryAfter ?? 60)
        case "limit_reached":
            return l10n.tr("report.error.limitReached")
        case "network":
            return l10n.tr("report.error.network")
        default:
            return result.message ?? "Could not submit problem report"
        }
    }

    private func iconForFile(_ file: ReportFileInfo) -> String {
        if file.kind == "image" { return "photo" }
        if file.path.hasPrefix("crash/") { return "exclamationmark.triangle" }
        if file.path.hasPrefix("logs/") { return "doc.plaintext" }
        if file.path.hasSuffix(".json") { return "curlybraces" }
        return "doc"
    }

    private func decodeDataURLImage(_ dataUrl: String) -> NSImage? {
        guard let comma = dataUrl.firstIndex(of: ",") else { return nil }
        let b64 = String(dataUrl[dataUrl.index(after: comma)...])
        guard let data = Data(base64Encoded: b64) else { return nil }
        return NSImage(data: data)
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
        if bytes >= 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        }
        return "\(bytes) B"
    }

    private static func defaultZipFilename() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return "sarto-report-\(fmt.string(from: Date())).zip"
    }
}

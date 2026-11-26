import AppKit
import SartoProtocol
import PrismDesign
import SwiftUI

// The install sheet every Install opens first (Sarto's install window): the ways to install a
// harness and, for the one picked, what it installs, which version, where it comes from, the
// folder it goes into, its size when known and what it needs, before anything runs. Also the
// confirmation an update of the user's own program shows its command in, and what each fix's
// button does on this Mac.

/// How a surface writes the host settings an install touches. Settings › Agents writes through its
/// store, so the values it shows stay current; the workbench writes straight to the host.
struct AgentHostSettings {
    let patch: @MainActor ([String: JSONValue]) async throws -> Void
    let setBinary: @MainActor (_ harnessId: String, _ path: String) async throws -> Void

    /// The agent host's own settings calls over a remote link, the local daemon's control socket
    /// otherwise.
    @MainActor
    static func direct(state: SartoState, daemon: LocalDaemonManager) -> AgentHostSettings {
        AgentHostSettings(
            patch: { patch in
                if state.connectionMode.isRemote, let host = state.activeHostSession {
                    _ = try await host.adminSettingsUpdate(patch)
                } else {
                    _ = try await daemon.updateHostSettings(patch)
                }
            },
            setBinary: { harnessId, path in
                if state.connectionMode.isRemote, let host = state.activeHostSession {
                    _ = try await host.adminSetAgentBinary(harnessId: harnessId, path: path)
                } else {
                    _ = try await daemon.setHostAgentBinary(harnessId: harnessId, path: path)
                }
            }
        )
    }

    /// A harness installed from Sarto gets its default agent, unless it has one already.
    @MainActor
    func registerInstalled(_ agentId: String, state: SartoState) async {
        await state.refreshAgentStatus(agentId)
        guard let status = state.agents.first(where: { $0.id == agentId }),
              status.registered == false,
              status.uninstalled != true,
              status.task == nil,
              status.state == "available"
        else { return }
        let harness = status.harnessId ?? status.id
        try? await patch(["agents": .object([harness: .object(["enabled": .bool(true)])])])
        await state.refreshAgentStatus(agentId)
    }

    /// Asks for the harness's program in an open panel and runs that one from now on.
    @MainActor
    func chooseProgram(for agentId: String, state: SartoState, onError: @escaping @MainActor (String) -> Void) {
        let harness = state.agents.first(where: { $0.id == agentId })?.harnessId ?? agentId
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let setBinary = setBinary
        Task {
            do {
                try await setBinary(harness, url.path)
                await state.refreshAgentStatus(agentId)
            } catch {
                onError(error.localizedDescription)
            }
        }
    }
}

/// What a fix's button does on this Mac.
@MainActor
enum AgentFixRunner {
    static func run(
        _ agentId: String,
        state: SartoState,
        surface: AgentActionSurface,
        settings: AgentHostSettings,
        openSettings: () -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        guard let entry = state.agentAvailability[agentId], let fix = entry.fix else { return }
        switch fix {
        case .install:
            state.requestAgentInstall(agentId, from: surface)
        case .openGuide(let tool):
            if let url = tool.guideURL { NSWorkspace.shared.open(url) }
        case .updateProgram(let command):
            state.requestAgentUpdate(agentId, command: command, from: surface)
        case .chooseProgram:
            settings.chooseProgram(for: agentId, state: state, onError: onError)
        case .retry:
            Task {
                do {
                    try await state.retryAgentStart(agentId)
                } catch {
                    onError(error.localizedDescription)
                }
            }
        case .openSettings:
            openSettings()
        }
    }
}

/// Shows the install sheet and the update confirmation a surface was asked for.
struct AgentAvailabilityPresenter: ViewModifier {
    @Bindable var state: SartoState
    let surface: AgentActionSurface
    let settings: AgentHostSettings

    private var installBinding: Binding<AgentAvailabilityRequest?> {
        let model = state.agentAvailabilityModel
        let surface = surface
        return Binding(
            get: {
                guard let request = model.request, request.surface == surface, request.kind == .install else { return nil }
                return request
            },
            set: { next in
                if next == nil, let current = model.request, current.surface == surface, current.kind == .install {
                    model.request = nil
                }
            }
        )
    }

    private var updateRequest: (request: AgentAvailabilityRequest, command: String)? {
        guard let request = state.agentAvailabilityModel.request, request.surface == surface,
              case .confirmUpdate(let command) = request.kind
        else { return nil }
        return (request, command)
    }

    func body(content: Content) -> some View {
        let tokens = state.tokens
        let l10n = state.l10n
        let update = updateRequest
        let name: String? = update.map { pending in
            state.agents.first(where: { $0.id == pending.request.agentId })?.harnessName
                ?? state.agentDisplayName(for: pending.request.agentId)
        }
        content
            .sheet(item: installBinding) { request in
                AgentInstallSheet(state: state, agentId: request.agentId, settings: settings)
                    .focusEffectDisabled()
                    .environment(\.prismTokens, tokens)
                    .environment(\.prismL10n, l10n)
                    .environment(\.locale, state.language.resolvedLocale)
                    .preferredColorScheme(state.palette.colorScheme)
            }
            .alert(
                l10n.tr("agents.update.title", name ?? ""),
                isPresented: Binding(
                    get: { update != nil },
                    set: { shown in
                        if !shown, let id = update?.request.id { state.dismissAgentRequest(id) }
                    }
                ),
                presenting: update
            ) { update in
                Button(l10n.tr("agents.update.run")) {
                    let agentId = update.request.agentId
                    state.dismissAgentRequest(update.request.id)
                    Task {
                        do {
                            try await state.updateAgentProgram(agentId)
                        } catch {
                            state.agentAvailabilityModel.installErrors[agentId] = error.localizedDescription
                        }
                    }
                }
                Button(l10n.tr("agents.install.cancel"), role: .cancel) {
                    state.dismissAgentRequest(update.request.id)
                }
            } message: { update in
                Text(l10n.tr("agents.update.body", update.command))
            }
    }
}

struct AgentInstallSheet: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    @Bindable var state: SartoState
    let agentId: String
    let settings: AgentHostSettings

    @State private var offer: InstallOffer?
    @State private var loadError: String?
    @State private var pickedRouteID: String?
    @State private var isReloading = false
    @State private var reloadError: String?
    @State private var copiedCommand: String?

    private var status: AgentStatusInfo? {
        state.agents.first { $0.id == agentId }
    }

    private var routes: [InstallRoute] {
        offer?.routes ?? []
    }

    /// The route picked, else the first that can install now, else the first.
    private var route: InstallRoute? {
        routes.first { $0.id == pickedRouteID } ?? routes.first(where: \.installable) ?? routes.first
    }

    var body: some View {
        let status = status
        let name = status?.harnessName ?? status?.name ?? agentId
        let route = route
        let ready = route?.installable == true
        VStack(spacing: 0) {
            header(name: name, status: status)

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if routes.count > 1 {
                        routePicker(routes: routes, selected: route, status: status)
                    }
                    if offer == nil && loadError == nil {
                        factsLoading
                    }
                    if let loadError {
                        noteRow(text: loadError, icon: "exclamationmark.triangle.fill", color: tokens.danger)
                    }
                    if offer != nil, routes.isEmpty, let detail = status?.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(tokens.secondaryForeground)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if let route {
                        facts(route)
                        if let command = route.command, !command.isEmpty {
                            commandField(route: route, command: command)
                        }
                        if route.id != InstallRoute.copyID, let notice = status?.availability.installNotice, !notice.isEmpty {
                            Text(notice)
                                .font(.system(size: 11.5))
                                .foregroundStyle(tokens.secondaryForeground)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        if !route.details.needs.allSatisfy(\.ok) {
                            noteRow(text: l10n.tr("agents.install.needsFirst"), icon: "info.circle.fill", color: tokens.warning)
                        }
                    }
                    if let link = status?.installUrl.flatMap(URL.init(string:)), ["http", "https"].contains(link.scheme?.lowercased() ?? "") {
                        Link(destination: link) {
                            HStack(spacing: 4) {
                                Text(l10n.tr("agents.install.guide"))
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9.5, weight: .semibold))
                            }
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(tokens.primary)
                        }
                    }
                    if status?.availability.program != nil || status?.binaryCommand != nil {
                        Button {
                            chooseElsewhere()
                        } label: {
                            Text(l10n.tr("agents.install.elsewhere"))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(tokens.primary)
                        }
                        .buttonStyle(.plain)
                    }
                    if let reloadError {
                        noteRow(text: reloadError, icon: "exclamationmark.triangle.fill", color: tokens.danger)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 460)

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            footer(route: route, ready: ready)
        }
        .frame(width: 500)
        .background(tokens.surface1)
        .task {
            await takeBackIfUninstalled()
            await loadOffer()
        }
        .onChange(of: status?.state) { _, _ in
            Task { await loadOffer() }
        }
    }

    // MARK: Parts

    private func header(name: String, status: AgentStatusInfo?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tokens.prismCobalt)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(l10n.tr("agents.install.title", name))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                if let status {
                    Text(introText(status: status, name: name))
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(tokens.hoverWash))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(l10n.tr("agents.install.cancel"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func routePicker(routes: [InstallRoute], selected: InstallRoute?, status: AgentStatusInfo?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(l10n.tr("agents.install.method"))
            VStack(spacing: 4) {
                ForEach(Array(routes.enumerated()), id: \.offset) { index, item in
                    let isSelected = item.id == selected?.id && item.firstStart == selected?.firstStart
                    let enabled = item.available || item.firstStart
                    Button {
                        pickedRouteID = item.id
                    } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 12.5))
                                .foregroundStyle(isSelected ? tokens.primary : tokens.mutedForeground)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(routeName(item))
                                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                                        .foregroundStyle(tokens.foreground)
                                    if index == 0 && item.available {
                                        Text(l10n.tr("agents.install.recommended"))
                                            .font(.system(size: 9.5, weight: .semibold))
                                            .foregroundStyle(tokens.success)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(Capsule().fill(tokens.successSoft))
                                    }
                                }
                                if !enabled {
                                    Text(l10n.tr("agents.install.notFound"))
                                        .font(.system(size: 11))
                                        .foregroundStyle(tokens.mutedForeground)
                                } else if routes.first?.id == InstallRoute.copyID, item.id != InstallRoute.copyID,
                                          let command = status?.availability.program?.command {
                                    Text(l10n.tr("agents.install.usesYours", command))
                                        .font(.system(size: 11))
                                        .foregroundStyle(tokens.mutedForeground)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                .fill(isSelected ? tokens.activeWash : tokens.surface2.opacity(0.5))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                .strokeBorder(isSelected ? tokens.primaryBorder : tokens.borderEtched, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.55)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    /// What the picked route installs, as label and value lines.
    private func facts(_ route: InstallRoute) -> some View {
        let details = route.details
        return VStack(alignment: .leading, spacing: 7) {
            if let name = details.what.name {
                factRow(l10n.tr("agents.install.factWhat")) {
                    Text(name).font(.system(size: 12, design: .monospaced))
                }
            }
            factRow(l10n.tr("agents.install.factVersion")) {
                if let version = details.version {
                    Text(version).font(.system(size: 12, design: .monospaced))
                } else {
                    Text(l10n.tr("agents.install.newest")).font(.system(size: 12))
                }
            }
            factRow(l10n.tr("agents.install.factSource")) {
                Text(sourceText(details.source)).font(.system(size: 12))
            }
            if let folder = details.folder {
                factRow(l10n.tr("agents.install.factFolder")) {
                    Text(folder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folder)
                }
            } else if case .package(let kind, _) = details.what, kind == "uvx" {
                factRow(l10n.tr("agents.install.factFolder")) {
                    Text(l10n.tr("agents.install.uvCache")).font(.system(size: 12))
                }
            }
            if let size = details.size {
                factRow(l10n.tr("agents.install.factSize")) {
                    let text = ByteCountFormatter.string(fromByteCount: Int64(size.bytes), countStyle: .file)
                    Text(size.packageOnly ? l10n.tr("agents.install.sizePackage", text) : text)
                        .font(.system(size: 12))
                }
            }
            if !details.needs.isEmpty {
                factRow(l10n.tr("agents.install.factNeeds")) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(details.needs) { need in
                            needRow(need)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.surface2.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))
    }

    private func factRow<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tokens.mutedForeground)
                .frame(width: 74, alignment: .leading)
            value()
                .foregroundStyle(tokens.foreground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func needRow(_ need: InstallNeed) -> some View {
        HStack(spacing: 5) {
            Image(systemName: need.ok ? "checkmark" : "xmark")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(need.ok ? tokens.success : tokens.danger)
                .frame(width: 12)
            Text(needName(need))
                .font(.system(size: 12))
            if !need.ok {
                Text(need.found.map { l10n.tr("agents.install.foundVersion", $0) } ?? l10n.tr("agents.install.notFound"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(tokens.mutedForeground)
            }
        }
    }

    private var factsLoading: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach([140.0, 90.0, 180.0, 220.0], id: \.self) { width in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 3).fill(tokens.surface3.opacity(0.7)).frame(width: 56, height: 9)
                    RoundedRectangle(cornerRadius: 3).fill(tokens.surface3.opacity(0.5)).frame(width: width, height: 9)
                }
            }
        }
        .padding(12)
        .accessibilityLabel(l10n.tr("agents.install.loading"))
    }

    /// The command a vendor's route runs, or the address of the archive it downloads, to copy.
    private func commandField(route: InstallRoute, command: String) -> some View {
        let archive = route.id == "archive"
        return VStack(alignment: .leading, spacing: 6) {
            sectionLabel(l10n.tr(archive ? "agents.install.downloads" : "agents.install.runs"))
            HStack(alignment: .top, spacing: 8) {
                Text(command)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(tokens.foreground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copiedCommand = command
                } label: {
                    Image(systemName: copiedCommand == command ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(copiedCommand == command ? tokens.success : tokens.mutedForeground)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(l10n.tr("agents.install.copy"))
                .accessibilityLabel(l10n.tr("agents.install.copy"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous).fill(tokens.codeBackground))
            .overlay(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))
            Text(l10n.tr(archive ? "agents.install.downloadBody" : "agents.install.ownTerminal"))
                .font(.system(size: 11))
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func footer(route: InstallRoute?, ready: Bool) -> some View {
        let firstStartOnly = route?.firstStart == true && route?.details.needs.allSatisfy(\.ok) == true
        return HStack(spacing: 8) {
            Spacer()
            SheetButton(
                title: l10n.tr(firstStartOnly ? "agents.install.close" : "agents.install.cancel"),
                prominent: false
            ) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            if let route, ready {
                SheetButton(title: l10n.tr("agents.install.button"), prominent: true) {
                    startInstall(route)
                }
                .keyboardShortcut(.defaultAction)
            } else if (offer != nil || loadError != nil) && !firstStartOnly {
                SheetButton(title: l10n.tr("agents.install.reload"), prominent: true, busy: isReloading) {
                    Task { await reloadEnvironment() }
                }
                .disabled(isReloading)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(tokens.placeholder)
            .textCase(.uppercase)
    }

    private func noteRow(text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(tokens.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    // MARK: Copy

    /// The line under the title: who installs what, by the routes the harness has, or while they
    /// load by what its status says, so the line does not change once they arrive.
    private func introText(status: AgentStatusInfo, name: String) -> String {
        let first = offer?.routes.first
        let pkg = status.availability.package
        let program = status.availability.program
        let uvx = offer != nil ? first?.firstStart == true : (pkg == nil && program?.onPath == false)
        let copy = offer != nil ? first?.id == InstallRoute.copyID : (pkg != nil && pkg?.isSdk != true)
        if uvx { return l10n.tr("agents.install.bodyUvx", name) }
        if copy {
            if let program, program.onPath {
                return l10n.tr("agents.install.bodyCopy", name, program.command)
            }
            return l10n.tr("agents.install.bodyCopyPlain", name)
        }
        if offer?.routes.isEmpty == true || (offer == nil && status.availability.installMethods.isEmpty) {
            return l10n.tr("agents.install.setupBody", name)
        }
        return l10n.tr(routes.count == 1 ? "agents.install.bodyOne" : "agents.install.body", name)
    }

    private func routeName(_ route: InstallRoute) -> String {
        switch route.id {
        case InstallRoute.copyID: return l10n.tr("agents.install.copyRoute")
        case "brew": return "Homebrew"
        case "npm": return "npm"
        case "script": return l10n.tr("agents.install.methodScript")
        case "archive": return l10n.tr("agents.install.methodArchive")
        default: return route.id
        }
    }

    /// The host of an address, as the sheet names where a file comes from.
    private func hostOf(_ address: String) -> String {
        guard let url = URL(string: address), let host = url.host, !host.isEmpty else { return address }
        return host
    }

    private func sourceText(_ source: InstallSource) -> String {
        switch source {
        case .npm(let registry):
            return registry.map { l10n.tr("agents.install.fromNpm", hostOf($0)) } ?? l10n.tr("agents.install.fromNpmUnknown")
        case .registry(let url):
            return l10n.tr("agents.install.fromRegistry", hostOf(url))
        case .vendor(let url):
            return hostOf(url)
        case .brew:
            return "Homebrew"
        case .pypi:
            return l10n.tr("agents.install.fromPypi")
        case .unknown(let kind):
            return kind
        }
    }

    private func needName(_ need: InstallNeed) -> String {
        guard need.kind == "node" else { return need.kind }
        return need.minimum.map { l10n.tr("agents.install.needsNode", $0) } ?? "Node.js"
    }

    // MARK: Actions

    /// A harness uninstalled from Sarto is taken back first, so it is detected again; one whose
    /// program is still on the machine is then back without installing anything.
    private func takeBackIfUninstalled() async {
        guard let status, status.uninstalled == true else { return }
        let harness = status.harnessId ?? status.id
        try? await settings.patch(["agents": .object([harness: .object(["uninstalled": .bool(false)])])])
        await state.refreshAgentStatus(agentId)
        guard let back = self.status, back.uninstalled != true, !AgentAvailability.needsInstall(back) else { return }
        await settings.registerInstalled(agentId, state: state)
        dismiss()
    }

    private func loadOffer() async {
        do {
            let next = try await state.installOffer(for: agentId)
            offer = next
            loadError = nil
            if let picked = pickedRouteID, !next.routes.contains(where: { $0.id == picked }) {
                pickedRouteID = nil
            }
        } catch is CancellationError {
            return
        } catch {
            if offer == nil { loadError = error.localizedDescription }
        }
    }

    private func reloadEnvironment() async {
        guard let host = state.activeHostSession else { return }
        isReloading = true
        reloadError = nil
        defer { isReloading = false }
        do {
            let statuses = try await host.reloadAgentEnvironment()
            state.mergeAgentStatuses(statuses)
            await loadOffer()
        } catch {
            reloadError = error.localizedDescription
        }
    }

    /// Its program installed somewhere else: chosen in an open panel, it runs from now on, and the
    /// sheet closes once it is chosen.
    private func chooseElsewhere() {
        let harness = status?.harnessId ?? agentId
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let settings = settings
        Task {
            do {
                try await settings.setBinary(harness, url.path)
                await state.refreshAgentStatus(agentId)
                dismiss()
            } catch {
                reloadError = error.localizedDescription
            }
        }
    }

    /// Starts the install by the route picked and closes the sheet: the install runs on the host,
    /// and the agent's status shows its progress and how it ended.
    private func startInstall(_ route: InstallRoute) {
        let state = state
        let agentId = agentId
        let settings = settings
        Task {
            if await state.installAgent(agentId, route: route) {
                await settings.registerInstalled(agentId, state: state)
            }
        }
        dismiss()
    }
}

/// The sheet's footer button, in the settings pill style.
private struct SheetButton: View {
    @Environment(\.prismTokens) private var tokens
    let title: String
    let prominent: Bool
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.mini)
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(prominent ? tokens.onPrimary : tokens.foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .fill(prominent ? tokens.primary : tokens.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .strokeBorder(prominent ? tokens.primary : tokens.borderEtched, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

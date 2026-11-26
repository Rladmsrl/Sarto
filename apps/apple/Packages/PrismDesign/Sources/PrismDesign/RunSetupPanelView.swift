import SwiftUI

/// The column of the run setup panel that leads, from the pill that opened it.
public enum PrismRunSetupColumn: Sendable, Equatable {
    case agent
    case model
    case run
}

/// The new session's run setup: the agent, its model, and its permission mode and effort, side by
/// side in one panel, so none of them hides behind a scroll or a second popover.
public struct RunSetupPanelView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let sections: [PrismAgentMenuSection]
    public let selectedAgentID: String?
    public let initialFocus: PrismRunSetupColumn
    public let onInspectAgent: (String) -> Void
    public let onChooseAgent: (String) -> Void
    public let onSelectModel: (String, String) -> Void
    public let onSelectMode: (String, String) -> Void
    public let onSelectEffort: (String, String) -> Void
    public let onToggleOption: (String, String, Bool) -> Void
    public let onSetPinnedModels: (@MainActor (String, [String]) async -> String?)?
    public let onFixAgent: ((String) -> Void)?
    public let onDone: () -> Void

    @State private var focus: PrismRunSetupColumn
    @State private var inspectedAgentID: String = ""
    @State private var searchQuery: String = ""
    @State private var showMoreForAgent: Set<String> = []
    @State private var hoveredKey: String? = nil
    @State private var hoveredPinKey: String? = nil
    @State private var managingFavorites: Bool = false
    @State private var pinError: String? = nil
    @State private var pinBusy: Bool = false
    @State private var draggedFavoriteID: String? = nil
    @State private var dropTargetFavoriteID: String? = nil
    @FocusState private var searchFocused: Bool

    private static let maxPinnedModels = PrismModelMenuLayout.numberedCount
    private static let starSlotWidth: CGFloat = 20
    private static let checkSlotWidth: CGFloat = 14

    public init(
        sections: [PrismAgentMenuSection],
        selectedAgentID: String?,
        initialFocus: PrismRunSetupColumn,
        onInspectAgent: @escaping (String) -> Void,
        onChooseAgent: @escaping (String) -> Void,
        onSelectModel: @escaping (String, String) -> Void,
        onSelectMode: @escaping (String, String) -> Void,
        onSelectEffort: @escaping (String, String) -> Void,
        onToggleOption: @escaping (String, String, Bool) -> Void,
        onSetPinnedModels: (@MainActor (String, [String]) async -> String?)? = nil,
        onFixAgent: ((String) -> Void)? = nil,
        onDone: @escaping () -> Void
    ) {
        self.sections = sections
        self.selectedAgentID = selectedAgentID
        self.initialFocus = initialFocus
        self.onInspectAgent = onInspectAgent
        self.onChooseAgent = onChooseAgent
        self.onSelectModel = onSelectModel
        self.onSelectMode = onSelectMode
        self.onSelectEffort = onSelectEffort
        self.onToggleOption = onToggleOption
        self.onSetPinnedModels = onSetPinnedModels
        self.onFixAgent = onFixAgent
        self.onDone = onDone
        _focus = State(initialValue: initialFocus)
    }

    private var query: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredSections: [PrismAgentMenuSection] {
        let q = query
        guard !q.isEmpty else { return sections }
        return sections.filter { sec in
            sec.agent.name.lowercased().contains(q)
                || sec.agent.id.lowercased().contains(q)
                || sec.models.contains { PrismModelMenuLayout.matches($0, query: q) }
        }
    }

    /// The agent the model and run columns show: the one last clicked, else the chosen one.
    private func shownSection(in list: [PrismAgentMenuSection]) -> PrismAgentMenuSection? {
        list.first(where: { $0.id == inspectedAgentID })
            ?? list.first(where: { $0.id == selectedAgentID })
            ?? list.first
    }

    private func moveFocus(_ column: PrismRunSetupColumn) {
        guard focus != column else { return }
        withAnimation(PrismSpringSpec.indicator.animation(tier: motionTier, reduceMotion: reduceMotion)) {
            focus = column
        }
    }

    public var body: some View {
        let list = filteredSections
        let shown = shownSection(in: list)

        VStack(spacing: 0) {
            searchField
                .padding(10)

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            if list.isEmpty {
                Text(l10n.tr("newSession.noMatch"))
                    .font(.system(size: 12))
                    .foregroundStyle(tokens.placeholder)
                    .frame(maxWidth: .infinity)
                    .frame(height: 372)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    agentColumn(list)
                        .frame(width: 192)
                    Rectangle().fill(tokens.borderEtched).frame(width: 1)
                    if let shown {
                        modelColumn(shown)
                            .frame(maxWidth: .infinity)
                        Rectangle().fill(tokens.borderEtched).frame(width: 1)
                        runColumn(shown)
                            .frame(width: 258)
                    } else {
                        Spacer()
                    }
                }
                .frame(height: 372)
            }

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            footer(shown)
        }
        .frame(minWidth: 560, idealWidth: 712, maxWidth: 712)
        .background(tokens.surface1)
        .onAppear {
            let initial = selectedAgentID ?? sections.first?.id ?? ""
            inspectedAgentID = initial
            if !initial.isEmpty { onInspectAgent(initial) }
        }
        .onChange(of: shown?.id) { _, nextID in
            pinError = nil
            draggedFavoriteID = nil
            dropTargetFavoriteID = nil
            if let nextID, !nextID.isEmpty, nextID != inspectedAgentID {
                inspectedAgentID = nextID
                onInspectAgent(nextID)
            }
            if let nextShown = shown, !canManageFavorites(for: nextShown) {
                managingFavorites = false
            }
        }
    }

    // MARK: - Header and footer

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5))
                .foregroundStyle(tokens.placeholder)
            TextField(l10n.tr("newSession.searchAgentsAndModels"), text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(tokens.foreground)
                .focused($searchFocused)
                .onSubmit(onDone)
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.placeholder)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(l10n.tr("runSetup.clearSearch"))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .fill(tokens.surface2.opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(searchFocused ? tokens.primaryBorder : tokens.borderEtched, lineWidth: 1)
        )
    }

    private func footer(_ shown: PrismAgentMenuSection?) -> some View {
        HStack(spacing: 10) {
            if let acct = shown?.agent.accountSummary, !acct.isEmpty {
                Text(acct)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(tokens.placeholder)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            keyHint("↩", l10n.tr("runSetup.hintDone"))
            keyHint("esc", l10n.tr("runSetup.hintClose"))
            Button(action: onDone) {
                EmptyView()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
            Button(action: onDone) {
                Text(l10n.tr("runSetup.done"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(tokens.onPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.primary))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(tokens.surface2.opacity(0.45))
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(tokens.placeholder)
                .padding(.horizontal, 4)
                .frame(minWidth: 18, minHeight: 16)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tokens.hoverWash))
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(tokens.mutedForeground)
        }
        .accessibilityHidden(true)
    }

    private func columnHeader(_ column: PrismRunSetupColumn, title: String, value: String?) -> some View {
        let focused = focus == column
        return Button {
            moveFocus(column)
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(focused ? tokens.primary : tokens.placeholder)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let value, !value.isEmpty {
                    Text(value)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                Rectangle().fill(tokens.borderEtched).frame(height: 1)
                if focused {
                    Capsule()
                        .fill(tokens.primary)
                        .frame(height: 2)
                        .padding(.horizontal, 12)
                }
            }
        }
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Agent column

    private func agentColumn(_ list: [PrismAgentMenuSection]) -> some View {
        let ready = list.filter(\.agent.isAvailable)
        let unavailable = list.filter { !$0.agent.isAvailable }
        return VStack(spacing: 0) {
            columnHeader(.agent, title: l10n.tr("runSetup.agent"), value: nil)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !ready.isEmpty {
                        railLabel(l10n.tr("newSession.readyAgents"), top: 4)
                        ForEach(ready) { agentRow($0) }
                    }
                    if !unavailable.isEmpty {
                        railLabel(l10n.tr("newSession.unavailableAgents"), top: ready.isEmpty ? 4 : 8)
                        ForEach(unavailable) { agentRow($0) }
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func railLabel(_ text: String, top: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(tokens.placeholder)
            .padding(.horizontal, 8)
            .padding(.top, top)
            .padding(.bottom, 2)
    }

    private func agentRow(_ section: PrismAgentMenuSection) -> some View {
        let agent = section.agent
        let picked = agent.id == selectedAgentID
        let inspected = agent.id == (inspectedAgentID.isEmpty ? selectedAgentID : inspectedAgentID)
        let key = "agent::\(agent.id)"
        return Button {
            inspectedAgentID = agent.id
            onInspectAgent(agent.id)
            if agent.isAvailable {
                onChooseAgent(agent.id)
                moveFocus(.model)
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(agent.isAvailable ? agent.brandColor : tokens.placeholder.opacity(0.45))
                    .frame(width: 8, height: 8)
                    .shadow(color: picked ? agent.brandColor.opacity(0.6) : .clear, radius: 4)
                Text(agent.name)
                    .font(.system(size: 12, weight: picked || inspected ? .semibold : .medium))
                    .foregroundStyle(agent.isAvailable ? tokens.foreground : tokens.placeholder)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if let tag = agent.tag {
                    Text(tag.text)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(PrismAgentTagStyle.color(tag.tone, tokens: tokens))
                        .lineLimit(1)
                        .help(tag.title ?? tag.text)
                }
                if picked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(tokens.primary)
                }
            }
            .padding(.horizontal, 8.5)
            .padding(.vertical, 6.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .fill(inspected ? tokens.activeWash : (hoveredKey == key ? tokens.hoverWash : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoveredKey = inside ? key : (hoveredKey == key ? nil : hoveredKey)
        }
        .accessibilityLabel(
            agent.tag.map { l10n.tr("agents.tag.rowState", agent.name, $0.title ?? $0.text) } ?? agent.name
        )
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    // MARK: - Model column

    private func canManageFavorites(for section: PrismAgentMenuSection) -> Bool {
        onSetPinnedModels != nil
            && section.canManagePinnedModels
            && section.agent.isAvailable
            && !section.models.isEmpty
    }

    private func orderedPinnedModels(in section: PrismAgentMenuSection) -> [PrismModelOption] {
        var byID: [String: PrismModelOption] = [:]
        for model in section.models {
            byID[model.id] = model
        }
        var seen = Set<String>()
        var ordered: [PrismModelOption] = []
        for id in section.pinnedModelIDs {
            if seen.insert(id).inserted, let model = byID[id] {
                ordered.append(model)
            }
        }
        return ordered
    }

    private func currentPinnedIDs(in section: PrismAgentMenuSection) -> [String] {
        orderedPinnedModels(in: section).map(\.id)
    }

    private func applyPinnedModels(_ next: [String], for section: PrismAgentMenuSection) {
        guard let onSetPinnedModels, !pinBusy else { return }
        pinBusy = true
        pinError = nil
        let agentID = section.id
        Task {
            let error = await onSetPinnedModels(agentID, next)
            pinBusy = false
            pinError = error
            if let error {
                AccessibilityNotification.Announcement(error).post()
            }
        }
    }

    private func toggleFavorite(_ model: PrismModelOption, in section: PrismAgentMenuSection) {
        let current = currentPinnedIDs(in: section)
        if let idx = current.firstIndex(of: model.id) {
            var next = current
            next.remove(at: idx)
            applyPinnedModels(next, for: section)
        } else if current.count >= Self.maxPinnedModels {
            let msg = l10n.tr("runSetup.favoritesFullHint", Self.maxPinnedModels)
            pinError = msg
            AccessibilityNotification.Announcement(msg).post()
        } else {
            applyPinnedModels(current + [model.id], for: section)
        }
    }

    private func moveFavorite(from sourceIndex: Int, to destinationIndex: Int, in section: PrismAgentMenuSection) {
        var next = currentPinnedIDs(in: section)
        guard next.indices.contains(sourceIndex),
              next.indices.contains(destinationIndex),
              sourceIndex != destinationIndex
        else { return }
        let moved = next.remove(at: sourceIndex)
        next.insert(moved, at: destinationIndex)
        applyPinnedModels(next, for: section)
    }

    private func modelColumn(_ section: PrismAgentMenuSection) -> some View {
        let canManage = canManageFavorites(for: section)
        let isEditingFavorites = managingFavorites && canManage
        let pinnedModels = orderedPinnedModels(in: section)
        let selectedName = section.models.first(where: { $0.id == section.selectedModelID })?.name

        return VStack(spacing: 0) {
            if isEditingFavorites {
                favoritesEditHeader(section: section, pinnedCount: pinnedModels.count)
                favoritesEditBody(section: section, pinnedModels: pinnedModels)
            } else {
                modelColumnHeader(
                    section: section,
                    selectedName: selectedName,
                    canManage: canManage,
                    pinnedCount: pinnedModels.count
                )
                modelBrowseBody(section: section, canManage: canManage)
            }
        }
    }

    private func modelColumnHeader(
        section: PrismAgentMenuSection,
        selectedName: String?,
        canManage: Bool,
        pinnedCount: Int
    ) -> some View {
        let focused = focus == .model
        return HStack(spacing: 6) {
            Button {
                moveFocus(.model)
            } label: {
                HStack(spacing: 6) {
                    Text(l10n.tr("runSetup.model"))
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(focused ? tokens.primary : tokens.placeholder)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let selectedName, !selectedName.isEmpty {
                        Text(selectedName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tokens.secondaryForeground)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if canManage {
                Button {
                    moveFocus(.model)
                    pinError = nil
                    withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                        managingFavorites = true
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: pinnedCount > 0 ? "star.fill" : "star")
                            .font(.system(size: 9.5, weight: .semibold))
                        if pinnedCount > 0 {
                            Text("\(pinnedCount)/\(Self.maxPinnedModels)")
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(pinnedCount > 0 ? tokens.primary : tokens.mutedForeground)
                    .padding(.horizontal, pinnedCount > 0 ? 6 : 5)
                    .frame(height: 20)
                    .background(
                        Capsule()
                            .fill(pinnedCount > 0 ? tokens.primarySoft : tokens.hoverWash.opacity(0.65))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                pinnedCount > 0 ? tokens.primaryBorder : tokens.borderEtched,
                                lineWidth: 0.75
                            )
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(l10n.tr("runSetup.favoritesManage"))
                .accessibilityLabel(l10n.tr("runSetup.favoritesManage"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                Rectangle().fill(tokens.borderEtched).frame(height: 1)
                if focused {
                    Capsule()
                        .fill(tokens.primary)
                        .frame(height: 2)
                        .padding(.horizontal, 12)
                }
            }
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func favoritesEditHeader(section: PrismAgentMenuSection, pinnedCount: Int) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 4.5) {
                Image(systemName: "star.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tokens.primary)
                Text(l10n.tr("runSetup.favoritesTitle"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(1)
                Text("\(pinnedCount)/\(Self.maxPinnedModels)")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(pinnedCount > 0 ? tokens.primary : tokens.mutedForeground)
            }

            Spacer(minLength: 4)

            if pinnedCount > 0 {
                Button {
                    applyPinnedModels([], for: section)
                } label: {
                    Text(l10n.tr("runSetup.favoritesReset"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                                .fill(tokens.hoverWash.opacity(0.65))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(pinBusy)
                .opacity(pinBusy ? 0.5 : 1)
            }

            Button {
                pinError = nil
                withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                    managingFavorites = false
                }
            } label: {
                Text(l10n.tr("runSetup.favoritesDone"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(tokens.onPrimary)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                            .fill(tokens.primary)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                Rectangle().fill(tokens.borderEtched).frame(height: 1)
                Capsule()
                    .fill(tokens.primary)
                    .frame(height: 2)
                    .padding(.horizontal, 12)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var pinErrorBanner: some View {
        if let pinError {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(pinError)
                    .font(.system(size: 10.5))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
            }
            .foregroundStyle(tokens.warning)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                    .fill(tokens.warningSoft)
            )
            .padding(.bottom, 4)
        }
    }

    private func modelBrowseBody(section: PrismAgentMenuSection, canManage: Bool) -> some View {
        let q = query
        let matchesAgent = section.agent.name.lowercased().contains(q)
            || section.agent.id.lowercased().contains(q)
        let searchingModels = !q.isEmpty && !matchesAgent
        let more = PrismModelMenuLayout.split(section.models).more
        let expanded = showMoreForAgent.contains(section.id)
        let modelSections = PrismModelMenuLayout.sections(
            section.models,
            selectedID: section.selectedModelID,
            query: searchingModels ? q : "",
            expanded: expanded
        )
        let shownCount = modelSections.reduce(0) { $0 + $1.models.count }

        return ScrollView {
            VStack(alignment: .leading, spacing: 2.5) {
                if section.agent.problemText != nil || section.agent.fixTitle != nil {
                    PrismAgentProblemCard(agent: section.agent, onFixAgent: onFixAgent)
                        .padding(.bottom, 6)
                }
                pinErrorBanner
                if shownCount == 0 {
                    Text(l10n.tr("composer.noModelsReported"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.placeholder)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                } else {
                    ForEach(modelSections) { modelSection in
                        if let heading = modelSection.heading {
                            Text(heading.uppercased())
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(tokens.placeholder)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.top, 5)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(modelSection.models) { model in
                            modelRow(section: section, model: model, canManage: canManage)
                        }
                    }
                    if !searchingModels && !more.isEmpty {
                        moreButton(section: section, expanded: expanded, count: more.count)
                            .padding(.top, 4)
                    }
                }
            }
            .padding(6)
        }
        .scrollIndicators(.automatic)
    }

    private func favoritesEditBody(
        section: PrismAgentMenuSection,
        pinnedModels: [PrismModelOption]
    ) -> some View {
        let q = query
        let matchesAgent = section.agent.name.lowercased().contains(q)
            || section.agent.id.lowercased().contains(q)
        let searchingModels = !q.isEmpty && !matchesAgent
        let pinnedSet = Set(pinnedModels.map(\.id))
        let unpinned = section.models.filter { model in
            guard !pinnedSet.contains(model.id) else { return false }
            if searchingModels {
                return PrismModelMenuLayout.matches(model, query: q)
            }
            return true
        }
        let unpinnedSections = PrismModelMenuLayout.grouped(unpinned, kind: .more)
        let atLimit = pinnedModels.count >= Self.maxPinnedModels

        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                pinErrorBanner

                Text(l10n.tr("runSetup.favoritesPinnedSection", pinnedModels.count, Self.maxPinnedModels))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tokens.primary)
                    .padding(.horizontal, 8)
                    .padding(.top, 2)

                if pinnedModels.isEmpty {
                    Text(l10n.tr("runSetup.favoritesEmptyHint", Self.maxPinnedModels))
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.placeholder)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                .fill(tokens.surface2.opacity(0.5))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                .strokeBorder(tokens.borderEtched, lineWidth: 1)
                        )
                } else {
                    VStack(spacing: 3) {
                        ForEach(Array(pinnedModels.enumerated()), id: \.element.id) { index, model in
                            pinnedEditableRow(
                                section: section,
                                model: model,
                                index: index,
                                total: pinnedModels.count
                            )
                        }
                    }
                }

                Rectangle()
                    .fill(tokens.borderEtched)
                    .frame(height: 1)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 4)

                Text(l10n.tr("runSetup.favoritesAllSection"))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tokens.placeholder)
                    .padding(.horizontal, 8)

                if unpinned.isEmpty {
                    Text(searchingModels ? l10n.tr("newSession.noMatch") : l10n.tr("composer.noModelsReported"))
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.placeholder)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(unpinnedSections) { modelSection in
                            if let heading = modelSection.heading {
                                Text(heading.uppercased())
                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(tokens.placeholder)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 5)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            ForEach(modelSection.models) { model in
                                unpinnedCandidateRow(
                                    section: section,
                                    model: model,
                                    atLimit: atLimit
                                )
                            }
                        }
                    }
                }
            }
            .padding(6)
        }
        .scrollIndicators(.automatic)
    }

    private func pinnedEditableRow(
        section: PrismAgentMenuSection,
        model: PrismModelOption,
        index: Int,
        total: Int
    ) -> some View {
        let key = "fav-pinned::\(section.id)::\(model.id)"
        let hovered = hoveredKey == key
        let isDropTarget = dropTargetFavoriteID == model.id && draggedFavoriteID != model.id

        return HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tokens.placeholder)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(1)
                if !model.subtitle.isEmpty {
                    Text(model.subtitle)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if total > 1 && hovered {
                HStack(spacing: 2) {
                    Button {
                        moveFavorite(from: index, to: index - 1, in: section)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(index > 0 ? tokens.secondaryForeground : tokens.placeholder.opacity(0.45))
                            .frame(width: 18, height: 18)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tokens.hoverWash))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(index == 0 || pinBusy)
                    .help(l10n.tr("runSetup.favoritesMoveUp"))

                    Button {
                        moveFavorite(from: index, to: index + 1, in: section)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(index + 1 < total ? tokens.secondaryForeground : tokens.placeholder.opacity(0.45))
                            .frame(width: 18, height: 18)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tokens.hoverWash))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(index + 1 >= total || pinBusy)
                    .help(l10n.tr("runSetup.favoritesMoveDown"))
                }
            }

            Button {
                toggleFavorite(model, in: section)
            } label: {
                Image(systemName: "star.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tokens.primary)
                    .frame(width: Self.starSlotWidth, height: Self.starSlotWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(pinBusy)
            .help(l10n.tr("composer.unpinModel", model.name))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .fill(tokens.primarySoft.opacity(hovered ? 0.85 : 0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(
                    isDropTarget ? tokens.primary : tokens.primaryBorder.opacity(0.7),
                    lineWidth: isDropTarget ? 1.5 : 1
                )
        )
        .contentShape(Rectangle())
        .onHover { inside in
            hoveredKey = inside ? key : (hoveredKey == key ? nil : hoveredKey)
        }
        .draggable(model.id) {
            Text(model.name)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tokens.foreground)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous).fill(tokens.surface1))
                .overlay(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous).strokeBorder(tokens.primaryBorder, lineWidth: 1))
                .onAppear { draggedFavoriteID = model.id }
        }
        .dropDestination(for: String.self) { items, _ in
            defer {
                draggedFavoriteID = nil
                dropTargetFavoriteID = nil
            }
            guard let sourceID = items.first,
                  let fromIndex = currentPinnedIDs(in: section).firstIndex(of: sourceID),
                  fromIndex != index
            else { return false }
            moveFavorite(from: fromIndex, to: index, in: section)
            return true
        } isTargeted: { targeted in
            dropTargetFavoriteID = targeted ? model.id : (dropTargetFavoriteID == model.id ? nil : dropTargetFavoriteID)
        }
    }

    private func unpinnedCandidateRow(
        section: PrismAgentMenuSection,
        model: PrismModelOption,
        atLimit: Bool
    ) -> some View {
        let key = "fav-all::\(section.id)::\(model.id)"
        let hovered = hoveredKey == key
        return Button {
            toggleFavorite(model, in: section)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(atLimit ? tokens.placeholder : tokens.secondaryForeground)
                        .lineLimit(1)
                    if !model.subtitle.isEmpty {
                        Text(model.subtitle)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "star")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(hovered && !atLimit ? tokens.primary : tokens.placeholder)
                    .frame(width: Self.starSlotWidth, height: Self.starSlotWidth)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5.5)
            .background(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .fill(hovered && !atLimit ? tokens.hoverWash : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pinBusy)
        .opacity(atLimit ? 0.55 : 1)
        .help(atLimit ? l10n.tr("runSetup.favoritesFullHint", Self.maxPinnedModels) : l10n.tr("composer.pinModel", model.name))
        .onHover { inside in
            hoveredKey = inside ? key : (hoveredKey == key ? nil : hoveredKey)
        }
    }

    private func modelRow(
        section: PrismAgentMenuSection,
        model: PrismModelOption,
        canManage: Bool
    ) -> some View {
        let active = model.id == section.selectedModelID
        let key = "model::\(section.id)::\(model.id)"
        let hovered = hoveredKey == key
        let starShown = canManage && (model.isPinned || hovered)
        let pinLabel = l10n.tr(model.isPinned ? "composer.unpinModel" : "composer.pinModel", model.name)
        return Button {
            onSelectModel(section.id, model.id)
            moveFocus(.run)
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.name)
                        .font(.system(size: 12, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? tokens.foreground : tokens.secondaryForeground)
                        .lineLimit(1)
                    if !model.subtitle.isEmpty {
                        Text(model.subtitle)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if canManage {
                    // Reserve space for the overlay star button so its tap never selects the model.
                    Color.clear.frame(width: Self.starSlotWidth, height: Self.starSlotWidth)
                } else if model.isPinned {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(tokens.primary)
                        .frame(width: Self.starSlotWidth, height: Self.starSlotWidth)
                        .accessibilityHidden(true)
                }
                Group {
                    if active {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(tokens.primary)
                    }
                }
                .frame(width: Self.checkSlotWidth)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .fill(active ? tokens.activeWash : (hovered ? tokens.hoverWash : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!section.agent.isAvailable)
        .opacity(section.agent.isAvailable ? 1 : 0.45)
        .overlay(alignment: .trailing) {
            if canManage {
                let starHovered = hoveredPinKey == key
                Button {
                    toggleFavorite(model, in: section)
                } label: {
                    Image(systemName: model.isPinned ? "star.fill" : "star")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(model.isPinned || starHovered ? tokens.primary : tokens.mutedForeground)
                        .frame(width: Self.starSlotWidth, height: Self.starSlotWidth)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(starHovered ? tokens.hoverWash : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(pinBusy)
                .help(pinLabel)
                .focusable(false)
                .accessibilityHidden(true)
                .padding(.trailing, 8 + Self.checkSlotWidth + 6)
                .opacity(starShown ? 1 : 0)
                .allowsHitTesting(starShown)
                .animation(PrismSpringSpec.micro.animation(tier: motionTier, reduceMotion: reduceMotion), value: starShown)
                .onHover { inside in
                    hoveredPinKey = inside ? key : (hoveredPinKey == key ? nil : hoveredPinKey)
                }
            }
        }
        .accessibilityAddTraits(active ? .isSelected : [])
        .onHover { inside in
            guard section.agent.isAvailable else {
                if hoveredKey == key { hoveredKey = nil }
                return
            }
            hoveredKey = inside ? key : (hoveredKey == key ? nil : hoveredKey)
        }
    }

    private func moreButton(section: PrismAgentMenuSection, expanded: Bool, count: Int) -> some View {
        Button {
            if expanded {
                showMoreForAgent.remove(section.id)
            } else {
                showMoreForAgent.insert(section.id)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                Text(expanded ? l10n.tr("composer.hideMoreModels") : l10n.tr("composer.moreModels", count))
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(tokens.secondaryForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(tokens.hoverWash.opacity(0.65)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Run column (permission mode, effort, switches)

    private func runColumn(_ section: PrismAgentMenuSection) -> some View {
        let modeName = section.modes.first(where: { $0.id == section.selectedModeID })?.name
        return VStack(spacing: 0) {
            columnHeader(.run, title: l10n.tr("runSetup.modeAndEffort"), value: modeName)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if section.modes.isEmpty {
                        Text(l10n.tr("runSetup.noModes"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(tokens.placeholder)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 10)
                    } else {
                        ForEach(section.modes) { mode in
                            modeRow(section: section, mode: mode)
                        }
                    }
                    if !section.toggles.isEmpty {
                        Rectangle().fill(tokens.borderEtched).frame(height: 1)
                            .padding(.vertical, 6)
                        ForEach(section.toggles) { item in
                            PrismSwitchRow(item: item, isAvailable: section.agent.isAvailable) { optionId, on in
                                onToggleOption(section.id, optionId, on)
                            }
                        }
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.automatic)

            if !section.effortLevels.isEmpty {
                Rectangle().fill(tokens.borderEtched).frame(height: 1)
                PrismEffortSegmentedControl(
                    title: section.effortTitle?.isEmpty == false
                        ? (section.effortTitle ?? l10n.tr("effort.title"))
                        : l10n.tr("effort.title"),
                    levels: section.effortLevels,
                    selectedID: section.selectedEffortID,
                    showShortcutHint: false,
                    onSelect: { value in onSelectEffort(section.id, value) }
                )
                .disabled(!section.agent.isAvailable)
                .opacity(section.agent.isAvailable ? 1.0 : 0.5)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    private func modeRow(section: PrismAgentMenuSection, mode: PrismModeOption) -> some View {
        let active = mode.id == section.selectedModeID
        let isFull = mode.look == .full
        let key = "mode::\(section.id)::\(mode.id)"
        let hovered = hoveredKey == key
        let desc = mode.description.isEmpty && isFull
            ? l10n.tr("composer.modeFullAccessWarning")
            : mode.description
        return Button {
            onSelectMode(section.id, mode.id)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: mode.look.systemImage)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isFull ? tokens.danger : (active ? tokens.primary : tokens.secondaryForeground))
                    .frame(width: 17)
                    .padding(.top, 1.5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.name)
                        .font(.system(size: 12, weight: active ? .semibold : .medium))
                        .foregroundStyle(isFull ? tokens.danger : tokens.foreground)
                        .lineLimit(1)
                    if !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 10))
                            .foregroundStyle(isFull ? tokens.danger.opacity(0.8) : tokens.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                if active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isFull ? tokens.danger : tokens.primary)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .fill(
                        active
                            ? (isFull ? tokens.dangerSoft : tokens.activeWash)
                            : (hovered ? (isFull ? tokens.dangerSoft.opacity(0.65) : tokens.hoverWash) : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!section.agent.isAvailable)
        .opacity(section.agent.isAvailable ? 1 : 0.45)
        .accessibilityAddTraits(active ? .isSelected : [])
        .onHover { inside in
            guard section.agent.isAvailable else {
                if hoveredKey == key { hoveredKey = nil }
                return
            }
            hoveredKey = inside ? key : (hoveredKey == key ? nil : hoveredKey)
        }
    }
}

// MARK: - Shared agent pieces

enum PrismAgentTagStyle {
    static func color(_ tone: PrismAgentTag.Tone, tokens: PrismTokens) -> Color {
        switch tone {
        case .muted: return tokens.placeholder
        case .attention: return tokens.warning
        case .danger: return tokens.danger
        }
    }
}

/// Why an agent cannot start, and the one action that fixes it.
struct PrismAgentProblemCard: View {
    @Environment(\.prismTokens) private var tokens

    let agent: PrismAgentSwitchOption
    let onFixAgent: ((String) -> Void)?

    var body: some View {
        let tone = agent.tag?.tone ?? .danger
        let accent = tone == .muted ? tokens.mutedForeground : PrismAgentTagStyle.color(tone, tokens: tokens)
        let fill: Color = switch tone {
        case .danger: tokens.dangerSoft
        case .attention: tokens.warningSoft
        case .muted: tokens.surface2
        }
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tone == .muted ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(accent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 7) {
                if let text = agent.problemText ?? agent.tag?.title ?? agent.tag?.text {
                    Text(text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let fixTitle = agent.fixTitle, let onFixAgent {
                    Button {
                        onFixAgent(agent.id)
                    } label: {
                        Text(fixTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(tokens.foreground)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(tokens.surface1))
                            .overlay(Capsule().strokeBorder(tokens.borderStrong, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(fill))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(accent.opacity(0.3), lineWidth: 1)
        )
    }
}

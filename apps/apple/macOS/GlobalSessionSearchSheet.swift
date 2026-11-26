import SartoProtocol
import PrismDesign
import SwiftUI

/// Cross-Agent Global Full-Text Search Sheet (`⌘K`), combining instant local session title/project
/// filtering with Sarto host SQLite FTS (`sessions.search`) across all agent histories.
struct GlobalSessionSearchSheet: View {
    private struct ScopedHit: Identifiable, Equatable {
        let hostId: String
        let hostName: String
        let isLocal: Bool
        let hit: ConversationHitInfo
        var id: String { "\(hostId)::\(hit.id)" }
    }

    private struct ScopedSession: Identifiable, Equatable {
        let hostId: String
        let hostName: String
        let isLocal: Bool
        let session: SessionSummary
        var id: String { "\(hostId)::\(session.id)" }
    }

    private enum ResultEntry: Identifiable, Equatable {
        case hit(ScopedHit)
        case session(ScopedSession)

        var id: String {
            switch self {
            case .hit(let h): return "hit::\(h.id)"
            case .session(let s): return "sess::\(s.id)"
            }
        }

        var sessionId: String {
            switch self {
            case .hit(let h): return h.hit.sessionId
            case .session(let s): return s.session.id
            }
        }

        var hostId: String {
            switch self {
            case .hit(let h): return h.hostId
            case .session(let s): return s.hostId
            }
        }
    }

    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    @Bindable var state: SartoState

    @State private var query: String = ""
    @State private var ftsHits: [ScopedHit] = []
    @State private var indexing: SearchIndexingInfo? = nil
    @State private var isSearching: Bool = false
    @State private var errorMessage: String? = nil
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var selectedIndex: Int = 0
    @State private var hoveredEntryID: String? = nil
    @FocusState private var inputFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func computeLocalMatches(hosts: [UnifiedHostSnapshot]) -> [ScopedSession] {
        let q = trimmedQuery.lowercased()
        let pool: [ScopedSession] = hosts.flatMap { host in
            host.sessions
                .filter { $0.origin != "subagent" && $0.archivedAt == nil }
                .map { ScopedSession(hostId: host.id, hostName: host.name, isLocal: host.isLocal, session: $0) }
        }
        if q.isEmpty {
            return Array(pool.sorted { $0.session.updatedAt > $1.session.updatedAt }.prefix(14))
        }
        let words = q.split(whereSeparator: \.isWhitespace).map(String.init)
        return pool
            .filter { entry in
                let s = entry.session
                let hay = "\(s.title ?? "") \(s.projectPath) \(s.agentId) \(entry.hostName)".lowercased()
                return words.allSatisfy { hay.contains($0) }
            }
            .sorted { $0.session.updatedAt > $1.session.updatedAt }
    }

    private func computeOrderedEntries(localMatches: [ScopedSession]) -> [ResultEntry] {
        ftsHits.map { .hit($0) } + localMatches.map { .session($0) }
    }

    private func computeSelectedEntryID(entries: [ResultEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        let clamped = max(0, min(selectedIndex, entries.count - 1))
        return entries[clamped].id
    }

    private var hasActiveIMEComposition: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }

    var body: some View {
        let hosts = state.unifiedHosts
        let matches = computeLocalMatches(hosts: hosts)
        let entries = computeOrderedEntries(localMatches: matches)
        let activeSelectedID = computeSelectedEntryID(entries: entries)
        let hostsByID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })

        VStack(spacing: 0) {
            // Search input header
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tokens.prismCobalt)

                TextField(l10n.tr("search.globalPlaceholder"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(tokens.foreground)
                    .focused($inputFocused)
                    .onSubmit {
                        openSelectedOrFirst()
                    }

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                } else if !query.isEmpty {
                    Button {
                        query = ""
                        ftsHits = []
                        indexing = nil
                        errorMessage = nil
                        selectedIndex = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(tokens.mutedForeground)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    dismiss()
                } label: {
                    Text("ESC")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(tokens.hoverWash))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(tokens.surface1)

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            if let idx = indexing, idx.total > 0 {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(l10n.tr("search.indexingProgress", idx.done, idx.total))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tokens.mutedForeground)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(tokens.surface1.opacity(0.6))
                Rectangle().fill(tokens.borderEtched).frame(height: 1)
            }

            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.warning)
                    Text(errorMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.warning)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if !ftsHits.isEmpty {
                            sectionTitle(l10n.tr("search.sectionMessages", ftsHits.count))
                            ForEach(Array(ftsHits.enumerated()), id: \.element.id) { idx, scoped in
                                let entryID = "hit::\(scoped.id)"
                                hitRow(
                                    scoped,
                                    hostSnap: hostsByID[scoped.hostId],
                                    entryID: entryID,
                                    isSelected: activeSelectedID == entryID,
                                    flatIndex: idx
                                )
                                .id(entryID)
                            }
                        }

                        if !matches.isEmpty {
                            sectionTitle(
                                trimmedQuery.isEmpty
                                    ? l10n.tr("search.sectionRecent")
                                    : l10n.tr("search.sectionTitles", matches.count)
                            )
                            let offset = ftsHits.count
                            ForEach(Array(matches.enumerated()), id: \.element.id) { idx, scoped in
                                let entryID = "sess::\(scoped.id)"
                                localSessionRow(
                                    scoped,
                                    entryID: entryID,
                                    isSelected: activeSelectedID == entryID,
                                    flatIndex: offset + idx
                                )
                                .id(entryID)
                            }
                        }

                        if ftsHits.isEmpty && matches.isEmpty && !isSearching {
                            VStack(spacing: 8) {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .font(.system(size: 24))
                                    .foregroundStyle(tokens.placeholder)
                                Text(l10n.tr("search.noResults"))
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(tokens.mutedForeground)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 48)
                        }
                    }
                    .padding(12)
                }
                .background(tokens.background)
                .onChange(of: activeSelectedID) { _, id in
                    guard let id else { return }
                    withAnimation(PrismSpringSpec.snappy.animation(tier: state.motionTier)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            // Footer keyboard hint bar
            HStack(spacing: 12) {
                Text(l10n.tr("search.navHint"))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
                Spacer()
                if !entries.isEmpty {
                    Text("\(min(selectedIndex + 1, entries.count)) / \(entries.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(tokens.surface1)
        }
        .frame(width: 636, height: 484)
        .background(tokens.background)
        .preferredColorScheme(state.palette.colorScheme)
        .onKeyPress(.downArrow) {
            guard !hasActiveIMEComposition else { return .ignored }
            moveSelection(delta: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard !hasActiveIMEComposition else { return .ignored }
            moveSelection(delta: -1)
            return .handled
        }
        .onAppear {
            inputFocused = true
            selectedIndex = 0
        }
        .onChange(of: query) { _, next in
            selectedIndex = 0
            scheduleRemoteSearch(next)
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private func moveSelection(delta: Int) {
        let matches = computeLocalMatches(hosts: state.unifiedHosts)
        let count = computeOrderedEntries(localMatches: matches).count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func openSelectedOrFirst() {
        let matches = computeLocalMatches(hosts: state.unifiedHosts)
        let items = computeOrderedEntries(localMatches: matches)
        guard !items.isEmpty else { return }
        let idx = max(0, min(selectedIndex, items.count - 1))
        openSession(items[idx].sessionId, hostId: items[idx].hostId)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(tokens.mutedForeground)
            .textCase(.uppercase)
            .padding(.horizontal, 8)
            .padding(.top, 4)
    }

    private func highlightedText(_ source: String) -> AttributedString {
        var attr = AttributedString(source)
        let terms = trimmedQuery.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.count >= 2 }
        guard !terms.isEmpty else { return attr }
        for term in terms {
            var searchStart = attr.startIndex
            while searchStart < attr.endIndex,
                  let range = attr[searchStart..<attr.endIndex].range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                attr[range].foregroundColor = tokens.prismCobalt
                attr[range].inlinePresentationIntent = .stronglyEmphasized
                searchStart = range.upperBound
            }
        }
        return attr
    }

    private func hitRow(_ scoped: ScopedHit, hostSnap: UnifiedHostSnapshot?, entryID: String, isSelected: Bool, flatIndex: Int) -> some View {
        let hit = scoped.hit
        let session = hostSnap?.sessions.first(where: { $0.id == hit.sessionId })
        let title = session?.title?.isEmpty == false ? session!.title! : l10n.tr("sidebar.untitledSession")
        let projectName = session.map { URL(fileURLWithPath: $0.projectPath).lastPathComponent } ?? ""
        let agentName = session.map { state.agentDisplayName(for: $0.agentId) } ?? ""
        let isHovered = hoveredEntryID == entryID

        return Button {
            openSession(hit.sessionId, hostId: scoped.hostId)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(tokens.prismCobalt)
                        .frame(width: 6, height: 6)
                    Text(highlightedText(title))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if state.hasMultipleHosts {
                        Text(scoped.hostName)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(scoped.isLocal ? tokens.placeholder : tokens.prismCobalt)
                            .lineLimit(1)
                    }
                    if let matches = hit.matches, matches > 1 {
                        Text(l10n.tr("search.matchCount", matches))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(tokens.prismCobalt)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tokens.prismCobalt.opacity(0.14)))
                    }
                    if !agentName.isEmpty {
                        Text(agentName)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                    }
                }

                HStack(alignment: .top, spacing: 6) {
                    Text(hit.role == "user" ? l10n.tr("search.roleUser") : l10n.tr("search.roleAgent"))
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(hit.role == "user" ? tokens.prismIris : tokens.success)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(tokens.hoverWash))

                    Text(highlightedText(hit.snippet))
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.secondaryForeground)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                if !projectName.isEmpty {
                    Text(projectName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .fill(isSelected ? tokens.activeWash : (isHovered ? tokens.hoverWash : tokens.surface1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .strokeBorder(isSelected ? tokens.prismCobalt.opacity(0.55) : tokens.borderEtched, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoveredEntryID = inside ? entryID : (hoveredEntryID == entryID ? nil : hoveredEntryID)
            if inside { selectedIndex = flatIndex }
        }
    }

    private func localSessionRow(
        _ scoped: ScopedSession,
        entryID: String,
        isSelected: Bool,
        flatIndex: Int
    ) -> some View {
        let session = scoped.session
        let title = session.title?.isEmpty == false ? session.title! : l10n.tr("sidebar.untitledSession")
        let projectName = session.scratch == true
            ? l10n.tr("sidebar.noProject")
            : URL(fileURLWithPath: session.projectPath).lastPathComponent
        let isHovered = hoveredEntryID == entryID

        return Button {
            openSession(session.id, hostId: scoped.hostId)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(session.status == .running ? tokens.success : tokens.mutedForeground.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(highlightedText(title))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if state.hasMultipleHosts {
                    Text(scoped.hostName)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(scoped.isLocal ? tokens.placeholder : tokens.prismCobalt)
                        .lineLimit(1)
                }
                Text(projectName)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(tokens.placeholder)
                    .lineLimit(1)
                Text(state.agentDisplayName(for: session.agentId))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tokens.hoverWash))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .fill(isSelected ? tokens.activeWash : (isHovered ? tokens.hoverWash : tokens.surface1.opacity(0.65)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .strokeBorder(isSelected ? tokens.prismCobalt.opacity(0.55) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoveredEntryID = inside ? entryID : (hoveredEntryID == entryID ? nil : hoveredEntryID)
            if inside { selectedIndex = flatIndex }
        }
    }

    private func scheduleRemoteSearch(_ raw: String) {
        searchTask?.cancel()
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else {
            ftsHits = []
            indexing = nil
            isSearching = false
            errorMessage = nil
            return
        }
        isSearching = true
        errorMessage = nil
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            let results = await state.searchAllHosts(query: q)
            guard !Task.isCancelled else { return }
            var merged: [ScopedHit] = []
            var firstIndexing: SearchIndexingInfo? = nil
            for r in results {
                if firstIndexing == nil, let idx = r.indexing, idx.total > 0 {
                    firstIndexing = idx
                }
                for h in r.hits {
                    merged.append(ScopedHit(hostId: r.hostId, hostName: r.hostName, isLocal: r.isLocal, hit: h))
                }
            }
            ftsHits = merged
            indexing = firstIndexing
            selectedIndex = 0
            isSearching = false
        }
    }

    private func openSession(_ sessionId: String, hostId: String) {
        dismiss()
        Task {
            await state.selectSession(sessionId, onHost: hostId)
        }
    }
}

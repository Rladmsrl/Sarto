import AppKit
import SartoProtocol
import PrismDesign
import SwiftUI

// MARK: - 1. Rich `@` File, Folder & Session + `/` Command Autocomplete Popover

enum ComposerMentionEntry: Equatable, Identifiable {
    case file(ComposerMentionRow)
    case session(ComposerSessionMentionRow)

    var id: String {
        switch self {
        case .file(let row): return "file:\(row.id)"
        case .session(let row): return "sess:\(row.id)"
        }
    }
}

enum ComposerRichCompletionMode: Equatable {
    case slash(commands: [SlashCommand], note: String?)
    case mention(
        files: [ComposerMentionRow],
        sessions: [ComposerSessionMentionRow],
        totalPoolCount: Int,
        hasQuery: Bool,
        noProject: Bool
    )

    var mentionEntries: [ComposerMentionEntry] {
        guard case .mention(let files, let sessions, _, _, _) = self else { return [] }
        return files.map(ComposerMentionEntry.file) + sessions.map(ComposerMentionEntry.session)
    }
}

struct ComposerRichAutocompleteView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    let mode: ComposerRichCompletionMode
    let agentName: String
    let selectedIndex: Int
    let onHighlight: (Int) -> Void
    let onSelectSlash: (SlashCommand) -> Void
    let onSelectFile: (ComposerMentionRow) -> Void
    let onSelectSession: (ComposerSessionMentionRow) -> Void

    private var rowCount: Int {
        switch mode {
        case .slash(let cmds, _): return cmds.count
        case .mention(let files, let sessions, _, _, _): return files.count + sessions.count
        }
    }

    private var headerTitle: String? {
        switch mode {
        case .slash(let cmds, _):
            return cmds.isEmpty ? nil : agentName
        case .mention(let files, let sessions, _, _, _):
            if !files.isEmpty && sessions.isEmpty {
                return l10n.tr("composer.mentions.files")
            }
            if files.isEmpty && !sessions.isEmpty {
                return l10n.tr("composer.mentions.sessions")
            }
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let headerTitle {
                HStack {
                    Text(headerTitle)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(tokens.placeholder)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 7)
                .padding(.bottom, 4)
            }

            if rowCount > 0 {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            switch mode {
                            case .slash(let commands, _):
                                ForEach(Array(commands.enumerated()), id: \.element.name) { idx, cmd in
                                    slashRow(cmd, index: idx, isSelected: idx == selectedIndex)
                                        .id("s:\(cmd.name)")
                                }

                            case .mention(let files, let sessions, _, _, _):
                                let showBothHeaders = !files.isEmpty && !sessions.isEmpty
                                if showBothHeaders {
                                    sectionHeader(l10n.tr("composer.mentions.files"))
                                }
                                ForEach(Array(files.enumerated()), id: \.element.id) { idx, row in
                                    fileRow(row, index: idx, isSelected: idx == selectedIndex)
                                        .id("file:\(row.id)")
                                }
                                if showBothHeaders {
                                    sectionHeader(l10n.tr("composer.mentions.sessions"))
                                        .padding(.top, 4)
                                }
                                let sessionOffset = files.count
                                ForEach(Array(sessions.enumerated()), id: \.element.id) { offset, row in
                                    let idx = sessionOffset + offset
                                    sessionRow(row, index: idx, isSelected: idx == selectedIndex)
                                        .id("sess:\(row.id)")
                                }
                            }
                        }
                        .padding(5)
                    }
                    .frame(maxHeight: 280)
                    .onChange(of: selectedIndex) { _, idx in
                        switch mode {
                        case .slash(let cmds, _) where cmds.indices.contains(idx):
                            proxy.scrollTo("s:\(cmds[idx].name)")
                        case .mention:
                            let entries = mode.mentionEntries
                            if entries.indices.contains(idx) {
                                proxy.scrollTo(entries[idx].id)
                            }
                        default:
                            break
                        }
                    }
                }
            }

            footerView
        }
        .background(tokens.surface1)
        .clipShape(RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous)
                .strokeBorder(tokens.borderStrong, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(tokens.palette.isDark ? 0.42 : 0.14), radius: 14, y: 6)
    }

    private func sectionHeader(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tokens.placeholder)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    private func fileRow(_ row: ComposerMentionRow, index: Int, isSelected: Bool) -> some View {
        let parts = splitFileNameAndDir(row.path, isFolder: row.isFolder)
        return Button {
            onSelectFile(row)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: row.isFolder ? "folder.fill" : "doc.text")
                    .font(.system(size: 11.5))
                    .foregroundStyle(row.isFolder ? tokens.warning : tokens.prismCobalt)
                    .frame(width: 16)

                highlightedSegment(parts.name, offset: parts.nameOffset, positions: row.positions, primary: true)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                if !parts.dir.isEmpty {
                    highlightedSegment(parts.dir, offset: 0, positions: row.positions, primary: false)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 6)

                if row.isFolder {
                    Text(l10n.tr("composer.mentions.folder"))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(tokens.surface2))
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
        .onHover { inside in
            if inside { onHighlight(index) }
        }
    }

    private func splitFileNameAndDir(_ path: String, isFolder: Bool) -> (name: String, dir: String, nameOffset: Int) {
        if let slash = path.lastIndex(of: "/") {
            let dir = String(path[..<slash])
            let base = String(path[path.index(after: slash)...])
            let displayName = isFolder ? "\(base)/" : base
            let offset = dir.count + 1
            return (displayName, dir, offset)
        }
        return (isFolder ? "\(path)/" : path, "", 0)
    }

    private func highlightedSegment(_ text: String, offset: Int, positions: [Int], primary: Bool) -> Text {
        var result = AttributedString()
        for run in ComposerPathMatcher.markedRuns(text: text, offset: offset, positions: positions) {
            var part = AttributedString(run.text)
            if run.marked {
                part.foregroundColor = tokens.foreground
                part.backgroundColor = tokens.primary.opacity(tokens.palette.isDark ? 0.30 : 0.22)
                part.font = primary
                    ? .system(size: 12.5, weight: .semibold)
                    : .system(size: 11, weight: .semibold, design: .monospaced)
            } else {
                part.foregroundColor = primary ? tokens.foreground : tokens.mutedForeground
                part.font = primary
                    ? .system(size: 12.5, weight: .medium)
                    : .system(size: 11, design: .monospaced)
            }
            result.append(part)
        }
        return Text(result)
    }

    private func slashRow(_ cmd: SlashCommand, index: Int, isSelected: Bool) -> some View {
        Button {
            onSelectSlash(cmd)
        } label: {
            HStack(spacing: 12) {
                HStack(spacing: 1) {
                    Text("/")
                        .foregroundStyle(tokens.placeholder)
                    Text(cmd.name)
                        .foregroundStyle(tokens.foreground)
                }
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .frame(minWidth: 92, maxWidth: 160, alignment: .leading)
                .lineLimit(1)

                if let hint = cmd.inputHint, !hint.isEmpty {
                    Text(hint)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                        .lineLimit(1)
                }

                Text(cmd.description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                    .fill(isSelected ? tokens.activeWash : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { onHighlight(index) }
        }
    }

    private func sessionRow(_ row: ComposerSessionMentionRow, index: Int, isSelected: Bool) -> some View {
        let item = row.candidate
        let relTime = compactRelativeTime(item.updatedAt)

        return Button {
            onSelectSession(row)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 11.5))
                    .foregroundStyle(tokens.prismCobalt)
                    .frame(width: 16)

                highlightedSessionTitle(item.title, positions: row.titlePositions)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                if let branch = item.branch, !branch.isEmpty {
                    Text(branch)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                        .lineLimit(1)
                        .frame(maxWidth: 96, alignment: .trailing)
                }

                Text(item.agentName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tokens.secondaryForeground)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(tokens.surface2))

                if !relTime.isEmpty {
                    Text(relTime)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                        .frame(minWidth: 24, alignment: .trailing)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                    .fill(isSelected ? tokens.activeWash : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { onHighlight(index) }
        }
    }

    private func highlightedSessionTitle(_ title: String, positions: [Int]) -> Text {
        var result = AttributedString()
        for run in ComposerPathMatcher.markedRuns(text: title, offset: 0, positions: positions) {
            var part = AttributedString(run.text)
            if run.marked {
                part.foregroundColor = tokens.foreground
                part.backgroundColor = tokens.primary.opacity(tokens.palette.isDark ? 0.30 : 0.22)
                part.font = .system(size: 12.5, weight: .semibold)
            } else {
                part.foregroundColor = tokens.foreground
                part.font = .system(size: 12.5, weight: .medium)
            }
            result.append(part)
        }
        return Text(result)
    }

    private func compactRelativeTime(_ rawTimestamp: Double) -> String {
        guard rawTimestamp > 0 else { return "" }
        let seconds = rawTimestamp > 1e11 ? rawTimestamp / 1000.0 : rawTimestamp
        let delta = max(0, Int(Date().timeIntervalSince1970 - seconds))
        if delta < 60 { return "<1m" }
        if delta < 3600 { return "\(delta / 60)m" }
        if delta < 86400 { return "\(delta / 3600)h" }
        return "\(delta / 86400)d"
    }

    @ViewBuilder
    private var footerView: some View {
        switch mode {
        case .slash(let cmds, let note):
            if cmds.isEmpty, let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.placeholder)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

        case .mention(let files, let sessions, let totalPoolCount, let hasQuery, let noProject):
            let hasRows = !files.isEmpty || !sessions.isEmpty
            if noProject {
                Text(l10n.tr("composer.mentions.chooseProject"))
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.placeholder)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else if totalPoolCount == 0 {
                Text(l10n.tr("composer.mentions.noFiles"))
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.placeholder)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else if !hasRows && hasQuery {
                Text(l10n.tr("composer.mentions.noMatches"))
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.placeholder)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else if hasRows {
                HStack(spacing: 12) {
                    Text(l10n.tr("composer.mentions.keysMove"))
                    Text(l10n.tr("composer.mentions.keysInsert"))
                    Spacer()
                }
                .font(.system(size: 10.5))
                .foregroundStyle(tokens.placeholder)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .overlay(alignment: .top) {
                    Rectangle().fill(tokens.borderEtched).frame(height: 1)
                }
            }
        }
    }
}

// MARK: - 2. Leading Command Description Strip (mirrors prompt-chips.tsx command strip)

struct ComposerLeadingCommandStripView: View {
    @Environment(\.prismTokens) private var tokens

    let command: SlashCommand
    let agentName: String

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 1) {
                Text("/")
                    .foregroundStyle(tokens.primary.opacity(0.6))
                Text(command.name)
                    .foregroundStyle(tokens.primary)
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))

            Text(command.description)
                .font(.system(size: 11.5))
                .foregroundStyle(tokens.secondaryForeground)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            let meta = [agentName, command.inputHint].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !meta.isEmpty {
                Text(meta)
                    .font(.system(size: 10.5))
                    .foregroundStyle(tokens.placeholder)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.surface1))
        .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))
        .shadow(color: Color.black.opacity(tokens.palette.isDark ? 0.25 : 0.08), radius: 8, y: 3)
    }
}

// MARK: - 3. Pasted-as-Link Toast (`Cmd+Shift+V` to revert to plain text)

struct ComposerPastedLinkToastView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    let onKeepAsText: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Text(l10n.tr("composer.chips.pastedLink"))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tokens.foreground)

            Button(action: onKeepAsText) {
                HStack(spacing: 5) {
                    Text(l10n.tr("composer.chips.pasteAsText"))
                        .font(.system(size: 11, weight: .semibold))
                    Text("⌘⇧V")
                        .font(.system(size: 10, design: .monospaced))
                        .opacity(0.75)
                }
                .foregroundStyle(tokens.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tokens.primarySoft))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 11)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.surface1))
        .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(tokens.borderStrong, lineWidth: 1))
        .shadow(color: Color.black.opacity(tokens.palette.isDark ? 0.36 : 0.14), radius: 10, y: 4)
    }
}

// MARK: - 4. Chip Hover Preview Card (Referenced Session, File snippet, Image thumb, Folder, URL / GitHub PR)

struct ComposerChipHoverPreviewView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    let chip: ComposerChip
    let attachment: DraftAttachmentItem?
    let loadFileLines: (String) async -> [String]?
    let loadSessionPreview: (String) async -> ComposerSessionPreview?

    @State private var fileLines: [String]? = nil
    @State private var sessionPreview: ComposerSessionPreview? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch chip {
            case .command:
                EmptyView()

            case .session(_, _, _, _, let title, let agentName, let missing):
                HStack(spacing: 6) {
                    Image(systemName: missing ? "exclamationmark.triangle.fill" : "bubble.left.and.text.bubble.right.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(missing ? tokens.warning : tokens.primary)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(agentName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(tokens.surface2))
                }

                if missing {
                    Text(l10n.tr("composer.chips.sessionMissing"))
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.warning)
                } else if let preview = sessionPreview {
                    if preview.excerpts.isEmpty {
                        Text(l10n.tr("composer.chips.sessionEmpty"))
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.mutedForeground)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(preview.excerpts) { item in
                                HStack(alignment: .top, spacing: 6) {
                                    Circle()
                                        .fill(item.role == "user" ? tokens.primary : tokens.prismCobalt)
                                        .frame(width: 5, height: 5)
                                        .padding(.top, 5)
                                    Text(item.text)
                                        .font(.system(size: 11))
                                        .foregroundStyle(item.role == "user" ? tokens.foreground : tokens.secondaryForeground)
                                        .lineLimit(2)
                                        .truncationMode(.tail)
                                }
                            }
                        }
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tokens.codeBackground))
                    }
                    HStack(spacing: 8) {
                        if preview.turnCount > 0 {
                            Text(l10n.tr("composer.chips.sessionTurns", preview.turnCount))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(tokens.secondaryForeground)
                        }
                        Text(l10n.tr("composer.chips.sessionSent"))
                            .font(.system(size: 10))
                            .foregroundStyle(tokens.placeholder)
                            .lineLimit(1)
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.55)
                        Text(l10n.tr("composer.chips.sessionSent"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(tokens.placeholder)
                    }
                }

                HStack(spacing: 12) {
                    if !missing {
                        Text(l10n.tr("composer.chips.clickToOpenSession"))
                    }
                    Text(l10n.tr("composer.chips.backspaceRemoves"))
                }
                .font(.system(size: 10))
                .foregroundStyle(tokens.placeholder)

            case .link(_, _, let url, let host, let path, _, let gh):
                HStack(spacing: 6) {
                    Image(systemName: gh.map { $0.kind == .pull ? "arrow.triangle.pull" : "circle.inset.filled" } ?? "globe")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(gh != nil ? tokens.prismIris : tokens.prismCobalt)
                    Text(gh?.shortLabel ?? "\(host)\(path)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(url)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(l10n.tr("composer.chips.opensInBrowser"))
                    .font(.system(size: 10))
                    .foregroundStyle(tokens.placeholder)

            case .mention(_, _, .image, _, let label, _, _, _, _):
                if let data = attachment?.thumbnailData, let img = PrismImageDecoder.swiftUIImage(from: data) {
                    img
                        .resizable()
                        .scaledToFill()
                        .frame(width: 240, height: 132)
                        .clipShape(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous))
                }
                HStack {
                    Text(label)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)
                    Spacer()
                    let meta = [
                        attachment.flatMap { a in a.pixelWidth.flatMap { w in a.pixelHeight.map { "\(w)×\($0)" } } },
                        attachment.map { PrismImageDecoder.formatByteCount($0.size) },
                    ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    if !meta.isEmpty {
                        Text(meta)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                    }
                }

            case .mention(_, _, let kind, _, let label, let linesSpec, let relPath, _, let missing):
                let displayPath = relPath ?? label
                HStack(spacing: 6) {
                    Image(systemName: kind == .folder ? "folder.fill" : "doc.text")
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.prismCobalt)
                    Text(displayPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tokens.secondaryForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let linesSpec {
                        Text(l10n.tr("composer.chips.lines", linesSpec))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                    }
                }

                if missing {
                    Text(attachment?.failureMessage ?? l10n.tr("composer.chips.missing"))
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.warning)
                } else if kind == .folder {
                    Text(l10n.tr("composer.chips.folderSent"))
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.mutedForeground)
                } else if let fileLines, !fileLines.isEmpty {
                    let parsedRange = parseRange(linesSpec)
                    let startLine = parsedRange.map { max(1, $0.start - 1) } ?? 1
                    let count = parsedRange.map { max(1, min(8, $0.end - startLine + 1)) } ?? 6
                    let sliceStart = max(0, startLine - 1)
                    let sliceEnd = min(fileLines.count, sliceStart + count)
                    if sliceStart < sliceEnd {
                        VStack(alignment: .leading, spacing: 1.5) {
                            ForEach(sliceStart..<sliceEnd, id: \.self) { idx in
                                let lineNum = idx + 1
                                let highlighted = parsedRange.map { lineNum >= $0.start && lineNum <= $0.end } ?? false
                                HStack(spacing: 8) {
                                    Text("\(lineNum)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(tokens.placeholder)
                                        .frame(width: 24, alignment: .trailing)
                                    Text(fileLines[idx].isEmpty ? " " : fileLines[idx])
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(tokens.foreground)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(highlighted ? tokens.primarySoft : Color.clear)
                            }
                        }
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tokens.codeBackground))
                    }
                }

                if !missing && kind == .file {
                    HStack(spacing: 12) {
                        Text(l10n.tr("composer.chips.clickToOpen"))
                        Text(l10n.tr("composer.chips.backspaceRemoves"))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(tokens.placeholder)
                }
            }
        }
        .padding(10)
        .frame(width: 320, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous).fill(tokens.surface1))
        .overlay(RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous).strokeBorder(tokens.borderStrong, lineWidth: 1))
        .shadow(color: Color.black.opacity(tokens.palette.isDark ? 0.38 : 0.14), radius: 12, y: 5)
        .allowsHitTesting(false)
        .task(id: chip.rawText) {
            fileLines = nil
            sessionPreview = nil
            switch chip {
            case .session(_, _, _, let sessionId, _, _, false):
                sessionPreview = await loadSessionPreview(sessionId)
            case .mention(_, _, .file, _, _, _, let relPath?, _, false):
                fileLines = await loadFileLines(relPath)
            default:
                break
            }
        }
    }

    private func parseRange(_ spec: String?) -> (start: Int, end: Int)? {
        guard let spec else { return nil }
        let parts = spec.replacingOccurrences(of: "-", with: "–").split(separator: "–")
        guard let first = parts.first.flatMap({ Int($0) }) else { return nil }
        let last = parts.count > 1 ? (Int(parts[1]) ?? first) : first
        return (first, max(first, last))
    }
}

// MARK: - 5. Passage Reply Comments Strip (mirrors comment-list.tsx)

struct ComposerReplyCommentsListView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    let comments: [DraftReplyComment]
    let onRevealEntry: (String) -> Void
    let onEdit: (String, String) -> Void
    let onRemove: (String) -> Void
    let onRemoveAll: () -> Void

    @State private var editingID: String? = nil
    @State private var editingText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(tokens.prismCobalt)
                Text(l10n.tr("composer.comments.header", comments.count))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(tokens.secondaryForeground)
                    .lineLimit(1)
                Spacer()
                Button(action: onRemoveAll) {
                    Text(l10n.tr("composer.comments.removeAll"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(tokens.mutedForeground)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(comments.enumerated()), id: \.element.id) { idx, item in
                    HStack(alignment: .top, spacing: 7) {
                        Text("\(idx + 1)")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(tokens.prismCobalt)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(tokens.primarySoft))
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 2) {
                            Button {
                                if let eid = item.entryId {
                                    onRevealEntry(eid)
                                }
                            } label: {
                                Text(item.passage.replacingOccurrences(of: "\n", with: " "))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(tokens.mutedForeground)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .padding(.leading, 6)
                                    .overlay(alignment: .leading) {
                                        Rectangle().fill(tokens.borderStrong).frame(width: 2)
                                    }
                            }
                            .buttonStyle(.plain)
                            .disabled(item.entryId == nil)

                            if editingID == item.id {
                                HStack(spacing: 5) {
                                    TextField("", text: $editingText)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(tokens.foreground)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(RoundedRectangle(cornerRadius: 5).fill(tokens.surface1))
                                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(tokens.primaryBorder, lineWidth: 1))
                                        .onSubmit {
                                            commitEdit(id: item.id)
                                        }
                                    Button(l10n.tr("composer.comments.save")) {
                                        commitEdit(id: item.id)
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(tokens.primary)
                                }
                            } else {
                                Button {
                                    editingID = item.id
                                    editingText = item.comment
                                } label: {
                                    Text(item.comment.isEmpty ? l10n.tr("composer.comments.addPlaceholder") : item.comment)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(item.comment.isEmpty ? tokens.placeholder : tokens.foreground)
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Button {
                            onRemove(item.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(tokens.mutedForeground)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(tokens.hoverWash))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous).fill(tokens.surface2.opacity(0.55)))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.surface1.opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))
    }

    private func commitEdit(id: String) {
        let next = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !next.isEmpty {
            onEdit(id, next)
        }
        editingID = nil
    }
}

// MARK: - 6. Top Edge Resize Grip (mirrors resize-grip.tsx)

struct ComposerResizeGripView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    let currentHeight: CGFloat
    let autoHeight: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let onSetFixedHeight: (CGFloat) -> Void
    let onResetAutoHeight: () -> Void

    private struct DragAnchor {
        let startHeight: CGFloat
        let startScreenY: CGFloat
    }

    @State private var isHovered = false
    @State private var dragAnchor: DragAnchor? = nil

    var body: some View {
        let isActive = isHovered || dragAnchor != nil
        ZStack {
            Color.clear
            Capsule()
                .fill(isActive ? tokens.primary.opacity(0.55) : tokens.borderStrong.opacity(0.45))
                .frame(width: isActive ? 44 : 28, height: 3)
                .opacity(isActive ? 1 : 0.35)
                .animation(.easeOut(duration: 0.14), value: isActive)
        }
        .frame(height: 10)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .pointerStyle(.frameResize(position: .top))
        .help(l10n.tr("composer.resize.label"))
        .onHover { isHovered = $0 }
        .onDisappear {
            isHovered = false
            dragAnchor = nil
        }
        .onTapGesture(count: 2) {
            dragAnchor = nil
            onResetAutoHeight()
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { _ in
                    let screenY = NSEvent.mouseLocation.y
                    let anchor = dragAnchor ?? DragAnchor(startHeight: currentHeight, startScreenY: screenY)
                    if dragAnchor == nil { dragAnchor = anchor }
                    // AppKit screen Y increases upward, so dragging up grows the composer 1:1 even as the grip moves.
                    let proposed = min(maxHeight, max(minHeight, anchor.startHeight + (screenY - anchor.startScreenY)))
                    onSetFixedHeight(proposed)
                }
                .onEnded { _ in
                    let finalProposed = dragAnchor.map { anchor in
                        anchor.startHeight + (NSEvent.mouseLocation.y - anchor.startScreenY)
                    }
                    dragAnchor = nil
                    if let finalProposed, finalProposed <= minHeight + 2, autoHeight <= minHeight + 2 {
                        onResetAutoHeight()
                    }
                }
        )
    }
}

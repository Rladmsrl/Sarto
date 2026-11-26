import Foundation
import SartoProtocol
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// Exports a session's thread replica to a clean Markdown transcript.
/// Adapted from Kettu's conversation-markdown.ts formatting conventions.
public enum SessionMarkdownExporter {
    private static let maxStepChars = 200
    private static let maxFilenameChars = 80

    private enum ExportItem {
        case message(heading: String, body: String)
        case reply(String)
        case step(String)
    }

    public static func render(replica: ThreadReplica, agentName: String) -> String {
        let title = resolvedTitle(replica.session.title)
        let resolvedAgent = nonEmpty(agentName) ?? nonEmpty(replica.session.agentId) ?? "Agent"
        let facts = sessionFacts(session: replica.session, agentName: resolvedAgent)
        let items = exportItems(replica: replica)

        var blocks: [String] = ["# \(oneLine(title))"]
        if !facts.isEmpty {
            blocks.append(facts.map { "- \($0)" }.joined(separator: "\n"))
        }
        blocks.append("---")

        var inReply = false
        var steps: [String] = []
        func flushSteps() {
            if !steps.isEmpty {
                blocks.append(steps.map { "- \($0)" }.joined(separator: "\n"))
                steps.removeAll(keepingCapacity: true)
            }
        }

        for item in items {
            switch item {
            case .message(let heading, let body):
                flushSteps()
                blocks.append("## \(oneLine(heading))")
                if !body.isEmpty {
                    blocks.append(body)
                }
                inReply = false
            case .step(let text):
                if !inReply {
                    blocks.append("## \(oneLine(resolvedAgent))")
                    inReply = true
                }
                if !text.isEmpty {
                    steps.append(text)
                }
            case .reply(let text):
                if !inReply {
                    blocks.append("## \(oneLine(resolvedAgent))")
                    inReply = true
                }
                flushSteps()
                if !text.isEmpty {
                    blocks.append(text)
                }
            }
        }
        flushSteps()

        return blocks.joined(separator: "\n\n") + "\n"
    }

    public static func suggestedFilename(title: String?) -> String {
        guard let raw = title?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "conversation.md"
        }

        // Replace path separators, control characters, and reserved filename punctuation.
        let forbidden: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        var cleaned = ""
        cleaned.reserveCapacity(min(raw.count, maxFilenameChars))
        var lastWasDash = false

        for ch in raw {
            let isControl = ch.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) }
            if isControl || forbidden.contains(ch) || ch.isNewline {
                if !lastWasDash && !cleaned.isEmpty {
                    cleaned.append("-")
                    lastWasDash = true
                }
            } else if ch.isWhitespace {
                if !lastWasDash && !cleaned.isEmpty {
                    cleaned.append("-")
                    lastWasDash = true
                }
            } else {
                cleaned.append(ch)
                lastWasDash = (ch == "-")
            }
            if cleaned.count >= maxFilenameChars {
                break
            }
        }

        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ".- "))
        guard !trimmed.isEmpty else {
            return "conversation.md"
        }

        if trimmed.lowercased().hasSuffix(".md") {
            return trimmed
        }
        return "\(trimmed).md"
    }

    #if os(macOS)
    @MainActor
    public static func saveWithPanel(replica: ThreadReplica, agentName: String) async throws -> URL? {
        let panel = NSSavePanel()
        let markdownType = UTType(filenameExtension: "md") ?? .plainText
        panel.allowedContentTypes = [markdownType, .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedFilename(title: replica.session.title)

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        try await Task.detached(priority: .userInitiated) {
            let markdown = render(replica: replica, agentName: agentName)
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        }.value
        return url
    }
    #endif

    // MARK: - Helpers

    private static func resolvedTitle(_ title: String?) -> String {
        nonEmpty(title) ?? "Conversation"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func modelName(from session: SessionView) -> String? {
        guard let option = session.config.first(where: { $0.category == "model" && $0.type == "select" }) else {
            return nil
        }
        guard let selected = option.value.stringValue, !selected.isEmpty else {
            return nil
        }
        if let choiceName = option.choices?.first(where: { $0.value == selected })?.name,
           !choiceName.isEmpty {
            return choiceName
        }
        return selected
    }

    private static func sessionFacts(session: SessionView, agentName: String) -> [String] {
        var facts: [String] = []
        if let model = modelName(from: session) {
            facts.append("Agent: \(oneLine(agentName)) (\(oneLine(model)))")
        } else {
            facts.append("Agent: \(oneLine(agentName))")
        }
        if !session.projectPath.isEmpty {
            facts.append("Project: \(inlineCode(oneLine(session.projectPath)))")
        }
        if session.createdAt > 0, session.createdAt.isFinite {
            let seconds = session.createdAt > 1_000_000_000_000 ? session.createdAt / 1000.0 : session.createdAt
            let date = Date(timeIntervalSince1970: seconds)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            facts.append("Created: \(formatter.string(from: date))")
        }
        return facts
    }

    private static func exportItems(replica: ThreadReplica) -> [ExportItem] {
        var items: [ExportItem] = []
        let projectPath = replica.session.projectPath

        for entry in replica.entries {
            switch entry {
            case .user(let id, let text, let content, _, let approval, _):
                // Permission/approval answers are internal thread records.
                if approval { break }
                let extras = replica.entryExtras[id]
                if let from = extras?.from, let ended = from.ended {
                    let title = from.title.isEmpty ? from.sessionId : from.title
                    let status: String
                    switch ended.stopReason {
                    case "end_turn": status = "finished"
                    case "cancelled": status = "was stopped"
                    case "refusal": status = "declined"
                    case nil: status = "failed"
                    default: status = "hit a limit"
                    }
                    items.append(.step("\(ended.agent) session \"\(oneLine(title))\" \(status)"))
                    break
                }
                let heading: String
                if extras?.sarto == true {
                    heading = "Sarto"
                } else if let from = extras?.from {
                    let title = from.title.isEmpty ? from.sessionId : from.title
                    heading = "From \(oneLine(title))"
                } else if extras?.fromSession == true {
                    heading = "From session"
                } else {
                    heading = "You"
                }
                let body = content.isEmpty
                    ? text.trimmingCharacters(in: .whitespacesAndNewlines)
                    : userBody(content)
                items.append(.message(heading: heading, body: body))

            case .sessionMessage(_, let senderId, let content):
                let heading: String
                if let senderId = nonEmpty(senderId) {
                    heading = "From \(senderId)"
                } else {
                    heading = "From parent session"
                }
                items.append(.message(heading: heading, body: userBody(content)))

            case .agent(_, let markdown, _, _, let attachments):
                let text = formatBody(texts: [markdown], refs: attachments)
                if !text.isEmpty {
                    items.append(.reply(text))
                }

            case .tool(let data):
                items.append(.step(stepText(for: data, projectPath: projectPath)))

            case .subagent(_, let sessionId):
                if let sid = nonEmpty(sessionId) {
                    items.append(.step("Subagent: \(oneLine(sid))"))
                } else {
                    items.append(.step("Subagent"))
                }

            case .sessionStarted(_, let sessionId, _):
                if let sid = nonEmpty(sessionId) {
                    items.append(.step("Started session: \(oneLine(sid))"))
                } else {
                    items.append(.step("Started session"))
                }

            case .thought,
                 .plan,
                 .notice,
                 .turnEnd,
                 .compaction,
                 .takeover,
                 .git,
                 .artifact,
                 .memory,
                 .settingsChange,
                 .browserOrigin,
                 .controlAsk,
                 .controlNote,
                 .deviceAccess,
                 .surfaceAccess,
                 .computerApp,
                 .computerSetup,
                 .projectMcp,
                 .projectHooks,
                 .problemReport,
                 .marketPublish,
                 .unknown:
                break
            }
        }
        return items
    }

    private static func userBody(_ content: [UserContent]) -> String {
        var texts: [String] = []
        var refs: [ContentRef] = []
        for part in content {
            switch part {
            case .text(let s):
                texts.append(s)
            case .ref(let r):
                refs.append(r)
            }
        }
        return formatBody(texts: texts, refs: refs)
    }

    private static func formatBody(texts: [String], refs: [ContentRef]) -> String {
        var parts = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !refs.isEmpty {
            var imageIndex = 0
            let names = refs.map { ref -> String in
                let label = refName(ref, nextImageNumber: {
                    imageIndex += 1
                    return imageIndex
                })
                return inlineCode(oneLine(label))
            }
            parts.append("Attachments: \(names.joined(separator: ", "))")
        }

        return parts.joined(separator: "\n\n")
    }

    private static func refName(_ ref: ContentRef, nextImageNumber: () -> Int) -> String {
        switch ref {
        case .imageData, .imageBlob:
            return "Image \(nextImageNumber())"
        case .attachment(let info):
            return info.name
        case .link(let uri, let name):
            return name.isEmpty ? uri : name
        case .audio(_, _, let name):
            return name ?? "Audio"
        case .video(_, _, let name):
            return name ?? "Video"
        case .terminal(_, let name):
            return name
        case .page(_, let name):
            return name
        case .device(_, let name):
            return name
        case .unsupported(let label):
            return label
        case .other(let kind):
            return kind
        }
    }

    private static func stepText(for data: ToolEntryData, projectPath: String) -> String {
        let primaryPath = data.locations.first?.path
        let name: String

        switch data.toolKind {
        case "read", "edit", "delete", "move":
            let verb: String
            switch data.toolKind {
            case "read": verb = "Read"
            case "edit": verb = "Edit"
            case "delete": verb = "Delete"
            default: verb = "Move"
            }
            if let path = primaryPath, !path.isEmpty {
                let rel = relativeDisplayPath(path, projectPath: projectPath)
                name = "\(verb) \(inlineCode(oneLine(rel)))"
            } else {
                let fallback = nonEmpty(data.label) ?? nonEmpty(data.description) ?? data.title
                name = "\(verb) \(oneLine(fallback))"
            }

        case "execute":
            let cmd = nonEmpty(data.description)
                ?? firstNonEmptyLine(data.rawInput)
                ?? data.title
            name = "Run \(inlineCode(oneLine(cmd)))"

        case "search":
            let target = nonEmpty(data.description) ?? nonEmpty(data.label) ?? data.title
            name = "Search \(oneLine(target))"

        case "fetch":
            let target = nonEmpty(data.description) ?? nonEmpty(data.label) ?? data.title
            name = "Fetch \(oneLine(target))"

        default:
            let label = nonEmpty(data.label) ?? nonEmpty(data.description) ?? data.title
            name = oneLine(label)
        }

        let statusSuffix: String
        switch data.status {
        case "failed":
            statusSuffix = " (failed)"
        case "cancelled":
            statusSuffix = " (cancelled)"
        default:
            statusSuffix = ""
        }

        return "\(name)\(statusSuffix)"
    }

    private static func firstNonEmptyLine(_ text: String?) -> String? {
        guard let text else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func relativeDisplayPath(_ path: String, projectPath: String) -> String {
        guard !projectPath.isEmpty else { return path }
        let prefix = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }

    /// Formats text as a Markdown inline code span, choosing a backtick fence longer than any run inside.
    private static func inlineCode(_ text: String) -> String {
        var longestRun = 0
        var currentRun = 0
        for ch in text {
            if ch == "`" {
                currentRun += 1
                if currentRun > longestRun { longestRun = currentRun }
            } else {
                currentRun = 0
            }
        }
        let fence = String(repeating: "`", count: longestRun + 1)
        let pad = (text.hasPrefix("`") || text.hasSuffix("`")) ? " " : ""
        return "\(fence)\(pad)\(text)\(pad)\(fence)"
    }

    private static func oneLine(_ text: String) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= maxStepChars {
            return collapsed
        }
        let prefix = collapsed.prefix(maxStepChars - 1)
        return "\(prefix)…"
    }
}

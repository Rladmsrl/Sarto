import Foundation
import SartoProtocol
import PrismDesign
import SwiftUI
import WebKit
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

// MARK: - 1. Multi-Language Syntax Highlighter (Cached, Theme-Aware, Search-Highlightable)

public enum CodeSyntaxHighlighter {
    private struct CacheKey: Hashable {
        let code: String
        let language: String
        let palette: PrismPalette
    }

    private final class HighlightCache: @unchecked Sendable {
        private let lock = NSLock()
        private let store = ThreadLRUStore<CacheKey, AttributedString>(capacity: 384)

        func get(_ key: CacheKey) -> AttributedString? {
            lock.lock()
            defer { lock.unlock() }
            return store.value(for: key)
        }

        func set(_ value: AttributedString, for key: CacheKey) {
            lock.lock()
            defer { lock.unlock() }
            store.set(value, for: key)
        }
    }

    private static let cache = HighlightCache()

    private static let keywordsByFamily: [String: Set<String>] = [
        "swift": [
            "import", "struct", "class", "enum", "protocol", "extension", "actor", "func", "init", "deinit",
            "let", "var", "if", "else", "guard", "switch", "case", "default", "for", "in", "while", "repeat",
            "break", "continue", "return", "throw", "throws", "rethrows", "try", "catch", "async", "await",
            "public", "private", "fileprivate", "internal", "open", "static", "final", "override", "mutating",
            "nonisolated", "some", "any", "where", "as", "is", "nil", "true", "false", "self", "Self", "super",
            "typealias", "associatedtype", "weak", "unowned", "defer", "do", "inout", "consuming", "borrowing",
        ],
        "js": [
            "import", "export", "from", "default", "const", "let", "var", "function", "return", "if", "else",
            "switch", "case", "break", "continue", "for", "of", "in", "while", "do", "try", "catch", "finally",
            "throw", "new", "class", "extends", "implements", "interface", "type", "enum", "namespace", "async",
            "await", "yield", "typeof", "instanceof", "keyof", "readonly", "private", "public", "protected",
            "static", "abstract", "as", "is", "satisfies", "true", "false", "null", "undefined", "this", "super",
            "void", "never", "unknown", "any", "string", "number", "boolean",
        ],
        "python": [
            "import", "from", "as", "def", "class", "return", "yield", "if", "elif", "else", "for", "in", "while",
            "break", "continue", "pass", "try", "except", "finally", "raise", "with", "lambda", "async", "await",
            "and", "or", "not", "is", "None", "True", "False", "self", "cls", "global", "nonlocal", "del", "assert",
            "match", "case",
        ],
        "rust": [
            "fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "pub", "mod", "use", "crate",
            "super", "self", "Self", "if", "else", "match", "for", "in", "while", "loop", "break", "continue",
            "return", "async", "await", "move", "ref", "where", "type", "unsafe", "extern", "as", "dyn", "true", "false",
        ],
        "go": [
            "package", "import", "func", "type", "struct", "interface", "map", "chan", "var", "const", "if", "else",
            "switch", "case", "default", "select", "for", "range", "break", "continue", "return", "go", "defer",
            "fallthrough", "goto", "nil", "true", "false", "iota",
        ],
        "c": [
            "include", "define", "ifdef", "ifndef", "endif", "pragma", "struct", "union", "enum", "typedef", "class",
            "namespace", "template", "typename", "using", "public", "private", "protected", "virtual", "override",
            "const", "constexpr", "static", "extern", "inline", "volatile", "auto", "void", "bool", "char", "int",
            "float", "double", "long", "short", "unsigned", "signed", "if", "else", "switch", "case", "default",
            "for", "while", "do", "break", "continue", "return", "sizeof", "new", "delete", "nullptr", "true", "false",
            "fragment", "vertex", "kernel", "device", "constant", "thread",
        ],
        "shell": [
            "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac",
            "function", "return", "exit", "export", "local", "readonly", "set", "unset", "shift", "source",
            "true", "false", "echo", "cd", "pwd", "ls", "git", "pnpm", "npm", "npx", "swift", "xcodebuild", "curl",
        ],
        "sql": [
            "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE",
            "ALTER", "DROP", "INDEX", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "AS", "AND", "OR", "NOT",
            "NULL", "IS", "IN", "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET", "DISTINCT", "UNION", "CASE",
            "WHEN", "THEN", "ELSE", "END", "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "DEFAULT", "TRUE", "FALSE",
        ],
    ]

    private static func normalizedFamily(_ raw: String?) -> String {
        switch raw?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? "" {
        case "swift": return "swift"
        case "ts", "tsx", "typescript", "js", "jsx", "javascript", "mjs", "cjs": return "js"
        case "py", "python", "python3": return "python"
        case "rs", "rust": return "rust"
        case "go", "golang": return "go"
        case "c", "h", "cpp", "cc", "cxx", "hpp", "objc", "m", "mm", "metal", "msl", "glsl": return "c"
        case "sh", "bash", "zsh", "shell", "console", "terminal": return "shell"
        case "sql", "sqlite", "postgres", "postgresql", "mysql": return "sql"
        case "json", "jsonc", "json5": return "json"
        case "yaml", "yml", "toml", "ini": return "yaml"
        case "diff", "patch": return "diff"
        case "html", "xml", "svg", "css", "scss": return "markup"
        default: return "generic"
        }
    }

    public static func highlight(
        _ code: String,
        language: String?,
        tokens: PrismTokens,
        findQuery: String = ""
    ) -> AttributedString {
        let family = normalizedFamily(language)
        let trimmedQuery = findQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = CacheKey(
            code: code,
            language: family,
            palette: tokens.palette
        )
        let base: AttributedString
        if let hit = cache.get(key) {
            base = hit
        } else {
            let palette = tokens.codeSyntax
            let highlighted: AttributedString
            if family == "diff" {
                highlighted = highlightDiff(code, palette: palette)
            } else if family == "json" {
                highlighted = highlightJSON(code, palette: palette)
            } else if family == "yaml" {
                highlighted = highlightYAML(code, palette: palette)
            } else {
                highlighted = highlightCode(code, family: family, palette: palette)
            }
            cache.set(highlighted, for: key)
            base = highlighted
        }

        guard !trimmedQuery.isEmpty else { return base }
        var searched = base
        applySearchHighlights(to: &searched, query: trimmedQuery, isDark: tokens.palette.isDark)
        return searched
    }

    private static func append(_ out: inout AttributedString, _ text: String, color: Color, bold: Bool = false) {
        var piece = AttributedString(text)
        piece.foregroundColor = color
        if bold {
            piece.inlinePresentationIntent = .stronglyEmphasized
        }
        out.append(piece)
    }

    private static func highlightDiff(_ code: String, palette: PrismCodeSyntaxColors) -> AttributedString {
        var out = AttributedString()
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        for (idx, line) in lines.enumerated() {
            let s = String(line)
            let suffix = idx + 1 < lines.count ? "\n" : ""
            if s.hasPrefix("+++") || s.hasPrefix("---") || s.hasPrefix("@@") {
                append(&out, s + suffix, color: palette.type, bold: true)
            } else if s.hasPrefix("+") {
                append(&out, s + suffix, color: palette.added)
            } else if s.hasPrefix("-") {
                append(&out, s + suffix, color: palette.removed)
            } else {
                append(&out, s + suffix, color: palette.plain)
            }
        }
        return out
    }

    private static func highlightJSON(_ code: String, palette: PrismCodeSyntaxColors) -> AttributedString {
        var out = AttributedString()
        let chars = Array(code)
        let n = chars.count
        var i = 0
        while i < n {
            let c = chars[i]
            if c == "\"" {
                let start = i
                i += 1
                while i < n {
                    if chars[i] == "\\" && i + 1 < n { i += 2; continue }
                    if chars[i] == "\"" { i += 1; break }
                    i += 1
                }
                var look = i
                while look < n && (chars[look] == " " || chars[look] == "\t") { look += 1 }
                let isKey = look < n && chars[look] == ":"
                append(&out, String(chars[start..<i]), color: isKey ? palette.property : palette.string)
            } else if c == "/" && i + 1 < n && chars[i + 1] == "/" {
                let start = i
                while i < n && chars[i] != "\n" { i += 1 }
                append(&out, String(chars[start..<i]), color: palette.comment)
            } else if c.isNumber || (c == "-" && i + 1 < n && chars[i + 1].isNumber) {
                let start = i
                i += 1
                while i < n && (chars[i].isNumber || chars[i] == "." || chars[i] == "e" || chars[i] == "E" || chars[i] == "+" || chars[i] == "-") {
                    i += 1
                }
                append(&out, String(chars[start..<i]), color: palette.number)
            } else if c.isLetter {
                let start = i
                while i < n && chars[i].isLetter { i += 1 }
                let word = String(chars[start..<i])
                let col = (word == "true" || word == "false" || word == "null") ? palette.keyword : palette.plain
                append(&out, word, color: col)
            } else {
                let start = i
                i += 1
                while i < n && chars[i] != "\"" && chars[i] != "/" && !chars[i].isNumber && !chars[i].isLetter && chars[i] != "-" {
                    i += 1
                }
                append(&out, String(chars[start..<i]), color: palette.plain)
            }
        }
        return out
    }

    private static func highlightYAML(_ code: String, palette: PrismCodeSyntaxColors) -> AttributedString {
        var out = AttributedString()
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        for (idx, lineSub) in lines.enumerated() {
            let line = String(lineSub)
            let nl = idx + 1 < lines.count ? "\n" : ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                append(&out, line + nl, color: palette.comment)
            } else if let colon = line.firstIndex(of: ":"), !trimmed.hasPrefix("\"") {
                let head = String(line[...colon])
                let tail = String(line[line.index(after: colon)...])
                append(&out, head, color: palette.property)
                let tailTrim = tail.trimmingCharacters(in: .whitespaces)
                if tailTrim == "true" || tailTrim == "false" || tailTrim == "null" {
                    append(&out, tail + nl, color: palette.keyword)
                } else if tailTrim.hasPrefix("\"") || tailTrim.hasPrefix("'") {
                    append(&out, tail + nl, color: palette.string)
                } else if Double(tailTrim) != nil {
                    append(&out, tail + nl, color: palette.number)
                } else {
                    append(&out, tail + nl, color: palette.plain)
                }
            } else {
                append(&out, line + nl, color: palette.plain)
            }
        }
        return out
    }

    private static func highlightCode(_ code: String, family: String, palette: PrismCodeSyntaxColors) -> AttributedString {
        var out = AttributedString()
        let keywords = keywordsByFamily[family] ?? keywordsByFamily["swift"]!
        let hashComments = family == "python" || family == "shell" || family == "generic"
        let sqlUpper = family == "sql"
        let chars = Array(code)
        let n = chars.count
        var i = 0

        func isIdentStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
        func isIdentPart(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

        while i < n {
            let c = chars[i]

            // Line comments (// or -- for SQL or # for Python/Shell)
            if (c == "/" && i + 1 < n && chars[i + 1] == "/")
                || (sqlUpper && c == "-" && i + 1 < n && chars[i + 1] == "-")
                || (hashComments && c == "#") {
                let start = i
                while i < n && chars[i] != "\n" { i += 1 }
                append(&out, String(chars[start..<i]), color: palette.comment)
                continue
            }

            // Block comments /* ... */
            if c == "/" && i + 1 < n && chars[i + 1] == "*" {
                let start = i
                i += 2
                while i + 1 < n && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i = min(n, i + 2)
                append(&out, String(chars[start..<i]), color: palette.comment)
                continue
            }

            // Strings ("...", '...', `...`)
            if c == "\"" || c == "'" || c == "`" {
                let quote = c
                let start = i
                i += 1
                while i < n {
                    if chars[i] == "\\" && i + 1 < n { i += 2; continue }
                    if chars[i] == quote { i += 1; break }
                    if quote != "`" && chars[i] == "\n" { break }
                    i += 1
                }
                append(&out, String(chars[start..<i]), color: palette.string)
                continue
            }

            // Attributes / decorators / preprocessor (@MainActor, #if)
            if (c == "@" || (c == "#" && (family == "swift" || family == "c"))) && i + 1 < n && isIdentStart(chars[i + 1]) {
                let start = i
                i += 1
                while i < n && isIdentPart(chars[i]) { i += 1 }
                append(&out, String(chars[start..<i]), color: palette.attribute)
                continue
            }

            // Numbers (decimal, hex 0x...)
            if c.isNumber {
                let start = i
                i += 1
                while i < n && (chars[i].isHexDigit || chars[i] == "x" || chars[i] == "X" || chars[i] == "." || chars[i] == "_") {
                    i += 1
                }
                append(&out, String(chars[start..<i]), color: palette.number)
                continue
            }

            // Identifiers, keywords, and PascalCase types
            if isIdentStart(c) {
                let start = i
                i += 1
                while i < n && isIdentPart(chars[i]) { i += 1 }
                let word = String(chars[start..<i])
                let lookup = sqlUpper ? word.uppercased() : word
                if keywords.contains(lookup) {
                    append(&out, word, color: palette.keyword)
                } else if let first = word.first, first.isUppercase, word.count > 1 {
                    append(&out, word, color: palette.type)
                } else {
                    append(&out, word, color: palette.plain)
                }
                continue
            }

            // Batch punctuation & whitespace runs for speed
            let start = i
            i += 1
            while i < n {
                let next = chars[i]
                if isIdentStart(next) || next.isNumber || next == "\"" || next == "'" || next == "`"
                    || next == "/" || next == "@" || next == "#" || (sqlUpper && next == "-") {
                    break
                }
                i += 1
            }
            append(&out, String(chars[start..<i]), color: palette.plain)
        }
        return out
    }

    public static func applySearchHighlights(to attr: inout AttributedString, query: String, isDark: Bool) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        let plain = String(attr.characters)
        var searchStart = plain.startIndex
        let bg = isDark ? Color(hex: 0xF59E0B).opacity(0.42) : Color(hex: 0xFDE047).opacity(0.75)
        let fg = isDark ? Color(hex: 0xFFFBEB) : Color(hex: 0x111827)

        while searchStart < plain.endIndex,
              let range = plain.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<plain.endIndex) {
            if let attrRange = Range(range, in: attr) {
                attr[attrRange].backgroundColor = bg
                attr[attrRange].foregroundColor = fg
            }
            searchStart = range.upperBound
        }
    }
}

// MARK: - 2. Inline Markdown + Inline Math + Emoji + Search Highlight Engine

public enum InlineMarkdownEngine {
    private struct CacheKey: Hashable {
        let raw: String
        let isDark: Bool
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private let store = ThreadLRUStore<CacheKey, AttributedString>(capacity: 512)

        func get(_ key: CacheKey) -> AttributedString? {
            lock.lock()
            defer { lock.unlock() }
            return store.value(for: key)
        }

        func set(_ val: AttributedString, for key: CacheKey) {
            lock.lock()
            defer { lock.unlock() }
            store.set(val, for: key)
        }
    }

    private static let cache = Cache()

    private static let emojiMap: [String: String] = [
        ":rocket:": "🚀", ":warning:": "⚠️", ":bulb:": "💡", ":sparkles:": "✨",
        ":white_check_mark:": "✅", ":x:": "❌", ":fire:": "🔥", ":bug:": "🐛",
        ":wrench:": "🔧", ":memo:": "📝", ":tada:": "🎉", ":zap:": "⚡",
        ":lock:": "🔒", ":mag:": "🔍", ":package:": "📦", ":eyes:": "👀",
    ]

    public static func render(_ raw: String, findQuery: String = "", isDark: Bool) -> AttributedString? {
        let trimmedQuery = findQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = CacheKey(raw: raw, isDark: isDark)
        let base: AttributedString
        if let hit = cache.get(key) {
            base = hit
        } else {
            let pre = preprocessInline(raw)
            guard let parsed = try? AttributedString(
                markdown: pre,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) else { return nil }
            cache.set(parsed, for: key)
            base = parsed
        }
        guard !trimmedQuery.isEmpty else { return base }
        var searched = base
        CodeSyntaxHighlighter.applySearchHighlights(to: &searched, query: trimmedQuery, isDark: isDark)
        return searched
    }

    private static func preprocessInline(_ raw: String) -> String {
        var text = raw
        if text.contains(":") {
            for (code, emoji) in emojiMap where text.contains(code) {
                text = text.replacingOccurrences(of: code, with: emoji)
            }
        }
        if text.contains("$") {
            text = formatInlineLatexSpans(text)
        }
        return text
    }

    /// Prettifies inline `$...$` LaTeX spans outside code backticks into crisp typographic math symbols.
    private static func formatInlineLatexSpans(_ input: String) -> String {
        let chars = Array(input)
        let n = chars.count
        var out = ""
        var i = 0
        var inCode = false

        while i < n {
            if chars[i] == "`" {
                inCode.toggle()
                out.append(chars[i])
                i += 1
                continue
            }
            if !inCode && chars[i] == "$" && (i == 0 || chars[i - 1] != "\\") && !(i + 1 < n && chars[i + 1] == "$") {
                var j = i + 1
                while j < n && chars[j] != "\n" && !(chars[j] == "$" && chars[j - 1] != "\\") {
                    j += 1
                }
                if j < n && chars[j] == "$" && j > i + 1 {
                    let body = String(chars[(i + 1)..<j])
                    // Avoid matching currency like "$10 and $20"
                    let looksCurrency = body.first?.isNumber == true && body.contains(" ")
                    if !looksCurrency {
                        out.append(LatexMathConverter.toTypographicInline(body))
                        i = j + 1
                        continue
                    }
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }
}

// MARK: - 3. GitHub Alert Card (`[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`)

public struct GitHubAlertCardView: View {
    @Environment(\.prismTokens) private var tokens

    public let kind: GitHubAlertKind
    public let text: String
    public let findQuery: String

    public init(kind: GitHubAlertKind, text: String, findQuery: String = "") {
        self.kind = kind
        self.text = text
        self.findQuery = findQuery
    }

    private var accentColor: Color {
        switch kind {
        case .note: return tokens.prismCobalt
        case .tip: return tokens.success
        case .important: return tokens.prismIris
        case .warning: return tokens.warning
        case .caution: return tokens.danger
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: kind.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentColor)
                Text(kind.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentColor)
            }

            if !text.isEmpty {
                renderedInlineText(text)
                    .font(.system(size: 13.5))
                    .lineSpacing(4.5)
                    .foregroundStyle(tokens.foreground.opacity(0.92))
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .fill(accentColor.opacity(tokens.palette.isDark ? 0.10 : 0.06))
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(accentColor)
                .frame(width: 3)
                .padding(.vertical, 4)
        }
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(accentColor.opacity(0.26), lineWidth: 0.75)
        )
    }

    private func renderedInlineText(_ raw: String) -> Text {
        if let attr = InlineMarkdownEngine.render(raw, findQuery: findQuery, isDark: tokens.palette.isDark) {
            return Text(attr)
        }
        return Text(raw)
    }
}

// MARK: - 4. Offline Vector Renderer for SVG, Mermaid Diagrams & Native WebKit MathML

public enum OfflineDiagramKind: Sendable, Hashable {
    case svg(String)
    case mermaid(String)
    case math(String)

    public var title: String {
        switch self {
        case .svg: return "SVG"
        case .mermaid: return "Mermaid"
        case .math: return "Math"
        }
    }

    public var rawSource: String {
        switch self {
        case .svg(let s), .mermaid(let s), .math(let s): return s
        }
    }

    public var sourceLanguage: String {
        switch self {
        case .svg: return "svg"
        case .mermaid: return "mermaid"
        case .math: return "latex"
        }
    }
}

public struct OfflineDiagramCardView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let kind: OfflineDiagramKind
    public let findQuery: String

    @State private var showSource: Bool = false
    @State private var copied: Bool = false
    @State private var measuredHeight: CGFloat = 140
    @State private var showZoomSheet: Bool = false

    public init(kind: OfflineDiagramKind, findQuery: String = "") {
        self.kind = kind
        self.findQuery = findQuery
    }

    public var body: some View {
        let isDark = tokens.palette.isDark
        let compiledHTML = Self.cachedHTML(kind: kind, isDark: isDark)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tokens.prismCobalt)

                Text(kind.title)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tokens.secondaryForeground)

                Spacer()

                if compiledHTML != nil {
                    Button {
                        showSource.toggle()
                    } label: {
                        Text(showSource ? l10n.tr("thread.diagram.preview") : l10n.tr("thread.diagram.source"))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(tokens.mutedForeground)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(tokens.hoverWash.opacity(0.6)))
                    }
                    .buttonStyle(.plain)

                    if !showSource {
                        Button {
                            showZoomSheet = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(tokens.mutedForeground)
                        }
                        .buttonStyle(.plain)
                        .help(l10n.tr("thread.diagram.zoom"))
                    }
                }

                #if os(macOS)
                if case .svg(let svgCode) = kind {
                    Button {
                        saveSVGToDisk(svgCode)
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(tokens.mutedForeground)
                    }
                    .buttonStyle(.plain)
                    .help(l10n.tr("thread.diagram.downloadSvg"))
                }
                #endif

                Button {
                    copyRawSource()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(copied ? l10n.tr("thread.copied") : l10n.tr("thread.copy"))
                            .font(.system(size: 10.5))
                    }
                    .foregroundStyle(copied ? tokens.success : tokens.mutedForeground)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(tokens.codeHeaderBackground)

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            if let html = compiledHTML, !showSource {
                SandboxedHTMLView(
                    html: html,
                    measuredHeight: $measuredHeight,
                    minHeight: isMath ? 54 : 110,
                    maxHeight: 520
                )
                .frame(height: max(isMath ? 54 : 110, min(520, measuredHeight)))
                .background(tokens.codeBackground)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(CodeSyntaxHighlighter.highlight(kind.rawSource, language: kind.sourceLanguage, tokens: tokens, findQuery: findQuery))
                        .font(.system(size: 12, design: .monospaced))
                        .lineSpacing(3.5)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(tokens.codeBackground)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(tokens.borderEtched, lineWidth: 1)
        )
        .sheet(isPresented: $showZoomSheet) {
            if let html = compiledHTML {
                VStack(spacing: 0) {
                    HStack {
                        Text(kind.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tokens.foreground)
                        Spacer()
                        Button(l10n.tr("composer.previewClose")) { showZoomSheet = false }
                            .buttonStyle(.plain)
                            .foregroundStyle(tokens.primary)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 42)
                    .background(tokens.surface1)
                    Rectangle().fill(tokens.borderEtched).frame(height: 1)
                    SandboxedHTMLView(html: html, measuredHeight: .constant(560), minHeight: 520, maxHeight: 720, allowScroll: true)
                        .frame(minWidth: 680, minHeight: 480)
                        .background(tokens.codeBackground)
                }
            }
        }
    }

    private var isMath: Bool {
        if case .math = kind { return true }
        return false
    }

    private var iconName: String {
        switch kind {
        case .svg: return "scribble.variable"
        case .mermaid: return "point.3.connected.trianglepath.dotted"
        case .math: return "function"
        }
    }

    private func copyRawSource() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(kind.rawSource, forType: .string)
        #endif
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }

    #if os(macOS)
    private func saveSVGToDisk(_ svg: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.svg]
        panel.nameFieldStringValue = "diagram.svg"
        if panel.runModal() == .OK, let url = panel.url {
            try? svg.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    #endif

    private struct HTMLCacheKey: Hashable {
        let kind: OfflineDiagramKind
        let isDark: Bool
    }

    /// Compiled pages per diagram, so a parent re-render never recompiles a Mermaid chart.
    private final class HTMLCache: @unchecked Sendable {
        private let lock = NSLock()
        private let store = ThreadLRUStore<HTMLCacheKey, String?>(capacity: 64)

        func html(for key: HTMLCacheKey, build: () -> String?) -> String? {
            lock.lock()
            let hit = store.value(for: key)
            lock.unlock()
            if let hit { return hit }
            let made = build()
            lock.lock()
            store.set(made, for: key)
            lock.unlock()
            return made
        }
    }

    private static let htmlCache = HTMLCache()

    private static func cachedHTML(kind: OfflineDiagramKind, isDark: Bool) -> String? {
        htmlCache.html(for: HTMLCacheKey(kind: kind, isDark: isDark)) {
            buildHTML(kind: kind, isDark: isDark)
        }
    }

    private static func buildHTML(kind: OfflineDiagramKind, isDark: Bool) -> String? {
        let fg = isDark ? "#E6E9F2" : "#181C26"
        let bg = "transparent"
        let bodyContent: String

        switch kind {
        case .svg(let raw):
            let sanitized = sanitizeSVG(raw)
            guard sanitized.contains("<svg") else { return nil }
            bodyContent = "<div class=\"wrap\">\(sanitized)</div>"
        case .mermaid(let raw):
            guard let svg = OfflineMermaidCompiler.compileToSVG(raw, isDark: isDark) else { return nil }
            bodyContent = "<div class=\"wrap\">\(svg)</div>"
        case .math(let raw):
            let mathML = LatexMathConverter.toMathML(raw)
            bodyContent = "<div class=\"math-wrap\">\(mathML)</div>"
        }

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:;">
        <style>
          html, body {
            margin: 0; padding: 0; background: \(bg); color: \(fg);
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            overflow-x: auto;
          }
          .wrap {
            display: flex; justify-content: center; align-items: center;
            padding: 14px 16px; box-sizing: border-box;
          }
          .wrap svg { max-width: 100%; height: auto; display: block; }
          .math-wrap {
            display: flex; justify-content: center; align-items: center;
            padding: 14px 18px; font-size: 17px; line-height: 1.5; color: \(fg);
          }
          math { font-family: "STIX Two Math", "Cambria Math", "Times New Roman", serif; }
        </style>
        </head>
        <body>\(bodyContent)</body>
        </html>
        """
    }

    /// Strips `<script>`, `on*` event attributes, and `javascript:` URLs before handing SVG to WKWebView.
    private static func sanitizeSVG(_ raw: String) -> String {
        var s = raw
        let patterns = [
            "(?is)<script[^>]*>.*?</script>",
            "(?is)<foreignObject[^>]*>.*?</foreignObject>",
            "(?i)\\son[a-z]+\\s*=\\s*\"[^\"]*\"",
            "(?i)\\son[a-z]+\\s*=\\s*'[^']*'",
            "(?i)javascript:",
        ]
        for p in patterns {
            if let rx = try? NSRegularExpression(pattern: p) {
                s = rx.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
            }
        }
        return s
    }
}

#if os(macOS)
private final class NonHijackingWKWebView: WKWebView {
    var allowInnerScroll: Bool = false

    override func scrollWheel(with event: NSEvent) {
        if allowInnerScroll {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}

private struct SandboxedHTMLView: NSViewRepresentable {
    let html: String
    @Binding var measuredHeight: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    var allowScroll: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = NonHijackingWKWebView(frame: .zero, configuration: cfg)
        web.allowInnerScroll = allowScroll
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        context.coordinator.lastHTML = html
        web.loadHTMLString(html, baseURL: nil)
        return web
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if let custom = webView as? NonHijackingWKWebView {
            custom.allowInnerScroll = allowScroll
        }
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SandboxedHTMLView
        var lastHTML: String = ""

        init(parent: SandboxedHTMLView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("Math.ceil(document.body.scrollHeight)") { [weak self] val, _ in
                guard let self else { return }
                let h = (val as? NSNumber)?.doubleValue ?? Double(self.parent.minHeight)
                let clamped = max(self.parent.minHeight, min(self.parent.maxHeight, CGFloat(h)))
                Task { @MainActor in
                    if abs(self.parent.measuredHeight - clamped) > 1 {
                        self.parent.measuredHeight = clamped
                    }
                }
            }
        }
    }
}
#else
import UIKit

private struct SandboxedHTMLView: UIViewRepresentable {
    let html: String
    @Binding var measuredHeight: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    var allowScroll: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = allowScroll
        web.navigationDelegate = context.coordinator
        context.coordinator.lastHTML = html
        web.loadHTMLString(html, baseURL: nil)
        return web
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        webView.scrollView.isScrollEnabled = allowScroll
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SandboxedHTMLView
        var lastHTML: String = ""

        init(parent: SandboxedHTMLView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("Math.ceil(document.body.scrollHeight)") { [weak self] val, _ in
                guard let self else { return }
                let h = (val as? NSNumber)?.doubleValue ?? Double(self.parent.minHeight)
                let clamped = max(self.parent.minHeight, min(self.parent.maxHeight, CGFloat(h)))
                Task { @MainActor in
                    if abs(self.parent.measuredHeight - clamped) > 1 {
                        self.parent.measuredHeight = clamped
                    }
                }
            }
        }
    }
}
#endif

// MARK: - 4b. Offline LaTeX -> Native MathML & Inline Typographic Converter

public enum LatexMathConverter {
    private static let symbols: [(String, String)] = [
        ("\\Rightarrow", "⇒"), ("\\Leftarrow", "⇐"), ("\\Leftrightarrow", "⇔"),
        ("\\rightarrow", "→"), ("\\leftarrow", "←"), ("\\leftrightarrow", "↔"),
        ("\\to", "→"), ("\\mapsto", "↦"),
        ("\\leq", "≤"), ("\\le", "≤"), ("\\geq", "≥"), ("\\ge", "≥"),
        ("\\neq", "≠"), ("\\ne", "≠"), ("\\approx", "≈"), ("\\equiv", "≡"), ("\\sim", "∼"),
        ("\\pm", "±"), ("\\mp", "∓"), ("\\times", "×"), ("\\cdot", "·"), ("\\div", "÷"),
        ("\\infty", "∞"), ("\\partial", "∂"), ("\\nabla", "∇"),
        ("\\sum", "∑"), ("\\prod", "∏"), ("\\int", "∫"),
        ("\\forall", "∀"), ("\\exists", "∃"), ("\\in", "∈"), ("\\notin", "∉"),
        ("\\subset", "⊂"), ("\\subseteq", "⊆"), ("\\cup", "∪"), ("\\cap", "∩"), ("\\emptyset", "∅"),
        ("\\alpha", "α"), ("\\beta", "β"), ("\\gamma", "γ"), ("\\delta", "δ"),
        ("\\epsilon", "ε"), ("\\varepsilon", "ε"), ("\\zeta", "ζ"), ("\\eta", "η"),
        ("\\theta", "θ"), ("\\lambda", "λ"), ("\\mu", "μ"), ("\\nu", "ν"), ("\\xi", "ξ"),
        ("\\pi", "π"), ("\\rho", "ρ"), ("\\sigma", "σ"), ("\\tau", "τ"),
        ("\\phi", "φ"), ("\\varphi", "φ"), ("\\chi", "χ"), ("\\psi", "ψ"), ("\\omega", "ω"),
        ("\\Gamma", "Γ"), ("\\Delta", "Δ"), ("\\Theta", "Θ"), ("\\Lambda", "Λ"),
        ("\\Pi", "Π"), ("\\Sigma", "Σ"), ("\\Phi", "Φ"), ("\\Psi", "Ψ"), ("\\Omega", "Ω"),
        ("\\dots", "…"), ("\\ldots", "…"), ("\\cdots", "⋯"),
    ]

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "x": "ˣ", "y": "ʸ", "k": "ᵏ",
    ]

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "n": "ₙ", "x": "ₓ",
    ]

    public static func toTypographicInline(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for (cmd, sym) in symbols {
            s = s.replacingOccurrences(of: cmd, with: sym)
        }
        s = replaceUnary(s, command: "\\text") { $0 }
        s = replaceUnary(s, command: "\\mathrm") { $0 }
        s = replaceUnary(s, command: "\\mathbf") { $0 }
        s = replaceUnary(s, command: "\\sqrt") { "√(\($0))" }
        s = replaceBinary(s, command: "\\frac") { "(\($0))/(\($1))" }
        s = applyScripts(s, trigger: "^", map: superscripts)
        s = applyScripts(s, trigger: "_", map: subscripts)
        s = s.replacingOccurrences(of: "\\,", with: " ")
            .replacingOccurrences(of: "\\;", with: " ")
            .replacingOccurrences(of: "\\left", with: "")
            .replacingOccurrences(of: "\\right", with: "")
        return s
    }

    public static func toMathML(_ raw: String) -> String {
        let inner = parseMathMLFragment(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        return "<math xmlns=\"http://www.w3.org/1998/Math/MathML\" display=\"block\"><mrow>\(inner)</mrow></math>"
    }

    private static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func parseMathMLFragment(_ src: String) -> String {
        let chars = Array(src)
        let n = chars.count
        var i = 0
        var nodes: [String] = []

        func readGroup() -> String {
            while i < n && chars[i].isWhitespace { i += 1 }
            guard i < n else { return "" }
            if chars[i] == "{" {
                i += 1
                var depth = 1
                let start = i
                while i < n && depth > 0 {
                    if chars[i] == "{" { depth += 1 }
                    else if chars[i] == "}" { depth -= 1 }
                    if depth > 0 { i += 1 }
                }
                let content = String(chars[start..<i])
                if i < n && chars[i] == "}" { i += 1 }
                return content
            }
            if chars[i] == "\\" {
                let start = i
                i += 1
                while i < n && chars[i].isLetter { i += 1 }
                return String(chars[start..<i])
            }
            let ch = String(chars[i])
            i += 1
            return ch
        }

        while i < n {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }

            if c == "\\" {
                let start = i
                i += 1
                if i < n && !chars[i].isLetter {
                    let sym = String(chars[i])
                    i += 1
                    if sym == "\\" {
                        nodes.append("<mspace linebreak=\"newline\"/>")
                    } else if sym == "," || sym == ";" || sym == " " {
                        nodes.append("<mspace width=\"0.25em\"/>")
                    } else {
                        nodes.append("<mo>\(escapeXML(sym))</mo>")
                    }
                    continue
                }
                while i < n && chars[i].isLetter { i += 1 }
                let cmd = String(chars[start..<i])
                switch cmd {
                case "\\frac", "\\dfrac", "\\tfrac":
                    let num = parseMathMLFragment(readGroup())
                    let den = parseMathMLFragment(readGroup())
                    nodes.append("<mfrac><mrow>\(num)</mrow><mrow>\(den)</mrow></mfrac>")
                case "\\sqrt":
                    let body = parseMathMLFragment(readGroup())
                    nodes.append("<msqrt><mrow>\(body)</mrow></msqrt>")
                case "\\text", "\\textrm", "\\mathrm", "\\operatorname":
                    let t = readGroup()
                    nodes.append("<mtext>\(escapeXML(t))</mtext>")
                case "\\mathbf", "\\boldsymbol":
                    let inner = parseMathMLFragment(readGroup())
                    nodes.append("<mrow mathvariant=\"bold\">\(inner)</mrow>")
                case "\\left", "\\right":
                    continue
                default:
                    if let matched = symbols.first(where: { $0.0 == cmd }) {
                        nodes.append("<mo>\(escapeXML(matched.1))</mo>")
                    } else {
                        nodes.append("<mi>\(escapeXML(String(cmd.dropFirst())))</mi>")
                    }
                }
                continue
            }

            if c == "^" || c == "_" {
                i += 1
                let arg = parseMathMLFragment(readGroup())
                let base = nodes.popLast() ?? "<mrow></mrow>"
                if c == "^" {
                    nodes.append("<msup>\(base)<mrow>\(arg)</mrow></msup>")
                } else {
                    nodes.append("<msub>\(base)<mrow>\(arg)</mrow></msub>")
                }
                continue
            }

            if c == "{" {
                let inner = parseMathMLFragment(readGroup())
                nodes.append("<mrow>\(inner)</mrow>")
                continue
            }

            if c.isNumber {
                let start = i
                while i < n && (chars[i].isNumber || chars[i] == ".") { i += 1 }
                nodes.append("<mn>\(escapeXML(String(chars[start..<i])))</mn>")
                continue
            }

            if c.isLetter {
                nodes.append("<mi>\(escapeXML(String(c)))</mi>")
                i += 1
                continue
            }

            nodes.append("<mo>\(escapeXML(String(c)))</mo>")
            i += 1
        }
        return nodes.joined()
    }

    private static func replaceUnary(_ s: String, command: String, transform: (String) -> String) -> String {
        var out = s
        while let r = out.range(of: "\(command){") {
            let start = r.upperBound
            var depth = 1
            var cur = start
            while cur < out.endIndex && depth > 0 {
                let ch = out[cur]
                if ch == "{" { depth += 1 } else if ch == "}" { depth -= 1 }
                if depth > 0 { cur = out.index(after: cur) }
            }
            guard depth == 0 else { break }
            let inner = String(out[start..<cur])
            out.replaceSubrange(r.lowerBound...cur, with: transform(inner))
        }
        return out
    }

    private static func replaceBinary(_ s: String, command: String, transform: (String, String) -> String) -> String {
        var out = s
        while let r = out.range(of: "\(command){") {
            func readBraced(from idx: String.Index) -> (String, String.Index)? {
                guard idx < out.endIndex && out[idx] == "{" else { return nil }
                var depth = 1
                var cur = out.index(after: idx)
                let start = cur
                while cur < out.endIndex && depth > 0 {
                    let ch = out[cur]
                    if ch == "{" { depth += 1 } else if ch == "}" { depth -= 1 }
                    if depth > 0 { cur = out.index(after: cur) }
                }
                guard depth == 0 else { return nil }
                return (String(out[start..<cur]), out.index(after: cur))
            }
            let firstOpen = out.index(before: r.upperBound)
            guard let (a, afterA) = readBraced(from: firstOpen),
                  let (b, afterB) = readBraced(from: afterA) else { break }
            out.replaceSubrange(r.lowerBound..<afterB, with: transform(a, b))
        }
        return out
    }

    private static func applyScripts(_ s: String, trigger: Character, map: [Character: Character]) -> String {
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == trigger && i + 1 < chars.count {
                if chars[i + 1] == "{" {
                    var j = i + 2
                    while j < chars.count && chars[j] != "}" { j += 1 }
                    if j < chars.count {
                        let inner = chars[(i + 2)..<j]
                        if inner.allSatisfy({ map[$0] != nil }) {
                            for ch in inner { out.append(map[ch]!) }
                            i = j + 1
                            continue
                        }
                    }
                } else if let mapped = map[chars[i + 1]] {
                    out.append(mapped)
                    i += 2
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }
}

// MARK: - 4c. Offline Mermaid Flowchart / Sequence / State -> Vector SVG Compiler

public enum OfflineMermaidCompiler {
    private struct FlowNode {
        let id: String
        var label: String
        var shape: String // "rect" | "round" | "diamond" | "circle"
    }
    private struct FlowEdge {
        let from: String
        let to: String
        let label: String?
        let dashed: Bool
    }

    public static func compileToSVG(_ source: String, isDark: Bool) -> String? {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }
        guard let first = lines.first else { return nil }

        if first.hasPrefix("sequenceDiagram") {
            return compileSequence(lines: Array(lines.dropFirst()), isDark: isDark)
        }
        if first.hasPrefix("flowchart") || first.hasPrefix("graph") || first.hasPrefix("stateDiagram") {
            let isLR = first.contains("LR") || first.contains("RL")
            return compileFlow(lines: Array(lines.dropFirst()), horizontal: isLR, isDark: isDark)
        }
        return nil
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func compileFlow(lines: [String], horizontal: Bool, isDark: Bool) -> String? {
        var nodes: [String: FlowNode] = [:]
        var order: [String] = []
        var edges: [FlowEdge] = []

        func registerNode(_ rawToken: String) -> String {
            let trimmed = rawToken.trimmingCharacters(in: .whitespaces)
            let patterns: [(open: String, close: String, shape: String)] = [
                ("([", "])", "round"), ("((", "))", "circle"),
                ("{", "}", "diamond"), ("(", ")", "round"), ("[", "]", "rect"),
            ]
            for p in patterns {
                if let o = trimmed.range(of: p.open), let c = trimmed.range(of: p.close, options: .backwards), o.upperBound <= c.lowerBound {
                    let id = String(trimmed[..<o.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let lbl = String(trimmed[o.upperBound..<c.lowerBound])
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                    let key = id.isEmpty ? lbl : id
                    if nodes[key] == nil {
                        order.append(key)
                        nodes[key] = FlowNode(id: key, label: lbl.isEmpty ? key : lbl, shape: p.shape)
                    } else if !lbl.isEmpty {
                        nodes[key]?.label = lbl
                        nodes[key]?.shape = p.shape
                    }
                    return key
                }
            }
            let clean = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if nodes[clean] == nil {
                order.append(clean)
                nodes[clean] = FlowNode(id: clean, label: clean, shape: "rect")
            }
            return clean
        }

        let arrowTokens = ["-.->", "==>", "-->", "->", "---"]
        for line in lines {
            if line.hasPrefix("subgraph") || line == "end" || line.hasPrefix("style ") || line.hasPrefix("classDef") || line.hasPrefix("class ") {
                continue
            }
            var matched = false
            for arrow in arrowTokens {
                if let r = line.range(of: arrow) {
                    let left = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                    var right = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    var edgeLabel: String? = nil
                    if right.hasPrefix("|"), let endPipe = right.dropFirst().firstIndex(of: "|") {
                        edgeLabel = String(right[right.index(after: right.startIndex)..<endPipe]).trimmingCharacters(in: .whitespaces)
                        right = String(right[right.index(after: endPipe)...]).trimmingCharacters(in: .whitespaces)
                    }
                    guard !left.isEmpty, !right.isEmpty else { continue }
                    let fromID = registerNode(left)
                    let toID = registerNode(right)
                    edges.append(FlowEdge(from: fromID, to: toID, label: edgeLabel, dashed: arrow.contains(".")))
                    matched = true
                    break
                }
            }
            if !matched && (line.contains("[") || line.contains("(") || line.contains("{")) {
                _ = registerNode(line)
            }
        }

        guard !order.isEmpty else { return nil }

        // Topological layering (Kahn-style with cycle guard)
        var layer: [String: Int] = [:]
        for id in order { layer[id] = 0 }
        for _ in 0..<order.count {
            var changed = false
            for e in edges {
                let nextL = (layer[e.from] ?? 0) + 1
                if nextL > (layer[e.to] ?? 0) && nextL < order.count {
                    layer[e.to] = nextL
                    changed = true
                }
            }
            if !changed { break }
        }

        var buckets: [Int: [String]] = [:]
        for id in order { buckets[layer[id] ?? 0, default: []].append(id) }
        let maxLayer = buckets.keys.max() ?? 0

        let nodeW: Double = 148
        let nodeH: Double = 40
        let gapPrimary: Double = 64
        let gapCross: Double = 28
        let pad: Double = 24

        var pos: [String: (x: Double, y: Double)] = [:]
        var maxX: Double = 0
        var maxY: Double = 0

        for l in 0...maxLayer {
            let group = buckets[l] ?? []
            for (idx, id) in group.enumerated() {
                let x: Double
                let y: Double
                if horizontal {
                    x = pad + Double(l) * (nodeW + gapPrimary)
                    y = pad + Double(idx) * (nodeH + gapCross)
                } else {
                    x = pad + Double(idx) * (nodeW + gapCross)
                    y = pad + Double(l) * (nodeH + gapPrimary)
                }
                pos[id] = (x, y)
                maxX = max(maxX, x + nodeW)
                maxY = max(maxY, y + nodeH)
            }
        }

        let width = Int(maxX + pad)
        let height = Int(maxY + pad)
        let fill = isDark ? "#1B1F2B" : "#FFFFFF"
        let stroke = isDark ? "#3B82F6" : "#2563EB"
        let edgeStroke = isDark ? "#6B768F" : "#64748B"
        let textCol = isDark ? "#E6E9F2" : "#181C26"
        let labelBg = isDark ? "#131620" : "#F8FAFC"

        var svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(width) \(height)" width="\(width)" height="\(height)">
        <defs>
          <marker id="pk-arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6.5" markerHeight="6.5" orient="auto-start-reverse">
            <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="\(edgeStroke)"/>
          </marker>
        </defs>
        """

        for e in edges {
            guard let p1 = pos[e.from], let p2 = pos[e.to] else { continue }
            let x1 = horizontal ? (p1.x + nodeW) : (p1.x + nodeW / 2)
            let y1 = horizontal ? (p1.y + nodeH / 2) : (p1.y + nodeH)
            let x2 = horizontal ? p2.x : (p2.x + nodeW / 2)
            let y2 = horizontal ? (p2.y + nodeH / 2) : p2.y
            let mx = (x1 + x2) / 2
            let my = (y1 + y2) / 2
            let dash = e.dashed ? " stroke-dasharray=\"5,4\"" : ""
            svg += "<path d=\"M \(x1) \(y1) Q \(mx) \(horizontal ? y1 : my) \(x2) \(y2)\" fill=\"none\" stroke=\"\(edgeStroke)\" stroke-width=\"1.5\"\(dash) marker-end=\"url(#pk-arrow)\"/>"
            if let lbl = e.label, !lbl.isEmpty {
                let lw = max(36, Double(lbl.count) * 7.2 + 12)
                svg += "<rect x=\"\(mx - lw / 2)\" y=\"\(my - 10)\" width=\"\(lw)\" height=\"18\" rx=\"4\" fill=\"\(labelBg)\"/>"
                svg += "<text x=\"\(mx)\" y=\"\(my + 3)\" text-anchor=\"middle\" font-size=\"10.5\" fill=\"\(edgeStroke)\">\(esc(lbl))</text>"
            }
        }

        for id in order {
            guard let node = nodes[id], let p = pos[id] else { continue }
            let rx = node.shape == "round" || node.shape == "circle" ? "18" : "8"
            if node.shape == "diamond" {
                let cx = p.x + nodeW / 2
                let cy = p.y + nodeH / 2
                svg += "<polygon points=\"\(cx),\(p.y - 4) \(p.x + nodeW + 4),\(cy) \(cx),\(p.y + nodeH + 4) \(p.x - 4),\(cy)\" fill=\"\(fill)\" stroke=\"\(stroke)\" stroke-width=\"1.4\"/>"
            } else {
                svg += "<rect x=\"\(p.x)\" y=\"\(p.y)\" width=\"\(nodeW)\" height=\"\(nodeH)\" rx=\"\(rx)\" fill=\"\(fill)\" stroke=\"\(stroke)\" stroke-width=\"1.4\"/>"
            }
            let clipped = node.label.count > 22 ? String(node.label.prefix(21)) + "…" : node.label
            svg += "<text x=\"\(p.x + nodeW / 2)\" y=\"\(p.y + nodeH / 2 + 4)\" text-anchor=\"middle\" font-size=\"12\" font-weight=\"500\" fill=\"\(textCol)\">\(esc(clipped))</text>"
        }

        svg += "</svg>"
        return svg
    }

    private static func compileSequence(lines: [String], isDark: Bool) -> String? {
        var actors: [String] = []
        var msgs: [(from: String, to: String, label: String, dashed: Bool)] = []

        func addActor(_ a: String) {
            let clean = a.trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty && !actors.contains(clean) { actors.append(clean) }
        }

        let arrows = ["-->>", "->>", "-->", "->"]
        for line in lines {
            if line.hasPrefix("participant ") || line.hasPrefix("actor ") {
                let name = line.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
                addActor(name.components(separatedBy: " as ").first ?? name)
                continue
            }
            for arr in arrows {
                if let r = line.range(of: arr) {
                    let from = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let rest = String(line[r.upperBound...])
                    let parts = rest.split(separator: ":", maxSplits: 1).map(String.init)
                    let to = parts[0].trimmingCharacters(in: .whitespaces)
                    let lbl = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                    addActor(from)
                    addActor(to)
                    msgs.append((from, to, lbl, arr.hasPrefix("--")))
                    break
                }
            }
        }

        guard !actors.isEmpty else { return nil }
        let colW: Double = 152
        let pad: Double = 24
        let headerH: Double = 34
        let rowH: Double = 42
        let width = Int(pad * 2 + Double(actors.count) * colW)
        let height = Int(pad * 2 + headerH + Double(max(1, msgs.count)) * rowH + 24)
        let fill = isDark ? "#1B1F2B" : "#FFFFFF"
        let stroke = isDark ? "#3B82F6" : "#2563EB"
        let lineCol = isDark ? "#4B5563" : "#94A3B8"
        let textCol = isDark ? "#E6E9F2" : "#181C26"

        func centerX(_ actor: String) -> Double {
            let idx = actors.firstIndex(of: actor) ?? 0
            return pad + Double(idx) * colW + colW / 2
        }

        var svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(width) \(height)" width="\(width)" height="\(height)">
        <defs>
          <marker id="pk-seq-arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6.5" markerHeight="6.5" orient="auto-start-reverse">
            <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="\(stroke)"/>
          </marker>
        </defs>
        """

        for actor in actors {
            let cx = centerX(actor)
            svg += "<line x1=\"\(cx)\" y1=\"\(pad + headerH)\" x2=\"\(cx)\" y2=\"\(Double(height) - pad)\" stroke=\"\(lineCol)\" stroke-dasharray=\"4,4\" stroke-width=\"1\"/>"
            svg += "<rect x=\"\(cx - 56)\" y=\"\(pad)\" width=\"112\" height=\"\(headerH)\" rx=\"7\" fill=\"\(fill)\" stroke=\"\(stroke)\" stroke-width=\"1.3\"/>"
            svg += "<text x=\"\(cx)\" y=\"\(pad + 21)\" text-anchor=\"middle\" font-size=\"11.5\" font-weight=\"600\" fill=\"\(textCol)\">\(esc(actor))</text>"
        }

        for (idx, m) in msgs.enumerated() {
            let y = pad + headerH + 28 + Double(idx) * rowH
            let x1 = centerX(m.from)
            let x2 = centerX(m.to)
            let dash = m.dashed ? " stroke-dasharray=\"5,4\"" : ""
            svg += "<line x1=\"\(x1)\" y1=\"\(y)\" x2=\"\(x2)\" y2=\"\(y)\" stroke=\"\(stroke)\" stroke-width=\"1.4\"\(dash) marker-end=\"url(#pk-seq-arrow)\"/>"
            if !m.label.isEmpty {
                let mx = (x1 + x2) / 2
                svg += "<text x=\"\(mx)\" y=\"\(y - 6)\" text-anchor=\"middle\" font-size=\"11\" fill=\"\(textCol)\">\(esc(m.label))</text>"
            }
        }
        svg += "</svg>"
        return svg
    }
}

// MARK: - 5. ANSI-Colored Shell Block View (for `execute` tool steps)

/// Longest line drawn in a lazy line list; a single multi-megabyte line would stall layout.
private let threadLineCharacterLimit = 4000

private func cappedLine<S: StringProtocol>(_ line: S) -> String {
    guard line.utf8.count > threadLineCharacterLimit else { return String(line) }
    return String(line.prefix(threadLineCharacterLimit)) + "…"
}

/// ANSI output parsed into styled lines once per distinct text.
private struct ANSIParsedOutput: Sendable {
    struct Run: Sendable {
        let text: String
        let fgCode: Int?
        let isBold: Bool
    }

    let lines: [[Run]]

    static let empty = ANSIParsedOutput(lines: [])

    init(lines: [[Run]]) {
        self.lines = lines
    }

    init(parsing output: String) {
        var lines: [[Run]] = [[]]
        for span in ANSITerminalParser.parse(output) {
            let pieces = span.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (idx, piece) in pieces.enumerated() {
                if idx > 0 { lines.append([]) }
                var text = piece
                if text.last == "\r" { text = text.dropLast() }
                guard !text.isEmpty else { continue }
                lines[lines.count - 1].append(Run(text: String(text), fgCode: span.fgCode, isBold: span.isBold))
            }
        }
        if lines.count > 1, lines[lines.count - 1].isEmpty {
            lines.removeLast()
        }
        self.lines = lines
    }
}

private final class ANSIParseCache: @unchecked Sendable {
    static let shared = ANSIParseCache()

    private let lock = NSLock()
    private let store = ThreadLRUStore<String, ANSIParsedOutput>(capacity: 48)

    func parsed(_ output: String) -> ANSIParsedOutput {
        lock.lock()
        let hit = store.value(for: output)
        lock.unlock()
        if let hit { return hit }
        let made = ANSIParsedOutput(parsing: output)
        lock.lock()
        store.set(made, for: output)
        lock.unlock()
        return made
    }
}

/// Remembers the last parse per view so an unchanged output skips even the cache's hashing; the
/// string comparison is a pointer check while the output keeps its storage.
@MainActor
private final class ANSIOutputMemo {
    private var source: String?
    private var parsed = ANSIParsedOutput.empty

    func parsed(for output: String) -> ANSIParsedOutput {
        if source == output { return parsed }
        parsed = ANSIParseCache.shared.parsed(output)
        source = output
        return parsed
    }
}

/// Fixed-height monospaced rows laid out lazily in a scroll area of bounded height, so expanding
/// long output never lays out every line at once. Scrolls both ways; each row is handed the
/// viewport width so a row background can span it.
struct ThreadLazyLinesScrollView<Row: View>: View {
    let lineCount: Int
    let rowHeight: CGFloat
    let maxHeight: CGFloat
    @ViewBuilder let row: (_ index: Int, _ minWidth: CGFloat) -> Row

    @State private var viewportWidth: CGFloat = 0

    private static var verticalPadding: CGFloat { 6 }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(0..<lineCount, id: \.self) { idx in
                    row(idx, viewportWidth)
                        .frame(height: rowHeight, alignment: .leading)
                }
            }
            .padding(.vertical, Self.verticalPadding)
        }
        .scrollIndicators(.automatic)
        .frame(height: min(maxHeight, CGFloat(lineCount) * rowHeight + Self.verticalPadding * 2))
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            if abs(viewportWidth - width) > 0.5 {
                viewportWidth = width
            }
        }
    }
}

public struct ANSIShellBlockView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let command: String?
    public let output: String
    public let isFailed: Bool
    public let findQuery: String
    public let onRunInTerminal: ((String) -> Void)?

    @State private var expanded: Bool = false
    @State private var copied: Bool = false
    @State private var memo = ANSIOutputMemo()

    private static let previewLines = 12
    private static let longOutputLines = 20
    private static let rowHeight: CGFloat = 17
    private static let expandedMaxHeight: CGFloat = 420

    public init(
        command: String?,
        output: String,
        isFailed: Bool = false,
        findQuery: String = "",
        onRunInTerminal: ((String) -> Void)? = nil
    ) {
        self.command = command
        self.output = output
        self.isFailed = isFailed
        self.findQuery = findQuery
        self.onRunInTerminal = onRunInTerminal
    }

    public var body: some View {
        let parsed = output.isEmpty ? ANSIParsedOutput.empty : memo.parsed(for: output)
        let lineCount = parsed.lines.count
        let isLong = lineCount > Self.longOutputLines
        let hiddenCount = max(0, lineCount - Self.previewLines)

        VStack(alignment: .leading, spacing: 0) {
            if let command, !command.isEmpty {
                HStack(spacing: 6) {
                    Text("$")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(isFailed ? tokens.danger : tokens.primary)
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tokens.foreground.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                    Spacer(minLength: 6)
                    if let onRunInTerminal {
                        Button {
                            onRunInTerminal(command)
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(tokens.mutedForeground)
                        }
                        .buttonStyle(.plain)
                        .help(l10n.tr("thread.code.runInTerminal"))
                    }
                    Button {
                        #if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        #endif
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.2))
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(copied ? tokens.success : tokens.mutedForeground)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(tokens.codeHeaderBackground)
                if !output.isEmpty {
                    Rectangle().fill(tokens.borderEtched).frame(height: 1)
                }
            }

            if !output.isEmpty {
                Group {
                    if expanded && isLong {
                        ThreadLazyLinesScrollView(
                            lineCount: lineCount,
                            rowHeight: Self.rowHeight,
                            maxHeight: Self.expandedMaxHeight
                        ) { idx, _ in
                            Text(renderLines(parsed.lines[idx...idx]))
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .textSelection(.enabled)
                                .padding(.horizontal, 10)
                        }
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(renderLines(parsed.lines.prefix(isLong ? Self.previewLines : lineCount)))
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .background(tokens.codeBackground)

                if isLong {
                    Rectangle().fill(tokens.borderEtched).frame(height: 1)
                    Button {
                        expanded.toggle()
                    } label: {
                        Text(expanded ? l10n.tr("thread.code.showLess") : l10n.tr("thread.code.showMore", hiddenCount))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(tokens.mutedForeground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(tokens.codeHeaderBackground.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                .strokeBorder(isFailed ? tokens.danger.opacity(0.35) : tokens.borderEtched, lineWidth: 1)
        )
    }

    private func renderLines(_ lines: ArraySlice<[ANSIParsedOutput.Run]>) -> AttributedString {
        let isDark = tokens.palette.isDark
        var attr = AttributedString()
        for (offset, line) in lines.enumerated() {
            if offset > 0 { attr.append(AttributedString("\n")) }
            var budget = threadLineCharacterLimit
            for run in line {
                guard budget > 0 else { break }
                let text: String
                if run.text.utf8.count > budget {
                    text = String(run.text.prefix(budget)) + "…"
                    budget = 0
                } else {
                    text = run.text
                    budget -= text.utf8.count
                }
                var piece = AttributedString(text)
                piece.foregroundColor = ansiColor(code: run.fgCode, isDark: isDark)
                if run.isBold {
                    piece.inlinePresentationIntent = .stronglyEmphasized
                }
                attr.append(piece)
            }
        }
        if !findQuery.isEmpty {
            CodeSyntaxHighlighter.applySearchHighlights(to: &attr, query: findQuery, isDark: isDark)
        }
        return attr
    }

    private func ansiColor(code: Int?, isDark: Bool) -> Color {
        guard let code else { return tokens.foreground.opacity(0.9) }
        switch code {
        case 30, 90: return tokens.mutedForeground
        case 31, 91: return tokens.danger
        case 32, 92: return tokens.success
        case 33, 93: return tokens.warning
        case 34, 94: return tokens.prismCobalt
        case 35, 95: return tokens.prismIris
        case 36, 96: return isDark ? Color(hex: 0x38BDF8) : Color(hex: 0x0284C7)
        default: return tokens.foreground.opacity(0.92)
        }
    }
}

// MARK: - 5b. Plain Tool Output Block (bounded preview, lazy full view)

/// The body of tool output markdown without its single wrapping code fence, if it has one.
func threadStripOuterFence(_ markdown: String) -> String {
    let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("```"), let firstNL = trimmed.firstIndex(of: "\n") else { return markdown }
    let body = trimmed[trimmed.index(after: firstNL)...]
    if body.hasSuffix("\n```") {
        return String(body.dropLast(4))
    }
    if body.hasSuffix("```") {
        return String(body.dropLast(3))
    }
    return markdown
}

/// Tool output markdown, unfenced, trimmed and split into capped lines once per distinct text.
@MainActor
private final class ToolOutputMemo {
    private var source: String?
    private(set) var lines: [String] = []

    func lines(for markdown: String) -> [String] {
        if source == markdown { return lines }
        source = markdown
        let trimmed = threadStripOuterFence(markdown).trimmingCharacters(in: .whitespacesAndNewlines)
        lines = trimmed.isEmpty
            ? []
            : trimmed.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                cappedLine(line.last == "\r" ? line.dropLast() : line)
            }
        return lines
    }
}

/// Plain tool output. The preview is bounded so huge output never becomes one giant `Text`;
/// expanding lays the full output out lazily, line by line.
struct ThreadToolOutputBlock: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    let markdown: String

    @State private var expanded = false
    @State private var memo = ToolOutputMemo()

    private static let previewLineLimit = 40
    private static let previewCharacterLimit = 8000
    private static let rowHeight: CGFloat = 17
    private static let expandedMaxHeight: CGFloat = 420

    var body: some View {
        let lines = memo.lines(for: markdown)
        if !lines.isEmpty {
            let preview = Self.preview(of: lines)
            VStack(alignment: .leading, spacing: 0) {
                if expanded && preview.isTruncated {
                    ThreadLazyLinesScrollView(
                        lineCount: lines.count,
                        rowHeight: Self.rowHeight,
                        maxHeight: Self.expandedMaxHeight
                    ) { idx, _ in
                        Text(lines[idx])
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .textSelection(.enabled)
                            .padding(.horizontal, 9)
                    }
                } else {
                    ScrollView {
                        Text(preview.text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                    }
                    .frame(maxHeight: 168)
                }

                if preview.isTruncated {
                    Rectangle().fill(tokens.borderEtched).frame(height: 1)
                    Button {
                        expanded.toggle()
                    } label: {
                        Text(expanded ? l10n.tr("thread.output.collapse") : l10n.tr("thread.output.showAll", lines.count))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(tokens.mutedForeground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(tokens.codeHeaderBackground.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(tokens.codeBackground)
            .clipShape(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                    .strokeBorder(tokens.borderEtched, lineWidth: 1)
            )
        }
    }

    private static func preview(of lines: [String]) -> (text: String, isTruncated: Bool) {
        var shown: [String] = []
        var characters = 0
        for line in lines.prefix(previewLineLimit) {
            characters += line.utf8.count + 1
            if characters > previewCharacterLimit && !shown.isEmpty { break }
            shown.append(line)
        }
        return (shown.joined(separator: "\n"), shown.count < lines.count)
    }
}

// MARK: - 5c. Expanded Diff Lines (lazy)

/// Every line of a diff, laid out lazily in a bounded scroll area so "Show all" on a huge diff
/// never builds thousands of rows at once.
struct ThreadDiffLinesView: View {
    let lines: [DiffLine]

    private static let maxHeight: CGFloat = 480

    var body: some View {
        ThreadLazyLinesScrollView(
            lineCount: lines.count,
            rowHeight: ThreadDiffLineRow.height,
            maxHeight: Self.maxHeight
        ) { idx, minWidth in
            ThreadDiffLineRow(line: lines[idx], minWidth: minWidth)
        }
    }
}

/// One unified-diff line: sign gutter, text and the added / deleted wash.
struct ThreadDiffLineRow: View {
    @Environment(\.prismTokens) private var tokens

    let line: DiffLine
    var minWidth: CGFloat = 0

    static let height: CGFloat = 17

    var body: some View {
        HStack(spacing: 8) {
            Text(line.kind == .added ? "+" : (line.kind == .deleted ? "-" : " "))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(
                    line.kind == .added ? tokens.success
                        : (line.kind == .deleted ? tokens.danger : tokens.placeholder)
                )
                .frame(width: 10)

            Text(line.text.utf8.count > threadLineCharacterLimit ? cappedLine(line.text) : line.text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(
                    line.kind == .added ? tokens.foreground
                        : (line.kind == .deleted ? tokens.secondaryForeground : tokens.mutedForeground)
                )
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .frame(minWidth: minWidth, maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
        .background(
            line.kind == .added ? tokens.successSoft
                : (line.kind == .deleted ? tokens.dangerSoft : Color.clear)
        )
    }
}

// MARK: - 6. Standalone Markdown Local / Remote Image Block

/// A project image file read and decoded off the main thread.
private struct LoadedProjectImage: Sendable {
    let key: String
    let data: Data
    let image: Image
    let fileName: String
    let fileURL: URL
}

/// Decoded project images by path and modification time, so a row scrolled back into view does
/// not read and decode its file again.
private final class ProjectImageCache: @unchecked Sendable {
    static let shared = ProjectImageCache()

    private final class Box {
        let value: LoadedProjectImage
        init(_ value: LoadedProjectImage) { self.value = value }
    }

    private let cache = NSCache<NSString, Box>()

    private init() {
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 64
    }

    func value(for key: String) -> LoadedProjectImage? {
        cache.object(forKey: key as NSString)?.value
    }

    func set(_ value: LoadedProjectImage) {
        cache.setObject(Box(value), forKey: value.key as NSString, cost: value.data.count)
    }
}

public struct MarkdownImageBlockView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let alt: String
    public let url: String
    public let projectPath: String
    public let onPreview: (PrismImagePreviewItem) -> Void

    @State private var loadedLocalImage: LoadedProjectImage? = nil
    @State private var remoteLoadApproved = false

    /// Remote images the user chose to load in this run of the app, so the choice survives the
    /// row being recycled while scrolling.
    @MainActor private static var approvedRemoteURLs: Set<String> = []

    public init(alt: String, url: String, projectPath: String, onPreview: @escaping (PrismImagePreviewItem) -> Void) {
        self.alt = alt
        self.url = url
        self.projectPath = projectPath
        self.onPreview = onPreview
    }

    public var body: some View {
        Group {
            if let local = loadedLocalImage {
                Button {
                    onPreview(PrismImagePreviewItem(
                        title: alt.isEmpty ? local.fileName : alt,
                        data: local.data
                    ))
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        local.image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 420, maxHeight: 280)
                            .clipShape(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                    .strokeBorder(tokens.borderEtched, lineWidth: 1)
                            )
                        if !alt.isEmpty {
                            Text(alt)
                                .font(.system(size: 11))
                                .foregroundStyle(tokens.mutedForeground)
                        }
                    }
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .contextMenu {
                    Button {
                        onPreview(PrismImagePreviewItem(
                            title: alt.isEmpty ? local.fileName : alt,
                            data: local.data
                        ))
                    } label: {
                        Label(l10n.tr("workbench.preview"), systemImage: "magnifyingglass")
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([local.fileURL])
                    } label: {
                        Label(l10n.tr("contextMenu.revealInFinder"), systemImage: "folder")
                    }
                }
                #endif
            } else if let remote = Self.remoteURL(url) {
                if remoteLoadApproved || Self.approvedRemoteURLs.contains(remote.absoluteString) {
                    remoteImage(remote)
                } else {
                    remotePlaceholder(remote)
                }
            }
        }
        .task(id: "\(projectPath)|\(url)") {
            let raw = url
            let root = projectPath
            let loaded = await Task.detached(priority: .utility) {
                Self.loadProjectImage(raw: raw, projectPath: root)
            }.value
            guard !Task.isCancelled else { return }
            if loadedLocalImage?.key != loaded?.key {
                loadedLocalImage = loaded
            }
        }
    }

    /// Fetching a remote image on render would let a prompt-injected agent leak data through
    /// the URL without any click, so remote images wait for the user to ask for them.
    private func remotePlaceholder(_ remote: URL) -> some View {
        Button {
            Self.approvedRemoteURLs.insert(remote.absoluteString)
            remoteLoadApproved = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.mutedForeground)
                Text(alt.isEmpty ? (remote.host ?? remote.absoluteString) : alt)
                    .font(.system(size: 11.5))
                    .foregroundStyle(tokens.secondaryForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(l10n.tr("thread.image.loadRemote"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(tokens.primary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.surface2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(remote.absoluteString)
    }

    private func remoteImage(_ remote: URL) -> some View {
        AsyncImage(url: remote) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 420, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous))
            default:
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.mutedForeground)
                    Text(alt.isEmpty ? url : alt)
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.secondaryForeground)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.surface2))
            }
        }
    }

    private static func remoteURL(_ raw: String) -> URL? {
        guard let remote = URL(string: raw),
              let scheme = remote.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return remote
    }

    private nonisolated static func loadProjectImage(raw: String, projectPath: String) -> LoadedProjectImage? {
        guard let safeURL = containedProjectImageURL(raw: raw, projectPath: projectPath) else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: safeURL.path))?[.modificationDate] as? Date
        let key = "\(safeURL.path)|\(modified?.timeIntervalSince1970 ?? 0)"
        if let hit = ProjectImageCache.shared.value(for: key) {
            return hit
        }
        guard let data = try? Data(contentsOf: safeURL),
              data.count <= 20 * 1024 * 1024,
              let img = PrismImageDecoder.swiftUIImage(from: data, cacheKey: "project-image:\(key)")
        else { return nil }
        let made = LoadedProjectImage(key: key, data: data, image: img, fileName: safeURL.lastPathComponent, fileURL: safeURL)
        ProjectImageCache.shared.set(made)
        return made
    }

    /// Resolves local image paths ONLY inside `projectPath` after symlink canonicalization,
    /// blocking arbitrary `/Users/...`, `file://`, or `../../` path traversal reads.
    private nonisolated static func containedProjectImageURL(raw: String, projectPath: String) -> URL? {
        guard !projectPath.isEmpty, !raw.isEmpty, !raw.contains("://"), !raw.hasPrefix("/") else {
            return nil
        }
        let rootResolved = URL(fileURLWithPath: projectPath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = rootResolved.path.hasSuffix("/") ? rootResolved.path : (rootResolved.path + "/")
        let candidate = rootResolved.appendingPathComponent(raw).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(rootPrefix),
              FileManager.default.fileExists(atPath: candidate.path)
        else {
            return nil
        }
        return candidate
    }
}

#if os(macOS)
// MARK: - 7. Unified Multi-Block Markdown Prose View (Continuous Selection Across Paragraphs/Lists)

/// Renders a contiguous run of Markdown prose blocks (headings, paragraphs, bullet/ordered lists,
/// blockquotes, and dividers) inside a single read-only AppKit NSTextView so users can drag-select
/// smoothly across multiple lines, headings, paragraphs, and list items without stopping at each
/// SwiftUI Text boundary.
public struct ThreadProseContextMenuConfig {
    public let l10n: PrismL10n
    public let motionTier: PrismMotionTier
    public let reduceMotion: Bool
    public let entryID: String
    public let fullReplyMarkdown: String
    public let isRemoteConnection: Bool
    public let onOpenURLInBrowser: ((URL) -> Void)?
    public let onQuoteReply: ((String) -> Void)?
    public let onRequestPassageComment: ((String, String) -> Void)?
    public let onFindInSession: ((String?) -> Void)?

    public init(
        l10n: PrismL10n,
        motionTier: PrismMotionTier = .ultra,
        reduceMotion: Bool = false,
        entryID: String = "",
        fullReplyMarkdown: String = "",
        isRemoteConnection: Bool = false,
        onOpenURLInBrowser: ((URL) -> Void)? = nil,
        onQuoteReply: ((String) -> Void)? = nil,
        onRequestPassageComment: ((String, String) -> Void)? = nil,
        onFindInSession: ((String?) -> Void)? = nil
    ) {
        self.l10n = l10n
        self.motionTier = motionTier
        self.reduceMotion = reduceMotion
        self.entryID = entryID
        self.fullReplyMarkdown = fullReplyMarkdown
        self.isRemoteConnection = isRemoteConnection
        self.onOpenURLInBrowser = onOpenURLInBrowser
        self.onQuoteReply = onQuoteReply
        self.onRequestPassageComment = onRequestPassageComment
        self.onFindInSession = onFindInSession
    }
}

public struct ThreadProseTextView: NSViewRepresentable {
    public let blocks: [MarkdownBlock]
    public let tokens: PrismTokens
    public let typography: PrismTypographyPrefs
    public let findQuery: String
    public let projectPath: String
    public let onOpenProjectFile: ((String) -> Void)?
    public let contextMenuConfig: ThreadProseContextMenuConfig?

    public init(
        blocks: [MarkdownBlock],
        tokens: PrismTokens,
        typography: PrismTypographyPrefs,
        findQuery: String,
        projectPath: String,
        onOpenProjectFile: ((String) -> Void)?,
        contextMenuConfig: ThreadProseContextMenuConfig? = nil
    ) {
        self.blocks = blocks
        self.tokens = tokens
        self.typography = typography
        self.findQuery = findQuery
        self.projectPath = projectPath
        self.onOpenProjectFile = onOpenProjectFile
        self.contextMenuConfig = contextMenuConfig
    }

    public struct RenderKey: Equatable {
        let blocks: [MarkdownBlock]
        let palette: PrismPalette
        let accentMode: PrismAccentMode
        let radiusBase: CGFloat
        let typography: PrismTypographyPrefs
        let findQuery: String
    }

    private var currentKey: RenderKey {
        RenderKey(
            blocks: blocks,
            palette: tokens.palette,
            accentMode: tokens.accentMode,
            radiusBase: tokens.radiusBase,
            typography: typography,
            findQuery: findQuery
        )
    }

    /// Resolves either a `file://` URL or a scheme-less relative/absolute file path link against `projectPath`.
    public static func resolveLocalFilePath(url: URL, projectPath: String) -> String? {
        if url.isFileURL {
            return url.path.isEmpty ? nil : url.path
        }
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme.isEmpty else { return nil }
        let raw = url.path.isEmpty ? (url.absoluteString.removingPercentEncoding ?? url.absoluteString) : url.path
        let stripped = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }
        guard !projectPath.isEmpty else { return trimmed }
        return URL(fileURLWithPath: projectPath, isDirectory: true)
            .appendingPathComponent(trimmed)
            .standardizedFileURL.path
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            projectPath: projectPath,
            tokens: tokens,
            onOpenProjectFile: onOpenProjectFile,
            contextMenuConfig: contextMenuConfig
        )
    }

    public func makeNSView(context: Context) -> ThreadProseNSTextView {
        let view = ThreadProseNSTextView.makeConfigured()
        view.delegate = context.coordinator
        view.onContextMenuRequest = { [weak coordinator = context.coordinator, weak view] event in
            guard let coordinator, let view else { return }
            coordinator.presentContextMenu(for: view, event: event)
        }
        apply(to: view, context: context)
        return view
    }

    public func updateNSView(_ nsView: ThreadProseNSTextView, context: Context) {
        context.coordinator.projectPath = projectPath
        context.coordinator.tokens = tokens
        context.coordinator.onOpenProjectFile = onOpenProjectFile
        context.coordinator.contextMenuConfig = contextMenuConfig
        apply(to: nsView, context: context)
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: ThreadProseNSTextView,
        context: Context
    ) -> CGSize? {
        // SwiftUI can query sizeThatFits before updateNSView after a state change; apply first so
        // the measurement always reflects the current blocks.
        apply(to: nsView, context: context)
        let width: CGFloat = {
            if let proposed = proposal.width, proposed.isFinite {
                return max(40, proposed)
            }
            if nsView.bounds.width >= 40 {
                return nsView.bounds.width
            }
            return 760
        }()
        let height = nsView.measuredHeight(forWidth: width)
        return CGSize(width: width, height: height)
    }

    private func apply(to nsView: ThreadProseNSTextView, context: Context) {
        let key = currentKey
        nsView.appearance = NSAppearance(named: tokens.palette.isDark ? .darkAqua : .aqua)
        nsView.blockquoteBarColor = NSColor(tokens.prismCobalt.opacity(0.45))
        nsView.dividerLineColor = NSColor(tokens.borderEtched)
        nsView.linkTextAttributes = [
            .foregroundColor: NSColor(tokens.primary),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        guard nsView.lastRenderKey != key else { return }
        let attr = ThreadProseAttributedBuilder.build(
            blocks: blocks,
            tokens: tokens,
            typography: typography,
            findQuery: findQuery
        )
        nsView.applyAttributedString(attr, key: key)
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var projectPath: String
        var tokens: PrismTokens
        var onOpenProjectFile: ((String) -> Void)?
        var contextMenuConfig: ThreadProseContextMenuConfig?

        init(
            projectPath: String,
            tokens: PrismTokens,
            onOpenProjectFile: ((String) -> Void)?,
            contextMenuConfig: ThreadProseContextMenuConfig?
        ) {
            self.projectPath = projectPath
            self.tokens = tokens
            self.onOpenProjectFile = onOpenProjectFile
            self.contextMenuConfig = contextMenuConfig
        }

        public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL?
            if let u = link as? URL {
                url = u
            } else if let s = link as? String {
                url = URL(string: s)
            } else {
                url = nil
            }
            guard let url else { return true }
            if let filePath = ThreadProseTextView.resolveLocalFilePath(url: url, projectPath: projectPath) {
                // Agent text must never hand a local file to the system, which could launch it.
                if let onOpenProjectFile {
                    let rel = ThreadTimelineBuilder.relativeDisplayPath(filePath, projectPath: projectPath)
                    onOpenProjectFile(rel)
                }
                return true
            }
            switch url.scheme?.lowercased() {
            case "http", "https", "mailto":
                NSWorkspace.shared.open(url)
            default:
                break
            }
            return true
        }

        func presentContextMenu(for textView: ThreadProseNSTextView, event: NSEvent) {
            let l10n = contextMenuConfig?.l10n ?? PrismL10n(language: PrismLanguage.loadSaved())
            let motionTier = contextMenuConfig?.motionTier ?? .ultra
            let reduceMotion = contextMenuConfig?.reduceMotion ?? false
            let localPoint = textView.convert(event.locationInWindow, from: nil)
            let hitLink = textView.hitTestLink(at: localPoint)
            let selectedText = textView.cleanedSelectedText()
            let clickedParagraph = textView.cleanedParagraphText(at: localPoint)

            var header: PrismContextMenuHeader? = nil
            var entries: [PrismContextMenuEntry] = []

            if let hit = hitLink {
                let url = hit.url
                if let filePath = ThreadProseTextView.resolveLocalFilePath(url: url, projectPath: projectPath) {
                    let relPath = ThreadTimelineBuilder.relativeDisplayPath(filePath, projectPath: projectPath)
                    let fileName = URL(fileURLWithPath: filePath).lastPathComponent
                    let subtitle = (relPath != fileName && !relPath.isEmpty) ? relPath : nil
                    header = PrismContextMenuHeader(
                        icon: Self.symbolName(forFilePath: filePath),
                        title: fileName.isEmpty ? relPath : fileName,
                        subtitle: subtitle
                    )

                    if let openProjectFile = onOpenProjectFile {
                        entries.append(.action(PrismContextMenuItem(
                            id: "link.openInWorkbench",
                            title: l10n.tr("contextMenu.openInWorkbench"),
                            systemImage: "doc.text.magnifyingglass",
                            role: .primary
                        ) {
                            openProjectFile(relPath)
                        }))
                    }

                    let isRemote = contextMenuConfig?.isRemoteConnection ?? false
                    if !isRemote && FileManager.default.fileExists(atPath: filePath) {
                        entries.append(.action(PrismContextMenuItem(
                            id: "link.revealInFinder",
                            title: l10n.tr("contextMenu.revealInFinder"),
                            systemImage: "folder"
                        ) {
                            // Highlights the file in Finder without executing it.
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
                        }))
                    }

                    entries.append(.action(PrismContextMenuItem(
                        id: "link.copyRelativePath",
                        title: l10n.tr("contextMenu.copyRelativePath"),
                        systemImage: "doc.on.doc"
                    ) {
                        Self.copyToPasteboard(relPath)
                    }))

                    if filePath != relPath && !filePath.isEmpty {
                        entries.append(.action(PrismContextMenuItem(
                            id: "link.copyFullPath",
                            title: l10n.tr("contextMenu.copyFullPath"),
                            systemImage: "link"
                        ) {
                            Self.copyToPasteboard(filePath)
                        }))
                    }
                } else {
                    let scheme = url.scheme?.lowercased() ?? ""
                    let isWeb = scheme == "http" || scheme == "https"
                    let isMail = scheme == "mailto"

                    if isWeb {
                        let host = url.host ?? url.absoluteString
                        header = PrismContextMenuHeader(
                            icon: "globe",
                            title: host,
                            subtitle: url.absoluteString == host ? nil : url.absoluteString
                        )
                        entries.append(.action(PrismContextMenuItem(
                            id: "link.openInBrowser",
                            title: l10n.tr("contextMenu.openInBrowser"),
                            systemImage: "safari",
                            role: .primary
                        ) {
                            NSWorkspace.shared.open(url)
                        }))
                        if let openInSartoBrowser = contextMenuConfig?.onOpenURLInBrowser {
                            entries.append(.action(PrismContextMenuItem(
                                id: "link.openInSartoBrowser",
                                title: l10n.tr("contextMenu.openInSartoBrowser"),
                                systemImage: "macwindow"
                            ) {
                                openInSartoBrowser(url)
                            }))
                        }
                    } else if isMail {
                        let address = url.absoluteString.replacingOccurrences(
                            of: "mailto:",
                            with: "",
                            options: [.anchored, .caseInsensitive]
                        )
                        header = PrismContextMenuHeader(
                            icon: "envelope",
                            title: address.isEmpty ? url.absoluteString : address,
                            subtitle: nil
                        )
                        entries.append(.action(PrismContextMenuItem(
                            id: "link.openMail",
                            title: l10n.tr("contextMenu.openInBrowser"),
                            systemImage: "envelope.open",
                            role: .primary
                        ) {
                            NSWorkspace.shared.open(url)
                        }))
                    }

                    entries.append(.action(PrismContextMenuItem(
                        id: "link.copyURL",
                        title: l10n.tr("contextMenu.copyLink"),
                        systemImage: "link"
                    ) {
                        Self.copyToPasteboard(url.absoluteString)
                    }))
                }

                entries.append(.separator(id: "sep.afterLink"))
            }

            if let selected = selectedText {
                entries.append(.action(PrismContextMenuItem(
                    id: "text.copy",
                    title: l10n.tr("contextMenu.copy"),
                    systemImage: "doc.on.doc",
                    shortcut: "⌘C"
                ) {
                    Self.copyToPasteboard(selected)
                }))
            }

            let passageFallback = selectedText
                ?? clickedParagraph
                ?? contextMenuConfig.flatMap { cfg in
                    let trimmed = cfg.fullReplyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : ThreadTimelineBuilder.truncateSingleLine(trimmed, maxChars: 240)
                }

            if let onQuoteReply = contextMenuConfig?.onQuoteReply, let passage = passageFallback {
                entries.append(.action(PrismContextMenuItem(
                    id: "thread.quoteReply",
                    title: l10n.tr("contextMenu.quoteReply"),
                    systemImage: "quote.opening"
                ) {
                    onQuoteReply(passage)
                }))
            }

            if let onRequestComment = contextMenuConfig?.onRequestPassageComment,
               let passage = passageFallback,
               let entryID = contextMenuConfig?.entryID
            {
                entries.append(.action(PrismContextMenuItem(
                    id: "thread.addComment",
                    title: l10n.tr("contextMenu.addComment"),
                    systemImage: "text.bubble"
                ) {
                    onRequestComment(entryID, passage)
                }))
            }

            if let onFind = contextMenuConfig?.onFindInSession {
                let searchSeed = selectedText.flatMap { raw -> String? in
                    let oneLine = raw
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !oneLine.isEmpty else { return nil }
                    return String(oneLine.prefix(120))
                }
                entries.append(.action(PrismContextMenuItem(
                    id: "thread.findInSession",
                    title: l10n.tr("contextMenu.findInSession"),
                    systemImage: "magnifyingglass",
                    shortcut: "⌘F"
                ) {
                    onFind(searchSeed)
                }))
            }

            entries.append(.separator(id: "sep.beforeReply"))

            entries.append(.action(PrismContextMenuItem(
                id: "text.selectAll",
                title: l10n.tr("contextMenu.selectBlock"),
                systemImage: "selection.pin.in.out",
                shortcut: "⌘A"
            ) { [weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
                textView.selectAll(nil)
            }))

            if let fullMarkdown = contextMenuConfig?.fullReplyMarkdown,
               !fullMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                entries.append(.action(PrismContextMenuItem(
                    id: "reply.copyMarkdown",
                    title: l10n.tr("contextMenu.copyFullReply"),
                    systemImage: "doc.on.clipboard"
                ) {
                    Self.copyToPasteboard(fullMarkdown)
                }))
            }

            let screenPoint = textView.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            PrismContextMenuPresenter.shared.present(
                header: header,
                items: entries,
                at: screenPoint,
                parentWindow: textView.window,
                tokens: tokens,
                motionTier: motionTier,
                reduceMotion: reduceMotion
            )
        }

        private static func copyToPasteboard(_ text: String) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }

        private static func symbolName(forFilePath path: String) -> String {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return "folder"
            }
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            switch ext {
            case "md", "markdown", "txt", "rst", "rtf":
                return "doc.text"
            case "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rs", "go", "c", "h", "cpp", "hpp",
                 "m", "mm", "metal", "json", "jsonc", "yaml", "yml", "toml", "sh", "zsh", "bash", "css",
                 "scss", "html", "xml", "sql", "rb", "java", "kt":
                return "chevron.left.forwardslash.chevron.right"
            case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "pdf":
                return "photo"
            default:
                return "doc"
            }
        }
    }
}

public final class ThreadProseNSTextView: NSTextView {
    static let blockquoteKey = NSAttributedString.Key("prism.blockquote")
    static let dividerKey = NSAttributedString.Key("prism.divider")

    private static weak var activeSelectionView: ThreadProseNSTextView?

    var lastRenderKey: ThreadProseTextView.RenderKey?
    private var heightCache: [Int: CGFloat] = [:]
    private var isSyncingContainer = false
    var blockquoteBarColor: NSColor = .controlAccentColor
    var dividerLineColor: NSColor = .separatorColor
    var onContextMenuRequest: ((NSEvent) -> Void)?

    static func makeConfigured() -> ThreadProseNSTextView {
        // Construct an explicit TextKit 1 stack so usedRect sizing and custom blockquote/divider
        // background drawing remain deterministic without runtime TextKit 2 fallback transitions.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)

        let tv = ThreadProseNSTextView(frame: .zero, textContainer: container)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isRichText = true
        tv.importsGraphics = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainerInset = .zero
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.usesFindBar = false
        tv.allowsUndo = false
        return tv
    }

    func applyAttributedString(_ attr: NSAttributedString, key: ThreadProseTextView.RenderKey) {
        let priorSelection = selectedRange()
        if let storage = textStorage {
            storage.beginEditing()
            storage.setAttributedString(attr)
            storage.endEditing()
            if priorSelection.length > 0 {
                let maxLen = storage.length
                let loc = min(priorSelection.location, maxLen)
                let len = min(priorSelection.length, maxLen - loc)
                if len > 0 {
                    setSelectedRange(NSRange(location: loc, length: len))
                }
            }
        }
        lastRenderKey = key
        heightCache.removeAll(keepingCapacity: true)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        let clampedWidth = max(40, width.isFinite ? width : 760)
        let cacheKey = Int((clampedWidth * 2).rounded())
        if let cached = heightCache[cacheKey] {
            return cached
        }
        guard let container = textContainer, let lm = layoutManager else { return 20 }
        let restoreWidth: CGFloat? = bounds.width >= 40 ? bounds.width : nil
        // Mutating containerSize synchronously triggers NSTextView.setFrameSize with the previous
        // frame width; guard re-entrancy so setFrameSize never clobbers the width being measured,
        // then restore the live wrap width after speculative SwiftUI probes.
        isSyncingContainer = true
        defer {
            if let restoreWidth, abs(container.containerSize.width - restoreWidth) > 0.5 {
                container.containerSize = NSSize(width: restoreWidth, height: CGFloat.greatestFiniteMagnitude)
                lm.ensureLayout(for: container)
            }
            isSyncingContainer = false
        }
        container.containerSize = NSSize(width: clampedWidth, height: CGFloat.greatestFiniteMagnitude)
        lm.ensureLayout(for: container)
        let used = lm.usedRect(for: container)
        let glyphRange = lm.glyphRange(for: container)
        let glyphBounds = glyphRange.length > 0
            ? lm.boundingRect(forGlyphRange: glyphRange, in: container)
            : .zero
        let height = max(18, ceil(max(used.maxY, glyphBounds.maxY)) + 2)
        heightCache[cacheKey] = height
        return height
    }

    public override func setFrameSize(_ newSize: NSSize) {
        if isSyncingContainer { return }
        super.setFrameSize(newSize)
        if newSize.width > 0, let container = textContainer {
            let target = NSSize(width: newSize.width, height: CGFloat.greatestFiniteMagnitude)
            if abs(container.containerSize.width - target.width) > 0.5 {
                isSyncingContainer = true
                container.containerSize = target
                layoutManager?.ensureLayout(for: container)
                isSyncingContainer = false
                needsDisplay = true
            }
        }
    }

    public override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let onContextMenuRequest {
            onContextMenuRequest(event)
            return
        }
        if let prev = Self.activeSelectionView, prev !== self, prev.selectedRange().length > 0 {
            prev.setSelectedRange(NSRange(location: 0, length: 0))
        }
        Self.activeSelectionView = self
        super.mouseDown(with: event)
    }

    public override func rightMouseDown(with event: NSEvent) {
        if let onContextMenuRequest {
            onContextMenuRequest(event)
            return
        }
        super.rightMouseDown(with: event)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        // Handled by PrismContextMenuPresenter in rightMouseDown / Ctrl+Click.
        nil
    }

    func cleanedSelectedText() -> String? {
        let sel = selectedRange()
        guard sel.length > 0, let full = textStorage?.string as NSString?, NSMaxRange(sel) <= full.length else {
            return nil
        }
        let cleaned = Self.cleanPlainText(full.substring(with: sel)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    func hitTestLink(at localPoint: NSPoint) -> (url: URL, displayText: String)? {
        guard let storage = textStorage,
              let lm = layoutManager,
              let tc = textContainer,
              storage.length > 0
        else { return nil }

        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: localPoint.x - origin.x, y: localPoint.y - origin.y)
        var fraction: CGFloat = 0
        let glyphIndex = lm.glyphIndex(for: containerPoint, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        guard glyphIndex < lm.numberOfGlyphs else { return nil }

        let glyphRect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: tc)
        guard glyphRect.insetBy(dx: -2, dy: -3).contains(containerPoint) else { return nil }

        let charIndex = lm.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < storage.length else { return nil }

        var effectiveRange = NSRange(location: 0, length: 0)
        guard let rawLink = storage.attribute(.link, at: charIndex, effectiveRange: &effectiveRange) else {
            return nil
        }
        let url: URL?
        if let u = rawLink as? URL {
            url = u
        } else if let s = rawLink as? String {
            url = URL(string: s)
        } else {
            url = nil
        }
        guard let resolvedURL = url else { return nil }
        let full = storage.string as NSString
        let display = NSMaxRange(effectiveRange) <= full.length
            ? Self.cleanPlainText(full.substring(with: effectiveRange))
            : resolvedURL.absoluteString
        return (resolvedURL, display)
    }

    func cleanedParagraphText(at localPoint: NSPoint) -> String? {
        guard let storage = textStorage,
              let lm = layoutManager,
              let tc = textContainer,
              storage.length > 0
        else { return nil }

        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: localPoint.x - origin.x, y: localPoint.y - origin.y)
        let charIndex = lm.characterIndex(for: containerPoint, in: tc, fractionOfDistanceBetweenInsertionPoints: nil)
        guard charIndex < storage.length else { return nil }

        let full = storage.string as NSString
        let paraRange = full.paragraphRange(for: NSRange(location: charIndex, length: 0))
        guard NSMaxRange(paraRange) <= full.length else { return nil }
        let cleaned = Self.cleanPlainText(full.substring(with: paraRange))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return ThreadTimelineBuilder.truncateSingleLine(cleaned, maxChars: 360)
    }

    public override func copy(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length > 0, let full = textStorage?.string as NSString?, NSMaxRange(sel) <= full.length else {
            super.copy(sender)
            return
        }
        let cleaned = Self.cleanPlainText(full.substring(with: sel))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cleaned, forType: .string)
    }

    static func cleanPlainText(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{200B}", with: "")
    }

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let storage = textStorage,
              let lm = layoutManager,
              let tc = textContainer,
              storage.length > 0
        else { return }
        let fullRange = NSRange(location: 0, length: storage.length)

        storage.enumerateAttribute(Self.blockquoteKey, in: fullRange) { value, range, _ in
            guard (value as? Bool) == true else { return }
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }
            let box = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            let barRect = NSRect(x: 0, y: box.minY + 1, width: 2, height: max(4, box.height - 2))
            if barRect.intersects(rect) {
                blockquoteBarColor.setFill()
                NSBezierPath(roundedRect: barRect, xRadius: 1, yRadius: 1).fill()
            }
        }

        storage.enumerateAttribute(Self.dividerKey, in: fullRange) { value, range, _ in
            guard (value as? Bool) == true else { return }
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }
            let box = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            let lineRect = NSRect(x: 0, y: floor(box.midY), width: bounds.width, height: 1)
            if lineRect.intersects(rect) {
                dividerLineColor.setFill()
                lineRect.fill()
            }
        }
    }
}

@MainActor
private enum ThreadProseAttributedBuilder {
    static func build(
        blocks: [MarkdownBlock],
        tokens: PrismTokens,
        typography: PrismTypographyPrefs,
        findQuery: String
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let isDark = tokens.palette.isDark
        let fgColor = NSColor(tokens.foreground)
        let bodyColor = NSColor(tokens.foreground.opacity(0.94))
        let secondaryColor = NSColor(tokens.secondaryForeground)
        let mutedColor = NSColor(tokens.mutedForeground)
        let bulletColor = NSColor(tokens.mutedForeground.opacity(0.75))
        let linkColor = NSColor(tokens.primary)
        let inlineCodeBg = NSColor(tokens.surface2.opacity(isDark ? 0.85 : 0.90))
        let searchBg = NSColor(isDark ? Color(hex: 0xF59E0B).opacity(0.42) : Color(hex: 0xFDE047).opacity(0.75))
        let searchFg = NSColor(isDark ? Color(hex: 0xFFFBEB) : Color(hex: 0x111827))

        func appendNewlineIfNeeded() {
            if out.length > 0 {
                let prevAttrs = out.attributes(at: out.length - 1, effectiveRange: nil)
                var nlAttrs: [NSAttributedString.Key: Any] = [:]
                if let style = prevAttrs[.paragraphStyle] {
                    nlAttrs[.paragraphStyle] = style
                }
                if let font = prevAttrs[.font] {
                    nlAttrs[.font] = font
                }
                out.append(NSAttributedString(string: "\n", attributes: nlAttrs))
            }
        }

        for (bIdx, block) in blocks.enumerated() {
            let isFirst = bIdx == 0
            let isLast = bIdx == blocks.count - 1

            switch block {
            case .heading(_, let level, let text):
                appendNewlineIfNeeded()
                let size: CGFloat = level == 1 ? 18 : (level == 2 ? 16.5 : 15)
                let para = NSMutableParagraphStyle()
                para.lineSpacing = 3
                para.paragraphSpacingBefore = isFirst ? 0 : (level <= 2 ? 10 : 6)
                para.paragraphSpacing = isLast ? 0 : 6
                appendInline(
                    text,
                    to: out,
                    baseSize: size,
                    baseWeight: .semibold,
                    baseColor: fgColor,
                    paragraphStyle: para,
                    extraAttributes: [:],
                    typography: typography,
                    findQuery: findQuery,
                    isDark: isDark,
                    linkColor: linkColor,
                    inlineCodeBg: inlineCodeBg,
                    searchBg: searchBg,
                    searchFg: searchFg
                )

            case .paragraph(_, let text):
                appendNewlineIfNeeded()
                let para = NSMutableParagraphStyle()
                para.lineSpacing = 5
                para.paragraphSpacing = isLast ? 0 : 10
                appendInline(
                    text,
                    to: out,
                    baseSize: 14.5,
                    baseWeight: .regular,
                    baseColor: bodyColor,
                    paragraphStyle: para,
                    extraAttributes: [:],
                    typography: typography,
                    findQuery: findQuery,
                    isDark: isDark,
                    linkColor: linkColor,
                    inlineCodeBg: inlineCodeBg,
                    searchBg: searchBg,
                    searchFg: searchFg
                )

            case .bulletList(_, let items):
                for (iIdx, item) in items.enumerated() {
                    appendNewlineIfNeeded()
                    let isLastItem = iIdx == items.count - 1
                    let para = NSMutableParagraphStyle()
                    para.lineSpacing = 4.5
                    para.firstLineHeadIndent = 6
                    para.headIndent = 19
                    para.tabStops = [NSTextTab(textAlignment: .left, location: 19)]
                    para.paragraphSpacing = isLastItem ? (isLast ? 0 : 10) : 5
                    let bulletPrefix = NSAttributedString(
                        string: "•\t",
                        attributes: [
                            .font: resolveProseFont(size: 14.5, weight: .regular, italic: false, typography: typography),
                            .foregroundColor: bulletColor,
                            .paragraphStyle: para,
                        ]
                    )
                    out.append(bulletPrefix)
                    let joined = item.replacingOccurrences(of: "\n", with: "\u{2028}")
                    appendInline(
                        joined,
                        to: out,
                        baseSize: 14.5,
                        baseWeight: .regular,
                        baseColor: bodyColor,
                        paragraphStyle: para,
                        extraAttributes: [:],
                        typography: typography,
                        findQuery: findQuery,
                        isDark: isDark,
                        linkColor: linkColor,
                        inlineCodeBg: inlineCodeBg,
                        searchBg: searchBg,
                        searchFg: searchFg
                    )
                }

            case .orderedList(_, let items):
                let maxNum = items.map(\.number).max() ?? 1
                let gutter: CGFloat = maxNum >= 100 ? 34 : (maxNum >= 10 ? 28 : 24)
                for (iIdx, item) in items.enumerated() {
                    appendNewlineIfNeeded()
                    let isLastItem = iIdx == items.count - 1
                    let para = NSMutableParagraphStyle()
                    para.lineSpacing = 4.5
                    para.firstLineHeadIndent = 2
                    para.headIndent = gutter
                    para.tabStops = [NSTextTab(textAlignment: .left, location: gutter)]
                    para.paragraphSpacing = isLastItem ? (isLast ? 0 : 10) : 5
                    let numPrefix = NSAttributedString(
                        string: "\(item.number).\t",
                        attributes: [
                            .font: resolveCodeFont(size: 13.5, weight: .medium, typography: typography),
                            .foregroundColor: mutedColor,
                            .paragraphStyle: para,
                        ]
                    )
                    out.append(numPrefix)
                    let joined = item.text.replacingOccurrences(of: "\n", with: "\u{2028}")
                    appendInline(
                        joined,
                        to: out,
                        baseSize: 14.5,
                        baseWeight: .regular,
                        baseColor: bodyColor,
                        paragraphStyle: para,
                        extraAttributes: [:],
                        typography: typography,
                        findQuery: findQuery,
                        isDark: isDark,
                        linkColor: linkColor,
                        inlineCodeBg: inlineCodeBg,
                        searchBg: searchBg,
                        searchFg: searchFg
                    )
                }

            case .blockquote(_, let text):
                appendNewlineIfNeeded()
                let para = NSMutableParagraphStyle()
                para.lineSpacing = 4.5
                para.firstLineHeadIndent = 12
                para.headIndent = 12
                para.paragraphSpacingBefore = isFirst ? 0 : 2
                para.paragraphSpacing = isLast ? 0 : 10
                let joined = text.replacingOccurrences(of: "\n", with: "\u{2028}")
                appendInline(
                    joined,
                    to: out,
                    baseSize: 13.5,
                    baseWeight: .regular,
                    baseColor: secondaryColor,
                    paragraphStyle: para,
                    extraAttributes: [ThreadProseNSTextView.blockquoteKey: true],
                    typography: typography,
                    findQuery: findQuery,
                    isDark: isDark,
                    linkColor: linkColor,
                    inlineCodeBg: inlineCodeBg,
                    searchBg: searchBg,
                    searchFg: searchFg
                )

            case .divider:
                appendNewlineIfNeeded()
                let para = NSMutableParagraphStyle()
                para.minimumLineHeight = 9
                para.maximumLineHeight = 9
                para.paragraphSpacingBefore = isFirst ? 0 : 4
                para.paragraphSpacing = isLast ? 0 : 10
                out.append(NSAttributedString(
                    string: "\u{200B}",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 6),
                        .foregroundColor: NSColor.clear,
                        .paragraphStyle: para,
                        ThreadProseNSTextView.dividerKey: true,
                    ]
                ))

            default:
                break
            }
        }

        return out
    }

    private static func appendInline(
        _ raw: String,
        to out: NSMutableAttributedString,
        baseSize: CGFloat,
        baseWeight: NSFont.Weight,
        baseColor: NSColor,
        paragraphStyle: NSParagraphStyle,
        extraAttributes: [NSAttributedString.Key: Any],
        typography: PrismTypographyPrefs,
        findQuery: String,
        isDark: Bool,
        linkColor: NSColor,
        inlineCodeBg: NSColor,
        searchBg: NSColor,
        searchFg: NSColor
    ) {
        let baseFont = resolveProseFont(size: baseSize, weight: baseWeight, italic: false, typography: typography)
        guard let parsed = InlineMarkdownEngine.render(raw, findQuery: findQuery, isDark: isDark) else {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: baseColor,
                .paragraphStyle: paragraphStyle,
            ]
            for (k, v) in extraAttributes { attrs[k] = v }
            out.append(NSAttributedString(string: raw, attributes: attrs))
            return
        }

        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            guard !text.isEmpty else { continue }
            let intent = run.inlinePresentationIntent ?? []
            let isBold = intent.contains(.stronglyEmphasized)
            let isItalic = intent.contains(.emphasized)
            let isCode = intent.contains(.code)
            let isStrike = intent.contains(.strikethrough)

            let font: NSFont
            if isCode {
                font = resolveCodeFont(
                    size: max(9, baseSize - 1.0),
                    weight: isBold ? .semibold : baseWeight,
                    typography: typography
                )
            } else {
                let effectiveWeight: NSFont.Weight = isBold
                    ? (baseWeight == .semibold ? .bold : .semibold)
                    : baseWeight
                font = resolveProseFont(
                    size: baseSize,
                    weight: effectiveWeight,
                    italic: isItalic,
                    typography: typography
                )
            }

            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: baseColor,
                .paragraphStyle: paragraphStyle,
            ]
            for (k, v) in extraAttributes { attrs[k] = v }

            if isCode {
                attrs[.backgroundColor] = inlineCodeBg
            }
            if isStrike {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attrs[.link] = link
                attrs[.foregroundColor] = linkColor
            }
            // Preserve search match highlights added by InlineMarkdownEngine.render.
            if !findQuery.isEmpty && run.backgroundColor != nil {
                attrs[.backgroundColor] = searchBg
                attrs[.foregroundColor] = searchFg
            }

            out.append(NSAttributedString(string: text, attributes: attrs))
        }
    }

    private static func resolveProseFont(
        size: CGFloat,
        weight: NSFont.Weight,
        italic: Bool,
        typography: PrismTypographyPrefs
    ) -> NSFont {
        let resolved = max(9, size + typography.textSizeDelta)
        var font: NSFont
        if !typography.proseFontFamily.isEmpty,
           let custom = NSFont(name: typography.proseFontFamily, size: resolved) {
            font = custom
            if weight == .semibold || weight == .bold || weight == .medium {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
        } else {
            font = NSFont.systemFont(ofSize: resolved, weight: weight)
        }
        if italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    private static func resolveCodeFont(
        size: CGFloat,
        weight: NSFont.Weight,
        typography: PrismTypographyPrefs
    ) -> NSFont {
        let resolved = max(9, size + typography.textSizeDelta)
        if !typography.codeFontFamily.isEmpty,
           let custom = NSFont(name: typography.codeFontFamily, size: resolved) {
            if weight == .semibold || weight == .bold || weight == .medium {
                return NSFontManager.shared.convert(custom, toHaveTrait: .boldFontMask)
            }
            return custom
        }
        return NSFont.monospacedSystemFont(ofSize: resolved, weight: weight)
    }
}
#endif

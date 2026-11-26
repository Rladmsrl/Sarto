import Foundation
import PrismDesign
import SartoProtocol
import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Prism Theme Snapshot for HTML Document Styling (Sendable, Zero Raw Colors)

struct MarkdownPreviewTheme: Sendable, Equatable {
    let isDark: Bool
    let background: String
    let surface1: String
    let surface2: String
    let codeHeaderBackground: String
    let foreground: String
    let secondaryForeground: String
    let mutedForeground: String
    let borderEtched: String
    let borderStrong: String
    let primary: String
    let primarySoft: String
    let cobalt: String
    let iris: String
    let success: String
    let warning: String
    let danger: String
    let syntaxKeyword: String
    let syntaxString: String
    let syntaxComment: String
    let syntaxNumber: String
    let syntaxType: String
    let syntaxAttribute: String

    @MainActor
    init(tokens: PrismTokens) {
        self.isDark = tokens.palette.isDark
        self.background = Self.cssRGBA(tokens.codeBackground)
        self.surface1 = Self.cssRGBA(tokens.surface1)
        self.surface2 = Self.cssRGBA(tokens.surface2)
        self.codeHeaderBackground = Self.cssRGBA(tokens.codeHeaderBackground)
        self.foreground = Self.cssRGBA(tokens.foreground)
        self.secondaryForeground = Self.cssRGBA(tokens.secondaryForeground)
        self.mutedForeground = Self.cssRGBA(tokens.mutedForeground)
        self.borderEtched = Self.cssRGBA(tokens.borderEtched)
        self.borderStrong = Self.cssRGBA(tokens.borderStrong)
        self.primary = Self.cssRGBA(tokens.primary)
        self.primarySoft = Self.cssRGBA(tokens.primarySoft)
        self.cobalt = Self.cssRGBA(tokens.prismCobalt)
        self.iris = Self.cssRGBA(tokens.prismIris)
        self.success = Self.cssRGBA(tokens.success)
        self.warning = Self.cssRGBA(tokens.warning)
        self.danger = Self.cssRGBA(tokens.danger)
        let syn = tokens.codeSyntax
        self.syntaxKeyword = Self.cssRGBA(syn.keyword)
        self.syntaxString = Self.cssRGBA(syn.string)
        self.syntaxComment = Self.cssRGBA(syn.comment)
        self.syntaxNumber = Self.cssRGBA(syn.number)
        self.syntaxType = Self.cssRGBA(syn.type)
        self.syntaxAttribute = Self.cssRGBA(syn.attribute)
    }

    @MainActor
    private static func cssRGBA(_ color: Color) -> String {
        #if os(macOS)
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.labelColor.usingColorSpace(.sRGB) ?? .white
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        let a = Double((ns.alphaComponent * 1000).rounded()) / 1000.0
        if a >= 0.999 {
            return "rgb(\(r), \(g), \(b))"
        }
        return "rgba(\(r), \(g), \(b), \(a))"
        #else
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return "rgba(\(Int(r * 255)), \(Int(g * 255)), \(Int(b * 255)), \(a))"
        #endif
    }
}

// MARK: - GitHub-Flavored Markdown + Safe HTML -> Self-Contained HTML Compiler

struct GitHubMarkdownHTMLRenderer {
    private let options: Options
    private var slugCounts: [String: Int] = [:]
    private var localImages: [LocalImageAsset] = []
    private var localImageByPath: [String: (id: Int, dataURI: String)] = [:]
    private var gatedRemoteImageCount: Int = 0

    private init(options: Options) {
        self.options = options
    }
    struct LocalImageAsset: Sendable, Equatable {
        let id: Int
        let title: String
        let data: Data
        let fileURL: URL
    }

    struct Options: Sendable, Equatable {
        let allowedRoot: String?
        let baseDirectory: String?
        let activeProjectPath: String
        let allowRemoteImages: Bool
        let theme: MarkdownPreviewTheme
    }

    struct Output: Sendable, Equatable {
        let html: String
        let localImages: [LocalImageAsset]
        let gatedRemoteImageCount: Int
    }

    private static let structuralHTMLTags: Set<String> = [
        "div", "center", "section", "article", "header", "footer", "nav", "aside", "main",
        "figure", "figcaption", "blockquote", "details", "summary",
        "table", "thead", "tbody", "tfoot", "tr", "th", "td",
        "ul", "ol", "li", "dl", "dt", "dd", "p",
        "h1", "h2", "h3", "h4", "h5", "h6", "picture",
    ]

    private static let inlineSafeHTMLTags: Set<String> = [
        "a", "img", "br", "hr", "b", "strong", "i", "em", "u", "s", "del", "ins",
        "mark", "small", "sub", "sup", "kbd", "code", "span", "abbr", "cite", "q", "var", "samp",
    ]

    private static let allSafeHTMLTags: Set<String> = structuralHTMLTags.union(inlineSafeHTMLTags).union(["pre", "source"])

    private static let shieldsNamedColors: [String: String] = [
        "brightgreen": "#4c1",
        "green": "#97ca00",
        "yellowgreen": "#a4a61d",
        "yellow": "#dfb317",
        "orange": "#fe7d37",
        "red": "#e05d44",
        "blue": "#007ec6",
        "lightgrey": "#9f9f9f",
        "lightgray": "#9f9f9f",
        "grey": "#555",
        "gray": "#555",
        "blueviolet": "#8a2be2",
        "ff69b4": "#ff69b4",
        "success": "#2ea043",
        "important": "#fe7d37",
        "critical": "#e05d44",
        "informational": "#007ec6",
        "inactive": "#9f9f9f",
    ]

    static func render(markdown: String, options: Options) -> Output {
        var ctx = GitHubMarkdownHTMLRenderer(options: options)
        let bodyHTML = ctx.compileDocument(markdown)
        let cspImgSrc = options.allowRemoteImages ? "data: https:" : "data:"
        let t = options.theme

        let fullHTML = """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src \(cspImgSrc);">
        <style>
          :root {
            color-scheme: \(t.isDark ? "dark" : "light");
            --bg: \(t.background);
            --surface-1: \(t.surface1);
            --surface-2: \(t.surface2);
            --code-header: \(t.codeHeaderBackground);
            --fg: \(t.foreground);
            --fg-secondary: \(t.secondaryForeground);
            --fg-muted: \(t.mutedForeground);
            --border: \(t.borderEtched);
            --border-strong: \(t.borderStrong);
            --primary: \(t.primary);
            --primary-soft: \(t.primarySoft);
            --cobalt: \(t.cobalt);
            --iris: \(t.iris);
            --success: \(t.success);
            --warning: \(t.warning);
            --danger: \(t.danger);
            --syn-kw: \(t.syntaxKeyword);
            --syn-str: \(t.syntaxString);
            --syn-cmt: \(t.syntaxComment);
            --syn-num: \(t.syntaxNumber);
            --syn-typ: \(t.syntaxType);
            --syn-attr: \(t.syntaxAttribute);
          }
          * { box-sizing: border-box; }
          html, body {
            margin: 0;
            padding: 0;
            background: transparent;
            color: var(--fg);
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Helvetica Neue", sans-serif;
            font-size: 13.5px;
            line-height: 1.66;
            -webkit-font-smoothing: antialiased;
            word-wrap: break-word;
            overflow-wrap: break-word;
          }
          .md-root {
            max-width: 900px;
            margin: 0 auto;
            padding: 18px 22px 36px;
          }
          h1, h2, h3, h4, h5, h6 {
            color: var(--fg);
            font-weight: 600;
            line-height: 1.3;
            margin: 1.35em 0 0.55em;
            scroll-margin-top: 14px;
          }
          .md-root > h1:first-child,
          .md-root > div:first-child > h1:first-child,
          div[align="center"] h1 {
            margin-top: 0.35em;
          }
          h1 {
            font-size: 1.65em;
            padding-bottom: 0.3em;
            border-bottom: 1px solid var(--border);
          }
          div[align="center"] > h1,
          center > h1 {
            border-bottom: none;
            padding-bottom: 0.05em;
          }
          h2 {
            font-size: 1.32em;
            padding-bottom: 0.25em;
            border-bottom: 1px solid var(--border);
          }
          h3 { font-size: 1.12em; }
          h4 { font-size: 1.0em; }
          h5, h6 { font-size: 0.92em; color: var(--fg-secondary); }
          p { margin: 0.65em 0; }
          div[align="center"], center, [align="center"] { text-align: center; }
          div[align="right"], [align="right"] { text-align: right; }
          div[align="left"], [align="left"] { text-align: left; }
          a {
            color: var(--primary);
            text-decoration: none;
          }
          a:hover { text-decoration: underline; }
          a.md-badge-link:hover { text-decoration: none; opacity: 0.92; }
          strong, b { font-weight: 600; color: var(--fg); }
          hr {
            border: 0;
            border-top: 1px solid var(--border);
            margin: 1.4em 0;
          }
          img {
            max-width: 100%;
            height: auto;
            vertical-align: middle;
            border-radius: 6px;
          }
          img.md-badge {
            border-radius: 4px;
            margin: 2px 2px;
            vertical-align: middle;
          }
          div[align="center"] img {
            border-radius: 0;
          }
          div[align="center"] img.md-badge {
            border-radius: 4px;
          }
          ul, ol {
            margin: 0.55em 0;
            padding-left: 1.65em;
          }
          li { margin: 0.26em 0; }
          li > p { margin: 0.25em 0; }
          input.md-task {
            margin: 0 0.45em 0.12em -1.2em;
            vertical-align: middle;
            accent-color: var(--primary);
          }
          blockquote {
            margin: 0.75em 0;
            padding: 0.15em 0 0.15em 13px;
            color: var(--fg-secondary);
            border-left: 3px solid var(--cobalt);
          }
          blockquote > :first-child { margin-top: 0; }
          blockquote > :last-child { margin-bottom: 0; }
          code {
            font-family: ui-monospace, "SF Mono", Menlo, Monaco, monospace;
            font-size: 0.875em;
            padding: 0.15em 0.4em;
            border-radius: 5px;
            background: var(--surface-2);
            border: 1px solid var(--border);
          }
          kbd {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 0.82em;
            padding: 0.12em 0.42em;
            border-radius: 5px;
            background: var(--surface-1);
            border: 1px solid var(--border-strong);
            box-shadow: inset 0 -1px 0 var(--border-strong);
          }
          pre {
            margin: 0.8em 0;
            padding: 0;
            border-radius: 8px;
            background: var(--surface-1);
            border: 1px solid var(--border);
            overflow: hidden;
          }
          .md-code-header {
            display: flex;
            align-items: center;
            padding: 5px 12px;
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 11px;
            font-weight: 600;
            color: var(--fg-muted);
            background: var(--code-header);
            border-bottom: 1px solid var(--border);
          }
          pre code {
            display: block;
            padding: 11px 13px;
            overflow-x: auto;
            background: transparent;
            border: 0;
            border-radius: 0;
            font-size: 12px;
            line-height: 1.52;
            color: var(--fg);
          }
          .syn-kw { color: var(--syn-kw); font-weight: 500; }
          .syn-str { color: var(--syn-str); }
          .syn-cmt { color: var(--syn-cmt); font-style: italic; }
          .syn-num { color: var(--syn-num); }
          .syn-typ { color: var(--syn-typ); }
          .syn-attr { color: var(--syn-attr); }
          .syn-add { color: var(--success); }
          .syn-del { color: var(--danger); }
          table {
            width: 100%;
            border-collapse: collapse;
            margin: 0.85em 0;
            border-radius: 8px;
            overflow: hidden;
            border: 1px solid var(--border);
            background: var(--surface-1);
            display: table;
          }
          .md-table-scroll {
            width: 100%;
            overflow-x: auto;
            margin: 0.85em 0;
          }
          .md-table-scroll > table { margin: 0; }
          th, td {
            padding: 8px 12px;
            border: 1px solid var(--border);
            text-align: left;
            vertical-align: top;
            font-size: 12.5px;
            line-height: 1.55;
          }
          th {
            background: var(--code-header);
            font-weight: 600;
            color: var(--fg);
          }
          td > p:first-child { margin-top: 0; }
          td > p:last-child { margin-bottom: 0; }
          details {
            margin: 0.75em 0;
            padding: 8px 12px;
            border-radius: 8px;
            background: var(--surface-1);
            border: 1px solid var(--border);
          }
          summary {
            cursor: pointer;
            font-weight: 500;
            color: var(--fg);
            outline: none;
            user-select: none;
          }
          details[open] > summary {
            margin-bottom: 8px;
            padding-bottom: 6px;
            border-bottom: 1px solid var(--border);
          }
          .md-alert {
            margin: 0.85em 0;
            padding: 10px 14px;
            border-radius: 8px;
            border: 1px solid var(--border);
            border-left-width: 3.5px;
            background: var(--surface-1);
          }
          .md-alert-title {
            display: flex;
            align-items: center;
            gap: 6px;
            font-size: 12px;
            font-weight: 600;
            margin-bottom: 4px;
          }
          .md-alert-body > p:first-child { margin-top: 0; }
          .md-alert-body > p:last-child { margin-bottom: 0; }
          .md-alert-note { border-left-color: var(--cobalt); }
          .md-alert-note .md-alert-title { color: var(--cobalt); }
          .md-alert-tip { border-left-color: var(--success); }
          .md-alert-tip .md-alert-title { color: var(--success); }
          .md-alert-important { border-left-color: var(--iris); }
          .md-alert-important .md-alert-title { color: var(--iris); }
          .md-alert-warning { border-left-color: var(--warning); }
          .md-alert-warning .md-alert-title { color: var(--warning); }
          .md-alert-caution { border-left-color: var(--danger); }
          .md-alert-caution .md-alert-title { color: var(--danger); }
          .md-diagram-card {
            margin: 0.85em 0;
            border-radius: 8px;
            border: 1px solid var(--border);
            background: var(--surface-1);
            overflow: hidden;
          }
          .md-diagram-body {
            display: flex;
            justify-content: center;
            align-items: center;
            padding: 14px 16px;
            overflow-x: auto;
          }
          .md-diagram-body svg {
            max-width: 100%;
            height: auto;
            display: block;
          }
          .md-math-body {
            display: flex;
            justify-content: center;
            align-items: center;
            padding: 14px 18px;
            font-size: 16.5px;
            overflow-x: auto;
          }
          math { font-family: "STIX Two Math", "Cambria Math", "Times New Roman", serif; }
          .md-remote-pill {
            display: inline-flex;
            align-items: center;
            gap: 4px;
            padding: 2px 8px;
            margin: 2px;
            border-radius: 5px;
            font-size: 11.5px;
            color: var(--fg-secondary);
            background: var(--surface-2);
            border: 1px solid var(--border);
          }
          .md-carousel {
            margin: 0.85em 0;
            display: grid;
            gap: 10px;
          }
          .md-carousel-slide {
            padding: 10px 12px;
            border-radius: 8px;
            border: 1px solid var(--border);
            background: var(--surface-1);
          }
          .md-carousel-badge {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 10.5px;
            color: var(--fg-muted);
            margin-bottom: 6px;
          }
        </style>
        </head>
        <body>
        <main class="md-root">
        \(bodyHTML)
        </main>
        </body>
        </html>
        """

        return Output(
            html: fullHTML,
            localImages: ctx.localImages,
            gatedRemoteImageCount: ctx.gatedRemoteImageCount
        )
    }

    // MARK: - Stateful Document Compiler

    private mutating func compileDocument(_ rawMarkdown: String) -> String {
            let normalized = rawMarkdown.contains("\r")
                ? rawMarkdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                : rawMarkdown
            let stripped = Self.stripUnsafeBlocksOutsideCodeFences(normalized)
            let lines = stripped.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return parseBlocks(lines)
        }

        mutating func uniqueHeadingSlug(for rawHeading: String) -> String {
            let plain = Self.plainHeadingText(rawHeading)
            let base = Self.githubSlug(plain)
            guard !base.isEmpty else { return "" }
            let seen = slugCounts[base] ?? 0
            slugCounts[base] = seen + 1
            return seen == 0 ? base : "\(base)-\(seen)"
        }

        // MARK: Block-Level Parser (GFM + Safe Structural HTML Interleaving)

        mutating func parseBlocks(_ rawLines: [String]) -> String {
            let lines = Self.coalesceMultilineHTMLTags(rawLines)
            var out: [String] = []
            var i = 0

            while i < lines.count {
                let raw = lines[i]
                let trimmed = raw.trimmingCharacters(in: .whitespaces)

                if trimmed.isEmpty {
                    i += 1
                    continue
                }

                // 1. Fenced code block (``` or ~~~, including 4-backtick carousel blocks)
                if let fence = Self.detectFenceOpen(trimmed) {
                    var codeLines: [String] = []
                    i += 1
                    while i < lines.count {
                        let cand = lines[i].trimmingCharacters(in: .whitespaces)
                        if cand.hasPrefix(fence.marker) && cand.dropFirst(fence.count).trimmingCharacters(in: .whitespaces).isEmpty {
                            i += 1
                            break
                        }
                        codeLines.append(lines[i])
                        i += 1
                    }
                    let code = codeLines.joined(separator: "\n")
                    out.append(renderCodeFence(language: fence.language, filename: fence.filename, code: code))
                    continue
                }

                // 2. Display LaTeX math block ($$ ... $$)
                if trimmed.hasPrefix("$$") {
                    if trimmed.count > 4 && trimmed.hasSuffix("$$") {
                        let latex = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                        out.append(renderMathBlock(latex))
                        i += 1
                        continue
                    }
                    var mathLines: [String] = []
                    let head = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !head.isEmpty { mathLines.append(head) }
                    i += 1
                    while i < lines.count {
                        let cand = lines[i].trimmingCharacters(in: .whitespaces)
                        if cand.hasSuffix("$$") {
                            let tail = String(cand.dropLast(2)).trimmingCharacters(in: .whitespaces)
                            if !tail.isEmpty { mathLines.append(tail) }
                            i += 1
                            break
                        }
                        mathLines.append(lines[i])
                        i += 1
                    }
                    out.append(renderMathBlock(mathLines.joined(separator: "\n")))
                    continue
                }

                // 3. Structural / Standalone Safe HTML tag line
                if let htmlBlock = tryRenderHTMLLine(trimmed) {
                    out.append(htmlBlock)
                    i += 1
                    continue
                }

                // 4. ATX Heading (# ... ######)
                if trimmed.hasPrefix("#") {
                    let hashes = trimmed.prefix(while: { $0 == "#" }).count
                    if hashes >= 1 && hashes <= 6 {
                        let rest = trimmed.dropFirst(hashes)
                        if rest.isEmpty || rest.first == " " || rest.first == "\t" {
                            var headingText = String(rest).trimmingCharacters(in: .whitespaces)
                            if headingText.hasSuffix("#") {
                                headingText = headingText.replacingOccurrences(of: "\\s+#+\\s*$", with: "", options: .regularExpression)
                            }
                            let slug = uniqueHeadingSlug(for: headingText)
                            let idAttr = slug.isEmpty ? "" : " id=\"\(Self.escAttr(slug))\""
                            out.append("<h\(hashes)\(idAttr)>\(renderInline(headingText))</h\(hashes)>")
                            i += 1
                            continue
                        }
                    }
                }

                // 5. Thematic break (---, ***, ___)
                if Self.isThematicBreak(trimmed) {
                    out.append("<hr>")
                    i += 1
                    continue
                }

                // 6. Blockquote / GitHub Alert (> [!NOTE], > ...)
                if trimmed.hasPrefix(">") {
                    var quoteLines: [String] = []
                    while i < lines.count {
                        let qt = lines[i].trimmingCharacters(in: .whitespaces)
                        guard qt.hasPrefix(">") else { break }
                        var content = String(qt.dropFirst())
                        if content.hasPrefix(" ") { content.removeFirst() }
                        quoteLines.append(content)
                        i += 1
                    }
                    if let first = quoteLines.first, let alert = Self.parseGitHubAlertHeader(first) {
                        var bodyLines = Array(quoteLines.dropFirst())
                        if !alert.remainder.isEmpty { bodyLines.insert(alert.remainder, at: 0) }
                        let innerHTML = parseBlocks(bodyLines)
                        out.append(Self.renderAlertCard(kind: alert.kind, innerHTML: innerHTML))
                    } else {
                        out.append("<blockquote>\(parseBlocks(quoteLines))</blockquote>")
                    }
                    continue
                }

                // 7. GFM Pipe Table
                if trimmed.contains("|"),
                   i + 1 < lines.count,
                   let alignments = Self.parseTableAlignments(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                    let headers = Self.splitPipeCells(trimmed)
                    if !headers.isEmpty {
                        i += 2
                        var rows: [[String]] = []
                        while i < lines.count {
                            let rt = lines[i].trimmingCharacters(in: .whitespaces)
                            guard !rt.isEmpty, rt.contains("|"), !Self.isStructuralHTMLLine(rt) else { break }
                            let cells = Self.splitPipeCells(rt)
                            if cells.isEmpty { break }
                            var row = cells
                            while row.count < headers.count { row.append("") }
                            if row.count > headers.count { row = Array(row.prefix(headers.count)) }
                            rows.append(row)
                            i += 1
                        }
                        out.append(renderPipeTable(headers: headers, alignments: alignments, rows: rows))
                        continue
                    }
                }

                // 8. Unordered or Ordered List (with nested sublist support)
                if Self.parseListMarker(raw) != nil {
                    let (listHTML, nextIndex) = parseList(lines: lines, startIndex: i)
                    out.append(listHTML)
                    i = nextIndex
                    continue
                }

                // 9. Setext Heading (Heading \n === or ---)
                if i + 1 < lines.count {
                    let nextTrim = lines[i + 1].trimmingCharacters(in: .whitespaces)
                    if !nextTrim.isEmpty && (nextTrim.allSatisfy({ $0 == "=" }) || (nextTrim.count >= 3 && nextTrim.allSatisfy({ $0 == "-" }) && !trimmed.contains("|"))) {
                        let level = nextTrim.first == "=" ? 1 : 2
                        let slug = uniqueHeadingSlug(for: trimmed)
                        let idAttr = slug.isEmpty ? "" : " id=\"\(Self.escAttr(slug))\""
                        out.append("<h\(level)\(idAttr)>\(renderInline(trimmed))</h\(level)>")
                        i += 2
                        continue
                    }
                }

                // 10. Standalone Markdown image line (![alt](url)) — clickable for local lightbox
                if let standaloneImg = Self.parseStandaloneMarkdownImage(trimmed) {
                    out.append("<p>\(renderImageElement(src: standaloneImg.url, alt: standaloneImg.alt, title: standaloneImg.title, extraAttrs: [:], allowLightboxLink: true))</p>")
                    i += 1
                    continue
                }

                // 11. Paragraph (join soft breaks with space, preserving trailing `  ` / `\` as `<br>`)
                var paraParts: [String] = []
                while i < lines.count {
                    let curRaw = lines[i]
                    let curTrim = curRaw.trimmingCharacters(in: .whitespaces)
                    if !paraParts.isEmpty && isBlockStarter(lines: lines, at: i) {
                        break
                    }
                    if curRaw.hasSuffix("  ") {
                        paraParts.append(renderInline(curTrim) + "<br>")
                    } else if curTrim.hasSuffix("\\") && curTrim.count > 1 {
                        paraParts.append(renderInline(String(curTrim.dropLast())) + "<br>")
                    } else {
                        paraParts.append(renderInline(curTrim))
                    }
                    i += 1
                }
                out.append("<p>\(paraParts.joined(separator: " "))</p>")
            }

            return out.joined(separator: "\n")
        }

        private func isBlockStarter(lines: [String], at idx: Int) -> Bool {
            let raw = lines[idx]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return true }
            if Self.detectFenceOpen(trimmed) != nil { return true }
            if trimmed.hasPrefix("$$") { return true }
            if Self.isStructuralHTMLLine(trimmed) { return true }
            if trimmed.hasPrefix("#") {
                let h = trimmed.prefix(while: { $0 == "#" }).count
                if h >= 1 && h <= 6 && (trimmed.dropFirst(h).isEmpty || trimmed.dropFirst(h).first == " ") {
                    return true
                }
            }
            if Self.isThematicBreak(trimmed) { return true }
            if trimmed.hasPrefix(">") { return true }
            if Self.parseListMarker(raw) != nil { return true }
            if Self.parseStandaloneMarkdownImage(trimmed) != nil { return true }
            if trimmed.contains("|"), idx + 1 < lines.count,
               Self.parseTableAlignments(lines[idx + 1].trimmingCharacters(in: .whitespaces)) != nil {
                return true
            }
            return false
        }

        // MARK: Nested List Parser

        private struct ListMarker {
            let ordered: Bool
            let number: Int
            let indent: Int
            let body: String
        }

        private static func parseListMarker(_ raw: String) -> ListMarker? {
            var indent = 0
            var idx = raw.startIndex
            while idx < raw.endIndex {
                if raw[idx] == " " { indent += 1; idx = raw.index(after: idx) }
                else if raw[idx] == "\t" { indent += 4; idx = raw.index(after: idx) }
                else { break }
            }
            let sub = raw[idx...]
            if sub.hasPrefix("- ") || sub.hasPrefix("* ") || sub.hasPrefix("+ ") || sub.hasPrefix("• ") {
                return ListMarker(ordered: false, number: 1, indent: indent, body: String(sub.dropFirst(2)))
            }
            let digits = sub.prefix(while: \.isNumber)
            if !digits.isEmpty, digits.count <= 9, let n = Int(digits) {
                let after = sub.dropFirst(digits.count)
                if after.hasPrefix(". ") || after.hasPrefix(") ") {
                    return ListMarker(ordered: true, number: n, indent: indent, body: String(after.dropFirst(2)))
                }
            }
            return nil
        }

        private mutating func parseList(lines: [String], startIndex: Int) -> (html: String, nextIndex: Int) {
            guard let first = Self.parseListMarker(lines[startIndex]) else {
                return ("", startIndex + 1)
            }
            let baseIndent = first.indent
            let isOrdered = first.ordered
            let startAttr = (isOrdered && first.number != 1) ? " start=\"\(first.number)\"" : ""
            let tag = isOrdered ? "ol" : "ul"
            var itemsHTML: [String] = []
            var i = startIndex

            while i < lines.count {
                let raw = lines[i]
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    // Look ahead: continue list only if next non-empty line is another list item or indented continuation
                    var look = i + 1
                    while look < lines.count && lines[look].trimmingCharacters(in: .whitespaces).isEmpty { look += 1 }
                    if look < lines.count,
                       let nextM = Self.parseListMarker(lines[look]),
                       nextM.indent >= baseIndent {
                        i = look
                        continue
                    }
                    break
                }
                guard let marker = Self.parseListMarker(raw) else { break }
                if marker.indent < baseIndent || (marker.indent == baseIndent && marker.ordered != isOrdered) {
                    break
                }
                if marker.indent > baseIndent {
                    let (nested, nextI) = parseList(lines: lines, startIndex: i)
                    if !itemsHTML.isEmpty {
                        let last = itemsHTML.removeLast()
                        if last.hasSuffix("</li>") {
                            itemsHTML.append(String(last.dropLast(5)) + nested + "</li>")
                        } else {
                            itemsHTML.append(last + nested)
                        }
                    } else {
                        itemsHTML.append("<li>\(nested)</li>")
                    }
                    i = nextI
                    continue
                }

                var itemTextParts: [String] = [marker.body]
                i += 1
                var nestedFragments: [String] = []

                while i < lines.count {
                    let contRaw = lines[i]
                    let contTrim = contRaw.trimmingCharacters(in: .whitespaces)
                    if contTrim.isEmpty { break }
                    if let subMarker = Self.parseListMarker(contRaw) {
                        if subMarker.indent > baseIndent {
                            let (subHTML, nextI) = parseList(lines: lines, startIndex: i)
                            nestedFragments.append(subHTML)
                            i = nextI
                            continue
                        }
                        break
                    }
                    let contIndent = contRaw.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                    if contIndent >= baseIndent + 2 && !Self.isStructuralHTMLLine(contTrim) && Self.detectFenceOpen(contTrim) == nil {
                        if contRaw.hasSuffix("  ") {
                            itemTextParts.append(contTrim + "\n")
                        } else {
                            itemTextParts.append(contTrim)
                        }
                        i += 1
                    } else if contIndent >= baseIndent + 2 && Self.detectFenceOpen(contTrim) != nil {
                        let fence = Self.detectFenceOpen(contTrim)!
                        var codeLines: [String] = []
                        i += 1
                        while i < lines.count {
                            let cTrim = lines[i].trimmingCharacters(in: .whitespaces)
                            if cTrim.hasPrefix(fence.marker) && cTrim.dropFirst(fence.count).trimmingCharacters(in: .whitespaces).isEmpty {
                                i += 1
                                break
                            }
                            let strippedLine = lines[i].count >= contIndent ? String(lines[i].dropFirst(min(contIndent, lines[i].prefix(while: { $0 == " " }).count))) : lines[i]
                            codeLines.append(strippedLine)
                            i += 1
                        }
                        nestedFragments.append(renderCodeFence(language: fence.language, filename: fence.filename, code: codeLines.joined(separator: "\n")))
                    } else {
                        break
                    }
                }

                let joinedBody = itemTextParts.joined(separator: " ")
                let renderedBody = renderTaskOrInline(joinedBody)
                itemsHTML.append("<li>\(renderedBody)\(nestedFragments.joined())</li>")
            }

            return ("<\(tag)\(startAttr)>\(itemsHTML.joined())</\(tag)>", i)
        }

        private mutating func renderTaskOrInline(_ body: String) -> String {
            if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") {
                return "<input type=\"checkbox\" class=\"md-task\" checked disabled>" + renderInline(String(body.dropFirst(4)))
            }
            if body.hasPrefix("[ ] ") {
                return "<input type=\"checkbox\" class=\"md-task\" disabled>" + renderInline(String(body.dropFirst(4)))
            }
            return renderInline(body)
        }

        // MARK: Safe Structural & Single-Line HTML Handler

        private static func isStructuralHTMLLine(_ trimmed: String) -> Bool {
            guard trimmed.hasPrefix("<"), trimmed.count >= 3 else { return false }
            if let tag = parseSingleHTMLTagLine(trimmed) {
                return allSafeHTMLTags.contains(tag.name)
            }
            if let single = parseSingleLinePairedHTMLBlock(trimmed) {
                return structuralHTMLTags.contains(single.name)
            }
            return false
        }

        private mutating func tryRenderHTMLLine(_ trimmed: String) -> String? {
            guard trimmed.hasPrefix("<") else { return nil }

            // Case A: Single-line paired block tag, e.g. `<h1>Sarto</h1>`, `<summary><b>All 46 agents</b></summary>`, `<p align="center">...</p>`
            if let paired = Self.parseSingleLinePairedHTMLBlock(trimmed),
               Self.structuralHTMLTags.contains(paired.name) {
                var attrs = sanitizeAttributes(tag: paired.name, rawAttrs: paired.rawAttrs)
                if paired.name.count == 2, paired.name.first == "h", let lvl = paired.name.last?.wholeNumberValue, (1...6).contains(lvl) {
                    if attrs["id"] == nil {
                        let slug = uniqueHeadingSlug(for: paired.inner)
                        if !slug.isEmpty { attrs["id"] = slug }
                    }
                }
                let attrStr = Self.formatAttrs(attrs)
                return "<\(paired.name)\(attrStr)>\(renderInline(paired.inner))</\(paired.name)>"
            }

            // Case B: Standalone opening, closing, or self-closing tag line, e.g. `<div align="center">`, `</div>`, `<img ...>`, `<td width="33%" valign="top">`
            if let single = Self.parseSingleHTMLTagLine(trimmed),
               Self.allSafeHTMLTags.contains(single.name) {
                if single.isClosing {
                    return "</\(single.name)>"
                }
                if single.name == "img" {
                    let rawMap = Self.parseRawAttributes(single.rawAttrs)
                    let src = rawMap["src"] ?? ""
                    let alt = rawMap["alt"] ?? ""
                    let title = rawMap["title"]
                    let safeExtra = sanitizeAttributes(tag: "img", rawAttrs: single.rawAttrs)
                    return renderImageElement(src: src, alt: alt, title: title, extraAttrs: safeExtra, allowLightboxLink: true)
                }
                if single.name == "br" || single.name == "hr" {
                    return "<\(single.name)>"
                }
                if single.name == "source" {
                    // Drop `<picture><source media="(prefers-color-scheme: ...)">` external/untrusted sources so `<img>` fallback renders deterministically
                    return ""
                }
                let attrs = sanitizeAttributes(tag: single.name, rawAttrs: single.rawAttrs)
                return "<\(single.name)\(Self.formatAttrs(attrs))>"
            }

            return nil
        }

        // MARK: GFM Pipe Table, Code Fence, Math, Diagram & Carousel Renderers

        private mutating func renderPipeTable(headers: [String], alignments: [String?], rows: [[String]]) -> String {
            var html = "<div class=\"md-table-scroll\"><table><thead><tr>"
            for (idx, h) in headers.enumerated() {
                let align = idx < alignments.count ? alignments[idx] : nil
                let style = align.map { " style=\"text-align: \($0);\"" } ?? ""
                html += "<th\(style)>\(renderInline(h))</th>"
            }
            html += "</tr></thead>"
            if !rows.isEmpty {
                html += "<tbody>"
                for row in rows {
                    html += "<tr>"
                    for (idx, cell) in row.enumerated() {
                        let align = idx < alignments.count ? alignments[idx] : nil
                        let style = align.map { " style=\"text-align: \($0);\"" } ?? ""
                        html += "<td\(style)>\(renderInline(cell))</td>"
                    }
                    html += "</tr>"
                }
                html += "</tbody>"
            }
            html += "</table></div>"
            return html
        }

        private mutating func renderCodeFence(language: String?, filename: String?, code: String) -> String {
            let lower = language?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if lower == "mermaid", let svg = OfflineMermaidCompiler.compileToSVG(code, isDark: options.theme.isDark) {
                return """
                <div class="md-diagram-card">
                  <div class="md-code-header">Mermaid</div>
                  <div class="md-diagram-body">\(svg)</div>
                </div>
                """
            }
            if lower == "svg" {
                let sanitized = Self.sanitizeSVGMarkup(code)
                if sanitized.contains("<svg") {
                    return """
                    <div class="md-diagram-card">
                      <div class="md-code-header">SVG</div>
                      <div class="md-diagram-body">\(sanitized)</div>
                    </div>
                    """
                }
            }
            if lower == "math" || lower == "latex" || lower == "tex" {
                return renderMathBlock(code)
            }
            if lower == "carousel" {
                let slides = code
                    .components(separatedBy: "<!-- slide -->")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !slides.isEmpty {
                    var cards: [String] = []
                    for (idx, slide) in slides.enumerated() {
                        let slideLines = slide.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                        let badge = slides.count > 1 ? "<div class=\"md-carousel-badge\">\(idx + 1) / \(slides.count)</div>" : ""
                        cards.append("<div class=\"md-carousel-slide\">\(badge)\(parseBlocks(slideLines))</div>")
                    }
                    return "<div class=\"md-carousel\">\(cards.joined())</div>"
                }
            }

            let headerLabel = filename ?? language ?? ""
            let headerHTML = headerLabel.isEmpty ? "" : "<div class=\"md-code-header\">\(Self.escHTML(headerLabel))</div>"
            let highlighted = Self.syntaxHighlightHTML(code, language: lower)
            return "<pre>\(headerHTML)<code>\(highlighted)</code></pre>"
        }

        private func renderMathBlock(_ latex: String) -> String {
            let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }
            let mathML = LatexMathConverter.toMathML(trimmed)
            return """
            <div class="md-diagram-card">
              <div class="md-math-body">\(mathML)</div>
            </div>
            """
        }

        // MARK: Inline Parser (Balanced Links, Linked Badges, Inline Code, Math, Safe Inline HTML, Emphasis)

        mutating func renderInline(_ input: String) -> String {
            guard !input.isEmpty else { return "" }
            let chars = Array(input)
            let n = chars.count
            var out = ""
            var i = 0

            while i < n {
                let c = chars[i]

                // 1. Backslash escape
                if c == "\\" && i + 1 < n && chars[i + 1].isASCII && !chars[i + 1].isLetter && !chars[i + 1].isNumber {
                    out.append(Self.escHTML(String(chars[i + 1])))
                    i += 2
                    continue
                }

                // 2. Inline code span (`...` or ``...``)
                if c == "`" {
                    var ticks = 0
                    while i + ticks < n && chars[i + ticks] == "`" { ticks += 1 }
                    var j = i + ticks
                    var foundClose: Int? = nil
                    while j < n {
                        if chars[j] == "`" {
                            var closeTicks = 0
                            while j + closeTicks < n && chars[j + closeTicks] == "`" { closeTicks += 1 }
                            if closeTicks == ticks {
                                foundClose = j
                                break
                            }
                            j += closeTicks
                        } else {
                            j += 1
                        }
                    }
                    if let closePos = foundClose {
                        var codeText = String(chars[(i + ticks)..<closePos])
                        if codeText.count >= 2 && codeText.first == " " && codeText.last == " " && !codeText.allSatisfy({ $0 == " " }) {
                            codeText.removeFirst()
                            codeText.removeLast()
                        }
                        out += "<code>\(Self.escHTML(codeText))</code>"
                        i = closePos + ticks
                        continue
                    } else {
                        out += String(repeating: "`", count: ticks)
                        i += ticks
                        continue
                    }
                }

                // 3. Inline image `![alt](url "title")`
                if c == "!" && i + 1 < n && chars[i + 1] == "[",
                   let parsed = Self.scanBracketParen(chars: chars, openBracketIndex: i + 1) {
                    let (url, title) = Self.splitLinkDestination(parsed.dest)
                    out += renderImageElement(src: url, alt: parsed.label, title: title, extraAttrs: [:], allowLightboxLink: false)
                    i = parsed.nextIndex
                    continue
                }

                // 4. Markdown link `[label](url "title")` — supports nested `![badge](...)` inside `label`!
                if c == "[",
                   let parsed = Self.scanBracketParen(chars: chars, openBracketIndex: i) {
                    let (rawDest, title) = Self.splitLinkDestination(parsed.dest)
                    let trimmedLabel = parsed.label.trimmingCharacters(in: .whitespacesAndNewlines)
                    let isBadgeLink = trimmedLabel.hasPrefix("![") || trimmedLabel.lowercased().hasPrefix("<img")
                    let innerHTML = renderInline(parsed.label)
                    if let safeHref = resolveHref(rawDest) {
                        let cls = isBadgeLink ? " class=\"md-badge-link\"" : ""
                        let titleAttr = title.map { " title=\"\(Self.escAttr($0))\"" } ?? ""
                        out += "<a href=\"\(Self.escAttr(safeHref))\"\(cls)\(titleAttr)>\(innerHTML)</a>"
                    } else {
                        out += innerHTML
                    }
                    i = parsed.nextIndex
                    continue
                }

                // 5. Autolink `<https://...>` or safe inline HTML tag (`<br/>`, `<img ...>`, `<b>`, `<kbd>`, `<a ...>`, etc.)
                if c == "<" {
                    if let closeAngle = Self.findClosingAngle(chars: chars, from: i) {
                        let rawInside = String(chars[(i + 1)..<closeAngle])
                        let lowerInside = rawInside.lowercased()
                        if lowerInside.hasPrefix("http://") || lowerInside.hasPrefix("https://") || lowerInside.hasPrefix("mailto:") {
                            if !rawInside.contains(where: { $0.isWhitespace }), let safeHref = resolveHref(rawInside) {
                                let label = lowerInside.hasPrefix("mailto:") ? String(rawInside.dropFirst(7)) : rawInside
                                out += "<a href=\"\(Self.escAttr(safeHref))\">\(Self.escHTML(label))</a>"
                                i = closeAngle + 1
                                continue
                            }
                        }
                        if let inlineHTML = tryRenderInlineHTMLTag(rawInside: rawInside) {
                            out += inlineHTML
                            i = closeAngle + 1
                            continue
                        }
                    }
                    out += "&lt;"
                    i += 1
                    continue
                }

                // 6. Inline math `$...$`
                if c == "$" && !(i + 1 < n && chars[i + 1] == "$") {
                    var j = i + 1
                    while j < n && chars[j] != "\n" && !(chars[j] == "$" && chars[j - 1] != "\\") { j += 1 }
                    if j < n && chars[j] == "$" && j > i + 1 {
                        let body = String(chars[(i + 1)..<j])
                        let looksCurrency = body.first?.isNumber == true && body.contains(" ")
                        if !looksCurrency {
                            out += Self.escHTML(LatexMathConverter.toTypographicInline(body))
                            i = j + 1
                            continue
                        }
                    }
                }

                // 7. Strikethrough `~~...~~`
                if c == "~" && i + 1 < n && chars[i + 1] == "~" {
                    if let end = Self.findClosingDelimiter(chars: chars, from: i + 2, delim: ["~", "~"]) {
                        out += "<del>\(renderInline(String(chars[(i + 2)..<end])))</del>"
                        i = end + 2
                        continue
                    }
                }

                // 8. Bold / Italic (`***`, `**`, `*`, `__`, `_` with intraword underscore protection)
                if c == "*" || c == "_" {
                    let prevAlnum = i > 0 && (chars[i - 1].isLetter || chars[i - 1].isNumber)
                    var run = 0
                    while i + run < n && chars[i + run] == c { run += 1 }

                    // Underscore inside identifiers like `Noise_IK_25519` never opens emphasis
                    if !(c == "_" && prevAlnum) {
                        if run >= 3,
                           let end = Self.findEmphasisClose(chars: chars, from: i + 3, marker: c, count: 3) {
                            out += "<strong><em>\(renderInline(String(chars[(i + 3)..<end])))</em></strong>"
                            i = end + 3
                            continue
                        }
                        if run >= 2,
                           let end = Self.findEmphasisClose(chars: chars, from: i + 2, marker: c, count: 2) {
                            out += "<strong>\(renderInline(String(chars[(i + 2)..<end])))</strong>"
                            i = end + 2
                            continue
                        }
                        if run == 1 && i + 1 < n && !chars[i + 1].isWhitespace,
                           let end = Self.findEmphasisClose(chars: chars, from: i + 1, marker: c, count: 1) {
                            out += "<em>\(renderInline(String(chars[(i + 1)..<end])))</em>"
                            i = end + 1
                            continue
                        }
                    }
                    out += String(repeating: String(c), count: run)
                    i += run
                    continue
                }

                // 9. Plain characters (`&`, `>` escaped)
                if c == "&" {
                    if let entityEnd = Self.matchSafeHTMLEntity(chars: chars, from: i) {
                        out += String(chars[i...entityEnd])
                        i = entityEnd + 1
                        continue
                    }
                    out += "&amp;"
                } else if c == ">" {
                    out += "&gt;"
                } else {
                    out.append(c)
                }
                i += 1
            }

            return out
        }

        private mutating func tryRenderInlineHTMLTag(rawInside: String) -> String? {
            let trimmed = rawInside.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let isClosing = trimmed.first == "/"
            let body = isClosing ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
            let cleanBody = body.hasSuffix("/") ? String(body.dropLast()).trimmingCharacters(in: .whitespaces) : body
            let tagName = cleanBody.prefix(while: { $0.isASCII && ($0.isLetter || $0.isNumber) }).lowercased()
            guard !tagName.isEmpty, Self.allSafeHTMLTags.contains(tagName) else { return nil }
            let afterName = cleanBody.dropFirst(tagName.count)
            guard afterName.isEmpty || afterName.first?.isWhitespace == true else { return nil }

            if isClosing {
                return "</\(tagName)>"
            }
            if tagName == "br" || tagName == "hr" {
                return "<\(tagName)>"
            }
            if tagName == "source" {
                return ""
            }
            let rawAttrs = String(afterName)
            if tagName == "img" {
                let rawMap = Self.parseRawAttributes(rawAttrs)
                let safeExtra = sanitizeAttributes(tag: "img", rawAttrs: rawAttrs)
                return renderImageElement(
                    src: rawMap["src"] ?? "",
                    alt: rawMap["alt"] ?? "",
                    title: rawMap["title"],
                    extraAttrs: safeExtra,
                    allowLightboxLink: false
                )
            }
            let safeAttrs = sanitizeAttributes(tag: tagName, rawAttrs: rawAttrs)
            return "<\(tagName)\(Self.formatAttrs(safeAttrs))>"
        }

        // MARK: Safe Image & Link Resolution (Local Containment + Offline Shields.io SVG Synthesis)

        private mutating func renderImageElement(
            src: String,
            alt: String,
            title: String?,
            extraAttrs: [String: String],
            allowLightboxLink: Bool
        ) -> String {
            let trimmedSrc = src.trimmingCharacters(in: .whitespacesAndNewlines)
            var attrs: [String: String] = [:]
            if let w = extraAttrs["width"] { attrs["width"] = w }
            if let h = extraAttrs["height"] { attrs["height"] = h }
            if let align = extraAttrs["align"] { attrs["align"] = align }
            attrs["alt"] = alt
            if let title, !title.isEmpty { attrs["title"] = title }

            // 1. Already a safe image data URI (non-SVG or sanitized SVG)
            if trimmedSrc.lowercased().hasPrefix("data:image/") {
                if trimmedSrc.lowercased().hasPrefix("data:image/svg+xml") {
                    return fallbackImagePill(label: alt.isEmpty ? "SVG" : alt)
                }
                attrs["src"] = trimmedSrc
                return "<img\(Self.formatAttrs(attrs))>"
            }

            // 2. Local workspace / agent-folder contained image -> inline `data:` URI
            if let root = options.allowedRoot,
               let local = loadContainedLocalImage(raw: trimmedSrc, allowedRoot: root, baseDirectory: options.baseDirectory, alt: alt) {
                attrs["src"] = local.dataURI
                let imgTag = "<img\(Self.formatAttrs(attrs))>"
                if allowLightboxLink {
                    return "<a href=\"sarto-image://\(local.id)\">\(imgTag)</a>"
                }
                return imgTag
            }

            // 3. Static `img.shields.io/badge/...` -> instant offline vector SVG badge (unless live remote images explicitly enabled)
            if !options.allowRemoteImages, let badgeDataURI = Self.synthesizeShieldsBadgeDataURI(trimmedSrc) {
                attrs["src"] = badgeDataURI
                let existingClass = attrs["class"]
                attrs["class"] = existingClass.map { "\($0) md-badge" } ?? "md-badge"
                return "<img\(Self.formatAttrs(attrs))>"
            }

            // 4. Remote HTTPS / HTTP image
            if let remote = URL(string: trimmedSrc),
               let scheme = remote.scheme?.lowercased(),
               scheme == "https" || scheme == "http" {
                if options.allowRemoteImages && scheme == "https" {
                    attrs["src"] = remote.absoluteString
                    if trimmedSrc.contains("shields.io") || trimmedSrc.contains("badge") {
                        attrs["class"] = "md-badge"
                    }
                    return "<img\(Self.formatAttrs(attrs))>"
                }
                gatedRemoteImageCount += 1
                let label = alt.isEmpty ? (remote.host ?? "Image") : alt
                return fallbackImagePill(label: label)
            }

            return fallbackImagePill(label: alt.isEmpty ? trimmedSrc : alt)
        }

        private func fallbackImagePill(label: String) -> String {
            "<span class=\"md-remote-pill\">🖼 \(Self.escHTML(label))</span>"
        }

        private mutating func loadContainedLocalImage(
            raw: String,
            allowedRoot: String,
            baseDirectory: String?,
            alt: String
        ) -> (id: Int, dataURI: String)? {
            guard let safeURL = Self.containedLocalURL(raw: raw, allowedRoot: allowedRoot, baseDirectory: baseDirectory) else {
                return nil
            }
            if let cached = localImageByPath[safeURL.path] {
                return cached
            }
            guard let rawData = try? Data(contentsOf: safeURL),
                  !rawData.isEmpty,
                  rawData.count <= 20 * 1024 * 1024
            else { return nil }

            let ext = safeURL.pathExtension.lowercased()
            let mime: String
            let payloadData: Data
            switch ext {
            case "svg":
                guard let svgText = String(data: rawData, encoding: .utf8) else { return nil }
                let cleanSVG = Self.sanitizeSVGMarkup(svgText)
                guard cleanSVG.contains("<svg"), let cleanBytes = cleanSVG.data(using: .utf8) else { return nil }
                mime = "image/svg+xml"
                payloadData = cleanBytes
            case "png":
                mime = "image/png"
                payloadData = rawData
            case "jpg", "jpeg":
                mime = "image/jpeg"
                payloadData = rawData
            case "gif":
                mime = "image/gif"
                payloadData = rawData
            case "webp":
                mime = "image/webp"
                payloadData = rawData
            case "ico":
                mime = "image/x-icon"
                payloadData = rawData
            default:
                return nil
            }

            let id = localImages.count
            let dataURI = "data:\(mime);base64,\(payloadData.base64EncodedString())"
            let title = alt.isEmpty ? safeURL.lastPathComponent : alt
            localImages.append(LocalImageAsset(id: id, title: title, data: payloadData, fileURL: safeURL))
            localImageByPath[safeURL.path] = (id, dataURI)
            return (id, dataURI)
        }

        private func resolveHref(_ rawHref: String) -> String? {
            let trimmed = rawHref.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let lower = trimmed.lowercased()
            if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") || lower.hasPrefix("data:") {
                return nil
            }

            // 1. In-document heading anchor `#slug`
            if trimmed.hasPrefix("#") {
                let rawFrag = String(trimmed.dropFirst())
                let decoded = rawFrag.removingPercentEncoding ?? rawFrag
                let normalizedSlug = Self.githubSlug(decoded)
                return "#" + (normalizedSlug.isEmpty ? decoded : normalizedSlug)
            }

            // 2. External web / mailto links
            if lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("mailto:") {
                return trimmed
            }

            // 3. `file://` or relative file path inside allowed root / active project
            let pathPart: String
            if lower.hasPrefix("file://"), let fileURL = URL(string: trimmed), fileURL.isFileURL {
                pathPart = fileURL.path
            } else if !trimmed.contains("://") {
                let withoutFrag = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
                pathPart = withoutFrag.removingPercentEncoding ?? withoutFrag
            } else {
                return nil
            }

            let root = options.allowedRoot ?? options.activeProjectPath
            guard !root.isEmpty,
                  let resolved = Self.containedLocalURL(raw: pathPart, allowedRoot: root, baseDirectory: options.baseDirectory)
            else {
                return nil
            }
            var comps = URLComponents()
            comps.scheme = "sarto-file"
            comps.host = "open"
            comps.queryItems = [URLQueryItem(name: "path", value: resolved.path)]
            return comps.string
        }

        private func sanitizeAttributes(tag: String, rawAttrs: String) -> [String: String] {
            let raw = Self.parseRawAttributes(rawAttrs)
            var out: [String: String] = [:]

            if let align = raw["align"]?.lowercased(), ["left", "center", "right", "justify"].contains(align) {
                out["align"] = align
                out["style"] = "text-align: \(align);"
            }
            if let valign = raw["valign"]?.lowercased(), ["top", "middle", "bottom", "baseline"].contains(valign) {
                out["valign"] = valign
            }
            if let width = raw["width"], Self.isSafeDimension(width) {
                out["width"] = width
            }
            if let height = raw["height"], Self.isSafeDimension(height) {
                out["height"] = height
            }
            if (tag == "td" || tag == "th"), let colspan = raw["colspan"], Int(colspan) != nil {
                out["colspan"] = colspan
            }
            if (tag == "td" || tag == "th"), let rowspan = raw["rowspan"], Int(rowspan) != nil {
                out["rowspan"] = rowspan
            }
            if tag == "details", raw["open"] != nil {
                out["open"] = ""
            }
            if tag == "ol", let start = raw["start"], Int(start) != nil {
                out["start"] = start
            }
            if let title = raw["title"], !title.isEmpty {
                out["title"] = title
            }
            if tag == "a", let href = raw["href"], let safeHref = resolveHref(href) {
                out["href"] = safeHref
            }
            return out
        }

    // MARK: - Static Helpers (Slug, Shields SVG, Containment, Sanitization, Syntax Highlighting)

    static func containedLocalURL(raw: String, allowedRoot: String, baseDirectory: String?) -> URL? {
        guard !allowedRoot.isEmpty, !raw.isEmpty else { return nil }
        let stripped = raw
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? raw
        let cleanPath = (stripped.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? stripped)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPath.isEmpty, !cleanPath.contains("://") else { return nil }

        let rootResolved = URL(fileURLWithPath: allowedRoot, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPrefix = rootResolved.path.hasSuffix("/") ? rootResolved.path : (rootResolved.path + "/")

        var candidates: [URL] = []
        if cleanPath.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: cleanPath))
        } else {
            if let baseDirectory, !baseDirectory.isEmpty {
                candidates.append(URL(fileURLWithPath: baseDirectory, isDirectory: true).appendingPathComponent(cleanPath))
            }
            candidates.append(rootResolved.appendingPathComponent(cleanPath))
        }

        for candidate in candidates {
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            if resolved.path.hasPrefix(rootPrefix),
               FileManager.default.fileExists(atPath: resolved.path) {
                return resolved
            }
        }
        return nil
    }

    /// Synthesizes a crisp offline two-tone SVG `data:image/svg+xml;base64,...` for `img.shields.io/badge/<label>-<message>-<color>`.
    static func synthesizeShieldsBadgeDataURI(_ rawURL: String) -> String? {
        guard let url = URL(string: rawURL),
              let host = url.host?.lowercased(),
              host == "img.shields.io",
              url.path.hasPrefix("/badge/")
        else { return nil }

        let rawSpec = String(url.path.dropFirst("/badge/".count))
        guard !rawSpec.isEmpty else { return nil }

        // Split on single `-` (Shields escapes literal `-` as `--` and space `_` as `__`)
        let tokens = splitShieldsTokens(rawSpec)
        let label: String
        let message: String
        let rawColor: String

        if tokens.count >= 3 {
            rawColor = tokens.last!
            message = tokens[tokens.count - 2]
            label = tokens.dropLast(2).joined(separator: "-")
        } else if tokens.count == 2 {
            label = ""
            message = tokens[0]
            rawColor = tokens[1]
        } else {
            return nil
        }

        let rightColor = resolveShieldsColor(rawColor)
        let cleanLabel = decodeShieldsText(label)
        let cleanMsg = decodeShieldsText(message)
        let leftW = cleanLabel.isEmpty ? 0 : Int(ceil(visualTextWidth(cleanLabel) + 14))
        let rightW = max(24, Int(ceil(visualTextWidth(cleanMsg) + 14)))
        let totalW = leftW + rightW
        let msgFg = isLightHexColor(rightColor) ? "#1f2328" : "#ffffff"

        let svg: String
        if leftW > 0 {
            svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="\(totalW)" height="20" role="img" aria-label="\(escAttr(cleanLabel)): \(escAttr(cleanMsg))">
              <clipPath id="r"><rect width="\(totalW)" height="20" rx="3" fill="#fff"/></clipPath>
              <g clip-path="url(#r)">
                <rect width="\(leftW)" height="20" fill="#555"/>
                <rect x="\(leftW)" width="\(rightW)" height="20" fill="\(rightColor)"/>
              </g>
              <g fill="#fff" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,PingFang SC,sans-serif" font-size="11">
                <text x="\(Double(leftW) / 2.0)" y="14">\(escHTML(cleanLabel))</text>
                <text x="\(Double(leftW) + Double(rightW) / 2.0)" y="14" fill="\(msgFg)" font-weight="500">\(escHTML(cleanMsg))</text>
              </g>
            </svg>
            """
        } else {
            svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="\(totalW)" height="20" role="img" aria-label="\(escAttr(cleanMsg))">
              <rect width="\(totalW)" height="20" rx="3" fill="\(rightColor)"/>
              <text x="\(Double(totalW) / 2.0)" y="14" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,PingFang SC,sans-serif" font-size="11" fill="\(msgFg)" font-weight="500">\(escHTML(cleanMsg))</text>
            </svg>
            """
        }
        guard let data = svg.data(using: .utf8) else { return nil }
        return "data:image/svg+xml;base64,\(data.base64EncodedString())"
    }

    private static func splitShieldsTokens(_ spec: String) -> [String] {
        let chars = Array(spec)
        var parts: [String] = []
        var cur = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "-" {
                if i + 1 < chars.count && chars[i + 1] == "-" {
                    cur.append("-")
                    i += 2
                    continue
                }
                parts.append(cur)
                cur = ""
                i += 1
                continue
            }
            cur.append(chars[i])
            i += 1
        }
        parts.append(cur)
        return parts
    }

    private static func decodeShieldsText(_ raw: String) -> String {
        let decoded = raw.removingPercentEncoding ?? raw
        var out = ""
        let chars = Array(decoded)
        var i = 0
        while i < chars.count {
            if chars[i] == "_" {
                if i + 1 < chars.count && chars[i + 1] == "_" {
                    out.append("_")
                    i += 2
                } else {
                    out.append(" ")
                    i += 1
                }
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    private static func resolveShieldsColor(_ raw: String) -> String {
        let lower = (raw.removingPercentEncoding ?? raw).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if let named = shieldsNamedColors[lower] { return named }
        if (lower.count == 6 || lower.count == 3) && lower.allSatisfy(\.isHexDigit) {
            return "#\(lower)"
        }
        return "#4c1"
    }

    private static func isLightHexColor(_ hexColor: String) -> Bool {
        var hex = hexColor.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6, let val = UInt32(hex, radix: 16) else { return false }
        let r = Double((val >> 16) & 0xFF)
        let g = Double((val >> 8) & 0xFF)
        let b = Double(val & 0xFF)
        let lum = 0.299 * r + 0.587 * g + 0.114 * b
        return lum > 186
    }

    private static func visualTextWidth(_ s: String) -> Double {
        var w = 0.0
        for scalar in s.unicodeScalars {
            if scalar.value > 0x2E7F {
                w += 11.2
            } else if scalar == " " {
                w += 3.6
            } else if "ilI1.,:;|!()[]".unicodeScalars.contains(scalar) {
                w += 4.2
            } else if "mwMW@%".unicodeScalars.contains(scalar) {
                w += 8.4
            } else {
                w += 6.5
            }
        }
        return w
    }

    static func githubSlug(_ plain: String) -> String {
        let lower = plain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out = ""
        var prevSpace = false
        for ch in lower {
            if ch.isLetter || ch.isNumber || ch == "_" {
                out.append(ch)
                prevSpace = false
            } else if ch == "-" {
                out.append("-")
                prevSpace = false
            } else if ch.isWhitespace {
                if !prevSpace && !out.isEmpty {
                    out.append("-")
                    prevSpace = true
                }
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    private static func plainHeadingText(_ raw: String) -> String {
        var s = raw
        if let rx = try? NSRegularExpression(pattern: "<[^>]+>") {
            s = rx.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        // Strip Markdown `[label](url)` -> `label` and formatting punctuation `*`, `_`, `` ` ``, `~`
        if let linkRx = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\([^)]*\\)") {
            s = linkRx.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        }
        return s.replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "~", with: "")
    }

    private static func stripUnsafeBlocksOutsideCodeFences(_ input: String) -> String {
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var segments: [(isCode: Bool, text: String)] = []
        var buf: [String] = []
        var i = 0

        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if let fence = detectFenceOpen(trimmed) {
                if !buf.isEmpty {
                    segments.append((false, buf.joined(separator: "\n")))
                    buf.removeAll(keepingCapacity: true)
                }
                var codeBuf: [String] = [lines[i]]
                i += 1
                while i < lines.count {
                    codeBuf.append(lines[i])
                    let ct = lines[i].trimmingCharacters(in: .whitespaces)
                    if ct.hasPrefix(fence.marker) && ct.dropFirst(fence.count).trimmingCharacters(in: .whitespaces).isEmpty {
                        i += 1
                        break
                    }
                    i += 1
                }
                segments.append((true, codeBuf.joined(separator: "\n")))
            } else {
                buf.append(lines[i])
                i += 1
            }
        }
        if !buf.isEmpty {
            segments.append((false, buf.joined(separator: "\n")))
        }

        let patterns = [
            "<!--[\\s\\S]*?-->",
            "(?is)<script\\b[^>]*>[\\s\\S]*?</script>",
            "(?is)<style\\b[^>]*>[\\s\\S]*?</style>",
            "(?is)<iframe\\b[^>]*>[\\s\\S]*?</iframe>",
            "(?is)<object\\b[^>]*>[\\s\\S]*?</object>",
            "(?is)<embed\\b[^>]*>",
        ]

        return segments.map { seg in
            guard !seg.isCode else { return seg.text }
            var cleaned = seg.text
            for pat in patterns {
                if let rx = try? NSRegularExpression(pattern: pat) {
                    cleaned = rx.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "")
                }
            }
            return cleaned
        }.joined(separator: "\n")
    }

    /// Joins multi-line opening HTML tags (such as `<img\n src="..."\n width="112">`) onto one line.
    private static func coalesceMultilineHTMLTags(_ lines: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("<"), !trimmed.hasPrefix("</"), !trimmed.contains(">"),
               let firstTagChar = trimmed.dropFirst().first, firstTagChar.isASCII && firstTagChar.isLetter {
                var joined = trimmed
                var j = i + 1
                var closed = false
                while j < min(lines.count, i + 10) {
                    let nextTrim = lines[j].trimmingCharacters(in: .whitespaces)
                    if nextTrim.isEmpty { break }
                    joined += " " + nextTrim
                    if nextTrim.contains(">") {
                        closed = true
                        j += 1
                        break
                    }
                    j += 1
                }
                if closed {
                    out.append(joined)
                    i = j
                    continue
                }
            }
            out.append(lines[i])
            i += 1
        }
        return out
    }

    private static func detectFenceOpen(_ trimmed: String) -> (marker: String, count: Int, language: String?, filename: String?)? {
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return nil }
        let ch = trimmed.first!
        let count = trimmed.prefix(while: { $0 == ch }).count
        let meta = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
        if ch == "`" && meta.contains("`") { return nil }
        guard !meta.isEmpty else { return (String(repeating: ch, count: count), count, nil, nil) }
        let parts = meta.split(separator: " ", maxSplits: 1).map(String.init)
        var lang = parts[0]
        var file: String? = nil
        if let colon = lang.firstIndex(of: ":"), colon > lang.startIndex {
            file = String(lang[lang.index(after: colon)...])
            lang = String(lang[..<colon])
        } else if parts.count > 1 {
            let rest = parts[1].trimmingCharacters(in: .whitespaces)
            if !rest.hasPrefix("{") {
                file = rest
                    .replacingOccurrences(of: "title=", with: "")
                    .replacingOccurrences(of: "file=", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return (String(repeating: ch, count: count), count, lang.isEmpty ? nil : lang, file)
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let compact = trimmed.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, (first == "-" || first == "*" || first == "_") else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func parseGitHubAlertHeader(_ line: String) -> (kind: GitHubAlertKind, remainder: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("[!"), let close = t.firstIndex(of: "]") else { return nil }
        let tag = String(t[t.index(t.startIndex, offsetBy: 2)..<close]).lowercased()
        guard let kind = GitHubAlertKind(rawValue: tag) else { return nil }
        let rest = String(t[t.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        return (kind, rest)
    }

    private static func renderAlertCard(kind: GitHubAlertKind, innerHTML: String) -> String {
        let cls: String
        let iconSVG: String
        switch kind {
        case .note:
            cls = "md-alert-note"
            iconSVG = "<svg width=\"14\" height=\"14\" viewBox=\"0 0 16 16\" fill=\"currentColor\"><path d=\"M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM6.5 7.75A.75.75 0 0 1 7.25 7h1a.75.75 0 0 1 .75.75v2.75h.25a.75.75 0 0 1 0 1.5h-2a.75.75 0 0 1 0-1.5h.25v-2h-.25a.75.75 0 0 1-.75-.75ZM8 6a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z\"/></svg>"
        case .tip:
            cls = "md-alert-tip"
            iconSVG = "<svg width=\"14\" height=\"14\" viewBox=\"0 0 16 16\" fill=\"currentColor\"><path d=\"M8 1.5c-2.363 0-4 1.69-4 3.75 0 .984.424 1.625.984 2.304l.214.253c.223.264.47.556.673.848.284.411.537.896.621 1.49a.75.75 0 0 1-1.484.211c-.04-.282-.163-.547-.37-.847a8.456 8.456 0 0 0-.542-.68c-.084-.1-.173-.205-.268-.32C3.201 7.75 2.5 6.766 2.5 5.25 2.5 2.31 4.863 0 8 0s5.5 2.31 5.5 5.25c0 1.516-.701 2.5-1.328 3.259-.095.115-.184.22-.268.319-.207.245-.383.453-.541.681-.208.3-.33.565-.37.847a.751.751 0 0 1-1.485-.212c.084-.593.337-1.078.621-1.489.203-.292.45-.584.673-.848.075-.088.147-.173.213-.253.561-.679.985-1.32.985-2.304 0-2.06-1.637-3.75-4-3.75ZM5.75 12h4.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1 0-1.5ZM6 15.25a.75.75 0 0 1 .75-.75h2.5a.75.75 0 0 1 0 1.5h-2.5a.75.75 0 0 1-.75-.75Z\"/></svg>"
        case .important:
            cls = "md-alert-important"
            iconSVG = "<svg width=\"14\" height=\"14\" viewBox=\"0 0 16 16\" fill=\"currentColor\"><path d=\"M0 1.75C0 .784.784 0 1.75 0h12.5C15.216 0 16 .784 16 1.75v9.5A1.75 1.75 0 0 1 14.25 13H8.06l-2.573 2.573A1.458 1.458 0 0 1 3 14.543V13H1.75A1.75 1.75 0 0 1 0 11.25Zm1.75-.25a.25.25 0 0 0-.25.25v9.5c0 .138.112.25.25.25h2a.75.75 0 0 1 .75.75v2.19l2.72-2.72a.749.749 0 0 1 .53-.22h6.5a.25.25 0 0 0 .25-.25v-9.5a.25.25 0 0 0-.25-.25Zm7 2.25v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 9a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z\"/></svg>"
        case .warning:
            cls = "md-alert-warning"
            iconSVG = "<svg width=\"14\" height=\"14\" viewBox=\"0 0 16 16\" fill=\"currentColor\"><path d=\"M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0 1 14.082 15H1.918a1.75 1.75 0 0 1-1.543-2.575Zm1.763.707a.25.25 0 0 0-.44 0L1.698 13.132a.25.25 0 0 0 .22.368h12.164a.25.25 0 0 0 .22-.368Zm.53 3.996v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z\"/></svg>"
        case .caution:
            cls = "md-alert-caution"
            iconSVG = "<svg width=\"14\" height=\"14\" viewBox=\"0 0 16 16\" fill=\"currentColor\"><path d=\"M4.47.22A.749.749 0 0 1 5 0h6c.199 0 .389.079.53.22l4.25 4.25c.141.14.22.331.22.53v6a.749.749 0 0 1-.22.53l-4.25 4.25A.749.749 0 0 1 11 16H5a.749.749 0 0 1-.53-.22L.22 11.53A.749.749 0 0 1 0 11V5c0-.199.079-.389.22-.53Zm.84 1.28L1.5 5.31v5.38l3.81 3.81h5.38l3.81-3.81V5.31L10.69 1.5ZM8 4a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 8 4Zm0 8a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z\"/></svg>"
        }
        return """
        <div class="md-alert \(cls)">
          <div class="md-alert-title">\(iconSVG)<span>\(escHTML(kind.title))</span></div>
          <div class="md-alert-body">\(innerHTML)</div>
        </div>
        """
    }

    private static func parseTableAlignments(_ trimmed: String) -> [String?]? {
        guard trimmed.contains("|") else { return nil }
        let cells = splitPipeCells(trimmed)
        guard !cells.isEmpty else { return nil }
        var alignments: [String?] = []
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty else { return nil }
            let left = c.hasPrefix(":")
            let right = c.hasSuffix(":")
            let core = c.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard core.count >= 3, core.allSatisfy({ $0 == "-" }) else { return nil }
            if left && right { alignments.append("center") }
            else if right { alignments.append("right") }
            else if left { alignments.append("left") }
            else { alignments.append(nil) }
        }
        return alignments
    }

    private static func splitPipeCells(_ trimmed: String) -> [String] {
        var s = trimmed
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") && !s.hasSuffix("\\|") { s.removeLast() }
        var cells: [String] = []
        var cur = ""
        let chars = Array(s)
        var i = 0
        var inCode = false
        while i < chars.count {
            if chars[i] == "`" {
                inCode.toggle()
                cur.append(chars[i])
                i += 1
                continue
            }
            if !inCode && chars[i] == "\\" && i + 1 < chars.count && chars[i + 1] == "|" {
                cur.append("|")
                i += 2
                continue
            }
            if !inCode && chars[i] == "|" {
                cells.append(cur.trimmingCharacters(in: .whitespaces))
                cur = ""
                i += 1
                continue
            }
            cur.append(chars[i])
            i += 1
        }
        cells.append(cur.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func parseStandaloneMarkdownImage(_ trimmed: String) -> (alt: String, url: String, title: String?)? {
        guard trimmed.hasPrefix("!["),
              let scanned = scanBracketParen(chars: Array(trimmed), openBracketIndex: 1),
              scanned.nextIndex == trimmed.count
        else { return nil }
        let (url, title) = splitLinkDestination(scanned.dest)
        guard !url.isEmpty else { return nil }
        return (scanned.label, url, title)
    }

    private static func scanBracketParen(chars: [Character], openBracketIndex: Int) -> (label: String, dest: String, nextIndex: Int)? {
        let n = chars.count
        guard openBracketIndex < n && chars[openBracketIndex] == "[" else { return nil }
        var depth = 1
        var i = openBracketIndex + 1
        var inCode = false
        while i < n && depth > 0 {
            if chars[i] == "\\" && i + 1 < n { i += 2; continue }
            if chars[i] == "`" { inCode.toggle(); i += 1; continue }
            if !inCode {
                if chars[i] == "[" { depth += 1 }
                else if chars[i] == "]" { depth -= 1; if depth == 0 { break } }
            }
            i += 1
        }
        guard depth == 0, i + 1 < n, chars[i + 1] == "(" else { return nil }
        let closeBracket = i
        var pDepth = 1
        var j = closeBracket + 2
        var inQuotes: Character? = nil
        while j < n && pDepth > 0 {
            let ch = chars[j]
            if ch == "\\" && j + 1 < n { j += 2; continue }
            if let q = inQuotes {
                if ch == q { inQuotes = nil }
                j += 1
                continue
            }
            if ch == "\"" || ch == "'" {
                inQuotes = ch
                j += 1
                continue
            }
            if ch == "(" { pDepth += 1 }
            else if ch == ")" { pDepth -= 1; if pDepth == 0 { break } }
            j += 1
        }
        guard pDepth == 0 else { return nil }
        let label = String(chars[(openBracketIndex + 1)..<closeBracket])
        let dest = String(chars[(closeBracket + 2)..<j])
        return (label, dest, j + 1)
    }

    private static func splitLinkDestination(_ raw: String) -> (url: String, title: String?) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<"), let close = s.firstIndex(of: ">") {
            let url = String(s[s.index(after: s.startIndex)..<close])
            let rest = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            let title = rest.count >= 2 ? String(rest.dropFirst().dropLast()) : nil
            return (url, title)
        }
        if let quoteIdx = s.firstIndex(where: { $0 == "\"" || $0 == "'" }) {
            let urlPart = String(s[..<quoteIdx]).trimmingCharacters(in: .whitespaces)
            var titlePart = String(s[quoteIdx...]).trimmingCharacters(in: .whitespaces)
            if titlePart.count >= 2 && (titlePart.first == "\"" || titlePart.first == "'") && titlePart.last == titlePart.first {
                titlePart = String(titlePart.dropFirst().dropLast())
                return (urlPart, titlePart)
            }
        }
        return (s, nil)
    }

    private static func findClosingAngle(chars: [Character], from start: Int) -> Int? {
        var i = start + 1
        var quote: Character? = nil
        while i < chars.count {
            let ch = chars[i]
            if ch == "\n" { return nil }
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == ">" {
                return i
            } else if ch == "<" {
                return nil
            }
            i += 1
        }
        return nil
    }

    private static func findClosingDelimiter(chars: [Character], from start: Int, delim: [Character]) -> Int? {
        guard chars.count >= start + delim.count else { return nil }
        var i = start
        while i + delim.count <= chars.count {
            if chars[i] == "`" {
                i += 1
                while i < chars.count && chars[i] != "`" { i += 1 }
                i += 1
                continue
            }
            if Array(chars[i..<(i + delim.count)]) == delim {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func findEmphasisClose(chars: [Character], from start: Int, marker: Character, count: Int) -> Int? {
        let n = chars.count
        var i = start
        while i + count <= n {
            if chars[i] == "\\" && i + 1 < n { i += 2; continue }
            if chars[i] == "`" {
                i += 1
                while i < n && chars[i] != "`" { i += 1 }
                i += 1
                continue
            }
            if chars[i] == marker {
                var run = 0
                while i + run < n && chars[i + run] == marker { run += 1 }
                if run >= count && i > start && !chars[i - 1].isWhitespace {
                    let afterIdx = i + count
                    let nextAlnum = afterIdx < n && (chars[afterIdx].isLetter || chars[afterIdx].isNumber)
                    if !(marker == "_" && nextAlnum) {
                        return i
                    }
                }
                i += run
                continue
            }
            i += 1
        }
        return nil
    }

    private static func matchSafeHTMLEntity(chars: [Character], from start: Int) -> Int? {
        let maxEnd = min(chars.count - 1, start + 10)
        guard start + 2 <= maxEnd else { return nil }
        var i = start + 1
        if chars[i] == "#" {
            i += 1
            if i <= maxEnd && (chars[i] == "x" || chars[i] == "X") {
                i += 1
                let hexStart = i
                while i <= maxEnd && chars[i].isHexDigit { i += 1 }
                if i > hexStart && i <= maxEnd && chars[i] == ";" { return i }
                return nil
            }
            let numStart = i
            while i <= maxEnd && chars[i].isNumber { i += 1 }
            if i > numStart && i <= maxEnd && chars[i] == ";" { return i }
            return nil
        }
        let nameStart = i
        while i <= maxEnd && chars[i].isASCII && (chars[i].isLetter || chars[i].isNumber) { i += 1 }
        if i > nameStart && i <= maxEnd && chars[i] == ";" { return i }
        return nil
    }

    private static func parseSingleHTMLTagLine(_ trimmed: String) -> (name: String, isClosing: Bool, rawAttrs: String)? {
        guard trimmed.hasPrefix("<"), trimmed.hasSuffix(">") else { return nil }
        let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty, !inner.contains("<"), !inner.contains(">") else { return nil }
        let isClosing = inner.hasPrefix("/")
        var rest = isClosing ? String(inner.dropFirst()).trimmingCharacters(in: .whitespaces) : inner
        if rest.hasSuffix("/") { rest = String(rest.dropLast()).trimmingCharacters(in: .whitespaces) }
        let name = rest.prefix(while: { $0.isASCII && ($0.isLetter || $0.isNumber) }).lowercased()
        guard !name.isEmpty else { return nil }
        let after = rest.dropFirst(name.count)
        guard after.isEmpty || after.first?.isWhitespace == true else { return nil }
        return (name, isClosing, String(after))
    }

    private static func parseSingleLinePairedHTMLBlock(_ trimmed: String) -> (name: String, rawAttrs: String, inner: String)? {
        guard trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), !trimmed.hasPrefix("</") else { return nil }
        let chars = Array(trimmed)
        guard let firstClose = findClosingAngle(chars: chars, from: 0), firstClose < chars.count - 3 else { return nil }
        let openBody = String(chars[1..<firstClose]).trimmingCharacters(in: .whitespaces)
        guard !openBody.hasSuffix("/") else { return nil }
        let name = openBody.prefix(while: { $0.isASCII && ($0.isLetter || $0.isNumber) }).lowercased()
        guard !name.isEmpty else { return nil }
        let afterName = openBody.dropFirst(name.count)
        guard afterName.isEmpty || afterName.first?.isWhitespace == true else { return nil }
        let closingSuffix = "</\(name)>"
        guard trimmed.lowercased().hasSuffix(closingSuffix) else { return nil }
        let contentEnd = chars.count - closingSuffix.count
        guard firstClose + 1 <= contentEnd else { return nil }
        let inner = String(chars[(firstClose + 1)..<contentEnd])
        // Reject when another `<name` appears nested on the same line
        if inner.lowercased().contains("<\(name)") { return nil }
        return (name, String(afterName), inner)
    }

    private static func parseRawAttributes(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        let chars = Array(raw)
        let n = chars.count
        var i = 0
        while i < n {
            while i < n && (chars[i].isWhitespace || chars[i] == "/") { i += 1 }
            guard i < n else { break }
            let nameStart = i
            while i < n && (chars[i].isLetter || chars[i].isNumber || chars[i] == "-" || chars[i] == "_" || chars[i] == ":") {
                i += 1
            }
            guard i > nameStart else { i += 1; continue }
            let key = String(chars[nameStart..<i]).lowercased()
            while i < n && chars[i].isWhitespace { i += 1 }
            if i < n && chars[i] == "=" {
                i += 1
                while i < n && chars[i].isWhitespace { i += 1 }
                if i < n && (chars[i] == "\"" || chars[i] == "'") {
                    let q = chars[i]
                    i += 1
                    let valStart = i
                    while i < n && chars[i] != q { i += 1 }
                    result[key] = decodeBasicHTMLEntities(String(chars[valStart..<i]))
                    if i < n && chars[i] == q { i += 1 }
                } else {
                    let valStart = i
                    while i < n && !chars[i].isWhitespace && chars[i] != ">" { i += 1 }
                    result[key] = decodeBasicHTMLEntities(String(chars[valStart..<i]))
                }
            } else {
                result[key] = ""
            }
        }
        return result
    }

    private static func decodeBasicHTMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private static func isSafeDimension(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 8 else { return false }
        let body = t.hasSuffix("%") || t.hasSuffix("px")
            ? t.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "px", with: "")
            : t
        return !body.isEmpty && body.allSatisfy(\.isNumber)
    }

    private static func formatAttrs(_ attrs: [String: String]) -> String {
        guard !attrs.isEmpty else { return "" }
        return attrs.keys.sorted().map { k in
            let v = attrs[k]!
            return v.isEmpty && k == "open" ? " open" : " \(k)=\"\(escAttr(v))\""
        }.joined()
    }

    static func sanitizeSVGMarkup(_ raw: String) -> String {
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

    static func escHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escAttr(_ s: String) -> String {
        escHTML(s).replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Lightweight HTML Syntax Highlighter (Matches CodeSyntaxHighlighter Families)

    private static let syntaxKeywords: [String: Set<String>] = [
        "swift": ["import", "struct", "class", "enum", "protocol", "extension", "actor", "func", "init", "let", "var", "if", "else", "guard", "switch", "case", "default", "for", "in", "while", "return", "throw", "throws", "try", "catch", "async", "await", "public", "private", "static", "final", "some", "any", "nil", "true", "false", "self", "Self"],
        "js": ["import", "export", "from", "default", "const", "let", "var", "function", "return", "if", "else", "switch", "case", "for", "of", "in", "while", "try", "catch", "throw", "new", "class", "extends", "interface", "type", "async", "await", "true", "false", "null", "undefined", "this"],
        "python": ["import", "from", "as", "def", "class", "return", "yield", "if", "elif", "else", "for", "in", "while", "try", "except", "finally", "raise", "with", "lambda", "async", "await", "and", "or", "not", "None", "True", "False", "self"],
        "rust": ["fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "pub", "mod", "use", "if", "else", "match", "for", "in", "while", "loop", "return", "async", "await", "move", "true", "false", "self", "Self"],
        "go": ["package", "import", "func", "type", "struct", "interface", "map", "chan", "var", "const", "if", "else", "switch", "case", "for", "range", "return", "go", "defer", "nil", "true", "false"],
        "shell": ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "export", "local", "set", "echo", "cd", "git", "pnpm", "npm", "npx", "swift", "xcodebuild", "curl", "sh"],
    ]

    private static func syntaxHighlightHTML(_ code: String, language: String) -> String {
        if language == "diff" || language == "patch" {
            return code.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                let s = String(line)
                if s.hasPrefix("+") && !s.hasPrefix("+++") {
                    return "<span class=\"syn-add\">\(escHTML(s))</span>"
                } else if s.hasPrefix("-") && !s.hasPrefix("---") {
                    return "<span class=\"syn-del\">\(escHTML(s))</span>"
                } else if s.hasPrefix("@@") || s.hasPrefix("+++") || s.hasPrefix("---") {
                    return "<span class=\"syn-typ\">\(escHTML(s))</span>"
                }
                return escHTML(s)
            }.joined(separator: "\n")
        }

        let family: String
        switch language {
        case "swift": family = "swift"
        case "ts", "tsx", "typescript", "js", "jsx", "javascript", "mjs", "cjs", "json", "jsonc": family = "js"
        case "py", "python": family = "python"
        case "rs", "rust": family = "rust"
        case "go", "golang": family = "go"
        case "sh", "bash", "zsh", "shell", "console": family = "shell"
        default: return escHTML(code)
        }

        let kw = syntaxKeywords[family] ?? []
        let hashComment = family == "python" || family == "shell"
        let chars = Array(code)
        let n = chars.count
        var out = ""
        var i = 0

        while i < n {
            let c = chars[i]
            if (c == "/" && i + 1 < n && chars[i + 1] == "/") || (hashComment && c == "#") {
                let s = i
                while i < n && chars[i] != "\n" { i += 1 }
                out += "<span class=\"syn-cmt\">\(escHTML(String(chars[s..<i])))</span>"
                continue
            }
            if c == "\"" || c == "'" {
                let q = c
                let s = i
                i += 1
                while i < n && chars[i] != "\n" {
                    if chars[i] == "\\" && i + 1 < n { i += 2; continue }
                    if chars[i] == q { i += 1; break }
                    i += 1
                }
                out += "<span class=\"syn-str\">\(escHTML(String(chars[s..<i])))</span>"
                continue
            }
            if c.isNumber {
                let s = i
                i += 1
                while i < n && (chars[i].isHexDigit || chars[i] == "x" || chars[i] == "." || chars[i] == "_") { i += 1 }
                out += "<span class=\"syn-num\">\(escHTML(String(chars[s..<i])))</span>"
                continue
            }
            if c.isLetter || c == "_" {
                let s = i
                i += 1
                while i < n && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") { i += 1 }
                let word = String(chars[s..<i])
                if kw.contains(word) {
                    out += "<span class=\"syn-kw\">\(escHTML(word))</span>"
                } else if let f = word.first, f.isUppercase, word.count > 1 {
                    out += "<span class=\"syn-typ\">\(escHTML(word))</span>"
                } else {
                    out += escHTML(word)
                }
                continue
            }
            out += escHTML(String(c))
            i += 1
        }
        return out
    }
}

// MARK: - Sandboxed Full-Pane WebKit Document View

#if os(macOS)
struct MarkdownDocumentWebView: NSViewRepresentable {
    let html: String
    let isDark: Bool
    let onOpenLocalFile: (String) -> Void
    let onPreviewLocalImage: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        web.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        web.navigationDelegate = context.coordinator
        context.coordinator.lastHTML = html
        web.loadHTMLString(html, baseURL: URL(string: "about:blank"))
        return web
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        webView.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            webView.loadHTMLString(html, baseURL: URL(string: "about:blank"))
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MarkdownDocumentWebView
        var lastHTML: String = ""

        init(parent: MarkdownDocumentWebView) {
            self.parent = parent
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            let scheme = url.scheme?.lowercased() ?? ""

            // Same-document `#anchor` navigation handled natively by WebKit C++ scrollToAnchor
            if scheme == "about" {
                decisionHandler(.allow)
                return
            }

            if scheme == "sarto-file" {
                if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let path = comps.queryItems?.first(where: { $0.name == "path" })?.value,
                   !path.isEmpty {
                    parent.onOpenLocalFile(path)
                }
                decisionHandler(.cancel)
                return
            }

            if scheme == "sarto-image" {
                let rawIdx = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if let idx = Int(rawIdx) {
                    parent.onPreviewLocalImage(idx)
                }
                decisionHandler(.cancel)
                return
            }

            if scheme == "https" || scheme == "http" || scheme == "mailto" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.cancel)
        }
    }
}
#endif

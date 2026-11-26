import AppKit
import SartoProtocol
import PrismDesign
import SwiftUI

// MARK: - Controller & Observable Bridge

@MainActor
struct ComposerHoveredChip: Equatable {
    let chip: ComposerChip
    /// Horizontal offset from the editor's leading edge, in points.
    let anchorX: CGFloat
    /// Vertical offset from the editor's top edge, in points.
    let anchorY: CGFloat
}

@MainActor
struct ComposerPastedLinkToast: Equatable {
    let fromUTF16: Int
    let toUTF16: Int
    let url: String
    let anchorX: CGFloat
}

@MainActor
struct ComposerKeyInterceptResult {
    let handled: Bool
    static let passThrough = ComposerKeyInterceptResult(handled: false)
    static let consume = ComposerKeyInterceptResult(handled: true)
}

/// Imperative bridge + fine-grained observable state for the macOS AppKit composer editor.
@MainActor
@Observable
final class ComposerEditorController {
    var caretUTF16: Int? = nil
    var isFocused: Bool = false
    var isComposing: Bool = false
    /// Whether the mention popover was already open when IME composition started (mirrors `prompt-box.tsx`).
    var compositionStartedWithMentionOpen: Bool = false
    var measuredContentHeight: CGFloat = 34
    /// Draft attachment IDs currently represented by inline `@` chips in the editor text.
    var mentionedAttachmentIDs: Set<UUID> = []
    /// Referenced session IDs currently represented by inline session chips in the editor text.
    var referencedSessionIDs: Set<String> = []
    var hoveredChip: ComposerHoveredChip? = nil
    var pastedLinkToast: ComposerPastedLinkToast? = nil

    @ObservationIgnored weak var textView: ComposerNSTextView?
    @ObservationIgnored private var pastedToastTask: Task<Void, Never>?

    func focus() {
        guard let tv = textView, let win = tv.window else { return }
        if win.firstResponder !== tv {
            win.makeFirstResponder(tv)
        }
    }

    func currentPlainText() -> String {
        textView?.plainText() ?? ""
    }

    func selectedPlainRange() -> NSRange {
        textView?.selectedPlainRange() ?? NSRange(location: 0, length: 0)
    }

    func setText(_ text: String, caretUTF16: Int? = nil, recordUndo: Bool = false) {
        textView?.applyProgrammaticText(text, caretUTF16: caretUTF16, recordUndo: recordUndo)
    }

    func insertPlainText(_ text: String) {
        textView?.insertUserPlainText(text)
    }

    func commitMarkedTextIfNeeded() {
        textView?.commitActiveCompositionIfNeeded()
    }

    func keepLinkAsText(url: String) {
        textView?.markLinkPlain(url: url)
        clearPastedLinkToast()
        focus()
    }

    func atVisualBoundary(forward: Bool) -> Bool {
        textView?.atVisualBoundary(forward: forward) ?? true
    }

    func xOffset(forPlainUTF16 pos: Int) -> CGFloat? {
        textView?.xOffset(forPlainUTF16: pos)
    }

    func showPastedLinkToast(_ toast: ComposerPastedLinkToast) {
        pastedToastTask?.cancel()
        pastedLinkToast = toast
        pastedToastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.pastedLinkToast = nil
        }
    }

    func clearPastedLinkToast() {
        pastedToastTask?.cancel()
        pastedToastTask = nil
        if pastedLinkToast != nil { pastedLinkToast = nil }
    }
}

// MARK: - Chip Attachment & Retina Pill Renderer

final class ComposerChipAttachment: NSTextAttachment {
    var chip: ComposerChip
    let rawToken: String
    var isSelected: Bool
    let hasThumbnail: Bool

    init(
        chip: ComposerChip,
        rawToken: String,
        isSelected: Bool,
        hasThumbnail: Bool,
        image: NSImage,
        baselineOffset: CGFloat
    ) {
        self.chip = chip
        self.rawToken = rawToken
        self.isSelected = isSelected
        self.hasThumbnail = hasThumbnail
        super.init(data: nil, ofType: nil)
        self.image = image
        self.bounds = CGRect(x: 0, y: baselineOffset, width: image.size.width, height: image.size.height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private enum ComposerChipRenderer {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        return c
    }()

    static func render(
        chip: ComposerChip,
        selected: Bool,
        tokens: PrismTokens,
        fontSize: CGFloat,
        thumbImage: NSImage?
    ) -> (image: NSImage, baselineOffset: CGFloat) {
        let pillHeight = max(20, round(fontSize + 6.5))
        let baselineOffset = -round((pillHeight - fontSize * 0.72) / 2.0) + 1.0
        let paletteTag = "\(tokens.palette.rawValue)-\(tokens.palette.isDark ? "d" : "l")-\(Int(fontSize * 10))"
        let cacheKey = "\(paletteTag)|\(selected ? "1" : "0")|\(chipCacheSignature(chip))|\(thumbImage != nil ? "t" : "n")" as NSString

        if thumbImage == nil, let cached = cache.object(forKey: cacheKey) {
            return (cached, baselineOffset)
        }

        let isMissing: Bool = {
            switch chip {
            case .mention(_, _, _, _, _, _, _, _, let missing): return missing
            case .session(_, _, _, _, _, _, let missing): return missing
            default: return false
            }
        }()

        let textFont = NSFont.systemFont(ofSize: max(11.5, fontSize - 2.0), weight: .medium)
        let secondaryFont = NSFont.systemFont(ofSize: max(11.0, fontSize - 2.5), weight: .regular)
        let primaryColor = NSColor(isMissing ? tokens.mutedForeground : tokens.foreground)
        let mutedColor = NSColor(tokens.mutedForeground)
        let accentColor = NSColor(tokens.primary)
        let warningColor = NSColor(tokens.warning)

        let labelAttr = NSMutableAttributedString()
        switch chip {
        case .command(_, _, let name):
            labelAttr.append(NSAttributedString(string: "/", attributes: [.font: textFont, .foregroundColor: accentColor.withAlphaComponent(0.6)]))
            labelAttr.append(NSAttributedString(string: name, attributes: [.font: textFont, .foregroundColor: accentColor]))

        case .session(_, _, _, _, let title, _, let missing):
            var attrs: [NSAttributedString.Key: Any] = [.font: textFont, .foregroundColor: primaryColor]
            if missing {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            labelAttr.append(NSAttributedString(string: title, attributes: attrs))

        case .mention(_, _, _, _, let label, let lines, _, _, let missing):
            var attrs: [NSAttributedString.Key: Any] = [.font: textFont, .foregroundColor: primaryColor]
            if missing {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            labelAttr.append(NSAttributedString(string: label, attributes: attrs))
            if let lines, !lines.isEmpty {
                labelAttr.append(NSAttributedString(string: ":\(lines)", attributes: [
                    .font: secondaryFont,
                    .foregroundColor: mutedColor,
                ]))
            }

        case .link(_, _, _, let host, let path, _, let gh):
            if let gh {
                labelAttr.append(NSAttributedString(string: gh.shortLabel, attributes: [
                    .font: textFont,
                    .foregroundColor: primaryColor,
                ]))
            } else {
                labelAttr.append(NSAttributedString(string: host, attributes: [
                    .font: textFont,
                    .foregroundColor: primaryColor,
                ]))
                let shortPath = ComposerChipsParser.shortLinkPath(host: host, path: path)
                if !shortPath.isEmpty {
                    labelAttr.append(NSAttributedString(string: shortPath, attributes: [
                        .font: secondaryFont,
                        .foregroundColor: mutedColor,
                    ]))
                }
            }
        }

        let maxTextWidth: CGFloat = 240
        let rawTextSize = labelAttr.size()
        let drawnTextWidth = min(ceil(rawTextSize.width), maxTextWidth)
        let iconSize: CGFloat = thumbImage != nil ? 14 : 12.5
        let padLeft: CGFloat = 6
        let padRight: CGFloat = 7
        let gap: CGFloat = 5
        let totalWidth = ceil(padLeft + iconSize + gap + drawnTextWidth + padRight)
        let pillSize = NSSize(width: totalWidth + 2, height: pillHeight)

        let isSessionChip: Bool = {
            if case .session = chip { return true }
            return false
        }()

        let fillColor: NSColor
        let strokeColor: NSColor
        let strokeWidth: CGFloat
        if isMissing {
            fillColor = NSColor(tokens.surface2).withAlphaComponent(0.45)
            strokeColor = warningColor.withAlphaComponent(0.75)
            strokeWidth = 1.0
        } else if selected {
            fillColor = accentColor.withAlphaComponent(tokens.palette.isDark ? 0.22 : 0.14)
            strokeColor = accentColor
            strokeWidth = 1.4
        } else if isSessionChip {
            fillColor = accentColor.withAlphaComponent(tokens.palette.isDark ? 0.16 : 0.10)
            strokeColor = accentColor.withAlphaComponent(tokens.palette.isDark ? 0.45 : 0.35)
            strokeWidth = 0.9
        } else {
            fillColor = NSColor(tokens.surface2).withAlphaComponent(tokens.palette.isDark ? 0.92 : 0.95)
            strokeColor = NSColor(tokens.borderStrong).withAlphaComponent(0.85)
            strokeWidth = 0.85
        }

        let symbolName: String
        let symbolTint: NSColor
        switch chip {
        case .command:
            symbolName = "command"
            symbolTint = accentColor
        case .session(_, _, _, _, _, _, let missing):
            if missing {
                symbolName = "exclamationmark.triangle.fill"
                symbolTint = warningColor
            } else {
                symbolName = "bubble.left.and.text.bubble.right.fill"
                symbolTint = accentColor
            }
        case .mention(_, _, let kind, _, let label, _, _, _, let missing):
            if missing {
                symbolName = "exclamationmark.triangle.fill"
                symbolTint = warningColor
            } else {
                switch kind {
                case .folder:
                    symbolName = "folder.fill"
                    symbolTint = NSColor(tokens.prismCobalt)
                case .image:
                    symbolName = "photo"
                    symbolTint = NSColor(tokens.prismCobalt)
                case .file:
                    symbolName = PrismImageDecoder.symbolName(for: label, mimeType: nil, type: "file")
                    symbolTint = NSColor(tokens.prismCobalt)
                }
            }
        case .link(_, _, _, _, _, let isLocal, let gh):
            if let gh {
                symbolName = gh.kind == .pull ? "arrow.triangle.pull" : "circle.inset.filled"
                symbolTint = NSColor(gh.kind == .pull ? tokens.prismIris : tokens.success)
            } else if isLocal {
                symbolName = "globe"
                symbolTint = accentColor
            } else {
                symbolName = "link"
                symbolTint = NSColor(tokens.prismCobalt)
            }
        }

        let image = NSImage(size: pillSize, flipped: true) { rect in
            let inset = strokeWidth / 2.0 + 0.5
            let pillRect = NSRect(
                x: 1 + inset,
                y: inset,
                width: rect.width - 2 - inset * 2,
                height: rect.height - inset * 2
            )
            let path = NSBezierPath(roundedRect: pillRect, xRadius: 6, yRadius: 6)
            fillColor.setFill()
            path.fill()

            strokeColor.setStroke()
            path.lineWidth = strokeWidth
            if isMissing {
                let dash: [CGFloat] = [3, 2]
                path.setLineDash(dash, count: 2, phase: 0)
            }
            path.stroke()

            let iconRect = NSRect(
                x: 1 + padLeft,
                y: (rect.height - iconSize) / 2.0,
                width: iconSize,
                height: iconSize
            )
            if let thumbImage {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: iconRect, xRadius: 3, yRadius: 3).addClip()
                thumbImage.draw(
                    in: iconRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0,
                    respectFlipped: true,
                    hints: nil
                )
                NSGraphicsContext.restoreGraphicsState()
            } else if let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                let cfg = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
                let configured = sym.withSymbolConfiguration(cfg) ?? sym
                let tinted = Self.tintedSymbol(configured, color: symbolTint)
                let symSize = tinted.size
                let scale = min(iconSize / max(1, symSize.width), iconSize / max(1, symSize.height))
                let drawSize = NSSize(width: symSize.width * scale, height: symSize.height * scale)
                let drawRect = NSRect(
                    x: iconRect.midX - drawSize.width / 2.0,
                    y: iconRect.midY - drawSize.height / 2.0,
                    width: drawSize.width,
                    height: drawSize.height
                )
                tinted.draw(
                    in: drawRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0,
                    respectFlipped: true,
                    hints: nil
                )
            }

            let textRect = NSRect(
                x: 1 + padLeft + iconSize + gap,
                y: (rect.height - rawTextSize.height) / 2.0,
                width: drawnTextWidth,
                height: rawTextSize.height
            )
            labelAttr.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
        image.isTemplate = false

        if thumbImage == nil {
            cache.setObject(image, forKey: cacheKey)
        }
        return (image, baselineOffset)
    }

    private static func tintedSymbol(_ image: NSImage, color: NSColor) -> NSImage {
        let size = image.size
        guard size.width > 0 && size.height > 0 else { return image }
        let out = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        out.isTemplate = false
        return out
    }

    private static func chipCacheSignature(_ chip: ComposerChip) -> String {
        switch chip {
        case .command(_, _, let name):
            return "c:\(name)"
        case .session(_, _, _, let sid, let title, _, let missing):
            return "s:\(sid):\(title):\(missing ? "1" : "0")"
        case .mention(_, _, let kind, _, let label, let lines, _, _, let missing):
            return "m:\(kind.rawValue):\(label):\(lines ?? ""):\(missing ? "1" : "0")"
        case .link(_, _, let url, _, _, let isLocal, let gh):
            return "l:\(url):\(isLocal ? "1" : "0"):\(gh?.shortLabel ?? "")"
        }
    }
}

// MARK: - Live Markdown Highlighter (mirrors markdown-preview.ts visual semantics)

@MainActor
private enum ComposerMarkdownStyler {
    private static let headingRegex = try! NSRegularExpression(pattern: #"^(#{1,6})(\s+)(.*)$"#, options: [.anchorsMatchLines])
    private static let quoteRegex = try! NSRegularExpression(pattern: #"^(>\s?)(.*)$"#, options: [.anchorsMatchLines])
    private static let bulletRegex = try! NSRegularExpression(pattern: #"^(\s*(?:[-*+]|\d+\.)\s+)"#, options: [.anchorsMatchLines])
    private static let boldRegex = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, options: [])
    private static let strikeRegex = try! NSRegularExpression(pattern: #"(~~)(?=\S)(.+?)(?<=\S)\1"#, options: [])
    private static let italicRegex = try! NSRegularExpression(pattern: #"(?<![\*\\])(\*)(?=\S)([^\*\n]+?)(?<=\S)\1(?!\*)"#, options: [])
    private static let codeRegex = try! NSRegularExpression(pattern: #"(`+)([^`\n]+?)\1"#, options: [])
    private static let mdLinkRegex = try! NSRegularExpression(pattern: #"(\[)([^\]\n]+)(\]\()([^\)\s\n]+)(\))"#, options: [])
    private static let markdownSpecialChars = CharacterSet(charactersIn: "#>-+*_~`[123456789")
    private static let selectionDependentChars = CharacterSet(charactersIn: "#>*_~`[")

    static func hasSelectionDependentSyntax(in text: String) -> Bool {
        (text as NSString).rangeOfCharacter(from: selectionDependentChars).location != NSNotFound
    }

    static func apply(
        to storage: NSTextStorage,
        tokens: PrismTokens,
        baseFont: NSFont,
        codeFont: NSFont,
        commandNames: [String],
        selection: NSRange,
        isFocused: Bool
    ) {
        let fullLen = storage.length
        guard fullLen > 0 else { return }

        let fullRange = NSRange(location: 0, length: fullLen)
        let str = storage.string
        let baseColor = NSColor(tokens.foreground)
        let nsStr = str as NSString

        // Reset base attributes on non-attachment runs only.
        storage.enumerateAttribute(.attachment, in: fullRange) { value, range, _ in
            if value == nil {
                storage.setAttributes([
                    .font: baseFont,
                    .foregroundColor: baseColor,
                ], range: range)
            }
        }

        // Fast-path plain text without leading `/` or Markdown characters.
        let hasLeadingSlash = str.hasPrefix("/")
        if !hasLeadingSlash && nsStr.rangeOfCharacter(from: markdownSpecialChars).location == NSNotFound {
            return
        }

        let mutedMark = NSColor(tokens.mutedForeground).withAlphaComponent(0.45)
        let activeMark = NSColor(tokens.mutedForeground).withAlphaComponent(0.75)
        let accentColor = NSColor(tokens.primary)
        let secondaryColor = NSColor(tokens.secondaryForeground)
        let linkColor = NSColor(tokens.prismCobalt)
        let codeBg = NSColor(tokens.surface2).withAlphaComponent(0.9)
        let codeFg = NSColor(tokens.prismCobalt)

        // Skip ranges containing attachments so chip bounds and colors stay intact.
        func containsAttachment(_ range: NSRange) -> Bool {
            var found = false
            storage.enumerateAttribute(.attachment, in: range) { value, _, stop in
                if value != nil {
                    found = true
                    stop.pointee = true
                }
            }
            return found
        }

        func touches(_ range: NSRange) -> Bool {
            guard isFocused else { return false }
            return selection.location <= NSMaxRange(range) && NSMaxRange(selection) >= range.location
        }

        // 1. Leading /command highlight
        let cmdLen = ComposerTrigger.leadingCommandLengthUTF16(in: str, names: commandNames)
        if cmdLen > 1 && cmdLen <= fullLen {
            let cmdRange = NSRange(location: 0, length: cmdLen)
            if !containsAttachment(cmdRange) {
                let cmdFont = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
                storage.addAttributes([.font: cmdFont, .foregroundColor: accentColor], range: cmdRange)
                storage.addAttribute(.foregroundColor, value: accentColor.withAlphaComponent(0.55), range: NSRange(location: 0, length: 1))
            }
        }

        // 2. Headings (# .. ######)
        for m in headingRegex.matches(in: str, range: fullRange) {
            if containsAttachment(m.range) { continue }
            let level = m.range(at: 1).length
            let scale: CGFloat = level == 1 ? 1.24 : (level == 2 ? 1.12 : 1.04)
            let hFont = NSFont.systemFont(ofSize: round(baseFont.pointSize * scale), weight: .semibold)
            let color = level >= 4 ? secondaryColor : baseColor
            storage.addAttributes([.font: hFont, .foregroundColor: color], range: m.range)
            let markRange = NSRange(location: m.range(at: 1).location, length: m.range(at: 1).length + m.range(at: 2).length)
            storage.addAttribute(.foregroundColor, value: touches(m.range) ? activeMark : mutedMark, range: markRange)
        }

        // 3. Blockquotes (> ...)
        for m in quoteRegex.matches(in: str, range: fullRange) {
            if containsAttachment(m.range) { continue }
            storage.addAttribute(.foregroundColor, value: secondaryColor, range: m.range)
            storage.addAttribute(.foregroundColor, value: touches(m.range) ? activeMark : mutedMark, range: m.range(at: 1))
        }

        // 4. List markers (- , * , 1. )
        for m in bulletRegex.matches(in: str, range: fullRange) {
            if containsAttachment(m.range) { continue }
            storage.addAttribute(.foregroundColor, value: activeMark, range: m.range(at: 1))
        }

        // 5. Bold (**text**)
        let boldFont = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
        for m in boldRegex.matches(in: str, range: fullRange) {
            if containsAttachment(m.range) { continue }
            storage.addAttribute(.font, value: boldFont, range: m.range(at: 2))
            let markCol = touches(m.range) ? activeMark : mutedMark
            let openLen = m.range(at: 1).length
            storage.addAttribute(.foregroundColor, value: markCol, range: NSRange(location: m.range.location, length: openLen))
            storage.addAttribute(.foregroundColor, value: markCol, range: NSRange(location: NSMaxRange(m.range) - openLen, length: openLen))
        }

        // 6. Italic (*text*)
        let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        for m in italicRegex.matches(in: str, range: fullRange) {
            if containsAttachment(m.range) { continue }
            storage.addAttribute(.font, value: italicFont, range: m.range(at: 2))
            let markCol = touches(m.range) ? activeMark : mutedMark
            storage.addAttribute(.foregroundColor, value: markCol, range: NSRange(location: m.range.location, length: 1))
            storage.addAttribute(.foregroundColor, value: markCol, range: NSRange(location: NSMaxRange(m.range) - 1, length: 1))
        }

        // 7. Strikethrough (~~text~~)
        for m in strikeRegex.matches(in: str, range: fullRange) {
            if containsAttachment(m.range) { continue }
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 2))
            let markCol = touches(m.range) ? activeMark : mutedMark
            storage.addAttribute(.foregroundColor, value: markCol, range: NSRange(location: m.range.location, length: 2))
            storage.addAttribute(.foregroundColor, value: markCol, range: NSRange(location: NSMaxRange(m.range) - 2, length: 2))
        }

        // 8. Inline code (`code`)
        for m in codeRegex.matches(in: str, range: fullRange) {
            if containsAttachment(m.range) { continue }
            storage.addAttributes([
                .font: codeFont,
                .foregroundColor: codeFg,
                .backgroundColor: codeBg,
            ], range: m.range(at: 2))
            let markCol = touches(m.range) ? activeMark : mutedMark
            let tickLen = m.range(at: 1).length
            storage.addAttribute(.foregroundColor, value: markCol, range: NSRange(location: m.range.location, length: tickLen))
            storage.addAttribute(.foregroundColor, value: markCol, range: NSRange(location: NSMaxRange(m.range) - tickLen, length: tickLen))
        }

        // 9. Markdown links ([text](url))
        for m in mdLinkRegex.matches(in: str, range: fullRange) {
            if containsAttachment(m.range) { continue }
            storage.addAttributes([
                .foregroundColor: linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: m.range(at: 2))
            let markCol = touches(m.range) ? activeMark : mutedMark
            storage.addAttribute(.foregroundColor, value: markCol, range: m.range(at: 1))
            let tailStart = m.range(at: 3).location
            let tailLen = NSMaxRange(m.range) - tailStart
            storage.addAttribute(.foregroundColor, value: markCol, range: NSRange(location: tailStart, length: tailLen))
        }
    }
}

// MARK: - Native AppKit NSTextView Subclass

@MainActor
final class ComposerNSTextView: NSTextView {
    struct Config {
        var scope: String
        var tokens: PrismTokens
        var fontSize: CGFloat
        var proseFontFamily: String
        var codeFontFamily: String
        var placeholder: String
        var isDisabled: Bool
        var commandNames: [String]
        var attachments: [DraftAttachmentItem]
        var sessionReferences: [DraftSessionReference]
        var missingSessionIDs: Set<String>
    }

    struct Callbacks {
        var onTextChange: (String, Int?) -> Void
        var onCaretChange: (Int?) -> Void
        var onKeyDown: (NSEvent) -> Bool
        var onPaste: () -> Bool
        var onChipClick: (ComposerChip) -> Void
        var onMentionDeleted: ([UUID]) -> Void
        var onSessionRefDeleted: ([String]) -> Void
        var isMentionPopoverOpen: () -> Bool
    }

    private struct UndoSnapshot: Equatable {
        let text: String
        let caretUTF16: Int
    }

    weak var controller: ComposerEditorController?
    var config: Config
    var callbacks: Callbacks

    /// URLs explicitly converted back to plain text via `Keep as text` (`Cmd+Shift+V`) in the current draft.
    private var plainLinkURLs: Set<String> = []
    /// Plain-text range of the `@mention` or URL currently being typed so it stays editable until caret leaves.
    private var activeTypingRange: Range<Int>? = nil
    private var isSyncingStorage = false
    private var isHandlingDirectEdit = false
    private var isUpdatingFromSwiftUI = false
    private var isDiscardingMarkedText = false
    private var pendingAppearanceRebuild = false
    /// Last draft string synced with SwiftUI so `updateConfig` only discards active IME
    /// composition when external state truly changed (not when typing into an empty box).
    private var lastSyncedExternalText: String = ""
    private var undoStack: [UndoSnapshot] = []
    private var redoStack: [UndoSnapshot] = []
    private var lastUndoPushTime: TimeInterval = 0
    private var lastCommittedSnapshot: UndoSnapshot = UndoSnapshot(text: "", caretUTF16: 0)
    private var hoverTask: Task<Void, Never>?
    private var hoveredCharIndex: Int? = nil
    private var trackingAreaRef: NSTrackingArea?

    init(config: Config, callbacks: Callbacks) {
        self.config = config
        self.callbacks = callbacks

        // Explicitly create TextKit 1 stack for deterministic glyph geometry and dynamic auto-height.
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 2
        layoutManager.addTextContainer(textContainer)

        super.init(frame: .zero, textContainer: textContainer)

        self.drawsBackground = false
        self.isRichText = true
        self.importsGraphics = false
        self.allowsUndo = false // Managed via plain-text undoStack so chip length swaps never desync NSRange.
        self.isVerticallyResizable = true
        self.isHorizontallyResizable = false
        self.minSize = NSSize(width: 0, height: 0)
        self.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        self.autoresizingMask = [.width]
        self.textContainerInset = NSSize(width: 4, height: 5)
        self.isAutomaticQuoteSubstitutionEnabled = false
        self.isAutomaticDashSubstitutionEnabled = false
        self.isAutomaticTextReplacementEnabled = false
        self.isAutomaticSpellingCorrectionEnabled = false
        self.isContinuousSpellCheckingEnabled = true
        self.smartInsertDeleteEnabled = false
        self.insertionPointColor = NSColor(config.tokens.primary)
        self.font = resolvedBaseFont()
        self.textColor = NSColor(config.tokens.foreground)
        self.isEditable = !config.isDisabled
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            clearHover()
        }
    }

    // MARK: - Fonts & Drawing

    private func resolvedBaseFont() -> NSFont {
        if !config.proseFontFamily.isEmpty,
           let custom = NSFont(name: config.proseFontFamily, size: config.fontSize) {
            return custom
        }
        return NSFont.systemFont(ofSize: config.fontSize, weight: .regular)
    }

    private func resolvedCodeFont() -> NSFont {
        let size = max(11.5, config.fontSize - 1.5)
        if !config.codeFontFamily.isEmpty,
           let custom = NSFont(name: config.codeFontFamily, size: size) {
            return custom
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty && !hasMarkedText() && !config.placeholder.isEmpty {
            let font = resolvedBaseFont()
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(config.tokens.placeholder),
                .paragraphStyle: style,
            ]
            let inset = textContainerInset
            let pad = textContainer?.lineFragmentPadding ?? 2
            let rect = NSRect(
                x: inset.width + pad,
                y: inset.height,
                width: max(0, bounds.width - (inset.width + pad) * 2),
                height: font.ascender - font.descender + 4
            )
            (config.placeholder as NSString).draw(in: rect, withAttributes: attrs)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportMeasuredHeight()
    }

    // MARK: - Focus & Responder

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            controller?.isFocused = true
            syncChipsAndMarkdown()
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            controller?.isFocused = false
            clearHover()
            syncChipsAndMarkdown()
        }
        return ok
    }

    // MARK: - IME Tracking

    private func discardActiveComposition() {
        guard hasMarkedText() else { return }
        isDiscardingMarkedText = true
        defer { isDiscardingMarkedText = false }
        inputContext?.discardMarkedText()
        if hasMarkedText() {
            super.unmarkText()
        }
        mutateController { ctrl in
            if ctrl.isComposing {
                ctrl.isComposing = false
            }
        }
    }

    func commitActiveCompositionIfNeeded() {
        guard hasMarkedText() else { return }
        inputContext?.discardMarkedText()
        if hasMarkedText() {
            unmarkText()
        }
        if !hasMarkedText() && plainText() != lastSyncedExternalText {
            handlePostEdit(isUserDelete: false)
        }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let wasComposing = hasMarkedText()
        if !wasComposing {
            controller?.compositionStartedWithMentionOpen = callbacks.isMentionPopoverOpen()
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        let nowComposing = hasMarkedText()
        mutateController { ctrl in
            if ctrl.isComposing != nowComposing {
                ctrl.isComposing = nowComposing
            }
        }
        reportMeasuredHeight()
        needsDisplay = true
    }

    override func unmarkText() {
        super.unmarkText()
        guard !hasMarkedText() else { return }
        mutateController { ctrl in
            if ctrl.isComposing {
                ctrl.isComposing = false
            }
        }
        // Skip re-entrant storage mutations while AppKit is mid-`insertText` or we are discarding/syncing.
        guard !isDiscardingMarkedText, !isHandlingDirectEdit, !isSyncingStorage, !isUpdatingFromSwiftUI else {
            return
        }
        if plainText() != lastSyncedExternalText {
            let beforeMentionIDs = controller?.mentionedAttachmentIDs ?? []
            let beforeSessionIDs = controller?.referencedSessionIDs ?? []
            pushUndoIfNeeded(
                previousText: lastCommittedSnapshot.text,
                previousCaret: lastCommittedSnapshot.caretUTF16,
                force: false
            )
            handlePostEdit(
                isUserDelete: !beforeMentionIDs.isEmpty || !beforeSessionIDs.isEmpty,
                candidateDeletedIDs: beforeMentionIDs,
                candidateDeletedSessionIDs: beforeSessionIDs
            )
        } else {
            syncChipsAndMarkdown()
        }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let hadMarked = hasMarkedText()
        let beforePlain = hadMarked ? lastCommittedSnapshot.text : plainText()
        let beforeCaret = hadMarked ? lastCommittedSnapshot.caretUTF16 : selectedPlainRange().location
        let beforeMentionIDs = controller?.mentionedAttachmentIDs ?? []
        let beforeSessionIDs = controller?.referencedSessionIDs ?? []
        pushUndoIfNeeded(previousText: beforePlain, previousCaret: beforeCaret, force: false)
        isHandlingDirectEdit = true
        super.insertText(string, replacementRange: replacementRange)
        isHandlingDirectEdit = false
        if hadMarked && !hasMarkedText() {
            mutateController { ctrl in
                if ctrl.isComposing {
                    ctrl.isComposing = false
                }
            }
        }
        if !hasMarkedText() {
            let text = plainText()
            let sel = selectedPlainRange()
            activeTypingRange = sel.length == 0 ? ComposerChipsParser.typingRange(in: text, caretUTF16: sel.location) : nil
            handlePostEdit(
                isUserDelete: !beforeMentionIDs.isEmpty || !beforeSessionIDs.isEmpty,
                candidateDeletedIDs: beforeMentionIDs,
                candidateDeletedSessionIDs: beforeSessionIDs
            )
        }
    }

    // MARK: - Plain Text <-> Display Storage Mapping

    /// Extracts the canonical plain Markdown text by expanding every `ComposerChipAttachment` back to its `rawToken`.
    func plainText() -> String {
        guard let storage = textStorage, storage.length > 0 else { return "" }
        let full = NSRange(location: 0, length: storage.length)
        var out = ""
        out.reserveCapacity(storage.length + 32)
        let ns = storage.string as NSString
        storage.enumerateAttribute(.attachment, in: full) { value, range, _ in
            if let chipAtt = value as? ComposerChipAttachment {
                out.append(chipAtt.rawToken)
            } else {
                out.append(ns.substring(with: range))
            }
        }
        return out
    }

    /// Canonical plain Markdown text excluding any active IME marked text range.
    func committedPlainText() -> String {
        guard let storage = textStorage, storage.length > 0 else { return "" }
        let marked = markedRange()
        guard marked.location != NSNotFound, marked.length > 0, NSMaxRange(marked) <= storage.length else {
            return plainText()
        }
        var out = ""
        out.reserveCapacity(storage.length + 32)
        let ns = storage.string as NSString
        func appendRange(_ subrange: NSRange) {
            guard subrange.length > 0 else { return }
            storage.enumerateAttribute(.attachment, in: subrange) { value, range, _ in
                if let chipAtt = value as? ComposerChipAttachment {
                    out.append(chipAtt.rawToken)
                } else {
                    out.append(ns.substring(with: range))
                }
            }
        }
        appendRange(NSRange(location: 0, length: marked.location))
        appendRange(NSRange(location: NSMaxRange(marked), length: storage.length - NSMaxRange(marked)))
        return out
    }

    func plainOffset(forDisplayOffset displayOffset: Int) -> Int {
        guard let storage = textStorage, storage.length > 0 else { return 0 }
        let clamped = max(0, min(displayOffset, storage.length))
        guard clamped > 0 else { return 0 }
        var plain = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: clamped)) { value, range, _ in
            if let chipAtt = value as? ComposerChipAttachment {
                plain += (chipAtt.rawToken as NSString).length
            } else {
                plain += range.length
            }
        }
        return plain
    }

    func displayOffset(forPlainOffset plainOffset: Int) -> Int {
        guard let storage = textStorage, storage.length > 0 else { return 0 }
        if plainOffset <= 0 { return 0 }
        var remaining = plainOffset
        var display = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if let chipAtt = value as? ComposerChipAttachment {
                let tokLen = (chipAtt.rawToken as NSString).length
                if remaining < tokLen {
                    stop.pointee = true
                    return
                }
                remaining -= tokLen
                display += range.length
            } else {
                if remaining <= range.length {
                    display += remaining
                    remaining = 0
                    stop.pointee = true
                    return
                }
                remaining -= range.length
                display += range.length
            }
        }
        return min(display, storage.length)
    }

    func selectedPlainRange() -> NSRange {
        let sel = selectedRange()
        let start = plainOffset(forDisplayOffset: sel.location)
        let end = sel.length == 0 ? start : plainOffset(forDisplayOffset: NSMaxRange(sel))
        return NSRange(location: start, length: max(0, end - start))
    }

    // MARK: - Programmatic Text Updates & Undo/Redo

    func applyProgrammaticText(_ newText: String, caretUTF16: Int?, recordUndo: Bool) {
        let hadMarked = hasMarkedText()
        let current = hadMarked ? lastCommittedSnapshot.text : plainText()
        let currentCaret = hadMarked ? lastCommittedSnapshot.caretUTF16 : selectedPlainRange().location
        if hadMarked {
            discardActiveComposition()
        }
        if recordUndo && current != newText {
            pushUndoIfNeeded(previousText: current, previousCaret: currentCaret, force: true)
        }
        let targetCaret = caretUTF16 ?? (newText as NSString).length
        let clampedCaret = max(0, min(targetCaret, (newText as NSString).length))
        activeTypingRange = nil
        if newText.isEmpty {
            plainLinkURLs.removeAll()
        }
        mutateController { $0.clearPastedLinkToast() }
        clearHover()

        isSyncingStorage = true
        if let storage = textStorage {
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: newText)
            storage.endEditing()
        }
        let rawDisplayPos = min(clampedCaret, textStorage?.length ?? 0)
        setSelectedRange(NSRange(location: rawDisplayPos, length: 0))
        isSyncingStorage = false

        syncChipsAndMarkdown(overridePlainCaret: clampedCaret)
        lastCommittedSnapshot = UndoSnapshot(text: newText, caretUTF16: clampedCaret)
        lastSyncedExternalText = newText
        let reportedCaret: Int? = selectedPlainRange().length == 0 ? clampedCaret : nil
        mutateController { ctrl in
            if ctrl.caretUTF16 != reportedCaret {
                ctrl.caretUTF16 = reportedCaret
            }
        }
        scrollRangeToVisible(selectedRange())
        reportMeasuredHeight()
        needsDisplay = true
    }

    private func mutateController(_ work: @escaping @MainActor (ComposerEditorController) -> Void) {
        guard let ctrl = controller else { return }
        if isUpdatingFromSwiftUI {
            DispatchQueue.main.async { [weak ctrl] in
                guard let ctrl else { return }
                work(ctrl)
            }
        } else {
            work(ctrl)
        }
    }

    func insertUserPlainText(_ inserted: String) {
        guard !inserted.isEmpty else { return }
        if hasMarkedText() {
            discardActiveComposition()
        }
        let current = plainText()
        let sel = selectedPlainRange()
        pushUndoIfNeeded(previousText: current, previousCaret: sel.location, force: true)

        let ns = current as NSString
        let safeLoc = max(0, min(sel.location, ns.length))
        let safeEnd = max(safeLoc, min(NSMaxRange(sel), ns.length))
        let before = ns.substring(to: safeLoc)
        let after = ns.substring(from: safeEnd)
        let next = before + inserted + after
        let nextCaret = safeLoc + (inserted as NSString).length

        // Check if the inserted string is a single standalone URL for "Pasted as link" toast.
        let trimmed = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        let links = ComposerChipsParser.findLinks(in: inserted)
        let singlePastedLink: ComposerChip? = (links.count == 1 && links[0].fromUTF16 == 0 && links[0].toUTF16 == (inserted as NSString).length && !trimmed.isEmpty)
            ? links[0]
            : nil

        applyProgrammaticText(next, caretUTF16: nextCaret, recordUndo: false)
        callbacks.onTextChange(next, nextCaret)

        if let link = singlePastedLink, case .link(_, _, let url, _, _, _, _) = link {
            let from = safeLoc
            let to = safeLoc + (inserted as NSString).length
            let x = xOffset(forPlainUTF16: from) ?? 12
            controller?.showPastedLinkToast(ComposerPastedLinkToast(
                fromUTF16: from,
                toUTF16: to,
                url: url,
                anchorX: x
            ))
        }
    }

    func markLinkPlain(url: String) {
        guard !url.isEmpty else { return }
        plainLinkURLs.insert(url)
        let sel = selectedPlainRange()
        syncChipsAndMarkdown(overridePlainCaret: sel.location)
    }

    private func pushUndoIfNeeded(previousText: String, previousCaret: Int, force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let snap = UndoSnapshot(text: previousText, caretUTF16: previousCaret)
        if !force && (now - lastUndoPushTime) < 0.65 && undoStack.last != nil {
            return
        }
        if undoStack.last != snap {
            undoStack.append(snap)
            if undoStack.count > 100 {
                undoStack.removeFirst()
            }
        }
        redoStack.removeAll()
        lastUndoPushTime = now
    }

    func performPlainUndo() {
        guard let prev = undoStack.popLast() else { return }
        let current = UndoSnapshot(text: plainText(), caretUTF16: selectedPlainRange().location)
        redoStack.append(current)
        applyProgrammaticText(prev.text, caretUTF16: prev.caretUTF16, recordUndo: false)
        callbacks.onTextChange(prev.text, prev.caretUTF16)
    }

    func performPlainRedo() {
        guard let next = redoStack.popLast() else { return }
        let current = UndoSnapshot(text: plainText(), caretUTF16: selectedPlainRange().location)
        undoStack.append(current)
        applyProgrammaticText(next.text, caretUTF16: next.caretUTF16, recordUndo: false)
        callbacks.onTextChange(next.text, next.caretUTF16)
    }

    // MARK: - Key Events, Paste & Copy

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if !config.isDisabled {
            // Cmd+Z / Cmd+Shift+Z / Cmd+Y plain-text undo & redo
            if flags == .command && key == "z" {
                performPlainUndo()
                return true
            }
            if (flags == [.command, .shift] && key == "z") || (flags == .command && key == "y") {
                performPlainRedo()
                return true
            }

            // Cmd+Shift+V: restore recently pasted link as plain text, or paste plain text.
            if flags == [.command, .shift] && key == "v" {
                if let toast = controller?.pastedLinkToast {
                    controller?.keepLinkAsText(url: toast.url)
                    return true
                }
                if let plain = NSPasteboard.general.string(forType: .string), !plain.isEmpty {
                    insertUserPlainText(plain)
                    return true
                }
                return true
            }

            // Cmd+V: route through smart paste handler (files, long text > 10k chars, images, single URL).
            if flags == .command && key == "v" {
                if callbacks.onPaste() {
                    return true
                }
                if let plain = NSPasteboard.general.string(forType: .string), !plain.isEmpty {
                    insertUserPlainText(plain)
                    return true
                }
                return true
            }
        }

        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
        guard !config.isDisabled else { return }
        if callbacks.onPaste() {
            return
        }
        if let plain = NSPasteboard.general.string(forType: .string), !plain.isEmpty {
            insertUserPlainText(plain)
        }
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let sel = selectedRange()
        guard sel.length > 0, let storage = textStorage else {
            return super.writeSelection(to: pboard, types: types)
        }
        var out = ""
        let ns = storage.string as NSString
        storage.enumerateAttribute(.attachment, in: sel) { value, range, _ in
            if let chipAtt = value as? ComposerChipAttachment {
                out.append(chipAtt.rawToken)
            } else {
                out.append(ns.substring(with: range))
            }
        }
        pboard.clearContents()
        pboard.setString(out, forType: .string)
        return true
    }

    override func keyDown(with event: NSEvent) {
        // Never intercept while IME composition is active or keyCode 229.
        if event.keyCode == 229 || hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        if callbacks.onKeyDown(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func deleteBackward(_ sender: Any?) {
        let hadMarked = hasMarkedText()
        let delRange = hadMarked ? NSRange(location: 0, length: 0) : deletionRangeForBackward()
        let deletedAttachmentIDs = hadMarked ? [] : attachmentIDs(inDisplayRange: delRange)
        let deletedSessionIDs = hadMarked ? [] : sessionIDs(inDisplayRange: delRange)
        if !hadMarked {
            let beforePlain = plainText()
            let beforeSel = selectedPlainRange()
            pushUndoIfNeeded(previousText: beforePlain, previousCaret: beforeSel.location, force: !deletedAttachmentIDs.isEmpty || !deletedSessionIDs.isEmpty)
        }
        isHandlingDirectEdit = true
        super.deleteBackward(sender)
        isHandlingDirectEdit = false
        if hadMarked && !hasMarkedText() {
            mutateController { ctrl in
                if ctrl.isComposing {
                    ctrl.isComposing = false
                }
            }
        }
        if !hasMarkedText() {
            let text = plainText()
            if hadMarked && text == lastCommittedSnapshot.text {
                reportMeasuredHeight()
                needsDisplay = true
                return
            }
            let sel = selectedPlainRange()
            if activeTypingRange != nil {
                activeTypingRange = sel.length == 0 ? ComposerChipsParser.typingRange(in: text, caretUTF16: sel.location) : nil
            }
            handlePostEdit(isUserDelete: !hadMarked, candidateDeletedIDs: deletedAttachmentIDs, candidateDeletedSessionIDs: deletedSessionIDs)
        }
    }

    override func deleteForward(_ sender: Any?) {
        let hadMarked = hasMarkedText()
        let delRange = hadMarked ? NSRange(location: 0, length: 0) : deletionRangeForForward()
        let deletedAttachmentIDs = hadMarked ? [] : attachmentIDs(inDisplayRange: delRange)
        let deletedSessionIDs = hadMarked ? [] : sessionIDs(inDisplayRange: delRange)
        if !hadMarked {
            let beforePlain = plainText()
            let beforeSel = selectedPlainRange()
            pushUndoIfNeeded(previousText: beforePlain, previousCaret: beforeSel.location, force: !deletedAttachmentIDs.isEmpty || !deletedSessionIDs.isEmpty)
        }
        isHandlingDirectEdit = true
        super.deleteForward(sender)
        isHandlingDirectEdit = false
        if hadMarked && !hasMarkedText() {
            mutateController { ctrl in
                if ctrl.isComposing {
                    ctrl.isComposing = false
                }
            }
        }
        if !hasMarkedText() {
            let text = plainText()
            if hadMarked && text == lastCommittedSnapshot.text {
                reportMeasuredHeight()
                needsDisplay = true
                return
            }
            handlePostEdit(isUserDelete: !hadMarked, candidateDeletedIDs: deletedAttachmentIDs, candidateDeletedSessionIDs: deletedSessionIDs)
        }
    }

    override func cut(_ sender: Any?) {
        let hadMarked = hasMarkedText()
        let delRange = hadMarked ? NSRange(location: 0, length: 0) : selectedRange()
        let deletedAttachmentIDs = hadMarked ? [] : attachmentIDs(inDisplayRange: delRange)
        let deletedSessionIDs = hadMarked ? [] : sessionIDs(inDisplayRange: delRange)
        if !hadMarked {
            let beforePlain = plainText()
            let beforeSel = selectedPlainRange()
            pushUndoIfNeeded(previousText: beforePlain, previousCaret: beforeSel.location, force: true)
        }
        isHandlingDirectEdit = true
        super.cut(sender)
        isHandlingDirectEdit = false
        if hadMarked && !hasMarkedText() {
            mutateController { ctrl in
                if ctrl.isComposing {
                    ctrl.isComposing = false
                }
            }
        }
        if !hasMarkedText() {
            handlePostEdit(isUserDelete: true, candidateDeletedIDs: deletedAttachmentIDs, candidateDeletedSessionIDs: deletedSessionIDs)
        }
    }

    private func deletionRangeForBackward() -> NSRange {
        let sel = selectedRange()
        if sel.length > 0 { return sel }
        guard sel.location > 0 else { return NSRange(location: 0, length: 0) }
        return NSRange(location: sel.location - 1, length: 1)
    }

    private func deletionRangeForForward() -> NSRange {
        let sel = selectedRange()
        if sel.length > 0 { return sel }
        let len = textStorage?.length ?? 0
        guard sel.location < len else { return NSRange(location: len, length: 0) }
        return NSRange(location: sel.location, length: 1)
    }

    private func attachmentIDs(inDisplayRange range: NSRange) -> Set<UUID> {
        guard range.length > 0, let storage = textStorage, NSMaxRange(range) <= storage.length else { return [] }
        var ids = Set<UUID>()
        storage.enumerateAttribute(.attachment, in: range) { value, _, _ in
            if let chipAtt = value as? ComposerChipAttachment,
               let key = chipAtt.chip.attachmentKey,
               let uuid = UUID(uuidString: key) {
                ids.insert(uuid)
            }
        }
        return ids
    }

    private func sessionIDs(inDisplayRange range: NSRange) -> Set<String> {
        guard range.length > 0, let storage = textStorage, NSMaxRange(range) <= storage.length else { return [] }
        var ids = Set<String>()
        storage.enumerateAttribute(.attachment, in: range) { value, _, _ in
            if let chipAtt = value as? ComposerChipAttachment,
               let sid = chipAtt.chip.sessionID {
                ids.insert(sid)
            }
        }
        return ids
    }

    override func didChangeText() {
        super.didChangeText()
        guard !isSyncingStorage, !isHandlingDirectEdit, !hasMarkedText() else { return }
        let beforeMentionIDs = controller?.mentionedAttachmentIDs ?? []
        let beforeSessionIDs = controller?.referencedSessionIDs ?? []
        pushUndoIfNeeded(
            previousText: lastCommittedSnapshot.text,
            previousCaret: lastCommittedSnapshot.caretUTF16,
            force: false
        )
        handlePostEdit(
            isUserDelete: !beforeMentionIDs.isEmpty || !beforeSessionIDs.isEmpty,
            candidateDeletedIDs: beforeMentionIDs,
            candidateDeletedSessionIDs: beforeSessionIDs
        )
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        guard !isSyncingStorage, !hasMarkedText() else { return }
        let sel = selectedPlainRange()
        if let typing = activeTypingRange {
            if sel.length > 0 || sel.location < typing.lowerBound || sel.location > typing.upperBound {
                activeTypingRange = nil
                syncChipsAndMarkdown(overridePlainCaret: nil)
            }
        } else if !stillSelectingFlag, let storage = textStorage,
                  ComposerMarkdownStyler.hasSelectionDependentSyntax(in: storage.string) {
            restyleMarkdownOnly()
        }
        let caret: Int? = sel.length == 0 ? sel.location : nil
        mutateController { ctrl in
            if ctrl.caretUTF16 != caret {
                ctrl.caretUTF16 = caret
            }
        }
        callbacks.onCaretChange(caret)
    }

    private func handlePostEdit(
        isUserDelete: Bool,
        candidateDeletedIDs: Set<UUID> = [],
        candidateDeletedSessionIDs: Set<String> = []
    ) {
        controller?.clearPastedLinkToast()
        clearHover()
        let text = plainText()
        if text.isEmpty {
            plainLinkURLs.removeAll()
        }
        let sel = selectedPlainRange()
        let caret: Int? = sel.length == 0 ? sel.location : nil

        syncChipsAndMarkdown(overridePlainCaret: nil)

        if isUserDelete && !candidateDeletedIDs.isEmpty {
            let stillReferenced = controller?.mentionedAttachmentIDs ?? []
            let gone = candidateDeletedIDs.subtracting(stillReferenced)
            if !gone.isEmpty {
                callbacks.onMentionDeleted(Array(gone))
            }
        }

        if isUserDelete && !candidateDeletedSessionIDs.isEmpty {
            let stillReferencedSessions = controller?.referencedSessionIDs ?? []
            let goneSessions = candidateDeletedSessionIDs.subtracting(stillReferencedSessions)
            if !goneSessions.isEmpty {
                callbacks.onSessionRefDeleted(Array(goneSessions))
            }
        }

        lastCommittedSnapshot = UndoSnapshot(text: text, caretUTF16: sel.location)
        lastSyncedExternalText = text
        controller?.caretUTF16 = caret
        callbacks.onTextChange(text, caret)
        reportMeasuredHeight()
        needsDisplay = true
    }

    // MARK: - Chip Materialization & Live Markdown Sync

    func syncChipsAndMarkdown(overridePlainCaret: Int? = nil, forceRebuild: Bool = false) {
        guard !isSyncingStorage, !hasMarkedText(), let storage = textStorage else { return }

        let currentPlain = plainText()
        let currentSel = selectedPlainRange()
        let plainSelStart = overridePlainCaret ?? currentSel.location
        let plainSelEnd = overridePlainCaret ?? NSMaxRange(currentSel)

        let attachmentsByToken = buildAttachmentLookup()
        let chips = ComposerChipsParser.findChips(
            in: currentPlain,
            commands: config.commandNames,
            sessionReferences: config.sessionReferences,
            missingSessionIDs: config.missingSessionIDs,
            resolveMention: { token in
                self.resolveMention(token, attachmentsByToken: attachmentsByToken)
            }
        )

        // Track every draft attachment & session reference represented by inline chips.
        var mentionedIDs = Set<UUID>()
        var referencedSessionIDs = Set<String>()
        for chip in chips {
            if let key = chip.attachmentKey, let uuid = UUID(uuidString: key) {
                mentionedIDs.insert(uuid)
            }
            if let sid = chip.sessionID {
                referencedSessionIDs.insert(sid)
            }
        }
        mutateController { ctrl in
            if ctrl.mentionedAttachmentIDs != mentionedIDs {
                ctrl.mentionedAttachmentIDs = mentionedIDs
            }
            if ctrl.referencedSessionIDs != referencedSessionIDs {
                ctrl.referencedSessionIDs = referencedSessionIDs
            }
        }

        // Build desired attachment list (excluding commands, actively-typed token, and plain-kept links).
        let widgetChips: [ComposerChip] = chips.filter { chip in
            if case .command = chip { return false }
            if let typing = activeTypingRange,
               typing.lowerBound <= chip.toUTF16 && typing.upperBound >= chip.fromUTF16 {
                return false
            }
            if case .link(_, _, let url, _, _, _, _) = chip, plainLinkURLs.contains(url) {
                return false
            }
            return true
        }

        // Check if current storage already has the exact same chip replacements.
        let shouldForceRebuild = forceRebuild || pendingAppearanceRebuild
        pendingAppearanceRebuild = false
        let needsStructuralRebuild = shouldForceRebuild
            || !storageMatches(plainText: currentPlain, widgetChips: widgetChips, plainSelStart: plainSelStart, plainSelEnd: plainSelEnd)

        isSyncingStorage = true
        defer { isSyncingStorage = false }

        if shouldForceRebuild {
            self.font = resolvedBaseFont()
            self.textColor = NSColor(config.tokens.foreground)
        }

        if needsStructuralRebuild {
            let built = NSMutableAttributedString()
            let baseFont = resolvedBaseFont()
            let baseAttrs: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: NSColor(config.tokens.foreground),
            ]
            let ns = currentPlain as NSString
            var cursor = 0
            var mappedStart = 0
            var mappedEnd = 0
            var startMapped = false
            var endMapped = false

            func mapBoundary(_ plainPos: Int, segmentPlainStart: Int, segmentPlainEnd: Int, segmentDisplayStart: Int, segmentDisplayLen: Int, isChip: Bool) -> Int? {
                if plainPos < segmentPlainStart || plainPos > segmentPlainEnd { return nil }
                if isChip {
                    return plainPos == segmentPlainStart ? segmentDisplayStart : segmentDisplayStart + segmentDisplayLen
                }
                return segmentDisplayStart + (plainPos - segmentPlainStart)
            }

            for chip in widgetChips {
                if chip.fromUTF16 > cursor {
                    let segRange = NSRange(location: cursor, length: chip.fromUTF16 - cursor)
                    let segStartDisplay = built.length
                    built.append(NSAttributedString(string: ns.substring(with: segRange), attributes: baseAttrs))
                    if !startMapped, let m = mapBoundary(plainSelStart, segmentPlainStart: cursor, segmentPlainEnd: chip.fromUTF16, segmentDisplayStart: segStartDisplay, segmentDisplayLen: segRange.length, isChip: false) {
                        mappedStart = m
                        startMapped = true
                    }
                    if !endMapped, let m = mapBoundary(plainSelEnd, segmentPlainStart: cursor, segmentPlainEnd: chip.fromUTF16, segmentDisplayStart: segStartDisplay, segmentDisplayLen: segRange.length, isChip: false) {
                        mappedEnd = m
                        endMapped = true
                    }
                }
                let chipDisplayStart = built.length
                let isSelected = plainSelStart < plainSelEnd && plainSelStart <= chip.fromUTF16 && plainSelEnd >= chip.toUTF16
                let thumb = thumbnailNSImage(for: chip)
                let rendered = ComposerChipRenderer.render(
                    chip: chip,
                    selected: isSelected,
                    tokens: config.tokens,
                    fontSize: config.fontSize,
                    thumbImage: thumb
                )
                let attachment = ComposerChipAttachment(
                    chip: chip,
                    rawToken: chip.rawText,
                    isSelected: isSelected,
                    hasThumbnail: thumb != nil,
                    image: rendered.image,
                    baselineOffset: rendered.baselineOffset
                )
                built.append(NSAttributedString(attachment: attachment))
                if !startMapped, let m = mapBoundary(plainSelStart, segmentPlainStart: chip.fromUTF16, segmentPlainEnd: chip.toUTF16, segmentDisplayStart: chipDisplayStart, segmentDisplayLen: 1, isChip: true) {
                    mappedStart = m
                    startMapped = true
                }
                if !endMapped, let m = mapBoundary(plainSelEnd, segmentPlainStart: chip.fromUTF16, segmentPlainEnd: chip.toUTF16, segmentDisplayStart: chipDisplayStart, segmentDisplayLen: 1, isChip: true) {
                    mappedEnd = m
                    endMapped = true
                }
                cursor = chip.toUTF16
            }

            if cursor < ns.length {
                let segRange = NSRange(location: cursor, length: ns.length - cursor)
                let segStartDisplay = built.length
                built.append(NSAttributedString(string: ns.substring(with: segRange), attributes: baseAttrs))
                if !startMapped, let m = mapBoundary(plainSelStart, segmentPlainStart: cursor, segmentPlainEnd: ns.length, segmentDisplayStart: segStartDisplay, segmentDisplayLen: segRange.length, isChip: false) {
                    mappedStart = m
                    startMapped = true
                }
                if !endMapped, let m = mapBoundary(plainSelEnd, segmentPlainStart: cursor, segmentPlainEnd: ns.length, segmentDisplayStart: segStartDisplay, segmentDisplayLen: segRange.length, isChip: false) {
                    mappedEnd = m
                    endMapped = true
                }
            }

            if !startMapped { mappedStart = built.length }
            if !endMapped { mappedEnd = built.length }

            storage.beginEditing()
            storage.setAttributedString(built)
            ComposerMarkdownStyler.apply(
                to: storage,
                tokens: config.tokens,
                baseFont: resolvedBaseFont(),
                codeFont: resolvedCodeFont(),
                commandNames: config.commandNames,
                selection: NSRange(location: mappedStart, length: max(0, mappedEnd - mappedStart)),
                isFocused: window?.firstResponder === self
            )
            storage.endEditing()

            let finalRange = NSRange(
                location: max(0, min(mappedStart, storage.length)),
                length: max(0, min(mappedEnd - mappedStart, storage.length - max(0, min(mappedStart, storage.length))))
            )
            setSelectedRange(finalRange)
        } else {
            restyleMarkdownOnly()
        }

        insertionPointColor = NSColor(config.tokens.primary)
        typingAttributes = [
            .font: resolvedBaseFont(),
            .foregroundColor: NSColor(config.tokens.foreground),
        ]
        reportMeasuredHeight()
    }

    private func restyleMarkdownOnly() {
        guard !hasMarkedText(), let storage = textStorage else { return }
        let wasSyncing = isSyncingStorage
        isSyncingStorage = true
        defer { isSyncingStorage = wasSyncing }
        storage.beginEditing()
        ComposerMarkdownStyler.apply(
            to: storage,
            tokens: config.tokens,
            baseFont: resolvedBaseFont(),
            codeFont: resolvedCodeFont(),
            commandNames: config.commandNames,
            selection: selectedRange(),
            isFocused: window?.firstResponder === self
        )
        storage.endEditing()
    }

    private func storageMatches(
        plainText: String,
        widgetChips: [ComposerChip],
        plainSelStart: Int,
        plainSelEnd: Int
    ) -> Bool {
        guard let storage = textStorage else { return false }
        var existing: [(attachment: ComposerChipAttachment, plainStart: Int)] = []
        var plainCursor = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let att = value as? ComposerChipAttachment {
                existing.append((att, plainCursor))
                plainCursor += (att.rawToken as NSString).length
            } else {
                plainCursor += range.length
            }
        }
        guard plainCursor == (plainText as NSString).length,
              existing.count == widgetChips.count
        else { return false }

        for (idx, chip) in widgetChips.enumerated() {
            let wantSelected = plainSelStart < plainSelEnd && plainSelStart <= chip.fromUTF16 && plainSelEnd >= chip.toUTF16
            let wantThumb = thumbnailNSImage(for: chip) != nil
            let entry = existing[idx]
            if entry.plainStart != chip.fromUTF16
                || (entry.attachment.rawToken as NSString).length != (chip.toUTF16 - chip.fromUTF16)
                || !entry.attachment.chip.hasSameVisualContent(as: chip)
                || entry.attachment.isSelected != wantSelected
                || entry.attachment.hasThumbnail != wantThumb {
                return false
            }
        }
        // Update shifted UTF-16 offsets in-place so typing before an existing chip avoids rebuilding NSTextStorage.
        for (idx, chip) in widgetChips.enumerated() {
            existing[idx].attachment.chip = chip
        }
        return true
    }

    private func buildAttachmentLookup() -> [String: DraftAttachmentItem] {
        var map: [String: DraftAttachmentItem] = [:]
        for item in config.attachments where item.kind != .text {
            if map[item.mentionTokenName] == nil {
                map[item.mentionTokenName] = item
            }
            if map[item.name] == nil {
                map[item.name] = item
            }
            if let rel = item.projectRelativePath, map[rel] == nil {
                map[rel] = item
                if item.kind == .folder && !rel.hasSuffix("/") {
                    map["\(rel)/"] = item
                }
            }
        }
        return map
    }

    private func resolveMention(
        _ token: String,
        attachmentsByToken: [String: DraftAttachmentItem]
    ) -> ComposerResolvedMention? {
        guard let item = attachmentsByToken[token] else { return nil }
        let kind: ComposerMentionKind
        switch item.kind {
        case .folder: kind = .folder
        case .image: kind = .image
        default: kind = .file
        }
        return ComposerResolvedMention(
            kind: kind,
            path: item.projectRelativePath,
            attachmentKey: item.id.uuidString,
            missing: item.failureMessage != nil
        )
    }

    private func thumbnailNSImage(for chip: ComposerChip) -> NSImage? {
        guard case .mention(_, _, .image, _, _, _, _, let key?, _) = chip,
              let uuid = UUID(uuidString: key),
              let item = config.attachments.first(where: { $0.id == uuid }),
              let data = item.thumbnailData
        else { return nil }
        return NSImage(data: data)
    }

    // MARK: - Geometry: Visual Line Boundaries, X Offset & Dynamic Height

    func atVisualBoundary(forward: Bool) -> Bool {
        let sel = selectedRange()
        guard sel.length == 0 else { return false }
        guard let lm = layoutManager, let storage = textStorage else { return true }
        let len = storage.length
        if len == 0 { return true }

        lm.ensureLayout(for: textContainer!)
        let glyphCount = lm.numberOfGlyphs
        if glyphCount == 0 { return true }

        let endsWithNewline = (storage.string as NSString).character(at: len - 1) == 0x0A
        if !forward {
            // ArrowUp: if caret is at the very end after a trailing newline, we are on an extra empty line below line 0.
            if sel.location == len && endsWithNewline {
                return false
            }
            let glyphIdx = min(lm.glyphIndexForCharacter(at: min(sel.location, len - 1)), glyphCount - 1)
            var lineRange = NSRange(location: 0, length: 0)
            _ = lm.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: &lineRange)
            return lineRange.location == 0
        } else {
            // ArrowDown: caret at end of doc is always on the last visual line.
            if sel.location >= len { return true }
            if endsWithNewline { return false }
            let glyphIdx = min(lm.glyphIndexForCharacter(at: sel.location), glyphCount - 1)
            var lineRange = NSRange(location: 0, length: 0)
            _ = lm.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: &lineRange)
            return NSMaxRange(lineRange) >= glyphCount
        }
    }

    func xOffset(forPlainUTF16 pos: Int) -> CGFloat? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return nil }
        lm.ensureLayout(for: tc)
        let displayPos = displayOffset(forPlainOffset: pos)
        if storage.length == 0 {
            return textContainerInset.width + tc.lineFragmentPadding
        }
        let clamped = min(displayPos, max(0, storage.length - 1))
        let glyphIdx = lm.glyphIndexForCharacter(at: clamped)
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 1), in: tc)
        let origin = textContainerOrigin
        return origin.x + rect.minX
    }

    func usedContentHeight() -> CGFloat {
        guard let lm = layoutManager, let tc = textContainer else { return 34 }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let lineH = max(20, ceil(resolvedBaseFont().ascender - resolvedBaseFont().descender + resolvedBaseFont().leading))
        return ceil(max(lineH, used.height) + textContainerInset.height * 2)
    }

    func reportMeasuredHeight() {
        let target = usedContentHeight()
        if let controller, abs(controller.measuredContentHeight - target) > 0.5 {
            DispatchQueue.main.async { [weak controller] in
                guard let controller, abs(controller.measuredContentHeight - target) > 0.5 else { return }
                controller.measuredContentHeight = target
            }
        }
    }

    // MARK: - Chip Click & Delayed Hover Preview

    private func chipHit(at windowPoint: NSPoint) -> (chip: ComposerChip, charIndex: Int, rectInView: NSRect)? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else {
            return nil
        }
        let local = convert(windowPoint, from: nil)
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: local.x - origin.x, y: local.y - origin.y)
        var fraction: CGFloat = 0
        let glyphIdx = lm.glyphIndex(for: containerPoint, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        guard glyphIdx < lm.numberOfGlyphs else { return nil }
        let charIdx = lm.characterIndexForGlyph(at: glyphIdx)
        guard charIdx < storage.length,
              let att = storage.attribute(.attachment, at: charIdx, effectiveRange: nil) as? ComposerChipAttachment
        else { return nil }

        let glyphRect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 1), in: tc)
        let viewRect = NSRect(
            x: glyphRect.origin.x + origin.x,
            y: glyphRect.origin.y + origin.y,
            width: glyphRect.width,
            height: glyphRect.height
        )
        guard viewRect.insetBy(dx: -2, dy: -2).contains(local) else { return nil }
        return (att.chip, charIdx, viewRect)
    }

    override func mouseDown(with event: NSEvent) {
        if let hit = chipHit(at: event.locationInWindow) {
            clearHover()
            callbacks.onChipClick(hit.chip)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let hit = chipHit(at: event.locationInWindow) else {
            if hoveredCharIndex != nil {
                clearHover()
                NSCursor.iBeam.set()
            }
            return
        }
        NSCursor.pointingHand.set()
        if hoveredCharIndex == hit.charIndex { return }
        hoveredCharIndex = hit.charIndex
        hoverTask?.cancel()

        let alreadyShowing = controller?.hoveredChip != nil
        let chip = hit.chip
        let charIndex = hit.charIndex
        let anchorX = hit.rectInView.minX
        let anchorY = hit.rectInView.minY
        if alreadyShowing {
            controller?.hoveredChip = ComposerHoveredChip(chip: chip, anchorX: anchorX, anchorY: anchorY)
        } else {
            hoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self, self.hoveredCharIndex == charIndex else { return }
                self.controller?.hoveredChip = ComposerHoveredChip(chip: chip, anchorX: anchorX, anchorY: anchorY)
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHover()
    }

    private func clearHover() {
        hoverTask?.cancel()
        hoverTask = nil
        hoveredCharIndex = nil
        mutateController { ctrl in
            if ctrl.hoveredChip != nil {
                ctrl.hoveredChip = nil
            }
        }
    }

    // MARK: - Config Refresh

    func updateConfig(_ next: Config, text: String) {
        isUpdatingFromSwiftUI = true
        defer { isUpdatingFromSwiftUI = false }

        let scopeChanged = config.scope != next.scope
        let appearanceChanged =
            config.tokens.palette != next.tokens.palette
            || config.fontSize != next.fontSize
            || config.proseFontFamily != next.proseFontFamily
            || config.codeFontFamily != next.codeFontFamily
        let visualChanged =
            scopeChanged
            || appearanceChanged
            || config.commandNames != next.commandNames
            || config.attachments != next.attachments
            || config.sessionReferences != next.sessionReferences
            || config.missingSessionIDs != next.missingSessionIDs
        let placeholderChanged = config.placeholder != next.placeholder
        let disabledChanged = config.isDisabled != next.isDisabled
        config = next

        if scopeChanged {
            undoStack.removeAll()
            redoStack.removeAll()
            plainLinkURLs.removeAll()
            activeTypingRange = nil
            pendingAppearanceRebuild = false
            clearHover()
            mutateController { $0.clearPastedLinkToast() }
        }

        if disabledChanged {
            isEditable = !next.isDisabled
        }

        let externalTextChanged = text != lastSyncedExternalText

        if hasMarkedText() {
            if scopeChanged || (externalTextChanged && text != committedPlainText()) {
                discardActiveComposition()
            } else {
                if appearanceChanged {
                    pendingAppearanceRebuild = true
                }
                if placeholderChanged || visualChanged {
                    needsDisplay = true
                }
                return
            }
        }

        if scopeChanged || plainText() != text {
            applyProgrammaticText(text, caretUTF16: nil, recordUndo: false)
        } else {
            lastSyncedExternalText = text
            if visualChanged || pendingAppearanceRebuild {
                syncChipsAndMarkdown(forceRebuild: appearanceChanged || pendingAppearanceRebuild)
            }
        }

        if placeholderChanged || visualChanged {
            needsDisplay = true
        }
    }
}

private final class ComposerScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let tv = documentView as? ComposerNSTextView else { return }
        let width = contentSize.width
        let height = contentSize.height
        if height > 0 && abs(tv.minSize.height - height) > 0.5 {
            tv.minSize = NSSize(width: 0, height: height)
        }
        if width > 20 && abs(tv.frame.width - width) > 0.5 {
            tv.setFrameSize(NSSize(width: width, height: max(tv.frame.height, height)))
            tv.reportMeasuredHeight()
        } else if height > 0 {
            let targetHeight = max(tv.usedContentHeight(), height)
            if abs(tv.frame.height - targetHeight) > 0.5 {
                tv.setFrameSize(NSSize(width: tv.frame.width, height: targetHeight))
            }
        }
    }
}

// MARK: - SwiftUI NSViewRepresentable Wrapper

struct ComposerTextEditor: NSViewRepresentable {
    let scope: String
    let controller: ComposerEditorController
    let text: String
    let placeholder: String
    let isDisabled: Bool
    let tokens: PrismTokens
    let typography: PrismTypographyPrefs
    let commandNames: [String]
    let attachments: [DraftAttachmentItem]
    let sessionReferences: [DraftSessionReference]
    let missingSessionIDs: Set<String>
    let isMentionPopoverOpen: () -> Bool
    let onTextChange: (String, Int?) -> Void
    let onCaretChange: (Int?) -> Void
    let onKeyDown: (NSEvent) -> Bool
    let onPaste: () -> Bool
    let onChipClick: (ComposerChip) -> Void
    let onMentionDeleted: ([UUID]) -> Void
    let onSessionRefDeleted: ([String]) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ComposerScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let cfg = makeConfig()
        let cbs = makeCallbacks()
        let textView = ComposerNSTextView(config: cfg, callbacks: cbs)
        textView.frame = NSRect(x: 0, y: 0, width: max(200, scrollView.contentSize.width), height: max(28, scrollView.contentSize.height))
        textView.controller = controller
        controller.textView = textView
        scrollView.documentView = textView

        if !text.isEmpty {
            textView.applyProgrammaticText(text, caretUTF16: nil, recordUndo: false)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        let contentWidth = scrollView.contentSize.width
        if contentWidth > 20 && abs(textView.frame.width - contentWidth) > 1 {
            textView.setFrameSize(NSSize(width: contentWidth, height: max(textView.frame.height, scrollView.contentSize.height)))
        }
        textView.controller = controller
        controller.textView = textView
        textView.callbacks = makeCallbacks()
        textView.updateConfig(makeConfig(), text: text)
    }

    private func makeConfig() -> ComposerNSTextView.Config {
        ComposerNSTextView.Config(
            scope: scope,
            tokens: tokens,
            fontSize: 14.5 + typography.textSizeDelta,
            proseFontFamily: typography.proseFontFamily,
            codeFontFamily: typography.codeFontFamily,
            placeholder: placeholder,
            isDisabled: isDisabled,
            commandNames: commandNames,
            attachments: attachments,
            sessionReferences: sessionReferences,
            missingSessionIDs: missingSessionIDs
        )
    }

    private func makeCallbacks() -> ComposerNSTextView.Callbacks {
        ComposerNSTextView.Callbacks(
            onTextChange: onTextChange,
            onCaretChange: onCaretChange,
            onKeyDown: onKeyDown,
            onPaste: onPaste,
            onChipClick: onChipClick,
            onMentionDeleted: onMentionDeleted,
            onSessionRefDeleted: onSessionRefDeleted,
            isMentionPopoverOpen: isMentionPopoverOpen
        )
    }
}

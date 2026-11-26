import Foundation

// MARK: - Structured Line Diff Engine

public enum DiffLineKind: Sendable, Equatable {
    case context
    case added
    case deleted
}

public struct DiffLine: Sendable, Equatable, Identifiable {
    public let id: Int
    public let kind: DiffLineKind
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    public let text: String

    public init(
        id: Int,
        kind: DiffLineKind,
        oldLineNumber: Int?,
        newLineNumber: Int?,
        text: String
    ) {
        self.id = id
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.text = text
    }
}

public struct DiffHunk: Sendable, Equatable, Identifiable {
    public let id: Int
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let lines: [DiffLine]

    public init(id: Int, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [DiffLine]) {
        self.id = id
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }

    public var header: String {
        "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
    }
}

public struct ComputedDiff: Sendable, Equatable {
    public let hunks: [DiffHunk]
    public let insertions: Int
    public let deletions: Int

    public init(hunks: [DiffHunk] = [], insertions: Int = 0, deletions: Int = 0) {
        self.hunks = hunks
        self.insertions = insertions
        self.deletions = deletions
    }

    public var isEmpty: Bool {
        hunks.isEmpty
    }
}

/// Fast line-level Myers O(ND) diff engine producing context-grouped unified hunks from `(oldText, newText)`.
public enum UnifiedDiffEngine {
    /// Maximum Myers edit distance before falling back to a linear replace block on huge unrelated files.
    public static let maxEditDistance = 2048

    private enum EditSegment {
        case equal(oldIndex: Int, newIndex: Int, count: Int)
        case delete(oldIndex: Int, count: Int)
        case insert(newIndex: Int, count: Int)
    }

    public static func compute(
        oldText: String?,
        newText: String?,
        contextLines: Int = 3
    ) -> ComputedDiff {
        let oldLines = splitLines(oldText)
        let newLines = splitLines(newText)

        if oldLines == newLines {
            return ComputedDiff(hunks: [], insertions: 0, deletions: 0)
        }

        let segments = computeEditSegments(oldLines: oldLines, newLines: newLines)
        var insertions = 0
        var deletions = 0
        for seg in segments {
            switch seg {
            case .insert(_, let count): insertions += count
            case .delete(_, let count): deletions += count
            case .equal: break
            }
        }
        guard insertions > 0 || deletions > 0 else {
            return ComputedDiff(hunks: [], insertions: 0, deletions: 0)
        }

        let hunks = materializeHunks(
            segments: segments,
            oldLines: oldLines,
            newLines: newLines,
            context: max(0, contextLines)
        )
        return ComputedDiff(hunks: hunks, insertions: insertions, deletions: deletions)
    }

    /// Splits text on LF (`0x0A`) at the UTF-8 byte level (avoiding Swift's `\r\n` single-Character
    /// grapheme cluster trap where `Character("\r\n") != Character("\n")`), stripping a single trailing `\r`.
    static func splitLines(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        let utf8 = text.utf8
        var slices = utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if utf8.last == UInt8(ascii: "\n"), let tail = slices.last, tail.isEmpty {
            slices.removeLast()
        }
        var result: [String] = []
        result.reserveCapacity(slices.count)
        for slice in slices {
            let trimmedSlice: String.UTF8View.SubSequence
            if slice.last == UInt8(ascii: "\r") {
                trimmedSlice = slice.dropLast()
            } else {
                trimmedSlice = slice
            }
            result.append(String(decoding: trimmedSlice, as: UTF8.self))
        }
        return result
    }

    private static func computeEditSegments(oldLines: [String], newLines: [String]) -> [EditSegment] {
        var prefix = 0
        let minLen = min(oldLines.count, newLines.count)
        while prefix < minLen && oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < (minLen - prefix)
            && oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }

        let midOldEnd = oldLines.count - suffix
        let midNewEnd = newLines.count - suffix
        let n = midOldEnd - prefix
        let m = midNewEnd - prefix

        var segments: [EditSegment] = []
        if prefix > 0 {
            segments.append(.equal(oldIndex: 0, newIndex: 0, count: prefix))
        }

        if n == 0 && m > 0 {
            segments.append(.insert(newIndex: prefix, count: m))
        } else if m == 0 && n > 0 {
            segments.append(.delete(oldIndex: prefix, count: n))
        } else if n > 0 && m > 0 {
            segments.append(contentsOf: myersSegments(
                oldLines: oldLines,
                newLines: newLines,
                prefix: prefix,
                n: n,
                m: m
            ))
        }

        if suffix > 0 {
            segments.append(.equal(oldIndex: midOldEnd, newIndex: midNewEnd, count: suffix))
        }
        return segments
    }

    /// Myers' O(ND) shortest-edit-script algorithm over integer-interned line IDs using a flat `[Int]` frontier trace.
    private static func myersSegments(
        oldLines: [String],
        newLines: [String],
        prefix: Int,
        n: Int,
        m: Int
    ) -> [EditSegment] {
        let maxD = min(n + m, maxEditDistance)

        // Intern unique lines in the active middle region so inner snake loops compare Int == Int.
        var table: [String: Int] = [:]
        table.reserveCapacity(min(n + m, 8192))
        var nextLineID = 1

        var oldIDs = [Int](repeating: 0, count: n)
        for i in 0..<n {
            let line = oldLines[prefix + i]
            if let existing = table[line] {
                oldIDs[i] = existing
            } else {
                table[line] = nextLineID
                oldIDs[i] = nextLineID
                nextLineID += 1
            }
        }

        var newIDs = [Int](repeating: 0, count: m)
        for j in 0..<m {
            let line = newLines[prefix + j]
            if let existing = table[line] {
                newIDs[j] = existing
            } else {
                table[line] = nextLineID
                newIDs[j] = nextLineID
                nextLineID += 1
            }
        }

        let vOffset = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        // Flat triangular trace storing `v[k]` at the end of each step `d < foundD` (`d + 1` ints per row).
        var trace: [Int] = []
        trace.reserveCapacity(min((maxD + 1) * (maxD + 2) / 2, 16_384))

        var foundD: Int? = nil

        for d in 0...maxD {
            if d == 0 {
                var x = 0
                var y = 0
                while x < n && y < m && oldIDs[x] == newIDs[y] {
                    x += 1
                    y += 1
                }
                v[vOffset] = x
                if x >= n && y >= m {
                    foundD = 0
                    break
                }
                trace.append(x)
                continue
            }

            var reachedEnd = false
            for k in stride(from: -d, through: d, by: 2) {
                let down = (k == -d) || (k != d && v[vOffset + k - 1] < v[vOffset + k + 1])
                var x = down ? v[vOffset + k + 1] : (v[vOffset + k - 1] + 1)
                var y = x - k
                while x < n && y < m && oldIDs[x] == newIDs[y] {
                    x += 1
                    y += 1
                }
                v[vOffset + k] = x
                if x >= n && y >= m {
                    foundD = d
                    reachedEnd = true
                    break
                }
            }
            if reachedEnd {
                break
            }

            for k in stride(from: -d, through: d, by: 2) {
                trace.append(v[vOffset + k])
            }
        }

        guard let totalD = foundD else {
            return [
                .delete(oldIndex: prefix, count: n),
                .insert(newIndex: prefix, count: m),
            ]
        }

        var reversedOps: [EditSegment] = []
        reversedOps.reserveCapacity(totalD * 2 + 1)
        var x = n
        var y = m

        if totalD > 0 {
            for d in stride(from: totalD, through: 1, by: -1) {
                let k = x - y
                let prevD = d - 1
                let prevRowBase = (prevD * (prevD + 1)) >> 1
                func vPrev(_ diag: Int) -> Int {
                    trace[prevRowBase + ((diag + prevD) >> 1)]
                }

                let down = (k == -d) || (k != d && vPrev(k - 1) < vPrev(k + 1))
                let prevK = down ? (k + 1) : (k - 1)
                let prevX = vPrev(prevK)
                let prevY = prevX - prevK

                let midX = down ? prevX : (prevX + 1)
                let midY = down ? (prevY + 1) : prevY
                let snakeLen = x - midX
                if snakeLen > 0 {
                    reversedOps.append(.equal(oldIndex: prefix + midX, newIndex: prefix + midY, count: snakeLen))
                }
                if down {
                    reversedOps.append(.insert(newIndex: prefix + prevY, count: 1))
                } else {
                    reversedOps.append(.delete(oldIndex: prefix + prevX, count: 1))
                }
                x = prevX
                y = prevY
            }
        }

        if x > 0 {
            reversedOps.append(.equal(oldIndex: prefix, newIndex: prefix, count: x))
        }

        // Reverse and coalesce adjacent identical edit kinds into compact run segments.
        var coalesced: [EditSegment] = []
        coalesced.reserveCapacity(reversedOps.count)
        for op in reversedOps.reversed() {
            if let last = coalesced.last {
                switch (last, op) {
                case (.delete(let o1, let c1), .delete(let o2, let c2)) where o1 + c1 == o2:
                    coalesced[coalesced.count - 1] = .delete(oldIndex: o1, count: c1 + c2)
                    continue
                case (.insert(let n1, let c1), .insert(let n2, let c2)) where n1 + c1 == n2:
                    coalesced[coalesced.count - 1] = .insert(newIndex: n1, count: c1 + c2)
                    continue
                case (.equal(let o1, let n1, let c1), .equal(let o2, let n2, let c2))
                    where o1 + c1 == o2 && n1 + c1 == n2:
                    coalesced[coalesced.count - 1] = .equal(oldIndex: o1, newIndex: n1, count: c1 + c2)
                    continue
                default:
                    break
                }
            }
            coalesced.append(op)
        }
        return coalesced
    }

    /// Materializes ONLY the changed lines and up to `context` unchanged lines around each hunk,
    /// skipping massive unchanged regions in O(1) without allocating `DiffLine` values for them.
    private static func materializeHunks(
        segments: [EditSegment],
        oldLines: [String],
        newLines: [String],
        context: Int
    ) -> [DiffHunk] {
        guard let firstChangeIdx = segments.firstIndex(where: {
            if case .equal = $0 { return false }
            return true
        }),
        let lastChangeIdx = segments.lastIndex(where: {
            if case .equal = $0 { return false }
            return true
        }) else {
            return []
        }

        var hunks: [DiffHunk] = []
        var currentLines: [DiffLine] = []
        var hunkFallbackOldStart = 1
        var hunkFallbackNewStart = 1
        var nextLineID = 0

        func appendContextRange(oldStart: Int, newStart: Int, count: Int) {
            guard count > 0 else { return }
            if currentLines.isEmpty {
                hunkFallbackOldStart = oldStart + 1
                hunkFallbackNewStart = newStart + 1
            }
            for offset in 0..<count {
                let oIdx = oldStart + offset
                let nIdx = newStart + offset
                currentLines.append(DiffLine(
                    id: nextLineID,
                    kind: .context,
                    oldLineNumber: oIdx + 1,
                    newLineNumber: nIdx + 1,
                    text: oldLines[oIdx]
                ))
                nextLineID += 1
            }
        }

        func flushHunk() {
            guard !currentLines.isEmpty else { return }
            let oldCount = currentLines.reduce(0) { $0 + ($1.kind != .added ? 1 : 0) }
            let newCount = currentLines.reduce(0) { $0 + ($1.kind != .deleted ? 1 : 0) }
            let oldStart = currentLines.compactMap(\.oldLineNumber).first ?? hunkFallbackOldStart
            let newStart = currentLines.compactMap(\.newLineNumber).first ?? hunkFallbackNewStart
            hunks.append(DiffHunk(
                id: hunks.count,
                oldStart: oldStart,
                oldCount: oldCount,
                newStart: newStart,
                newCount: newCount,
                lines: currentLines
            ))
            currentLines = []
        }

        // Leading context immediately preceding `firstChangeIdx`.
        if firstChangeIdx > 0, case .equal(let oIdx, let nIdx, let count) = segments[firstChangeIdx - 1] {
            let take = min(context, count)
            let skip = count - take
            appendContextRange(oldStart: oIdx + skip, newStart: nIdx + skip, count: take)
        }

        for idx in firstChangeIdx...lastChangeIdx {
            switch segments[idx] {
            case .delete(let oldIdx, let count):
                if currentLines.isEmpty {
                    hunkFallbackOldStart = oldIdx + 1
                }
                for offset in 0..<count {
                    let lineIdx = oldIdx + offset
                    currentLines.append(DiffLine(
                        id: nextLineID,
                        kind: .deleted,
                        oldLineNumber: lineIdx + 1,
                        newLineNumber: nil,
                        text: oldLines[lineIdx]
                    ))
                    nextLineID += 1
                }

            case .insert(let newIdx, let count):
                if currentLines.isEmpty {
                    hunkFallbackNewStart = newIdx + 1
                }
                for offset in 0..<count {
                    let lineIdx = newIdx + offset
                    currentLines.append(DiffLine(
                        id: nextLineID,
                        kind: .added,
                        oldLineNumber: nil,
                        newLineNumber: lineIdx + 1,
                        text: newLines[lineIdx]
                    ))
                    nextLineID += 1
                }

            case .equal(let oldIdx, let newIdx, let count):
                if count <= 2 * context {
                    appendContextRange(oldStart: oldIdx, newStart: newIdx, count: count)
                } else {
                    appendContextRange(oldStart: oldIdx, newStart: newIdx, count: context)
                    flushHunk()
                    let tailSkip = count - context
                    appendContextRange(oldStart: oldIdx + tailSkip, newStart: newIdx + tailSkip, count: context)
                }
            }
        }

        // Trailing context immediately following `lastChangeIdx`.
        if lastChangeIdx + 1 < segments.count,
           case .equal(let oIdx, let nIdx, let count) = segments[lastChangeIdx + 1] {
            let take = min(context, count)
            appendContextRange(oldStart: oIdx, newStart: nIdx, count: take)
        }

        flushHunk()
        return hunks
    }
}

// MARK: - Lightweight ANSI Escape Sanitizer & Span Parser for Terminal PTY Streams

public struct ANSISpan: Sendable, Equatable, Identifiable {
    public let id: Int
    public let text: String
    public let fgCode: Int? // 30..37, 90..97
    public let isBold: Bool

    public init(id: Int, text: String, fgCode: Int? = nil, isBold: Bool = false) {
        self.id = id
        self.text = text
        self.fgCode = fgCode
        self.isBold = isBold
    }
}

/// Parses PTY output streams, stripping OSC/CSI control noise (cursor moves, window titles)
/// while preserving SGR colors/bold, column-reset `\r` overwrites, and safe trailing escape buffering.
public enum ANSITerminalParser {
    private struct StyledCell {
        var char: Character
        var fg: Int?
        var bold: Bool
    }

    public static func parse(_ raw: String) -> [ANSISpan] {
        var carry = ""
        return parse(raw, carry: &carry)
    }

    /// Parses a PTY chunk while stashing any incomplete trailing ESC/CSI/OSC sequence into `carry`
    /// so chunk boundaries never leak partial escape fragments into rendered terminal text.
    public static func parse(_ raw: String, carry: inout String) -> [ANSISpan] {
        let combined: String
        if carry.isEmpty {
            combined = raw
        } else {
            combined = carry + raw
            carry.removeAll(keepingCapacity: true)
        }
        guard !combined.isEmpty else { return [] }

        var rawPieces: [(text: String, fg: Int?, bold: Bool)] = []
        var lineCells: [StyledCell] = []
        var cursorCol = 0
        var fg: Int? = nil
        var bold = false

        let scalars = Array(combined.unicodeScalars)
        var i = 0

        func flushLine(withNewline: Bool) {
            for cell in lineCells {
                appendPiece(cell.char, fg: cell.fg, bold: cell.bold)
            }
            if withNewline {
                appendPiece("\n", fg: fg, bold: bold)
            }
            lineCells.removeAll(keepingCapacity: true)
            cursorCol = 0
        }

        // The open piece is kept outside `rawPieces` so appending never copies an array element.
        var pieceText = ""
        var pieceFG: Int? = nil
        var pieceBold = false

        func appendPiece(_ ch: Character, fg cellFG: Int?, bold cellBold: Bool) {
            if pieceText.isEmpty || (pieceFG == cellFG && pieceBold == cellBold) {
                pieceFG = cellFG
                pieceBold = cellBold
            } else {
                rawPieces.append((pieceText, pieceFG, pieceBold))
                pieceText = ""
                pieceFG = cellFG
                pieceBold = cellBold
            }
            pieceText.append(ch)
        }

        func putChar(_ ch: Character) {
            let cell = StyledCell(char: ch, fg: fg, bold: bold)
            if cursorCol < lineCells.count {
                lineCells[cursorCol] = cell
            } else {
                while lineCells.count < cursorCol {
                    lineCells.append(StyledCell(char: " ", fg: nil, bold: false))
                }
                lineCells.append(cell)
            }
            cursorCol += 1
        }

        while i < scalars.count {
            let s = scalars[i]

            if s.value == 0x1B { // ESC
                guard i + 1 < scalars.count else {
                    carry = "\u{1B}"
                    break
                }
                let next = scalars[i + 1]
                if next == "[" {
                    // CSI sequence: ESC [ (0x20..0x3F)* (0x40..0x7E)
                    var j = i + 2
                    var paramStr = ""
                    while j < scalars.count && scalars[j].value >= 0x20 && scalars[j].value <= 0x3F {
                        paramStr.unicodeScalars.append(scalars[j])
                        j += 1
                    }
                    guard j < scalars.count else {
                        carry = String(String.UnicodeScalarView(scalars[i..<scalars.count]))
                        break
                    }
                    let finalByte = scalars[j]
                    if finalByte.value >= 0x40 && finalByte.value <= 0x7E {
                        if finalByte == "m" {
                            applySGR(paramStr, fg: &fg, bold: &bold)
                        } else if finalByte == "K" {
                            let mode = Int(paramStr.trimmingCharacters(in: .whitespaces)) ?? 0
                            switch mode {
                            case 0:
                                if cursorCol < lineCells.count {
                                    lineCells.removeSubrange(cursorCol..<lineCells.count)
                                }
                            case 1:
                                let limit = min(cursorCol + 1, lineCells.count)
                                for idx in 0..<limit {
                                    lineCells[idx] = StyledCell(char: " ", fg: nil, bold: false)
                                }
                            case 2:
                                lineCells.removeAll(keepingCapacity: true)
                                cursorCol = 0
                            default:
                                break
                            }
                        }
                        i = j + 1
                        continue
                    } else {
                        // Interrupted CSI (e.g. a fresh ESC); resume from `j`.
                        i = j
                        continue
                    }
                } else if next == "]" || next == "P" || next == "X" || next == "^" || next == "_" {
                    // OSC, DCS, SOS, PM and APC strings end at BEL (0x07), ST (ESC \), or C1 ST (0x9C).
                    var j = i + 2
                    var terminated = false
                    while j < scalars.count {
                        if scalars[j].value == 0x07 || scalars[j].value == 0x9C {
                            j += 1
                            terminated = true
                            break
                        }
                        if scalars[j].value == 0x1B {
                            if j + 1 < scalars.count {
                                if scalars[j + 1] == "\\" {
                                    j += 2
                                    terminated = true
                                    break
                                } else {
                                    // Interrupted by a new ESC sequence.
                                    terminated = true
                                    break
                                }
                            } else {
                                // Ends on trailing ESC that may become ESC \.
                                break
                            }
                        }
                        j += 1
                    }
                    if !terminated {
                        carry = String(String.UnicodeScalarView(scalars[i..<scalars.count]))
                        break
                    }
                    i = j
                    continue
                } else {
                    // nF / Fp / Fe / Fs escapes: ESC, intermediates 0x20-0x2F, then one final byte
                    // 0x30-0x7E, e.g. `ESC ( B` from tput sgr0 or `ESC = ` for keypad mode.
                    var j = i + 1
                    while j < scalars.count && scalars[j].value >= 0x20 && scalars[j].value <= 0x2F {
                        j += 1
                    }
                    guard j < scalars.count else {
                        carry = String(String.UnicodeScalarView(scalars[i..<scalars.count]))
                        break
                    }
                    if scalars[j].value >= 0x30 && scalars[j].value <= 0x7E {
                        i = j + 1
                    } else {
                        // Not a valid escape: drop ESC and intermediates, resume at the stray byte.
                        i = j
                    }
                    continue
                }
            }

            if s == "\r" {
                if i + 1 < scalars.count && scalars[i + 1] == "\n" {
                    flushLine(withNewline: true)
                    i += 2
                } else {
                    // Standalone carriage return rewinds column cursor to overwrite the current line.
                    cursorCol = 0
                    i += 1
                }
                continue
            }

            if s == "\n" {
                flushLine(withNewline: true)
                i += 1
                continue
            }

            if s.value == 0x07 { // BEL
                i += 1
                continue
            }

            if s.value == 0x08 { // BS
                if cursorCol > 0 {
                    if cursorCol == lineCells.count {
                        lineCells.removeLast()
                    }
                    cursorCol -= 1
                }
                i += 1
                continue
            }

            if s.value == 0x09 {
                putChar("\t")
                i += 1
                continue
            }
            if isControl(s) {
                // Other C0/C1 controls never occupy a cell.
                i += 1
                continue
            }

            // Build the whole printable run once and let String segment it into grapheme clusters,
            // so combining marks and emoji sequences join their base character in linear time.
            var endIdx = i + 1
            while endIdx < scalars.count && !isControl(scalars[endIdx]) {
                endIdx += 1
            }
            var run = String.UnicodeScalarView()
            run.append(contentsOf: scalars[i..<endIdx])
            for ch in String(run) {
                putChar(ch)
            }
            i = endIdx
        }

        flushLine(withNewline: false)
        if !pieceText.isEmpty {
            rawPieces.append((pieceText, pieceFG, pieceBold))
        }

        return rawPieces.enumerated().map { idx, piece in
            ANSISpan(id: idx, text: piece.text, fgCode: piece.fg, isBold: piece.bold)
        }
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return v < 0x20 || v == 0x7F || (v >= 0x80 && v <= 0x9F)
    }

    private static func applySGR(_ rawParams: String, fg: inout Int?, bold: inout Bool) {
        if rawParams.isEmpty {
            fg = nil
            bold = false
            return
        }

        let normalized = rawParams.replacingOccurrences(of: ":", with: ";")
        let codes = normalized.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        if codes.isEmpty {
            fg = nil
            bold = false
            return
        }

        var idx = 0
        while idx < codes.count {
            let code = codes[idx]
            switch code {
            case 0:
                fg = nil
                bold = false
                idx += 1
            case 1:
                bold = true
                idx += 1
            case 22:
                bold = false
                idx += 1
            case 30...37, 90...97:
                fg = code
                idx += 1
            case 39:
                fg = nil
                idx += 1
            case 38:
                // Extended foreground: 38;5;N (256-color) or 38;2;R;G;B (24-bit truecolor).
                guard idx + 1 < codes.count else {
                    idx = codes.count
                    break
                }
                let mode = codes[idx + 1]
                if mode == 5 {
                    if idx + 2 < codes.count {
                        fg = map256ToANSI(codes[idx + 2])
                    }
                    idx += min(3, codes.count - idx)
                } else if mode == 2 {
                    if idx + 4 < codes.count {
                        fg = mapRGBToANSI(r: codes[idx + 2], g: codes[idx + 3], b: codes[idx + 4])
                    }
                    idx += min(5, codes.count - idx)
                } else {
                    idx += 2
                }
            case 48, 58:
                // Extended background (48) or underline (58) color: skip all color arguments cleanly
                // so R/G/B/palette numbers like 0, 1, 31..37 never corrupt foreground or bold state.
                guard idx + 1 < codes.count else {
                    idx = codes.count
                    break
                }
                let mode = codes[idx + 1]
                if mode == 5 {
                    idx += min(3, codes.count - idx)
                } else if mode == 2 {
                    idx += min(5, codes.count - idx)
                } else {
                    idx += 2
                }
            default:
                idx += 1
            }
        }
    }

    private static func map256ToANSI(_ index: Int) -> Int? {
        guard (0...255).contains(index) else { return nil }
        if index < 8 {
            return 30 + index
        }
        if index < 16 {
            return 90 + (index - 8)
        }
        if index < 232 {
            let cube = index - 16
            let r = (cube / 36) * 51
            let g = ((cube / 6) % 6) * 51
            let b = (cube % 6) * 51
            return mapRGBToANSI(r: r, g: g, b: b)
        }
        let gray = 8 + (index - 232) * 10
        return gray < 128 ? 90 : 37
    }

    private static func mapRGBToANSI(r: Int, g: Int, b: Int) -> Int {
        let cr = max(0, min(255, r))
        let cg = max(0, min(255, g))
        let cb = max(0, min(255, b))
        let maxC = max(cr, max(cg, cb))
        let minC = min(cr, min(cg, cb))
        if maxC - minC < 32 {
            return maxC < 110 ? 90 : 37
        }
        let bright = maxC >= 190
        let base = bright ? 90 : 30
        let rBit = cr >= (maxC * 2) / 3 ? 1 : 0
        let gBit = cg >= (maxC * 2) / 3 ? 2 : 0
        let bBit = cb >= (maxC * 2) / 3 ? 4 : 0
        let ansiOffset = rBit | gBit | bBit
        return base + (ansiOffset == 0 ? 7 : ansiOffset)
    }
}

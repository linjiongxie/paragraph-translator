import Foundation

/// GFM table structure, including the original cell ranges for lossless rewriting.
/// See https://github.github.com/gfm/#tables-extension-.
public enum MarkdownTable {
    public enum Alignment: Equatable {
        case unspecified, left, center, right
    }

    public struct Cell {
        public let markdown: String
        /// UTF-16 range in the original row, excluding surrounding spaces and tabs.
        public let sourceRange: NSRange
        public var content: AttributedString { FormattedText.inline(from: inlineMarkdown(markdown)) }
    }

    public struct Row {
        public let sourceLine: Int
        public let source: String
        /// All source cells, including extra body cells that GFM does not display.
        public let cells: [Cell]
    }

    public struct Table {
        public let header: Row
        public let rows: [Row]
        public let alignments: [Alignment]
        public let sourceLines: Range<Int>
        public let delimiterLineIndex: Int
        public let delimiterSource: String
        public let blankLinesBefore: Int
        public var columnCount: Int { header.cells.count }

        /// GFM pads short body rows and ignores excess cells for presentation.
        /// The original `Row.cells` remain intact for translation and copying.
        public func displayedCells(in row: Row) -> [Cell] {
            var cells = Array(row.cells.prefix(columnCount))
            while cells.count < columnCount {
                cells.append(Cell(markdown: "", sourceRange: NSRange(location: row.source.utf16.count, length: 0)))
            }
            return cells
        }
    }

    /// Finds top-level pipe tables, excluding fenced and indented code blocks.
    /// Shared by display and translation so they agree on table boundaries.
    public static func tables(in lines: [String]) -> [Table] {
        var result: [Table] = []
        var index = 0
        var blankLines = 0
        var fence: Fence?
        while index < lines.count {
            let line = lines[index]
            if let current = fence {
                if let body = current.continuationBody(line) {
                    if current.closes(with: body) { fence = nil }
                    blankLines = 0
                    index += 1
                    continue
                }
                // An unclosed fence ends with its list/blockquote container.
                // Reconsider this line so an ensuing top-level table is visible.
                fence = nil
            }
            if let opening = Fence.opening(line) {
                fence = opening
                blankLines = 0
                index += 1
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blankLines += 1
                index += 1
                continue
            }
            if let table = parse(lines: lines, startingAt: index, blankLinesBefore: blankLines) {
                result.append(table)
                index = table.sourceLines.upperBound
            } else {
                index += 1
            }
            blankLines = 0
        }
        return result
    }

    public static func parse(lines: [String], startingAt index: Int, blankLinesBefore: Int = 0) -> Table? {
        guard index >= 0, index + 1 < lines.count,
              !isIndentedCode(lines[index]), !isIndentedCode(lines[index + 1]),
              !startsOtherBlock(lines[index]), containsUnescapedPipe(lines[index]) else { return nil }
        let header = row(from: lines[index], sourceLine: index)
        let delimiter = row(from: lines[index + 1], sourceLine: index + 1)
        guard !header.cells.isEmpty, header.cells.count == delimiter.cells.count else { return nil }
        var alignments: [Alignment] = []
        for cell in delimiter.cells {
            guard let alignment = delimiterAlignment(cell.markdown) else { return nil }
            alignments.append(alignment)
        }
        var rows: [Row] = []
        var end = index + 2
        while end < lines.count {
            let source = lines[end]
            guard !source.trimmingCharacters(in: .whitespaces).isEmpty,
                  !startsOtherBlock(source) else { break }
            rows.append(row(from: source, sourceLine: end))
            end += 1
        }
        return Table(header: header, rows: rows, alignments: alignments,
                     sourceLines: index..<end, delimiterLineIndex: index + 1,
                     delimiterSource: lines[index + 1], blankLinesBefore: blankLinesBefore)
    }

    /// Splits unescaped pipes before inline parsing, including pipes in code spans.
    public static func row(from line: String, sourceLine: Int = 0) -> Row {
        let units = Array(line.utf16)
        let whole = trimmedRange(0..<units.count, in: units)
        let pipes = pipeOffsets(in: units)
        var ranges: [Range<Int>] = []
        var start = 0
        for pipe in pipes {
            ranges.append(start..<pipe)
            start = pipe + 1
        }
        ranges.append(start..<units.count)
        if pipes.first == whole.lowerBound { ranges.removeFirst() }
        if pipes.last == whole.upperBound - 1, !ranges.isEmpty { ranges.removeLast() }
        let original = line as NSString
        let cells = ranges.map { range -> Cell in
            let trimmed = trimmedRange(range, in: units)
            let sourceRange = NSRange(location: trimmed.lowerBound, length: trimmed.count)
            return Cell(markdown: original.substring(with: sourceRange), sourceRange: sourceRange)
        }
        return Row(sourceLine: sourceLine, source: line, cells: cells)
    }

    private static func containsUnescapedPipe(_ line: String) -> Bool {
        !pipeOffsets(in: Array(line.utf16)).isEmpty
    }

    private static func pipeOffsets(in units: [UInt16]) -> [Int] {
        var result: [Int] = []
        var backslashes = 0
        for (index, unit) in units.enumerated() {
            if unit == 124, backslashes.isMultiple(of: 2) { result.append(index) }
            backslashes = unit == 92 ? backslashes + 1 : 0
        }
        return result
    }

    private static func trimmedRange(_ range: Range<Int>, in units: [UInt16]) -> Range<Int> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, units[lower] == 32 || units[lower] == 9 { lower += 1 }
        while upper > lower, units[upper - 1] == 32 || units[upper - 1] == 9 { upper -= 1 }
        return lower..<upper
    }

    private static func delimiterAlignment(_ source: String) -> Alignment? {
        var body = source[...]
        let left = body.first == ":"
        let right = body.last == ":"
        if left { body.removeFirst() }
        if right, !body.isEmpty { body.removeLast() }
        guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return nil }
        if left && right { return .center }
        if left { return .left }
        if right { return .right }
        return .unspecified
    }

    private static func isIndentedCode(_ source: String) -> Bool {
        var columns = 0
        for character in source {
            if character == " " { columns += 1 }
            else if character == "\t" { columns += 4 - columns % 4 }
            else { break }
            if columns >= 4 { return true }
        }
        return false
    }

    private static func startsOtherBlock(_ source: String) -> Bool {
        let body = source.drop(while: { $0 == " " || $0 == "\t" })
        guard !isIndentedCode(source) else { return false }
        if body.first == ">" || Fence.opening(source) != nil { return true }
        let text = String(body)
        return matches(#"^(#{1,6})([ \t]|$)"#, text)
            || matches(#"^([-+*])([ \t]+|$)"#, text)
            || matches(#"^1[.)]([ \t]+|$)"#, text)
            || matches(#"^([-*_])(?:[ \t]*\1){2,}[ \t]*$"#, text)
            || matches(#"^<(?:!--|\?|!\[CDATA\[|!DOCTYPE|/?(?:address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul|script|pre|style|textarea)(?:[ \t>/]|$))"#, text)
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private struct Fence {
        let marker: Character
        let count: Int
        let containers: [Container]

        enum Container {
            case quote
            case indentation(Int)
        }

        static func opening(_ line: String) -> Fence? {
            var content = line
            var containers: [Container] = []
            // Recognize only the container prefixes needed to exclude their
            // code fences. Container tables continue through the plain-text path.
            while containers.count < 32 {
                if let prefix = content.range(of: #"^ {0,3}>[ \t]?"#, options: .regularExpression) {
                    containers.append(.quote)
                    content = String(content[prefix.upperBound...])
                } else if let prefix = content.range(of: #"^ {0,3}(?:[-+*]|[0-9]{1,9}[.)])[ \t]+"#, options: .regularExpression) {
                    var columns = 0
                    for character in content[prefix] {
                        columns += character == "\t" ? 4 - columns % 4 : 1
                    }
                    containers.append(.indentation(columns))
                    content = String(content[prefix.upperBound...])
                } else {
                    break
                }
            }
            guard !isIndentedCode(content) else { return nil }
            let body = content.drop(while: { $0 == " " })
            guard let marker = body.first, marker == "`" || marker == "~" else { return nil }
            let count = body.prefix(while: { $0 == marker }).count
            guard count >= 3 else { return nil }
            if marker == "`", body.dropFirst(count).contains("`") { return nil }
            return Fence(marker: marker, count: count, containers: containers)
        }

        func continuationBody(_ line: String) -> String? {
            var content = line
            for container in containers {
                switch container {
                case .quote:
                    guard let prefix = content.range(of: #"^ {0,3}>[ \t]?"#, options: .regularExpression) else { return nil }
                    content = String(content[prefix.upperBound...])
                case .indentation(let required):
                    if content.trimmingCharacters(in: .whitespaces).isEmpty { content = ""; continue }
                    var body = content[...]
                    var columns = 0
                    while columns < required, let character = body.first, character == " " || character == "\t" {
                        columns += character == "\t" ? 4 - columns % 4 : 1
                        body.removeFirst()
                    }
                    guard columns >= required else { return nil }
                    content = String(repeating: " ", count: columns - required) + body
                }
            }
            return content
        }

        func closes(with line: String) -> Bool {
            guard !isIndentedCode(line) else { return false }
            let body = line.drop(while: { $0 == " " })
            let run = body.prefix(while: { $0 == marker }).count
            return run >= count && body.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
        }
    }

    public static func inlineBreakCount(in markdown: String) -> Int {
        inlineBreakRanges(in: unescapeTablePipes(markdown)).count
    }

    private static func unescapeTablePipes(_ source: String) -> String {
        // Table pipes are escaped even inside code spans, unlike normal Markdown.
        let units = Array(source.utf16)
        var unescaped: [UInt16] = []
        var index = 0
        while index < units.count {
            if units[index] == 92 {
                let start = index
                while index < units.count, units[index] == 92 { index += 1 }
                let count = index - start
                let escapesPipe = index < units.count && units[index] == 124 && !count.isMultiple(of: 2)
                unescaped.append(contentsOf: repeatElement(UInt16(92), count: count - (escapesPipe ? 1 : 0)))
            } else {
                unescaped.append(units[index])
                index += 1
            }
        }
        return String(decoding: unescaped, as: UTF16.self)
    }

    private static func inlineMarkdown(_ source: String) -> String {
        let markdown = unescapeTablePipes(source)
        // A cell cannot contain a block newline in pipe syntax. Native selection
        // capture uses an inline HTML break when a source cell has multiple lines.
        let mutable = NSMutableString(string: markdown)
        for range in inlineBreakRanges(in: markdown).reversed() {
            mutable.replaceCharacters(in: range, with: "\n")
        }
        return mutable as String
    }

    private static func inlineBreakRanges(in markdown: String) -> [NSRange] {
        let codeRanges = codeSpanRanges(in: markdown)
        let units = Array(markdown.utf16)
        let expression = try? NSRegularExpression(pattern: #"<br\s*/?\s*>"#, options: .caseInsensitive)
        return (expression?.matches(in: markdown, range: NSRange(location: 0, length: markdown.utf16.count)) ?? [])
            .map(\.range).filter { range in
                !isEscaped(at: range.location, in: units)
                    && !codeRanges.contains(where: { NSIntersectionRange($0, range).length > 0 })
            }
    }

    private static func isEscaped(at offset: Int, in units: [UInt16]) -> Bool {
        var backslashes = 0
        var index = offset
        while index > 0, units[index - 1] == 92 {
            backslashes += 1
            index -= 1
        }
        return !backslashes.isMultiple(of: 2)
    }

    private static func codeSpanRanges(in text: String) -> [NSRange] {
        let units = Array(text.utf16)
        var spans: [NSRange] = []
        var index = 0
        while index < units.count {
            guard units[index] == 96, !isEscaped(at: index, in: units) else { index += 1; continue }
            let start = index
            while index < units.count, units[index] == 96 { index += 1 }
            let count = index - start
            var end = index
            while end < units.count {
                guard units[end] == 96 else { end += 1; continue }
                let closeStart = end
                while end < units.count, units[end] == 96 { end += 1 }
                if end - closeStart == count {
                    spans.append(NSRange(location: start, length: end - start))
                    index = end
                    break
                }
            }
        }
        return spans
    }
}

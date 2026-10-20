import Foundation

struct TranslationLayout {
    let paragraphs: [String]
    private let lines: [String]
    private let separators: [String]
    private let units: [Unit]
    private let tables: [MarkdownTable.Table]

    private struct Unit {
        let line: Int
        let prefix: String
        let cellRange: NSRange?
        let tableIndex: Int?
    }

    static let responseSchema = Data(#"{"type":"object","properties":{"translations":{"type":"array","items":{"type":"string"}}},"required":["translations"],"additionalProperties":false}"#.utf8)

    init(source: String) {
        let original = source as NSString
        let newline = try! NSRegularExpression(pattern: "\\r\\n|[\\n\\r\u{0085}\u{2028}\u{2029}]")
        var lines: [String] = []
        var separators: [String] = []
        var position = 0
        for match in newline.matches(in: source, range: NSRange(location: 0, length: original.length)) {
            lines.append(original.substring(with: NSRange(location: position, length: match.range.location - position)))
            separators.append(original.substring(with: match.range))
            position = NSMaxRange(match.range)
        }
        lines.append(original.substring(from: position))
        self.lines = lines
        self.separators = separators
        let tables = MarkdownTable.tables(in: lines)
        self.tables = tables
        var tableAtLine: [Int: Int] = [:]
        var rowAtLine: [Int: MarkdownTable.Row] = [:]
        for (tableIndex, table) in tables.enumerated() {
            for line in table.sourceLines { tableAtLine[line] = tableIndex }
            for row in [table.header] + table.rows { rowAtLine[row.sourceLine] = row }
        }
        let prefixPattern = try! NSRegularExpression(pattern: "^[ \\t]*(?:(?:#{1,6}|[-+*•]|\\d+[.)]|>+)[ \\t]+)?")
        var units: [Unit] = []
        var paragraphs: [String] = []
        for index in lines.indices {
            if let tableIndex = tableAtLine[index] {
                guard let row = rowAtLine[index] else { continue }
                for cell in row.cells where Self.needsCellTranslation(cell) {
                    units.append(Unit(line: index, prefix: "", cellRange: cell.sourceRange, tableIndex: tableIndex))
                    paragraphs.append(cell.markdown)
                }
            } else if !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                let match = prefixPattern.firstMatch(in: lines[index], range: NSRange(lines[index].startIndex..., in: lines[index]))
                let prefix = match.map { (lines[index] as NSString).substring(with: $0.range) } ?? ""
                units.append(Unit(line: index, prefix: prefix, cellRange: nil, tableIndex: nil))
                paragraphs.append(String(lines[index].dropFirst(prefix.count)))
            }
        }
        self.units = units
        self.paragraphs = paragraphs
    }

    func render(response: String) throws -> String {
        struct Response: Decodable { let translations: [String] }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: Data(response.utf8)),
              decoded.translations.count == units.count else {
            throw CodexTranslatorError.invalidParagraphLayout
        }
        let translations = decoded.translations.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for (position, translation) in translations.enumerated() {
            guard !translation.isEmpty, translation.rangeOfCharacter(from: .newlines) == nil,
                  inlineFormat(translation) == inlineFormat(paragraphs[position]) else {
                throw CodexTranslatorError.invalidParagraphLayout
            }
            if units[position].cellRange != nil {
                guard Self.isSafeTableCell(translation),
                      Self.numbers(in: translation) == Self.numbers(in: paragraphs[position]),
                      MarkdownTable.inlineBreakCount(in: translation) == MarkdownTable.inlineBreakCount(in: paragraphs[position]) else {
                    throw CodexTranslatorError.invalidParagraphLayout
                }
            }
        }
        let result = renderedLines(translations: translations, through: lines.count - 1, blankPendingCells: false)
        guard hasOriginalTableStructure(result) else { throw CodexTranslatorError.invalidParagraphLayout }
        return result.enumerated().map { index, line in
            line + (index < separators.count ? separators[index] : "")
        }.joined()
    }

    /// A temporary preview of a syntactically valid JSON prefix. Inline Markdown
    /// can still be unfinished; callers must use `render` before accepting a result.
    func renderPartial(response: String) -> String? {
        var parser = PartialTranslationResponse(response, maximumItems: units.count)
        guard let preview = parser.parse() else { return nil }
        if preview.isComplete { return try? render(response: response) }

        var translations = preview.translations.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // An opening quote or a partial escape has no visible text of its own.
        if translations.last?.isEmpty == true { translations.removeLast() }
        guard !translations.isEmpty,
              translations.allSatisfy({ !$0.isEmpty && $0.rangeOfCharacter(from: .newlines) == nil }) else { return nil }

        for (unit, translation) in zip(units, translations) where unit.cellRange != nil {
            guard Self.isSafeTableCell(translation) else { return nil }
        }
        let lastUnit = units[translations.count - 1]
        // A table needs its delimiter row from the first cell onward. Keep its
        // shape stable while later cells stream, without exposing source text.
        let lastLine = lastUnit.tableIndex.map { tables[$0].sourceLines.upperBound - 1 } ?? lastUnit.line
        let result = renderedLines(translations: translations, through: lastLine, blankPendingCells: true)
        guard hasOriginalTableStructure(result) else { return nil }
        return result.enumerated().map { index, line in
            line + (index < lastLine ? separators[index] : "")
        }.joined()
    }

    private func renderedLines(translations: [String], through lastLine: Int, blankPendingCells: Bool) -> [String] {
        var result = Array(lines[...lastLine])
        var cellReplacements: [Int: [(NSRange, String)]] = [:]
        for (position, unit) in units.enumerated() where unit.line <= lastLine {
            if let range = unit.cellRange {
                if position < translations.count {
                    cellReplacements[unit.line, default: []].append((range, translations[position]))
                } else if blankPendingCells {
                    cellReplacements[unit.line, default: []].append((range, ""))
                }
            } else if position < translations.count {
                result[unit.line] = unit.prefix + translations[position]
            }
        }
        for (line, replacements) in cellReplacements {
            let mutable = NSMutableString(string: result[line])
            for (range, translation) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
                mutable.replaceCharacters(in: range, with: translation)
            }
            result[line] = mutable as String
        }
        if blankPendingCells {
            for table in tables where table.sourceLines.lowerBound <= lastLine {
                for row in [table.header] + table.rows where row.sourceLine <= lastLine {
                    let line = row.sourceLine
                    guard result[line].trimmingCharacters(in: .whitespaces).isEmpty
                            || MarkdownTable.row(from: result[line]).cells.count != row.cells.count,
                          let first = row.cells.first, let last = row.cells.last else { continue }
                    // Without an outer pipe, a pending boundary cell can look
                    // like missing framing or an empty line. Add preview-only
                    // framing; the final copy keeps the original row exactly.
                    let original = row.source as NSString
                    if !original.substring(to: first.sourceRange.location).contains("|") { result[line] = "|" + result[line] }
                    if !original.substring(from: NSMaxRange(last.sourceRange)).contains("|") { result[line] += "|" }
                }
            }
        }
        return result
    }

    private func hasOriginalTableStructure(_ renderedLines: [String]) -> Bool {
        for table in tables where table.sourceLines.lowerBound < renderedLines.count {
            guard let rendered = MarkdownTable.parse(lines: renderedLines, startingAt: table.sourceLines.lowerBound),
                  rendered.sourceLines == table.sourceLines,
                  rendered.columnCount == table.columnCount,
                  rendered.rows.map({ $0.cells.count }) == table.rows.map({ $0.cells.count }) else { return false }
        }
        return true
    }

    private static func needsCellTranslation(_ cell: MarkdownTable.Cell) -> Bool {
        // Empty cells and numeric values are structural data. Keeping them
        // outside the response avoids both needless work and changed results.
        String(cell.content.characters).rangeOfCharacter(from: .letters) != nil
    }

    private static func isSafeTableCell(_ text: String) -> Bool {
        var escaped = false
        for character in text {
            if character == "|", !escaped { return false }
            if character == "\\" { escaped.toggle() } else { escaped = false }
        }
        // A trailing escape could consume the fixed closing cell delimiter.
        return !escaped
    }

    private static func numbers(in text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"[-+−]?\d+(?:[.,]\d+)*(?:[ \t]*(?:%|‰))?"#)
        let original = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: original.length)).map {
            original.substring(with: $0.range).filter { $0 != " " && $0 != "\t" }
        }
    }

    private struct InlineFormat: Equatable {
        var strong = 0
        var italic = 0
        var code = 0
        var links: [String] = []
    }

    private func inlineFormat(_ text: String) -> InlineFormat {
        let attributed = FormattedText.inline(from: text)
        var result = InlineFormat()
        var previous: InlinePresentationIntent = []
        var previousLink: String?
        for run in attributed.runs {
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.stronglyEmphasized), !previous.contains(.stronglyEmphasized) { result.strong += 1 }
            if intent.contains(.emphasized), !previous.contains(.emphasized) { result.italic += 1 }
            if intent.contains(.code), !previous.contains(.code) { result.code += 1 }
            let link = run.link?.absoluteString
            if let link, link != previousLink { result.links.append(link) }
            previous = intent
            previousLink = link
        }
        return result
    }
}

/// Reads only the response schema, rather than extracting apparent strings with
/// a regular expression. Incomplete escapes never become visible characters.
private struct PartialTranslationResponse {
    struct Preview {
        let translations: [String]
        var isComplete = false
    }

    private enum JSONString {
        case complete(String)
        case incomplete(String)
        case invalid
    }

    private enum HexQuad {
        case value(UInt32)
        case incomplete
        case invalid
    }

    private let scalars: [Unicode.Scalar]
    private let maximumItems: Int
    private var position = 0

    init(_ response: String, maximumItems: Int) {
        scalars = Array(response.unicodeScalars)
        self.maximumItems = maximumItems
    }

    mutating func parse() -> Preview? {
        guard take("{") else { return nil }
        skipWhitespace()
        guard case .complete("translations") = readString(), take(":"), take("[") else { return nil }
        var translations: [String] = []
        skipWhitespace()
        if position == scalars.count { return Preview(translations: translations) }
        if scalars[position] != "]" {
            while true {
                guard translations.count < maximumItems else { return nil }
                switch readString() {
                case .invalid:
                    return nil
                case .incomplete(let text):
                    guard text.rangeOfCharacter(from: .newlines) == nil else { return nil }
                    return Preview(translations: translations + [text])
                case .complete(let text):
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          text.rangeOfCharacter(from: .newlines) == nil else { return nil }
                    translations.append(text)
                }
                skipWhitespace()
                if position == scalars.count { return Preview(translations: translations) }
                if scalars[position] == "]" { break }
                guard take(","), translations.count < maximumItems else { return nil }
                skipWhitespace()
                if position == scalars.count { return Preview(translations: translations) }
            }
        }
        guard translations.count == maximumItems, take("]") else { return nil }
        skipWhitespace()
        if position == scalars.count { return Preview(translations: translations) }
        guard take("}") else { return nil }
        skipWhitespace()
        guard position == scalars.count else { return nil }
        return Preview(translations: translations, isComplete: true)
    }

    private mutating func take(_ scalar: Unicode.Scalar) -> Bool {
        skipWhitespace()
        guard position < scalars.count, scalars[position] == scalar else { return false }
        position += 1
        return true
    }

    private mutating func skipWhitespace() {
        while position < scalars.count, [0x20, 0x09, 0x0A, 0x0D].contains(scalars[position].value) { position += 1 }
    }

    private mutating func readString() -> JSONString {
        guard position < scalars.count, scalars[position] == "\"" else { return .invalid }
        position += 1
        var text = ""
        while position < scalars.count {
            let scalar = scalars[position]
            position += 1
            if scalar == "\"" { return .complete(text) }
            guard scalar.value >= 0x20 else { return .invalid }
            if scalar != "\\" {
                text.unicodeScalars.append(scalar)
                continue
            }
            guard position < scalars.count else { return .incomplete(text) }
            let escape = scalars[position].value
            position += 1
            switch escape {
            case 0x22, 0x5C, 0x2F:
                text.unicodeScalars.append(Unicode.Scalar(escape)!)
            case 0x62: text.append("\u{08}")
            case 0x66: text.append("\u{0C}")
            case 0x6E: text.append("\n")
            case 0x72: text.append("\r")
            case 0x74: text.append("\t")
            case 0x75:
                var value: UInt32
                switch readHexQuad() {
                case .value(let number): value = number
                case .incomplete: return .incomplete(text)
                case .invalid: return .invalid
                }
                if (0xD800...0xDBFF).contains(value) {
                    guard position < scalars.count else { return .incomplete(text) }
                    guard scalars[position] == "\\" else { return .invalid }
                    position += 1
                    guard position < scalars.count else { return .incomplete(text) }
                    guard scalars[position] == "u" else { return .invalid }
                    position += 1
                    switch readHexQuad() {
                    case .value(let low) where (0xDC00...0xDFFF).contains(low):
                        value = 0x10000 + ((value - 0xD800) << 10) + low - 0xDC00
                    case .incomplete: return .incomplete(text)
                    default: return .invalid
                    }
                } else if (0xDC00...0xDFFF).contains(value) {
                    return .invalid
                }
                guard let decoded = Unicode.Scalar(value) else { return .invalid }
                text.unicodeScalars.append(decoded)
            default:
                return .invalid
            }
        }
        return .incomplete(text)
    }

    private mutating func readHexQuad() -> HexQuad {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard position < scalars.count else { return .incomplete }
            let digit = scalars[position].value
            position += 1
            let hex: UInt32
            switch digit {
            case 0x30...0x39: hex = digit - 0x30
            case 0x41...0x46: hex = digit - 0x41 + 10
            case 0x61...0x66: hex = digit - 0x61 + 10
            default: return .invalid
            }
            value = (value << 4) | hex
        }
        return .value(value)
    }
}

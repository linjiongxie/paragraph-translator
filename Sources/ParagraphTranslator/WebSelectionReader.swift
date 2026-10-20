import AppKit
import ApplicationServices

struct WebParagraphContext {
    var listDepth = 0
    var isHeading = false
}

struct WebInlineTraits {
    var strong = false
    var emphasized = false
    var tableCell: WebTableCellContext?
}

struct WebInlineInterval<Marker> {
    let start: Marker
    let end: Marker
    var traits = WebInlineTraits()
}

/// Metadata may describe an entire source leaf, but text is requested only
/// after the traversal intersects that leaf with the supplied selection.
@MainActor
protocol WebSelectionInlineMarkerSource {
    associatedtype Marker
    func compare(_ left: Marker, _ right: Marker) throws -> ComparisonResult
    func inlineInterval(at marker: Marker) throws -> WebInlineInterval<Marker>
    func nextMarker(after marker: Marker) throws -> Marker
    func inlineText(from start: Marker, to end: Marker) throws -> String
    func tableObjectIsInGap(from start: Marker, to end: Marker, before cell: WebTableCellContext) throws -> Bool
}

extension WebSelectionInlineMarkerSource {
    func tableObjectIsInGap(from start: Marker, to end: Marker, before cell: WebTableCellContext) throws -> Bool { false }
}

struct WebTableCellContext: Equatable {
    let table: Int
    let row: Int
    let column: Int
    let rows: Int
    let columns: Int
    let rowSpan: Int
    let columnSpan: Int
    let complete: Bool
    let tableCharacters: Int?

    var attribute: NSDictionary {
        ["table": table, "row": row, "column": column, "rows": rows, "columns": columns,
         "rowSpan": rowSpan, "columnSpan": columnSpan, "complete": complete,
         "tableCharacters": tableCharacters ?? -1] as NSDictionary
    }

    init(table: Int, row: Int, column: Int, rows: Int, columns: Int,
         rowSpan: Int = 1, columnSpan: Int = 1, complete: Bool, tableCharacters: Int? = nil) {
        self.table = table; self.row = row; self.column = column
        self.rows = rows; self.columns = columns
        self.rowSpan = rowSpan; self.columnSpan = columnSpan; self.complete = complete
        self.tableCharacters = tableCharacters
    }

    init?(_ value: Any?) {
        guard let value = value as? NSDictionary,
              let table = value["table"] as? Int, let row = value["row"] as? Int,
              let column = value["column"] as? Int, let rows = value["rows"] as? Int,
              let columns = value["columns"] as? Int,
              let rowSpan = value["rowSpan"] as? Int, let columnSpan = value["columnSpan"] as? Int,
              let complete = value["complete"] as? Bool else { return nil }
        self.init(table: table, row: row, column: column, rows: rows, columns: columns,
                  rowSpan: rowSpan, columnSpan: columnSpan, complete: complete,
                  tableCharacters: (value["tableCharacters"] as? Int).flatMap { $0 >= 0 ? $0 : nil })
    }
}

enum WebSemanticStyle {
    static let strong = NSAttributedString.Key("ParagraphSemanticStrong")
    static let emphasized = NSAttributedString.Key("ParagraphSemanticEmphasis")
    static let tableCell = NSAttributedString.Key("ParagraphSemanticTableCell")
    static let tableObject = NSAttributedString.Key("ParagraphSemanticTableObject")
}

@MainActor
enum WebSelectionInlineTraversal {
    static func applying<Source: WebSelectionInlineMarkerSource>(
        to attributed: NSAttributedString,
        source: Source,
        start: Source.Marker,
        end: Source.Marker,
        maximumIntervals: Int = 2_000,
        deadline: TimeInterval
    ) throws -> NSAttributedString {
        func checkTime() throws {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw WebSelectionFailure.timedOut }
        }
        try checkTime()
        guard maximumIntervals > 0 else { throw WebSelectionFailure.limitExceeded }
        guard try source.compare(start, end) == .orderedAscending else { throw WebSelectionFailure.invalidRange }
        let result = NSMutableAttributedString(attributedString: attributed)
        let original = attributed.string as NSString
        var cursor = start
        var offset = 0
        var intervals = 0

        func append(until intervalEnd: Source.Marker, traits: WebInlineTraits, beforeCell: WebTableCellContext? = nil) throws {
            try checkTime()
            guard try source.compare(cursor, intervalEnd) == .orderedAscending,
                  try source.compare(intervalEnd, end) != .orderedDescending else { throw WebSelectionFailure.noProgress }
            let text = try source.inlineText(from: cursor, to: intervalEnd)
            try checkTime()
            let length = text.utf16.count
            guard length <= original.length - offset else { throw WebSelectionFailure.invalidContent }
            let range = NSRange(location: offset, length: length)
            guard original.substring(with: range) == text else { throw WebSelectionFailure.invalidContent }
            if length > 0 {
                if traits.strong { result.addAttribute(WebSemanticStyle.strong, value: true, range: range) }
                if traits.emphasized { result.addAttribute(WebSemanticStyle.emphasized, value: true, range: range) }
                if let cell = traits.tableCell { result.addAttribute(WebSemanticStyle.tableCell, value: cell.attribute, range: range) }
                if text == "\u{FFFC}", let cell = beforeCell,
                   try source.tableObjectIsInGap(from: cursor, to: intervalEnd, before: cell) {
                    result.addAttribute(WebSemanticStyle.tableObject, value: ["table": cell.table] as NSDictionary, range: range)
                }
            }
            offset += length
            cursor = intervalEnd
        }

        while try source.compare(cursor, end) == .orderedAscending {
            try checkTime()
            // Chromium can represent the same textual position using a cell
            // anchor and its final static-text leaf. Once the supplied exact
            // paragraph is fully reconstructed, no further leaf text exists.
            if offset == original.length { break }
            var probe = cursor
            var interval: WebInlineInterval<Source.Marker>?
            // At a boundary Chromium can return the exhausted previous leaf.
            // Move only the metadata probe; retain cursor so no selected text
            // is skipped and no preceding leaf's style crosses the boundary.
            for _ in 0..<4 {
                guard intervals < maximumIntervals else { throw WebSelectionFailure.limitExceeded }
                intervals += 1
                let candidate = try source.inlineInterval(at: probe)
                guard try source.compare(candidate.start, candidate.end) != .orderedDescending else { throw WebSelectionFailure.invalidRange }
                if try source.compare(cursor, candidate.end) == .orderedAscending {
                    interval = candidate
                    break
                }
                let next = try source.nextMarker(after: probe)
                guard try source.compare(probe, next) == .orderedAscending,
                      try source.compare(next, end) != .orderedDescending else { throw WebSelectionFailure.noProgress }
                probe = next
                try checkTime()
            }
            guard let interval else { throw WebSelectionFailure.noProgress }
            if try source.compare(cursor, interval.start) == .orderedAscending {
                let gapEnd = try source.compare(interval.start, end) == .orderedAscending ? interval.start : end
                try append(until: gapEnd, traits: WebInlineTraits(), beforeCell: interval.traits.tableCell)
                if try source.compare(cursor, end) == .orderedSame { break }
            }
            let clippedEnd = try source.compare(interval.end, end) == .orderedAscending ? interval.end : end
            try append(until: clippedEnd, traits: interval.traits)
        }
        try checkTime()
        guard offset == original.length else { throw WebSelectionFailure.invalidContent }
        return result
    }
}

enum WebSelectionFailure: Error, Equatable {
    case unsupported
    case invalidRange
    case comparisonUnavailable
    case invalidContent
    case noProgress
    case limitExceeded
    case timedOut
    case selectionChanged
    case unsupportedTable
    case accessibilityError(Int)

    var fallbackReason: String {
        let detail: String
        switch self {
        case .unsupported: detail = "来源没有提供可用的网页段落标记"
        case .invalidRange: detail = "来源返回了无效选区"
        case .comparisonUnavailable: detail = "无法安全比较选区边界"
        case .invalidContent: detail = "来源返回的段落文字不完整"
        case .noProgress: detail = "来源的段落标记未向前移动"
        case .limitExceeded: detail = "选区超过了格式读取预算"
        case .timedOut: detail = "格式读取超过了 1 秒预算"
        case .selectionChanged: detail = "读取期间来源选区发生了变化"
        case .unsupportedTable: detail = "表格选区不完整，或包含暂不支持的合并单元格"
        case .accessibilityError(let code): detail = "辅助功能格式接口返回错误 \(code)"
        }
        return "\(detail)；已回退到普通选区文字，段落、列表或字体格式可能不完整。"
    }
}

/// The traversal can be tested without reading another application's UI.
/// Implementations must return text only for the exact supplied interval.
@MainActor
protocol WebSelectionMarkerSource {
    associatedtype Marker
    var selectedTextLength: Int? { get }
    func compare(_ left: Marker, _ right: Marker) throws -> ComparisonResult
    func nextParagraphEnd(after marker: Marker) throws -> Marker
    func attributedText(from start: Marker, to end: Marker) throws -> NSAttributedString
    func context(from start: Marker, to end: Marker) throws -> WebParagraphContext
    func selectionMatches(start: Marker, end: Marker) throws -> Bool
}

extension WebSelectionMarkerSource {
    var selectedTextLength: Int? { nil }
}

@MainActor
enum WebSelectionTraversal {
    static func capture<Source: WebSelectionMarkerSource>(
        source: Source,
        start: Source.Marker,
        end: Source.Marker,
        maximumCharacters: Int = 20_000,
        maximumParagraphs: Int = 1_000,
        deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 1
    ) throws -> String {
        func checkTime() throws {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw WebSelectionFailure.timedOut
            }
        }
        try checkTime()
        guard maximumCharacters > 0, maximumParagraphs > 0 else {
            throw WebSelectionFailure.limitExceeded
        }
        guard try source.compare(start, end) == .orderedAscending else {
            throw WebSelectionFailure.invalidRange
        }

        var cursor = start
        var paragraphs: [(attributed: NSAttributedString, context: WebParagraphContext)] = []
        var characterCount = 0
        while try source.compare(cursor, end) == .orderedAscending {
            try checkTime()
            // Distinct AX anchors may denote the identical final textual
            // position. The exact SelectedText projection is an independent
            // bound; the source still verifies its contents and markers below.
            if let length = source.selectedTextLength, characterCount == length { break }
            guard paragraphs.count < maximumParagraphs else {
                throw WebSelectionFailure.limitExceeded
            }
            let candidate = try source.nextParagraphEnd(after: cursor)
            guard try source.compare(cursor, candidate) == .orderedAscending else {
                throw WebSelectionFailure.noProgress
            }
            // Navigation may return a marker beyond the selection. Clip it
            // before making any string or attributed-string request.
            let clippedEnd = try source.compare(candidate, end) == .orderedAscending
                ? candidate : end
            try checkTime()
            let attributed = try source.attributedText(from: cursor, to: clippedEnd)
            characterCount += attributed.length
            guard characterCount <= maximumCharacters else {
                throw WebSelectionFailure.limitExceeded
            }
            let context = try source.context(from: cursor, to: clippedEnd)
            paragraphs.append((attributed, context))
            cursor = clippedEnd
        }
        try checkTime()
        guard try source.selectionMatches(start: start, end: end) else {
            throw WebSelectionFailure.selectionChanged
        }
        try checkTime()
        guard paragraphs.contains(where: { $0.attributed.length > 0 }) else {
            throw WebSelectionFailure.invalidContent
        }
        let result = try WebSelectionMarkdown.renderBlocks(paragraphs)
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WebSelectionFailure.invalidContent }
        guard result.utf16.count <= maximumCharacters else {
            throw WebSelectionFailure.limitExceeded
        }
        try checkTime()
        return result
    }
}

/// Converts only styles and list markers explicitly supplied by the source.
/// AX attributed strings use accessibility keys, not AppKit's `.font` key.
enum WebSelectionMarkdown {
    private struct Run {
        var text: String
        let bold: Bool
        let italic: Bool
    }

    static func render(_ attributed: NSAttributedString, context: WebParagraphContext) -> String {
        let original = attributed.string as NSString
        var contentRange = NSRange(location: 0, length: original.length)
        var prefix = ""
        if context.listDepth > 0,
           let expression = try? NSRegularExpression(pattern: "^[ \\t]*([•◦▪‣⁃●○■□*+\\-]|[0-9]+[.)])[ \\t]*"),
           let match = expression.firstMatch(in: attributed.string, range: contentRange) {
            let marker = original.substring(with: match.range(at: 1))
            prefix = marker.first?.isNumber == true ? marker + " " : "- "
            contentRange = NSRange(location: match.range.length, length: original.length - match.range.length)
        }
        let body = attributed.attributedSubstring(from: contentRange)
        var runs: [Run] = []
        func append(_ text: String, bold: Bool, italic: Bool) {
            guard !text.isEmpty else { return }
            if let last = runs.last, last.bold == bold, last.italic == italic {
                runs[runs.count - 1].text += text
            } else {
                runs.append(Run(text: text, bold: bold, italic: italic))
            }
        }
        body.enumerateAttributes(in: NSRange(location: 0, length: body.length)) { attributes, range, _ in
            let traits = fontTraits(attributes)
            let bold = context.isHeading || traits.bold
            let italic = !context.isHeading && traits.italic
            let raw = (body.string as NSString).substring(with: range)
            append(raw, bold: bold, italic: italic)
        }
        let styledRuns = runs
        runs = []
        for run in styledRuns {
            func appendLine(_ line: String) {
                let leading = line.prefix(while: { $0.isWhitespace })
                let remainder = line.dropFirst(leading.count)
                let trailing = remainder.reversed().prefix(while: { $0.isWhitespace }).count
                append(String(leading), bold: false, italic: false)
                append(String(remainder.dropLast(trailing)), bold: run.bold, italic: run.italic)
                append(String(remainder.suffix(trailing)), bold: false, italic: false)
            }
            // Keep boundary whitespace outside Markdown delimiters; close
            // styles on explicit newlines so every displayed line is balanced.
            var line = ""
            for character in run.text {
                if character.isNewline {
                    appendLine(line)
                    append(String(character), bold: false, italic: false)
                    line = ""
                } else {
                    line.append(character)
                }
            }
            appendLine(line)
        }
        var markdown = ""
        var stack: [String] = []
        for run in runs {
            let wanted = (run.bold ? ["**"] : []) + (run.italic ? ["*"] : [])
            let shared = zip(stack, wanted).prefix(while: { $0 == $1 }).count
            for delimiter in stack.dropFirst(shared).reversed() { markdown += delimiter }
            for delimiter in wanted.dropFirst(shared) { markdown += delimiter }
            markdown += escaped(run.text)
            stack = wanted
        }
        for delimiter in stack.reversed() { markdown += delimiter }
        let indentation = String(repeating: "    ", count: max(0, context.listDepth - 1))
        let continuation = indentation + (prefix.isEmpty ? "" : "    ")
        return indentation + prefix + markdown.replacingOccurrences(of: "\n", with: "\n" + continuation)
    }

    /// Group only explicit AX cell metadata. Range containment, or exact text
    /// coverage of one table anchor's offsets, proves that absent spans are
    /// empty cells rather than unselected values. Partial tables and merged
    /// cells use the existing plain fallback.
    static func renderBlocks(_ paragraphs: [(attributed: NSAttributedString, context: WebParagraphContext)]) throws -> String {
        var blocks: [(text: String, context: WebParagraphContext)] = []
        var cells: [(context: WebTableCellContext, attributed: NSMutableAttributedString, rawCharacters: Int)] = []
        var previousParagraphCell: WebTableCellContext?
        var tableObjects: Set<Int> = []
        var renderedTables: Set<Int> = []

        func flushTable() throws {
            guard let first = cells.first?.context else { return }
            let capturedCharacters = cells.reduce(0) { $0 + $1.rawCharacters }
            let complete = first.complete || first.tableCharacters == capturedCharacters
            guard complete, first.rows > 0, first.columns > 0,
                  first.rows <= 1_000, first.columns <= 1_000,
                  first.rows <= 1_000 / first.columns else { throw WebSelectionFailure.unsupportedTable }
            var grid = Array(repeating: Array(repeating: "", count: first.columns), count: first.rows)
            var previousIndex = -1
            for cell in cells {
                let meta = cell.context
                guard meta.table == first.table, meta.rows == first.rows, meta.columns == first.columns,
                      meta.tableCharacters == first.tableCharacters, meta.complete == first.complete,
                      meta.rowSpan == 1, meta.columnSpan == 1,
                      (0..<first.rows).contains(meta.row), (0..<first.columns).contains(meta.column) else {
                    throw WebSelectionFailure.unsupportedTable
                }
                let index = meta.row * first.columns + meta.column
                guard index > previousIndex else { throw WebSelectionFailure.unsupportedTable }
                previousIndex = index
                let markdown = render(cell.attributed, context: WebParagraphContext())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "|", with: "\\|")
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                    .replacingOccurrences(of: "\n", with: "<br>")
                grid[meta.row][meta.column] = markdown
            }
            func row(_ values: [String]) -> String { "| " + values.joined(separator: " | ") + " |" }
            var lines = [row(grid[0]), row(Array(repeating: "---", count: first.columns))]
            lines += grid.dropFirst().map(row)
            blocks.append((lines.joined(separator: "\n"), WebParagraphContext()))
            renderedTables.insert(first.table)
            cells.removeAll(keepingCapacity: true)
        }

        for paragraph in paragraphs {
            var pieces: [(NSAttributedString, WebTableCellContext?)] = []
            paragraph.attributed.enumerateAttribute(WebSemanticStyle.tableCell,
                in: NSRange(location: 0, length: paragraph.attributed.length)) { value, range, _ in
                let piece = NSMutableAttributedString(attributedString: paragraph.attributed.attributedSubstring(from: range))
                if value == nil {
                    var objectRanges: [NSRange] = []
                    piece.enumerateAttribute(WebSemanticStyle.tableObject, in: NSRange(location: 0, length: piece.length)) { value, range, _ in
                        if let owner = value as? NSDictionary, let table = owner["table"] as? Int,
                           (piece.string as NSString).substring(with: range) == "\u{FFFC}" {
                            tableObjects.insert(table)
                            objectRanges.append(range)
                        }
                    }
                    for range in objectRanges.reversed() { piece.deleteCharacters(in: range) }
                }
                if piece.length > 0 { pieces.append((piece, WebTableCellContext(value))) }
            }
            var firstPiece = true
            for (piece, metadata) in pieces {
                if let metadata {
                    if let last = cells.last, last.context.table != metadata.table { try flushTable() }
                    if let last = cells.last, last.context == metadata {
                        if firstPiece, previousParagraphCell == metadata,
                           !last.attributed.string.hasSuffix("\n"), !piece.string.hasPrefix("\n") {
                            last.attributed.append(NSAttributedString(string: "\n"))
                        }
                        last.attributed.append(piece)
                        cells[cells.count - 1].rawCharacters += piece.length
                    } else {
                        cells.append((metadata, NSMutableAttributedString(attributedString: piece), piece.length))
                    }
                    previousParagraphCell = metadata
                } else if !piece.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try flushTable()
                    blocks.append((render(piece, context: paragraph.context), paragraph.context))
                    previousParagraphCell = nil
                } else if cells.isEmpty {
                    blocks.append((render(piece, context: paragraph.context), paragraph.context))
                    previousParagraphCell = nil
                }
                firstPiece = false
            }
        }
        try flushTable()
        guard tableObjects.isSubset(of: renderedTables) else { throw WebSelectionFailure.unsupportedTable }
        var result = ""
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                let bothLists = blocks[index - 1].context.listDepth > 0 && block.context.listDepth > 0
                let desired = bothLists ? 1 : 2
                let existing = result.reversed().prefix(while: { $0 == "\n" }).count
                    + block.text.prefix(while: { $0 == "\n" }).count
                result += String(repeating: "\n", count: max(0, desired - existing))
            }
            result += block.text
        }
        return result
    }

    private static func fontTraits(_ attributes: [NSAttributedString.Key: Any]) -> (bold: Bool, italic: Bool) {
        let font = attributes[.accessibilityFont] as? NSDictionary
        var bold = (attributes[WebSemanticStyle.strong] as? NSNumber)?.boolValue == true
        var italic = (attributes[WebSemanticStyle.emphasized] as? NSNumber)?.boolValue == true
        if #available(macOS 26.0, *) {
            let boldKey = NSAttributedString.Key.accessibilityFontBoldAttribute
            let italicKey = NSAttributedString.Key.accessibilityFontItalicAttribute
            bold = bold || (font?[boldKey.rawValue] as? NSNumber)?.boolValue == true
                || (attributes[boldKey] as? NSNumber)?.boolValue == true
            italic = italic || (font?[italicKey.rawValue] as? NSNumber)?.boolValue == true
                || (attributes[italicKey] as? NSNumber)?.boolValue == true
        }
        if let name = font?[NSAccessibility.FontAttributeKey.fontName.rawValue] as? String,
           let native = NSFont(name: name, size: NSFont.systemFontSize) {
            let traits = NSFontManager.shared.traits(of: native)
            bold = bold || traits.contains(.boldFontMask)
            italic = italic || traits.contains(.italicFontMask)
        }
        return (bold, italic)
    }

    private static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_[]#<>".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}

/// Public AX text-marker APIs are available in the current SDK. In Chromium,
/// querying one attributed string for the full selection still flattens block
/// boundaries. Navigate explicit paragraph ends and request only clipped text.
@MainActor
final class WebSelectionReader {
    let deadline = ProcessInfo.processInfo.systemUptime + 1
    var hasTimeRemaining: Bool { ProcessInfo.processInfo.systemUptime < deadline }

    func read(from element: AXUIElement, expectedText: String?) throws -> String {
        let source = AccessibilityWebSelectionSource(element: element, deadline: deadline, expectedText: expectedText)
        let range = try source.beginSelection()
        return try WebSelectionTraversal.capture(source: source, start: range.0, end: range.1, deadline: deadline)
    }
}

@MainActor
private final class AccessibilityWebSelectionSource: WebSelectionMarkerSource, WebSelectionInlineMarkerSource {
    typealias Marker = AXTextMarker
    private let element: AXUIElement
    private let deadline: TimeInterval
    private let expectedText: String?
    private struct TableContext {
        let identifier: Int
        let rows: Int
        let columns: Int
        let complete: Bool
        let characters: Int?
    }
    private struct NodeContext {
        var paragraph = WebParagraphContext()
        var inline = WebInlineTraits()
        var table: TableContext?
    }
    private var tables: [AXUIElement] = []
    private var selection: (Marker, Marker)?
    private var contexts: [(AXUIElement, NodeContext)] = []
    private var originalText: String?
    private var capturedText = ""
    var selectedTextLength: Int? { originalText?.utf16.count }

    init(element: AXUIElement, deadline: TimeInterval, expectedText: String?) {
        self.element = element
        self.deadline = deadline
        self.expectedText = expectedText
    }

    func beginSelection() throws -> (Marker, Marker) {
        let range = try selectedRange()
        selection = range
        do {
            originalText = try attribute(kAXSelectedTextAttribute as CFString, of: element) as? String
            if let expectedText, originalText != expectedText { throw WebSelectionFailure.selectionChanged }
            if let originalText, originalText.utf16.count > 20_000 {
                throw WebSelectionFailure.limitExceeded
            }
        } catch WebSelectionFailure.unsupported {
            originalText = nil
        }
        return range
    }

    func selectedRange() throws -> (Marker, Marker) {
        let value = try attribute(kAXSelectedTextMarkerRangeAttribute as CFString, of: element)
        guard CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else {
            throw WebSelectionFailure.invalidRange
        }
        let range = value as! AXTextMarkerRange
        let first = AXTextMarkerRangeCopyStartMarker(range)
        let last = AXTextMarkerRangeCopyEndMarker(range)
        return try compare(first, last) == .orderedDescending ? (last, first) : (first, last)
    }

    func compare(_ left: Marker, _ right: Marker) throws -> ComparisonResult {
        if CFEqual(left, right) { return .orderedSame }
        let unordered = [left, right] as CFArray
        let value = try parameter(kAXTextMarkerRangeForUnorderedTextMarkersParameterizedAttribute as CFString, unordered)
        guard CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else {
            throw WebSelectionFailure.comparisonUnavailable
        }
        let range = value as! AXTextMarkerRange
        let first = AXTextMarkerRangeCopyStartMarker(range)
        let last = AXTextMarkerRangeCopyEndMarker(range)
        if CFEqual(first, left), CFEqual(last, right) { return .orderedAscending }
        if CFEqual(first, right), CFEqual(last, left) { return .orderedDescending }
        // Do not decode marker bytes, compare opaque bytes lexicographically,
        // or call AXLength/String on a potentially out-of-selection range.
        throw WebSelectionFailure.comparisonUnavailable
    }

    func nextParagraphEnd(after marker: Marker) throws -> Marker {
        try textMarker(parameter(kAXNextParagraphEndTextMarkerForTextMarkerParameterizedAttribute as CFString, marker))
    }

    func attributedText(from start: Marker, to end: Marker) throws -> NSAttributedString {
        let range = AXTextMarkerRangeCreate(kCFAllocatorDefault, start, end)
        let attributed: NSAttributedString
        do {
            let value = try parameter(kAXAttributedStringForTextMarkerRangeParameterizedAttribute as CFString, range)
            if CFGetTypeID(value) == CFAttributedStringGetTypeID(), let text = value as? NSAttributedString {
                attributed = text
            } else {
                throw WebSelectionFailure.invalidContent
            }
        } catch WebSelectionFailure.unsupported {
            let value = try parameter(kAXStringForTextMarkerRangeParameterizedAttribute as CFString, range)
            guard let text = value as? String else { throw WebSelectionFailure.invalidContent }
            attributed = NSAttributedString(string: text)
        }
        capturedText += attributed.string
        let rich = try WebSelectionInlineTraversal.applying(to: attributed, source: self, start: start, end: end, deadline: deadline)
        let result = NSMutableAttributedString(attributedString: rich)
        var attachments: [(NSRange, AXUIElement)] = []
        rich.enumerateAttribute(NSAttributedString.Key("AXAttachment"), in: NSRange(location: 0, length: rich.length)) { value, range, _ in
            if let value, CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID(),
               (rich.string as NSString).substring(with: range) == "\u{FFFC}" {
                attachments.append((range, value as! AXUIElement))
            }
        }
        for (range, attachment) in attachments {
            if try attribute(kAXRoleAttribute as CFString, of: attachment) as? String == "AXTable" {
                let owner = try context(of: attachment).table
                guard let owner else { throw WebSelectionFailure.unsupportedTable }
                result.addAttribute(WebSemanticStyle.tableObject, value: ["table": owner.identifier] as NSDictionary, range: range)
            }
        }
        return result
    }

    func inlineInterval(at marker: Marker) throws -> WebInlineInterval<Marker> {
        let leaf = try uiElement(parameter(kAXUIElementForTextMarkerParameterizedAttribute as CFString, marker))
        let value = try parameter(kAXTextMarkerRangeForUIElementParameterizedAttribute as CFString, leaf)
        guard CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { throw WebSelectionFailure.invalidRange }
        let range = value as! AXTextMarkerRange
        return WebInlineInterval(start: AXTextMarkerRangeCopyStartMarker(range), end: AXTextMarkerRangeCopyEndMarker(range), traits: try context(of: leaf).inline)
    }

    func nextMarker(after marker: Marker) throws -> Marker {
        try textMarker(parameter(kAXNextTextMarkerForTextMarkerParameterizedAttribute as CFString, marker))
    }

    func inlineText(from start: Marker, to end: Marker) throws -> String {
        let range = AXTextMarkerRangeCreate(kCFAllocatorDefault, start, end)
        guard let text = try parameter(kAXStringForTextMarkerRangeParameterizedAttribute as CFString, range) as? String else { throw WebSelectionFailure.invalidContent }
        return text
    }

    func tableObjectIsInGap(from start: Marker, to end: Marker, before cell: WebTableCellContext) throws -> Bool {
        guard tables.indices.contains(cell.table) else { throw WebSelectionFailure.unsupportedTable }
        let table = tables[cell.table]
        let value = try parameter(kAXTextMarkerRangeForUIElementParameterizedAttribute as CFString, table)
        guard CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { throw WebSelectionFailure.invalidRange }
        let first = AXTextMarkerRangeCopyStartMarker(value as! AXTextMarkerRange)
        // Some Chromium tables place an unstyled object-replacement character
        // before their first cell. The table's explicit marker must be inside
        // the already-read one-character gap; adjacent text alone is no proof.
        return try compare(start, first) != .orderedDescending
            && compare(first, end) == .orderedAscending
    }

    func context(from start: Marker, to end: Marker) throws -> WebParagraphContext {
        var probe = start
        var leaf = try uiElement(parameter(kAXUIElementForTextMarkerParameterizedAttribute as CFString, probe))
        // The previous paragraph's end marker can point at its last text leaf.
        // Advance past that exhausted leaf, never past this clipped interval.
        for _ in 0..<4 {
            let value = try parameter(kAXTextMarkerRangeForUIElementParameterizedAttribute as CFString, leaf)
            guard CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { throw WebSelectionFailure.invalidRange }
            let leafEnd = AXTextMarkerRangeCopyEndMarker(value as! AXTextMarkerRange)
            if try compare(probe, leafEnd) == .orderedAscending { return try context(of: leaf).paragraph }
            if try compare(probe, end) == .orderedSame { return try context(of: leaf).paragraph }
            let next = try textMarker(parameter(kAXNextTextMarkerForTextMarkerParameterizedAttribute as CFString, probe))
            guard try compare(probe, next) == .orderedAscending,
                  try compare(next, end) != .orderedDescending else { throw WebSelectionFailure.noProgress }
            probe = next
            leaf = try uiElement(parameter(kAXUIElementForTextMarkerParameterizedAttribute as CFString, probe))
        }
        throw WebSelectionFailure.noProgress
    }

    func selectionMatches(start: Marker, end: Marker) throws -> Bool {
        let current = try selectedRange()
        guard try compare(start, current.0) == .orderedSame,
              try compare(end, current.1) == .orderedSame else { return false }
        if let originalText {
            let currentText = try attribute(kAXSelectedTextAttribute as CFString, of: element) as? String
            guard currentText == originalText else { return false }
            guard capturedText == originalText else { throw WebSelectionFailure.invalidContent }
        }
        return true
    }

    private func context(of leaf: AXUIElement) throws -> NodeContext {
        var current = leaf
        var path: [(AXUIElement, String, String)] = []
        var result = NodeContext()
        for _ in 0..<32 {
            if let cached = contexts.first(where: { CFEqual($0.0, current) }) {
                result = cached.1
                break
            }
            guard !path.contains(where: { CFEqual($0.0, current) }) else { throw WebSelectionFailure.noProgress }
            let role = try attribute(kAXRoleAttribute as CFString, of: current) as? String ?? ""
            let subrole: String
            do { subrole = try attribute(kAXSubroleAttribute as CFString, of: current) as? String ?? "" }
            catch WebSelectionFailure.unsupported { subrole = "" }
            path.append((current, role, subrole))
            if role == "AXWebArea" || role == (kAXApplicationRole as String) { break }
            current = try uiElement(attribute(kAXParentAttribute as CFString, of: current))
        }
        guard path.count < 32 else { throw WebSelectionFailure.limitExceeded }
        for (node, role, subrole) in path.reversed() {
            if role == (kAXListRole as String) { result.paragraph.listDepth += 1 }
            if role == (kAXHeadingRole as String) { result.paragraph.isHeading = true }
            if role == "AXTable" {
                result.table = try tableContext(node)
                result.inline.tableCell = nil
            }
            if ["AXCell", "AXColumnHeader", "AXRowHeader"].contains(role), let table = result.table {
                let row = try indexRange("AXRowIndexRange", of: node)
                let column = try indexRange("AXColumnIndexRange", of: node)
                result.inline.tableCell = WebTableCellContext(table: table.identifier,
                    row: row.location, column: column.location, rows: table.rows, columns: table.columns,
                    rowSpan: row.length, columnSpan: column.length,
                    complete: table.complete, tableCharacters: table.characters)
            }
            if subrole == "AXStrongStyleGroup" { result.inline.strong = true }
            if subrole == "AXEmphasisStyleGroup" { result.inline.emphasized = true }
            contexts.append((node, result))
        }
        return result
    }

    private func indexRange(_ name: String, of target: AXUIElement) throws -> CFRange {
        let value = try attribute(name as CFString, of: target)
        guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .cfRange else {
            throw WebSelectionFailure.unsupportedTable
        }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length > 0 else {
            throw WebSelectionFailure.unsupportedTable
        }
        return range
    }

    private func tableContext(_ table: AXUIElement) throws -> TableContext {
        guard let selection,
              let rows = try attribute("AXARIARowCount" as CFString, of: table) as? NSNumber,
              let columns = try attribute("AXARIAColumnCount" as CFString, of: table) as? NSNumber,
              rows.intValue > 0, columns.intValue > 0,
              rows.intValue <= 1_000, columns.intValue <= 1_000,
              rows.intValue <= 1_000 / columns.intValue else { throw WebSelectionFailure.unsupportedTable }
        let value = try parameter(kAXTextMarkerRangeForUIElementParameterizedAttribute as CFString, table)
        guard CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { throw WebSelectionFailure.invalidRange }
        let range = value as! AXTextMarkerRange
        let first = AXTextMarkerRangeCopyStartMarker(range)
        let last = AXTextMarkerRangeCopyEndMarker(range)
        let complete = try compare(selection.0, first) != .orderedDescending
            && compare(last, selection.1) != .orderedDescending
        var characters: Int?
        // These are offsets local to one explicitly identified table anchor,
        // never global offsets mixed with a selected static-text anchor. They
        // describe length only and do not request any unselected text.
        if CFEqual(try uiElement(parameter(kAXUIElementForTextMarkerParameterizedAttribute as CFString, first)), table),
           CFEqual(try uiElement(parameter(kAXUIElementForTextMarkerParameterizedAttribute as CFString, last)), table),
           let a = try parameter(kAXIndexForTextMarkerParameterizedAttribute as CFString, first) as? NSNumber,
           let b = try parameter(kAXIndexForTextMarkerParameterizedAttribute as CFString, last) as? NSNumber,
           a.intValue >= 0, b.intValue >= a.intValue, b.intValue - a.intValue <= 20_000 {
            characters = b.intValue - a.intValue
        }
        let identifier: Int
        if let index = tables.firstIndex(where: { CFEqual($0, table) }) { identifier = index }
        else { identifier = tables.count; tables.append(table) }
        return TableContext(identifier: identifier, rows: rows.intValue, columns: columns.intValue,
                            complete: complete, characters: characters)
    }

    private func prepare(_ target: AXUIElement) throws {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw WebSelectionFailure.timedOut }
        AXUIElementSetMessagingTimeout(target, Float(min(0.08, remaining)))
    }

    private func attribute(_ name: CFString, of target: AXUIElement) throws -> CFTypeRef {
        try prepare(target)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(target, name, &value)
        return try checked(error, value)
    }

    private func parameter(_ name: CFString, _ argument: CFTypeRef) throws -> CFTypeRef {
        try prepare(element)
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(element, name, argument, &value)
        return try checked(error, value)
    }

    private func checked(_ error: AXError, _ value: CFTypeRef?) throws -> CFTypeRef {
        switch error {
        case .success:
            guard let value else { throw WebSelectionFailure.unsupported }
            return value
        case .attributeUnsupported, .parameterizedAttributeUnsupported, .noValue:
            throw WebSelectionFailure.unsupported
        default:
            throw WebSelectionFailure.accessibilityError(Int(error.rawValue))
        }
    }

    private func textMarker(_ value: CFTypeRef) throws -> Marker {
        guard CFGetTypeID(value) == AXTextMarkerGetTypeID() else { throw WebSelectionFailure.invalidRange }
        return value as! AXTextMarker
    }

    private func uiElement(_ value: CFTypeRef) throws -> AXUIElement {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw WebSelectionFailure.invalidRange }
        return value as! AXUIElement
    }
}

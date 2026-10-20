import AppKit
import ApplicationServices

struct WebParagraphContext {
    var listDepth = 0
    var isHeading = false
}

struct WebInlineTraits {
    var strong = false
    var emphasized = false
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
}

enum WebSemanticStyle {
    static let strong = NSAttributedString.Key("ParagraphSemanticStrong")
    static let emphasized = NSAttributedString.Key("ParagraphSemanticEmphasis")
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

        func append(until intervalEnd: Source.Marker, traits: WebInlineTraits) throws {
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
            }
            offset += length
            cursor = intervalEnd
        }

        while try source.compare(cursor, end) == .orderedAscending {
            try checkTime()
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
                try append(until: gapEnd, traits: WebInlineTraits())
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
    func compare(_ left: Marker, _ right: Marker) throws -> ComparisonResult
    func nextParagraphEnd(after marker: Marker) throws -> Marker
    func attributedText(from start: Marker, to end: Marker) throws -> NSAttributedString
    func context(from start: Marker, to end: Marker) throws -> WebParagraphContext
    func selectionMatches(start: Marker, end: Marker) throws -> Bool
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
        var paragraphs: [(text: String, context: WebParagraphContext)] = []
        var characterCount = 0
        while try source.compare(cursor, end) == .orderedAscending {
            try checkTime()
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
            let markdown = WebSelectionMarkdown.render(attributed, context: context)
            paragraphs.append((markdown, context))
            cursor = clippedEnd
        }
        try checkTime()
        guard try source.selectionMatches(start: start, end: end) else {
            throw WebSelectionFailure.selectionChanged
        }
        try checkTime()
        guard paragraphs.contains(where: { !$0.text.isEmpty }) else {
            throw WebSelectionFailure.invalidContent
        }
        var result = ""
        for (index, paragraph) in paragraphs.enumerated() {
            if index > 0 {
                let bothLists = paragraphs[index - 1].context.listDepth > 0
                    && paragraph.context.listDepth > 0
                let desired = bothLists ? 1 : 2
                let existing = result.reversed().prefix(while: { $0 == "\n" }).count
                    + paragraph.text.prefix(while: { $0 == "\n" }).count
                result += String(repeating: "\n", count: max(0, desired - existing))
            }
            result += paragraph.text
        }
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
    private struct NodeContext {
        var paragraph = WebParagraphContext()
        var inline = WebInlineTraits()
    }
    private var contexts: [(AXUIElement, NodeContext)] = []
    private var originalText: String?
    private var capturedText = ""

    init(element: AXUIElement, deadline: TimeInterval, expectedText: String?) {
        self.element = element
        self.deadline = deadline
        self.expectedText = expectedText
    }

    func beginSelection() throws -> (Marker, Marker) {
        let range = try selectedRange()
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
        return try WebSelectionInlineTraversal.applying(to: attributed, source: self, start: start, end: end, deadline: deadline)
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
            if subrole == "AXStrongStyleGroup" { result.inline.strong = true }
            if subrole == "AXEmphasisStyleGroup" { result.inline.emphasized = true }
            contexts.append((node, result))
        }
        return result
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

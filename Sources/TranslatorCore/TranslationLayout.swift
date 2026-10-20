import Foundation

struct TranslationLayout {
    let paragraphs: [String]
    private let lines: [String]
    private let separators: [String]
    private let translatedIndices: [Int]
    private let prefixes: [String]

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
        translatedIndices = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        let prefixPattern = try! NSRegularExpression(pattern: "^[ \\t]*(?:(?:#{1,6}|[-+*•]|\\d+[.)]|>+)[ \\t]+)?")
        let linePrefixes = lines.map { line in
            guard let match = prefixPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return "" }
            return (line as NSString).substring(with: match.range)
        }
        prefixes = linePrefixes
        paragraphs = translatedIndices.map { index in String(lines[index].dropFirst(linePrefixes[index].count)) }
    }

    func render(response: String) throws -> String {
        struct Response: Decodable { let translations: [String] }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: Data(response.utf8)),
              decoded.translations.count == translatedIndices.count else {
            throw CodexTranslatorError.invalidParagraphLayout
        }
        var result = lines
        for (position, pair) in zip(translatedIndices, decoded.translations).enumerated() {
            let (index, rawTranslation) = pair
            let translation = rawTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translation.isEmpty, translation.rangeOfCharacter(from: .newlines) == nil,
                  inlineFormat(translation) == inlineFormat(paragraphs[position]) else {
                throw CodexTranslatorError.invalidParagraphLayout
            }
            result[index] = prefixes[index] + translation
        }
        return result.enumerated().map { index, line in
            line + (index < separators.count ? separators[index] : "")
        }.joined()
    }

    /// A temporary preview of a syntactically valid JSON prefix. Inline Markdown
    /// can still be unfinished; callers must use `render` before accepting a result.
    func renderPartial(response: String) -> String? {
        var parser = PartialTranslationResponse(response, maximumItems: translatedIndices.count)
        guard let preview = parser.parse() else { return nil }
        if preview.isComplete { return try? render(response: response) }

        var translations = preview.translations.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // An opening quote or a partial escape has no visible text of its own.
        if translations.last?.isEmpty == true { translations.removeLast() }
        guard !translations.isEmpty,
              translations.allSatisfy({ !$0.isEmpty && $0.rangeOfCharacter(from: .newlines) == nil }) else { return nil }

        let lastLine = translatedIndices[translations.count - 1]
        var result = Array(lines[...lastLine])
        for (index, translation) in zip(translatedIndices, translations) {
            result[index] = prefixes[index] + translation
        }
        return result.enumerated().map { index, line in
            line + (index < lastLine ? separators[index] : "")
        }.joined()
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

import Foundation

public enum FormattedText {
    public struct Line {
        public let content: AttributedString
        public let headingLevel: Int?
        public let marker: String?
        /// Leading columns, with each tab expanded to four spaces.
        public let indentation: Int
        public let blankLinesBefore: Int
    }

    public static func lines(from text: String) -> [Line] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
        var blankLines = 0
        var result: [Line] = []
        for raw in normalized.components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty {
                blankLines += 1
                continue
            }
            let indentationText = String(raw.prefix { $0 == " " || $0 == "\t" })
            let indentation = indentationText.replacingOccurrences(of: "\t", with: "    ").count
            var body = String(raw.dropFirst(indentationText.count))
            var heading: Int?
            var marker: String?
            if let matched = match("^(#{1,6})[ \\t]+(.*)$", body) {
                heading = matched[0].count
                body = matched[1]
            } else if let matched = match("^([-+*•])[ \\t]+(.*)$", body) {
                marker = "•"
                body = matched[1]
            } else if let matched = match("^(\\d+[.)])[ \\t]+(.*)$", body) {
                marker = matched[0]
                body = matched[1]
            }
            let attributed = inline(from: body)
            result.append(Line(content: attributed, headingLevel: heading, marker: marker,
                               indentation: indentation, blankLinesBefore: blankLines))
            blankLines = 0
        }
        return result
    }

    static func inline(from text: String) -> AttributedString {
        // CommonMark treats a closing delimiter after punctuation and before
        // a letter/number as literal text (e.g. **重要：**正文). Give the parser
        // a temporary non-punctuation character inside that span, then remove
        // it from the attributed result without changing the visible text.
        var sentinel = "\u{E000}"
        while text.contains(sentinel) { sentinel += "\u{E000}" }
        let pattern = #"(?<!\\)(\*\*|__|\*|_)(?=\S)([^\r\n]+?)(?<!\\)\1(?=[\p{L}\p{N}])"#
        let mutable = NSMutableString(string: text)
        if let expression = try? NSRegularExpression(pattern: pattern) {
            let original = text as NSString
            for match in expression.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
                let body = original.substring(with: match.range(at: 2))
                if let last = body.unicodeScalars.last, CharacterSet.punctuationCharacters.contains(last) {
                    mutable.insert(sentinel, at: NSMaxRange(match.range(at: 2)))
                }
            }
        }
        var attributed = (try? AttributedString(markdown: mutable as String, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        while let range = attributed.range(of: sentinel) { attributed.removeSubrange(range) }
        return attributed
    }

    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let found = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let string = text as NSString
        return (1..<found.numberOfRanges).map { string.substring(with: found.range(at: $0)) }
    }
}

import AppKit
import Foundation

@MainActor
final class FixtureSource: WebSelectionMarkerSource {
    typealias Marker = Int
    let text: NSAttributedString
    let ends: [Int]
    let contexts: [(Range<Int>, WebParagraphContext)]
    let selection: Range<Int>
    var reads: [Range<Int>] = []
    var nextOverride: Int?
    var changed = false
    var comparisonUnavailable = false
    var failAfterReads: Int?
    var delayRead = false
    var selectedTextLength: Int?

    init(text: NSAttributedString, ends: [Int], contexts: [(Range<Int>, WebParagraphContext)], selection: Range<Int>) {
        self.text = text; self.ends = ends; self.contexts = contexts; self.selection = selection
    }
    func compare(_ left: Int, _ right: Int) throws -> ComparisonResult {
        if comparisonUnavailable { throw WebSelectionFailure.comparisonUnavailable }
        return left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
    }
    func nextParagraphEnd(after marker: Int) throws -> Int {
        nextOverride ?? ends.first(where: { $0 > marker }) ?? marker
    }
    func attributedText(from start: Int, to end: Int) throws -> NSAttributedString {
        guard start >= selection.lowerBound, end <= selection.upperBound, start < end else {
            throw WebSelectionFailure.invalidRange
        }
        if let failAfterReads, reads.count >= failAfterReads { throw WebSelectionFailure.invalidContent }
        if delayRead { Thread.sleep(forTimeInterval: 0.02) }
        reads.append(start..<end)
        return text.attributedSubstring(from: NSRange(location: start, length: end-start))
    }
    func context(from start: Int, to end: Int) throws -> WebParagraphContext {
        contexts.first(where: { $0.0.overlaps(start..<end) })?.1 ?? WebParagraphContext()
    }
    func selectionMatches(start: Int, end: Int) throws -> Bool { !changed }
}

@MainActor
final class InlineFixtureSource: WebSelectionInlineMarkerSource {
    typealias Marker = Int
    let text: String
    let intervals: [WebInlineInterval<Int>]
    let selection: Range<Int>
    var reads: [Range<Int>] = []
    var returnPreviousAtBoundary = false
    var stuck = false
    var wrongText = false
    var delayRead = false
    var ownedTableObjectGaps: [Range<Int>] = []

    init(text: String, intervals: [WebInlineInterval<Int>], selection: Range<Int>) {
        self.text = text; self.intervals = intervals; self.selection = selection
    }
    func compare(_ left: Int, _ right: Int) throws -> ComparisonResult {
        left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
    }
    func inlineInterval(at marker: Int) throws -> WebInlineInterval<Int> {
        if stuck { return WebInlineInterval(start: marker, end: marker) }
        if returnPreviousAtBoundary, let index = intervals.firstIndex(where: { $0.start == marker }), index > 0 {
            return intervals[index - 1]
        }
        guard let interval = intervals.first(where: { marker < $0.end }) else { throw WebSelectionFailure.invalidRange }
        return interval
    }
    func nextMarker(after marker: Int) throws -> Int { stuck ? marker : marker + 1 }
    func tableObjectIsInGap(from start: Int, to end: Int, before cell: WebTableCellContext) throws -> Bool {
        ownedTableObjectGaps.contains(start..<end)
    }
    func inlineText(from start: Int, to end: Int) throws -> String {
        guard start >= selection.lowerBound, end <= selection.upperBound, start < end else { throw WebSelectionFailure.invalidRange }
        if delayRead { Thread.sleep(forTimeInterval: 0.02) }
        reads.append(start..<end)
        return wrongText ? "wrong" : (text as NSString).substring(with: NSRange(location: start, length: end - start))
    }
}

@main
struct TraversalTests {
    @MainActor static func main() {
        do { try run() }
        catch {
            fputs("Web selection traversal FAILED: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor static func run() throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw NSError(domain: "WebSelectionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            checks += 1
        }
        func fixture() -> FixtureSource {
            let blocks: [(String, Int, Bool)] = [
                ("answer.", 0, false), ("What data shows", 0, true),
                ("• Things one", 1, false), ("◦ Nested", 2, false), ("• Last", 1, false)
            ]
            let prefix = "OUTSIDE "
            let full = prefix + blocks.map(\.0).joined() + " OUTSIDE"
            let attributed = NSMutableAttributedString(string: full)
            let strong = (full as NSString).range(of: "one")
            attributed.addAttribute(.accessibilityFont, value: ["AXFontBold": true], range: strong)
            var offset = prefix.utf16.count
            var ends: [Int] = []
            var contexts: [(Range<Int>, WebParagraphContext)] = []
            for block in blocks {
                let next = offset + block.0.utf16.count
                ends.append(next)
                contexts.append((offset..<next, WebParagraphContext(listDepth: block.1, isHeading: block.2)))
                offset = next
            }
            return FixtureSource(text: attributed, ends: ends, contexts: contexts, selection: (prefix.utf16.count+2)..<(offset-2))
        }
        let source = fixture()
        let result = try WebSelectionTraversal.capture(source: source, start: source.selection.lowerBound, end: source.selection.upperBound)
        try check(result == "swer.\n\n**What data shows**\n\n- Things **one**\n    - Nested\n- La", "Actual source paragraphs/list nesting/heading/strong must survive a flattened AXSelectedText projection; got: \(result.debugDescription)")
        try check(source.reads.count == 5, "Read each clipped paragraph once")
        try check(source.reads.first?.lowerBound == source.selection.lowerBound && source.reads.last?.upperBound == source.selection.upperBound, "Clip first/last paragraph exactly")
        try check(source.reads.allSatisfy { source.selection.lowerBound <= $0.lowerBound && $0.upperBound <= source.selection.upperBound }, "Never read outside the user's selection")
        for limit in [0, 2] {
            let limited = fixture()
            do {
                _ = try WebSelectionTraversal.capture(source: limited, start: limited.selection.lowerBound, end: limited.selection.upperBound, maximumParagraphs: limit)
                try check(false, "Paragraph budget must fail")
            } catch WebSelectionFailure.limitExceeded { checks += 1 }
        }
        let stuck = fixture(); stuck.nextOverride = stuck.selection.lowerBound
        do {
            _ = try WebSelectionTraversal.capture(source: stuck, start: stuck.selection.lowerBound, end: stuck.selection.upperBound)
            try check(false, "No-progress source must fail")
        } catch WebSelectionFailure.noProgress { checks += 1 }
        let reversed = fixture(); reversed.nextOverride = reversed.selection.lowerBound - 1
        do {
            _ = try WebSelectionTraversal.capture(source: reversed, start: reversed.selection.lowerBound, end: reversed.selection.upperBound)
            try check(false, "Backward source must fail")
        } catch WebSelectionFailure.noProgress { checks += 1 }
        let small = fixture()
        do {
            _ = try WebSelectionTraversal.capture(source: small, start: small.selection.lowerBound, end: small.selection.upperBound, maximumCharacters: 10)
            try check(false, "Character budget must fail")
        } catch WebSelectionFailure.limitExceeded { checks += 1 }
        let timed = fixture()
        do {
            _ = try WebSelectionTraversal.capture(source: timed, start: timed.selection.lowerBound, end: timed.selection.upperBound, deadline: 0)
            try check(false, "Expired deadline must fail")
        } catch WebSelectionFailure.timedOut { checks += 1 }
        try check(timed.reads.isEmpty, "Expired deadline cannot read text")
        let changed = fixture(); changed.changed = true
        do {
            _ = try WebSelectionTraversal.capture(source: changed, start: changed.selection.lowerBound, end: changed.selection.upperBound)
            try check(false, "Changed selection cannot publish a capture")
        } catch WebSelectionFailure.selectionChanged { checks += 1 }

        func simple(_ text: String, depth: Int = 0) -> FixtureSource {
            let range = 0..<text.utf16.count
            return FixtureSource(text: NSAttributedString(string: text), ends: [range.upperBound], contexts: [(range, WebParagraphContext(listDepth: depth))], selection: range)
        }
        let oversized = simple(String(repeating: "a", count: 20_001))
        do {
            _ = try WebSelectionTraversal.capture(source: oversized, start: 0, end: oversized.selection.upperBound, deadline: ProcessInfo.processInfo.systemUptime + 5)
            try check(false, "20,001 source characters must fail the default budget")
        } catch WebSelectionFailure.limitExceeded { checks += 1 }
        let exact = simple(String(repeating: "a", count: 20_000))
        let exactText = try WebSelectionTraversal.capture(source: exact, start: 0, end: exact.selection.upperBound, deadline: ProcessInfo.processInfo.systemUptime + 5)
        try check(exactText.utf16.count == 20_000, "Exactly 20,000 plain characters fit")
        let manyText = String(repeating: "a", count: 1_001)
        let many = FixtureSource(text: NSAttributedString(string: manyText), ends: Array(1...1_001), contexts: [], selection: 0..<1_001)
        do {
            _ = try WebSelectionTraversal.capture(source: many, start: 0, end: 1_001, deadline: ProcessInfo.processInfo.systemUptime + 5)
            try check(false, "1,001 source paragraphs must fail the default budget")
        } catch WebSelectionFailure.limitExceeded { checks += 1 }
        let uncertain = fixture(); uncertain.comparisonUnavailable = true
        do {
            _ = try WebSelectionTraversal.capture(source: uncertain, start: uncertain.selection.lowerBound, end: uncertain.selection.upperBound)
            try check(false, "Uncertain marker ordering must fail before reading text")
        } catch WebSelectionFailure.comparisonUnavailable { checks += 1 }
        try check(uncertain.reads.isEmpty, "No text query without safe marker ordering")
        let partlyFailed = fixture(); partlyFailed.failAfterReads = 1
        do {
            _ = try WebSelectionTraversal.capture(source: partlyFailed, start: partlyFailed.selection.lowerBound, end: partlyFailed.selection.upperBound)
            try check(false, "A failed second paragraph cannot publish the first paragraph as a complete selection")
        } catch WebSelectionFailure.invalidContent { checks += 1 }
        let overrun = simple("a"); overrun.delayRead = true
        do {
            _ = try WebSelectionTraversal.capture(source: overrun, start: 0, end: 1, deadline: ProcessInfo.processInfo.systemUptime + 0.01)
            try check(false, "Work that finishes after the deadline cannot publish a result")
        } catch WebSelectionFailure.timedOut { checks += 1 }
        let beyond = fixture(); beyond.nextOverride = beyond.text.length + 1_000
        _ = try WebSelectionTraversal.capture(source: beyond, start: beyond.selection.lowerBound, end: beyond.selection.upperBound)
        try check(beyond.reads == [beyond.selection], "Even a far-outside next marker must be clipped before its text is requested")
        let invalid = simple("a")
        for endpoints in [(0, 0), (1, 0)] {
            do {
                _ = try WebSelectionTraversal.capture(source: invalid, start: endpoints.0, end: endpoints.1)
                try check(false, "Traversal requires a normalized, nonempty range")
            } catch WebSelectionFailure.invalidRange { checks += 1 }
        }
        try check(invalid.reads.isEmpty, "Invalid ranges cannot read text")
        let unicodeText = "🙂firstSECOND"
        let unicode = FixtureSource(text: NSAttributedString(string: unicodeText), ends: [7, unicodeText.utf16.count], contexts: [], selection: 2..<(unicodeText.utf16.count-1))
        let unicodeResult = try WebSelectionTraversal.capture(source: unicode, start: unicode.selection.lowerBound, end: unicode.selection.upperBound)
        try check(unicodeResult == "first\n\nSECON", "AX offsets use UTF-16; partial Unicode selections remain correctly clipped")

        let ordered = WebSelectionMarkdown.render(NSAttributedString(string: "17. Keep numbering"), context: WebParagraphContext(listDepth: 1))
        try check(ordered == "17. Keep numbering", "Keep the source's ordered-list number")
        let partialList = WebSelectionMarkdown.render(NSAttributedString(string: "selected body only"), context: WebParagraphContext(listDepth: 2))
        try check(partialList == "    selected body only", "Do not invent an unselected bullet or number")
        let literal = WebSelectionMarkdown.render(NSAttributedString(string: "literal **stars** and _names_"), context: WebParagraphContext())
        try check(literal == "literal \\*\\*stars\\*\\* and \\_names\\_", "Source punctuation cannot inject Markdown styles")
        let nativeOnly = NSAttributedString(string: "native font", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        try check(WebSelectionMarkdown.render(nativeOnly, context: WebParagraphContext()) == "native font", "AX strings must use accessibility font keys, not AppKit .font")
        let accessibilityBold = NSAttributedString(string: "font traits", attributes: [.accessibilityFont: [NSAccessibility.FontAttributeKey.fontName.rawValue: NSFont.boldSystemFont(ofSize: 13).fontName]])
        try check(WebSelectionMarkdown.render(accessibilityBold, context: WebParagraphContext()) == "**font traits**", "Resolve the AXFontName using native font traits")
        let semanticOnly = NSMutableAttributedString(string: "plain strong tail", attributes: [.accessibilityFont: ["AXFontSize": 14]])
        semanticOnly.addAttribute(NSAttributedString.Key("ParagraphSemanticStrong"), value: true, range: NSRange(location: 6, length: 6))
        try check(WebSelectionMarkdown.render(semanticOnly, context: WebParagraphContext()) == "plain **strong** tail", "Explicit AXStrongStyleGroup semantics preserve mixed strong/plain text even when AXFont exposes only size")

        func inline(_ source: InlineFixtureSource, maximumIntervals: Int = 2_000, deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 1) throws -> NSAttributedString {
            let range = NSRange(location: source.selection.lowerBound, length: source.selection.count)
            let selected = (source.text as NSString).substring(with: range)
            let attributed = NSAttributedString(string: selected, attributes: [.accessibilityFont: ["AXFontSize": 14]])
            return try WebSelectionInlineTraversal.applying(to: attributed, source: source, start: source.selection.lowerBound, end: source.selection.upperBound, maximumIntervals: maximumIntervals, deadline: deadline)
        }
        func inlineMarkdown(_ source: InlineFixtureSource) throws -> String {
            WebSelectionMarkdown.render(try inline(source), context: WebParagraphContext())
        }
        let mixed = InlineFixtureSource(text: "plain strong tail", intervals: [
            WebInlineInterval(start: 0, end: 6),
            WebInlineInterval(start: 6, end: 12, traits: WebInlineTraits(strong: true)),
            WebInlineInterval(start: 12, end: 17)
        ], selection: 0..<17)
        let mixedAttributed = try inline(mixed)
        try check(WebSelectionMarkdown.render(mixedAttributed, context: WebParagraphContext()) == "plain **strong** tail", "Leaf traversal overlays only the explicitly strong interval in a size-only paragraph")
        try check(mixedAttributed.attribute(.accessibilityFont, at: 7, effectiveRange: nil) as? [String: Int] == ["AXFontSize": 14], "Semantic overlay must preserve the source's existing font attributes")
        try check(mixed.reads == [0..<6, 6..<12, 12..<17], "Read only the clipped inline intervals, once each")
        let clipped = InlineFixtureSource(text: mixed.text, intervals: mixed.intervals, selection: 8..<15)
        try check(try inlineMarkdown(clipped) == "**rong** ta", "Partial selection clips both source leaves before applying strong semantics")
        try check(clipped.reads == [8..<12, 12..<15], "No full-leaf text reads outside a partial selection")
        let staleLeaf = InlineFixtureSource(text: mixed.text, intervals: mixed.intervals, selection: 0..<17)
        staleLeaf.returnPreviousAtBoundary = true
        try check(try inlineMarkdown(staleLeaf) == "plain **strong** tail", "An exhausted previous leaf at a boundary cannot extend its style or skip the next character")
        try check(staleLeaf.reads == mixed.reads, "Moving a metadata probe does not move the text cursor")
        let nested = InlineFixtureSource(text: "abcde", intervals: [
            WebInlineInterval(start: 0, end: 1),
            WebInlineInterval(start: 1, end: 2, traits: WebInlineTraits(strong: true)),
            WebInlineInterval(start: 2, end: 3, traits: WebInlineTraits(strong: true, emphasized: true)),
            WebInlineInterval(start: 3, end: 4, traits: WebInlineTraits(strong: true)),
            WebInlineInterval(start: 4, end: 5)
        ], selection: 0..<5)
        let nestedParsed = try AttributedString(markdown: inlineMarkdown(nested), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let nestedStyles = nestedParsed.runs.map { ($0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true ? 1 : 0) + ($0.inlinePresentationIntent?.contains(.emphasized) == true ? 2 : 0) }
        try check(nestedStyles == [0, 1, 3, 1, 0], "Nested strong/emphasis ancestry must combine without losing mixed plain spans; got \(try inlineMarkdown(nested)): \(nestedStyles)")
        let unicodeInline = InlineFixtureSource(text: "x🙂强yz", intervals: [
            WebInlineInterval(start: 0, end: 1),
            WebInlineInterval(start: 1, end: 4, traits: WebInlineTraits(strong: true)),
            WebInlineInterval(start: 4, end: 6)
        ], selection: 1..<5)
        try check(try inlineMarkdown(unicodeInline) == "**🙂强**y", "Inline offsets count UTF-16 across emoji and Chinese text")
        let missingSubrole = InlineFixtureSource(text: "plain", intervals: [WebInlineInterval(start: 0, end: 5)], selection: 0..<5)
        try check(try inlineMarkdown(missingSubrole) == "plain", "A leaf with no semantic subrole remains plain and does not force capture fallback")
        let gap = InlineFixtureSource(text: "a b", intervals: [
            WebInlineInterval(start: 0, end: 1, traits: WebInlineTraits(strong: true)),
            WebInlineInterval(start: 2, end: 3, traits: WebInlineTraits(emphasized: true))
        ], selection: 0..<3)
        try check(try inlineMarkdown(gap) == "**a** *b*", "An interval gap retains its exact selected text and receives no adjacent semantic style")
        let stuckInline = InlineFixtureSource(text: "a", intervals: [], selection: 0..<1); stuckInline.stuck = true
        do {
            _ = try inline(stuckInline)
            try check(false, "Inline metadata must make forward progress")
        } catch WebSelectionFailure.noProgress { checks += 1 }
        try check(stuckInline.reads.isEmpty, "No inline text query when leaf navigation is stuck")
        let limitedInline = InlineFixtureSource(text: mixed.text, intervals: mixed.intervals, selection: 0..<17)
        do {
            _ = try inline(limitedInline, maximumIntervals: 1)
            try check(false, "Inline leaf count has a finite metadata budget")
        } catch WebSelectionFailure.limitExceeded { checks += 1 }
        let expiredInline = InlineFixtureSource(text: "a", intervals: [WebInlineInterval(start: 0, end: 1)], selection: 0..<1)
        do {
            _ = try inline(expiredInline, deadline: 0)
            try check(false, "Expired inline capture must fail before any work")
        } catch WebSelectionFailure.timedOut { checks += 1 }
        try check(expiredInline.reads.isEmpty, "Expired inline capture cannot request text")
        let slowInline = InlineFixtureSource(text: "a", intervals: [WebInlineInterval(start: 0, end: 1)], selection: 0..<1); slowInline.delayRead = true
        do {
            _ = try inline(slowInline, deadline: ProcessInfo.processInfo.systemUptime + 0.01)
            try check(false, "An inline text query that exceeds the remaining deadline must not publish")
        } catch WebSelectionFailure.timedOut { checks += 1 }
        let invalidInline = InlineFixtureSource(text: "a", intervals: [WebInlineInterval(start: 0, end: 1)], selection: 0..<1); invalidInline.wrongText = true
        do {
            _ = try inline(invalidInline)
            try check(false, "Inline span text must exactly reconstruct the captured paragraph")
        } catch WebSelectionFailure.invalidContent { checks += 1 }
        // The measured Claude selection exposed 1,501 UTF-16 characters and
        // these nine semantic strong ranges despite size-only font metadata.
        // Use neutral synthetic content to retain that shape without storing
        // the user's selected conversation.
        let observedStrong = [0..<36, 39..<83, 326..<356, 435..<459, 728..<777, 934..<959, 961..<985, 1071..<1091, 1119..<1149]
        let shapeText = String(repeating: "x", count: 1_501)
        let boundaries = Array(Set([0, 1_501] + observedStrong.flatMap { [$0.lowerBound, $0.upperBound] })).sorted()
        let shapeIntervals = zip(boundaries, boundaries.dropFirst()).map { start, end in
            WebInlineInterval(start: start, end: end, traits: WebInlineTraits(strong: observedStrong.contains(where: { $0.contains(start) })))
        }
        let observedShape = InlineFixtureSource(text: shapeText, intervals: shapeIntervals, selection: 0..<1_501)
        let shapeAttributed = try inline(observedShape)
        var actualStrong: [Range<Int>] = []
        shapeAttributed.enumerateAttribute(WebSemanticStyle.strong, in: NSRange(location: 0, length: 1_501)) { value, range, _ in
            if (value as? NSNumber)?.boolValue == true { actualStrong.append(range.location..<(range.location + range.length)) }
        }
        try check(actualStrong == observedStrong, "Size-only source metadata plus actual nine-span semantic shape must preserve exact UTF-16 strong ranges")
        for (text, emphasized, expected) in [("前重点后", "重点", "前*重点*后"), ("preitalicfix", "italic", "pre*italic*fix")] {
            let italic = NSMutableAttributedString(string: text)
            italic.addAttribute(.accessibilityFont, value: ["AXFontItalic": true], range: (text as NSString).range(of: emphasized))
            let markdown = WebSelectionMarkdown.render(italic, context: WebParagraphContext())
            try check(markdown == expected, "Use single-star emphasis next to Chinese text and inside English words")
            let parsed = try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            let italicText = parsed.runs.filter { $0.inlinePresentationIntent?.contains(.emphasized) == true }.map { String(parsed.characters[$0.range]) }.joined()
            try check(italicText == emphasized, "Generated emphasis must render through Foundation's actual Markdown parser")
        }
        for styles in [[1, 2], [2, 1], [1, 3], [3, 1], [2, 3], [3, 2]] {
            let adjacent = NSMutableAttributedString(string: "ab")
            for (index, style) in styles.enumerated() {
                adjacent.addAttribute(.accessibilityFont, value: ["AXFontBold": style & 1 != 0, "AXFontItalic": style & 2 != 0], range: NSRange(location: index, length: 1))
            }
            let markdown = WebSelectionMarkdown.render(adjacent, context: WebParagraphContext())
            let parsed = try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            var actualStyles: [Int] = []
            for run in parsed.runs {
                let style = (run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true ? 1 : 0) + (run.inlinePresentationIntent?.contains(.emphasized) == true ? 2 : 0)
                actualStyles += Array(repeating: style, count: parsed.characters[run.range].count)
            }
            try check(actualStyles == styles, "Adjacent bold/italic runs must preserve actual parser intents: \(markdown)")
        }
        // AX may expose each HTML cell as a paragraph while SelectedText has
        // no tabs or newlines. Cell metadata must recover that real grid.
        func tableFixture(_ values: [[String]] = [["Metric", "Before", "After"], ["Count", "12", "8"], ["Rate", "50%", "60%"]], complete: Bool = true, selectedCharacters: Int? = nil, tableCharacters: Int? = nil, span: Int = 1) -> FixtureSource {
            let attributed = NSMutableAttributedString(string: values.flatMap { $0 }.joined())
            var offset = 0
            var ends: [Int] = []
            for (row, cells) in values.enumerated() {
                for (column, value) in cells.enumerated() {
                    let range = NSRange(location: offset, length: value.utf16.count)
                    if range.length > 0 {
                        var metadata: [String: Any] = ["table": 1, "row": row, "column": column,
                            "rows": values.count, "columns": cells.count, "rowSpan": 1, "columnSpan": span,
                            "complete": complete]
                        if let tableCharacters { metadata["tableCharacters"] = tableCharacters }
                        attributed.addAttribute(NSAttributedString.Key("ParagraphSemanticTableCell"), value: metadata as NSDictionary, range: range)
                    }
                    offset += range.length
                    ends.append(offset)
                }
            }
            return FixtureSource(text: attributed, ends: ends, contexts: [], selection: 0..<(selectedCharacters ?? offset))
        }
        let fullTable = tableFixture()
        let tableResult = try WebSelectionTraversal.capture(source: fullTable, start: 0, end: fullTable.selection.upperBound)
        try check(tableResult == "| Metric | Before | After |\n| --- | --- | --- |\n| Count | 12 | 8 |\n| Rate | 50% | 60% |", "HTML table row and column metadata must survive flattened selected text; got \(tableResult.debugDescription)")
        try check(fullTable.reads.count == 9 && fullTable.reads.allSatisfy { fullTable.selection.contains($0.lowerBound) && $0.upperBound <= fullTable.selection.upperBound }, "Table reconstruction cannot request unselected text")
        let emptyHeaderValues = [["", "Before", "After"], ["Count", "12", "8"]]
        let tableCharacters = emptyHeaderValues.flatMap { $0 }.joined().utf16.count
        let samePositionTable = tableFixture(emptyHeaderValues, complete: false, tableCharacters: tableCharacters)
        let samePositionMarkdown = try WebSelectionTraversal.capture(source: samePositionTable, start: 0, end: samePositionTable.selection.upperBound)
        try check(samePositionMarkdown == "|  | Before | After |\n| --- | --- | --- |\n| Count | 12 | 8 |", "Same-table anchor index metadata plus exact selected-cell coverage proves a full table and preserves the genuinely blank first header")
        let partialTable = tableFixture(emptyHeaderValues, complete: false, selectedCharacters: tableCharacters - 1, tableCharacters: tableCharacters)
        do {
            _ = try WebSelectionTraversal.capture(source: partialTable, start: 0, end: partialTable.selection.upperBound)
            try check(false, "Missing even one table character cannot be published as a complete Markdown grid")
        } catch WebSelectionFailure.unsupportedTable { checks += 1 }
        try check(partialTable.reads.allSatisfy { $0.upperBound <= partialTable.selection.upperBound }, "A partial table cannot be repaired by reading beyond the selection")
        let mergedTable = tableFixture(span: 2)
        do {
            _ = try WebSelectionTraversal.capture(source: mergedTable, start: 0, end: mergedTable.selection.upperBound)
            try check(false, "Merged cells must not invent an ordinary rectangular table")
        } catch WebSelectionFailure.unsupportedTable { checks += 1 }
        let aliasEnd = InlineFixtureSource(text: "plain strong tail", intervals: mixed.intervals, selection: 0..<17)
        let aliasAttributed = try WebSelectionInlineTraversal.applying(to: NSAttributedString(string: aliasEnd.text), source: aliasEnd,
            start: 0, end: 18, deadline: ProcessInfo.processInfo.systemUptime + 1)
        try check(aliasAttributed.string == aliasEnd.text && aliasEnd.reads == [0..<6, 6..<12, 12..<17], "A text-equivalent final marker with a distinct opaque representation cannot force a read past the captured paragraph")
        let legitimateObject = simple("literal \u{FFFC} object")
        try check(try WebSelectionTraversal.capture(source: legitimateObject, start: 0, end: legitimateObject.selection.upperBound) == "literal \u{FFFC} object", "A legitimate object-replacement character outside an explicitly identified table must remain intact")
        let loneObject = simple("\u{FFFC}")
        try check(try WebSelectionTraversal.capture(source: loneObject, start: 0, end: 1) == "\u{FFFC}", "A standalone legitimate object character cannot be treated as a table placeholder without owner metadata")
        let explicitTableObject = NSMutableAttributedString(string: "\u{FFFC}", attributes: [WebSemanticStyle.tableObject: ["table": 1] as NSDictionary])
        explicitTableObject.append(fullTable.text)
        let ownedObject = FixtureSource(text: explicitTableObject, ends: [1] + fullTable.ends.map { $0 + 1 }, contexts: [], selection: 0..<explicitTableObject.length)
        try check(try WebSelectionTraversal.capture(source: ownedObject, start: 0, end: ownedObject.selection.upperBound) == tableResult, "Only an explicitly AXTable-owned object marker is removed after exact selected text has been read")
        let multilineTemplate = tableFixture([["H"], ["ABCD"]], complete: false, tableCharacters: 5)
        let multilineCells = FixtureSource(text: multilineTemplate.text, ends: [1, 3, 5], contexts: [], selection: 0..<5)
        try check(try WebSelectionTraversal.capture(source: multilineCells, start: 0, end: 5) == "| H |\n| --- |\n| AB<br>CD |", "Paragraph boundaries inside one table cell become breaks without corrupting source-character coverage proof")
        let pipeCells = tableFixture([["A | B"], ["x\\y\nz"]])
        try check(try WebSelectionTraversal.capture(source: pipeCells, start: 0, end: pipeCells.selection.upperBound) == "| A \\| B |\n| --- |\n| x\\\\y<br>z |", "Literal pipes, backslashes and cell line breaks must remain valid Markdown cells")
        let strongCells = NSMutableAttributedString(attributedString: fullTable.text)
        strongCells.addAttribute(WebSemanticStyle.strong, value: true, range: (strongCells.string as NSString).range(of: "Count"))
        let strongTable = FixtureSource(text: strongCells, ends: fullTable.ends, contexts: [], selection: fullTable.selection)
        try check(try WebSelectionTraversal.capture(source: strongTable, start: 0, end: strongTable.selection.upperBound).contains("| **Count** | 12 | 8 |"), "Table reconstruction must retain the existing leaf-level semantic strong capture")
        let paragraphAlias = simple("text")
        paragraphAlias.selectedTextLength = 4
        try check(try WebSelectionTraversal.capture(source: paragraphAlias, start: 0, end: 5) == "text", "A full exact SelectedText projection terminates paragraph traversal when a different final AX anchor denotes the same textual boundary")
        try check(paragraphAlias.reads == [0..<4], "Equivalent end anchors cannot cause an extra paragraph or out-of-selection text read")
        let objectCell = WebTableCellContext(table: 0, row: 0, column: 0, rows: 1, columns: 1, complete: false, tableCharacters: 1)
        let objectGap = InlineFixtureSource(text: "\u{FFFC}H", intervals: [WebInlineInterval(start: 1, end: 2, traits: WebInlineTraits(tableCell: objectCell))], selection: 0..<2)
        objectGap.ownedTableObjectGaps = [0..<1]
        let gapAttributed = try inline(objectGap)
        try check(try WebSelectionMarkdown.renderBlocks([(gapAttributed, WebParagraphContext())]) == "| H |\n| --- |", "A one-character selected object gap is removed only when the next cell's own table start marker lies inside it")
        let unrelatedGap = InlineFixtureSource(text: objectGap.text, intervals: objectGap.intervals, selection: 0..<2)
        let unrelatedAttributed = try inline(unrelatedGap)
        try check(try WebSelectionMarkdown.renderBlocks([(unrelatedAttributed, WebParagraphContext())]) == "\u{FFFC}\n\n| H |\n| --- |", "An identical character adjacent to a table must remain if the table's start metadata does not establish ownership")
        for content in ["\u{FFFC}", "before \u{FFFC} after"] {
            let objectOnly = NSMutableAttributedString(string: content)
            objectOnly.addAttribute(WebSemanticStyle.tableObject, value: ["table": 9] as NSDictionary, range: (content as NSString).range(of: "\u{FFFC}"))
            do {
                _ = try WebSelectionMarkdown.renderBlocks([(objectOnly, WebParagraphContext())])
                try check(false, "A table-owned object cannot disappear if its table cells were not fully recovered")
            } catch WebSelectionFailure.unsupportedTable { checks += 1 }
        }
        let wrongOwnerObject = NSMutableAttributedString(string: "\u{FFFC}", attributes: [WebSemanticStyle.tableObject: ["table": 9] as NSDictionary])
        wrongOwnerObject.append(fullTable.text)
        do {
            _ = try WebSelectionMarkdown.renderBlocks([(wrongOwnerObject, WebParagraphContext())])
            try check(false, "A different recovered table cannot justify removing this object's table marker")
        } catch WebSelectionFailure.unsupportedTable { checks += 1 }
        let defaults = SelectedPassage(text: "plain", bounds: nil)
        try check(!defaults.plainFallback && defaults.fallbackReason == nil, "Existing manual-selection callers retain their defaults")
        let failures: [WebSelectionFailure] = [.unsupported, .invalidRange, .comparisonUnavailable, .invalidContent, .noProgress, .limitExceeded, .timedOut, .selectionChanged, .accessibilityError(-25204)]
        try check(failures.allSatisfy { $0.fallbackReason.contains("已回退到普通选区文字") }, "Every capture failure exposes an explicit fallback reason")
        print("Web selection traversal: \(checks) checks passed")
    }
}

import XCTest
@testable import TranslatorCore

final class MarkdownTableTests: XCTestCase {
    func testParsesHeaderAlignmentAndInlineCells() throws {
        let table = try XCTUnwrap(parse("| Item | **Status** | Count |\n| :-- | :-: | --: |\n| Sample | *Ready* | 12 |"))
        XCTAssertEqual(table.columnCount, 3)
        XCTAssertEqual(table.alignments, [.left, .center, .right])
        XCTAssertEqual(table.sourceLines, 0..<3)
        XCTAssertEqual(table.header.cells.map(\.markdown), ["Item", "**Status**", "Count"])
        XCTAssertTrue(table.header.cells[1].content.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertEqual(table.rows[0].cells.map(\.markdown), ["Sample", "*Ready*", "12"])
    }

    func testOptionalOuterPipesAndSingleDashDelimiterAreSupported() throws {
        let table = try XCTUnwrap(parse("Name | Value\n:- | -:\nalpha | beta"))
        XCTAssertEqual(table.alignments, [.left, .right])
        XCTAssertEqual(table.rows[0].cells.map(\.markdown), ["alpha", "beta"])
    }

    func testEmptyHeaderAndEmptyCellsAreNotDiscarded() throws {
        let table = try XCTUnwrap(parse("| | Value | |\n| - | - | - |\n|| two ||"))
        XCTAssertEqual(table.header.cells.map(\.markdown), ["", "Value", ""])
        XCTAssertEqual(table.rows[0].cells.map(\.markdown), ["", "two", ""])
    }

    func testEscapedPipesDoNotSplitEvenInsideCodeAndEmphasis() throws {
        let table = try XCTUnwrap(parse(#"| f\|oo | Data |"# + "\n| - | - |\n" + #"| b `\|` az | **\|** |"#))
        XCTAssertEqual(table.header.cells.count, 2)
        XCTAssertEqual(String(table.header.cells[0].content.characters), "f|oo")
        XCTAssertEqual(String(table.rows[0].cells[0].content.characters), "b | az")
        XCTAssertEqual(String(table.rows[0].cells[1].content.characters), "|")
        XCTAssertTrue(table.rows[0].cells[0].content.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }

    func testEvenBackslashesBeforePipeAllowASeparator() throws {
        let table = try XCTUnwrap(parse("A | B\n- | -\n" + #"a\\|b"#))
        XCTAssertEqual(table.rows[0].cells.map(\.markdown), [#"a\\"#, "b"])
    }

    func testInlineHTMLBreaksBecomeCellLineBreaksOutsideCodeOnly() throws {
        let table = try XCTUnwrap(parse("| A | B |\n| - | - |\n| one<br>two<BR />three | `<br>` and ``<br/>`` |"))
        XCTAssertEqual(String(table.rows[0].cells[0].content.characters), "one\ntwo\nthree")
        XCTAssertEqual(String(table.rows[0].cells[1].content.characters), "<br> and <br/>")
        XCTAssertEqual(table.rows[0].cells[0].markdown, "one<br>two<BR />three")
    }

    func testCellRangesUseUTF16AndPreserveSourceSpacing() throws {
        let table = try XCTUnwrap(parse("| 项目 | 数量 |\n| - | - |\n  | 😀组合 |  12  | "))
        let row = table.rows[0]
        XCTAssertEqual(row.sourceLine, 2)
        XCTAssertEqual(row.source, "  | 😀组合 |  12  | ")
        XCTAssertEqual(row.cells.map { (row.source as NSString).substring(with: $0.sourceRange) }, ["😀组合", "12"])
        let rebuilt = NSMutableString(string: row.source)
        for (cell, replacement) in zip(row.cells, ["示例", "34"]).reversed() {
            rebuilt.replaceCharacters(in: cell.sourceRange, with: replacement)
        }
        XCTAssertEqual(rebuilt as String, "  | 示例 |  34  | ")
    }

    func testHeaderAndDelimiterMustHaveEqualColumnCounts() {
        XCTAssertNil(parse("| A | B |\n| --- |\n| C |"))
        XCTAssertNil(parse("A | B\n- | invalid\nC | D"))
        XCTAssertNil(parse("A | B\n: | -:\nC | D"))
    }

    func testBodyShortRowsPadAndLongRowsIgnoreExtraForDisplayOnly() throws {
        let table = try XCTUnwrap(parse("| A | B |\n| - | - |\n| C |\n| D | E | F |\nplain"))
        XCTAssertEqual(table.rows.count, 3)
        XCTAssertEqual(table.displayedCells(in: table.rows[0]).map(\.markdown), ["C", ""])
        XCTAssertEqual(table.displayedCells(in: table.rows[1]).map(\.markdown), ["D", "E"])
        XCTAssertEqual(table.rows[1].cells.map(\.markdown), ["D", "E", "F"])
        XCTAssertEqual(table.displayedCells(in: table.rows[2]).map(\.markdown), ["plain", ""])
    }

    func testBodyMayBeEmptyAndStopsAtBlankOrAnotherBlock() throws {
        let table = try XCTUnwrap(parse("A | B\n- | -\n# After | heading"))
        XCTAssertEqual(table.rows.count, 0)
        XCTAssertEqual(table.sourceLines, 0..<2)
        let beforeBlank = try XCTUnwrap(parse("A | B\n- | -\nx | y\n\nz | w"))
        XCTAssertEqual(beforeBlank.rows.count, 1)
        for ending in ["> Quote | text", "- Item | text", "1. Item | text", "```swift", "***"] {
            let stopped = try XCTUnwrap(parse("A | B\n- | -\nx | y\n" + ending))
            XCTAssertEqual(stopped.rows.count, 1, ending)
        }
    }

    func testOrdinaryTextAndFourSpaceIndentedCodeAreNotTables() {
        XCTAssertNil(parse("Title\n---\nbody"))
        XCTAssertNil(parse("    A | B\n    - | -\n    C | D"))
        XCTAssertNil(parse("A | B\nparagraph\nC | D"))
    }

    func testBlocksGroupTableAndKeepSurroundingSpacingAndLists() throws {
        let blocks = FormattedText.blocks(from: "# Intro\n\n| A | B |\n| - | - |\n| C | D |\n\n\n- After")
        XCTAssertEqual(blocks.count, 3)
        guard blocks.count == 3, case .line(let intro) = blocks[0],
              case .table(let table) = blocks[1], case .line(let after) = blocks[2] else {
            return XCTFail("Expected heading, grouped table, and list")
        }
        XCTAssertEqual(intro.headingLevel, 1)
        XCTAssertEqual(table.blankLinesBefore, 1)
        XCTAssertEqual(table.header.sourceLine, 2)
        XCTAssertEqual(table.delimiterLineIndex, 3)
        XCTAssertEqual(table.delimiterSource, "| - | - |")
        XCTAssertEqual(after.marker, "•")
        XCTAssertEqual(after.blankLinesBefore, 2)
    }

    func testBlocksDoNotTurnFencedCodeIntoATable() {
        for fence in ["```", "~~~~"] {
            let blocks = FormattedText.blocks(from: fence + "markdown\nA | B\n- | -\nC | D\n" + fence)
            XCTAssertEqual(blocks.count, 5)
            XCTAssertFalse(blocks.contains { if case .table = $0 { return true }; return false })
        }
    }

    func testSharedScannerRequiresMatchingFenceAndThenFindsFollowingTable() {
        let lines = ["````markdown", "A | B", "- | -", "```", "C | D", "- | -", "````", "", "E | F", "- | -"]
        let tables = MarkdownTable.tables(in: lines)
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables.first?.sourceLines, 8..<10)
        XCTAssertEqual(tables.first?.blankLinesBefore, 1)
    }

    func testListContainedFencedCodeDoesNotBecomeTableOrHideFollowingTable() {
        for prefix in ["- ", "1. ", "> - "] {
            let indent = prefix == "> - " ? ">   " : String(repeating: " ", count: prefix.count)
            let lines = [prefix + "```markdown", indent + "A | B", indent + "- | -", indent + "C | D", indent + "```", "", "E | F", "- | -"]
            let tables = MarkdownTable.tables(in: lines)
            XCTAssertEqual(tables.count, 1, prefix)
            XCTAssertEqual(tables.first?.sourceLines, 6..<8, prefix)
        }
    }

    func testContainerFenceStopsAtContainerBoundaryEvenWithoutClosingFence() {
        for (opening, body) in [("- ```", "  "), ("> ```", "> "), ("- > ```", "  > ")] {
            let tables = MarkdownTable.tables(in: [opening, body + "A | B", body + "- | -", body + "C | D", "", "E | F", "- | -"])
            XCTAssertEqual(tables.count, 1, opening)
            XCTAssertEqual(tables.first?.sourceLines, 5..<7, opening)
        }
    }

    func testEscapedHTMLBreakIsLiteralAndSharesCountWithRenderedBreaks() throws {
        let table = try XCTUnwrap(parse("| A | B |\n| - | - |\n" + #"| one\<br>two<br>three | `<br>` and **four<br/>five** |"#))
        XCTAssertEqual(String(table.rows[0].cells[0].content.characters), "one<br>two\nthree")
        XCTAssertEqual(MarkdownTable.inlineBreakCount(in: table.rows[0].cells[0].markdown), 1)
        XCTAssertEqual(MarkdownTable.inlineBreakCount(in: table.rows[0].cells[1].markdown), 1)
        XCTAssertEqual(MarkdownTable.inlineBreakCount(in: #"one\\<br>two"#), 1)
        XCTAssertEqual(MarkdownTable.inlineBreakCount(in: #"one\\\<br>two"#), 0)
    }

    func testNewlineNormalizationMatchesLegacyLines() {
        let blocks = FormattedText.blocks(from: "A | B\r\n- | -\r\nC | D\r\n\r\nAfter")
        XCTAssertEqual(blocks.count, 2)
        guard blocks.count == 2, case .table(let table) = blocks[0], case .line(let after) = blocks[1] else { return XCTFail() }
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(after.blankLinesBefore, 1)
        XCTAssertEqual(FormattedText.lines(from: "A | B\n- | -\nC | D").count, 3)
    }

    private func parse(_ source: String) -> MarkdownTable.Table? {
        MarkdownTable.parse(lines: source.components(separatedBy: "\n"), startingAt: 0)
    }
}

import XCTest
@testable import TranslatorCore

final class FormattedTextTests: XCTestCase {
    func testHeadingParagraphAndNestedListsRemainSeparateRows() {
        let rows = FormattedText.lines(from: "# Heading\n\nParagraph.\n\n- Outer\n    1. Inner")
        XCTAssertEqual(rows.count, 4)
        guard rows.count == 4 else { return }
        XCTAssertEqual(rows[0].headingLevel, 1)
        XCTAssertEqual(rows[1].blankLinesBefore, 1)
        XCTAssertEqual(rows[2].marker, "•")
        XCTAssertEqual(rows[3].marker, "1.")
        XCTAssertEqual(rows[3].indentation, 4)
        XCTAssertEqual(String(rows[3].content.characters), "Inner")
    }

    func testInlineBoldIsRenderedAsEmphasisInsteadOfLiteralStars() {
        let row = FormattedText.lines(from: "请保留**关键结论**与正文。")[0]
        XCTAssertEqual(String(row.content.characters), "请保留关键结论与正文。")
        XCTAssertTrue(row.content.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    func testChineseEmphasisWithTrailingPunctuationRendersWithoutLiteralMarkers() {
        let row = FormattedText.lines(from: "**重要：**正文和*提示：*后文")[0]
        XCTAssertEqual(String(row.content.characters), "重要：正文和提示：后文")
        XCTAssertTrue(row.content.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(row.content.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
    }

    func testCRLFDoesNotDoubleTheParagraphSpacing() {
        let rows = FormattedText.lines(from: "One\r\n\r\nTwo")
        XCTAssertEqual(rows.count, 2)
        guard rows.count == 2 else { return }
        XCTAssertEqual(rows[1].blankLinesBefore, 1)
    }

    func testTwoSpaceNestedListDoesNotFlattenToOuterLevel() {
        let rows = FormattedText.lines(from: "- Outer\n  - Inner")
        XCTAssertEqual(rows.count, 2)
        guard rows.count == 2 else { return }
        XCTAssertGreaterThan(rows[1].indentation, rows[0].indentation)
    }
}

import XCTest
@testable import TranslatorCore

final class TranslationTableLayoutTests: XCTestCase {
    func testTranslatesTableCellsAndPreservesFramingAlignmentAndMixedNewlines() throws {
        let source = "# Results\r\n\r\n| Metric | **Group A** | Group B |\r\n| :--- | ---: | :---: |\r\n| Score | 3 / 4 (avg 3.5) | 7/7, 58.7 |\r\n|  | 60% | [docs](https://example.com) |\n"
        let layout = TranslationLayout(source: source)
        XCTAssertEqual(layout.paragraphs, ["Results", "Metric", "**Group A**", "Group B", "Score", "3 / 4 (avg 3.5)", "[docs](https://example.com)"])
        let response = #"{"translations":["结果","指标","**甲组**","乙组","得分","3 / 4（平均 3.5）","[文档](https://example.com)"]}"#
        XCTAssertEqual(try layout.render(response: response), "# 结果\r\n\r\n| 指标 | **甲组** | 乙组 |\r\n| :--- | ---: | :---: |\r\n| 得分 | 3 / 4（平均 3.5） | 7/7, 58.7 |\r\n|  | 60% | [文档](https://example.com) |\n")
    }

    func testTableWithoutOuterPipesAndUnicodeCellsKeepsExactSourceSpacing() throws {
        let layout = TranslationLayout(source: "🚀 Name\t |\tStatus \n:--|--:\n Café | Ready \n")
        XCTAssertEqual(layout.paragraphs, ["🚀 Name", "Status", "Café", "Ready"])
        XCTAssertEqual(try layout.render(response: #"{"translations":["🚀 名称","状态","咖啡馆","就绪"]}"#), "🚀 名称\t |\t状态 \n:--|--:\n 咖啡馆 | 就绪 \n")
    }

    func testEmptyAndNumericCellsNeedNoTranslationItems() throws {
        let source = "|  | 10 |\n| --- | ---: |\n|  | 57% |\n| -3.5 | 3 / 4 |"
        let layout = TranslationLayout(source: source)
        XCTAssertEqual(layout.paragraphs, [])
        XCTAssertEqual(try layout.render(response: #"{"translations":[]}"#), source)
        XCTAssertEqual(layout.renderPartial(response: #"{"translations":[]}"#), source)
    }

    func testMultilineAndLinkedNumericCellsRemainFixedWithoutTranslationItems() throws {
        let source = "| **10** | 20 |\n| --- | --- |\n| 1<br>2 | [57%](https://example.com) |\n| <br> | |"
        let layout = TranslationLayout(source: source)
        XCTAssertEqual(layout.paragraphs, [])
        XCTAssertEqual(try layout.render(response: #"{"translations":[]}"#), source)
    }

    func testCodeFencesContainingPipesAreNotParsedAsTables() {
        let source = "```markdown\n| Name | Value |\n| --- | --- |\n| Example | 10 |\n```\n\nReal | Table\n--- | ---\nLabel | 20"
        let layout = TranslationLayout(source: source)
        XCTAssertEqual(layout.paragraphs, ["```markdown", "| Name | Value |", "| --- | --- |", "| Example | 10 |", "```", "Real", "Table", "Label"])
    }

    func testRejectsUnescapedPipesNewlinesAndChangedTableNumbers() {
        let layout = TranslationLayout(source: "| Note |\n| --- |\n| avg 3.7 |")
        for response in [
            #"{"translations":["备注 | 多余列","平均 3.7"]}"#,
            #"{"translations":["备注","平均\n3.7"]}"#,
            #"{"translations":["备注","平均 3.8"]}"#,
            #"{"translations":["备注","平均"]}"#,
            #"{"translations":["备注","平均 3.7\\"]}"#
        ] {
            XCTAssertThrowsError(try layout.render(response: response), response)
        }
    }

    func testPreservesInlineFormattingAndEscapedPipeWithinCells() throws {
        let source = "| **Name** | Note |\n| --- | --- |\n| *Start* | `A\\|B`: [docs](https://example.com) |"
        let layout = TranslationLayout(source: source)
        let response = #"{"translations":["**名称**","备注","*开始*","`A\\|B`：[文档](https://example.com)"]}"#
        XCTAssertEqual(try layout.render(response: response), "| **名称** | 备注 |\n| --- | --- |\n| *开始* | `A\\|B`：[文档](https://example.com) |")
        XCTAssertThrowsError(try layout.render(response: #"{"translations":["名称","备注","*开始*","`A\\|B`：[文档](https://example.com)"]}"#))
    }

    func testTableNumericValidationKeepsSignsAndPercentagesWhileAllowingSpacing() throws {
        let layout = TranslationLayout(source: "| Note |\n| --- |\n| change -3.7, share 57 % |")
        XCTAssertEqual(try layout.render(response: #"{"translations":["备注","变化 -3.7，占比 57%"]}"#), "| 备注 |\n| --- |\n| 变化 -3.7，占比 57% |")
        XCTAssertThrowsError(try layout.render(response: #"{"translations":["备注","变化 3.7，占比 57%"]}"#))
        XCTAssertThrowsError(try layout.render(response: #"{"translations":["备注","变化 -3.7，占比 57"]}"#))
    }

    func testTableCellRetainsInlineBreaksRatherThanMergingItsParagraphs() throws {
        let layout = TranslationLayout(source: "| Note |\n| --- |\n| first<br>second<br/>third |")
        let valid = #"{"translations":["备注","第一<BR />第二<br>第三"]}"#
        XCTAssertEqual(try layout.render(response: valid), "| 备注 |\n| --- |\n| 第一<BR />第二<br>第三 |")
        for response in [
            #"{"translations":["备注","第一第二第三"]}"#,
            #"{"translations":["备注","第一<br>第二第三"]}"#,
            #"{"translations":["备注","第一<br>第二<br>第三<br>末尾"]}"#
        ] {
            XCTAssertThrowsError(try layout.render(response: response), response)
            XCTAssertNil(layout.renderPartial(response: response), response)
        }
    }

    func testTableCellCannotGainInlineBreaksThatAreAbsentInTheSource() {
        let layout = TranslationLayout(source: "| Note |\n| --- |\n| one paragraph |")
        XCTAssertThrowsError(try layout.render(response: #"{"translations":["备注","一段<br>正文"]}"#))
    }

    func testTableInlineBreakValidationDistinguishesLiteralEscapedAndCodeTags() throws {
        let escaped = TranslationLayout(source: "| Note |\n| --- |\n| first\\<br>second |")
        XCTAssertEqual(try escaped.render(response: #"{"translations":["备注","第一\\<br>第二"]}"#), "| 备注 |\n| --- |\n| 第一\\<br>第二 |")
        XCTAssertThrowsError(try escaped.render(response: #"{"translations":["备注","第一<br>第二"]}"#))

        let code = TranslationLayout(source: "| Note |\n| --- |\n| literal `<br>` then<br>next paragraph |")
        XCTAssertEqual(try code.render(response: #"{"translations":["备注","字面量`<br>`，然后<br/>下一段"]}"#), "| 备注 |\n| --- |\n| 字面量`<br>`，然后<br/>下一段 |")
        XCTAssertThrowsError(try code.render(response: #"{"translations":["备注","字面量`<br>`，然后下一段"]}"#))
    }

    func testRejectsBlockMarkersThatWouldInterruptAnUnframedTableRow() {
        let layout = TranslationLayout(source: "Name | Status\n--- | ---\nReady | 10")
        XCTAssertThrowsError(try layout.render(response: ##"{"translations":["# 名称","状态","就绪"]}"##))
        XCTAssertThrowsError(try layout.render(response: #"{"translations":["名称","状态","- 就绪"]}"#))
        XCTAssertNil(layout.renderPartial(response: ##"{"translations":["# 名称","状态"##))
        XCTAssertNil(layout.renderPartial(response: #"{"translations":["名称","状态","- 就绪"#))
    }

    func testPartialTableUsesBlankCellsAndNeverLeaksUntranslatedEnglish() {
        let layout = TranslationLayout(source: "# Results\n\n| Metric | Group |\n| :--- | ---: |\n| Score | avg 3.7 |\n\nConclusion")
        XCTAssertEqual(layout.renderPartial(response: #"{"translations":["结果"#), "# 结果")
        XCTAssertEqual(layout.renderPartial(response: #"{"translations":["结果","指"#), "# 结果\n\n| 指 |  |\n| :--- | ---: |\n|  |  |")
        XCTAssertEqual(layout.renderPartial(response: #"{"translations":["结果","指标","组别","得分","平均 3"#), "# 结果\n\n| 指标 | 组别 |\n| :--- | ---: |\n| 得分 | 平均 3 |")
    }

    func testPartialTableKeepsFixedNumericCellsAndExistingBlankCells() {
        let layout = TranslationLayout(source: "| Note | 10 |\n| --- | --- |\n| Ready | |")
        XCTAssertEqual(layout.renderPartial(response: #"{"translations":["备"#), "| 备 | 10 |\n| --- | --- |\n|  | |")
    }

    func testPartialShortBodyRowRemainsATableWhenItsOnlyCellIsPending() throws {
        let layout = TranslationLayout(source: "Name | Count\n--- | ---:\nReady")
        XCTAssertEqual(layout.renderPartial(response: #"{"translations":["名称"#), "|名称 | |\n--- | ---:\n||")
        XCTAssertEqual(try layout.render(response: #"{"translations":["名称","数量","就绪"]}"#), "名称 | 数量\n--- | ---:\n就绪")
    }

    func testPartialTableDoesNotRenderUnsafeCellBoundaries() {
        let layout = TranslationLayout(source: "| Note |\n| --- |\n| Ready |")
        XCTAssertNil(layout.renderPartial(response: #"{"translations":["备注|"#))
        XCTAssertNil(layout.renderPartial(response: #"{"translations":["备注\\"#))
        XCTAssertEqual(layout.renderPartial(response: #"{"translations":["备注\\|"#), "| 备注\\| |\n| --- |\n|  |")
    }

    func testPartialCompletedTableUsesTheStrictFinalRenderer() throws {
        let layout = TranslationLayout(source: "| Note | Count |\n| --- | ---: |\n| Ready | 10 |\n")
        let response = #"{"translations":["备注","数量","就绪"]}"#
        XCTAssertEqual(layout.renderPartial(response: response), try layout.render(response: response))
    }
}

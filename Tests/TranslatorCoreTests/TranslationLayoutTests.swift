import XCTest
@testable import TranslatorCore

final class TranslationLayoutTests: XCTestCase {
    func testRebuildsOriginalParagraphBreaksAndBlankLines() throws {
        let layout = TranslationLayout(source: "First paragraph.\n\nSecond paragraph.\n\n\nThird paragraph.")
        XCTAssertEqual(layout.paragraphs, ["First paragraph.", "Second paragraph.", "Third paragraph."])
        let translated = try layout.render(response: #"{"translations":["第一段。","第二段。","第三段。"]}"#)
        XCTAssertEqual(translated, "第一段。\n\n第二段。\n\n\n第三段。")
    }

    func testPreservesListLineBreaksAndMixedNewlineStyles() throws {
        let layout = TranslationLayout(source: "Title\r\n- First item\r\n- Second item\r\n\r\nConclusion\u{2029}Last")
        let translated = try layout.render(response: #"{"translations":["标题","第一项","第二项","结语","最后"]}"#)
        XCTAssertEqual(translated, "标题\r\n- 第一项\r\n- 第二项\r\n\r\n结语\u{2029}最后")
    }

    func testPreservesWhitespaceOnlyLinesAndOuterNewlines() throws {
        let layout = TranslationLayout(source: "\nHello\n  \nWorld\n")
        XCTAssertEqual(layout.paragraphs, ["Hello", "World"])
        XCTAssertEqual(try layout.render(response: #"{"translations":["你好","世界"]}"#), "\n你好\n  \n世界\n")
    }

    func testRejectsMergedParagraphsInsteadOfReturningCollapsedText() {
        let layout = TranslationLayout(source: "First\n\nSecond")
        XCTAssertThrowsError(try layout.render(response: #"{"translations":["第一段和第二段"]}"#))
    }

    func testRejectsAdditionalParagraphsAndEmptyTranslation() {
        let layout = TranslationLayout(source: "First")
        XCTAssertThrowsError(try layout.render(response: #"{"translations":["第一段","多余"]}"#))
        XCTAssertThrowsError(try layout.render(response: #"{"translations":[" "]}"#))
        XCTAssertThrowsError(try layout.render(response: #"{"translations":["第一行\n第二行"]}"#))
    }

    func testRejectsUnstructuredModelOutput() {
        let layout = TranslationLayout(source: "First")
        XCTAssertThrowsError(try layout.render(response: "模型返回了没有段落对应关系的纯文字"))
    }

    func testUnicodeTextIsNotTruncatedByUTF16RangeConversion() throws {
        let layout = TranslationLayout(source: "Launch 🚀 today.\n\nCafé opens tomorrow.")
        XCTAssertEqual(layout.paragraphs, ["Launch 🚀 today.", "Café opens tomorrow."])
        XCTAssertEqual(try layout.render(response: #"{"translations":["今天发射 🚀。","咖啡馆明天开业。"]}"#), "今天发射 🚀。\n\n咖啡馆明天开业。")
    }

    func testRestoresHeadingNumberingAndNestedIndentationWithoutAskingModelToRecreateThem() throws {
        let layout = TranslationLayout(source: "# Heading\n\n1. **Start:** body\n    - child")
        XCTAssertEqual(layout.paragraphs, ["Heading", "**Start:** body", "child"])
        XCTAssertEqual(try layout.render(response: #"{"translations":["标题","**开始：**正文","子项"]}"#), "# 标题\n\n1. **开始：**正文\n    - 子项")
    }

    func testRejectsTranslationThatSilentlyDropsInlineEmphasis() {
        let layout = TranslationLayout(source: "**Important:** keep the reference.")
        XCTAssertThrowsError(try layout.render(response: #"{"translations":["重要：保留参考。"]}"#))
    }

    func testRejectsDroppedItalicCodeOrChangedLinkDestination() {
        XCTAssertThrowsError(try TranslationLayout(source: "*Important*").render(response: #"{"translations":["重要"]}"#))
        XCTAssertThrowsError(try TranslationLayout(source: "`TLS`").render(response: #"{"translations":["TLS"]}"#))
        XCTAssertThrowsError(try TranslationLayout(source: "[docs](https://example.com)").render(response: #"{"translations":["[文档](https://other.example)"]}"#))
    }

    func testAcceptsTranslatedInlineStylesWithTheOriginalLinkTarget() throws {
        let layout = TranslationLayout(source: "*Important* and `TLS`: [docs](https://example.com)")
        XCTAssertEqual(try layout.render(response: #"{"translations":["*重要*和`TLS`：[文档](https://example.com)"]}"#), "*重要*和`TLS`：[文档](https://example.com)")
    }
}

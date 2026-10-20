import XCTest
@testable import TranslatorCore

final class TranslationStreamingLayoutTests: XCTestCase {
    func testShowsDecodedTranslationBeforeJSONStringAndObjectAreComplete() {
        let layout = TranslationLayout(source: "First paragraph.\n\nSecond paragraph.")
        XCTAssertNil(layout.renderPartial(response: #"{"translations":["#))
        XCTAssertEqual(layout.renderPartial(response: #"{"translations":["第一"#), "第一")
        XCTAssertEqual(layout.renderPartial(response: #"{"translations":["第一段。","第二"#), "第一段。\n\n第二")
    }

    func testRestoresHeadingNestedListAndLeadingBlankLinesWithoutShowingEnglish() {
        let layout = TranslationLayout(source: "\n# Heading\r\n\r\n1. First\r\n  - Child\nConclusion")
        XCTAssertEqual(layout.renderPartial(response: #"{"translations":["标题","第一","子"#), "\n# 标题\r\n\r\n1. 第一\r\n  - 子")
    }

    func testWaitsForTranslationRatherThanDisplayingJSONEnvelope() {
        let layout = TranslationLayout(source: "English")
        for prefix in ["", "  ", "{", #"{"trans"#, #"{"translations"#, #"{"translations":"#, #"{"translations":["#, #"{"translations":["  "#] {
            XCTAssertNil(layout.renderPartial(response: prefix), prefix)
        }
    }

    func testDecodesQuotesBackslashesAndSlashWithoutExposingEscapeSyntax() {
        let layout = TranslationLayout(source: "English")
        XCTAssertEqual(layout.renderPartial(response: #"{"translations":["引号\"与斜线\\和\/"#), "引号\"与斜线\\和/")
        XCTAssertEqual(layout.renderPartial(response: #"{"translations":["完成\\"#), "完成\\")
        XCTAssertEqual(layout.renderPartial(response: #"{"translations":["完成\"#), "完成")
    }

    func testWaitsForAllFourUnicodeEscapeDigits() {
        let layout = TranslationLayout(source: "English")
        for suffix in [#"\u"#, #"\u4"#, #"\u4e"#, #"\u4e2"#] {
            XCTAssertEqual(layout.renderPartial(response: #"{"translations":["开头"# + suffix), "开头")
        }
        XCTAssertEqual(layout.renderPartial(response: #"{"translations":["开头\u4e2d"#), "开头中")
    }

    func testCombinesUnicodeSurrogatePairsWithoutReplacementCharacters() {
        let layout = TranslationLayout(source: "English")
        for suffix in [#"\uD83D"#, #"\uD83D\"#, #"\uD83D\u"#, #"\uD83D\uDE"#] {
            XCTAssertEqual(layout.renderPartial(response: #"{"translations":["火箭"# + suffix), "火箭")
        }
        XCTAssertEqual(layout.renderPartial(response: #"{"translations":["火箭\uD83D\uDE80"#), "火箭🚀")
        XCTAssertEqual(layout.renderPartial(response: #"{"translations":["火箭🚀，咖啡 Café"#), "火箭🚀，咖啡 Café")
    }

    func testRejectsInvalidJSONStructuresAndEscapes() {
        let layout = TranslationLayout(source: "English")
        for response in [
            #"["译文""#, #"{"other":["译文""#, #"{"translations":"译文""#,
            #"{"translations":[42"#, #"{"translations":["译文\q"#,
            #"{"translations":["译文\uXX00"#, #"{"translations":["译文\uDE80"#,
            #"{"translations":["译文\uD83D中"#, #"{"translations":["译文\uD83D\u0041"#,
            #"{"translations":["译文",]}"#, #"{"translations":["译文"],"other":1}"#,
            #"{"translations":["译文"]}garbage"#
        ] {
            XCTAssertNil(layout.renderPartial(response: response), response)
        }
    }

    func testRejectsExtraItemsAsSoonAsTheResponseRequiresAnotherItem() {
        let layout = TranslationLayout(source: "English")
        XCTAssertNil(layout.renderPartial(response: #"{"translations":["译文","#))
        XCTAssertNil(layout.renderPartial(response: #"{"translations":["译文","多余"#))
        XCTAssertNil(layout.renderPartial(response: #"{"translations":["译文","多余"]}"#))
    }

    func testRejectsClosedArrayThatCanNoLongerMatchParagraphCount() {
        let layout = TranslationLayout(source: "One\nTwo")
        XCTAssertEqual(layout.renderPartial(response: #"{"translations":["一""#), "一")
        XCTAssertNil(layout.renderPartial(response: #"{"translations":["一"]"#))
        XCTAssertNil(layout.renderPartial(response: #"{"translations":[]}"#))
    }

    func testRejectsEmptyCompletedItemsAndNewlinesInsideAnItem() {
        let layout = TranslationLayout(source: "English\nSecond")
        XCTAssertNil(layout.renderPartial(response: #"{"translations":[" ","第二"#))
        XCTAssertNil(layout.renderPartial(response: #"{"translations":["译文\n第二行"#))
        XCTAssertNil(layout.renderPartial(response: #"{"translations":["译文\u2029第二行"#))
        XCTAssertNil(layout.renderPartial(response: "{\"translations\":[\"译文\n第二行"))
    }

    func testTemporarilyAllowsUnclosedInlineMarkdownWhileStreaming() {
        let layout = TranslationLayout(source: "**Important:** body")
        XCTAssertEqual(layout.renderPartial(response: #"{"translations":["**重要"#), "**重要")
        XCTAssertEqual(layout.renderPartial(response: #"{"translations":["**重要：**正"#), "**重要：**正")
        XCTAssertNil(layout.renderPartial(response: #"{"translations":["重要：正文"]}"#))
    }

    func testCompletedResponseUsesTheSameStrictRendererIncludingTrailingWhitespace() throws {
        let layout = TranslationLayout(source: "\n# Heading\n  \n- Body\n\n")
        let response = #" { "translations" : [ "标题", "正文" ] } "#
        XCTAssertEqual(layout.renderPartial(response: response), try layout.render(response: response))
    }

    func testValidJSONKeyEscapesAreAccepted() {
        let layout = TranslationLayout(source: "English")
        XCTAssertEqual(layout.renderPartial(response: #"{"translat\u0069ons":["译文"#), "译文")
    }
}

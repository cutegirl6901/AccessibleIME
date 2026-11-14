import XCTest

@testable import KeyboardCore

final class CharacterDescriptionTableTests: XCTestCase {

    // MARK: - 解析

    func testParsesTabSeparatedColumns() {
        let text = "我\t(我们的我)\t自称\n们\t(我们的们)\t复数后缀\n"
        let table = CharacterDescriptionTable.parse(text)
        XCTAssertEqual(table.description(for: "我"), "(我们的我)")
        XCTAssertEqual(table.description(for: "们"), "(我们的们)")
    }

    func testSkipsCommentsBlankLinesAndBOM() {
        let text = "\u{FEFF}# 注释\na\tAlfa\t第1个字母\n\n# 另一段注释\nb\tBravo\n"
        let table = CharacterDescriptionTable.parse(text)
        XCTAssertEqual(table.count, 2)
        XCTAssertEqual(table.description(for: "a"), "Alfa")
        XCTAssertEqual(table.description(for: "b"), "Bravo")
    }

    func testOnlyFirstDescriptionIsKept() {
        let text = "好\t(好坏的好)\t多音字【hǎo】优点多\n"
        let table = CharacterDescriptionTable.parse(text)
        XCTAssertEqual(table.description(for: "好"), "(好坏的好)")
    }

    func testSkipsRowsWhoseKeyIsNotExactlyOneCharacter() {
        // 上游存在少量脏数据行。
        let text = "我\t(我们的我)\n驆(驻驆的驆)\t古同警跸的跸\n\t空键\n"
        let table = CharacterDescriptionTable.parse(text)
        XCTAssertEqual(table.count, 1)
        XCTAssertTrue(table.contains("我"))
    }

    func testIgnoresLineWithoutTab() {
        let table = CharacterDescriptionTable.parse("没有制表符的一行\n我\t(我们的我)\n")
        XCTAssertEqual(table.count, 1)
    }

    func testHandlesCRLF() {
        let table = CharacterDescriptionTable.parse("我\t(我们的我)\r\n们\t(我们的们)\r\n")
        XCTAssertEqual(table.count, 2)
    }

    // MARK: - 单字描述

    func testStripsWrappingParentheses() {
        XCTAssertEqual(
            CharacterDescriptionSpeech.stripWrappingParentheses("(我们的我)"),
            "我们的我"
        )
    }

    func testKeepsTextWhenParenthesesAreNotWrapping() {
        XCTAssertEqual(
            CharacterDescriptionSpeech.stripWrappingParentheses("【hǎo】优点多"),
            "【hǎo】优点多"
        )
        XCTAssertEqual(
            CharacterDescriptionSpeech.stripWrappingParentheses("(a)(b)"),
            "(a)(b)"
        )
    }

    func testSpokenDescriptionUsesStrippedParenthesisedForm() {
        let table = CharacterDescriptionTable(entries: ["我": "(我们的我)"])
        XCTAssertEqual(CharacterDescriptionSpeech.spokenDescription(for: "我", table: table), "我们的我")
    }

    func testSpokenDescriptionAppendsDeAndCharacterWhenUnparenthesised() {
        // 繁体字典风格：描述本身不含括号。
        let table = CharacterDescriptionTable(entries: ["我": "我們"])
        XCTAssertEqual(CharacterDescriptionSpeech.spokenDescription(for: "我", table: table), "我們的我")
    }

    func testSpokenDescriptionFallsBackToCharacterWhenMissing() {
        let table = CharacterDescriptionTable(entries: [:])
        XCTAssertEqual(CharacterDescriptionSpeech.spokenDescription(for: "龘", table: table), "龘")
    }

    // MARK: - 组合解释

    func testPerCharacterDescriptionsForWomen() {
        let table = CharacterDescriptionTable(entries: [
            "我": "(我们的我)",
            "们": "(我们的们)",
        ])
        XCTAssertEqual(
            CharacterDescriptionSpeech.perCharacterDescriptions(for: "我们", table: table),
            ["我们的我", "我们的们"]
        )
    }

    func testPerCharacterDescriptionsDeduplicatesRepeatedCharacters() {
        let table = CharacterDescriptionTable(entries: ["的": "(目的的确的)"])
        // 「的的」不应产出两条相同的解释。
        XCTAssertEqual(
            CharacterDescriptionSpeech.perCharacterDescriptions(for: "的的", table: table),
            ["目的的确的"]
        )
    }

    func testPerCharacterDescriptionsSkipsUnknownCharacters() {
        let table = CharacterDescriptionTable(entries: ["我": "(我们的我)"])
        XCTAssertEqual(
            CharacterDescriptionSpeech.perCharacterDescriptions(for: "我龘", table: table),
            ["我们的我"]
        )
    }

    func testAnnouncementCombinesWordAndDescriptions() {
        let table = CharacterDescriptionTable(entries: [
            "我": "(我们的我)",
            "们": "(我们的们)",
        ])
        XCTAssertEqual(
            CharacterDescriptionSpeech.announcement(for: "我们", table: table),
            "我们，我们的我，我们的们"
        )
    }

    func testAnnouncementFallsBackToWordWhenNoDescriptions() {
        let table = CharacterDescriptionTable(entries: [:])
        XCTAssertEqual(CharacterDescriptionSpeech.announcement(for: "我们", table: table), "我们")
    }

    func testAnnouncementKeepsWordWhenOnlyPartiallyKnown() {
        let table = CharacterDescriptionTable(entries: ["我": "(我们的我)"])
        XCTAssertEqual(
            CharacterDescriptionSpeech.announcement(for: "我龘", table: table),
            "我龘，我们的我"
        )
    }

    func testWhitespaceIsNotDescribed() {
        let table = CharacterDescriptionTable(entries: [" ": "(空格的空)"])
        XCTAssertEqual(
            CharacterDescriptionSpeech.perCharacterDescriptions(for: "我 们", table: table),
            []
        )
    }

    // MARK: - Unicode 完整性

    func testIteratesByGraphemeClusterNotScalar() {
        // 扩展汉字（BMP 外的补充平面字符）必须整体处理。
        let ext = "𠮷"
        let table = CharacterDescriptionTable(entries: [Character(ext): "(吉的异体)"])
        let parts = CharacterDescriptionSpeech.perCharacterDescriptions(for: ext, table: table)
        XCTAssertEqual(parts, ["吉的异体"])
    }

    // MARK: - 真实资源

    func testBundledSimplifiedTableLoadsAndCoversCommonCharacters() throws {
        let table = CharacterDescriptionTable.load(languageCode: "zh_CN")
        try XCTSkipIf(table.count == 0, "资源未打包进测试 bundle")
        for character in ["我", "们", "你", "好", "中", "国"] {
            XCTAssertTrue(table.contains(Character(character)), "缺少字符：\(character)")
        }
        XCTAssertEqual(
            CharacterDescriptionSpeech.announcement(for: "我们", table: table),
            "我们，我们的我，我们的们"
        )
    }

    func testLanguageCodeMapping() {
        XCTAssertEqual(CharacterDescriptionTable.resourceName(for: "zh_CN"), "zh_CN.compact")
        XCTAssertEqual(CharacterDescriptionTable.resourceName(for: "zh-Hans"), "zh_CN.compact")
        XCTAssertEqual(CharacterDescriptionTable.resourceName(for: "zh_TW"), "zh_TW.compact")
        XCTAssertEqual(CharacterDescriptionTable.resourceName(for: "zh-Hant-HK"), "zh_TW.compact")
    }
}

import XCTest

@testable import KeyboardCore

/// 纯键盘输入路径的逐字反馈契约。
///
/// 覆盖用户报告的核心问题：只打字、不触摸候选时，确认上屏后必须能听到
/// 「词 + 逐字解释」。
final class CommittedTextAnnouncementTests: XCTestCase {

    private let table = CharacterDescriptionTable(entries: [
        "我": "(我们的我)",
        "们": "(我们的们)",
        "你": "(你们的你)",
        "好": "(好坏的好)",
        "的": "(目的的确的)",
    ])

    // MARK: - 1. 只用键盘输入并确认「我们」

    func testSpaceConfirmedWordProducesWordAndPerCharacterDescriptions() throws {
        let spoken = try XCTUnwrap(
            CommittedTextAnnouncement.announcement(
                for: "我们",
                source: .space,
                lastAnnounced: nil,
                table: table
            )
        )
        XCTAssertEqual(spoken, "我们，我们的我，我们的们")
    }

    func testReturnConfirmedWordAlsoAnnounces() throws {
        let spoken = try XCTUnwrap(
            CommittedTextAnnouncement.announcement(
                for: "我们",
                source: .returnKey,
                lastAnnounced: nil,
                table: table
            )
        )
        XCTAssertEqual(spoken, "我们，我们的我，我们的们")
    }

    func testCandidateSourceStillAnnounces() throws {
        let spoken = try XCTUnwrap(
            CommittedTextAnnouncement.announcement(
                for: "我们",
                source: .candidate,
                lastAnnounced: nil,
                table: table
            )
        )
        XCTAssertEqual(spoken, "我们，我们的我，我们的们")
    }

    // MARK: - 2. 只用键盘连续输入多个词

    func testSequentialWordsEachAnnounce() throws {
        let first = try XCTUnwrap(
            CommittedTextAnnouncement.announcement(
                for: "我们", source: .space, lastAnnounced: nil, table: table
            )
        )
        let second = try XCTUnwrap(
            CommittedTextAnnouncement.announcement(
                for: "你好", source: .space, lastAnnounced: "我们", table: table
            )
        )
        XCTAssertEqual(first, "我们，我们的我，我们的们")
        XCTAssertEqual(second, "你好，你们的你，好坏的好")
    }

    // MARK: - 3. 拼音组合与候选更新期间不误报

    func testPlainSpaceIsNeverAnnounced() {
        XCTAssertNil(
            CommittedTextAnnouncement.announcement(
                for: " ", source: .space, lastAnnounced: nil, table: table
            )
        )
    }

    func testNewlineIsNeverAnnounced() {
        XCTAssertNil(
            CommittedTextAnnouncement.announcement(
                for: "\n", source: .returnKey, lastAnnounced: nil, table: table
            )
        )
    }

    func testLatinTextIsNeverAnnounced() {
        XCTAssertNil(
            CommittedTextAnnouncement.announcement(
                for: "abc", source: .compositionFinalization, lastAnnounced: nil, table: table
            )
        )
    }

    func testPunctuationOnlyIsNeverAnnounced() {
        XCTAssertNil(
            CommittedTextAnnouncement.announcement(
                for: "，。", source: .space, lastAnnounced: nil, table: table
            )
        )
    }

    func testKeySourceIsNotAnnounced() {
        // 单个字母按键的直通提交不应触发逐字播报。
        XCTAssertFalse(CommittedTextAnnouncement.shouldAnnounce(source: .key))
        XCTAssertNil(
            CommittedTextAnnouncement.announcement(
                for: "w", source: .key, lastAnnounced: nil, table: table
            )
        )
    }

    // MARK: - 4. 触摸选词仍只播报一次（连续相同文本不重复整段）

    func testRepeatedIdenticalCommitAnnouncesWordOnlyOnce() throws {
        let first = try XCTUnwrap(
            CommittedTextAnnouncement.announcement(
                for: "我们", source: .candidate, lastAnnounced: nil, table: table
            )
        )
        let second = try XCTUnwrap(
            CommittedTextAnnouncement.announcement(
                for: "我们", source: .candidate, lastAnnounced: "我们", table: table
            )
        )
        XCTAssertEqual(first, "我们，我们的我，我们的们")
        // 第二次只读词本身，不再重复整段解释。
        XCTAssertEqual(second, "我们")
    }

    // MARK: - 5. 快速输入、删除、重新选词

    func testRapidAlternatingWordsEachGetFreshAnnouncement() throws {
        let a = try XCTUnwrap(
            CommittedTextAnnouncement.announcement(
                for: "我们", source: .space, lastAnnounced: nil, table: table
            )
        )
        let b = try XCTUnwrap(
            CommittedTextAnnouncement.announcement(
                for: "你好", source: .candidate, lastAnnounced: "我们", table: table
            )
        )
        let c = try XCTUnwrap(
            CommittedTextAnnouncement.announcement(
                for: "我们", source: .space, lastAnnounced: "你好", table: table
            )
        )
        XCTAssertEqual(a, "我们，我们的我，我们的们")
        XCTAssertEqual(b, "你好，你们的你，好坏的好")
        // 与上一条不同，应当重新给出完整解释。
        XCTAssertEqual(c, "我们，我们的我，我们的们")
    }

    func testPartialTextWithoutCodePointTableStillAnnouncesWord() throws {
        // 词中含表格未收录的字：仍应播报已收录部分，且不丢词本身。
        let spoken = try XCTUnwrap(
            CommittedTextAnnouncement.announcement(
                for: "我龘", source: .space, lastAnnounced: nil, table: table
            )
        )
        XCTAssertEqual(spoken, "我龘，我们的我")
    }

    // MARK: - 汉字判定

    func testContainsHanDetectsBasicAndExtensionBlocks() {
        XCTAssertTrue(CommittedTextAnnouncement.containsHan("我"))
        XCTAssertTrue(CommittedTextAnnouncement.containsHan("你a"))
        XCTAssertTrue(CommittedTextAnnouncement.containsHan("𠮷"))  // 扩展 B 区
        XCTAssertTrue(CommittedTextAnnouncement.containsHan("㐀"))  // 扩展 A 区
        XCTAssertFalse(CommittedTextAnnouncement.containsHan("abc"))
        XCTAssertFalse(CommittedTextAnnouncement.containsHan("，。"))
        XCTAssertFalse(CommittedTextAnnouncement.containsHan(""))
    }

    // MARK: - 来源白名单

    func testAllChineseCommitSourcesAreAnnounced() {
        let expected: [CommittedTextSource] = [
            .candidate, .correction, .engineCommit, .compositionFinalization,
            .space, .returnKey,
        ]
        for source in expected {
            XCTAssertTrue(
                CommittedTextAnnouncement.shouldAnnounce(source: source),
                "\(source) 应当播报"
            )
        }
    }

    func testNonChineseSourcesAreSilent() {
        let silent: [CommittedTextSource] = [.key, .directText, .emoji]
        for source in silent {
            XCTAssertFalse(
                CommittedTextAnnouncement.shouldAnnounce(source: source),
                "\(source) 不应播报"
            )
        }
    }
}

import XCTest

@testable import KeyboardCore

final class KeySpeechTests: XCTestCase {

    private let table = CharacterDescriptionTable(entries: [
        "你": "(你们的你)",
        "我": "(我们的我)",
        "好": "(好坏的好)",
        "们": "(我们的们)",
        "，": "逗号",
        "。": "句号",
        "A": "(字母A)",
    ])

    private func snapshot(
        kind: KeySpeechKind = .letter,
        keyLabel: String = "n",
        inputMode: InputMode = .chinese,
        page: KeyboardPage = .letters,
        shiftState: ShiftState = .off,
        composition: String = "",
        candidates: [String] = [],
        comments: [String?] = [],
        committed: String? = nil,
        deleted: String? = nil
    ) -> KeySpeechSnapshot {
        KeySpeechSnapshot(
            kind: kind,
            keyLabel: keyLabel,
            inputMode: inputMode,
            page: page,
            shiftState: shiftState,
            composition: composition,
            candidates: candidates,
            candidateComments: comments,
            committedText: committed,
            deletedText: deleted
        )
    }

    // MARK: 字母键

    func testLetterReadsKeyThenFirstCandidate() {
        let s = snapshot(composition: "n", candidates: ["你", "呢"], comments: ["nǐ", "ne"])
        XCTAssertEqual(
            KeySpeechComposer.compose(s, detail: .standard, table: table),
            "n，你，你们的你"
        )
    }

    func testLetterConciseOmitsExplanation() {
        let s = snapshot(candidates: ["你"])
        XCTAssertEqual(KeySpeechComposer.compose(s, detail: .concise, table: table), "n，你")
    }

    func testLetterDetailedIncludesPronunciation() {
        let s = snapshot(candidates: ["你"], comments: ["nǐ"])
        XCTAssertEqual(
            KeySpeechComposer.compose(s, detail: .detailed, table: table),
            "n，你，nǐ，你们的你"
        )
    }

    func testLetterFallsBackToCompositionWhenNoCandidate() {
        let s = snapshot(composition: "zh", candidates: [])
        XCTAssertEqual(KeySpeechComposer.compose(s, detail: .standard, table: table), "n，zh")
    }

    func testAppVoiceChannelOmitsKeyName() {
        // 通道 1/2 由键盘自己发声，必须只读候选，否则会和旁白的键名重叠。
        let s = snapshot(composition: "n", candidates: ["你"], comments: ["nǐ"])
        XCTAssertEqual(
            KeySpeechComposer.compose(s, detail: .standard, table: table, includeKeyName: false),
            "你，你们的你"
        )
    }

    func testAppVoiceChannelStaysSilentInEnglishMode() {
        // 英文模式没有候选；键盘不发声，交给旁白念字母。
        let s = snapshot(keyLabel: "a", inputMode: .english)
        XCTAssertNil(
            KeySpeechComposer.compose(s, detail: .standard, table: table, includeKeyName: false)
        )
    }

    func testEnglishLetterReadsKeyOnly() {
        let s = snapshot(keyLabel: "a", inputMode: .english, candidates: ["你"])
        XCTAssertEqual(KeySpeechComposer.compose(s, detail: .standard, table: table), "a")
    }

    // MARK: 候选内容从状态来，不写死

    func testCandidateTextIsNeverHardcoded() {
        let s = snapshot(candidates: ["龘"], comments: [nil])
        let spoken = KeySpeechComposer.compose(s, detail: .standard, table: table)
        XCTAssertTrue(spoken?.contains("龘") ?? false)
        // 字典里没有「龘」，不应编造解释
        XCTAssertEqual(spoken, "n，龘")
    }

    func testMultiCharacterCandidateExplainsEachUniqueCharacterOnce() {
        let s = snapshot(composition: "women", candidates: ["我们"], comments: [nil])
        XCTAssertEqual(
            KeySpeechComposer.compose(s, detail: .standard, table: table),
            "n，我们，我们的我，我们的们"
        )
    }

    // MARK: 删除 / 上屏

    func testDeleteReadsRemovedText() {
        let s = snapshot(kind: .delete, keyLabel: "删除", deleted: "你")
        XCTAssertEqual(KeySpeechComposer.compose(s, detail: .standard, table: table), "已删除 你，你们的你")
    }

    func testDeleteWithoutKnownTextIsSilent() {
        let s = snapshot(kind: .delete, keyLabel: "删除", deleted: nil)
        XCTAssertNil(KeySpeechComposer.compose(s, detail: .standard, table: table))
    }

    func testSpaceReadsCommittedText() {
        let s = snapshot(kind: .space, keyLabel: "空格", committed: "你好")
        XCTAssertEqual(
            KeySpeechComposer.compose(s, detail: .standard, table: table),
            "你好，你们的你，好坏的好"
        )
    }

    func testCandidateSelectionReadsCommittedText() {
        let s = snapshot(kind: .candidate, keyLabel: "你好", committed: "你好")
        XCTAssertEqual(
            KeySpeechComposer.compose(s, detail: .standard, table: table),
            "你好，你们的你，好坏的好"
        )
    }

    func testCandidateFallbackUsesCandidateTitle() {
        let s = snapshot(kind: .candidate, keyLabel: "你好")
        XCTAssertEqual(KeySpeechComposer.compose(s, detail: .standard, table: table), "你好")
    }

    func testSpaceWithoutCommitReadsKeyName() {
        let s = snapshot(kind: .space, keyLabel: "空格")
        XCTAssertEqual(KeySpeechComposer.compose(s, detail: .standard, table: table), "空格")
    }

    // MARK: 状态类

    func testShiftStates() {
        for (state, expected) in [
            (ShiftState.off, "小写"),
            (ShiftState.singleUse, "单次大写"),
            (ShiftState.capsLock, "大写锁定"),
        ] {
            let s = snapshot(kind: .shift, keyLabel: "", shiftState: state)
            XCTAssertEqual(KeySpeechComposer.compose(s, detail: .standard, table: table), expected)
        }
    }

    func testInputMode() {
        let zh = snapshot(kind: .inputMode, inputMode: .chinese)
        let en = snapshot(kind: .inputMode, inputMode: .english)
        XCTAssertEqual(KeySpeechComposer.compose(zh, detail: .standard, table: table), "中文输入")
        XCTAssertEqual(KeySpeechComposer.compose(en, detail: .standard, table: table), "英文输入")
    }

    func testKeyboardPage() {
        let s = snapshot(kind: .keyboardPage, page: .numbers)
        XCTAssertEqual(KeySpeechComposer.compose(s, detail: .standard, table: table), "数字键盘")
    }

    // MARK: 标点 / 数字 / 英文候选

    func testPunctuationUsesTable() {
        let s = snapshot(kind: .punctuation, keyLabel: "，")
        XCTAssertEqual(KeySpeechComposer.compose(s, detail: .standard, table: table), "逗号")
    }

    func testPunctuationFallsBackToGlyph() {
        let s = snapshot(kind: .punctuation, keyLabel: "～")
        XCTAssertEqual(KeySpeechComposer.compose(s, detail: .standard, table: table), "～")
    }

    func testDigitReadsDigit() {
        let s = snapshot(kind: .digit, keyLabel: "3")
        XCTAssertEqual(KeySpeechComposer.compose(s, detail: .standard, table: table), "3")
    }

    func testASCIICandidateIsNotSpelledOutByDictionary() {
        // 字典里有 "a" -> "Alfa"；英文候选不应被读成 NATO 字母表。
        XCTAssertEqual(
            KeySpeechComposer.referentSpeech("hello", comment: nil, detail: .standard, table: table),
            "hello"
        )
    }

    func testMixedTextKeepsWholeWordThenExplainsHan() {
        XCTAssertEqual(
            KeySpeechComposer.referentSpeech("A你", comment: nil, detail: .standard, table: table),
            "A你，字母A，你们的你"
        )
    }

    // MARK: 分类

    func testClassify() {
        XCTAssertEqual(KeySpeechComposer.classify(key: "n"), .letter)
        XCTAssertEqual(KeySpeechComposer.classify(key: "3"), .digit)
        XCTAssertEqual(KeySpeechComposer.classify(key: "，"), .punctuation)
        XCTAssertEqual(KeySpeechComposer.classify(key: "😊"), .function)
    }

    // MARK: 未知字符不编造

    func testUnknownCharacterFallsBackToItself() {
        XCTAssertEqual(
            KeySpeechComposer.referentSpeech("𠮷", comment: nil, detail: .standard, table: table),
            "𠮷"
        )
    }
}

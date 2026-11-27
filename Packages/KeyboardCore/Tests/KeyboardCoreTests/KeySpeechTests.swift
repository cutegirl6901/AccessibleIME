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

    func testQueuedChannelFallsBackToCompositionWithoutCandidates() {
        // 真机需求（2026-11-27）：每按一个键都要有反馈，不能静默。
        // 没有候选时读拼音串，让用户知道自己打出了什么。
        let s = snapshot(composition: "w", candidates: [])
        XCTAssertEqual(
            KeySpeechComposer.compose(s, detail: .standard, table: table, includeKeyName: false),
            "w"
        )
    }

    func testAppVoiceChannelStaysSilentInEnglishMode() {
        // 英文模式没有候选；键盘不发声，交给旁白念字母。
        let s = snapshot(keyLabel: "a", inputMode: .english)
        XCTAssertNil(
            KeySpeechComposer.compose(s, detail: .standard, table: table, includeKeyName: false)
        )
    }

    // MARK: 核心需求：有候选就读第一个候选

    /// 用户明确要求：输入一个字符，如果候选有内容，就播报第一个候选。
    func testAlwaysReadsFirstCandidateWhenAvailable() {
        let s = snapshot(composition: "n", candidates: ["你", "呢", "尼"])
        XCTAssertEqual(
            KeySpeechComposer.compose(s, detail: .standard, table: table, includeKeyName: false),
            "你，你们的你"
        )
    }

    /// 关键回归：不同输入必须读出不同结果。
    ///
    /// 真机上曾出现「不管输入什么，都读同一个字（我们的我）」。
    /// 这条测试锁死「输入变化 → 输出变化」这一最基本性质。
    func testDifferentInputsProduceDifferentSpeech() {
        let cases: [(comp: String, cands: [String], expectedPrefix: String)] = [
            ("n", ["你"], "你"),
            ("ni", ["你好"], "你好"),
            ("w", ["我"], "我"),
            ("h", ["好"], "好"),
        ]
        var outputs: [String] = []
        for c in cases {
            let s = snapshot(composition: c.comp, candidates: c.cands)
            let out = KeySpeechComposer.compose(
                s, detail: .concise, table: table, includeKeyName: false
            )
            XCTAssertNotNil(out, "输入 \(c.comp) 应当有播报")
            XCTAssertTrue(
                out!.hasPrefix(c.expectedPrefix),
                "输入 \(c.comp) 应读 \(c.expectedPrefix)，实际 \(out!)"
            )
            outputs.append(out!)
        }
        XCTAssertEqual(Set(outputs).count, cases.count, "不同输入不得产生相同播报")
    }

    /// 候选为空时必须退回拼音串，不能静默。
    func testFallsBackToCompositionInsteadOfSilence() {
        let s = snapshot(composition: "ni", candidates: [])
        XCTAssertEqual(
            KeySpeechComposer.compose(s, detail: .standard, table: table, includeKeyName: false),
            "ni"
        )
    }

    /// 有候选时不应读拼音，必须读候选。
    func testCandidateTakesPrecedenceOverComposition() {
        let s = snapshot(composition: "wo", candidates: ["我"])
        let out = KeySpeechComposer.compose(
            s, detail: .concise, table: table, includeKeyName: false
        )
        XCTAssertEqual(out, "我")
        XCTAssertFalse(out!.contains("wo"), "有候选时不应读出拼音串")
    }

    // MARK: 旁白通道：只补新信息，不重复键名

    func testQueuedChannelReadsFirstCandidateForLetter() {
        let s = snapshot(composition: "n", candidates: ["你"], comments: ["nǐ"])
        XCTAssertEqual(
            KeySpeechComposer.compose(s, detail: .standard, table: table, includeKeyName: false),
            "你，你们的你"
        )
    }

    func testQueuedChannelReadsCommittedDirectText() {
        // 智能引号：insertDirectText 走 .punctuation，上屏文本必须被读出来。
        let s = snapshot(kind: .punctuation, keyLabel: "“", committed: "“")
        XCTAssertEqual(
            KeySpeechComposer.compose(s, detail: .standard, table: table, includeKeyName: false),
            "“"
        )
    }

    func testQueuedChannelBareDigitWithoutCandidateIsSilent() {
        // 数字键在无候选、无组合时确实没有新信息可读，保持安静。
        let s = snapshot(kind: .digit, keyLabel: "3")
        XCTAssertNil(
            KeySpeechComposer.compose(s, detail: .standard, table: table, includeKeyName: false)
        )
    }

    func testQueuedChannelReadsCandidateForDigitInComposition() {
        // 九宫格/数字参与组字时，候选才是新信息。
        let s = snapshot(kind: .digit, keyLabel: "6", composition: "6", candidates: ["你"])
        XCTAssertEqual(
            KeySpeechComposer.compose(s, detail: .standard, table: table, includeKeyName: false),
            "你，你们的你"
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

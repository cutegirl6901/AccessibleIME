import XCTest

@testable import SpeechLogicCheck

/// 播报行为的可执行验证。
///
/// 这些测试在 Ubuntu 上就能跑（纯 Foundation），
/// 用来在每次改动后确认「按键播报读到的是本次输入、且不静默」。
final class KeySpeechBehaviorTests: XCTestCase {

    private let table = CharacterDescriptionTable(entries: [
        "你": "(你们的你)",
        "我": "(我们的我)",
        "好": "(好坏的好)",
        "们": "(我们的们)",
    ])

    private func snapshot(
        kind: KeySpeechKind = .letter,
        keyLabel: String = "n",
        inputMode: InputMode = .chinese,
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
            page: .letters,
            shiftState: .off,
            composition: composition,
            candidates: candidates,
            candidateComments: comments,
            committedText: committed,
            deletedText: deleted
        )
    }

    private func speak(_ s: KeySpeechSnapshot, includeKeyName: Bool = false) -> String? {
        KeySpeechComposer.compose(
            s, detail: .concise, table: table, includeKeyName: includeKeyName
        )
    }

    // MARK: 需求 1：有候选就读第一个候选

    func testReadsFirstCandidateWhenAvailable() {
        let s = snapshot(composition: "n", candidates: ["你", "呢", "尼"])
        XCTAssertEqual(speak(s), "你")
    }

    func testReadsOnlyFirstCandidateNotOthers() {
        let s = snapshot(composition: "wo", candidates: ["我", "握", "窝"])
        let out = speak(s) ?? ""
        XCTAssertEqual(out, "我")
        XCTAssertFalse(out.contains("握"))
        XCTAssertFalse(out.contains("窝"))
    }

    // MARK: 需求 2：不同输入必须读不同结果（锁死「永远读同一个字」）

    func testDifferentInputsProduceDifferentSpeech() {
        let cases: [(comp: String, cands: [String], expected: String)] = [
            ("n", ["你"], "你"),
            ("ni", ["你好"], "你好"),
            ("w", ["我"], "我"),
            ("h", ["好"], "好"),
        ]
        var outputs: Set<String> = []
        for c in cases {
            let out = speak(snapshot(composition: c.comp, candidates: c.cands))
            XCTAssertEqual(out, c.expected, "输入 \(c.comp) 应读 \(c.expected)")
            outputs.insert(out ?? "<nil>")
        }
        XCTAssertEqual(outputs.count, cases.count, "不同输入不得产生相同播报")
    }

    /// 同一份候选不得因重复调用而变化（防止读到外部可变状态）。
    func testRepeatedCallsAreStable() {
        let s = snapshot(composition: "n", candidates: ["你"])
        let first = speak(s)
        for _ in 0..<5 {
            XCTAssertEqual(speak(s), first)
        }
    }

    // MARK: 需求 3：没有候选时不能静默

    func testFallsBackToCompositionInsteadOfSilence() {
        let s = snapshot(composition: "ni", candidates: [])
        XCTAssertEqual(speak(s), "ni")
    }

    func testNoCandidateNoCompositionStillGivesFeedbackWhenSelfVoicing() {
        // 键盘自己发声时至少读键名
        let s = snapshot(composition: "", candidates: [])
        XCTAssertEqual(speak(s, includeKeyName: true), "n")
    }

    // MARK: 需求 4：有候选时不读拼音

    func testCandidateTakesPrecedenceOverComposition() {
        let s = snapshot(composition: "wo", candidates: ["我"])
        let out = speak(s) ?? ""
        XCTAssertEqual(out, "我")
        XCTAssertFalse(out.contains("wo"), "有候选时不应读出拼音串")
    }

    // MARK: 上屏与删除

    func testCommittedTextWinsOverCandidates() {
        let s = snapshot(kind: .candidate, keyLabel: "你", candidates: ["你"], committed: "你好")
        XCTAssertEqual(speak(s), "你好")
    }

    func testDeleteReadsRemovedText() {
        let s = snapshot(kind: .delete, keyLabel: "删除", deleted: "你")
        XCTAssertEqual(speak(s), "已删除 你")
    }

    // MARK: 英文模式

    func testEnglishLetterStaysSilentForAnnouncementChannel() {
        // 旁白自己会念字母，键盘不再补一条，避免双重朗读。
        let s = snapshot(inputMode: .english, composition: "a")
        XCTAssertNil(speak(s))
    }

    // MARK: 反漂移：枚举 case 必须与 KeyboardCore 一致

    func testSupportTypesMatchKeyboardCore() {
        // 若 KeyboardCore 增加了页面 / 模式 / 大小写状态，
        // 这里的穷举 switch 会在编译期报错，从而提醒同步副本。
        for page in [KeyboardPage.letters, .numbers, .symbols, .emoji] {
            switch page {
            case .letters, .numbers, .symbols, .emoji: break
            }
        }
        for mode in [InputMode.chinese, .english] {
            switch mode {
            case .chinese, .english: break
            }
        }
        for shift in [ShiftState.off, .singleUse, .capsLock] {
            switch shift {
            case .off, .singleUse, .capsLock: break
            }
        }
    }
}

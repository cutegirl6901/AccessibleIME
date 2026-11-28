import UIKit
import XCTest

// 本 target 通过 fileSystemSynchronizedGroups 直接编译 Keyboard 源码，
// KeyboardViewController 与我们在同一模块内，因此不能也不需要 import Keyboard。
@testable import KeyboardCore

/// 端到端验证：按下一个字符键后，该键的 accessibilityValue 是否变成候选。
///
/// ## 为什么需要这条测试
///
/// 之前的单元测试只验证「文本生成逻辑」：
/// 给一段输入状态，`KeySpeechComposer` 是否返回正确的朗读串。
/// 但那不覆盖真正的链路——
///
///   按键 → 引擎快照 → 候选栏刷新 → 写 accessibilityValue → layoutChanged
///
/// 这条测试走完整链路，直接断言用户手指下那个键的 value 变成候选词。
/// 这正是「输入一个字符会不会播报候选」的可执行定义。
@MainActor
final class KeySpeechEndToEndTests: XCTestCase {

    /// 与生产一致：26 键、中文、无 bootstrap 副作用。
    private final class FixtureController: KeyboardViewController {
        override func viewDidLoad() {
            // 跳过扩展 bootstrap，避免真实 librime 与宿主依赖。
        }
    }

    /// 可控的假引擎：`wo` 组合返回候选「我」。
    private final class StubRimeEngine: RimeEngine {
        var keys: [String] = []
        var raw = ""
        var runtimeSelection: RimeRuntimeSelection? { nil }
        var onRuntimeSelectionChanged: ((RimeRuntimeSelection) -> Void)?

        private func makeOutput() -> RimeOutput {
            let candidates: [RimeCandidate] =
                raw.isEmpty ? [] : [.init(text: "我", comment: "wo")]
            return RimeOutput(
                rawInput: raw,
                composition: .init(preeditText: raw, cursorPosition: raw.count),
                candidates: candidates
            )
        }

        func output() -> RimeOutput { makeOutput() }
        func processKey(_ key: String) -> RimeOutput { keys.append(key); raw += key; return makeOutput() }
        func replaceInput(_ input: String) -> RimeOutput { raw = input; return makeOutput() }
        func selectCandidate(at index: Int) -> RimeOutput { makeOutput() }
        func selectCandidate(globalIndex index: Int) -> RimeOutput { makeOutput() }
        func candidateWindow(from globalIndex: Int, limit: Int) -> RimeCandidateWindow {
            .init(candidates: [], startIndex: globalIndex, nextIndex: globalIndex, hasMoreCandidates: false)
        }
        func deleteBackward() -> RimeOutput { if !raw.isEmpty { raw.removeLast() }; return makeOutput() }
        func resetSession() { raw = "" }
        func recoverSession() {}
        func suspendForVisibilityChange() {}
        func resumeAfterVisibilityChange() {}
        func isComposing() -> Bool { !raw.isEmpty }
        func pageUp() -> RimeOutput { makeOutput() }
        func pageDown() -> RimeOutput { makeOutput() }
    }

    private func makeFixture() -> FixtureController {
        let owner = FixtureController()
        owner.loadViewIfNeeded()
        owner.controller = KeyboardController(state: KeyboardState())
        owner.cachedLayoutStyle = .twentySixKey
        owner.view.frame = CGRect(x: 0, y: 0, width: 390, height: owner.preferredKeyboardHeight)
        owner.setupRootStack()
        owner.reloadKeyboard()
        owner.view.setNeedsLayout()
        owner.view.layoutIfNeeded()
        return owner
    }

    private func descendants(_ root: UIView) -> [UIView] {
        var out: [UIView] = [root]
        for sub in root.subviews { out.append(contentsOf: descendants(sub)) }
        return out
    }

    /// 核心断言：按住 `w` 后，该键的 value 应包含候选「我」。
    func testKeyValueBecomesCandidateAfterPress() throws {
        let owner = makeFixture()
        let engine = StubRimeEngine()
        owner.controller.rimeEngine = engine
        owner.controller.usesT9InputSemantics = false

        let key = try XCTUnwrap(
            descendants(owner.rootStack)
                .compactMap { $0 as? KeyboardKeyButton }
                .first { $0.accessibilityIdentifier == "w" || $0.title(for: .normal) == "w" },
            "找不到 w 键"
        )

        // 按下前：value 里没有候选。
        let before = key.accessibilityValue ?? ""
        XCTAssertFalse(before.contains("我"), "按键前不应已有候选：\(before)")

        owner.insertKey(key)

        // 播报走 afterUISync + 下一轮主循环，需要让出主线程。
        let settled = expectation(description: "value 更新")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 3)

        let after = key.accessibilityValue ?? ""
        XCTAssertTrue(
            after.contains("我"),
            "按下 w 后 value 应含候选「我」，实际：\(after)"
        )
        XCTAssertTrue(
            after.contains("w"),
            "朗读串应含键名，实际：\(after)"
        )
    }

    /// 不同按键必须得到不同 value（防止「永远读同一个字」）。
    func testDifferentKeysProduceDifferentValues() throws {
        let owner = makeFixture()
        let engine = StubRimeEngine()
        owner.controller.rimeEngine = engine
        owner.controller.usesT9InputSemantics = false

        let keys = try ["w", "n"].map { ch in
            try XCTUnwrap(
                descendants(owner.rootStack)
                    .compactMap { $0 as? KeyboardKeyButton }
                    .first { $0.accessibilityIdentifier == ch || $0.title(for: .normal) == ch },
                "找不到 \(ch) 键"
            )
        }

        for key in keys { owner.insertKey(key) }

        let settled = expectation(description: "value 更新")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 3)

        let values = keys.map { $0.accessibilityValue ?? "" }
        XCTAssertTrue(values.allSatisfy { $0.contains("我") }, "两个键都应读到候选：\(values)")
        XCTAssertEqual(Set(values).count, 2, "不同键的朗读串应不同（含各自键名）：\(values)")
    }
}

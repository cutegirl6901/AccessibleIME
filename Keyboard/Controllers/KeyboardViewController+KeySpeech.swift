import KeyboardCore
import UIKit

// MARK: - 按键即读（VoiceOver 主动反馈）
//
// 设计要点见 KeySpeechAnnouncer 的注释。这里只负责：
//   1. 在 controller.handle 之前推进序号
//   2. 在 syncUI 之后立刻快照当前输入状态
//   3. 生成朗读文本并投递
//
// 为什么快照要在这里、并且紧挨 syncUI：
//   - 候选栏刷新在 syncUI 内完成，播报必须基于刷新后的状态
//   - 但不能再读 controller.state 的「未来值」：快照是值拷贝，天然隔离

extension KeyboardViewController {

    // MARK: 入口

    /// 按键开始：推进序号。在 `controller.handle(...)` 之前调用。
    @discardableResult
    func beginKeySpeechEvent() -> UInt64 {
        keySpeechAnnouncer.beginInputEvent()
    }

    /// 按键结束：快照 → 生成文本 → 投递。在 `syncUI(...)` 之后调用。
    ///
    /// - Parameters:
    ///   - kind: 按键类别
    ///   - keyLabel: 按键的可读名称（字母用原字符，空格/回车等用中文）
    ///   - sequence: `beginKeySpeechEvent()` 的返回值
    ///   - committedOverride: 本次已确定上屏的文本（若引擎未通过 lastRimeOutput 暴露）
    ///   - deletedOverride: 本次已确定删除的文本
    func finishKeySpeechEvent(
        kind: KeySpeechKind,
        keyLabel: String,
        sequence: UInt64,
        committedOverride: String? = nil,
        deletedOverride: String? = nil
    ) {
        // 失败/中断的按键不应该播报。
        guard keySpeechAnnouncer.isCurrent(sequence) else { return }

        let snapshot = makeKeySpeechSnapshot(
            kind: kind,
            keyLabel: keyLabel,
            committedOverride: committedOverride,
            deletedOverride: deletedOverride
        )

        let text = KeySpeechComposer.compose(
            snapshot,
            detail: keySpeechAnnouncer.detail,
            table: CharacterDescriptionTableProvider.shared.table
        )
        keySpeechAnnouncer.announce(text, sequence: sequence)
    }

    // MARK: 快照

    /// 从**当前**输入状态构造快照。
    ///
    /// 只读取公开的 `controller.state` 字段，不写死任何候选内容。
    func makeKeySpeechSnapshot(
        kind: KeySpeechKind,
        keyLabel: String,
        committedOverride: String? = nil,
        deletedOverride: String? = nil
    ) -> KeySpeechSnapshot {
        let state = controller.state
        let output = state.lastRimeOutput
        let candidates = output?.candidates.map(\.text) ?? []
        let comments = output?.candidates.map(\.comment) ?? []

        return KeySpeechSnapshot(
            kind: kind,
            keyLabel: keyLabel,
            inputMode: state.inputMode,
            page: state.currentPage,
            shiftState: state.shiftState,
            composition: output?.rawInput ?? state.currentComposition,
            candidates: candidates,
            candidateComments: comments,
            committedText: committedOverride ?? output?.committedText,
            deletedText: deletedOverride,
            revision: state.compositionRevision
        )
    }

    // MARK: 常见按键的便捷入口

    /// 字母/数字/标点键统一入口。
    func speakInsertKey(_ key: String, sequence: UInt64) {
        finishKeySpeechEvent(
            kind: KeySpeechComposer.classify(key: key),
            keyLabel: key,
            sequence: sequence
        )
    }

    /// 删除键。`deletedText` 是这次真正被删掉的文本。
    func speakDelete(deletedText: String?, sequence: UInt64) {
        finishKeySpeechEvent(
            kind: .delete,
            keyLabel: "删除",
            sequence: sequence,
            deletedOverride: deletedText
        )
    }

    /// 上屏类按键（空格、回车、选词）。
    func speakCommit(
        kind: KeySpeechKind,
        keyLabel: String,
        committedText: String?,
        sequence: UInt64
    ) {
        finishKeySpeechEvent(
            kind: kind,
            keyLabel: keyLabel,
            sequence: sequence,
            committedOverride: committedText
        )
    }

    /// 状态类按键（大小写、中英文、键盘页）。
    func speakStateChange(_ kind: KeySpeechKind, sequence: UInt64) {
        finishKeySpeechEvent(kind: kind, keyLabel: "", sequence: sequence)
    }

    // MARK: 设置与生命周期

    /// VoiceOver 是否开启。
    ///
    /// 已在真机上观测到该值在键盘扩展里可能不可靠（开启时仍返回 false）。
    /// 因此它**只用于诊断与提速**，不用于决定是否播报。
    var isVoiceOverProbablyRunning: Bool {
        UIAccessibility.isVoiceOverRunning
    }

    /// 从本地设置刷新播报配置。主 App 与本扩展不共享容器，因此各读本地存储。
    func refreshKeySpeechSettings() {
        // 关闭完全访问后主 App 与扩展不共享容器，App Group 里的写入读不到。
        // 因此按键播报这一项优先读标准存储；App Group 只作为旧配置的兼容来源。
        let primary = UserDefaults.standard
        let fallback = UserDefaults(suiteName: Self.appGroupID)

        func value(for key: String) -> Any? {
            if let v = primary.object(forKey: key) { return v }
            return fallback?.object(forKey: key)
        }

        if let raw = value(for: Self.keySpeechDetailKey) as? Int,
            let detail = KeySpeechDetail(rawValue: raw)
        {
            keySpeechAnnouncer.detail = detail
        } else {
            // 键不存在时用默认值，不要被 integer(forKey:) 的 0 拉成 concise。
            keySpeechAnnouncer.detail = .standard
        }

        let modeRaw = value(for: Self.keySpeechDeliveryModeKey) as? String ?? ""
        keySpeechAnnouncer.deliveryMode =
            KeySpeechAnnouncer.DeliveryMode(rawValue: modeRaw) ?? .immediate
    }

    /// 键盘消失/切换 App 时清理，避免下次出现念上次残留。
    func resetKeySpeech() {
        keySpeechAnnouncer.reset()
    }

    static let keySpeechDetailKey = "key_speech_detail"
    static let keySpeechDeliveryModeKey = "key_speech_delivery_mode"
}

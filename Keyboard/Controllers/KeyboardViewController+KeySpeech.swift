import KeyboardCore
import UIKit

// MARK: - 按键即读（VoiceOver 主动反馈）
//
// 设计要点见 KeySpeechAnnouncer 的注释。这里只负责：
//   1. 在 controller.handle 之前推进序号
//   2. 拍下这次按键产生的输入状态
//   3. 生成朗读文本并投递
//
// 为什么快照只读 controller.state：
//   - 朗读内容来自 RIME 输出（候选、拼音、上屏文本）与输入模式，
//     全部是 KeyboardController 的值状态，与任何视图无关。
//   - 快照是值拷贝，天然与之后的状态隔离，不会读到「未来值」。
//
// 因此播报**不依赖候选栏刷新**：默认通道（排队公告）在 syncUI 之前投递，
// 只有仍然依赖候选格身份的诊断通道才等到 syncUI 之后。

extension KeyboardViewController {

    // MARK: 入口

    /// 按键开始：推进序号。在 `controller.handle(...)` 之前调用。
    @discardableResult
    func beginKeySpeechEvent() -> UInt64 {
        keySpeechAnnouncer.beginInputEvent()
    }

    /// 按键结束：快照 → 生成文本 → 投递。
    ///
    /// 走旁白公告的通道在 `syncUI` 之前调用，`syncUI` 之后调用的是
    /// 依赖候选格身份的诊断通道。两条路径都只读值快照，不依赖视图。
    ///
    /// - Parameters:
    ///   - kind: 按键类别
    ///   - keyLabel: 按键的可读名称（字母用原字符，空格/回车等用中文）
    ///   - sequence: `beginKeySpeechEvent()` 的返回值
    ///   - committedOverride: 本次已确定上屏的文本（若引擎未通过 lastRimeOutput 暴露）
    ///   - deletedOverride: 本次已确定删除的文本
    @discardableResult
    func finishKeySpeechEvent(
        kind: KeySpeechKind,
        keyLabel: String,
        sequence: UInt64,
        committedOverride: String? = nil,
        deletedOverride: String? = nil
    ) -> KeySpeechAnnouncer.Outcome {
        // 失败/中断的按键不应该播报。
        guard keySpeechAnnouncer.isCurrent(sequence) else { return .droppedSuperseded }

        let snapshot = makeKeySpeechSnapshot(
            kind: kind,
            keyLabel: keyLabel,
            committedOverride: committedOverride,
            deletedOverride: deletedOverride
        )

        // 是否在朗读文本里拼上键名，由通道自己决定。
        // 默认不拼：旁白在触摸按键时已经念过键名，键盘再念一遍会让两套声音
        // 叠在一起，听感与系统输入法差别很大。
        let includeKeyName = keySpeechAnnouncer.channel.includesKeyName
        let text = KeySpeechComposer.compose(
            snapshot,
            detail: keySpeechAnnouncer.detail,
            table: CharacterDescriptionTableProvider.shared.table,
            includeKeyName: includeKeyName
        )
        // 一次按键一条播报：不合并、不防抖。
        let outcome = keySpeechAnnouncer.announce(text, sequence: sequence)
        // 只要这次按键确实产生了一条播报（立即投递，或排队模式下已入队），
        // 就算它已经覆盖了上屏内容，撤销 onCommittedText 留下的兜底播报，
        // 否则同一个词会被念两遍。
        //
        // 不比对文本是否相等：部分提交时 `onCommittedText` 给的是
        // 「已确认前缀 + 本段候选」，而 RimeOutput 里只有本段候选，
        // 两者本来就不一样，比对相等会让去重失效。
        //
        // 序列过期的按键在函数开头就返回了，走不到这里，因此不会误清。
        if outcome != .droppedNoSpeech, isCommitBearingKey(kind: kind, snapshot: snapshot) {
            pendingCommittedAnnouncement = nil
        }
        return outcome
    }

    /// 这次按键是否已经把「上屏内容」读出来了。
    ///
    /// 判定不看具体文字，只看语义：上屏类按键只要产生了上屏文本，
    /// 或本身是候选/空格/回车，就说明该读的内容已经由这次按键播报覆盖。
    private func isCommitBearingKey(kind: KeySpeechKind, snapshot: KeySpeechSnapshot) -> Bool {
        if let committed = snapshot.committedText, !committed.isEmpty { return true }
        switch kind {
        case .candidate, .space, .returnKey: return true
        default: return false
        }
    }

    /// 当前通道是否由键盘自己发声（通道 1 / 2）。
    ///
    /// 只用于诊断与设置页说明；播报内容不再按它分叉，
    /// 而是统一由通道的 `includesKeyName` 决定。
    var isAppVoiceChannel: Bool {
        keySpeechAnnouncer.channel is AppVoiceSpeechChannel
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
    ///
    /// 上屏文本的去重与兜底撤销统一在 `finishKeySpeechEvent` 里处理，
    /// 这里只负责把「本次已上屏的文本」交给快照。
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

        // 默认每次按键立即播报（不合并）。旧版本存的 "coalesced" 已不存在，
        // 解析失败会自动回到 .immediate，不需要额外迁移。
        let modeRaw = value(for: Self.keySpeechDeliveryModeKey) as? String ?? ""
        keySpeechAnnouncer.deliveryMode =
            KeySpeechAnnouncer.DeliveryMode(rawValue: modeRaw) ?? .immediate

        // 播报通道。默认 3（旁白公告，低优先级排队）：
        // 旁白先念键名，候选排在其后播出，不抢话、不移动焦点。
        // 存的是通道编号；解析失败一律回到默认值，不要静默切到别的通道。
        let channelNumber = value(for: Self.keySpeechChannelKey) as? Int
        let channelID = channelNumber.flatMap(KeySpeechChannelID.init(rawValue:)) ?? .queuedAnnouncement
        if keySpeechAnnouncer.channel.id != channelID {
            keySpeechAnnouncer.selectChannel(channelID, announceName: false)
        }
        // 无条件注入回调：只有部分通道需要它，但漏注入会让整条通道静默，
        // 而代价只是一次可选绑定赋值。
        installSpeechChannelCallbacks(keySpeechAnnouncer.channel)
    }

    /// 通道 5 用：创建一个常驻、可聚焦、视觉上不可见的状态元素。
    ///
    /// 必须真的加进视图层级，否则 VoiceOver 无法把 valueChanged 落到它上面。
    var candidateSpeechStatusElement: UIView? {
        if let cached = candidateSpeechStatusElementCache, cached.superview != nil {
            return cached
        }
        guard let host = view else { return nil }
        let element = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        element.isAccessibilityElement = true
        element.accessibilityTraits = .staticText
        element.accessibilityLabel = "候选朗读状态"
        element.isUserInteractionEnabled = false
        element.alpha = 0.01
        host.addSubview(element)
        candidateSpeechStatusElementCache = element
        return element
    }

    /// 键盘消失/切换 App 时清理，避免下次出现念上次残留。
    func resetKeySpeech() {
        keySpeechAnnouncer.reset()
        // 未投递的上屏播报也一并丢弃：键盘已经收起，迟到的朗读只会造成困惑。
        pendingCommittedAnnouncement = nil
        candidateSpeechStatusElementCache?.removeFromSuperview()
        candidateSpeechStatusElementCache = nil
    }

    static let keySpeechDetailKey = "key_speech_detail"
    static let keySpeechDeliveryModeKey = "key_speech_delivery_mode"
    static let keySpeechChannelKey = "key_speech_channel"
}

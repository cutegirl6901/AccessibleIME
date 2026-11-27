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

    /// 按键结束的**第二条路径**：登记一条待播报，等引擎快照真正落地后再发声。
    ///
    /// ## 为什么要延迟
    ///
    /// 异步引擎（`isResponsiveRimePipelineEnabled`）下 `handle()` 立即返回，
    /// 这时 `state.lastRimeOutput` 还是旧值。同步播报会持续朗读上一次的候选
    /// （真机现象：不管输入什么都重复同一句释义）。
    ///
    /// ## 两种落地方式
    ///
    /// - 引擎快照在 `onResponsivePresentationNeeded` 里落地 → 立刻拍新鲜快照播报；
    /// - 300ms 内没等到（非异步路径、或本次按键不产生快照，
    ///   例如大小写切换）→ 超时兜底用当前状态照发。
    ///
    /// 两条路径最终都汇入 `flushDeferredKeySpeech`，去重与序号判定只有一份实现。
    func beginDeferredKeySpeech(
        kind: KeySpeechKind,
        keyLabel: String,
        sequence: UInt64,
        committedOverride: String? = nil,
        deletedOverride: String? = nil
    ) {
        // 先取消上一条的兜底：新按键已经让它的内容作废。
        deferredKeySpeechTimeoutTask?.cancel()
        deferredKeySpeech = DeferredKeySpeech(
            sequence: sequence,
            kind: kind,
            keyLabel: keyLabel,
            committedOverride: committedOverride,
            deletedOverride: deletedOverride,
            revisionAtRegistration: controller.state.compositionRevision
        )
        deferredKeySpeechRegisteredCount += 1
        ProbeLog.log("REGISTER", [
            ("seq", String(sequence)),
            ("kind", String(describing: kind)),
            ("key", keyLabel),
            ("rev", String(controller.state.compositionRevision)),
            ("pipeline", controller.isResponsiveRimePipelineEnabled ? "async" : "sync"),
        ])
        scheduleDeferredKeySpeechTimeout(sequence: sequence)
    }

    /// 超时兜底：到点仍未落地的播报照发，避免整次按键静默。
    private func scheduleDeferredKeySpeechTimeout(sequence: UInt64) {
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.deferredKeySpeechTimeout)
            guard !Task.isCancelled, let self else { return }
            guard self.deferredKeySpeech?.sequence == sequence else { return }
            self.flushDeferredKeySpeech(reason: "timeout")
        }
        deferredKeySpeechTimeoutTask = task
    }

    /// 引擎快照落地后的播报入口。由 `onResponsivePresentationNeeded` 调用。
    ///
    /// 此时 `applyRimeOutput` 已经执行完，`state.lastRimeOutput` 是本轮的新值。
    ///
    /// - Parameter timing: 只投递与该时机匹配的通道。
    ///   `beforeUISync` 通道（默认的排队公告）在 `syncUI` **之前**投递，
    ///   这是 0.2.5 记录过的结论：与 `reloadData` 同帧的公告会被系统丢弃。
    ///   `afterUISync` 通道（焦点转移）必须等候选栏刷新完，否则移到空列表上。
    func deliverDeferredKeySpeechIfNeeded(timing: KeySpeechDeliveryTiming) {
        guard let pending = deferredKeySpeech else { return }

        // 这条登记必须仍是最新一次按键。
        //
        // 否则会出现这样的错读：按下字母 n 后立刻按删除，删除自己的快照
        // 先到达，就会用「删除之后的 state」去播报 n 的候选。
        // 删除、选词、切换等动作都会推进序号，因此用序号判定即可。
        guard keySpeechAnnouncer.isCurrent(pending.sequence) else {
            deferredKeySpeechTimeoutTask?.cancel()
            deferredKeySpeech = nil
            return
        }

        // 通道可能在等待期间被切换；以投递时的实际通道为准。
        guard keySpeechAnnouncer.channel.timing == timing else { return }
        flushDeferredKeySpeech(reason: "snapshot-\(timing == .beforeUISync ? "pre" : "post")")
    }

    /// 拍快照并投递，然后清空登记。
    private func flushDeferredKeySpeech(reason: String) {
        guard let pending = deferredKeySpeech else { return }
        if reason == "timeout" {
            deferredKeySpeechTimedOutCount += 1
        } else {
            deferredKeySpeechDeliveredCount += 1
        }
        deferredKeySpeech = nil
        deferredKeySpeechTimeoutTask?.cancel()

        // 自助诊断：把这几个数字拼成一句话，供三击大小写键朗读。
        // 判断方法：revAtRegister 与 revNow 不同 = 快照前进了（读到新数据）；
        // 相同 = 引擎没更新，问题在 RIME 侧。
        // 再比较 engineCandidates 与 barCandidates：两者不等说明播报和候选栏
        // 读的不是同一份数据。
        let engineCount = controller.state.lastRimeOutput?.candidates.count ?? -1
        let barCount = accumulatedCandidates.count
        let channelNumber = keySpeechAnnouncer.channel.id.rawValue
        let revisionBefore = pending.revisionAtRegistration
        let revisionNow = controller.state.compositionRevision

        // 逐段拼接：整条表达式一次性写会让类型检查超时。
        var summary = "通道\(channelNumber)，"
        summary += "取数\(reason)，"
        summary += "修订\(revisionBefore)到\(revisionNow)，"
        summary += "引擎候选\(engineCount)个，"
        summary += "候选栏\(barCount)个"
        lastSpeechDiagnostic = summary

        // 真机探针：系统日志可用数据线直接读取，绕开 App Group 隔离。
        // 只记录结构性信息（长度/数量/通道），不记录候选文字本身。
        // 先逐项取好再传入：13 个元素的元组字面量一次性写会让类型检查超时。
        var fields: [(String, String)] = []
        fields.append(("reason", reason))
        fields.append(("seq", String(pending.sequence)))
        fields.append(("kind", String(describing: pending.kind)))
        fields.append(("key", pending.keyLabel))
        fields.append(("revAtRegister", String(revisionBefore)))
        fields.append(("revNow", String(revisionNow)))
        fields.append(("engineCandidates", String(engineCount)))
        fields.append(("barCandidates", String(barCount)))
        fields.append(("barRevision", String(candidateSnapshotCompositionRevision)))
        fields.append(("channel", String(channelNumber)))
        fields.append(("delivered", String(deferredKeySpeechDeliveredCount)))
        fields.append(("timedOut", String(deferredKeySpeechTimedOutCount)))
        ProbeLog.log("FLUSH", fields)

        // 诊断日志走运行时开关（Logger 的 logging_enabled），不受 #if DEBUG 限制。
        // 这样 Release 构建在真机上也能看到按键这一刻读到的到底是新值还是旧值。
        if Logger.isLiveCategoryEnabled(.performance) {
            Logger.shared.info(
                "KEYSPEECH flush reason=\(reason) seq=\(pending.sequence) "
                    + "registered=\(deferredKeySpeechRegisteredCount) "
                    + "delivered=\(deferredKeySpeechDeliveredCount) "
                    + "timedOut=\(deferredKeySpeechTimedOutCount) "
                    + "kind=\(String(describing: pending.kind)) key=\(pending.keyLabel) "
                    + "revisionAtRegister=\(pending.revisionAtRegistration) "
                    + "revisionNow=\(controller.state.compositionRevision) "
                    + "raw=\(controller.state.lastRimeOutput?.rawInput ?? "nil") "
                    + "candidates=\(controller.state.lastRimeOutput?.candidates.count ?? 0) "
                    + "first=\(controller.state.lastRimeOutput?.candidates.first?.text ?? "nil")",
                category: .performance
            )
        }

        finishKeySpeechEvent(
            kind: pending.kind,
            keyLabel: pending.keyLabel,
            sequence: pending.sequence,
            committedOverride: pending.committedOverride,
            deletedOverride: pending.deletedOverride
        )
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
        // 真机探针：这是最终交给旁白的文本，直接对应你能听到的内容。
        ProbeLog.log("SPEAK", [
            ("seq", String(sequence)),
            ("chars", String(text?.count ?? -1)),
            ("text", text ?? "<nil>"),
            ("channel", String(describing: keySpeechAnnouncer.channel.id)),
        ])

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

        // 候选来源：优先用候选栏**已经显示**的数据。
        //
        // 真机结论：同一时刻摸候选区能读对，而按键播报读错，
        // 说明两者读的不是同一份数据。候选栏是用户能验证的「真相」，
        // 因此以它为准；只有候选栏尚未刷新（修订号落后）时才回退到引擎输出。
        let barMatchesCurrentState =
            !accumulatedCandidates.isEmpty
            && candidateSnapshotCompositionRevision == state.compositionRevision

        let candidates: [String]
        let comments: [String?]
        if barMatchesCurrentState {
            candidates = accumulatedCandidates.map(\.title)
            comments = accumulatedCandidates.map(\.comment)
        } else {
            candidates = output?.candidates.map(\.text) ?? []
            comments = output?.candidates.map(\.comment) ?? []
        }

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

        // 播报通道。
        //
        // 默认改为 2（键盘自己用 AVSpeechSynthesizer 发声）。
        //
        // 为什么不再用通道 3（旁白公告）：
        // 真机反复确认——`UIAccessibility.post(.announcement)` 在键盘扩展里
        // 只在键盘刚出现时生效一次，之后系统静默丢弃。
        // 观察到的现象与此完全一致：「切到别的 App 再切回来，第一个字符能读对，
        // 之后所有按键都无声」。0.2.2–0.2.10 的历史记录也是同一结论
        //（「时有时无，后期完全听不到」）。
        //
        // 键盘自己发声不经过旁白队列，因此不受该限制；代价是需要自己念键名，
        // 已由 `includesKeyName = true` 处理。
        let storedChannel = value(for: Self.keySpeechChannelKey) as? Int

        // 一次性迁移：把旧的「旁白公告」通道强制切到应用语音。
        //
        // 原因：通道 3 在键盘扩展里只在键盘出现时生效一次，之后系统静默丢弃，
        // 真机表现为「第一个字符能读、之后全无声」。用户设备上很可能已存过 3，
        // 只改默认值不会生效。用独立标记确保只迁移一次，
        // 之后用户仍可在主 App 里自由改回其它通道。
        let migrationKey = "key_speech_channel_migrated_from_announcement"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            UserDefaults.standard.set(true, forKey: migrationKey)
            if storedChannel == KeySpeechChannelID.queuedAnnouncement.rawValue {
                UserDefaults.standard.set(
                    KeySpeechChannelID.appVoicePlayback.rawValue,
                    forKey: Self.keySpeechChannelKey
                )
            }
        }

        let channelNumber = value(for: Self.keySpeechChannelKey) as? Int
        let channelID = channelNumber.flatMap(KeySpeechChannelID.init(rawValue:)) ?? .appVoicePlayback
        if keySpeechAnnouncer.channel.id != channelID {
            keySpeechAnnouncer.selectChannel(channelID, announceName: false)
        }
        // 无条件注入回调：只有部分通道需要它，但漏注入会让整条通道静默，
        // 而代价只是一次可选绑定赋值。
        installSpeechChannelCallbacks(keySpeechAnnouncer.channel)
    }

    /// 键盘消失/切换 App 时清理，避免下次出现念上次残留。
    func resetKeySpeech() {
        keySpeechAnnouncer.reset()
        deferredKeySpeechTimeoutTask?.cancel()
        deferredKeySpeech = nil
        // 未投递的上屏播报也一并丢弃：键盘已经收起，迟到的朗读只会造成困惑。
        // 必须同时取消兜底任务，否则它会在下次展开键盘后醒来并播报旧文本。
        pendingCommittedAnnouncementTask?.cancel()
        pendingCommittedAnnouncementTask = nil
        pendingCommittedAnnouncement = nil
        // 去重基准也要清：不清的话，下次真的输入同一个字会被判成「重复」
        // 而只读词本身，读法与首次不一致。
        lastAnnouncedCommittedText = nil
        lastFocusedCandidateText = nil
    }

    static let keySpeechDetailKey = "key_speech_detail"
    static let keySpeechDeliveryModeKey = "key_speech_delivery_mode"
    static let keySpeechChannelKey = "key_speech_channel"
}

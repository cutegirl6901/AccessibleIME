import KeyboardCore
//
//  KeyboardViewController+CandidateBar.swift
//  Keyboard
//
//  候选栏与控制器状态之间的薄适配。
//
//  候选栏架构：
//    ┌──────────────────────────────────────────┐
//    │ [cand1] [cand2] ... [scroll right]  [▼] │ ← 左右无极滑动 + 展开按钮
//    └──────────────────────────────────────────┘
//
//  翻页：输入更新后准备多页数据，UICollectionView 仅渲染屏幕附近候选。
//
//  展开后面板（流式布局，填满整个键盘区域）：
//    ┌─────────────────────────────────[▲]─────┐
//    │  [你好] [你好吗] [你] [你们] [你好啊]    │ ← 宽度自适应 + 自动换行
//    │  [你好世界] [你好呀] [你的] ...          │
//    │  ...                          (scroll ↓) │
//    └──────────────────────────────────────────┘
//
import UIKit

// MARK: === 候选栏 ===

extension KeyboardViewController {

    // MARK: --- 候选栏容器 ---

    /// Connects the presentation-only candidate container to controller state.
    func makeCandidateBar() -> UIView {
        let view = CandidateBarView(
            backgroundColor: .clear,
            interactionTarget: self,
            expandAction: #selector(handleCandidateBarTrailingButton)
        )
        #if DEBUG && KEYBOARD_WAKE_OWNER_PROBE
            installWakeOwnerProbeControls(on: view)
        #endif
        let collectionView = view.collectionView
        collectionView.dataSource = self
        collectionView.delegate = self
        candidateCollectionView = collectionView
        candidateScrollView = collectionView
        candidateExpandButton = view.expandButton
        candidateExpandButtonWidthConstraint = view.expandButtonWidthConstraint
        fillCandidateBar()
        view.onItemTap = { [weak self] indexPath in
            self?.commitCompactCandidate(at: indexPath)
        }
        return view
    }

    /// Idle trailing control dismisses the keyboard; expandable content still expands.
    @objc func handleCandidateBarTrailingButton() {
        guard !isKeyboardHeightAdjusting else { return }
        guard !shouldBlockT9RecoveryPresentation else { return }
        let canExpand = presentedCandidates.contains { $0.kind.expandsCandidateBarPanel }
        if canExpand {
            toggleCandidateExpand()
        } else {
            dismissKeyboard()
        }
    }

    /// 切换候选面板展开/收起。展开面板覆盖在现有键盘之上，
    /// 不拆除底层按键和候选栏，因此切换动画期间没有整页重排。
    @objc func toggleCandidateExpand() {
        guard !isKeyboardHeightAdjusting else { return }
        guard !shouldBlockT9RecoveryPresentation else { return }
        // UIKit reveal owns this short interaction boundary; do not race overlapping overlays.
        guard (candidateExpandedPanel as? ExpandedCandidatePanelContainerView)?.isTransitioning != true else { return }
        if isPinyinPathExpanded {
            dismissPinyinPathExpandedPanel(animated: false)
        }
        isCandidateExpanded.toggle()
        candidatePrefetchRequestSerial += 1
        deferredCandidatePrefetchMode = nil
        updateExpandButtonAppearance()
        if isCandidateExpanded {
            candidatePrefetchMode = .expanded
            if controller.state.pendingPunctuation != nil || controller.state.pendingKaomoji != nil {
                resetCandidateSnapshotFromController()
                fillCandidateBar()
            }
            presentExpandedCandidatePanel()
            if hasMoreCandidates {
                scheduleCandidatePrefetch(mode: .expanded)
            }
        } else {
            candidatePrefetchMode = .bar
            if controller.state.pendingPunctuation != nil || controller.state.pendingKaomoji != nil {
                resetCandidateSnapshotFromController()
                fillCandidateBar()
            }
            dismissExpandedCandidatePanel(animated: true)
        }
    }

    // MARK: --- 刷新 ---

    /// 刷新候选栏内容。
    ///
    /// 每次新的拼音输入时：
    ///   1. 从 RIME 获取第一页候选
    ///   2. 集合视图立即显示第一页，仅渲染可见 cell
    ///   3. 用户实际滚动到末尾时，再按需请求后续页
    func refreshCandidateBar() {
        guard candidateCollectionView != nil else { return }
        let refreshStart = CACurrentMediaTime()

        resetCandidateSnapshotFromController()
        #if DEBUG
            let preeditLength = controller.state.lastRimeOutput?.composition?.preeditText.count ?? 0

            Logger.shared.info(
                "refreshCandidateBar: page1=\(accumulatedCandidates.count), next=\(nextCandidateGlobalIndex), "
                    + "hasMore=\(hasMoreCandidates), preeditLength=\(preeditLength)",
                category: .display
            )
        #endif

        fillCandidateBar()
        let refreshMs = (CACurrentMediaTime() - refreshStart) * 1000
        #if DEBUG
            Logger.shared.performance(
                "CANDIDATES refresh total=\(String(format: "%.1f", refreshMs))ms items=\(accumulatedCandidates.count)"
            )
        #endif
        if refreshMs >= 30 {
            Logger.shared.warning(
                "SLOW CANDIDATES refresh duration=\(String(format: "%.1f", refreshMs))ms "
                    + "items=\(accumulatedCandidates.count) depth=\(candidatePageDepth)",
                category: .performance
            )
        }

        // 滚动回最左侧
        if candidateScrollView.contentOffset.x != 0 {
            candidateScrollView.setContentOffset(.zero, animated: false)
        }

        if isCandidateExpanded {
            refreshExpandedPanel()
        }
        if hasMoreCandidates {
            scheduleCandidatePrefetch(mode: candidatePrefetchMode)
        }
    }

    /// 刷新横向候选列表的数据呈现。`UICollectionView` 自行复用可见 cell，
    /// 不需要为每个已加载候选创建常驻 UIButton。
    func fillCandidateBar(keepScrollPosition: Bool = false) {
        guard let collectionView = candidateCollectionView else {
            Logger.shared.warning("fillCandidateBar: candidateCollectionView is nil", category: .general)
            return
        }
        #if DEBUG
            let renderStart = CACurrentMediaTime()
        #endif
        let items = presentedCandidates

        // Dual-mode trailing control (`PD-CANDIDATE-BAR-IDLE-DISMISS-001`):
        // expandable content keeps expand + swipe-down; idle shows dismiss.
        let canExpand = items.contains { $0.kind.expandsCandidateBarPanel }
        candidateExpandButton?.isHidden = false
        if let bar = candidateBar as? CandidateBarView {
            bar.allowsSwipeToExpand = canExpand
        }
        updateExpandButtonAppearance(canExpand: canExpand)
        (candidateBar as? CandidateBarView)?.setInputRecoveryNotice(
            shouldBlockT9RecoveryPresentation ? controller.compositionInputRecoveryMessage : nil)
        #if DEBUG && KEYBOARD_WAKE_OWNER_PROBE
            refreshWakeOwnerProbeControls()
        #endif

        let currentOffset = candidateScrollView.contentOffset.x
        // 关键：优先就地更新已有 cell，而不是 reloadData()。
        // reloadData 会销毁并重建 cell，VoiceOver 必须重扫整棵无障碍树，
        // 焦点转移因此要等好几秒（0.2.11 的真机问题）。
        // 就地更新保留 cell 对象与其无障碍元素身份，焦点转移可立即生效。
        // 只有候选数量变化（必须插入/删除 cell）时才退回 reloadData。
        if !reloadCandidateCellsInPlace(items, collectionView: collectionView) {
            collectionView.reloadData()
        }
        if keepScrollPosition {
            collectionView.layoutIfNeeded()
            let maxOffset = max(0, candidateScrollView.contentSize.width - candidateScrollView.bounds.width)
            candidateScrollView.contentOffset.x = min(currentOffset, maxOffset)
        } else if items.isEmpty {
            candidateScrollView.setContentOffset(.zero, animated: false)
        }
        collectionView.alwaysBounceHorizontal = hasMoreCandidates && !items.isEmpty

        #if DEBUG
            Logger.shared.debug(
                "fillCandidateBar collection: items=\(items.count), "
                    + "durationMs=\(String(format: "%.1f", (CACurrentMediaTime() - renderStart) * 1000))",
                category: .display
            )
        #endif

    }

    /// 按键后把 VoiceOver 焦点移到候选栏第一格，从而朗读该格的
    /// accessibilityLabel（词 + 读法 + 逐字解释）。
    ///
    /// 为什么必须是焦点转移，而不是 announcement：
    /// 本项目真机反复验证过——键盘扩展里 UIAccessibility.post(.announcement)
    /// **听不到**（0.2.2–0.2.10 全部失败），而焦点转移**能听到**（0.2.11 成功）。
    /// 这是唯一有真机成功记录的路径，不要再用 announcement 替代它。
    ///
    /// 为什么以前慢：候选栏每次都 reloadData()，cell 被销毁重建，
    /// VoiceOver 必须重扫整棵无障碍树才能定位新 cell，于是要等好几秒。
    /// 现在候选内容改为就地更新（reconfigure），cell 对象保持存活，
    /// 焦点转移可以立刻生效。
    ///
    /// 去重与序号：同一候选不重复转移；序号保证快速输入时旧请求作废。
    func focusFirstCandidateAfterKeypress() {
        guard controller.state.inputMode == .chinese else {
            lastFocusedCandidateText = nil
            return
        }
        // 候选文字优先取候选栏已显示的内容：
        // 异步引擎下 state.lastRimeOutput 可能是上一轮的值，
        // 而候选栏是用户能验证的真相。
        // 焦点转移本身就依赖候选格，因此两者必须同源。
        let firstText: String?
        if !accumulatedCandidates.isEmpty {
            firstText = accumulatedCandidates.first?.title
        } else {
            firstText = controller.state.lastRimeOutput?.candidates.first?.text
        }
        guard let firstText, !firstText.isEmpty else {
            lastFocusedCandidateText = nil
            return
        }
        // 候选面板展开时，焦点属于面板，不抢占。
        guard !isCandidateExpanded else { return }
        guard !shouldBlockT9RecoveryPresentation else { return }
        // 不去重：候选字相同也必须再读一次。
        // 盲人用户无法区分「没读到」和「没按上」，静默比重复更有害。
        lastFocusedCandidateText = firstText
        candidateAnnouncementSequence &+= 1
        let sequence = candidateAnnouncementSequence

        // 候选栏已在本次 syncUI 内就地更新完毕，这里只等一个主线程循环，
        // 让 UIKit 提交本帧布局，然后立刻转移焦点。
        //
        // ## 三级兜底
        //
        // 真机反馈：切应用回来偶尔能读一次、之后全无。
        // 说明这条路径「有时能通」，失败点在其中某个 guard 上。
        // 因此把三个可能失败的位置分开，逐级降级，并记录实际走到哪一级：
        //   1. 指向第一格候选 (cell)          —— 最佳，能读出完整候选标签
        //   2. 指向候选栏容器 (collectionView) —— 格未渲染时用它，旁白会读容器
        //   3. 退回 announcement              —— 两条都不通时最后尝试
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.candidateAnnouncementSequence == sequence else {
                self.recordFocusOutcome("superseded")
                return
            }
            guard !self.isCandidateExpanded else {
                self.recordFocusOutcome("expanded-blocked")
                return
            }

            guard let collectionView = self.candidateCollectionView else {
                self.recordFocusOutcome("no-collection-view")
                self.fallbackAnnounce(firstText)
                return
            }
            guard collectionView.numberOfItems(inSection: 0) > 0 else {
                self.recordFocusOutcome("collection-empty")
                self.fallbackAnnounce(firstText)
                return
            }

            let indexPath = IndexPath(item: 0, section: 0)
            if let cell = collectionView.cellForItem(at: indexPath) {
                self.recordFocusOutcome("cell")
                UIAccessibility.post(notification: .layoutChanged, argument: cell)
            } else {
                // 格还没渲染出来（cellForItem 返回 nil）。
                // 这种情况在快速输入或首帧时很常见，指向容器仍能出声。
                self.recordFocusOutcome("container")
                UIAccessibility.post(notification: .layoutChanged, argument: collectionView)
            }
        }
    }

    /// 焦点转移两条路都失败时的最后尝试。
    ///
    /// announcement 在扩展里大多听不到，但「偶尔能听到一次」——
    /// 有总比完全静默好，且不影响主路径。
    private func fallbackAnnounce(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UIAccessibility.post(
            notification: .announcement,
            argument: AccessibilityAnnouncement.queued(trimmed)
        )
    }

    /// 记录焦点转移走到哪一级，供「双击空格」诊断朗读。
    func recordFocusOutcome(_ outcome: String) {
        lastFocusOutcome = outcome
    }

    /// 文字真正进入输入框后，用 VoiceOver 播报「词 + 逐字解释」。
    ///
    /// 时序难点：`onCommittedText` 在 `controller.handle(...)` **内部**触发，
    /// 而按键播报的 `speakCommit` 在 `syncUI` 之后才执行。若这里直接投递，
    /// 同一个词会被念两遍（用户反馈过「读重复了」）。
    ///
    /// 因此这里只**登记**待播内容，由两条路径之一消费：
    /// - 本次按键的播报已经覆盖了上屏内容 → 撤销登记；
    /// - 没有任何按键播报路径（引擎内部提交、或按键播报关闭）→ 主线程兜底投递。
    ///
    /// 决策逻辑放在 CommittedTextAnnouncement（纯函数、有单测覆盖），
    /// 这里只负责登记、去重与投递。
    func announceCommittedTextIfNeeded(_ event: CommittedTextEvent) {
        // 不使用 isVoiceOverRunning 判断：键盘扩展里该返回值不可靠，
        // VoiceOver 关闭时 post 本身是 no-op，没有副作用。
        guard
            let spoken = CommittedTextAnnouncement.announcement(
                for: event.text,
                source: event.source,
                lastAnnounced: lastAnnouncedCommittedText,
                table: CharacterDescriptionTableProvider.shared.table
            )
        else { return }

        // 按键播报关闭时没有别的路径会读它，直接发声。
        guard keySpeechAnnouncer.deliveryMode != .off else {
            postCommittedAnnouncement(spoken, committedText: event.text)
            return
        }

        pendingCommittedAnnouncement = (committedText: event.text, spoken: spoken)
        // 兜底延时放宽到比按键播报更长。
        //
        // 真机现象（0.2.19）：原先「下一个主线程循环就补发」会抢在延迟播报
        // 之前执行。而延迟播报要等引擎快照落地（最长 300ms），
        // 于是听到的永远是这条兜底的旧内容（「我们的我」），
        // 按键播报反而被它覆盖。
        //
        // 另外必须保存句柄：键盘收起后这条 Task 若还活着，
        // 会在下次展开键盘时把上一轮的旧文本补发出来
        // （真机表现为「收起再展开后第一下读的是上次的字」）。
        pendingCommittedAnnouncementTask?.cancel()
        pendingCommittedAnnouncementTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.flushPendingCommittedAnnouncementIfNeeded()
        }
    }

    /// 没有按键播报接手时，把登记的上屏播报补发出去。
    func flushPendingCommittedAnnouncementIfNeeded() {
        guard let pending = pendingCommittedAnnouncement else { return }
        pendingCommittedAnnouncement = nil
        ProbeLog.log("COMMITTED_FALLBACK", [
            ("spoken", pending.spoken),
            ("channel", String(describing: keySpeechAnnouncer.channel.id)),
        ])
        // 键盘已经收起时不要再发声：用户此时在别的界面，
        // 一句迟到的候选朗读只会造成困惑。
        guard viewIfLoaded?.window != nil else { return }
        postCommittedAnnouncement(pending.spoken, committedText: pending.committedText)
    }

    private func postCommittedAnnouncement(_ spoken: String, committedText: String) {
        candidateAnnouncementSequence &+= 1
        lastAnnouncedCommittedText = committedText
        // 真机探针：这是与 6 个通道完全独立的第二条播报路径。
        // 若它先于按键播报发声，听感上会盖掉通道差异。
        ProbeLog.log("COMMITTED", [
            ("spoken", spoken),
            ("committed", committedText),
            ("seq", String(candidateAnnouncementSequence)),
            ("channel", String(describing: keySpeechAnnouncer.channel.id)),
        ])
        AccessibilityAnnouncement.postQueued(spoken)
    }

    func appendToCandidateBar(insertedCount: Int? = nil) {
        guard let collectionView = candidateCollectionView,
            let insertedCount,
            insertedCount > 0
        else {
            fillCandidateBar(keepScrollPosition: true)
            return
        }

        let currentCount = collectionView.numberOfItems(inSection: 0)
        let expectedOldCount = max(0, presentedCandidates.count - insertedCount)
        guard currentCount == expectedOldCount else {
            fillCandidateBar(keepScrollPosition: true)
            return
        }

        let indexPaths = (expectedOldCount..<(expectedOldCount + insertedCount)).map {
            IndexPath(item: $0, section: 0)
        }
        let currentOffset = candidateScrollView.contentOffset
        let generation = candidateSnapshotGeneration
        UIView.performWithoutAnimation {
            collectionView.performBatchUpdates {
                collectionView.insertItems(at: indexPaths)
            } completion: { _ in
                guard self.candidateSnapshotGeneration == generation,
                    collectionView === self.candidateCollectionView
                else { return }
                let maxOffset = max(
                    0, self.candidateScrollView.contentSize.width - self.candidateScrollView.bounds.width)
                self.candidateScrollView.contentOffset.x = min(currentOffset.x, maxOffset)
                collectionView.alwaysBounceHorizontal = self.hasMoreCandidates && !self.presentedCandidates.isEmpty
            }
        }
    }

    // MARK: --- 候选数据 ---

    /// 获取当前应显示的候选词列表。
    ///
    /// 无极滑动模式下优先返回累积列表（包含已加载的所有页的候选），
    /// 确保候选栏和展开面板始终显示相同的候选集合。
    func candidateItems() -> [CandidateItem] {
        guard !shouldBlockT9RecoveryPresentation else { return [] }
        if !accumulatedCandidates.isEmpty {
            return accumulatedCandidates
        }
        return CandidateBarDataSource.candidateItems(from: controller)
    }

    private func nextGlobalIndexAfterCurrentItems() -> Int {
        let referencedNextIndex = accumulatedCandidates.compactMap { item in
            item.selectionReference?.globalIndex.map { $0 + 1 }
        }.max()
        if let referencedNextIndex { return referencedNextIndex }
        return controller.state.lastRimeOutput?.candidates.count ?? 0
    }

    /// Rebuilds the presentation cache from the controller state.
    ///
    /// Page changes rebuild the keyboard before `refreshCandidateBar()` can run.
    /// When a key both commits composition and returns to letters, this prevents
    /// the newly created candidate bar from reusing stale accumulated candidates.
    func resetCandidateSnapshotFromController() {
        if controller.isCompositionInputRecoveryPending {
            invalidateCandidatesForInputRecovery()
            return
        }
        // Placeholder 是旧按钮式候选栏的安全哨兵，不属于当前 collection 快照。
        // 在唯一重建边界过滤一次，避免每个数据源回调都复制并过滤数组。
        let pendingItems: [CandidateItem]?
        if controller.state.pendingPunctuation != nil {
            pendingItems = controller.pendingPunctuationCandidateItems(expanded: isCandidateExpanded)
        } else if controller.state.pendingKaomoji != nil {
            pendingItems = controller.pendingKaomojiCandidateItems(expanded: isCandidateExpanded)
        } else {
            pendingItems = nil
        }
        accumulatedCandidates = (pendingItems ?? CandidateBarDataSource.candidateItems(from: controller)).filter {
            $0.kind != .placeholder
        }
        candidateSnapshotGeneration += 1
        candidateSnapshotCompositionRevision = controller.state.compositionRevision
        candidateSnapshotOrigin = controller.state.lastRimeOutput?.candidateOrigin
        candidateSnapshotRawInput = controller.state.lastRimeOutput?.rawInput ?? controller.state.currentComposition
        nextCandidateGlobalIndex = nextGlobalIndexAfterCurrentItems()
        hasMoreCandidates = controller.state.lastRimeOutput?.hasMorePages ?? false
        isLoadingMoreCandidates = false
        deferredCandidatePrefetchMode = nil
        candidatePrefetchRequestSerial += 1
        candidateCellSizeCache.removeAll(keepingCapacity: true)
        candidatePageDepth = 0
        candidatePrefetchMode = isCandidateExpanded ? .expanded : .bar
    }

    /// Publish candidates from a captured T9 composition snapshot (same revision as Path Bar).
    func resetCandidateSnapshot(from snapshot: T9CompositionPresentationSnapshot) {
        if controller.isCompositionInputRecoveryPending {
            invalidateCandidatesForInputRecovery()
            return
        }
        // Prefer snapshot-owned paging fields; do not re-read live controller for
        // page identity when the snapshot already captured them.
        let preedit =
            !snapshot.compositionPreedit.isEmpty
            ? snapshot.compositionPreedit
            : snapshot.visiblePreedit
        let items: [CandidateItem]
        if !preedit.isEmpty || !snapshot.candidates.isEmpty {
            items = CandidateBarDataSource.candidateItems(
                from: controller,
                rimeCandidates: snapshot.candidates,
                preeditText: preedit.isEmpty ? " " : preedit,
                pageNumber: snapshot.candidatePageNumber,
                candidateOrigin: snapshot.candidateOrigin
            )
        } else {
            items = CandidateBarDataSource.candidateItems(from: controller)
        }
        accumulatedCandidates = items.filter { $0.kind != .placeholder }
        candidateSnapshotGeneration += 1
        candidateSnapshotCompositionRevision = snapshot.revision
        candidateSnapshotOrigin = snapshot.candidateOrigin
        candidateSnapshotRawInput =
            snapshot.rimeRawInput
            ?? controller.state.currentComposition
        nextCandidateGlobalIndex = nextGlobalIndexAfterCurrentItems()
        hasMoreCandidates = snapshot.hasMorePages
        isLoadingMoreCandidates = false
        deferredCandidatePrefetchMode = nil
        candidatePrefetchRequestSerial += 1
        candidateCellSizeCache.removeAll(keepingCapacity: true)
        candidatePageDepth = 0
        candidatePrefetchMode = isCandidateExpanded ? .expanded : .bar
    }
}

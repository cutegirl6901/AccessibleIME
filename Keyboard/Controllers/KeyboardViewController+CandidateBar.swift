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
        collectionView.reloadData()
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

        // 候选播报由按键路径的 announceCurrentFirstCandidate 负责，
        // 这里不再重复播报，避免同一次输入出现两条 announcement。
    }

    /// 按键后播报当前第一个候选。
    ///
    /// 直接读取 KeyboardController 的 RIME 输出，不依赖候选栏 UI 状态，
    /// 因此不会受 UI 重建时序影响。
    ///
    /// 在按键路径调用（controller.handle 之后、syncUI 之前），此时 RIME 已产出
    /// 新候选，且不与 UI 重建同帧，announcement 能稳定送达。
    func announceCurrentFirstCandidate() {
        // 诊断（临时）：报告此刻的状态，区分「非中文模式」「无 RIME 输出」「无候选」三种情况。
        let mode = controller.state.inputMode
        let outputCount = controller.state.lastRimeOutput?.candidates.count ?? -1
        UIAccessibility.post(
            notification: .announcement,
            argument: "播报检查 模式\(mode) 候选数\(outputCount)"
        )

        guard controller.state.inputMode == .chinese else { return }
        guard let output = controller.state.lastRimeOutput,
            let first = output.candidates.first,
            !first.text.isEmpty
        else { return }
        guard first.text != lastAnnouncedCandidateText else { return }

        lastAnnouncedCandidateText = first.text
        let spoken = CharacterDescriptionSpeech.announcement(
            for: first.text,
            table: CharacterDescriptionTableProvider.shared.table
        )
        UIAccessibility.post(notification: .announcement, argument: spoken)
    }

    /// 文字真正进入输入框后，用 VoiceOver 播报上屏内容。
    ///
    /// 与候选播报的分工：候选刷新时已播过「词 + 逐字解释」，
    /// 这里只播上屏的词本身，避免同一段解释被连续读两遍。
    /// 若解释尚未播过（例如直接选词、输入法自行提交），则补上解释。
    ///
    /// 只对中文的候选/纠错/引擎提交播报；字母、标点、空格、回车不播报。
    ///
    /// 注意：键盘扩展里 UIAccessibility.post(.announcement) 实测不生效（见
    /// announceFirstCandidateIfNeeded 的说明）。上屏后候选栏已清空，没有可转移
    /// 焦点的候选格，因此这里保留 announcement 调用作为向前兼容，不依赖它。
    /// 上屏内容通常由宿主输入框自身的文本变化被 VoiceOver 感知。
    func announceCommittedTextIfNeeded(_ event: CommittedTextEvent) {
        // 同候选播报：不使用 isVoiceOverRunning 判断（扩展里返回值不可靠），
        // VoiceOver 关闭时 post 本身是 no-op。
        guard shouldAnnounceCommit(event.source) else { return }

        let text = event.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // 只播报含汉字的内容，避免朗读标点或拉丁串。
        guard containsCJKCharacter(text) else { return }

        let spoken: String
        // 与候选播报共用去重会互相污染：上屏写入后，再把同一候选打出来
        // 会被误判为重复而不播报。这里用独立变量，并且只在文本重复时省略解释。
        if text == lastAnnouncedCommittedText {
            spoken = text
        } else {
            spoken = CharacterDescriptionSpeech.announcement(
                for: text,
                table: CharacterDescriptionTableProvider.shared.table
            )
        }
        candidateAnnouncementSequence &+= 1
        lastAnnouncedCommittedText = text
        UIAccessibility.post(notification: .announcement, argument: spoken)
    }

    /// 是否包含汉字（基本区 / 扩展 A 区）。用于过滤不应朗读的提交。
    private func containsCJKCharacter(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                return true
            }
        }
        return false
    }

    /// 需要朗读提交结果的来源。
    private func shouldAnnounceCommit(_ source: CommittedTextSource) -> Bool {
        switch source {
        case .candidate, .correction, .engineCommit, .compositionFinalization:
            return true
        case .key, .space, .returnKey, .directText, .emoji:
            return false
        }
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

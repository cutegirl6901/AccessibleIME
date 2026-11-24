import KeyboardCore
import UIKit

extension KeyboardViewController {
    @objc func toggleShift(_ sender: UIButton) {
        guard !isKeyboardHeightAdjusting else { return }
        emitKeyPressFeedbackIfNeeded(for: sender)

        // 诊断 spike：三击 Shift 循环切换播报通道（1–5）。
        // 检测必须在 controller.handle 之前完成，因为切换时要撤销这次大小写变更。
        if registerShiftTapForChannelSwitch() {
            // 这一次点击只用于切换通道，不改大小写状态。
            let reset = controller.resetShiftState()
            syncUI(with: reset)
            cycleSpeechChannel()
            return
        }

        let speechSequence = beginKeySpeechEvent()
        let effects = controller.handle(.toggleShift)
        syncUI(with: effects)
        speakStateChange(.shift, sequence: speechSequence)
    }

    /// 记录一次大小写键点击，判断是否构成三击。
    ///
    /// - Returns: true 表示这是三击中的第三下，调用方应切换通道并跳过大小写变更。
    private func registerShiftTapForChannelSwitch() -> Bool {
        let now = CACurrentMediaTime()
        if let last = lastShiftTapForChannelSwitchTime,
            now - last <= Self.shiftChannelSwitchWindow
        {
            shiftTapChainForChannelSwitch += 1
        } else {
            shiftTapChainForChannelSwitch = 1
        }
        lastShiftTapForChannelSwitchTime = now

        guard shiftTapChainForChannelSwitch >= 3 else { return false }
        // 计数归零，避免第四下又被当成新的一次三击。
        shiftTapChainForChannelSwitch = 0
        lastShiftTapForChannelSwitchTime = nil
        return true
    }

    /// 切到下一条通道。通道会朗读自己的名字（听不到名字即为该通道静默）。
    func cycleSpeechChannel() {
        let next = keySpeechAnnouncer.cycleChannel()
        installSpeechChannelCallbacks(next)
        // 记住选择，键盘下次出现时仍是这条通道，便于反复对比。
        UserDefaults.standard.set(next.id.rawValue, forKey: Self.keySpeechChannelKey)
    }

    /// 通道 4 需要控制器提供候选格。
    ///
    /// 必须在**每次**换通道后调用，不能只在「通道号与默认值不同」时才调用：
    /// 漏注入会让整条通道静默，而这只是一次可选绑定赋值。
    func installSpeechChannelCallbacks(_ channel: any KeySpeechChannel) {
        if let focus = channel as? FocusTransferSpeechChannel {
            focus.focusFirstCandidate = { [weak self] in
                self?.focusFirstCandidateAfterKeypress()
            }
        }
    }

    /// 三击判定窗口。比双击大写（0.35 秒）宽，因为三击更慢。
    static let shiftChannelSwitchWindow: CFTimeInterval = 0.6

    @objc func toggleKeyboardPage(_ sender: UIButton) {
        guard !isKeyboardHeightAdjusting else { return }
        emitKeyPressFeedbackIfNeeded(for: sender)
        typoCorrectionRecallCoordinator.invalidateTypoCorrectionRecall()
        let speechSequence = beginKeySpeechEvent()
        let effects = controller.handle(.togglePage)
        syncUI(with: effects)
        // 键名由旁白念；这里只补「现在在哪个键盘」这个新信息。
        speakStateChange(.keyboardPage, sequence: speechSequence)
    }

    @objc func switchToLettersPage(_ sender: UIButton) {
        guard !isKeyboardHeightAdjusting else { return }
        emitKeyPressFeedbackIfNeeded(for: sender)
        let effects = cycleKeyboardPage(to: .letters)
        syncUI(with: effects)
    }

    @objc func switchToNumbersPage(_ sender: UIButton) {
        guard !isKeyboardHeightAdjusting else { return }
        emitKeyPressFeedbackIfNeeded(for: sender)
        let effects = cycleKeyboardPage(to: .numbers)
        syncUI(with: effects)
    }

    @objc func switchToEmojiPage(_ sender: UIButton) {
        guard !isKeyboardHeightAdjusting else { return }
        emitKeyPressFeedbackIfNeeded(for: sender)
        let effects = cycleKeyboardPage(to: .emoji)
        syncUI(with: effects)
    }

    @objc func switchToSymbolsPage(_ sender: UIButton) {
        guard !isKeyboardHeightAdjusting else { return }
        emitKeyPressFeedbackIfNeeded(for: sender)
        let effects = cycleKeyboardPage(to: .symbols)
        syncUI(with: effects)
    }

    /// Clears active T9 composition without committing raw digits (ADR 0018).
    @objc func reinputT9Composition(_ sender: UIButton) {
        guard !isKeyboardHeightAdjusting else { return }
        emitKeyPressFeedbackIfNeeded(for: sender)
        let effects = controller.abandonCompositionForVisibilityChange()
        syncUI(with: effects)
    }

    /// Native-style punctuation entry on the nine-key grid (comma-first common mark).
    @objc func insertT9CommonPunctuation(_ sender: UIButton) {
        guard !isKeyboardHeightAdjusting else { return }
        emitKeyPressFeedbackIfNeeded(for: sender)
        let effects = controller.handle(.pressT9CommonPunctuation)
        syncUI(with: effects)
    }

    /// Compatibility selector retained for any stale target wiring; forwards to product path panel.
    @objc func t9SelectPinyinPlaceholder(_ sender: UIButton) {
        t9SelectPinyin(sender)
    }

    @objc func insertKaomoji(_ sender: UIButton) {
        guard !isKeyboardHeightAdjusting else { return }
        emitKeyPressFeedbackIfNeeded(for: sender)
        let effects = controller.handle(.pressKaomoji)
        syncUI(with: effects)
    }

    /// Compatibility selector retained for any stale target wiring; forwards to product path.
    @objc func showKaomojiCandidatesPlaceholder(_ sender: UIButton) {
        insertKaomoji(sender)
    }

    private func cycleKeyboardPage(to targetPage: KeyboardPage) -> KeyboardEffect {
        var effects: KeyboardEffect = []
        var remainingSteps = 4

        guard controller.state.currentPage != targetPage else { return effects }
        typoCorrectionRecallCoordinator.invalidateTypoCorrectionRecall()
        while controller.state.currentPage != targetPage && remainingSteps > 0 {
            effects.formUnion(controller.handle(.togglePage))
            remainingSteps -= 1
        }

        return effects
    }

    @objc func toggleInputMode(_ sender: UIButton) {
        guard !isKeyboardHeightAdjusting else { return }
        emitKeyPressFeedbackIfNeeded(for: sender)
        // This must run even without composition: an old delayed recall is still stale
        // once the input-mode contract changes.
        typoCorrectionRecallCoordinator.invalidateTypoCorrectionRecall()
        let speechSequence = beginKeySpeechEvent()
        var effects = controller.handle(.toggleInputMode)

        if controller.state.inputMode == .english {
            let context = textDocumentProxy.documentContextBeforeInput
            let autoCapEffect = controller.applyAutoCapitalization(contextBeforeInput: context)
            effects.formUnion(autoCapEffect)
        }

        syncUI(with: effects)
        speakStateChange(.inputMode, sequence: speechSequence)
    }

    @objc func candidatePageUp() {
        guard !isKeyboardHeightAdjusting else { return }
        emitKeyPressFeedback()
        let effects = controller.handle(.candidatePageUp)
        syncUI(with: effects)
    }

    @objc func candidatePageDown() {
        guard !isKeyboardHeightAdjusting else { return }
        emitKeyPressFeedback()
        let effects = controller.handle(.candidatePageDown)
        syncUI(with: effects)
    }

    @objc func insertSpace(_ sender: UIButton) {
        guard !isKeyboardHeightAdjusting else { return }
        emitKeyPressFeedbackIfNeeded(for: sender)
        let speechSequence = beginKeySpeechEvent()
        let effects = controller.handle(.insertSpace)
        syncUI(with: effects)
        // 有上屏文本就播报上屏内容（含逐字解释），否则读「空格」。
        speakCommit(kind: .space, keyLabel: "空格", committedText: nil, sequence: speechSequence)
    }

    @objc func insertReturn(_ sender: UIButton) {
        guard !isKeyboardHeightAdjusting else { return }
        emitKeyPressFeedbackIfNeeded(for: sender)
        let speechSequence = beginKeySpeechEvent()
        let effects = controller.handle(.insertReturn)
        syncUI(with: effects)
        speakCommit(kind: .returnKey, keyLabel: "回车", committedText: nil, sequence: speechSequence)
    }
}

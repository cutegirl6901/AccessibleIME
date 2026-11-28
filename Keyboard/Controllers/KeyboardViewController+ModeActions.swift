import KeyboardCore
import UIKit

extension KeyboardViewController {
    @objc func toggleShift(_ sender: UIButton) {
        guard !isKeyboardHeightAdjusting else { return }
        emitKeyPressFeedbackIfNeeded(for: sender)

        let speechSequence = beginKeySpeechEvent()
        let effects = controller.handle(.toggleShift)
        syncUI(with: effects)
        speakStateChange(.shift, sequence: speechSequence)
    }

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

        // 快速双击空格 = 朗读自助诊断，本次不插入空格。
        //
        // 判据：与上一次空格点击的间隔小于 0.6 秒。
        // 单击仍然照常插入空格，因此不影响正常使用。
        let now = CACurrentMediaTime()
        if now - lastSpaceTapTime <= Self.spaceDiagnosticDoubleTapWindow {
            lastSpaceTapTime = 0
            emitKeyPressFeedbackIfNeeded(for: sender)
            speakSpaceDiagnostic()
            return
        }
        lastSpaceTapTime = now

        emitKeyPressFeedbackIfNeeded(for: sender)
        let speechSequence = beginKeySpeechEvent()
        let effects = controller.handle(.insertSpace)
        // 与字母键同理：异步引擎下 handle() 返回时本次上屏文本可能还没落到
        // state.lastRimeOutput，同步读会拿到 nil（表现为只念「空格」而不是上屏的字）。
        // 统一交给延迟播报，等快照落地后读真实上屏文本。
        beginDeferredKeySpeech(kind: .space, keyLabel: "空格", sequence: speechSequence)
        syncUI(with: effects)
        if !controller.isResponsiveRimePipelineEnabled {
            deliverDeferredKeySpeechIfNeeded(timing: .afterUISync)
        }
    }

    @objc func insertReturn(_ sender: UIButton) {
        guard !isKeyboardHeightAdjusting else { return }
        emitKeyPressFeedbackIfNeeded(for: sender)
        let speechSequence = beginKeySpeechEvent()
        let effects = controller.handle(.insertReturn)
        beginDeferredKeySpeech(kind: .returnKey, keyLabel: "回车", sequence: speechSequence)
        syncUI(with: effects)
        if !controller.isResponsiveRimePipelineEnabled {
            deliverDeferredKeySpeechIfNeeded(timing: .afterUISync)
        }
    }
}

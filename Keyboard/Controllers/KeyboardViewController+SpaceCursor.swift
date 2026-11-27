import KeyboardCore
import UIKit

// MARK: - Space Key Cursor Control

extension KeyboardViewController {
    /// Handles the trackpad-like cursor gesture on the space key.
    ///
    /// The space key is created in `makeBottomRow` with two behaviors:
    /// tapping inserts a normal space, while a long-press converts the keyboard into a trackpad,
    /// moving the insertion point horizontally inside the host app's active text field.
    @objc func handleSpaceCursorLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard !isKeyboardHeightAdjusting else { return }
        guard let spaceButton = gesture.view as? UIButton else { return }
        // Gesture recognizers can still deliver after UIButton.isEnabled changes.
        guard !shouldBlockT9RecoveryPresentation else {
            if isCursorMovementModeActive {
                isCursorMovementModeActive = false
                spaceCursorLastLocationX = nil
                setCursorMovementModeUI(active: false, exceptionView: spaceButton)
                restoreKeyAppearance(spaceButton)
                refreshT9InputRecoveryPresentation()
            }
            return
        }

        switch gesture.state {
        case .began:
            isCursorMovementModeActive = true
            spaceCursorLastLocationX = gesture.location(in: spaceButton).x
            setCursorMovementModeUI(active: true, exceptionView: spaceButton)
            // Restoring the key appearance removes the default pressed state color
            restoreKeyAppearance(spaceButton)
            emitFeedback(for: .modeEnter)

        case .changed:
            guard let lastX = spaceCursorLastLocationX else { return }
            let currentX = gesture.location(in: spaceButton).x
            let diff = currentX - lastX
            // A 10-point threshold keeps small finger jitter from moving the cursor too aggressively.
            let offset = Int(diff / 10)

            if offset != 0 {
                commitTrace.close(.nextInput)
                textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
                // Compensate the last location by the exact movement distance we just applied
                spaceCursorLastLocationX = lastX + CGFloat(offset * 10)
            }

        case .ended, .cancelled:
            isCursorMovementModeActive = false
            spaceCursorLastLocationX = nil
            setCursorMovementModeUI(active: false, exceptionView: spaceButton)
            restoreKeyAppearance(spaceButton)

        default:
            break
        }
    }

    /// 朗读自助诊断。
    ///
    /// 走当前通道发声：这一句能不能听到，本身就说明该通道是否可用。
    /// 朗读自助诊断。
    ///
    /// 刻意**不走当前通道**，而是固定用应用语音（AVSpeechSynthesizer）发声：
    /// 这一句的作用是确认「声音能不能出来」，如果它也依赖通道，
    /// 通道坏了就永远得不到任何反馈，无法判断到底哪一层出了问题。
    func speakSpaceDiagnostic() {
        let message: String
        if let diagnostic = lastSpeechDiagnostic {
            message = "诊断：" + diagnostic
        } else {
            message = "诊断：还没有按键记录。请先输入几个字母，再快速双击空格。"
        }
        diagnosticChannel.speak(message)
        ProbeLog.log("DIAG_TAP", [
            ("message", message),
            ("currentChannel", String(describing: keySpeechAnnouncer.channel.id)),
        ])
    }

    /// 专供诊断使用的独立发声器：不参与通道切换，确保一定能出声。
    var diagnosticChannel: any KeySpeechChannel {
        if let existing = cachedDiagnosticChannel { return existing }
        let created = KeySpeechChannelFactory.make(.appVoiceIsolated)
        cachedDiagnosticChannel = created
        return created
    }

    func endSpaceCursorMovementForHeightAdjustment() {
        guard isCursorMovementModeActive else { return }
        isCursorMovementModeActive = false
        spaceCursorLastLocationX = nil
        if let root = rootStack { setCursorMovementModeUI(active: false, exceptionView: root) }
    }

    private func setCursorMovementModeUI(active: Bool, exceptionView: UIView) {
        func updateButtons(in view: UIView) {
            for subview in view.subviews {
                if let button = subview as? UIButton, button != exceptionView {
                    button.isUserInteractionEnabled = !active
                    // Apply a subtle disabled visual state to keys during cursor movement mode.
                    let targetAlpha: CGFloat = active ? 0.3 : 1.0
                    button.titleLabel?.alpha = targetAlpha
                    button.imageView?.alpha = targetAlpha
                } else if let stack = subview as? UIStackView {
                    updateButtons(in: stack)
                }
            }
        }
        if let root = rootStack {
            updateButtons(in: root)
        }
    }
}

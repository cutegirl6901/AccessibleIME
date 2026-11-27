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
            // 顺手启动诊断定时器：继续按住到 3 秒就朗读诊断。
            scheduleSpaceDiagnostic()

        case .changed:
            guard let lastX = spaceCursorLastLocationX else { return }
            let currentX = gesture.location(in: spaceButton).x
            let diff = currentX - lastX
            // A 10-point threshold keeps small finger jitter from moving the cursor too aggressively.
            let offset = Int(diff / 10)

            if offset != 0 {
                // 手指真的在拖动 = 在移动光标，不是在等诊断。
                cancelSpaceDiagnostic()
                commitTrace.close(.nextInput)
                textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
                // Compensate the last location by the exact movement distance we just applied
                spaceCursorLastLocationX = lastX + CGFloat(offset * 10)
            }

        case .ended, .cancelled:
            cancelSpaceDiagnostic()
            isCursorMovementModeActive = false
            spaceCursorLastLocationX = nil
            setCursorMovementModeUI(active: false, exceptionView: spaceButton)
            restoreKeyAppearance(spaceButton)

        default:
            break
        }
    }

    /// 启动「按住空格 3 秒朗读诊断」。
    func scheduleSpaceDiagnostic() {
        cancelSpaceDiagnostic()
        spaceDiagnosticTimer = Timer.scheduledTimer(
            withTimeInterval: Self.spaceDiagnosticHoldDuration,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.speakSpaceDiagnostic()
            }
        }
    }

    func cancelSpaceDiagnostic() {
        spaceDiagnosticTimer?.invalidate()
        spaceDiagnosticTimer = nil
    }

    /// 朗读自助诊断。
    ///
    /// 走当前通道发声：这一句能不能听到，本身就说明该通道是否可用。
    func speakSpaceDiagnostic() {
        let message: String
        if let diagnostic = lastSpeechDiagnostic {
            message = "诊断：" + diagnostic
        } else {
            message = "诊断：还没有按键记录。请先输入几个字母，再按住空格三秒。"
        }
        keySpeechAnnouncer.channel.speak(message)
        ProbeLog.log("DIAG_HOLD", [("message", message)])
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

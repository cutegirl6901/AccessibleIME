import UIKit

/// Content-free UIKit tracking terminals used only by Debug diagnostics.
/// They describe pointer lifecycle, never the key label or document content.
enum KeyboardKeyTrackingPhase: String {
    case began
    case endedInside
    case endedOutside
    case cancelled
}

final class KeyboardKeyButton: UIButton {
    /// UIControl still asks the target button whether a tracked touch is inside.
    /// The root hit-test stack assigns visual gaps to explicit per-key cells, and
    /// this slop keeps small finger drift valid through touch-up and long press.
    var touchSlop: CGFloat = 4
    var expandedTouchOutsets: UIEdgeInsets = .zero
    /// Same snapshot `touchFrame`, in this button's coordinates. Overlay on/off
    /// must not change this; `touchUpInside` reads it instead of a second box.
    var localTouchBounds: CGRect?
    var visualStyle: KeyVisualStyle = .character

    /// 九宫格（T9）键要送给 RIME 的数字身份，例如 `"2"`。
    ///
    /// ## 为什么不放在 accessibilityValue
    ///
    /// `accessibilityValue` 是**无障碍专用**字段：VoiceOver 会把它和 label 一起朗读。
    /// 系统键盘正是用它承载「按下后读出的内容」（见 TextInputUI：
    /// 按键自身有 label，候选写进 value）。
    ///
    /// 早先的实现把 `"t9Digit"` 这个业务标记塞进 accessibilityValue，
    /// 导致两个用途抢同一个字段——一旦播报写入候选，T9 身份就丢了，
    /// 后续按键会把显示字符（MNO）当成输入，组合彻底错乱。
    ///
    /// 因此把身份移到这个专用属性上，accessibilityValue 归还给无障碍。
    var t9DigitIdentity: String?

    #if DEBUG
        /// Kept on the button so diagnostics see UIKit's real tracking terminals,
        /// including cancellations that do not result in a business key action.
        var trackingEventHandler: ((KeyboardKeyButton, KeyboardKeyTrackingPhase) -> Void)?
    #endif

    /// Touch geometry follows layout, not the transient press-feedback scale.
    /// UIButton's center/bounds stay stable while its transform animates.
    func touchLayoutFrame(in view: UIView) -> CGRect {
        guard let superview else { return .zero }
        return superview.convert(
            CGRect(
                x: center.x - bounds.width / 2, y: center.y - bounds.height / 2,
                width: bounds.width, height: bounds.height), to: view)
    }

    func touchLayoutBounds(_ rect: CGRect, from view: UIView) -> CGRect {
        guard let superview else { return .zero }
        return superview.convert(rect, from: view).offsetBy(
            dx: bounds.minX - center.x + bounds.width / 2,
            dy: bounds.minY - center.y + bounds.height / 2)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isEnabled, !isHidden, alpha > 0.01 else {
            return false
        }
        if let localTouchBounds {
            return localTouchBounds.contains(point)
        }
        let outsets = UIEdgeInsets(
            top: -max(touchSlop, expandedTouchOutsets.top),
            left: -max(touchSlop, expandedTouchOutsets.left),
            bottom: -max(touchSlop, expandedTouchOutsets.bottom),
            right: -max(touchSlop, expandedTouchOutsets.right)
        )
        return bounds.inset(by: outsets).contains(point)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let accepted = super.beginTracking(touch, with: event)
        #if DEBUG
            if accepted {
                trackingEventHandler?(self, .began)
            }
        #endif
        return accepted
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        #if DEBUG
            let phase: KeyboardKeyTrackingPhase
            if let touch {
                phase = point(inside: touch.location(in: self), with: event) ? .endedInside : .endedOutside
            } else {
                phase = .endedOutside
            }
            trackingEventHandler?(self, phase)
        #endif
        super.endTracking(touch, with: event)
    }

    override func cancelTracking(with event: UIEvent?) {
        #if DEBUG
            trackingEventHandler?(self, .cancelled)
        #endif
        super.cancelTracking(with: event)
    }

}

import KeyboardCore
import UIKit

extension KeyboardViewController {
    /// Adds semantic VoiceOver metadata without coupling accessibility text to visible key glyphs.
    func configureKeyAccessibility(_ button: UIButton, title: String, action: Selector) {
        // UIButton(type:) does not reliably run subclass initializers, and
        // image-only function keys can lose the default AX element flag.
        // The UI harness queries `XCUIElementTypeKey` via `.keyboardKey`.
        button.isAccessibilityElement = true
        // 只给 .keyboardKey，不要加 .button。
        //
        // 真机回归（0.2.19）：加上 .button 后旁白把按键当普通按钮，
        // 必须「双击」才能上屏；系统键盘的字符键是抬手即插入。
        // 旁白对 .keyboardKey 的默认激活方式是单击。
        button.accessibilityTraits = .keyboardKey
        button.accessibilityHint = nil
        button.accessibilityValue = nil

        switch action {
        case #selector(deleteKeyTouchUpInside(_:forEvent:)):
            button.accessibilityIdentifier = "delete"
            button.accessibilityLabel = "删除"
            button.accessibilityHint = "删除光标前的字符。轻点删除一个；按住可连续删除。"

        case #selector(toggleShift(_:)):
            button.accessibilityLabel = "大写"
            button.accessibilityHint = "切换单次大写或大写锁定。"
            button.accessibilityValue = shiftAccessibilityValue
            button.addTarget(
                self,
                action: #selector(refreshShiftAccessibilityValue(_:)),
                for: .touchUpInside
            )

        case #selector(handleInputModeList(from:with:)):
            button.accessibilityIdentifier = "nextKeyboard"
            button.accessibilityLabel = "切换键盘"
            button.accessibilityHint = "按住以选择其他键盘。"

        case #selector(toggleKeyboardPage(_:)):
            button.accessibilityLabel = "键盘页面"
            button.accessibilityValue = keyboardPageAccessibilityValue(for: title)
            button.accessibilityHint = "切换到\(keyboardPageAccessibilityValue(for: title))。"

        case #selector(toggleInputMode(_:)):
            button.accessibilityLabel = "输入语言"
            button.accessibilityValue = inputModeAccessibilityValue(for: title)
            button.accessibilityHint = "切换中文与英文输入。"

        case #selector(insertSpace(_:)):
            button.accessibilityIdentifier = "space"
            button.accessibilityLabel = "空格"
            button.accessibilityValue = spaceAccessibilityValue(for: title)
            button.accessibilityHint = "插入空格。左右滑动可移动光标。"

        case #selector(insertReturn(_:)):
            button.accessibilityIdentifier = "return"
            button.accessibilityLabel = returnKeyAccessibilityLabel(for: title)
            button.accessibilityHint = "执行\(returnKeyAccessibilityLabel(for: title))。"

        case #selector(insertKaomoji(_:)), #selector(showKaomojiCandidatesPlaceholder(_:)):
            button.accessibilityLabel = KaomojiChrome.accessibilityLabel
            button.accessibilityHint = KaomojiChrome.accessibilityHint

        default:
            button.accessibilityLabel = title
        }
    }

    /// 把候选写进刚按下的字符键的 `accessibilityValue`，并让旁白重读该键。
    ///
    /// ## 为什么这样做（对照系统输入法）
    ///
    /// 系统键盘的 `TextInputUI` 二进制里 `UIAccessibilityPostNotification`
    /// 出现 0 次——它从不"播报"，而是：
    ///   1. 按键元素自带 `accessibilityLabel`（键名）
    ///   2. 按下后把候选写进该元素的 `accessibilityValue`
    ///   3. 用 `.layoutChanged` 让旁白重新读这个元素
    /// 旁白于是读出「n，你」。
    ///
    /// 本项目已确认无障碍树是通的（用户滑过按键能读出字母名），
    /// 缺的正是第 2、3 步。
    ///
    /// - Parameter text: 要朗读的候选文本（已由上层按详细程度生成）。
    func refreshTouchedKeyAccessibilityValue(with text: String) {
        guard let key = lastTouchedCharacterKey else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        key.accessibilityValue = trimmed

        // 下一轮主循环再做 layoutChanged：
        // 让 UIKit 先提交本帧布局，旁白才能定位到元素。
        // 直接同步调用在候选栏刚刷新时可能指向旧的树。
        DispatchQueue.main.async { [weak key] in
            guard let key, key.window != nil else { return }
            UIAccessibility.post(notification: .layoutChanged, argument: key)
        }
    }

    @objc private func refreshShiftAccessibilityValue(_ sender: UIButton) {
        sender.accessibilityValue = shiftAccessibilityValue
    }

    private var shiftAccessibilityValue: String {
        switch controller.state.shiftState {
        case .off:
            return "关闭"
        case .singleUse:
            return "单次大写"
        case .capsLock:
            return "大写锁定"
        }
    }

    private func keyboardPageAccessibilityValue(for title: String) -> String {
        switch title {
        case "123":
            return "数字键盘"
        case "#+=":
            return "符号键盘"
        case "😊":
            return "表情键盘"
        case "ABC":
            return "字母键盘"
        default:
            return title
        }
    }

    private func inputModeAccessibilityValue(for title: String) -> String {
        switch title {
        case "中":
            return "中文"
        case "英":
            return "英文"
        default:
            return title
        }
    }

    private func spaceAccessibilityValue(for title: String) -> String? {
        switch title {
        case "拼音":
            return "拼音输入"
        case "English":
            return "英文输入"
        case "选定":
            return "选定首个候选词"
        default:
            return nil
        }
    }

    func returnKeyAccessibilityLabel(for title: String) -> String {
        switch title {
        case "go":
            return "前往"
        case "google", "search":
            return "搜索"
        case "join":
            return "加入"
        case "next":
            return "下一项"
        case "route":
            return "路线"
        case "send":
            return "发送"
        case "yahoo":
            return "雅虎搜索"
        case "done":
            return "完成"
        case "SOS":
            return "紧急呼叫"
        case "continue":
            return "继续"
        default:
            return "回车"
        }
    }
}

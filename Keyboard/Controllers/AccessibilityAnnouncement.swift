import UIKit

/// 向旁白投递朗读文本的统一入口。
///
/// ## 为什么单独抽一个类型
///
/// 键盘里有两条播报路径：
/// 1. 按键后的状态播报（`KeySpeechChannel` 的旁白通道）；
/// 2. 文本真正上屏后的逐字反馈（`announceCommittedTextIfNeeded`）。
///
/// 两条路径必须用**同样的优先级**投递，否则上屏反馈会打断按键播报，
/// 听感与系统输入法不一致。因此把构造逻辑收敛到这里。
enum AccessibilityAnnouncement {

    /// 构造「排在其它语音之后」的公告。
    ///
    /// 用普通 `String` 投递等于 `default` 优先级：会**打断**旁白正在念的
    /// 键名，两条语音互相抢占，历史表现是「时有时无」。
    /// 「排队」的定义是「等其它语音说完再播」，正好得到
    /// 「n → 你」的自然顺序，与系统输入法的听感一致。
    ///
    /// - Note: `UIAccessibilityPriority` 自 iOS 17 起可用，本工程最低 iOS 18。
    static func queued(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .accessibilitySpeechAnnouncementPriority: UIAccessibilityPriority.low
            ]
        )
    }

    /// 投递一条排队公告。空白文本直接忽略。
    ///
    /// `UIAccessibility.post` 在 SDK 里标了 `@MainActor`，因此这里也必须是
    /// 主线程隔离；所有调用方（键盘控制器、播报通道）本来就在主线程。
    @MainActor
    static func postQueued(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: queued(trimmed))
    }
}

import KeyboardCore
import UIKit

/// 按键播报的投递时机。
///
/// 只有一个时机：`syncUI` 之后。
/// 早期版本有 `beforeUISync`，但候选栏数据是在 `syncUI` 内部的
/// `refreshCandidateBar()` 才更新的，在它之前读候选只能拿到上一轮残留
/// （真机表现为「不管输入什么都读同一个字」）。该时机已整体移除。
enum KeySpeechDeliveryTiming: Sendable {
    case afterUISync
}

/// 播报通道协议。
///
/// ## 为什么只剩一条通道
///
/// 历史上试过 7 条（AVSpeechSynthesizer 两种会话、旁白公告两种优先级、
/// 焦点转移、按键值刷新等）。真机结论：
/// - 键盘自己用 AVSpeechSynthesizer 发声：**完全听不到**
/// - `UIAccessibility.post(.announcement)`：只在键盘刚出现时偶尔放行一次
/// - 焦点转移：能出声，但**会把旁白焦点抢到候选栏**，手感不能接受
///
/// 保留多条通道只会让人反复试错。因此只保留一条。
@MainActor
protocol KeySpeechChannel: AnyObject {
    var id: KeySpeechChannelID { get }

    /// 本次播报文本是否要包含键名。
    var includesKeyName: Bool { get }

    /// 朗读一段文本。
    func speak(_ text: String)

    /// 立即停止当前朗读。
    func stop()
}

/// 唯一的播报通道：改写按住的那个键的 accessibilityValue，再让旁白重读它。
///
/// ## 为什么是这个做法
///
/// 1. **不移动焦点**。旁白重新朗读的是用户手指下那个键，
///    焦点不会跳到候选栏，连续打字不会被打断。
/// 2. **不依赖任何播报 API**。系统键盘（TextInputUI）二进制里
///    `UIAccessibilityPostNotification(.announcement)` 出现 0 次，
///    它靠的正是「元素值变化 + 布局通知」。
/// 3. **复用已确认可用的通路**。真机上「滑过按键能读出字母名」，
///    说明键的无障碍树是通的；这里只是把候选写进它的 value。
@MainActor
final class KeyValueSpeechChannel: KeySpeechChannel {
    var id: KeySpeechChannelID { .keyValueRefresh }

    /// 由控制器注入：把文本写进当前按键的 accessibilityValue，
    /// 并用 `.layoutChanged` 指回那个键（不是候选栏）。
    var applyValueToKey: ((String) -> Void)?

    private(set) var speakCallCount = 0

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speakCallCount += 1
        applyValueToKey?(trimmed)
    }

    func stop() {
        // 值刷新无法取消，也不需要。
    }
}

/// 播报通道标识。
///
/// 只保留一个值。保留枚举形式是为了让持久化的旧值（1/2/3/4/6）
/// 在解析失败时安全回退，而不是崩溃。
enum KeySpeechChannelID: Int, CaseIterable, Sendable {
    /// 改写按键 accessibilityValue 并让旁白重读该键。
    case keyValueRefresh = 7

    var shortName: String { "按键值朗读" }
}

/// 创建唯一的播报通道。
@MainActor
enum KeySpeechChannelFactory {
    static func make(_ id: KeySpeechChannelID) -> any KeySpeechChannel {
        switch id {
        case .keyValueRefresh:
            return KeyValueSpeechChannel()
        }
    }
}

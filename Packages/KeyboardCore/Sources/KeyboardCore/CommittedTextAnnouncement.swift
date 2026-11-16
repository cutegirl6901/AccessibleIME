import Foundation

/// 上屏播报的决策逻辑（纯值计算，便于单元测试）。
///
/// 背景：纯键盘输入与触摸候选走不同的提交路径——
/// - 触摸候选：`insertText(source: .candidate)`
/// - 键盘空格/回车确认：`commitInlinePreedit(source: .space / .returnKey)`
///
/// 早期实现只放行 `.candidate` 等来源，导致「只打字、不摸候选」的用户
/// 收不到任何逐字反馈。这里把「该不该播、播什么」收敛成一个可测试的纯函数，
/// UI 层只负责调用与投递通知。
public enum CommittedTextAnnouncement {
    /// 该来源的提交是否需要朗读。
    ///
    /// 放行所有可能承载中文的路径：候选选择、纠错、引擎提交、组合结束，
    /// 以及键盘空格/回车确认。字母直通、直接文本、表情不播报。
    public static func shouldAnnounce(source: CommittedTextSource) -> Bool {
        switch source {
        case .candidate, .correction, .engineCommit, .compositionFinalization,
            .space, .returnKey:
            return true
        case .key, .directText, .emoji:
            return false
        }
    }

    /// 文本是否至少包含一个汉字。
    ///
    /// 覆盖基本区、扩展 A、扩展 B（含「𠮷」等常用扩展字）与兼容表意文字。
    public static func containsHan(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where isHanScalar(scalar.value) {
            return true
        }
        return false
    }

    static func isHanScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x3400...0x4DBF,      // 扩展 A
            0x4E00...0x9FFF,      // 基本区
            0xF900...0xFAFF,      // 兼容表意文字
            0x20000...0x2A6DF,    // 扩展 B
            0x2A700...0x2EBEF,    // 扩展 C–F
            0x30000...0x3134F:    // 扩展 G
            return true
        default:
            return false
        }
    }

    /// 计算要交给 VoiceOver 的朗读文本；不需要播报时返回 nil。
    ///
    /// - Parameters:
    ///   - text: 真正写入输入框的文本（已确认的汉字，不是拼音）。
    ///   - source: 提交来源。
    ///   - lastAnnounced: 上一次已播报过的文本（用于避免连续重复整段）。
    ///   - table: 汉字描述表。
    public static func announcement(
        for text: String,
        source: CommittedTextSource,
        lastAnnounced: String?,
        table: CharacterDescriptionTable
    ) -> String? {
        guard shouldAnnounce(source: source) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 纯标点、纯空格、纯拉丁串不播报。
        guard containsHan(trimmed) else { return nil }
        // 连续两次提交相同文本时只读词本身，避免整段解释被连着读两遍。
        if text == lastAnnounced { return trimmed }
        return CharacterDescriptionSpeech.announcement(for: trimmed, table: table)
    }
}

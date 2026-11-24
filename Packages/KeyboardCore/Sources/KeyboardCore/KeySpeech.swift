import Foundation

// MARK: - 播报密度

/// 按键朗读的详细程度。
///
/// 基线文档中早已确认「简洁 / 标准 / 详细」三档，但一直未实现。
/// 这里把它实现为纯值类型，便于单元测试与持久化。
public enum KeySpeechDetail: Int, CaseIterable, Sendable {
    /// 只读候选词本身，例如「你」。
    case concise = 0

    /// 候选词 + 逐字解释，例如「你，你们的你」。（默认）
    case standard = 1

    /// 候选词 + 读音 + 逐字解释，例如「你，nǐ，你们的你」。
    case detailed = 2
}

// MARK: - 按键类别

/// 按键在朗读语义上的类别。决定播报用的是键名还是更新后的输入状态。
public enum KeySpeechKind: Equatable, Sendable {
    /// 字母键：中文模式下播报「键名，当前首候选」。
    case letter
    /// 数字键：播报数字本身。
    case digit
    /// 标点键：播报标点名称（来自描述表），查不到则读原字符。
    case punctuation
    /// 删除键：播报被删掉的内容。
    case delete
    /// 选择候选：播报真正上屏的内容。
    case candidate
    /// 空格键：有上屏文本时播报上屏内容，否则读「空格」。
    case space
    /// 回车键：有上屏文本时播报上屏内容，否则读「回车」。
    case returnKey
    /// 大小写键：播报切换后的状态。
    case shift
    /// 中英文切换：播报切换后的模式。
    case inputMode
    /// 键盘页面切换：播报目标页面。
    case keyboardPage
    /// 其它功能键（表情、颜表情等）：播报键名。
    case function
}

// MARK: - 快照

/// 一次按键处理完成后、同一同步时刻捕获的输入状态。
///
/// 关键约束：这个快照必须在 `controller.handle(...)` **返回之后立即**构造。
/// 之后所有朗读都只读这份快照，不再回读 `controller.state`。
/// 这样才能保证「异步候选计算完成后朗读的是这次按键的结果」，
/// 而不是下一步输入的结果。
public struct KeySpeechSnapshot {
    public var kind: KeySpeechKind
    /// 按键自身的可读名称，例如 "n"、"3"、"逗号"。
    public var keyLabel: String
    public var inputMode: InputMode
    public var page: KeyboardPage
    public var shiftState: ShiftState
    /// 当前未上屏的拼音串，例如 "nihao"。
    public var composition: String
    /// 当前页候选文字，按显示顺序。
    public var candidates: [String]
    /// 与 `candidates` 一一对应的 RIME 注释（通常是拼音）。
    public var candidateComments: [String?]
    /// 本次按键上屏的文本（若有）。
    public var committedText: String?
    /// 本次删除掉的文本（若有）。
    public var deletedText: String?
    /// 捕获时的组合修订号，用于诊断与过期判定。
    public var revision: UInt64

    public init(
        kind: KeySpeechKind,
        keyLabel: String,
        inputMode: InputMode,
        page: KeyboardPage,
        shiftState: ShiftState,
        composition: String = "",
        candidates: [String] = [],
        candidateComments: [String?] = [],
        committedText: String? = nil,
        deletedText: String? = nil,
        revision: UInt64 = 0
    ) {
        self.kind = kind
        self.keyLabel = keyLabel
        self.inputMode = inputMode
        self.page = page
        self.shiftState = shiftState
        self.composition = composition
        self.candidates = candidates
        self.candidateComments = candidateComments
        self.committedText = committedText
        self.deletedText = deletedText
        self.revision = revision
    }
}

// MARK: - 文本生成

/// 把一次按键的状态快照转成 VoiceOver 要读的文本。
///
/// 所有数据驱动，不含任何写死的候选词或释义。
public enum KeySpeechComposer {

    /// 生成播报文本；返回 nil 表示这次按键不需要额外播报。
    ///
    /// - Parameter includeKeyName: 是否由键盘自己再念一遍键名。
    ///   走旁白公告时传 `false`：旁白在焦点落到按键时已经念过键名，
    ///   再拼一遍就是双重朗读，听感与系统输入法差别很大。
    ///   只有键盘自己发声（不经过旁白）的通道才需要 `true`。
    public static func compose(
        _ snapshot: KeySpeechSnapshot,
        detail: KeySpeechDetail,
        table: CharacterDescriptionTable,
        includeKeyName: Bool = true
    ) -> String? {
        switch snapshot.kind {
        case .delete:
            guard let deleted = snapshot.deletedText, !deleted.isEmpty else { return nil }
            let spoken = fragment(for: deleted, detail: detail, table: table)
            return "已删除 \(spoken)"

        case .candidate, .space, .returnKey:
            // 只有空白（例如回车换行）没有可读内容，交给下面的键名兜底。
            if let committed = snapshot.committedText,
                !committed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return fragment(for: committed, detail: detail, table: table)
            }
            // 没有上屏文本时的兜底。旁白通道下空格/回车保持安静：
            // 旁白已经念过键名，这里再补一条只是重复。
            switch snapshot.kind {
            case .candidate: return snapshot.keyLabel.isEmpty ? nil : snapshot.keyLabel
            case .space: return includeKeyName ? "空格" : nil
            default: return includeKeyName ? "回车" : nil
            }

        case .shift:
            switch snapshot.shiftState {
            case .off: return "小写"
            case .singleUse: return "单次大写"
            case .capsLock: return "大写锁定"
            }

        case .inputMode:
            return snapshot.inputMode == .chinese ? "中文输入" : "英文输入"

        case .keyboardPage:
            return pageName(snapshot.page)

        case .letter:
            return letterSpeech(
                snapshot,
                detail: detail,
                table: table,
                includeKeyName: includeKeyName
            )

        case .digit, .punctuation, .function:
            // 键名交给旁白。键盘只在有「新信息」时才补充一条：
            // 中文模式下数字/标点同样会参与组字，因此要看当前首候选。
            if includeKeyName {
                if snapshot.kind == .punctuation,
                    let glyph = snapshot.keyLabel.first,
                    let name = table.description(for: glyph)
                {
                    return name
                }
                return snapshot.keyLabel
            }
            return supplementarySpeech(snapshot, detail: detail, table: table)
        }
    }

    // MARK: 分项

    private static func letterSpeech(
        _ snapshot: KeySpeechSnapshot,
        detail: KeySpeechDetail,
        table: CharacterDescriptionTable,
        includeKeyName: Bool
    ) -> String? {
        // 英文模式没有候选语义。
        // 走旁白公告（includeKeyName = false）时保持安静：
        // 旁白已经在念这个字母，键盘再念一遍就是双重朗读。
        guard snapshot.inputMode == .chinese else {
            guard includeKeyName else { return nil }
            return snapshot.keyLabel.isEmpty ? nil : snapshot.keyLabel
        }

        // 字母键也可能直接上屏（标点自动接纳、T9 组合结束等）。
        // 这时上屏文本才是新信息，候选列表可能是空的。
        if let committed = snapshot.committedText,
            !committed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let spoken = fragment(for: committed, detail: detail, table: table)
            guard includeKeyName, !snapshot.keyLabel.isEmpty else { return spoken }
            return "\(snapshot.keyLabel)，\(spoken)"
        }

        if let top = snapshot.candidates.first, !top.isEmpty {
            let comment = snapshot.candidateComments.first ?? nil
            let candidate = referentSpeech(top, comment: comment, detail: detail, table: table)
            guard includeKeyName, !snapshot.keyLabel.isEmpty else { return candidate }
            return "\(snapshot.keyLabel)，\(candidate)"
        }

        // 没有候选时的退路。
        //
        // 键盘自己发声（includeKeyName = true）读「键名，拼音」，让用户知道自己打出什么；
        // 走旁白公告（false）必须保持安静——旁白已经在念这个键，
        // 再读一遍拼音串就是双重朗读。
        if !snapshot.composition.isEmpty {
            guard includeKeyName else { return nil }
            guard !snapshot.keyLabel.isEmpty else { return snapshot.composition }
            return "\(snapshot.keyLabel)，\(snapshot.composition)"
        }

        // 走到这里说明既没有候选也没有拼音。
        // 旁白通道保持安静：没有新信息，读键名只会和旁白重复。
        guard includeKeyName else { return nil }
        return snapshot.keyLabel.isEmpty ? nil : snapshot.keyLabel
    }

    /// 只读「按键带来的新信息」：上屏文本优先，其次首候选。
    ///
    /// 用于旁白通道（`includeKeyName = false`）：键名已由旁白读出，
    /// 键盘只在确实产生了新内容时才补一条，避免重复朗读。
    private static func supplementarySpeech(
        _ snapshot: KeySpeechSnapshot,
        detail: KeySpeechDetail,
        table: CharacterDescriptionTable
    ) -> String? {
        if let committed = snapshot.committedText,
            !committed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return fragment(for: committed, detail: detail, table: table)
        }
        if let top = snapshot.candidates.first, !top.isEmpty {
            let comment = snapshot.candidateComments.first ?? nil
            return referentSpeech(top, comment: comment, detail: detail, table: table)
        }
        return nil
    }

    /// 候选/上屏文本的朗读形式。
    static func fragment(
        for text: String,
        detail: KeySpeechDetail,
        table: CharacterDescriptionTable
    ) -> String {
        referentSpeech(text, comment: nil, detail: detail, table: table)
    }

    /// 候选词的整体朗读：优先整词读音，其次逐字解释。
    public static func referentSpeech(
        _ text: String,
        comment: String?,
        detail: KeySpeechDetail,
        table: CharacterDescriptionTable
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        // 纯 ASCII 交给系统读，避免把 "a" 读成 NATO 的 "Alfa"。
        if isASCIIOnly(trimmed) { return trimmed }

        // 含汉字：先给词，再给解释。
        guard containsHan(trimmed) else {
            // 纯标点/符号：优先用描述表的名称（如「，」→「逗号」）。
            if let name = table.description(for: firstCharacter(of: trimmed)) {
                return name
            }
            return trimmed
        }

        if detail == .concise { return trimmed }

        var parts: [String] = [trimmed]

        if detail == .detailed, let comment, !comment.isEmpty,
            comment.lowercased() != trimmed.lowercased()
        {
            parts.append(comment)
        }

        let explanations = CharacterDescriptionSpeech.perCharacterDescriptions(for: trimmed, table: table)
        parts.append(contentsOf: explanations)
        return parts.joined(separator: "，")
    }

    private static func pageName(_ page: KeyboardPage) -> String {
        switch page {
        case .letters: return "字母键盘"
        case .numbers: return "数字键盘"
        case .symbols: return "符号键盘"
        case .emoji: return "表情键盘"
        }
    }

    private static func firstCharacter(of text: String) -> Character {
        text.first ?? " "
    }

    public static func isASCIIOnly(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { $0.isASCII }
    }

    public static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                0x20000...0x2A6DF, 0x2A700...0x2EBEF, 0x30000...0x3134F:
                return true
            default:
                return false
            }
        }
    }

    /// 把按键字符串归类，供 UI 层决定播报路径。
    public static func classify(key: String) -> KeySpeechKind {
        guard key.count == 1, let first = key.first else { return .function }
        if first.isLetter { return .letter }
        if first.isNumber { return .digit }
        // 只认标点。emoji 也属于 Unicode 的 Symbol 类，不能算标点，
        // 否则会去描述表里查「😊」并给出奇怪的结果。
        if first.isPunctuation { return .punctuation }
        return .function
    }
}

import Foundation

/// 单个字符的朗读描述来源（NVDA 字典）。
///
/// 数据随 KeyboardCore 资源打包，离线可用：
/// - `CharDescriptions/zh_CN.compact.txt`
/// - `CharDescriptions/zh_TW.compact.txt`
///
/// 原始字典受 GPL 约束，精简派生与来源说明见
/// `CharDescriptions/SOURCES.md`。
public struct CharacterDescriptionTable: Sendable {
    /// 字符 → 第一条描述（已去掉外层括号前不处理，保留原始描述）。
    private let entries: [Character: String]

    public var count: Int { entries.count }

    public init(entries: [Character: String]) {
        self.entries = entries
    }

    /// 查一个字符的第一条描述；没有则返回 nil。
    public func description(for character: Character) -> String? {
        entries[character]
    }

    /// 是否有该字符的条目。
    public func contains(_ character: Character) -> Bool {
        entries[character] != nil
    }
}

// MARK: - 解析

extension CharacterDescriptionTable {
    /// 解析 NVDA `characterDescriptions.dic` 格式的文本。
    ///
    /// 格式约定：
    /// - UTF-8，允许 BOM
    /// - `#` 开头为注释，空行忽略
    /// - 以真实 Tab 分列：第一列字符，其余列为有序描述
    /// - 只取第一条描述；键必须恰好是一个 Unicode 字符（字素簇）
    public static func parse(_ text: String) -> CharacterDescriptionTable {
        var entries: [Character: String] = [:]
        entries.reserveCapacity(32_768)

        var body = text
        if body.hasPrefix("\u{FEFF}") {
            body.removeFirst()
        }

        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty || line.hasPrefix("#") { continue }

            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 2 else { continue }

            let key = String(columns[0])
            // 只接受单字符键；多字符行多为上游数据异常，跳过以免污染查表。
            guard key.count == 1, let character = key.first else { continue }

            let firstDescription = String(columns[1]).trimmingCharacters(in: .whitespaces)
            guard !firstDescription.isEmpty else { continue }
            entries[character] = firstDescription
        }

        return CharacterDescriptionTable(entries: entries)
    }

    /// 从 bundle 资源加载。语言代码形如 `zh_CN` / `zh_TW`。
    ///
    /// 找不到资源时返回空表，调用方应回退到原字符朗读，不影响输入。
    public static func load(languageCode: String, bundle: Bundle? = nil) -> CharacterDescriptionTable {
        let bundle = bundle ?? .module
        let name = resourceName(for: languageCode)
        guard
            let url = bundle.url(forResource: name, withExtension: "txt", subdirectory: "CharDescriptions")
                ?? bundle.url(forResource: name, withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return CharacterDescriptionTable(entries: [:])
        }
        return parse(text)
    }

    /// 按系统首选语言挑一个可用的资源语言代码，优先简体。
    static func resourceName(for languageCode: String) -> String {
        let normalized = languageCode.lowercased()
        if normalized.hasPrefix("zh") {
            // 繁体地区使用繁体字典，其余中文一律简体。
            let traditional = ["tw", "hk", "mo", "hant"]
            if traditional.contains(where: { normalized.contains($0) }) {
                return "zh_TW.compact"
            }
            return "zh_CN.compact"
        }
        return "zh_CN.compact"
    }
}

// MARK: - 朗读格式化

public enum CharacterDescriptionSpeech {
    /// 单个字符的朗读描述。
    ///
    /// 规则：
    /// - 第一条描述被 ASCII 括号完整包围时，去掉外层括号直接用，例如
    ///   `(我们的我)` → `我们的我`
    /// - 否则按「描述＋的＋原字」，例如繁体 `我們` → `我們的我`
    /// - 查不到时回退原字符
    public static func spokenDescription(
        for character: Character,
        table: CharacterDescriptionTable
    ) -> String {
        guard let raw = table.description(for: character) else {
            return String(character)
        }
        let stripped = stripWrappingParentheses(raw)
        if stripped != raw {
            // 原文带外层括号：剥离后即为完整说法，不再追加「的」和原字。
            return stripped.isEmpty ? String(character) : stripped
        }
        return "\(raw)的\(character)"
    }

    /// 为一段候选文本生成逐字解释，例如
    /// 「我们」→「我们的我，我们的们」。
    ///
    /// 说明：
    /// - 按字素簇遍历，不会拆坏扩展汉字
    /// - 同一字符只解释一次，避免「我们的我的我」这类重复
    /// - 全部查不到时返回空数组，调用方回退为只读原词
    public static func perCharacterDescriptions(
        for text: String,
        table: CharacterDescriptionTable
    ) -> [String] {
        var seen: Set<Character> = []
        var result: [String] = []
        for character in text {
            // 空白不参与解释
            if character.isWhitespace { continue }
            if seen.contains(character) { continue }
            seen.insert(character)

            guard table.contains(character) else { continue }
            result.append(spokenDescription(for: character, table: table))
        }
        return result
    }

    /// 候选在 VoiceOver 中应朗读的完整文案。
    ///
    /// 有解释时：「我们，我们的我，我们的们」
    /// 无解释时：原词（不额外拼接）
    public static func announcement(
        for text: String,
        table: CharacterDescriptionTable
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        let parts = perCharacterDescriptions(for: trimmed, table: table)
        guard !parts.isEmpty else { return trimmed }
        return "\(trimmed)，" + parts.joined(separator: "，")
    }

    /// 去掉完整包裹描述的外层 ASCII 括号。只有首尾成对且内部不含更外层括号时才算。
    static func stripWrappingParentheses(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("("), trimmed.hasSuffix(")") else {
            return text
        }
        let inner = String(trimmed.dropFirst().dropLast())
        // 内部若还有不匹配的括号，说明不是"完整包裹"，保持原样。
        if inner.contains("(") || inner.contains(")") { return text }
        return inner
    }
}

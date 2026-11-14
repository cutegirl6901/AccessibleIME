import Foundation

/// 懒加载的汉字描述表，供候选朗读使用。
///
/// 字典约 1 MB，只在首次朗读时加载一次；资源缺失时返回空表，
/// 朗读自动退回原字符，不影响输入。
///
/// 说明：整个类型标为 `@MainActor`——朗读与候选更新都发生在主线程，
/// 与键盘 UI 生命周期一致，也满足工程的 Swift 6 严格并发检查。
@MainActor
public enum CharacterDescriptionTableProvider {
    private static var cached: CharacterDescriptionTable?

    /// 共享实例。首次访问时从资源加载。
    public static var shared: CharacterDescriptionTable {
        if let cached { return cached }
        let table = CharacterDescriptionTable.load(languageCode: preferredLanguageCode())
        cached = table
        return table
    }

    /// 测试注入入口，避免依赖真实资源。
    public static func overrideForTesting(_ table: CharacterDescriptionTable?) {
        cached = table
    }

    /// 首选字典语言：跟随系统语言，繁体走繁体表，其余走简体表。
    static func preferredLanguageCode() -> String {
        Locale.preferredLanguages.first ?? "zh-Hans"
    }
}

import Foundation
import Synchronization

/// 懒加载的汉字描述表，供候选朗读使用。
///
/// 字典约 1 MB，只在首次朗读时加载一次；资源缺失时返回空表，
/// 朗读自动退回原字符，不影响输入。
///
/// 并发：缓存由 `Mutex` 保护。返回值 `CharacterDescriptionTable` 是
/// 只读的 `Sendable` 值类型，因此调用方（UIKit 代码或单元测试）
/// 无需 MainActor 隔离即可安全读取。
public final class CharacterDescriptionTableProvider: Sendable {
    private let cached: Mutex<CharacterDescriptionTable?>

    /// 共享实例。首次访问时从资源加载。
    public static let shared = CharacterDescriptionTableProvider()

    public init() {
        cached = Mutex(nil)
    }

    /// 当前可用的描述表，必要时加载。
    public var table: CharacterDescriptionTable {
        cached.withLock { value in
            if let value { return value }
            let loaded = CharacterDescriptionTable.load(languageCode: Self.preferredLanguageCode())
            value = loaded
            return loaded
        }
    }

    /// 测试注入入口，避免依赖真实资源。
    public func overrideForTesting(_ table: CharacterDescriptionTable?) {
        cached.withLock { $0 = table }
    }

    /// 首选字典语言：跟随系统语言，繁体走繁体表，其余走简体表。
    static func preferredLanguageCode() -> String {
        Locale.preferredLanguages.first ?? "zh-Hans"
    }
}

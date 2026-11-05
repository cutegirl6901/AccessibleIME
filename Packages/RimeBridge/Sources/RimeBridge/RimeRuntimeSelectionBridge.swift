import Foundation
import KeyboardCore

/// Shared App Group resolution for base scheme + layout + T9 readiness.
enum RimeRuntimeSelectionBridge {
    /// 原型说明：不使用 App Group，方案选择读取键盘扩展自己的标准存储。
    static let appGroupID = "group.com.DoubleShy0N.Universe-Keyboard"

    /// 原型专用：无完全访问、无 App Group 时使用的本地存储。
    static var localDefaults: UserDefaults { .standard }

    static func resolve(
        defaults: UserDefaults? = localDefaults,
        sharedDataDir: String? = nil
    ) -> RimeRuntimeSelection {
        let fingerprint = sharedDataDir.flatMap { dir in
            let url = URL(fileURLWithPath: dir).appendingPathComponent("t9.schema.yaml")
            return RimeT9Readiness.fingerprint(ofFileAt: url)
        }
        return RimeRuntimeSelection.resolve(defaults: defaults, onDiskFingerprint: fingerprint)
    }
}

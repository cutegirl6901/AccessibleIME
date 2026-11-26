import Foundation
import os

/// 真机诊断探针（方案 A）。
///
/// ## 为什么需要它
///
/// 本项目无法通过 App Group 把键盘扩展的诊断交给主 App：
/// 两个 target 的 entitlements 都是空的，完全访问又是关闭的，
/// 因此 `UserDefaults.standard` 彼此隔离，`Logger` 写的内容主 App 读不到。
///
/// 但键盘扩展**可以**写系统日志，而系统日志可以用数据线读取：
///
/// ```
/// idevicesyslog -m AccessibleIMEProbe
/// ```
/// 或 macOS 上：
/// ```
/// log stream --device --predicate 'subsystem == "com.accessibleime.probe"'
/// ```
///
/// 因此这里把排查所需的最小信息直接投到系统日志，绕过所有共享容器限制。
///
/// ## 输出约定
///
/// 每条日志以 `PROBE|` 开头，字段用 ` | ` 分隔，便于肉眼扫读和脚本切分。
/// 不记录用户实际输入的候选文字内容（隐私），只记录长度、数量、通道号等结构性信息。
public enum ProbeLog {

    /// 固定子系统名，供过滤使用。改动会破坏已有的读取脚本。
    public static let subsystem = "com.accessibleime.probe"

    private static let logger = os.Logger(subsystem: subsystem, category: "keyboard")

    /// 开关：由键盘自己的标准存储控制，主 App 无法写入（容器隔离）。
    /// 默认开启，因为当前阶段排查优先；验证结束后可改为 false 减少日志量。
    public static var isEnabled = true

    /// 写一条探针日志。
    ///
    /// - Parameters:
    ///   - tag: 事件短名，例如 `SPEAK`、`CHANNEL`、`LIFECYCLE`。
    ///   - fields: 键值对，会按 `k=v` 拼接。
    public static func log(_ tag: String, _ fields: [(String, String)]) {
        guard isEnabled else { return }
        let body = fields.map { "\($0.0)=\($0.1)" }.joined(separator: " | ")
        logger.info("PROBE|\(tag, privacy: .public)|\(body, privacy: .public)")
    }

    /// 便捷重载：单个键值。
    public static func log(_ tag: String, _ key: String, _ value: String) {
        log(tag, [(key, value)])
    }
}

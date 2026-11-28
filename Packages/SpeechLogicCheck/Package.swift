// swift-tools-version: 6.0
import PackageDescription

/// 播报逻辑的独立验证包。
///
/// ## 为什么单独建一个包
///
/// KeyboardCore 依赖 CoreGraphics（ChromeTouchHitGeometry.swift 等），
/// 无法在 Linux 上编译；而 macOS runner 近期频繁排队 20 分钟后超时取消，
/// 导致播报相关测试根本跑不起来。
///
/// 这个包只包含「按键播报文本生成」所需的三个文件副本
/// （KeySpeech / CharacterDescriptionTable / SupportTypes），
/// 纯 Foundation，可在 Ubuntu 上几十秒内跑完。
///
/// ## 与主代码的关系
///
/// 源文件是**复制**过来的，不是链接。为防止漂移：
/// 1. CI 里会逐字节比对副本与 KeyboardCore 中的原件（scripts/check-speech-mirror.sh）
/// 2. 测试里会检查枚举 case 名称一致
/// 只要主代码改了而副本没同步，校验就会失败。
let package = Package(
    name: "SpeechLogicCheck",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SpeechLogicCheck"),
        .testTarget(
            name: "SpeechLogicCheckTests",
            dependencies: ["SpeechLogicCheck"]
        ),
    ]
)

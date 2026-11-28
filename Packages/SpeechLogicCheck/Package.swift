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
        .target(
            name: "SpeechLogicCheck",
            // Bundle.module 需要 target 声明资源。
            // 这两个字典与 KeyboardCore 里的是同一份文件（同样由
            // check-speech-mirror.sh 校验），因此这里也能验证真实字典解析。
            resources: [.copy("Resources/CharDescriptions")]
        ),
        .testTarget(
            name: "SpeechLogicCheckTests",
            dependencies: ["SpeechLogicCheck"]
        ),
    ]
)

import KeyboardCore
import SwiftUI

/// 设置 → 输入体验 → 按键播报。
///
/// 这里配置的是「用户按键时的主动反馈」，与 VoiceOver 探索候选时的朗读是两条路径：
/// 前者由键盘主动发公告，后者由候选按钮的 accessibilityLabel 决定。
/// 两者共用同一份候选文本与逐字解释数据，因此不会出现读法不一致。
///
/// 默认配置（排队公告 + 每次按键播报）对齐系统输入法的听感：
/// 旁白先念键名，候选排在其后播出；输入一个字符就播报一次，不合并。
struct KeySpeechSettingsView: View {
    // 关闭完全访问时 App Group 不可用，主 App 与键盘扩展无法共享容器。
    // 键盘侧读取顺序是「标准存储优先、App Group 兜底」，这里同样写标准存储。
    private let defaults = UserDefaults.standard

    @AppStorage("key_speech_detail", store: UserDefaults.standard)
    private var detail: Int = KeySpeechDetail.standard.rawValue

    @AppStorage("key_speech_delivery_mode", store: UserDefaults.standard)
    private var deliveryMode: String = "immediate"

    var body: some View {
        Form {
            Section {
                Text("默认设置不用改。回到键盘打一个字母，应该能听到该键和当前候选。")
                Text("若想确认播报是否正常：摸到左下角的「切换键盘」键，它会报出最近一次播报状态。")
            } header: {
                Text("怎么用")
            }

            Section {
                Picker("播报详细程度", selection: $detail) {
                    Text("简洁").tag(KeySpeechDetail.concise.rawValue)
                    Text("标准").tag(KeySpeechDetail.standard.rawValue)
                    Text("详细").tag(KeySpeechDetail.detailed.rawValue)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("播报详细程度")
            } footer: {
                Text(detailDescription)
            }

            Section {
                Picker("播报方式", selection: $deliveryMode) {
                    Text("每次按键都播报（推荐）").tag("immediate")
                    Text("等上一条读完").tag("sequential")
                    Text("关闭按键播报").tag("off")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("播报方式")
            } footer: {
                Text(deliveryModeDescription)
            }

        }
        .navigationTitle("按键播报")
        .tint(.primary)
        .onChange(of: detail) { _, _ in defaults.synchronize() }
        .onChange(of: deliveryMode) { _, _ in defaults.synchronize() }
    }

    private var detailDescription: String {
        switch KeySpeechDetail(rawValue: detail) ?? .standard {
        case .concise:
            return "只读候选词本身，例如「你」。最快，但同音字较难区分。"
        case .standard:
            return "候选词加逐字解释，例如「你，你们的你」。"
        case .detailed:
            return "再加 RIME 提供的读音，例如「你，nǐ，你们的你」。"
        }
    }

    private var deliveryModeDescription: String {
        switch deliveryMode {
        case "sequential":
            return "等系统报告上一条读完再播下一条。更像传统读屏软件，但每条之间会有明显停顿；系统若不回调则会退化为立即模式。"
        case "off":
            return "按键不再主动播报，只能通过移动焦点逐项浏览候选。"
        default:
            return "输入一个字符就播报一次，不合并。候选排在键名之后朗读，不打断旁白。"
        }
    }
}

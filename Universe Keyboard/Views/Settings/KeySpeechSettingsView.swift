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

    // 语音通道。默认 3 = 旁白公告（低优先级排队）：旁白先念键名，候选随后跟上。
    @AppStorage("key_speech_channel", store: UserDefaults.standard)
    private var channel: Int = 3

    var body: some View {
        Form {
            Section {
                Text("默认设置不用改。回到键盘打一个字母，应该先听到键名，紧接着听到候选。")
                Text("如果完全听不到候选，在键盘上三击大小写键换下一条语音通道，再试一次。")
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

            Section {
                Picker("语音通道", selection: $channel) {
                    Text("三，旁白公告，排队朗读（推荐）").tag(3)
                    Text("六，旁白公告，打断上一句").tag(6)
                    Text("一，应用语音，独立音频会话").tag(1)
                    Text("二，应用语音，播放类别混音").tag(2)
                    Text("四，旁白焦点转移").tag(4)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("语音通道")
            } footer: {
                Text(channelDescription)
                Text("也可以在键盘上三击大小写键循环切换，切到时键盘会先读通道名。若听不到通道名，就说明这条通道没声音。")
            }

            Section {
                Text("只有通道三走旁白自己的语音与语速，听感与系统输入法一致。")
                Text("通道一、二由键盘自己发声，用固定语速，不会排队，也不会移动焦点。")
                Text("候选词本身的无障碍标签始终包含逐字解释，无论这里怎么设置；关闭按键播报只影响「按键」反馈。")
            }
        }
        .navigationTitle("按键播报")
        .tint(.primary)
        .onChange(of: detail) { _, _ in defaults.synchronize() }
        .onChange(of: deliveryMode) { _, _ in defaults.synchronize() }
        .onChange(of: channel) { _, _ in defaults.synchronize() }
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

    private var channelDescription: String {
        // 说明每条通道的行为，以及什么时候该换别的通道。
        switch channel {
        case 1:
            return "一：键盘自己发声，不使用应用音频会话。若扩展里默认会话被静音，这条会绕开它。"
        case 2:
            return "二：键盘自己发声，并把音频会话设为播放混音。用于验证静音开关打开时能否出声。"
        case 4:
            return "四：把旁白焦点移到第一个候选，靠焦点变化朗读。会抢走按键焦点，连续打字手感与系统键盘不同。"
        case 6:
            return "六：每键一条旁白公告，但会打断上一句。快速连打时总是读最新一条，代价是键名可能被切掉。"
        default:
            return "三：发一条低优先级旁白公告，排在键名之后朗读。不移动焦点、不打断旁白，最接近系统输入法。"
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

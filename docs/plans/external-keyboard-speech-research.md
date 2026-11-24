# 外部输入法「键盘内朗读」实现调研

> 日期：2026-11-23
> 目的：回答「为什么候选朗读一直静默」，并给出可下载对照的现成输入法
> 方法：Apple 官方文档 + Stack Overflow + 真实上架/开源键盘的 Info.plist 与源码
> 关联：`docs/plans/key-speech-channel-spike.md`、`docs/architecture/decisions/0007-full-access-and-privacy-boundary.md`

## 一、结论

**键盘扩展要「自己发声」（`AVSpeechSynthesizer` / `AudioServicesPlaySystemSound`），
必须开启完全访问（`RequestsOpenAccess = true`）。**

这不是时序问题，是能力边界问题。五通道 spike 的假设（「换时机就能出声」）方向本身有偏差：
通道 1/2 走的是「扩展自己发声」，在完全访问关闭时**注定静默**，与调用时机无关。

## 二、证据

### 1. Apple 官方：音频被明确列为完全访问能力

Custom Keyboard 文档（Extensibility Programming Guide）中，
把 `RequestsOpenAccess` 设为 YES 后获得的能力里明确写着：

> Ability to play audio, including keyboard clicks using the **playInputClick** method

同一页也写明，完全访问关闭时键盘「只能履行基础键盘职责」，不包含音频能力。

### 2. Stack Overflow：按键音必须开完全访问

| 问题 | 票数 | 关键结论 |
|---|---|---|
| Play standard iOS keyboard click sound in Custom Keyboard Extension | 18 | 必须在后台队列调用 `AudioServicesPlaySystemSound`，且**完全访问开启时才会响** |
| Playing system click sound in iOS keyboard extension | 2（采纳） | 注释原文：**If Open Access=Off, no click sound.** |
| iOS swift custom keyboard no sound and delay | 0（采纳） | 同上，并需在扩展 Info.plist 里声明 |

### 3. 真实产品横向对比（全部来自各自仓库的 Info.plist）

| 产品 | 键盘内朗读 | `RequestsOpenAccess` |
|---|---|---|
| 粤拼 yuetyam/jyutping | **有**（`Keyboard/Speech/Speech.swift`） | **true** |
| 仓输入法 imfuxiao/Hamster | 有（按键音/反馈） | **true** |
| 松烟 Suzukaa-a/songyan-ios | 有 | **true** |
| stoat-keyboard（注音 RIME） | 有 | **true** |
| Universe-Keyboard（本项目上游） | — | **true** |
| OpenBlabber | 有 | **true** |
| jboard | 无（只走 `UIAccessibility`） | false |
| **AccessibleIME（本项目）** | **静默** | **false** |

规律非常干净：**要求键盘自己发声的产品，全部声明了完全访问；唯一 false 的 jboard 恰好不做键盘内朗读。**

### 4. 源码摘录：粤拼怎么做（一个已上架、能在键盘里朗读的实现）

```swift
// Keyboard/Speech/Speech.swift
nonisolated(unsafe) private static let synthesizer: AVSpeechSynthesizer = {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = delegate      // delegate 记录 isSpeaking
        return synthesizer
}()

static func speak(_ text: String, isRomanization: Bool = true) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice              // 指定 zh-HK 粤语音色
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
        synthesizer.speak(utterance)
}
static func stop() {
        synthesizer.stopSpeaking(at: .immediate)
}
```

要点：单例合成器 + delegate 记录 `isSpeaking` + `stop` 打断，
与我们在 `AppVoiceSpeechChannel` 里的写法**基本一致**——差别只在 Info.plist 的开关。

按键音走另一条路：

```swift
// Keyboard/SharedModels/AudioFeedback.swift
enum AudioFeedback: SystemSoundID {
        case input = 1123
        case delete = 1155
        case modify = 1156
        static func perform(_ feedback: AudioFeedback) {
                AudioServicesPlaySystemSound(feedback.rawValue)
        }
}
```

### 5. 上架中文输入法的自述（第三方旁证）

- **ReRime 输入法**（RIME 内核、支持旁白、iOS 26+）：
  「不开完全访问也能打中文和英文；**开启后**可以保存学习记录，
  并使用剪贴板、**按键音、触感**和整句候选的免费体验」
- **RooQi Keyboard**：「基础输入无需完全访问；
  **键盘翻译和朗读在部分系统版本（包括 iOS 18）需要开启完全访问**」
- **落格输入法 X**：明确面向视障用户，「解释库……每个字只取一个最常见且更准确的解释词，
  可让视障者提高输入效率」

## 三、与本地现状的差异

| 项 | 本项目 | 上述可朗读产品 |
|---|---|---|
| `Keyboard/Info.plist` `RequestsOpenAccess` | `false` | `true` |
| 扩展内 `AVSpeechSynthesizer` 代码 | **已写好**（通道 1/2） | 已写好 |
| 音频会话处理 | 已写（通道 2 设 `.playback + .mixWithOthers`） | 多数不显式设置 |

**附加发现（内部不一致）**：`docs/architecture/decisions/0007-full-access-and-privacy-boundary.md`
写着「The Extension requests Full Access because shared App Group settings, diagnostics and managed RIME data depend on it」，
但 `Keyboard/Info.plist` 实际是 `false`。ADR 状态标注「implementation pending」，
说明这项决策从未落到工程文件里，而它恰好就是朗读静默的直接原因。

## 四、推荐下载对照（建议装 1–2 个，做一次 A/B）

| 推荐度 | 产品 | 理由 |
|---|---|---|
| 高 | **粤拼**（App Store 免费，开源于 yuetyam/jyutping） | 与我们的实现几乎同构，最直接可对照；键盘设置里有「声音回应」开关 |
| 高 | **ReRime 输入法**（免费，RIME 内核，支持旁白） | 形态最接近本项目（RIME + 中文 + 旁白 + 本地隐私） |
| 中 | **落格输入法 X** | 明确为视障用户设计，候选解释库有针对性优化 |
| 中 | **仓输入法 Hamster** | RIME 内核，可看「完全访问开启后」的完整能力表现 |

### 关键 A/B 实验（不用改我们的代码就能验证结论）

1. 装好粤拼 → 设置 → 通用 → 键盘 → 键盘 → 粤拼 → 打开**允许完全访问**
2. 打开备忘录打字，听键盘是否朗读/发声
3. 回到同一处**关闭**允许完全访问
4. 再打字对比

若「开＝有声、关＝静音」，即一次性证实本调研结论。

## 五、建议动作

1. **先做上面的 A/B**，用现成产品把结论钉死，避免又一轮盲改。
2. 把 `Keyboard/Info.plist` 的 `RequestsOpenAccess` 改为 `true`，
   与 ADR 0007 对齐；同时在主应用文案里保留「完全访问仅用于本地朗读与学习，不上传任何输入内容」的隐私说明。
3. 五通道 spike 的取舍应随之调整：**通道 1/2 才是有效路径**（需完全访问），
   通道 3/4/5 依赖 VoiceOver 队列，属「系统决定」，无公开 API 保证顺序与完整性。
4. **注意退路陷阱**：`AVSpeechSynthesizer.write` 渲染 PCM + `AVAudioEngine` 播放
   同样属于「扩展输出音频」，同样受完全访问限制，**不能指望它绕过**这个问题。
5. 若产品坚持「完全访问关闭也要有朗读」，则需承认：
   完全访问关闭时只剩 VoiceOver 通道（不稳定），
   或由**主应用**承担朗读（但主应用不在前台时无法随键触发）。这是一个必须由人类拍板的产品取舍。

## 六、待验证问题

1. 完全访问打开后，`.announcement` 与「扩展自发音」是否仍互相打架？
2. 通道 2 的 `.playback + .mixWithOthers` 是否会压低旁白音量？
3. SideStore 免费签名下，完全访问开关能否正常保存并生效？
4. 打开完全访问后，键盘首次弹出是否因加载 RIME 资源而变慢？

## 七、来源

- Apple, *App Extension Programming Guide — Custom Keyboard*（RequestsOpenAccess 能力表）
- Stack Overflow 24668631 / 26075388 / 26696000 / 27208209
- yuetyam/jyutping（Keyboard/Speech/Speech.swift, Keyboard/Info.plist, Keyboard/SharedModels/AudioFeedback.swift）
- imfuxiao/Hamster（HamsterKeyboard/Info.plist, SbxlmKeyboard/Info.plist）
- Suzukaa-a/songyan-ios, taigikeyboard/stoat-keyboard, shchnk1103/Universe-Keyboard, BChip/OpenBlabber, nkrsn/jboard
- App Store 商店页：ReRime 输入法、RooQi Keyboard、落格输入法 X、粤拼

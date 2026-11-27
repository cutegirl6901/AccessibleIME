import AVFoundation
import KeyboardCore
import UIKit

/// 播报通道的诊断版 spike。
///
/// ## 为什么需要多通道
///
/// 这个键盘的候选朗读反复静默，而同一套 API 在不同时机得到过互相矛盾的结论：
/// - 0.2.5 在 UI 重建之前发 announcement：听得到
/// - 0.2.2–0.2.10 在别处发 announcement：听不到
/// - 0.2.11 用焦点转移：听得到，但慢
///
/// 单次改一版只能验证一条路，成本太高。因此一次装机提供 5 条可切换通道，
/// 用三击 Shift 循环，切到时先朗读自己的名字，方便盲人用户确认当前在测哪条。
///
/// ## 统一规则
///
/// 1. 只读候选，不读键名。键名由 VoiceOver 自己念，两套声音叠在一起听不清。
/// 2. 每个键都读，不去重。宁可重复，不可静默。
/// 3. 旁白通道用 `.low` 优先级排队，让候选排在键名之后；键盘自发声通道
///    仍走「先 stop 再 speak」的打断逻辑（与调音节拍器结论一致）。
///
/// ## 默认行为
///
/// 默认通道是 3（旁白公告，低优先级排队）。这是与系统输入法最接近的一条：
/// 旁白先念键名，候选排在其后播出，不抢话、不移动焦点。
/// 通道 6 是同一种公告的「打断式」变体，用于快速连打时不想让队列落后。
/// 通道 4（焦点转移）保留为诊断备选，不再作为默认。
enum KeySpeechChannelID: Int, CaseIterable, Sendable {
    case appVoiceIsolated = 1
    case appVoicePlayback = 2
    case queuedAnnouncement = 3
    case focusTransfer = 4
    case interruptingAnnouncement = 6
    /// 通道 7：把候选写进按键的 accessibilityValue，再用 .layoutChanged 指回该键。
    ///
    /// 这是系统键盘的做法（见 TextInputUI 二进制：完全不使用 announcement），
    /// 也是本项目唯一被真机证实「无障碍树本身是通的」的路径
    /// （用户反馈：滑过按键能读出字母名）。
    case keyValueRefresh = 7
    // 编号 5 保留空缺，不复用：0.2.17 曾把它分配给一个依赖
    // `UIAccessibility.Notification.valueChanged` 的通道，而该通知
    // 在 UIKit 中并不存在，那段代码从未编译过，已整体删除。
    // 不复用编号，避免旧版本存下的「5」被解读成另一条通道。

    /// 切到该通道时朗读的名字。用完整句子，避免只听到一个编号。
    var spokenName: String {
        switch self {
        case .appVoiceIsolated: return "通道一，应用语音，独立音频会话"
        case .appVoicePlayback: return "通道二，应用语音，播放类别混音"
        case .queuedAnnouncement: return "通道三，旁白公告，排队朗读"
        case .focusTransfer: return "通道四，旁白焦点转移"
        case .interruptingAnnouncement: return "通道六，旁白公告，打断式"
        case .keyValueRefresh: return "通道七，按键值刷新"
        }
    }

    var shortName: String {
        switch self {
        case .appVoiceIsolated: return "应用语音（独立会话）"
        case .appVoicePlayback: return "应用语音（播放混音）"
        case .queuedAnnouncement: return "旁白公告（排队）"
        case .focusTransfer: return "旁白焦点转移"
        case .interruptingAnnouncement: return "旁白公告（打断）"
        case .keyValueRefresh: return "按键值刷新"
        }
    }

    /// 设置页副标题，说明这条通道在测什么。
    var detail: String {
        switch self {
        case .appVoiceIsolated:
            return "键盘自己发声，不使用应用音频会话。若扩展里默认会话被静音，这条会绕开它。"
        case .appVoicePlayback:
            return "键盘自己发声，并把音频会话设为播放混音。用于验证静音开关打开时是否仍能出声。"
        case .queuedAnnouncement:
            return "在候选栏刷新之前发旁白公告，并标记为低优先级排队。旁白会先念键名，再念候选。"
        case .focusTransfer:
            return "把旁白焦点移到第一个候选。0.2.11 确认能出声，但每键都要重扫无障碍树。"
        case .interruptingAnnouncement:
            return "同样每键一条旁白公告，但用默认优先级：会打断上一句，快速连打时永远听最新一条。"
        case .keyValueRefresh:
            return "把当前候选写进按键的 accessibilityValue，再让旁白重读这个键。与系统键盘一致，不依赖任何播报 API。"
        }
    }
}

/// 投递时机。决定这条通道必须在候选栏刷新之前还是之后调用。
enum KeySpeechDeliveryTiming: Sendable {
    case beforeUISync
    case afterUISync
}

/// 通道协议。所有实现都在主线程使用。
@MainActor
protocol KeySpeechChannel: AnyObject {
    var id: KeySpeechChannelID { get }
    var timing: KeySpeechDeliveryTiming { get }

    /// 本次播报文本是否要包含键名。
    ///
    /// 排旁白队列的通道不包含键名：旁白在焦点落到按键时已经念过键名，
    /// 再拼一遍就是双重朗读。这与系统输入法的听感一致。
    var includesKeyName: Bool { get }

    /// 朗读一段文本。文本已经由上层生成好。
    func speak(_ text: String)

    /// 立即停止当前朗读。
    func stop()
}

extension KeySpeechChannel {
    /// 默认不拼键名：旁白自己会念。只有明确需要自报键名的通道才覆盖。
    var includesKeyName: Bool { false }
}

// MARK: - 应用语音

/// 用 AVSpeechSynthesizer 自己发声，不排 VoiceOver 的队。
///
/// 关键实现细节（照调音节拍器已验证的写法）：
/// - 打断时要 stop，让出一个 run loop，再 speak，否则吞掉开头音节
/// - didFinish 用 utterance 身份比对，避免旧句的回调清掉新句状态
@MainActor
class AppVoiceSpeechChannel: NSObject, KeySpeechChannel, AVSpeechSynthesizerDelegate {

    let id: KeySpeechChannelID
    var timing: KeySpeechDeliveryTiming { .afterUISync }
    /// 键盘自己发声，旁白不会念这次按键，所以必须把键名一起读出来。
    var includesKeyName: Bool { true }

    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?
    private var pendingSpeakTask: Task<Void, Never>?

    /// 诊断：记录是否真的调用过 speak，便于日志判断走到哪一步。
    private(set) var speakCallCount = 0
    /// 诊断：最近一次会话配置失败的原因（只读；子类用 `recordError` 写）。
    private(set) var lastErrorDescription: String?

    /// 供子类记录会话配置失败。Swift 没有 `protected`，
    /// 因此用私有 setter + 显式写入方法来表达同一个意图。
    func recordError(_ description: String) {
        lastErrorDescription = description
    }

    init(id: KeySpeechChannelID, usesApplicationAudioSession: Bool) {
        self.id = id
        super.init()
        // 扩展里默认 true 时，合成器会借用应用的音频会话；
        // 若会话不可用或被静音，结果是完全没声音也不报错。
        synthesizer.usesApplicationAudioSession = usesApplicationAudioSession
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speakCallCount += 1
        Logger.shared.info(
            "KeySpeech channel=\(id.rawValue) appVoice len=\(trimmed.count) "
                + "usesAppSession=\(synthesizer.usesApplicationAudioSession) speaking=\(synthesizer.isSpeaking)",
            category: .general
        )

        let wasSpeaking = synthesizer.isSpeaking || pendingSpeakTask != nil
        pendingSpeakTask?.cancel()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        // AVSpeechUtterance.rate 是 0 到 1。0.55 接近系统默认语速。
        utterance.rate = 0.55
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        currentUtterance = utterance

        if wasSpeaking {
            pendingSpeakTask = Task { @MainActor [weak self] in
                // 给合成器一个 run loop 完成取消，否则开头音节被吞。
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                self.synthesizer.speak(utterance)
            }
        } else {
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        pendingSpeakTask?.cancel()
        pendingSpeakTask = nil
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    // 这两个回调必须声明为 nonisolated：
    // AVSpeechSynthesizerDelegate 是否带 @MainActor 标注随 SDK 版本而变，
    // 而 nonisolated 实现可以同时满足「带标注」与「不带标注」两种协议要求，
    // 因此在任何 SDK 下都能通过 Swift 6 严格并发检查。
    // 真正的状态处理跳回主线程执行。
    // AVSpeechUtterance 不是 Sendable，不能跨 actor 传递。
    // 因此在 nonisolated 回调里先用 ObjectIdentifier 记住身份，
    // 只把「是不是当前这一句」这个 Bool 带进主线程。
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let finished = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self else { return }
            Logger.shared.info("KeySpeech didFinish channel=\(self.id.rawValue)", category: .general)
            // 被替换掉的旧句不能清掉新句的状态。
            guard let current = self.currentUtterance,
                ObjectIdentifier(current) == finished
            else { return }
            self.currentUtterance = nil
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let cancelled = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self else { return }
            Logger.shared.info("KeySpeech didCancel channel=\(self.id.rawValue)", category: .general)
            guard let current = self.currentUtterance,
                ObjectIdentifier(current) == cancelled
            else { return }
            self.currentUtterance = nil
        }
    }
}

/// 通道 2：额外把音频会话设成播放加混音，验证静音开关的影响。
@MainActor
final class PlaybackSessionSpeechChannel: AppVoiceSpeechChannel {

    private var didConfigureSession = false

    init() {
        super.init(id: .appVoicePlayback, usesApplicationAudioSession: true)
    }

    override func speak(_ text: String) {
        configureSessionIfNeeded()
        super.speak(text)
    }

    private func configureSessionIfNeeded() {
        guard !didConfigureSession else { return }
        didConfigureSession = true
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // 失败不致命：合成器仍会尝试用自己的路径。
            recordError(error.localizedDescription)
        }
    }
}

// MARK: - 旁白通道

/// 通道 3（默认）：在候选栏刷新之前发公告，并标记为低优先级排队。
///
/// ## 为什么是 `.low`
///
/// 用普通 `String` 投递等于 `default` 优先级：**打断**旁白正在念的键名，
/// 两条语音互相抢，这就是历史上「时有时无」的直接原因。
/// Apple 文档对 `UIAccessibilityPriority.low` 的定义是
/// 「排队，等其它语音说完再播」，正好得到「n → 你」的自然顺序，
/// 与系统输入法的听感一致，也不需要等待 `announcementDidFinish`。
///
/// ## 为什么在候选栏刷新之前
///
/// 0.2.5 的真机记录：与 `reloadData` 同帧投递的公告会被系统丢弃。
/// 这里在 `syncUI` 之前投递，且播报内容来自 `controller.state` 的值快照，
/// 不依赖任何视图刷新。
@MainActor
final class AnnouncementSpeechChannel: KeySpeechChannel {
    let id: KeySpeechChannelID = .queuedAnnouncement

    /// 投递时机改为 `afterUISync`。
    ///
    /// 真机事实（2026-11-27）：这条是唯一能出声的通道，
    /// 但不管输入什么，永远读「我们的我」。
    ///
    /// 原因：原先在 `beforeUISync` 投递，而候选栏数据是在
    /// `syncUI` 内部的 `refreshCandidateBar()` 才更新的（见 Presentation.swift）。
    /// 于是播报读到的是上一轮残留的候选——一直是同一个字。
    ///
    /// 改到 `syncUI` 之后投递，读到的才是本次按键的真实候选。
    /// 0.2.5 曾记录「与 reloadData 同帧的公告会被系统丢弃」，
    /// 但当前候选栏已改为就地更新（不 reloadData），该限制不再适用。
    var timing: KeySpeechDeliveryTiming { .afterUISync }

    private(set) var speakCallCount = 0

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speakCallCount += 1
        UIAccessibility.post(notification: .announcement, argument: AccessibilityAnnouncement.queued(trimmed))
    }

    func stop() {
        // 公开 API 无法取消已投递的公告。
    }
}

/// 通道 6：与通道 3 相同的公告，但用默认优先级——打断上一句。
///
/// 取舍：
/// - 通道 3（`.low`）不打断旁白的键名，单键输入最自然；但快速连打时
///   每条都要排队，候选会越来越落后。
/// - 通道 6（`.default`）会打断正在念的内容，因此永远读最新一条，
///   代价是键名可能被切掉。
///
/// 两者都是「一次按键一条播报」，区别只在是否允许打断。
@MainActor
final class InterruptingAnnouncementSpeechChannel: KeySpeechChannel {
    let id: KeySpeechChannelID = .interruptingAnnouncement
    var timing: KeySpeechDeliveryTiming { .beforeUISync }

    private(set) var speakCallCount = 0

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speakCallCount += 1
        // 直接用 String 投递 = default 优先级：打断上一句。
        UIAccessibility.post(notification: .announcement, argument: trimmed)
    }

    func stop() {
        // 公开 API 无法取消已投递的公告。
    }
}

/// 通道 4：把旁白焦点移到第一个候选格。
///
/// 诊断备选，不再是默认。它会把焦点从按键抢到候选栏，
/// 连续打字时手感与系统输入法差别明显。
///
/// 通过闭包回调交给控制器执行，因为只有控制器知道候选栏在哪。
@MainActor
final class FocusTransferSpeechChannel: KeySpeechChannel {
    let id: KeySpeechChannelID = .focusTransfer
    var timing: KeySpeechDeliveryTiming { .afterUISync }

    /// 由控制器注入：把焦点移到第一个候选并朗读它的无障碍标签。
    var focusFirstCandidate: (() -> Void)?

    private(set) var speakCallCount = 0

    func speak(_ text: String) {
        speakCallCount += 1
        // 这条通道不直接使用文本：候选格自带完整的 accessibilityLabel，
        // 移过去 VoiceOver 会读出比纯候选更丰富的内容（含逐字解释）。
        focusFirstCandidate?()
    }

    func stop() {
        // 焦点转移无法取消。
    }
}

/// 通道 7：把候选写进按键的 accessibilityValue，再用 `.layoutChanged` 指回该键。
///
/// ## 为什么这条最可能有效
///
/// 1. 系统键盘就是这么做的：`TextInputUI` 二进制里
///    `UIAccessibilityPostNotification` 出现 **0 次**，
///    它靠元素自身的 value 变化配合布局通知。
/// 2. 真机已确认本项目的无障碍树是通的——
///    用户滑过按键能读出字母名，说明 label/traits 都正常。
///    缺的只是「按下后把候选补进 value 并让旁白重读」这一步。
/// 3. `.layoutChanged` 在本扩展里是有效的（项目 0.2.11 的成功记录
///    用的正是它），失效的只有 `.announcement`。
@MainActor
final class KeyValueRefreshSpeechChannel: KeySpeechChannel {
    let id: KeySpeechChannelID = .keyValueRefresh
    var timing: KeySpeechDeliveryTiming { .afterUISync }

    /// 由控制器注入：把候选写进按键 value 并刷新焦点。
    var refreshKeyValue: ((String) -> Void)?

    private(set) var speakCallCount = 0

    func speak(_ text: String) {
        speakCallCount += 1
        refreshKeyValue?(text)
    }

    func stop() {
        // 布局刷新无法取消，也不需要。
    }
}

// MARK: - 工厂

@MainActor
enum KeySpeechChannelFactory {
    /// 按编号创建通道。注意：通道 4 需要控制器注入回调后才完全可用。
    static func make(_ id: KeySpeechChannelID) -> any KeySpeechChannel {
        switch id {
        case .appVoiceIsolated:
            return AppVoiceSpeechChannel(id: .appVoiceIsolated, usesApplicationAudioSession: false)
        case .appVoicePlayback:
            return PlaybackSessionSpeechChannel()
        case .queuedAnnouncement:
            return AnnouncementSpeechChannel()
        case .focusTransfer:
            return FocusTransferSpeechChannel()
        case .interruptingAnnouncement:
            return InterruptingAnnouncementSpeechChannel()
        case .keyValueRefresh:
            return KeyValueRefreshSpeechChannel()
        }
    }
}

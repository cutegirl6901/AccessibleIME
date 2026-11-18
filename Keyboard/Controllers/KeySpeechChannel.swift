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
/// 3. 新键立即打断旧句：先 stop，再让出一个 run loop，然后 speak。
///    否则开头音节会被吞掉（与调音节拍器的 SpeechFeedback 结论一致）。
///
/// ## 默认行为
///
/// 默认通道仍是 4（焦点转移），即当前已发布行为。只有用户三击 Shift 才切换。
enum KeySpeechChannelID: Int, CaseIterable, Sendable {
    case appVoiceIsolated = 1
    case appVoicePlayback = 2
    case announcementBeforeSync = 3
    case focusTransfer = 4
    case valueChanged = 5

    /// 切到该通道时朗读的名字。用完整句子，避免只听到一个编号。
    var spokenName: String {
        switch self {
        case .appVoiceIsolated: return "通道一，应用语音，独立音频会话"
        case .appVoicePlayback: return "通道二，应用语音，播放类别混音"
        case .announcementBeforeSync: return "通道三，旁白公告，界面刷新之前"
        case .focusTransfer: return "通道四，旁白焦点转移"
        case .valueChanged: return "通道五，旁白数值变化"
        }
    }

    var shortName: String {
        switch self {
        case .appVoiceIsolated: return "应用语音（独立会话）"
        case .appVoicePlayback: return "应用语音（播放混音）"
        case .announcementBeforeSync: return "旁白公告（刷新前）"
        case .focusTransfer: return "旁白焦点转移"
        case .valueChanged: return "旁白数值变化"
        }
    }

    /// 设置页副标题，说明这条通道在测什么。
    var detail: String {
        switch self {
        case .appVoiceIsolated:
            return "键盘自己发声，不使用应用音频会话。若扩展里默认会话被静音，这条会绕开它。"
        case .appVoicePlayback:
            return "键盘自己发声，并把音频会话设为播放混音。用于验证静音开关打开时是否仍能出声。"
        case .announcementBeforeSync:
            return "在候选栏刷新之前发旁白公告。0.2.5 曾在此时机听到声音。"
        case .focusTransfer:
            return "把旁白焦点移到第一个候选。0.2.11 确认能出声，但每键都要重扫无障碍树。"
        case .valueChanged:
            return "更新一个常驻候选状态元素并发送数值变化通知。旁白对数值变化通常更敏感。"
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

    /// 朗读一段文本。文本已经由上层生成好（只含候选，不含键名）。
    func speak(_ text: String)

    /// 立即停止当前朗读。
    func stop()
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

    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?
    private var pendingSpeakTask: Task<Void, Never>?

    /// 诊断：记录是否真的调用过 speak，便于日志判断走到哪一步。
    private(set) var speakCallCount = 0
    private(set) var lastErrorDescription: String?

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
            lastErrorDescription = error.localizedDescription
        }
    }
}

// MARK: - 旁白通道

/// 通道 3：在候选栏刷新之前发公告。
///
/// 0.2.5 的提交信息明确记录过：这个时机下 announcement 能听到；
/// 与 reloadData 同帧时会被系统丢弃。这里把它单独做成一条通道做对照。
@MainActor
final class AnnouncementSpeechChannel: KeySpeechChannel {
    let id: KeySpeechChannelID = .announcementBeforeSync
    var timing: KeySpeechDeliveryTiming { .beforeUISync }

    private(set) var speakCallCount = 0

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speakCallCount += 1
        UIAccessibility.post(notification: .announcement, argument: trimmed)
    }

    func stop() {
        // 公开 API 无法取消已投递的公告。
    }
}

/// 通道 4：把旁白焦点移到第一个候选格。即当前已发布行为。
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

/// 通道 5：更新一个常驻元素并发送数值变化通知。
///
/// VoiceOver 对数值变化通常比公告更敏感，且不需要等待 UI 重建时机。
@MainActor
final class ValueChangedSpeechChannel: KeySpeechChannel {
    let id: KeySpeechChannelID = .valueChanged
    var timing: KeySpeechDeliveryTiming { .afterUISync }

    private(set) var speakCallCount = 0
    private weak var statusView: UIView?

    /// 由控制器注入一个常驻、可聚焦的无障碍状态元素。
    var statusElementProvider: (() -> UIView?)?

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speakCallCount += 1

        guard let view = statusElementProvider?() ?? statusView else { return }
        statusView = view
        view.accessibilityLabel = trimmed
        view.accessibilityValue = trimmed
        UIAccessibility.post(notification: .valueChanged, argument: view)
    }

    func stop() {}
}

// MARK: - 工厂

@MainActor
enum KeySpeechChannelFactory {
    /// 按编号创建通道。注意：通道 4 / 5 需要控制器注入回调后才完全可用。
    static func make(_ id: KeySpeechChannelID) -> any KeySpeechChannel {
        switch id {
        case .appVoiceIsolated:
            return AppVoiceSpeechChannel(id: .appVoiceIsolated, usesApplicationAudioSession: false)
        case .appVoicePlayback:
            return PlaybackSessionSpeechChannel()
        case .announcementBeforeSync:
            return AnnouncementSpeechChannel()
        case .focusTransfer:
            return FocusTransferSpeechChannel()
        case .valueChanged:
            return ValueChangedSpeechChannel()
        }
    }
}

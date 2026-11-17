import KeyboardCore
import UIKit

/// 键盘扩展里的按键播报器。
///
/// ## 能力边界（重要，不要假设普通 App 的能力在扩展里成立）
///
/// - `UIAccessibility.isVoiceOverRunning` 在键盘扩展里**被观测到不可靠**
///   （有时 VoiceOver 已开启却返回 false）。因此它只能用来「提前跳过」，
///   绝不能用来「决定是否播报」——否则会整体静默。VoiceOver 关闭时，
///   `UIAccessibility.post` 本身是 no-op，没有副作用。
/// - `UIAccessibility.post(notification: .announcement, ...)` 在扩展里
///   **可用但不保证**：系统的朗读队列由 VoiceOver 持有，扩展无法查询队列、
///   无法得知某条公告是否念完、无法保证顺序、也无法保证每条都完整播出。
/// - 没有公开 API 能「把公告插队到最前」或「等待上一条读完」。私有 API 一律不用。
///
/// ## 据此采取的取舍
///
/// - **不做防抖、不合并**：每次按键都生成一条播报，符合「一次按键一次反馈」。
/// - 系统打断由系统的打断策略决定；但**快速连按时旧公告会被主动作废**，
///   避免读到过期候选（这是唯一必要的「丢弃」，丢弃的是**过期**内容，
///   不是用户按下的那一次）。可选严格排队模式见 `DeliveryMode`。
/// - 检测不可靠时**宁可照发**：漏读比误发更伤盲人用户。
@MainActor
final class KeySpeechAnnouncer {

    /// 投递模式。
    enum DeliveryMode: String, CaseIterable, Sendable {
        /// 每次按键立即投递；新按键会作废旧公告。延迟最低。（默认）
        case immediate
        /// 在 immediate 基础上，等系统回调确认上一条念完再投下一条。
        ///
        /// 注意：`announcementDidFinish` 在键盘扩展里**是否可靠未经证实**，
        /// 且一旦回调丢失就会卡住。因此带超时兜底。
        case sequential
        /// 完全关闭按键播报（用户可关）。
        case off
    }

    /// 单条播报的投递结果，仅用于诊断。
    enum Outcome: Equatable {
        case posted
        case droppedSuperseded
        case droppedNoSpeech
    }

    // MARK: - 状态

    /// 单调递增的输入事件序号。每次物理按键 +1。
    private(set) var currentSequence: UInt64 = 0
    /// 已成功投递的最大序号，用于诊断重复/乱序。
    private(set) var lastPostedSequence: UInt64 = 0
    /// 因被更新按键取代而作废的条数（诊断用）。
    private(set) var supersededCount = 0

    private var pendingAnnouncement: (sequence: UInt64, text: String)?
    private var timeoutTask: Task<Void, Never>?
    private var isSpeaking = false

    var deliveryMode: DeliveryMode = .immediate
    var detail: KeySpeechDetail = .standard

    /// 供诊断/单测替换的投递钩子。生产环境走 `UIAccessibility.post`。
    var postAnnouncement: (String) -> Void = { text in
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    // MARK: - 序号

    /// 推进事件序号。必须在 `controller.handle(...)` **之前**调用，
    /// 这样即使回调、异步任务延迟，也能识别出「这条播报属于哪一次按键」。
    @discardableResult
    func beginInputEvent() -> UInt64 {
        currentSequence &+= 1
        return currentSequence
    }

    /// 判断某个序号是否仍是「最新」的。不是最新的就说明用户已经继续输入，
    /// 这条内容已过期，必须丢弃，否则会读到旧候选。
    func isCurrent(_ sequence: UInt64) -> Bool {
        sequence == currentSequence
    }

    // MARK: - 投递

    /// 投递一条播报。
    ///
    /// - Parameters:
    ///   - text: 已经由 `KeySpeechComposer` 生成好的朗读文本。
    ///   - sequence: 这次按键的序号（`beginInputEvent()` 的返回值）。
    @discardableResult
    func announce(_ text: String?, sequence: UInt64) -> Outcome {
        guard deliveryMode != .off else { return .droppedNoSpeech }
        guard let text, !text.isEmpty else { return .droppedNoSpeech }

        // 过期内容直接丢弃：用户已经按了下一个键，读旧候选会造成误导。
        guard isCurrent(sequence) else {
            supersededCount += 1
            return .droppedSuperseded
        }

        switch deliveryMode {
        case .immediate:
            post(text, sequence: sequence)
            return .posted

        case .sequential:
            // 严格模式：若上一条还在念，先缓存最新一条；等 finish 回调或超时再发。
            // 这里仍然只保留最新的一条——保留更早的只会让用户听到过时内容。
            if isSpeaking {
                if let previous = pendingAnnouncement, !isCurrent(previous.sequence) {
                    supersededCount += 1
                }
                pendingAnnouncement = (sequence, text)
                return .droppedSuperseded
            }
            post(text, sequence: sequence)
            return .posted

        case .off:
            return .droppedNoSpeech
        }
    }

    /// 直接投递，不走队列。立即模式下每次都走这里。
    private func post(_ text: String, sequence: UInt64) {
        lastPostedSequence = sequence
        isSpeaking = deliveryMode == .sequential
        postAnnouncement(text)
        guard deliveryMode == .sequential else { return }
        scheduleTimeout(for: sequence)
    }

    /// 严格模式的超时兜底。
    ///
    /// `announcementDidFinish` 在扩展里可能不来（我们尚未证实它在键盘扩展中
    /// 可靠触发）。没有兜底会导致播报永久卡死，因此设一个保守上限。
    private func scheduleTimeout(for sequence: UInt64) {
        timeoutTask?.cancel()
        // 用 Task + sleep 而不是 DispatchWorkItem：在 Swift 6 下天然继承 MainActor 隔离，
        // 不需要 assumeIsolated 断言。超时只影响「排队」，不会切断系统正在念的内容。
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, self.isSpeaking else { return }
            self.finishSpeaking(sequence: sequence, reason: "timeout")
        }
    }

    /// 系统回调「这一条念完了」。只有在 sequential 模式才需要。
    func announcementDidFinish(sequence: UInt64) {
        guard deliveryMode == .sequential, isSpeaking else { return }
        finishSpeaking(sequence: sequence, reason: "finished")
    }

    private func finishSpeaking(sequence: UInt64, reason: String) {
        timeoutTask?.cancel()
        timeoutTask = nil
        isSpeaking = false
        _ = reason

        guard let next = pendingAnnouncement else { return }
        pendingAnnouncement = nil
        // 缓存的那条也可能已经过期，投递前再确认一次。
        guard isCurrent(next.sequence) else {
            supersededCount += 1
            return
        }
        post(next.text, sequence: next.sequence)
    }

    // MARK: - 生命周期

    /// 键盘消失/切走时清空队列，避免下次出现时突然念上次的残留内容。
    func reset() {
        timeoutTask?.cancel()
        timeoutTask = nil
        pendingAnnouncement = nil
        isSpeaking = false
    }
}

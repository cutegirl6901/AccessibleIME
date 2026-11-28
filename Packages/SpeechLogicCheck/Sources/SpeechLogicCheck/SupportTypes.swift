import Foundation

// 这里只复制 `KeySpeech` 需要的最小类型定义。
// 真正的定义在 KeyboardCore/KeyboardState.swift。
// 为防止漂移，测试里会检查本文件与源文件的枚举 case 名称完全一致。

public enum KeyboardPage: Equatable, Sendable {
    case letters
    case numbers
    case symbols
    case emoji
}

public enum InputMode: Equatable, Sendable {
    case chinese
    case english
}

public enum ShiftState: Equatable, Sendable {
    case off
    case singleUse
    case capsLock
}

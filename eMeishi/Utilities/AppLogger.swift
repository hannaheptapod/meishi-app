import Foundation
import os

/// アプリ全体のロガー定義
/// Release版では `.private` アノテーション付きの値が自動秘匿される
enum AppLogger {
    // Bundle.main.bundleIdentifier は iOS 26 で @MainActor。nonisolated(unsafe) で伝搬を断ち切る
    nonisolated(unsafe) private static let subsystem = Bundle.main.bundleIdentifier ?? "com.jinks.eMeishi"

    nonisolated(unsafe) static let ocr         = Logger(subsystem: subsystem, category: "ocr")
    nonisolated(unsafe) static let classifier  = Logger(subsystem: subsystem, category: "classifier")
    nonisolated(unsafe) static let llm         = Logger(subsystem: subsystem, category: "llm")
    nonisolated(unsafe) static let search      = Logger(subsystem: subsystem, category: "search")
    nonisolated(unsafe) static let pipeline    = Logger(subsystem: subsystem, category: "pipeline")
    nonisolated(unsafe) static let tokenizer   = Logger(subsystem: subsystem, category: "tokenizer")
    nonisolated(unsafe) static let autoTag     = Logger(subsystem: subsystem, category: "autoTag")
    nonisolated(unsafe) static let persistence = Logger(subsystem: subsystem, category: "persistence")
    nonisolated(unsafe) static let export      = Logger(subsystem: subsystem, category: "export")
    nonisolated(unsafe) static let contacts    = Logger(subsystem: subsystem, category: "contacts")
    nonisolated(unsafe) static let camera      = Logger(subsystem: subsystem, category: "camera")
}

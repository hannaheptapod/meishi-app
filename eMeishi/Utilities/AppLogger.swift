import Foundation
import os

/// アプリ全体のロガー定義
/// Release版では `.private` アノテーション付きの値が自動秘匿される
nonisolated enum AppLogger {
    // Logger は Sendable なので、nonisolated 型の static let として actor をまたいで参照できる。
    private static let subsystem = "com.jinks.emeishi"

    static let ocr         = Logger(subsystem: subsystem, category: "ocr")
    static let classifier  = Logger(subsystem: subsystem, category: "classifier")
    static let llm         = Logger(subsystem: subsystem, category: "llm")
    static let search      = Logger(subsystem: subsystem, category: "search")
    static let pipeline    = Logger(subsystem: subsystem, category: "pipeline")
    static let tokenizer   = Logger(subsystem: subsystem, category: "tokenizer")
    static let autoTag     = Logger(subsystem: subsystem, category: "autoTag")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let export      = Logger(subsystem: subsystem, category: "export")
    static let contacts    = Logger(subsystem: subsystem, category: "contacts")
    static let camera      = Logger(subsystem: subsystem, category: "camera")
    static let cloudKit    = Logger(subsystem: subsystem, category: "cloudKit")
    static let performance = Logger(subsystem: subsystem, category: "performance")
}

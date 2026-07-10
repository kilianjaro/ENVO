import Foundation
import os

/// Centralized loggers. All app code logs through these instead of `print()`
/// so messages flow through Console.app / sysdiagnose with the right
/// subsystem and category, and respect Apple's privacy-string handling.
enum Log {
    private static let subsystem: String = {
        Bundle.main.bundleIdentifier ?? "envo"
    }()

    static let audio   = Logger(subsystem: subsystem, category: "audio")
    static let engine  = Logger(subsystem: subsystem, category: "engine")
    static let volume  = Logger(subsystem: subsystem, category: "volume")
    static let session = Logger(subsystem: subsystem, category: "session")
    static let general = Logger(subsystem: subsystem, category: "general")
}

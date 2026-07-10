import Foundation
import AppIntents

/// AppIntent surface for Shortcuts / Siri / Spotlight.
///
/// Three intents wired to a shared engine reference set at app launch.
/// Limited to in-foreground operation — running the engine from a
/// fully-suspended state requires the audio session to be reactivated,
/// which the user-launched intent path handles correctly.
@available(iOS 16.0, *)
enum EnvoIntentBridge {

    /// Set by ENVOApp at launch. Intents access it through a synchronous
    /// snapshot to avoid touching MainActor state on background queues.
    static weak var engine: EnvoEngine?

    @MainActor
    static func start() {
        engine?.start()
    }

    @MainActor
    static func stop() {
        engine?.stop()
    }

    @MainActor
    static func toggle() {
        guard let engine = engine else { return }
        if engine.isActive { engine.stop() } else { engine.start() }
    }
}

@available(iOS 16.0, *)
struct StartENVOIntent: AppIntent {
    static var title: LocalizedStringResource = "Start ENVO"
    static var description = IntentDescription("Begins adapting your volume to ambient noise.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        EnvoIntentBridge.start()
        return .result()
    }
}

@available(iOS 16.0, *)
struct StopENVOIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop ENVO"
    static var description = IntentDescription("Stops ENVO and restores your baseline volume.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        EnvoIntentBridge.stop()
        return .result()
    }
}

@available(iOS 16.0, *)
struct ToggleENVOIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle ENVO"
    static var description = IntentDescription("Starts ENVO if it's stopped, or stops it if it's running.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        EnvoIntentBridge.toggle()
        return .result()
    }
}

/// Shortcuts app entries. Users can find these by name and add them to
/// Siri / Home Screen / Action Button without typing.
@available(iOS 16.0, *)
struct ENVOShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartENVOIntent(),
            phrases: [
                "Start \(.applicationName)",
                "Begin \(.applicationName)",
                "Turn on \(.applicationName)"
            ],
            shortTitle: "Start ENVO",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: StopENVOIntent(),
            phrases: [
                "Stop \(.applicationName)",
                "End \(.applicationName)",
                "Turn off \(.applicationName)"
            ],
            shortTitle: "Stop ENVO",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: ToggleENVOIntent(),
            phrases: [
                "Toggle \(.applicationName)"
            ],
            shortTitle: "Toggle ENVO",
            systemImageName: "switch.2"
        )
    }
}

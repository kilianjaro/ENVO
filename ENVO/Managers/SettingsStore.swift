import Foundation
import Combine

/// Persisted user preferences. Loaded once at launch, written through to
/// UserDefaults on every change via Combine.
///
/// Add new prefs by:
///   1. Adding a stored key constant.
///   2. Adding a @Published property with the loaded value as default.
///   3. Adding a `.sink` in `wireUp()` that writes back to UserDefaults.
final class SettingsStore: ObservableObject {

    // MARK: - Keys

    private enum Key {
        static let speedMode      = "envo.settings.speedMode"
        static let rangeMode      = "envo.settings.rangeMode"
        static let allowIncrease  = "envo.settings.allowIncrease"
        static let allowDecrease  = "envo.settings.allowDecrease"
        static let autoResume     = "envo.settings.autoResume"
        static let wasActive      = "envo.settings.wasActive"
        static let onboarded      = "envo.settings.onboarded"
    }

    // MARK: - Engine preferences

    @Published var speedMode: SpeedMode
    @Published var rangeMode: RangeMode
    @Published var allowIncrease: Bool
    @Published var allowDecrease: Bool

    /// Resume the engine automatically if it was active at last quit.
    @Published var autoResume: Bool

    /// Set to true when the engine is active, cleared on graceful stop.
    /// `autoResume` only re-enters if this was true at launch.
    @Published var wasActive: Bool

    /// True once the user has seen the onboarding sheet.
    @Published var hasCompletedOnboarding: Bool

    private var cancellables = Set<AnyCancellable>()
    private let defaults: UserDefaults

    // MARK: - Lifecycle

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        self.speedMode = SettingsStore.loadEnum(SpeedMode.self,
                                                key: Key.speedMode,
                                                defaults: defaults,
                                                default: .medium)
        self.rangeMode = SettingsStore.loadEnum(RangeMode.self,
                                                key: Key.rangeMode,
                                                defaults: defaults,
                                                default: .medium)
        self.allowIncrease = defaults.object(forKey: Key.allowIncrease) as? Bool ?? true
        self.allowDecrease = defaults.object(forKey: Key.allowDecrease) as? Bool ?? true
        self.autoResume    = defaults.object(forKey: Key.autoResume) as? Bool ?? false
        self.wasActive     = defaults.object(forKey: Key.wasActive) as? Bool ?? false
        self.hasCompletedOnboarding = defaults.object(forKey: Key.onboarded) as? Bool ?? false

        wireUp()
    }

    // MARK: - Persistence wiring

    private func wireUp() {
        $speedMode
            .dropFirst()
            .sink { [weak self] mode in
                self?.defaults.set(mode.rawValue, forKey: Key.speedMode)
            }
            .store(in: &cancellables)

        $rangeMode
            .dropFirst()
            .sink { [weak self] mode in
                self?.defaults.set(mode.rawValue, forKey: Key.rangeMode)
            }
            .store(in: &cancellables)

        $allowIncrease
            .dropFirst()
            .sink { [weak self] v in
                self?.defaults.set(v, forKey: Key.allowIncrease)
            }
            .store(in: &cancellables)

        $allowDecrease
            .dropFirst()
            .sink { [weak self] v in
                self?.defaults.set(v, forKey: Key.allowDecrease)
            }
            .store(in: &cancellables)

        $autoResume
            .dropFirst()
            .sink { [weak self] v in
                self?.defaults.set(v, forKey: Key.autoResume)
            }
            .store(in: &cancellables)

        $wasActive
            .dropFirst()
            .sink { [weak self] v in
                self?.defaults.set(v, forKey: Key.wasActive)
            }
            .store(in: &cancellables)

        $hasCompletedOnboarding
            .dropFirst()
            .sink { [weak self] v in
                self?.defaults.set(v, forKey: Key.onboarded)
            }
            .store(in: &cancellables)
    }

    // MARK: - Helpers

    private static func loadEnum<T: RawRepresentable>(
        _ type: T.Type,
        key: String,
        defaults: UserDefaults,
        default fallback: T
    ) -> T where T.RawValue == String {
        guard let raw = defaults.string(forKey: key),
              let value = T(rawValue: raw) else {
            return fallback
        }
        return value
    }
}

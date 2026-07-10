import Foundation
import Combine

/// Owns the persisted calibration profile and publishes its state.
///
/// Split out of CalibrationManager so the engine can hold a stable reference
/// to "the current profile" without instantiating a CalibrationManager just
/// to read from disk. CalibrationManager runs the calibration *process* and
/// writes back to this store when it finishes.
final class CalibrationStore: ObservableObject {

    @Published private(set) var profile: CalibrationProfile?

    /// True when a usable profile is loaded.
    var isCalibrated: Bool { profile != nil }

    private let storageKey = "envo_calibration_profile"

    init() {
        self.profile = Self.loadFromDisk(key: storageKey)
    }

    /// Reload from disk (e.g. after a calibration finishes).
    func reload() {
        self.profile = Self.loadFromDisk(key: storageKey)
    }

    /// Persist a freshly-built profile and publish it.
    func save(_ profile: CalibrationProfile) {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        self.profile = profile
    }

    /// Wipe the saved profile. Used by "reset calibration" flows.
    func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        self.profile = nil
    }

    private static func loadFromDisk(key: String) -> CalibrationProfile? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let profile = try? JSONDecoder().decode(CalibrationProfile.self, from: data) else {
            return nil
        }
        return profile
    }
}

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

    /// True when a profile is loaded AND it passes its own validity check.
    ///
    /// This is deliberately stricter than "a profile exists". A profile that
    /// recorded no measurable speaker output — the signature of the silent
    /// sweep / deaf mic bug — would otherwise flip the engine into calibrated
    /// mode, where every ambient estimate is derived from a subtraction that
    /// cannot work. Better to run uncalibrated than to run on a profile that
    /// is confidently wrong.
    var isCalibrated: Bool { profile?.isUsable == true }

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

    /// Loads and validates. A stored profile from an older schema is deleted
    /// rather than migrated: v1 stored normalized 0…1 levels, and there is no
    /// sound way to reinterpret those as the dBFS values v2 expects. The user
    /// is asked to recalibrate, which now takes ~35 seconds and actually works.
    private static func loadFromDisk(key: String) -> CalibrationProfile? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }

        guard let profile = try? JSONDecoder().decode(CalibrationProfile.self, from: data),
              profile.version == CalibrationProfile.currentVersion else {
            Log.general.info("Discarding calibration profile from an incompatible schema; recalibration required.")
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }

        guard profile.isUsable else {
            Log.general.info("Discarding calibration profile that recorded no measurable speaker output.")
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        return profile
    }
}

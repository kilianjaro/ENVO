import Foundation
import AVFoundation

/// What a calibration run learned about this room and this device.
///
/// WHAT CHANGED FROM v1
/// --------------------
/// v1 stored the normalized 0…1 mic level and did arithmetic on it directly:
///
///     ambient = rawMic - (expectedMicLevel(volume) - silenceFloor)
///
/// Every term there is a decibel value, so that expression subtracts
/// logarithms as if they were energies. It is not an approximation of the
/// right answer — it is a different quantity. Combined with a normalization
/// floor of −60 dBFS that clamped quiet rooms to literal zero, calibrated
/// mode produced a silence floor of 0, zero device contribution for the
/// lower volume steps, and a permanently-triggered gap detector.
///
/// v2 stores raw dBFS and does the subtraction in the power domain, which
/// is the physically correct operation: the mic hears room + speaker mixed
/// energetically, so recovering the room means removing the speaker's
/// *energy*, not its decibel value.
///
/// v2 also derives a `VolumeTaper` from the sweep. The sweep is, incidentally,
/// a direct measurement of how much acoustic output each slider position
/// produces on this device — which is exactly what the engine needs to make
/// "±6 dB" mean ±6 dB rather than "some slider fraction that used to be
/// computed with the wrong curve."
struct CalibrationProfile: Codable, Equatable {

    /// Bumped whenever the stored meaning changes. Profiles from an older
    /// version are discarded rather than reinterpreted — a v1 profile's
    /// numbers are normalized levels, and reading them as dBFS would be
    /// worse than having no profile at all.
    ///
    /// v3: levels are now A-weighted, so an absolute dBFS figure from v2 is
    /// several dB away from the same room measured today. The derived taper
    /// would survive (it comes from differences at a fixed spectrum) but the
    /// silence floor would not, and a wrong floor means a wrong "recalibrate?"
    /// prompt.
    static let currentVersion = 3

    var version: Int = CalibrationProfile.currentVersion

    /// Room ambient measured at volume 0, in dBFS.
    var silenceFloorDB: Float

    /// Sweep results, sorted by volume.
    var points: [CalibrationPoint]

    var date: Date

    /// Raw value of the `AVAudioSession.Port` that was active during the
    /// sweep. The measured taper only describes that route; on any other
    /// route the engine falls back to the default taper.
    var routePortType: String?

    struct CalibrationPoint: Codable, Equatable {
        /// Slider position, 0…1.
        let volume: Float
        /// Total mic level measured at that position, in dBFS (room + speaker).
        let micLevelDB: Float
    }

    // MARK: - Level curve

    /// Total expected mic level (room + speaker) at a slider position.
    /// Interpolates linearly between measured points and clamps outside them.
    func expectedMicLevelDB(atVolume volume: Float) -> Float {
        guard let first = points.first, let last = points.last else {
            return silenceFloorDB
        }
        if points.count == 1 { return first.micLevelDB }
        if volume <= first.volume { return first.micLevelDB }
        if volume >= last.volume { return last.micLevelDB }

        for i in 0..<(points.count - 1) {
            let lo = points[i], hi = points[i + 1]
            if volume >= lo.volume && volume <= hi.volume {
                let denom = hi.volume - lo.volume
                guard denom > 0 else { return lo.micLevelDB }
                let t = (volume - lo.volume) / denom
                return lo.micLevelDB + t * (hi.micLevelDB - lo.micLevelDB)
            }
        }
        return silenceFloorDB
    }

    /// The speaker's own contribution at a slider position, with the room's
    /// contribution energetically removed.
    func deviceContributionDB(atVolume volume: Float) -> Float {
        AcousticMath.subtractDB(expectedMicLevelDB(atVolume: volume), silenceFloorDB)
    }

    // NOTE ON RUNTIME AMBIENT ESTIMATION
    // ----------------------------------
    // This type deliberately offers no "estimate the room from a live mic
    // reading" method. It once did, by subtracting `deviceContributionDB` from
    // the reading, and that was unsound: the sweep measures the speaker while
    // playing a known test noise, so the stored figure is what the device
    // *would* produce at that volume playing that noise. Real program material
    // is quieter and constantly varying, and often absent entirely.
    //
    // In practice the live reading therefore sat far below the expected device
    // level, every tick reported the room as masked, the estimate stopped
    // updating, and the adjustment stayed pinned at 0.0 dB no matter how much
    // the room changed. Runtime ambient is now tracked by `AmbientTracker`,
    // which needs no assumption about what is playing.

    // MARK: - Measured taper

    /// The volume→output curve measured by the sweep, or `nil` when the sweep
    /// did not produce a physically sensible curve (see VolumeTaper's
    /// validation). A `nil` here means the engine uses the default taper —
    /// the profile is still useful for ambient separation.
    var measuredTaper: VolumeTaper? {
        let usable = points.compactMap { point -> (volume: Float, gainDB: Float)? in
            let device = deviceContributionDB(atVolume: point.volume)
            // Steps where the speaker never rose above the room floor tell us
            // nothing about the taper.
            guard device > AcousticMath.silenceDB + 1.0 else { return nil }
            return (volume: point.volume, gainDB: device)
        }
        return VolumeTaper(measuredPoints: usable)
    }

    /// True when the taper measured here still describes the current output
    /// route. Calibrating on the phone speaker says nothing about the curve a
    /// Bluetooth speaker applies to the same slider positions.
    func taperAppliesToCurrentRoute() -> Bool {
        guard let stored = routePortType else { return false }
        guard let current = AVAudioSession.sharedInstance()
            .currentRoute.outputs.first?.portType else { return false }
        return current.rawValue == stored
    }

    /// The taper the engine should use right now.
    var applicableTaper: VolumeTaper {
        guard taperAppliesToCurrentRoute(), let measured = measuredTaper else {
            return .default
        }
        return measured
    }

    // MARK: - Validation

    /// Whether this profile is worth trusting at all.
    ///
    /// A profile that recorded no measurable device contribution anywhere is
    /// the signature of the old bug (silent sweep, deaf mic) and must not be
    /// treated as "calibrated" — doing so switched the engine into a mode
    /// whose core subtraction was guaranteed to return nonsense.
    var isUsable: Bool {
        guard version == CalibrationProfile.currentVersion else { return false }
        guard points.count >= 3 else { return false }
        guard silenceFloorDB.isFinite, silenceFloorDB > AcousticMath.silenceDB else { return false }

        // The loudest step must be clearly above the room floor, or the sweep
        // measured nothing.
        guard let loudest = points.max(by: { $0.micLevelDB < $1.micLevelDB }) else { return false }
        return loudest.micLevelDB - silenceFloorDB >= 6.0
    }
}

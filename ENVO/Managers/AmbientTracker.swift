import Foundation

/// Estimates the room's level from a stream of microphone readings, without
/// needing to know what the device is currently playing.
///
/// WHY NOT SUBTRACT THE CALIBRATED SPEAKER LEVEL
/// ---------------------------------------------
/// The calibration sweep measures what the speaker produces at each volume
/// *while playing a known test noise*. At runtime the program material is
/// different, quieter, constantly varying — and often absent entirely. So the
/// calibrated figure is an upper bound on what the device could be
/// contributing, never an estimate of what it is contributing.
///
/// Subtracting it per tick therefore fails in the ordinary case: the measured
/// level sits far below the expected speaker level, the subtraction reports
/// "the room is masked", and the estimate stops updating. Making the room
/// louder does not help — it moves the reading further from the only
/// condition under which the old path produced a number at all. The result
/// was an adjustment pinned at 0.0 dB regardless of the environment.
///
/// WHAT THIS DOES INSTEAD
/// ----------------------
/// Tracks a low percentile of the recent level history. Music and speech are
/// dynamic: between beats, between words, in decays and pauses, the microphone
/// hears mostly the room. The 20th percentile of a 10–60 second window
/// therefore approximates the ambient floor closely, and it does so whether or
/// not anything is playing and whether or not a calibration profile exists.
///
/// FEEDBACK STABILITY
/// ------------------
/// ENVO raising the volume does raise the microphone reading, so there is a
/// loop. Its gain is `compensationGain × musicFraction`, where musicFraction
/// is how much of the *floor* is our own playback. The floor is measured at
/// the quiet moments of the program material, so musicFraction is small there;
/// and `compensationGain` is 0.4. The loop gain is well under 1 in every case,
/// so it converges rather than running away — and the range clamp bounds it
/// absolutely regardless.
struct AmbientTracker: Equatable {

    /// Which percentile of the window counts as "the floor". Low enough to sit
    /// under the program material, high enough not to chase single dropouts.
    let percentile: Float

    /// Readings needed before an estimate is produced at all.
    let minimumSamples: Int

    /// How far above the floor a reading may sit and still count as one of the
    /// readings that *defines* the floor. Used by `voiceShareAtFloor`.
    let floorToleranceDB: Float

    private var samples: [Float] = []

    /// Voice-band share captured alongside each level, same index. Kept in
    /// step with `samples` by construction so the two can never drift apart.
    private var voiceShares: [Float] = []

    private let capacity: Int

    init(percentile: Float = 0.2,
         minimumSamples: Int = 5,
         capacity: Int = 60,
         floorToleranceDB: Float = 6.0) {
        self.percentile = min(max(percentile, 0.0), 1.0)
        self.minimumSamples = max(1, minimumSamples)
        self.capacity = max(minimumSamples, capacity)
        self.floorToleranceDB = max(0, floorToleranceDB)
    }

    var count: Int { samples.count }

    mutating func ingest(_ levelDB: Float, voiceShare: Float = 0) {
        guard levelDB.isFinite else { return }
        samples.append(levelDB)
        voiceShares.append(voiceShare.isFinite ? voiceShare : 0)
        if samples.count > capacity {
            let excess = samples.count - capacity
            samples.removeFirst(excess)
            voiceShares.removeFirst(excess)
        }
    }

    mutating func reset() {
        samples.removeAll()
        voiceShares.removeAll()
    }

    /// The ambient floor over the most recent `window` readings, or nil when
    /// there is not yet enough history to say.
    func floorDB(overLast window: Int) -> Float? {
        let count = windowCount(window)
        guard count >= minimumSamples else { return nil }

        let recent = samples.suffix(count).sorted()
        // Order statistic: selecting a percentile is a choice among observed
        // values, so it is correct in dB directly — no power conversion needed.
        let index = Int((Float(recent.count - 1) * percentile).rounded())
        return recent[min(max(index, 0), recent.count - 1)]
    }

    /// Mean voice-band share across only those readings that sit at or near
    /// the floor.
    ///
    /// WHY NOT JUST READ THE LIVE VALUE
    /// --------------------------------
    /// The microphone's voice-band share is a ~140 ms snapshot of whatever is
    /// arriving right now; the floor is a percentile over 10–60 seconds of
    /// history. Feeding the instantaneous share into a decision about the
    /// floor compares two different moments.
    ///
    /// That mismatch has a specific consequence, because **music is voice-band
    /// heavy**. During a loud passage the share sits high, so the anti-Lombard
    /// damper engages — but the floor it is damping was measured in the quiet
    /// gaps, where the room dominates and the music does not. ENVO ends up
    /// discounting a legitimate room reading because the *music* looked like
    /// speech.
    ///
    /// Selecting the readings near the floor fixes the comparison: those are
    /// the moments the floor actually came from, and in them the program
    /// material is quiet, so the voice-band content genuinely is the room.
    func voiceShareAtFloor(overLast window: Int) -> Float? {
        guard let floor = floorDB(overLast: window) else { return nil }
        let count = windowCount(window)

        let levels = Array(samples.suffix(count))
        let shares = Array(voiceShares.suffix(count))
        guard levels.count == shares.count else { return nil }

        var total: Float = 0
        var matched = 0
        for i in 0..<levels.count where levels[i] <= floor + floorToleranceDB {
            total += shares[i]
            matched += 1
        }
        // The floor is itself one of the samples, so this cannot be empty —
        // but the loop stays total rather than relying on that.
        guard matched > 0 else { return nil }
        return total / Float(matched)
    }

    private func windowCount(_ window: Int) -> Int {
        min(max(window, minimumSamples), samples.count)
    }
}

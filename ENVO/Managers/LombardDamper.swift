import Foundation

/// Defence against the Lombard Effect, as a pure function.
///
/// In 1911 Étienne Lombard observed that people involuntarily raise their
/// voices in noise. It is why a restaurant fills and then climbs, conversation
/// by conversation, into a roar: everyone talks louder to clear the noise
/// floor, which raises the noise floor, which makes everyone talk louder.
///
/// A volume controller that naively tracked "the room is getting louder" would
/// ride that spiral and pour it into the listener's ears over an entire
/// evening — the exact "too loud over a long time" failure a safety-conscious
/// design has to prevent. So when the ambient noise is dominated by *voices*
/// rather than by machinery, traffic or crowd wash, ENVO holds back.
///
/// TWO PROPERTIES THAT MAKE THIS SAFE
/// ----------------------------------
/// 1. **One-directional.** The correction only ever subtracts from the ambient
///    estimate, so it can only remove upward pressure on the volume.
/// 2. **Floored at the baseline.** It can never report the room as quieter
///    than it was when START was pressed, so a room full of chatter cannot
///    trick ENVO into creeping the volume *down* either.
///
/// Together these mean the damper can make ENVO do less, never more — a
/// property worth preserving in any future change here.
struct LombardDamper: Equatable {

    /// Voice-band share below which no correction applies at all.
    var engageShare: Float

    /// Share at which the correction reaches its full value.
    var fullEffectShare: Float

    /// Maximum correction.
    ///
    /// Modest on purpose. The percentile ambient floor already sits in the
    /// gaps *between* words, where speech contributes least, so most of this
    /// work is done before the damper is consulted.
    var maxDampingDB: Float

    init(engageShare: Float = 0.45,
         fullEffectShare: Float = 0.85,
         maxDampingDB: Float = 3.0) {
        self.engageShare = engageShare
        self.fullEffectShare = max(fullEffectShare, engageShare + 0.01)
        self.maxDampingDB = max(0, maxDampingDB)
    }

    /// - Parameters:
    ///   - ambientDB: the measured ambient floor.
    ///   - voiceShare: how speech-like the readings *at that floor* were.
    ///     Must be measured on the same samples the floor came from — see
    ///     `AmbientTracker.voiceShareAtFloor`. Passing the instantaneous
    ///     microphone value here reintroduces the bug this signature exists
    ///     to prevent: music is voice-band heavy, so a loud passage would damp
    ///     a floor that was measured during the quiet gaps.
    ///   - baselineDB: the room as it was when START was pressed.
    func damp(ambientDB: Float, voiceShare: Float, baselineDB: Float) -> Float {
        guard ambientDB.isFinite, voiceShare.isFinite, baselineDB.isFinite else {
            return ambientDB
        }
        guard voiceShare > engageShare else { return ambientDB }

        let ramp = AcousticMath.clamp(
            (voiceShare - engageShare) / (fullEffectShare - engageShare), 0, 1
        )
        let damped = ambientDB - maxDampingDB * ramp

        // Never below the baseline, and never below the undamped value.
        return max(damped, min(ambientDB, baselineDB))
    }
}

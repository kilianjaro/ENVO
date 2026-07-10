# ENVO

### Volume that listens to the room.

**Adaptive volume control for iPhone that measures the noise in your environment and levels your audio output in real time — so your music, podcasts, and calls stay perfectly audible as the world around you gets louder or quieter. You set the volume. ENVO keeps it right.**

*By Totemphonia Studio Berlin.*

---

## Summary

You know the dance. On the train, a tunnel roars up and you can't hear your podcast, so you turn it up. The train stops, the roar vanishes, and now it's blasting — so you turn it down. Café, gym, plane, sidewalk: all day your thumb does a job a machine should be doing.

ENVO is that machine. It takes a loudness snapshot of your surroundings once a second through the microphone, works out how loud the room *actually* is (separating the room from your own playback), and gently glides your volume up or down to match. Your chosen level is always the baseline — ENVO only adds a small, safe nudge on top, and the moment you touch the volume buttons, that becomes the new baseline. No audio is ever recorded, stored, or sent anywhere.

Under the hood it's built on real psychoacoustics — the science of how ears actually perceive loudness — including specific defenses against the **Lombard Effect** (the reason a restaurant slowly gets deafening) so it never chases its own tail into your ears.

---

## The problem, in plain language

Imagine you're listening to a podcast at a volume that's *just right*. "Just right" isn't really about the volume of the podcast — it's about the **gap** between the podcast and everything else in the room. Acousticians call this the signal-to-noise ratio, but you can just call it the gap. When the room is quiet, a small volume gives you a comfortable gap. When a bus rolls past, the noise floor rises up and swallows that gap, and suddenly you can't make out the words — even though the podcast is playing at exactly the same volume as before.

So what do you actually want? Not constant *volume*. You want a **constant gap**. You want the podcast to stay the same comfortable distance above the noise, whatever the noise is doing. That means the volume has to move — up when the world gets loud, down when it gets quiet — just to keep the thing you're listening to sitting in the same perceptual place.

That's the whole idea. ENVO watches the noise floor and moves your volume so the gap stays put.

---

## How ENVO works — the science, explained simply

### 1. Listening without recording

Think of a camera's light meter. It reads *how bright* a scene is so the camera can set exposure — but it never keeps the picture. ENVO's microphone reading is exactly that, but for sound. Every fraction of a second it computes a single number — the **RMS** (root-mean-square) energy of the incoming audio, which is just a fancy average of "how much sound pressure is arriving right now." That number is turned into decibels, smoothed, and the raw audio is thrown away instantly. Nothing is recorded, buffered to disk, or transmitted. The math runs on Apple's Accelerate framework (`vDSP`) so it's essentially free for your battery.

### 2. Thinking in decibels, not slider-percent

Here's a thing about ears that trips up naive volume apps: **loudness is logarithmic.** Doubling the actual physical sound power doesn't feel "twice as loud" — it feels like a modest step up. Your ear packs an enormous range of real-world intensities into a comfortable perceptual span. That's why the unit we use is the decibel (dB), which is logarithmic by design: every +6 dB is roughly a *doubling* of amplitude, but only a moderate bump in how loud it *feels*.

Now, the iPhone volume slider is linear — 0 to 100%. So "make it 3 dB louder" is a *tiny* nudge when you're at 20% and a *big* jump when you're at 80%. ENVO always reasons in dB — the language your ear speaks — and then translates that intent into the right slider movement for wherever your baseline happens to be. The payoff: **"+3 dB" feels like the same amount of "louder" whether you started quiet or loud.** This is the `VolumeMath` core, and it's why the adaptation feels natural instead of lurchy.

The **RANGE** control is simply the ceiling on this intent: ±3 dB (gentle), ±6 dB (balanced), or ±9 dB (assertive). ENVO will never push more than that far from your baseline, in either direction.

### 3. The feedback trap — and why calibration exists

The microphone hears *everything* — including your own music coming out of your own speaker. This is a trap. Picture the naive loop: the room gets a little louder → the mic reads "louder" → the app turns up the volume → now the mic hears more of *your own music* → it reads "louder" again → it turns up again → … The volume runs away to the ceiling with no help from the actual environment. It's the audio equivalent of pointing a camera at its own screen.

**Calibration** breaks the loop. Once, in a quiet room, ENVO plays a carefully generated **pink-noise** test tone (pink noise has equal energy per octave — it "sounds balanced" to the ear, unlike harsh white noise) at six volume levels: 15, 30, 50, 70, 85, and 100%. At each level it measures how much of *its own sound* the microphone picks up, and it also measures the room's **silence floor** with the speaker off. The result is a personal curve: *"when my speaker is at 50%, the mic should be hearing about this much of me."*

In everyday use, ENVO subtracts that predicted self-contribution from the live mic reading. What's left is the **true ambient noise** — the room, minus you. It's conceptually like noise cancellation, except it's cancelling the app's own voice out of its *measurement* rather than out of your ears. Calibrated, ENVO can tell the difference between "the café got busy" and "I turned my music up," and only reacts to the first.

ENVO works uncalibrated too — it's more conservative there and caps itself harder to stay safe — but a 30-second calibration is what unlocks the accurate, confident version.

### 4. The Lombard Effect — the one that really matters

In 1911 a French doctor named Étienne Lombard noticed something we all do without realizing: **in the presence of noise, people involuntarily raise their voices.** You've done it in a loud bar. Everyone has. And here's why it's dangerous for a volume-control app:

A restaurant at 7 p.m. is half full and pleasant. As it fills, people talk a little louder to be heard over each other. That makes the room louder. So everyone talks louder *still* to clear the new noise floor. The room climbs, conversation by conversation, into a roar — a slow social feedback spiral driven entirely by the Lombard reflex. If a volume app naively measured "the room is getting louder" and dutifully cranked your audio to match, it would ride that spiral straight up and pour it into your ears, all evening, without you noticing until it hurt. **This is exactly the "too loud over a long time" failure mode a safety-conscious design has to prevent.**

ENVO defends against it by listening to the *shape* of the noise, not just its level. Human speech has a fingerprint: most of its energy lives in a band roughly **300–3000 Hz**. Using the **Goertzel algorithm** — a clever, cheap way to ask "how much energy is sitting at exactly this pitch?" without running a full, expensive frequency analysis — ENVO measures how *speech-like* the ambient noise is at four voice frequencies and three non-voice frequencies, and computes a voice-band share. When the noise floor is dominated by voices, ENVO **holds back**: it refuses to chase people who are simply talking louder. It saves its response for genuine environmental noise — engines, HVAC, machinery, traffic, the wash of a crowd — the stuff that really is masking your audio.

Crucially, this damping is **one-directional and floored**: it can only *remove upward pressure*, never invent downward pressure. So a room full of chatter can't trick ENVO into creeping your volume *down* either. And because the total excursion is hard-capped by the RANGE and the safety ceiling (below), there is no long, slow path to a harmful level. When calibrated, the speech detector is even smarter — it accounts for the fact that music itself is voice-band-heavy, so your own playback doesn't get mistaken for a room full of talkers.

### 5. Ignoring the door slam — transient rejection

A dropped tray, a slammed door, a single cough: loud, but gone in a heartbeat. You do not want your volume to jump because someone bumped a table. ENVO keeps a short rolling window of recent readings and leans on the **median** — the *typical* value — which a lone spike can barely move. A brief burst that towers over the recent normal gets gently "winsorized" (clipped back to a sane threshold) before it can pollute the running average. But **sustained** loudness passes through fine: the median catches up within a few seconds, so a genuinely louder room is fully honored while a hand-clap is shrugged off. This is the `SpikeFilter`.

### 6. Speed and Range — the two dials you actually touch

- **RESPONSE (Speed)** is how long a memory ENVO keeps. **FAST** averages the last 10 seconds and reacts to a passing truck; **SLOW** averages 60 seconds and ignores the truck, moving only when the whole environment shifts; **MED** (30 s) sits in between. Short memory = twitchy and responsive; long memory = calm and deliberate.
- **RANGE** is how far ENVO is allowed to roam from your baseline: **±3 / ±6 / ±9 dB**. Think of it as a leash length.
- **DIR** lets you allow only upward adjustments, only downward, or both — handy if you only ever want ENVO to *rescue* you from noise but never to quiet you down (or vice-versa).

### 7. Gap detection — stealing a clean look at the room

Every so often your own audio pauses — the gap between tracks, a beat of silence in a podcast, the end of a sentence on a call. In those moments the microphone gets a **pure, uncontaminated reading of the room** with no playback to subtract. ENVO notices these natural gaps and uses them to quietly re-anchor its estimate of the true noise floor, keeping the whole system honest between calibrations. If the live silence floor drifts far from what calibration recorded, ENVO surfaces a gentle "recalibrate?" hint.

---

## Safety — why ENVO can't run away with your ears

This is the part that got the most engineering attention, because a volume controller that can misbehave is not a product — it's a hazard. ENVO stacks **several independent guards**, any one of which alone would prevent a runaway:

1. **Hard ceiling.** ENVO will never drive the system above **92%** volume, no matter what the room does. Full stop.
2. **Range cap.** It will never move more than your chosen **±3/6/9 dB** from *your* baseline, in either direction.
3. **Rate limit.** It can't change faster than a slow, smooth glide (a few percent per second). No sudden jumps — every adjustment is a gentle ramp.
4. **Your baseline always wins.** The instant you touch a volume button or Control Center, that new level becomes the baseline and ENVO's offset resets to zero. You are never fighting the app; it always yields to you.
5. **Mean-reverting by design.** When the room quiets down, the offset melts back toward zero on its own. ENVO's natural resting state is "do nothing."
6. **Lombard-proofed.** As described above, the speech-share damper specifically prevents the slow social feedback spiral from ever translating into a slow creep on your volume over a long session.
7. **Transient-proofed.** Spikes can't trigger jumps.
8. **Feedback-proofed.** Calibration stops the app from hearing itself and chasing its own output.

The design goal is simple: **you should be able to forget ENVO is on.** It should quietly keep things comfortable and never, ever surprise you.

---

## Real-world use cases

**The commute (train / subway / bus).** The classic. Tunnels roar, stations fall quiet, the doors open onto a platform and close again. ENVO tracks every transition so your podcast stays intelligible in the tunnel and doesn't blast you on the platform. Set RESPONSE to FAST for reactive transit environments.

**Café & co-working.** You're working to a playlist. The espresso grinder screams for four seconds, the milk steamer hisses, a group sits down nearby. Instead of you reaching for the volume every few minutes, ENVO rides the swells — and its spike filter shrugs off the grinder's short bursts so your music doesn't pump.

**The open-plan office.** The room is calm at 9 a.m. and swells after lunch as it fills and conversations multiply. This is a textbook Lombard environment — exactly where a naive app would slowly cook your ears. ENVO recognizes the rising tide is *voices* and holds steady, only nudging for the genuine mechanical noise (AC, printers, the street outside).

**Air travel.** A plane cabin is a wall of low-frequency engine drone — constant and heavy. ENVO finds the right offset to keep your film or music clearly above the drone and simply *holds it* there for the whole flight, easing back only for the quiet moments (boarding, taxiing, the seatbelt-sign announcement).

**The gym.** Class music thumps, then it's quiet between your own sets. ENVO keeps your headphones balanced against the room so you're not deafened during a track and straining during a rest.

**Cooking with a podcast.** Extractor fan on, tap running, pan sizzling, then sudden quiet. Your hands are covered in flour. ENVO is the sous-chef that manages the volume so you don't have to.

**Restaurants & bars (solving the space, not just the listener).** On a call in a bar that's filling up? ENVO keeps your caller audible without you joining the shouting match — and because it's Lombard-aware, it won't mistake the rising hubbub for a reason to keep climbing. When the group leaves and the room suddenly hushes, ENVO catches the drop and eases you down *before* you become the person whose phone is audible three tables over. That "sudden-silence blast" — the library moment — is precisely the public-space acoustics problem ENVO is built to prevent.

---

## Privacy

ENVO is built to be trustworthy with the most sensitive sensor on your phone:

- **No audio is recorded, stored, or transmitted — ever.** Only instantaneous power levels are computed in memory and immediately discarded.
- **Everything runs on-device.** There is no server, no account, no network call. ENVO has no analytics and collects no personal data.
- **Calibration profiles stay local**, saved only on your device.
- The microphone is used **exclusively** for real-time noise-level measurement, and this is stated plainly in the permission prompt.

---

## Features

- 🎚️ **Real-time adaptive volume** driven by ambient noise
- 🧠 **Psychoacoustic dB-domain adaptation** — perceptually consistent at any base level
- 🗣️ **Lombard-Effect defense** via speech-band (Goertzel) detection
- 🎯 **Room calibration** to separate your playback from true ambient noise
- 🚪 **Transient rejection** so door slams and coughs don't move your volume
- 🛡️ **Layered safety**: hard ceiling, range cap, rate limiting, instant user override
- 🎧 **Background operation** with any audio app (Music, Spotify, Podcasts, YouTube, calls)
- 🔵 **Bluetooth-aware** — keeps hi-fi A2DP output on your headphones while sensing the room with the built-in mic
- 🗣️ **Siri & Shortcuts** — "Start ENVO," "Stop ENVO," Action Button, automations
- 🔒 **Private by design** — no recording, no network, no data collection
- 🌑 **Distinctive brutalist interface** with a live noise visualizer

---

## Controls at a glance

| Control | What it does |
|---|---|
| **RESPONSE** | Reaction speed — SLOW (60 s) / MED (30 s) / FAST (10 s) averaging window |
| **RANGE** | Maximum adjustment — ±3 dB / ±6 dB / ±9 dB from your baseline |
| **DIR** | Allow volume increases (+), decreases (–), or both |
| **CALIBRATE** | Run a 30 s room calibration, or a 5 s quick silence-floor refresh |
| **START / STOP** | Activate or deactivate adaptation |
| **AUTO-RESUME** | Optionally restart ENVO on launch if it was running at last quit |

---

## Requirements & build

- **iOS 16.0+**, iPhone (portrait)
- **Xcode 16+**, Swift 5
- Microphone permission (requested on first START / CALIBRATE)
- `UIBackgroundModes: audio` for continuous background monitoring

```bash
# Build & run tests from the project directory
cd ENVO
xcodebuild -project ENVO.xcodeproj -scheme ENVO \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

---

## Architecture (for developers)

ENVO is a compact SwiftUI + Combine app with a clean separation between the pure signal/DSP logic and the platform glue:

| Component | Responsibility |
|---|---|
| `AudioManager` | Mic tap, RMS via `vDSP`, dB normalization, Goertzel voice-band share. Reads levels only — never records. |
| `EnvoEngine` | The 1 Hz control loop: ambient estimate → dB intent → smoothing → rate limit → safety ceiling. Holds the safety guards. |
| `VolumeMath` | Pure, unit-tested dB ↔ slider-delta conversions (base-relative, ceiling-aware). |
| `SpikeFilter` | Median/IQR winsorizing transient rejection. |
| `CalibrationManager` / `CalibrationProfile` / `CalibrationStore` | Runs the pink-noise sweep, builds & persists the room curve. |
| `VolumeController` | Owns the system volume via `MPVolumeView`, KVO-observes user changes, enforces "user always wins." |
| `BackgroundAudioHandler` | Silent looping player + audio-session lifecycle for background survival. |
| `NowPlayingController` / `EnvoIntents` | Lock-screen tile and Siri/Shortcuts surface. |

The DSP and math layers (`VolumeMath`, `SpikeFilter`, `CalibrationProfile`, `SettingsStore`, font scaling) are covered by unit tests and are deterministic and side-effect-free, which makes the safety-critical behavior verifiable in isolation.

---

## Credits

Designed and built by **Totemphonia Studio Berlin** — [totemphonia.com](https://totemphonia.com)

*ENVO reads your environment so your ears don't have to.*

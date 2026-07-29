# ENVO

### Volume that listens to the room.

**Adaptive volume control for iPhone that measures the noise in your environment and levels your audio output in real time — so your music, podcasts, and calls stay perfectly audible as the world around you gets louder or quieter. You set the volume. ENVO keeps it right.**

*By Totemphonia Studio Berlin.*

---

## Summary

You know the dance. On the train, a tunnel roars up and you can't hear your podcast, so you turn it up. The train stops, the roar vanishes, and now it's blasting — so you turn it down. Café, gym, plane, sidewalk: all day your thumb does a job a machine should be doing.

ENVO is that machine. It takes a loudness snapshot of your surroundings once a second through the microphone, finds the room's true noise floor underneath your own playback, and eases your volume up or down to match. Your chosen level is always the baseline — ENVO only adds a small, safe nudge on top, and the moment you touch the volume buttons, that becomes the new baseline. No audio is ever recorded, stored, or sent anywhere.

Under the hood it's built on real psychoacoustics — the science of how ears actually perceive loudness — including specific defenses against the **Lombard Effect** (the reason a restaurant slowly gets deafening) so it never chases its own tail into your ears.

---

## The problem, in plain language

Imagine you're listening to a podcast at a volume that's *just right*. "Just right" isn't really about the volume of the podcast — it's about the **gap** between the podcast and everything else in the room. Acousticians call this the signal-to-noise ratio, but you can just call it the gap. When the room is quiet, a small volume gives you a comfortable gap. When a bus rolls past, the noise floor rises up and swallows that gap, and suddenly you can't make out the words — even though the podcast is playing at exactly the same volume as before.

So what do you actually want? Not constant *volume*. You want a **constant gap**. You want the podcast to stay the same comfortable distance above the noise, whatever the noise is doing. That means the volume has to move — up when the world gets loud, down when it gets quiet — just to keep the thing you're listening to sitting in the same perceptual place.

That's the whole idea. ENVO watches the noise floor and moves your volume so the gap stays put.

---

## How ENVO works — the science, explained simply

### 1. Listening without recording

Think of a camera's light meter. It reads *how bright* a scene is so the camera can set exposure — but it never keeps the picture. ENVO's microphone reading is exactly that, but for sound. Every fraction of a second it computes a single number — the **RMS** (root-mean-square) energy of the incoming audio, which is just a fancy average of "how much sound pressure is arriving right now." That number is turned into decibels, smoothed, and the raw audio is thrown away instantly. Nothing is recorded, buffered to disk, or transmitted.

Before that measurement, the signal passes through an **A-weighting filter** — the same correction a sound level meter applies when it reports dB(A). Ears are far less sensitive to low frequencies, but low frequencies carry enormous energy: traffic rumble, ventilation, a fridge compressor, the body of a bus, wind across the microphone. Measured flat, those dominate the number while barely affecting whether you can actually hear your podcast, and a control loop reading them would chase rumble instead of the noise that genuinely masks your audio. A-weighting discounts them by roughly 19 dB at 100 Hz and 39 dB at 31.5 Hz, so what ENVO measures tracks what you *perceive*.

A note on the number shown on screen: converting dBFS to an absolute dB SPL figure requires knowing the microphone's exact sensitivity, which iOS does not expose and which varies by device. **The displayed value is an estimate, ±10 dB.** What it reports faithfully is *change* — the scale is 1:1, so a room that gets 10 dB louder moves the reading by 10.

### 2. Thinking in decibels, not slider-percent

Here's a thing about ears that trips up naive volume apps: **loudness is logarithmic.** Doubling the actual physical sound power doesn't feel "twice as loud" — it feels like a modest step up. Your ear packs an enormous range of real-world intensities into a comfortable perceptual span. That's why the unit we use is the decibel (dB), which is logarithmic by design: every +6 dB is roughly a *doubling* of amplitude, but only a moderate bump in how loud it *feels*.

Now, the iPhone volume slider is *not* a straight percentage of loudness. It's a **tapered fader**: its twenty hardware steps are spread across several tens of dB of real acoustic range, so halving the slider is far more than halving the perceived loudness. A volume app that assumes the slider is proportional to amplitude will hand you two or three times the adjustment you asked for.

ENVO reasons entirely in dB — the language your ear speaks — and converts that intent into slider movement exactly once, through a **taper model** (`VolumeTaper`). Two sources feed it:

- **Uncalibrated**, ENVO assumes a deliberately *steep* curve. Assuming steeper-than-reality means each requested dB maps to a smaller slider move, so ENVO errs toward adjusting **less** than you asked for. Under-delivering is a mild disappointment; over-delivering is a safety problem.
- **Calibrated**, the taper is *measured* on your actual device (see below), and "±6 dB" means ±6 dB on your hardware.

The payoff either way: **"+3 dB" feels like the same amount of "louder" whether you started quiet or loud** — and it never quietly becomes +8.

The **RANGE** control is a hard ceiling on this intent, not a sensitivity dial: ±3 dB (gentle), ±6 dB (balanced), or ±9 dB (assertive). ENVO will never push more than that far from your baseline, in either direction. How *strongly* it reacts is a separate, fixed constant (it applies about 0.4 dB of volume change per dB of room change) — so widening the range gives you more headroom without also making ENVO twitchier.

### 3. The feedback trap — finding the room underneath your own music

The microphone hears *everything* — including your own music coming out of your own speaker. This is a trap. Picture the naive loop: the room gets a little louder → the mic reads "louder" → the app turns up the volume → now the mic hears more of *your own music* → it reads "louder" again → it turns up again → … The volume runs away to the ceiling with no help from the actual environment. It's the audio equivalent of pointing a camera at its own screen.

The tempting fix is to subtract your playback from the reading. It doesn't work, for a reason worth stating plainly: **you can't know how loud your own playback is.** The volume setting tells you the *gain*, not the level — a quiet passage and a loud chorus at the same slider position are twenty decibels apart. Any fixed estimate of "what my speaker is contributing right now" is wrong nearly all the time, and subtracting a wrong number is worse than subtracting nothing.

ENVO uses **percentile noise-floor tracking** instead (`AmbientTracker`). Music and speech are dynamic: between beats, between words, in decays and pauses, the microphone hears mostly the room. So ENVO keeps a rolling window of the last 10–60 seconds of readings and takes the **20th percentile** — the level the signal keeps falling back to. That's the ambient floor, and it works whether you're playing loud music, quiet podcasts, or nothing at all.

This also settles the feedback question mathematically. The loop's gain is `0.4 × (how much of the floor is your own playback)`. Because the floor is measured at the program material's *quiet* moments, that fraction is small — and 0.4 is already well under 1. The loop converges instead of running away, and the range cap bounds it absolutely regardless.

**So what is calibration for?** Two things, both real:

1. It measures your device's **volume taper** — how much actual loudness each slider position produces — which is what makes "±6 dB" mean ±6 dB rather than a cautious guess. This is the big one.
2. It records the room's **silence floor**, which lets ENVO notice later that you're somewhere acoustically different and suggest recalibrating.

Calibration plays a carefully generated **pink-noise** test tone (pink noise has equal energy per octave — it "sounds balanced" to the ear, unlike harsh white noise) at six volume levels: 25, 40, 55, 70, 85, and 100%, plus a silent step to read the room. It takes about 35 seconds. If the microphone never hears the test tone clearly above the room, the run **fails loudly** rather than saving a profile full of nothing — a confidently wrong profile is worse than no profile.

ENVO works fine uncalibrated. It simply uses the cautious default taper, so it adjusts somewhat less than the range you selected.

### 4. The Lombard Effect — the one that really matters

In 1911 a French doctor named Étienne Lombard noticed something we all do without realizing: **in the presence of noise, people involuntarily raise their voices.** You've done it in a loud bar. Everyone has. And here's why it's dangerous for a volume-control app:

A restaurant at 7 p.m. is half full and pleasant. As it fills, people talk a little louder to be heard over each other. That makes the room louder. So everyone talks louder *still* to clear the new noise floor. The room climbs, conversation by conversation, into a roar — a slow social feedback spiral driven entirely by the Lombard reflex. If a volume app naively measured "the room is getting louder" and dutifully cranked your audio to match, it would ride that spiral straight up and pour it into your ears, all evening, without you noticing until it hurt. **This is exactly the "too loud over a long time" failure mode a safety-conscious design has to prevent.**

ENVO defends against it by listening to the *shape* of the noise, not just its level. Human speech has a fingerprint: most of its energy lives in a band roughly **300–3000 Hz**. Using the **Goertzel algorithm** — a clever, cheap way to ask "how much energy is sitting at exactly this pitch?" without running a full, expensive frequency analysis — ENVO measures how *speech-like* the ambient noise is at four voice frequencies and three non-voice frequencies, and computes a voice-band share. When the noise floor is dominated by voices, ENVO **holds back**: it refuses to chase people who are simply talking louder. It saves its response for genuine environmental noise — engines, HVAC, machinery, traffic, the wash of a crowd — the stuff that really is masking your audio.

Crucially, this damping is **one-directional and floored**: it can only *remove upward pressure*, never invent downward pressure. It's clamped never to read the room as quieter than the baseline, so a room full of chatter can't trick ENVO into creeping your volume *down* either. And because the total excursion is hard-capped by the RANGE and the safety ceiling (below), there is no long, slow path to a harmful level.

There's a subtlety here that's easy to get wrong, and worth spelling out: **music is voice-band heavy too.** A rock track and a room full of talkers look similar to a speech detector. So *when* you sample the voice-band share matters as much as how you measure it. ENVO records the share alongside every level reading, and when the damper asks "how speech-like is this room?", it looks only at the readings that sit at or near the noise floor — the quiet moments the floor was actually derived from. In those moments your own playback is quiet, so what's left really is the room. Sampling the live microphone value instead would engage the damper during every loud musical passage and quietly suppress ENVO's response for the wrong reason.

The correction is deliberately modest — at most 3 dB — because the percentile floor already does much of this work for free: it sits in the gaps *between* words, where speech contributes least.

### 5. Ignoring the door slam — transient rejection

A dropped tray, a slammed door, a single cough: loud, but gone in a heartbeat. You do not want your volume to jump because someone bumped a table. ENVO keeps a short rolling window of recent readings and leans on the **median** — the *typical* value — which a lone spike can barely move. A brief burst that towers over the recent normal gets gently "winsorized" (clipped back to a sane threshold) before it can reach the noise-floor estimate. But **sustained** loudness passes through fine: the median catches up within a few seconds, so a genuinely louder room is fully honored while a hand-clap is shrugged off. This is the `SpikeFilter`.

### 6. Speed and Range — the two dials you actually touch

- **RESPONSE (Speed)** is how long a memory ENVO keeps — the window the noise floor is measured over. **FAST** looks at the last 10 seconds and reacts to a passing truck; **SLOW** looks at 60 seconds and ignores the truck, moving only when the whole environment shifts; **MED** (30 s) sits in between. Short memory = twitchy and responsive; long memory = calm and deliberate.
- **RANGE** is how far ENVO is allowed to roam from your baseline: **±3 / ±6 / ±9 dB**. Think of it as a leash length.
- **DIR** lets you allow only upward adjustments, only downward, or both — handy if you only ever want ENVO to *rescue* you from noise but never to quiet you down (or vice-versa).

### 7. Noticing you've changed rooms

Every so often your own audio pauses — the gap between tracks, a beat of silence in a podcast, the end of a sentence on a call. In those moments the microphone gets a **pure, uncontaminated reading of the room**.

ENVO watches for these stretches (five consecutive seconds where nothing rises more than 3 dB above the expected floor) and compares what it hears against the silence floor recorded at calibration. If four of them in a row disagree by more than 6 dB, the room you're in is not the room you calibrated in, and the CALIBRATE button quietly changes to **RECAL?**.

That's all it does now. Earlier versions leaned on these pauses as the *only* moment ambient could be measured; percentile tracking reads the floor continuously, so the pauses are no longer load-bearing — just a convenient sanity check.

---

## Safety — why ENVO can't run away with your ears

This is the part that got the most engineering attention, because a volume controller that can misbehave is not a product — it's a hazard. ENVO stacks **several independent guards**, any one of which alone would prevent a runaway:

1. **Hard ceiling.** ENVO will never drive the system above **92%** volume, no matter what the room does. It caps ENVO's own contribution only — if *you* choose a higher volume, ENVO leaves it alone rather than dragging you back down.
2. **Range cap.** It will never move more than your chosen **±3/6/9 dB** from *your* baseline, in either direction.
3. **Absolute travel limit.** Independently of the taper, the range and the control loop, ENVO may never move the slider more than **0.25** of its full travel — five hardware steps. This is enforced again at the point that actually touches the hardware, because a limit is only worth having where the writes happen.
4. **Rate limit.** The adjustment can't change faster than **0.75 dB per second**. Note what this can and cannot promise: iOS quantizes the system volume to twenty steps of 0.05, so a single step is worth roughly **3 dB** of real loudness and the output physically cannot glide. What the rate limit actually buys is *spacing* — ENVO must accumulate several seconds of consistent intent before it crosses a step boundary, so steps are infrequent and never rapid. A quarter-step of hysteresis on either side of each boundary stops the output flipping back and forth when the intent hovers near one.
5. **Your baseline always wins.** The instant you touch a volume button or Control Center, that new level becomes the baseline, ENVO's offset resets to zero, and it re-measures the room from there. You are never fighting the app.
6. **Mean-reverting by design.** When the room quiets down, the offset melts back toward zero on its own, and lands exactly on zero rather than hovering near it. ENVO's natural resting state is "do nothing."
7. **Lombard-proofed.** As described above, the speech-share damper prevents the slow social feedback spiral from translating into a slow creep on your volume over a long session.
8. **Transient-proofed.** Spikes can't trigger jumps.
9. **Feedback-proofed.** The noise floor is measured at the quiet moments of your own program material, so ENVO's own output barely enters it. The resulting loop gain is far below 1 — the loop converges by construction, not by luck.
10. **Never steers blind.** If the microphone stops delivering audio — an interruption, a media-services reset, a failed engine start — ENVO *holds* its current adjustment and works on reviving the mic. It never acts on a frozen reading.
11. **Starts over when the setup changes.** Plug in headphones and your speaker's bleed into the microphone vanishes; unplug them and it reappears. Neither is the room changing, but both move the measured noise floor, and a naive controller would follow them the wrong way. ENVO watches for route changes, drops its adjustment to zero and re-measures the room from scratch — without writing the slider on the way out, since each route has its own remembered volume.

The design goal is simple: **you should be able to forget ENVO is on.** It should quietly keep things comfortable and never, ever surprise you.

Guards 1–4 and 6 are proven by property tests that sweep every base volume against every range and several taper shapes, driving the *shipping* control law rather than a re-implementation of it. Guard 10's decision half — that an unusable reading holds the adjustment instead of resetting it — is covered too; the microphone-revival path around it is device behaviour and is verified by hand.

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
- 🎯 **Room calibration** that measures your device's real volume curve, so the dB range you pick is the dB range you get
- 🚪 **Transient rejection** so door slams and coughs don't move your volume
- 🛡️ **Layered safety**: hard ceiling, range cap, absolute travel limit, rate limiting, instant user override
- 🎧 **Background operation** with any audio app (Music, Spotify, Podcasts, YouTube, calls)
- 🔵 **Bluetooth-aware** — keeps hi-fi A2DP output on your headphones while sensing the room with the built-in mic
- 🗣️ **Siri & Shortcuts** — "Start ENVO," "Stop ENVO," Action Button, automations
- 🤫 **Inert until you start it** — ENVO doesn't claim the audio session or change anything about your playback until you press START, and hands the route straight back when you stop
- 🔒 **Private by design** — no recording, no network, no data collection
- 🌑 **Distinctive brutalist interface** with a live noise visualizer

---

## Controls at a glance

| Control | What it does |
|---|---|
| **RESPONSE** | Reaction speed — SLOW (60 s) / MED (30 s) / FAST (10 s) noise-floor window |
| **RANGE** | Maximum adjustment — ±3 dB / ±6 dB / ±9 dB from your baseline |
| **DIR** | Allow volume increases (+), decreases (–), or both |
| **CALIBRATE** | Run a ~35 s room calibration, or a 5 s quick silence-floor refresh |
| **START / STOP** | Activate or deactivate adaptation |
| **AUTO-RESUME** | Optionally restart ENVO on launch if it was running at last quit |

---

## Requirements & build

- **iOS 16.0+**, iPhone (portrait)
- **Xcode 16+**, Swift 5
- Microphone permission (requested on first START / CALIBRATE)
- `UIBackgroundModes: audio` for continuous background monitoring

```bash
# Run from the folder containing ENVO.xcodeproj (the same folder as this README)
xcodebuild -project ENVO.xcodeproj -scheme ENVO \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

---

## Architecture (for developers)

ENVO is a compact SwiftUI + Combine app with a clean separation between the pure signal/DSP logic and the platform glue:

| Component | Responsibility |
|---|---|
| `AudioManager` | Mic tap, A-weighted RMS, dBFS levels, Goertzel voice-band share, liveness tracking. Reads levels only — never records. |
| `AWeightingFilter` | IEC 61672 A-weighting as three biquads, so the level tracks perceived loudness rather than low-frequency energy. |
| `EnvoEngine` | The 1 Hz loop, wiring the pure pieces together and owning lifecycle. |
| `AcousticMath` | Power-domain dB arithmetic. Decibels are logarithmic, so combining them requires converting to power first — doing it naively is a whole class of bug. |
| `AmbientTracker` | Percentile noise-floor estimation, plus the voice-band share of the readings that define that floor. No assumption about what's playing. |
| `LombardDamper` | Speech-share damping, provably one-directional: it can only ever make ENVO adjust less. |
| `ControlLaw` | The adjustment decision as a pure function: room delta → dB offset, with gain, smoothing, dead band and rate limit. |
| `VolumeTaper` (in `VolumeMath.swift`) | dB ↔ slider-delta conversion through a measured or default taper, with the bounds enforced. |
| `SpikeFilter` | Median/IQR winsorizing transient rejection. |
| `CalibrationManager` / `CalibrationProfile` / `CalibrationStore` | Runs the pink-noise sweep, derives the taper, validates and persists. Refuses to save an unusable profile, and discards profiles from older schemas rather than reinterpreting them. |
| `VolumeController` | Owns the system volume via `MPVolumeView`, KVO-observes user changes, enforces "user always wins", applies the final travel clamp, and snaps writes to the hardware's 0.05 step grid with hysteresis so the output cannot flip between steps. |
| `AudioSessionController` | Sole owner of the `AVAudioSession` category and activation, reference-counted between the engine and calibration. Nothing touches the session at launch. |
| `BackgroundAudioHandler` | Silent looping player for background survival. |
| `NowPlayingController` / `EnvoIntents` | Lock-screen tile and Siri/Shortcuts surface. |

**Testing.** The safety-critical logic lives in pure, deterministic types — `AcousticMath`, `AmbientTracker`, `ControlLaw`, `LombardDamper`, `VolumeTaper`, `SpikeFilter`, `CalibrationProfile` — plus `AWeightingFilter` — so the guarantees can be verified in isolation. 105 tests cover them, including property tests that sweep the full parameter space for bound violations, an end-to-end simulation that runs the real tracker, spike filter and control law over a changing room, and a check of the A-weighting response against the IEC 61672 table.

This structure is deliberate: an earlier version proved its safety properties with a hand-written simulation that *re-implemented* the control loop, which meant it could only ever prove things about itself. The tests now drive the shipping code.

---

## Credits

Designed and built by **Totemphonia Studio Berlin** — [totemphonia.com](https://totemphonia.com)

*ENVO reads your environment so your ears don't have to.*

# ENVO

### Volume that listens to the room.

**Adaptive volume control for iPhone that measures the noise in your environment and levels your audio output in real time — so your music, podcasts, and calls stay perfectly audible as the world around you gets louder or quieter. You set the volume. ENVO keeps it right.**

*By Totemphonia Studio Berlin.*

---

## Summary

You know the dance. On the train, a tunnel roars up and you can't hear your podcast, so you turn it up. The train stops, the roar vanishes, and now it's blasting — so you turn it down. Café, gym, plane, sidewalk: all day your thumb does a job a machine should be doing.

ENVO is that machine. It measures your surroundings ten times a second through the microphone, finds the room's true noise floor underneath your own playback, and eases your volume up or down to match. Your chosen level is always the baseline — ENVO only adds a small, safe nudge on top, and the moment you touch the volume buttons, that becomes the new baseline. No audio is ever recorded, stored, or sent anywhere.

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

Before that measurement, the signal is split into six **octave bands** — 125 Hz, 250, 500, 1 k, 2 k, 4 k — because "how loud is this room" and "how much of my audio is this room burying" are not the same question, and only the second one matters here.

The obvious instrument would be an **A-weighting filter**, the correction a sound level meter applies when it reports dB(A). ENVO measures that too, and reports it in the calibration log, because it is the number you can compare against any SPL app. But A-weighting is a *loudness* curve, and it is the wrong tool for a masking problem. It discounts 100 Hz by about 19 dB on the grounds that ears are insensitive there — and then a bus, a train or an aircraft cabin, which are essentially a wall of low-frequency drone, reads as unremarkable while making your podcast completely unintelligible.

The reason is a real psychoacoustic effect called **upward spread of masking**: low-frequency noise doesn't just mask low-frequency content, it raises the threshold of audibility in the bands *above* it. So ENVO takes each band's level, spreads it upward at 12 dB per octave, and combines the result using the octave-band importance weights from ANSI S3.5 — the standard for which frequencies actually carry the information a listener needs. What comes out is a single number that tracks how buried your audio is, not how loud the room feels. A flat room at some level reads exactly that level, and the arithmetic is 1:1 in dB.

**A note on the number shown on screen, and an honest limit.** It is this masking-weighted figure, so it is *not* a dB(A) reading and won't match an SPL app. Converting to an absolute dB SPL figure would require knowing the microphone's exact sensitivity, which iOS does not expose and which varies by device. **The displayed value is an estimate, ±10 dB.**

It is also **compressed**, and this is worth stating plainly because it was measured rather than assumed. iOS applies automatic gain control to microphone input — quietly turning the mic down as things get louder — and switching that off requires a session mode that also bypasses the *output* processing chain for the whole device, making every app's playback quieter. For an app whose entire job is managing how loud music is, that trade is not available at any price. So the AGC stays.

The cost, measured on an iPhone 14 against a calibrated sound level meter: a room change verified at 20 dB read as **15.6 dB**. A slope of 0.78, identical going up and coming down, returning to within 0.1 dB. ENVO is tuned to account for it — the control gain is raised to suit — but the consequence is that ENVO's decibels are approximate, not exact. It adapts *usefully*, not *accurately*, and on this hardware that is the only honest option.

### 2. Thinking in decibels, not slider-percent

Here's a thing about ears that trips up naive volume apps: **loudness is logarithmic.** Doubling the actual physical sound power doesn't feel "twice as loud" — it feels like a modest step up. Your ear packs an enormous range of real-world intensities into a comfortable perceptual span. That's why the unit we use is the decibel (dB), which is logarithmic by design: every +6 dB is roughly a *doubling* of amplitude, but only a moderate bump in how loud it *feels*.

Now, the iPhone volume slider is *not* a straight percentage of loudness. It's a **tapered fader**: its twenty hardware steps are spread across several tens of dB of real acoustic range, so halving the slider is far more than halving the perceived loudness. A volume app that assumes the slider is proportional to amplitude will hand you two or three times the adjustment you asked for.

ENVO reasons entirely in dB — the language your ear speaks — and converts that intent into slider movement exactly once, through a **taper model** (`VolumeTaper`). Two sources feed it:

- **Uncalibrated**, ENVO assumes a deliberately *steep* curve. Assuming steeper-than-reality means each requested dB maps to a smaller slider move, so ENVO errs toward adjusting **less** than you asked for. Under-delivering is a mild disappointment; over-delivering is a safety problem.
- **Calibrated**, the taper is *measured* on your actual device (see below), and "±6 dB" means ±6 dB on your hardware.

The payoff either way: **"+3 dB" feels like the same amount of "louder" whether you started quiet or loud** — and it never quietly becomes +8.

The **RANGE** control is a hard ceiling on this intent, not a sensitivity dial: ±3, ±6 or ±9 dB. ENVO will never push more than that far from your baseline, in either direction. How *strongly* it reacts is a separate, fixed constant — about 0.5 dB of volume change per dB of room change, which after the microphone's compression works out near 0.4 in practice — so widening the range gives you more headroom without also making ENVO twitchier.

**What that adds up to in practice**, and it is coarser than the decibels above suggest, because iOS only lets an app move the system volume in fixed steps of roughly 3 dB:

| The room gets louder by | ENVO does |
|---|---|
| under ~5 dB | nothing |
| ~5 dB | one step, +3 dB |
| ~12 dB | two steps, +6 dB |
| ~20 dB | three steps, +9 dB |

An office filling up after lunch is about 8 dB. A quiet home to a busy café is about 25. So in daily use you would see one or two steps, occasionally three. Coming back down works the same way, with a deliberate dead zone in between so the volume cannot flutter between two steps.

### 3. The feedback trap — finding the room underneath your own music

The microphone hears *everything* — including your own music coming out of your own speaker. This is a trap. Picture the naive loop: the room gets a little louder → the mic reads "louder" → the app turns up the volume → now the mic hears more of *your own music* → it reads "louder" again → it turns up again → … The volume runs away to the ceiling with no help from the actual environment. It's the audio equivalent of pointing a camera at its own screen.

The tempting fix is to subtract your playback from the reading. It doesn't work, for a reason worth stating plainly: **you can't know how loud your own playback is.** The volume setting tells you the *gain*, not the level — a quiet passage and a loud chorus at the same slider position are twenty decibels apart. Any fixed estimate of "what my speaker is contributing right now" is wrong nearly all the time, and subtracting a wrong number is worse than subtracting nothing.

ENVO uses **percentile noise-floor tracking** instead (`AmbientTracker`). Music and speech are dynamic: between beats, between words, in decays and pauses, the microphone hears mostly the room. So ENVO keeps a rolling window of the last 10–60 seconds of readings and takes **L90** — the level the signal exceeds 90% of the time, the standard statistic for a residual noise floor in environmental acoustics. That's the ambient floor, and it works whether you're playing loud music, quiet podcasts, or nothing at all.

A percentile is only as good as the number of readings behind it, which is why ENVO measures ten times a second rather than once. Sampled at 1 Hz, the L90 of a ten-second window is the single lowest of ten readings — an estimator with several decibels of scatter produced by nothing but which millisecond each reading happened to land on. At 10 Hz the same window carries a hundred readings and the estimate is steady. Each reading is a proper **125 ms Fast-weighted level**, the short integration a sound level meter uses, not an instantaneous snapshot.

**But there is an honest limit here, and ENVO handles it explicitly.** The gaps trick works beautifully for speech — a podcast drops to the room level between sentences. It works far less well for dense modern music played on a speaker: a mastered pop track has a loudness range of three to eight decibels, so there are no real gaps, and the floor lands a few dB under *the music* rather than on the room. Then the loop is partly listening to itself: ENVO turns up, the floor it measures rises with it, and it reads its own output as the room getting louder. It still converges — the loop gain stays well under 1 and the range cap bounds it absolutely — but the effective gain climbs from the 0.4 it was tuned for to about 0.67.

So ENVO measures that coupling and removes what it can (`SelfCouplingEstimator`). It knows exactly when it moved the volume and by exactly how many decibels, which makes its own adjustment a probe signal: step the output by a known amount, watch what the measured floor does, and the ratio is how much of the floor is the device rather than the room. On headphones it settles near 0 and nothing is subtracted; on a speaker it climbs, and the device's added contribution comes back out. This is backed by a starting estimate derived from the output route — the built-in speaker is a few centimetres from the microphone and certainly couples, sealed headphones certainly don't — which a completed measurement then overrides.

#### The wall this eventually hits, stated plainly

There is a limit here that no amount of cleverness gets past, and it was measured on a real device rather than reasoned about.

The probe above can only subtract the music **ENVO itself added** — the amount above the volume *you* chose. It has no way to remove the music you were already playing when you pressed START. And on iOS it never will: subtracting your music would require access to the audio another app is playing, and the system does not hand that to anyone.

So when continuous music plays out loud, loudly enough to be the loudest thing in the room, it sets a floor that ENVO cannot see beneath. A test bears this out exactly: with the same track at the same volume, the room was dropped by 22 dB and ENVO's measured floor moved **0.4 dB**. It had stopped listening to the room and was listening to the music.

What that means in practice:

| Listening through | Adapting downward |
|---|---|
| **Headphones** | Full range. The microphone cannot hear your music at all. |
| **Speech — podcasts, audiobooks — out loud** | Works. The gaps between sentences genuinely reach the room. |
| **Continuous music out loud** | Returns you to your starting volume, but cannot go below it. |

Worth noting which way this fails. When your music is the loudest thing in the room, you do not need it turned down in order to *hear* it — the gap is already enormous. Failing to reduce is a comfort miss, not an audibility one, and ENVO still restores your baseline correctly. It is the least harmful of the available failures, which is why the design accepts it rather than papering over it.

**So what is calibration for?** Two things, both real:

1. It measures your device's **volume taper** — how much actual loudness each slider position produces — which is what makes "±6 dB" mean ±6 dB rather than a cautious guess. This is the big one.
2. It records the room's **silence floor**, which lets ENVO notice later that you're somewhere acoustically different and suggest recalibrating.

Calibration plays a carefully generated **pink-noise** test tone (pink noise has equal energy per octave — it "sounds balanced" to the ear, unlike harsh white noise) at six volume levels: 25, 40, 55, 70, 85, and 100%, plus a silent step to read the room. It takes about 35 seconds. If the microphone never hears the test tone clearly above the room, the run **fails loudly** rather than saving a profile full of nothing — a confidently wrong profile is worse than no profile.

ENVO works fine uncalibrated. It simply uses the cautious default taper, so it adjusts somewhat less than the range you selected.

### 4. The Lombard Effect — the one that really matters

In 1911 a French doctor named Étienne Lombard noticed something we all do without realizing: **in the presence of noise, people involuntarily raise their voices.** You've done it in a loud bar. Everyone has. And here's why it's dangerous for a volume-control app:

A restaurant at 7 p.m. is half full and pleasant. As it fills, people talk a little louder to be heard over each other. That makes the room louder. So everyone talks louder *still* to clear the new noise floor. The room climbs, conversation by conversation, into a roar — a slow social feedback spiral driven entirely by the Lombard reflex. If a volume app naively measured "the room is getting louder" and dutifully cranked your audio to match, it would ride that spiral straight up and pour it into your ears, all evening, without you noticing until it hurt. **This is exactly the "too loud over a long time" failure mode a safety-conscious design has to prevent.**

ENVO defends against it by asking two independent questions about the noise, neither of which is "how loud is it".

**What shape is it?** Speech babble peaks around 500 Hz and keeps substantial energy through 2 kHz. Traffic, ventilation, engines and tyre noise are dominated by 125 Hz and below. ENVO already has the octave-band levels from §1, so this is just a ratio — a genuine band measurement, with nothing between the bands going unseen.

**Is it modulating?** This is the one that actually separates a person from a fan, and it is temporal rather than spectral. Speech modulates its own level at the syllable rate — three to five times a second, by several decibels. Steady mechanical noise doesn't modulate at all. ENVO bandpasses the level envelope around that rate and measures its depth (`ModulationDetector`). This is the standard modulation-domain approach used in voice activity detection, and it is what a purely spectral test cannot do: music is speech-shaped too, and so is any broadband sound in a room with little low end.

The two are **averaged rather than multiplied**, because they fail in opposite situations and neither should be able to veto the other. Many-talker babble in a packed restaurant averages toward steady noise and loses its modulation, but keeps its speech-shaped spectrum. A broadband hiss in a carpeted room reads spectrally speech-like but does not modulate. Requiring both would miss the first; accepting either would fire on the second.

When the noise floor is dominated by voices, ENVO **holds back**: it refuses to chase people who are simply talking louder. It saves its response for genuine environmental noise — engines, HVAC, machinery, traffic, the wash of a crowd — the stuff that really is masking your audio.

Crucially, this damping is **one-directional and floored**: it can only *remove upward pressure*, never invent downward pressure. It's clamped never to read the room as quieter than the baseline, so a room full of chatter can't trick ENVO into creeping your volume *down* either. And because the total excursion is hard-capped by the RANGE and the safety ceiling (below), there is no long, slow path to a harmful level.

There's a subtlety here that's easy to get wrong, and worth spelling out: **music looks speech-like too**, on both measures — it is midrange-heavy and it modulates. A rock track and a room full of talkers resemble each other. So *when* you sample matters as much as how you measure. ENVO records the speech score alongside every level reading, and when the damper asks "how speech-like is this room?", it looks only at the readings that sit at or near the noise floor — the quiet moments the floor was actually derived from. In those moments your own playback is quiet, so what's left really is the room. Sampling the live microphone value instead would engage the damper during every loud musical passage and quietly suppress ENVO's response for the wrong reason.

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
9. **Feedback-proofed.** The noise floor is measured at the quiet moments of your own program material, so ENVO's own output mostly stays out of it — and where it doesn't, ENVO measures how much of its *own added volume* gets in and subtracts that. The loop gain is far below 1 either way: it converges by construction, not by luck. What it cannot subtract is the music you were already playing when you pressed START — see the limit described in section 3.
10. **Never steers blind.** If the microphone stops delivering audio — an interruption, a media-services reset, a failed engine start — ENVO *holds* its current adjustment and works on reviving the mic, backing off between attempts rather than hammering the audio system. It never acts on a frozen reading.
10a. **Knows when it can't measure, and says so.** A covered microphone (pocket, bag, face-down) and an input at full scale both produce readings that aren't measurements of the room. ENVO detects both, holds its adjustment, and tells you in plain language rather than acting on the number. A covered mic is caught spectrally — covering a microphone is a low-pass, and a room that merely went quiet keeps its shape.
10b. **Doesn't touch the volume when nothing is playing.** ENVO hands the level straight back the moment playback stops, so your next track never starts at a level you didn't choose. It keeps reading the room so it's ready when you press play.
10c. **Admits when it's powerless.** Some routes — AirPlay receivers, HDMI, some external audio devices — keep their own volume and silently discard every write. ENVO detects that and says so, rather than reporting adjustments it never made.
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

**Restaurants & bars.** On a call in a bar that's filling up? ENVO keeps your caller audible without you joining the shouting match — and because it's Lombard-aware, it won't mistake the rising hubbub for a reason to keep climbing. When the group leaves and the room hushes, ENVO eases you back down to where you started.

One caveat, measured rather than guessed: how far *below* your starting point it can go depends on what you're listening through. On headphones, or with speech content, the full downward range is available. Playing continuous music out loud, ENVO returns you to your baseline but cannot go below it — see section 3 for why.

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
- 🗣️ **Lombard-Effect defense** via octave-band spectral shape + syllabic modulation detection
- 🔇 **Knows when it can't measure** — says so plainly if the mic is covered, the input is clipping, nothing is playing, or the route won't let anyone change its volume
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
| `AudioManager` | Mic tap, 125 ms Fast time weighting, the 10 Hz reading queue the engine drains, liveness and clipping detection. Reads levels only — never records. Audio-thread state lives in an object the tap holds strongly, so teardown cannot race a buffer in flight. |
| `OctaveBandAnalyzer` | Six octave bands, 125 Hz – 4 kHz, as pairs of cascaded RBJ bandpasses (12 dB/octave skirts, matching the masking spread they feed). |
| `MaskingWeighting` | Band levels → the control signal, via upward spread of masking + ANSI S3.5 band importance. Also the spectral descriptors for speech detection and obstruction. |
| `ModulationDetector` | Syllabic (2–8 Hz) envelope modulation depth — the temporal half of the speech/steady-noise discriminator. |
| `AWeightingFilter` | IEC 61672 A-weighting as three biquads. No longer the control signal; kept as the diagnostic figure that *is* comparable to a dB(A) meter. |
| `EnvoEngine` | Measures at 10 Hz, decides at 1 Hz. Wires the pure pieces together and owns lifecycle. |
| `AcousticMath` | Power-domain dB arithmetic. Decibels are logarithmic, so combining them requires converting to power first — doing it naively is a whole class of bug. |
| `AmbientTracker` | L90 noise-floor estimation, plus the speech score of the readings that define that floor. No assumption about what's playing. |
| `SelfCouplingEstimator` | Measures how much of the floor is ENVO's own playback, using its own volume steps as a probe, and removes it. Route-derived prior, measurement-refined. |
| `ObstructionDetector` | Spots a covered microphone — a large level drop *accompanied by* a collapse in the high bands, which a room that merely went quiet does not show. |
| `LombardDamper` | Speech-share damping, provably one-directional: it can only ever make ENVO adjust less. |
| `ControlLaw` | The adjustment decision as a pure function: room delta → dB offset, with gain, smoothing, dead band and rate limit. |
| `VolumeTaper` (in `VolumeMath.swift`) | dB ↔ slider-delta conversion through a measured or default taper, with the bounds enforced. |
| `SpikeFilter` | Median/IQR winsorizing transient rejection. Deliberately upward-only — see the type comment for why symmetry would blind the floor estimator. |
| `CalibrationManager` / `CalibrationProfile` / `CalibrationStore` | Runs the pink-noise sweep, derives the taper, validates and persists. Refuses to save an unusable profile, and discards profiles from older schemas rather than reinterpreting them. |
| `VolumeController` | Owns the system volume via `MPVolumeView`, KVO-observes user changes, enforces "user always wins", applies the final travel clamp, and snaps writes to the hardware's step grid with hysteresis. Measures that grid at runtime rather than assuming it, and detects routes where writes silently do nothing. |
| `AudioSessionController` | Sole owner of the `AVAudioSession` category and activation, reference-counted between the engine and calibration. Nothing touches the session at launch. |
| `BackgroundAudioHandler` | Silent looping player for background survival. |
| `NowPlayingController` / `EnvoIntents` | Lock-screen tile and Siri/Shortcuts surface. |

**Testing.** The safety-critical logic lives in pure, deterministic types — `AcousticMath`, `AmbientTracker`, `ControlLaw`, `LombardDamper`, `VolumeTaper`, `SpikeFilter`, `CalibrationProfile`, `MaskingWeighting`, `ModulationDetector`, `SelfCouplingEstimator`, `ObstructionDetector` — plus `AWeightingFilter` and `OctaveBandAnalyzer` — so the guarantees can be verified in isolation. 162 tests cover them, including property tests that sweep the full parameter space for bound violations, an end-to-end simulation that runs the real tracker, spike filter and control law over a changing room at the rates the engine actually uses, a closed-loop simulation with the hardware quantizer in it, and checks of the A-weighting and filterbank responses against their reference tables.

This structure is deliberate: an earlier version proved its safety properties with a hand-written simulation that *re-implemented* the control loop, which meant it could only ever prove things about itself. The tests now drive the shipping code.

---

## Credits

Designed and built by **Totemphonia Studio Berlin** — [totemphonia.com](https://totemphonia.com)

*ENVO reads your environment so your ears don't have to.*

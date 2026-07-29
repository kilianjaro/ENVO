# ENVO — App Store Launch Pack

Everything needed for the App Store Connect listing. Character-limited fields are marked with their Apple maximums and current counts.

---

## App Name (max 30)
```
ENVO
```
> Optional keyword-boosted variant (26 chars): `ENVO: Adaptive Volume`

## Subtitle (max 30 · currently 28)
```
Adaptive volume for any room
```
Alternates (both 28): `Volume that follows the room` · `Ambient-aware volume control`

## Promotional Text (max 170 · currently 169)
*(Editable any time without a new build — good for seasonal/marketing tweaks.)*
```
ENVO listens to your surroundings and adjusts your volume in real time, so music, podcasts and calls stay clear as the world gets louder or quieter. You stay in control.
```

## Keywords (max 100 · currently 93)
*(Comma-separated, no spaces — spaces waste characters. Don't repeat the app name or words already in the subtitle.)*
```
adaptive,ambient,noise,volume,loudness,decibel,podcast,commute,headphones,leveling,auto,sound
```

---

## Description (max 4000 · currently 3967)
> ⚠️ Only ~33 characters of headroom. Re-count before adding anything here.

```
Your volume, minus the noise.

You know the dance. On the train, a tunnel roars and you can't hear your podcast, so you turn it up. The train stops and now it's blasting — so you turn it down. Café, gym, plane, sidewalk: all day, your thumb does a job a machine should be doing.

ENVO is that machine. It listens to the room and gently levels your volume to match — up when the world gets loud, back down when it quiets — so what you're hearing stays in the same comfortable place. You set the volume. ENVO keeps it right.

HOW IT WORKS
Ten times a second, ENVO measures your surroundings through the microphone — not just how loud the room is, but how much of it is actually burying what you're listening to. Then it eases your volume up or down by a small, safe amount. Your chosen level is always the baseline: the instant you touch the volume buttons, that becomes the new normal. You are never fighting the app.

BUILT ON REAL PSYCHOACOUSTICS
• Measures masking, not just loudness. A bus or a plane cabin is mostly deep rumble that a sound meter barely registers — yet it's exactly what makes speech impossible to follow. ENVO splits the room into frequency bands and weighs each by how much it's burying your audio.
• Thinks in decibels, the way your ears perceive loudness — an adjustment feels the same whether you started quiet or loud.
• Defends against the Lombard Effect — the reason a restaurant slowly gets deafening as people raise their voices. ENVO tells voices from machinery by their frequency and by the rhythm of speech itself, then refuses to chase people who are simply talking louder.
• Rejects transients — a door slam is loud but brief, and ENVO shrugs it off.
• Knows its own voice. On a speaker the mic hears your music too — ENVO measures its own contribution and takes it back out, so it can never chase itself.

ROOM CALIBRATION
Every iPhone's volume slider is a curve, not a straight line. A 35-second calibration measures that curve on your device, so the range you choose is the range you actually get. Until then, ENVO plays it safe and adjusts a little less than you asked for.

SAFETY FIRST
ENVO is engineered so it can't run away with your ears:
• A hard ceiling it will never exceed.
• A range cap (±3, ±6, or ±9 dB) you choose.
• A hard limit on how far it can move the slider.
• Gradual, rate-limited changes — ENVO must see several seconds of consistent change before it moves at all.
• Your manual volume change always wins, instantly.

HONEST WHEN IT CAN'T HELP
ENVO says plainly when it can't do its job, instead of reporting numbers it can't stand behind:
• Microphone covered — pocket, bag, or face-down. ENVO can tell a muffled mic from a room that simply went quiet, and holds steady instead of acting on a reading it doesn't trust.
• Nothing playing — it hands the volume back, so your next track never starts at a level you didn't choose.
• An output that keeps its own volume, like an AirPlay receiver. ENVO says so instead of pretending.

WORKS EVERYWHERE YOU DO
Commutes, cafés, open-plan offices, flights, the gym, a bar that's filling up. ENVO runs quietly in the background with any audio app — Music, Spotify, Podcasts, YouTube, audiobooks, calls — and keeps hi-fi stereo on your Bluetooth headphones while sensing the room with the built-in mic. Your lock screen stays your music app's.

HANDS-FREE
Start and stop with Siri, the Action Button, or Shortcuts automations.

PRIVATE BY DESIGN
No audio is ever recorded, stored, or transmitted. Only instantaneous sound levels are measured in memory and discarded. Everything runs on your device — no account, no server, no analytics. Calibration stays local to your iPhone.

CONTROLS
• RESPONSE — reaction speed (SLOW / MED / FAST).
• RANGE — how far it may adjust (±3 / ±6 / ±9 dB).
• DIRECTION — up, down, or both.
• CALIBRATE — full setup (~35 s) or a 5-second refresh.

ENVO reads your environment so your ears don't have to.

From Totemphonia Studio Berlin.
```

---

## What's New (Version 1.0 · max 4000)

```
Welcome to ENVO 1.0.

ENVO listens to the noise around you and automatically levels your volume to match — so your music, podcasts, and calls stay perfectly audible as your environment changes, without you ever reaching for the volume buttons.

• Real-time adaptive volume built on genuine psychoacoustics
• Measures masking rather than loudness, so low-frequency drone — buses, trains, plane cabins — counts for what it actually does to speech
• Lombard-Effect defense so it never chases rising chatter into your ears
• Never chases its own output: on a speaker, ENVO measures its own contribution to what the mic hears and removes it
• Room calibration that measures your device's real volume curve, so the range you choose is the range you get
• Layered safety: a hard ceiling, a range cap, a slider travel limit, and gradual rate-limited changes
• Tells you when it can't measure — covered microphone, nothing playing, or an output that owns its own volume
• Background operation with any audio app, plus Siri & Shortcuts
• Completely private — no audio is recorded, stored, or transmitted

Thanks for trying ENVO. We'd love your feedback.
```

---

## Promotional Text — seasonal alternates
- **Commuter angle (154):** `Tunnels roar, stations fall quiet. ENVO tracks every change and levels your volume in real time, so your podcast stays clear the whole ride. Private, hands-free.`
- **Focus angle (150):** `The café gets loud, then it doesn't. ENVO keeps your music sitting right above the noise all day — automatically, safely, without ever grabbing your volume from you.`

---

## URLs
- **Support URL:** https://totemphonia.com  *(a reachable support/contact page is required — add an ENVO support or contact section)*
- **Marketing URL (optional):** https://totemphonia.com
- **Privacy Policy URL (required):** https://totemphonia.com/privacy  *(must exist and state: no data collected, mic used only for on-device level measurement, nothing recorded/transmitted)*

---

## App Privacy — "Nutrition Label" answers

In App Store Connect ▸ App Privacy, declare:

- **Data collection: NONE.** Answer "No, we do not collect data from this app." ENVO has no analytics, account, or network calls, so no data types are collected.
- **Tracking:** No.
- This matches the bundled `PrivacyInfo.xcprivacy`, which declares no tracking, no collected data types, and a single accessed-API reason (`CA92.1`, UserDefaults, for saving your settings/calibration).

---

## Age Rating
- **4+** — no objectionable content. Answer "None" to all content questions.

---

## Category
- **Primary:** Utilities (recommended) or Music
- **Secondary:** Music (or Health & Fitness, given the hearing-comfort angle)

---

## App Review Notes (IMPORTANT — paste into the "Notes" field)

```
WHAT ENVO DOES
ENVO is an adaptive volume controller. It continuously measures the ambient
noise level around the device via the microphone and automatically adjusts the
system output volume so the user's audio stays audible as their environment
changes. No audio is recorded, stored, or transmitted — only instantaneous
sound-power levels are computed in memory and discarded.

WHY IT USES THE "audio" BACKGROUND MODE (Guideline 2.5.4)
Continuous background microphone monitoring is the CORE, ESSENTIAL function of
the app — not incidental. Users run ENVO while listening to other apps (Music,
Spotify, Podcasts, calls) with the screen locked or the app backgrounded, and
ENVO must keep measuring the room and adjusting volume the entire time. The app
maintains an active audio session for this purpose. The audio session is
configured with .mixWithOthers so ENVO never interrupts or takes over other
apps' playback; it purely observes the environment and nudges the system volume.

HOW TO TEST
1. Launch ENVO and complete the microphone permission prompt.
2. (Optional) Run CALIBRATE — a ~35s pink-noise sweep on the built-in speaker.
3. START PLAYBACK IN ANY AUDIO APP FIRST (e.g. Music). This step is required:
   with nothing playing there is nothing to adapt, so ENVO deliberately hands
   the volume back and displays "NOTHING PLAYING". That is correct behaviour,
   not a failure.
4. Tap START in ENVO. Allow ~10 seconds for it to measure the room before it
   will move anything — it anchors a baseline first, by design.
5. Create ambient noise near the device (play noise from another device, run a
   fan, talk loudly). The volume adjusts upward; when noise stops, it eases back.
   Keep the noise going for at least 15-20 seconds: ENVO requires several
   seconds of consistent change before it acts, so brief bursts are ignored on
   purpose.
6. Press the hardware volume buttons at any time — ENVO immediately yields and
   adopts your level as the new baseline.
7. Leave the bottom edge of the device clear. If the microphone is covered
   (face-down on a desk, in a pocket), ENVO detects it, holds its adjustment and
   displays "MIC COVERED".

SAFETY
Output is hard-capped (never above ~92% system volume), bounded by a user-chosen
±3/6/9 dB range, additionally bounded by an absolute limit on how far the volume
slider may be moved from the user's setting, and rate-limited to 0.75 dB per
second of intent. Note that iOS quantizes the system volume to discrete steps
(each worth roughly 3 dB), so the output cannot literally glide; what the rate
limit guarantees is SPACING — ENVO must accumulate several seconds of consistent
intent before it crosses a step boundary, and a quarter-step of hysteresis on
either side prevents the output flipping back and forth. Steps are therefore
infrequent and never rapid. The user's manual volume changes always override the
app immediately and reset the adjustment to zero. If the microphone stops
delivering audio, is covered, or is clipping, the app holds its current
adjustment rather than acting on a reading it cannot trust.

PRIVACY
No recording, no storage, no network, no accounts, no analytics. All processing
is on-device. See the bundled privacy manifest.

A short demo video is available on request.
```

> Reviewer tip: the silent-audio background-survival pattern is scrutinized under 2.5.4. The notes above pre-empt the concern by making clear the mic monitoring is genuine, continuous, and central — attaching a 20–30 s screen-recording demo materially reduces rejection risk.

### Demo video shot list (~30 s, one continuous take, no cuts)

Record with a second device filming the iPhone (screen recording alone can't show the room getting louder). Have Music playing and a Bluetooth speaker or second phone ready as the noise source.

1. **0–5 s** — ENVO main screen in STANDBY, NOISE readout showing "—". Music already playing in another app. Tap START; badge flips to ACTIVE, readout goes live.
2. **5–14 s** — Bring up loud noise near the iPhone (second device playing café noise / a fan) and **hold it**. Show ADJ stepping up and the Control Center volume slider rising with it. Don't cut early: ENVO needs several seconds of sustained noise before it acts, and that restraint is the feature.
3. **14–20 s** — Kill the noise source. Show ADJ returning toward 0.
4. **20–25 s** — Press a hardware volume button mid-adjustment. Show ENVO instantly adopting the new baseline (VOL updates, ADJ resets) — "the user always wins."
5. **25–32 s** — Lock the phone, keep the noise going, show volume still adapting from the lock screen; unlock, tap STOP, volume returns to baseline, mic indicator disappears.

One shot list line per 2.5.4 concern: step 5 is the background-mode justification, step 4 is user control, step 1's "—" shows the mic truly idles when off.

Two things worth capturing deliberately:
- **ADJ moves in steps, not a glide.** iOS quantizes system volume to roughly 3 dB per step, so ADJ will jump rather than sweep. This is honest and expected — don't reshoot hoping for a smooth ramp, and don't imply one in the captions.
- **The lock screen in step 5 still shows the user's own music**, with their transport controls intact. ENVO deliberately does not claim the Now Playing tile. That is a good half-second to hold on, because it's the clearest possible demonstration that ENVO runs alongside the user's media player rather than taking it over.

---

## Screenshot plan (6.7" and 6.1" required)
Suggested captions over the brutalist black UI:
1. **"Volume that listens to the room."** — main screen, ACTIVE, offset showing +dB.
2. **"Set it once. Forget it's on."** — RESPONSE / RANGE / DIRECTION controls.
3. **"It knows a door slam from a loud room."** — visualizer mid-pulse.
4. **"Calibrate to your space in 35 seconds."** — calibration console.
5. **"Never too loud. Never too quiet."** — readout with NOISE / VOL / ADJ.
6. **"Private by design — nothing is ever recorded."** — info/privacy panel.

---

## Export Compliance
- `ITSAppUsesNonExemptEncryption` is set to `false` in Info.plist → no export-compliance questionnaire required at upload. Confirm this remains accurate (ENVO uses no encryption beyond OS defaults).

---

## Pre-submit checklist
- [ ] App icon 1024² present, no alpha (already in `Media.xcassets`)
- [ ] Privacy Policy URL live and accurate
- [ ] Support URL reachable
- [ ] App Privacy set to "No data collected"
- [ ] Review Notes + demo video attached
- [ ] Screenshots for all required device sizes

### On-device verification (the simulator cannot test any of these)

Volume, microphone, routing and interruptions all behave differently on real hardware. Each item below is a claim this listing makes:

- [ ] **Opening the app changes nothing.** With music playing from another app, launch ENVO and confirm playback level is unaffected until START is pressed. (Turn AUTO-RESUME off first, or it starts on its own.)
- [ ] **Calibration is audible at every step.** All six volume steps should be clearly heard, and the console should report a measurable speaker level for each — not "below room floor".
- [ ] **The measured taper is sane.** The calibration log prints the measured dB-per-slider figure against the assumed default of 60 dB. Expect roughly 45–50 dB. A wildly different number means the assumption needs revisiting.
- [ ] **The range means what it says.** With an SPL meter, confirm a ±6 dB setting produces about ±6 dB after calibration — and no more than that before it.
- [ ] Hardware-button override: ENVO yields instantly and ADJ resets to 0.0.
- [ ] Bluetooth (A2DP) route: stereo preserved, adaptation still works.
- [ ] Interruption recovery: take a call during ACTIVE, and during calibration.
- [ ] Headphone plug/unplug while ACTIVE.
- [ ] Background battery over a ~1 h session.
- [ ] Calibration cancel and sheet-dismiss mid-run both restore the original volume.

#### Measurement integrity — two constants this listing's claims rest on

Both are currently reasoned estimates. Neither can be settled anywhere but on hardware, and everything the description says about measurement sits downstream of them.

- [ ] **Is the input path linear in dB?** Play a source at known 5 dB increments and confirm the NOISE readout tracks 1:1. The audio session runs in `mode: .default`, which leaves iOS input processing — including automatic gain control — switched on. A fixed gain cancels out against the baseline; **AGC does not**, because it is level-dependent and has its own multi-second time constants that would fight the ambient tracker. If the scale turns out compressed, `mode: .measurement` is the fix, at the cost of route-wide output attenuation. This is the single most load-bearing unverified assumption in the app.
- [ ] **Is the displayed SPL figure in the right place?** Compare the NOISE readout against a reference sound level meter. Only `AudioManager.fullScaleSPL` (currently 117.0) needs to move. Note the on-screen number is the masking-weighted control level and is **not** a dB(A) figure — it will not match an SPL app, and is not meant to. The calibration log prints the A-weighted dB(A) value alongside; *that* is the one to compare.

#### New behaviours to confirm

- [ ] **Covered microphone.** Put the phone face-down or in a pocket while ACTIVE: "MIC COVERED" should appear within a few seconds and the adjustment should freeze. Then confirm the opposite — switching off a fan or letting a café empty must NOT trigger it, since a room that merely goes quiet keeps its spectral shape.
- [ ] **Nothing playing.** Pause the music: ENVO should hand the volume back and show "NOTHING PLAYING", then resume adapting when playback restarts.
- [ ] **AirPlay / HDMI.** Route to an AirPlay receiver: "OUTPUT NOT CONTROLLABLE" should appear rather than ENVO reporting adjustments it cannot make.
- [ ] **Volume step size.** The log prints the measured quantum when it differs from the 0.05 default. Confirm what your routes actually use — headphone and Bluetooth routes commonly use 1/16.
- [ ] **Self-coupling on a speaker.** This is the reference setup: iPhone into a room stereo, phone on the counter. Confirm ENVO does not creep upward over a long session with dense music playing.
- [ ] **Lock screen belongs to the music app.** With Spotify or Music playing and ENVO ACTIVE, confirm the lock screen still shows the user's track and that its transport controls still control the music, not ENVO.

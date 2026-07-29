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

## Description (max 4000 · currently 3220)

```
Your volume, minus the noise.

You know the dance. On the train, a tunnel roars and you can't hear your podcast, so you turn it up. The train stops, the roar vanishes, and now it's blasting — so you turn it down. Café, gym, plane, sidewalk: all day, your thumb does a job a machine should be doing.

ENVO is that machine. It listens to the noise around you and gently levels your volume to match — up when the world gets loud, back down when it quiets — so what you're hearing stays in the same comfortable place. You set the volume. ENVO keeps it right.

HOW IT WORKS
Once a second, ENVO takes a loudness snapshot of your surroundings through the microphone. It works out how loud the room truly is, then eases your volume up or down by a small, safe amount. Your chosen level is always the baseline — the instant you touch the volume buttons, that becomes the new normal. You are never fighting the app.

BUILT ON REAL PSYCHOACOUSTICS
• Thinks in decibels, the way your ears actually perceive loudness — so an adjustment feels the same whether you started quiet or loud.
• Defends against the Lombard Effect — the reason a restaurant slowly gets deafening as people raise their voices to be heard. ENVO recognizes when noise is just voices and refuses to chase it into your ears.
• Rejects transients — a door slam or a dropped tray is loud but brief, and ENVO shrugs it off instead of jumping.

ROOM CALIBRATION
Every iPhone's volume slider is a curve, not a straight line — the same step means different amounts of loudness at different points. A 35-second calibration measures that curve on your device, so the range you choose is the range you actually get. Until you calibrate, ENVO plays it safe and adjusts a little less than you asked for.

SAFETY FIRST
ENVO is engineered so it can't run away with your ears:
• A hard ceiling it will never exceed.
• A range cap (±3, ±6, or ±9 dB) you choose.
• A limit on how far it can move the slider, whatever else happens.
• Gradual, rate-limited changes — ENVO must see several seconds of consistent change before it moves at all.
• Your manual volume change always wins, instantly.

WORKS EVERYWHERE YOU DO
Commutes, cafés, open-plan offices, flights, the gym, cooking at home, a bar that's filling up. ENVO runs quietly in the background with any audio app — Music, Spotify, Podcasts, YouTube, audiobooks, and calls — and keeps hi-fi stereo on your Bluetooth headphones while sensing the room with the built-in mic.

HANDS-FREE
Start and stop with Siri, the Action Button, or Shortcuts automations. Turn it on when you leave the house and forget it's there.

PRIVATE BY DESIGN
No audio is ever recorded, stored, or transmitted. Only instantaneous sound levels are measured in memory and immediately discarded. Everything runs on your device — no account, no server, no analytics, no data collection. Calibration stays local to your iPhone.

CONTROLS
• RESPONSE — how fast ENVO reacts (SLOW / MED / FAST).
• RANGE — how far it's allowed to adjust (±3 / ±6 / ±9 dB).
• DIRECTION — allow volume up, down, or both.
• CALIBRATE — full room setup (~35 s), or a 5-second quick refresh.

ENVO reads your environment so your ears don't have to.

From Totemphonia Studio Berlin.
```

---

## What's New (Version 1.0 · max 4000)

```
Welcome to ENVO 1.0.

ENVO listens to the noise around you and automatically levels your volume to match — so your music, podcasts, and calls stay perfectly audible as your environment changes, without you ever reaching for the volume buttons.

• Real-time adaptive volume built on genuine psychoacoustics
• Lombard-Effect defense so it never chases rising chatter into your ears
• Room calibration that measures your device's real volume curve, so the range you choose is the range you get
• Layered safety: a hard ceiling, a range cap, a slider travel limit, and gradual rate-limited changes
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
3. Start playback in any audio app (e.g. Music).
4. Tap START in ENVO.
5. Create ambient noise near the device (play noise from another device, run a
   fan, talk loudly). The volume adjusts upward; when noise stops, it eases back.
6. Press the hardware volume buttons at any time — ENVO immediately yields and
   adopts your level as the new baseline.

SAFETY
Output is hard-capped (never above ~92% system volume), bounded by a user-chosen
±3/6/9 dB range, additionally bounded by an absolute limit on how far the volume
slider may be moved from the user's setting, and rate-limited to 0.75 dB per
second so changes are always a smooth glide. The user's manual volume changes
always override the app immediately and reset the adjustment to zero. If the
microphone stops delivering audio for any reason, the app holds its current
adjustment rather than acting on a stale reading.

PRIVACY
No recording, no storage, no network, no accounts, no analytics. All processing
is on-device. See the bundled privacy manifest.

A short demo video is available on request.
```

> Reviewer tip: the silent-audio background-survival pattern is scrutinized under 2.5.4. The notes above pre-empt the concern by making clear the mic monitoring is genuine, continuous, and central — attaching a 20–30 s screen-recording demo materially reduces rejection risk.

### Demo video shot list (~30 s, one continuous take, no cuts)

Record with a second device filming the iPhone (screen recording alone can't show the room getting louder). Have Music playing and a Bluetooth speaker or second phone ready as the noise source.

1. **0–5 s** — ENVO main screen in STANDBY, NOISE readout showing "—". Tap START; badge flips to ACTIVE, readout goes live.
2. **5–12 s** — Music audibly playing. Bring up loud noise near the iPhone (second device playing café noise / a fan). Show ADJ climbing (+) and the Control Center volume slider rising with it.
3. **12–18 s** — Kill the noise source. Show ADJ easing back toward 0 — no jump-cut, the smoothing is the point.
4. **18–24 s** — Press a hardware volume button mid-adjustment. Show ENVO instantly adopting the new baseline (VOL updates, ADJ resets) — "the user always wins."
5. **24–30 s** — Lock the phone, keep the noise going, show volume still adapting from the lock screen; unlock, tap STOP, volume returns to baseline, mic indicator disappears.

One shot list line per 2.5.4 concern: step 5 is the background-mode justification, step 4 is user control, step 1's "—" shows the mic truly idles when off.

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

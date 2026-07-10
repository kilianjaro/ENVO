# ENVOTests

Unit tests for the pure-logic pieces of ENVO. These cover `VolumeMath`,
`CalibrationProfile`, `SpikeFilter`, `SettingsStore`, and the font-scaling
helper — everything that doesn't need a live mic, volume controller, or
audio session.

## Adding the test target in Xcode (one-time)

The Xcode project currently has no test target. To enable these tests:

1. Open `ENVO.xcodeproj`.
2. File ▸ New ▸ Target… ▸ **Unit Testing Bundle**.
3. Name it `ENVOTests`, target language Swift, Project ▸ ENVO,
   Target to be Tested ▸ ENVO.
4. Xcode will create an `ENVOTests` folder next to `ENVO/`. **Delete
   the generated folder** (keep the target).
5. In the target's *Build Phases ▸ Compile Sources*, add every `.swift`
   file in this directory.
6. ⌘U to run.

Because the source files are picked up by the existing
`fileSystemSynchronizedGroups` entry, the app target should not include
this `ENVOTests` directory — the unit-test target is the only consumer.

## What to add next

These tests cover the pure-math layer. Worth adding once you have time:

- `VolumeController.handleVolumeChange` classification — requires a fake
  `MPVolumeView` or shim; do-able with protocol extraction.
- `EnvoEngine.tick` flow — requires injecting a fake clock and fake
  audio/volume managers. Big payoff for refactor work.
- Audio interruption resume path — needs a notification fake.

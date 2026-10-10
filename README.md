<p align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/icon.png" width="140" alt="Grow a Song icon">
</p>

<h1 align="center">Grow a Song</h1>

<p align="center">
  Your time outside becomes music.<br>
  Every minute outdoors adds a layer to today's song, composed on your iPhone by an open-weight model.
</p>

<p align="center">
  <a href="https://youtube.com/shorts/LCFFlzZQWFE">Demo video</a> ·
  <a href="https://res.cloudinary.com/dz05pa4ud/video/upload/v1791619582/2026-10-09_Ephemeral_Echoes_fvm7ke.m4a">Listen to a real run</a> ·
  <a href="https://dev.to/challenges/hacktoberfest-week1-2026-10-05">DEV challenge</a>
</p>

---

## What it does

Start a walk or a run. Your song begins as a single low drone. As you spend time outside,
new layers fade in:

| Share of your daily target | Layer |
|---|---|
| 0 % | Drone |
| 8 % | Pads |
| 25 % | Bass |
| 42 % | Drums |
| 67 % | Melody |
| 100 % | A 10 second field recording of where you are |

Stay inside and your song stays thin. The only way to hear all of it is to go outside.

Before each outing, **Gemma 3 1B runs on the phone** and composes the song: key, scale,
tempo, chord progression, instruments, a title and a one-line liner note, based on the
time of day, the sun's height, what you're about to do and how much you've been outside
this week. After a session it writes a short field note.

No account, no server, no API key. After a one-time model download it works in airplane mode.

## A real run

On Friday, 9 October 2026, I ran with the app in my pocket:

- 35.1 minutes counted as outside, 3.4 km
- Gemma composed **Ephemeral Echoes**: D dorian, 160 bpm, chords 1 7 5 3, warm pads,
  pulse bass, driving drums, kalimba
- All 6 layers playing by the end (20 minute target)

[Full song](https://res.cloudinary.com/dz05pa4ud/video/upload/v1791619582/2026-10-09_Ephemeral_Echoes_fvm7ke.m4a) ·
[How it grew, layer by layer](https://res.cloudinary.com/dz05pa4ud/video/upload/v1791619583/2026-10-09_Ephemeral_Echoes_growth_ix2hzm.m4a)

## How it works

```
 Sensors (on device)                 Composer (on device)            Sound (on device)
 ───────────────────                 ────────────────────            ─────────────────
 GPS + CoreMotion + sun position ─┐
                                  ├─► outside minutes ─► layers ─┐
 Apple Watch daylight (optional) ─┘                              │
                                                                 ▼
 time of day, activity, week ─────► Gemma 3 1B (MLX) ─► SongSpec JSON ─► sequencer ─► synth ─► AirPods
                                     schema-guided                       16 bars      Swift
```

**Gemma composes, Swift plays.** A 1B model is good at taste and bad at bookkeeping, so it
makes about ten musical decisions and returns them as JSON. Output is constrained token by
token to a JSON Schema with MLX's guided generation (XGrammar), with a free-text parse as a
fallback. A deterministic sequencer turns the spec into 16 bars of notes, and a small synth
written from scratch plays them: detuned saw pads, an FM kalimba, a sine kick, a Freeverb-style
reverb. The same spec always produces the same song.

**Knowing you're outside without a light sensor.** iPhone apps can't read the ambient light
sensor, so the phone infers it. A minute counts when the sun is above civil twilight
(computed locally with the NOAA solar equations) and CoreMotion says you're on foot, or the
GPS fix is accurate to 20 m while you're away from home. Driving never counts. With an Apple
Watch, its measured time in daylight from HealthKit takes over.

**Built to survive a real run.** Gemma only uses the GPU while the app is on screen (iOS
denies GPU work to background apps, and MLX would otherwise crash), with every MLX call
wrapped so failures fall back to a built-in song. Progress saves every 30 seconds. A newly
composed song swaps in at the next phrase boundary instead of cutting notes off. Unplugging
AirPods pauses playback instead of playing from your pocket.

### Composer eval (M2 Pro, `make eval`)

| | Before | After |
|---|---|---|
| Schema-guided success | 0 / 6 | 6 / 6 |
| Average compose time | 9.5 s | 4.4 s |

The first version failed because greedy decoding filled the token budget with JSON
whitespace. Whitespace and closing-token biases fixed it. Shuffling the order of options in
the prompt fixed a second problem: the 1B model kept picking whichever option it read first.

## Project layout

```
Packages/GrowCore     Pure Swift engine, testable on a Mac: solar math, outside classifier,
                      layer schedule, SongSpec contract, sequencer, realtime synth, WAV I/O,
                      and the growsong-render CLI
Shared/Composer       GemmaComposer: model loading, schema-guided decoding, fallbacks
App/                  iOS app: SwiftUI, AVAudioEngine, CoreLocation, CoreMotion, HealthKit
Watch/                Optional watchOS companion: rings, a haptic tap per new layer, workout session
Tools/ComposerEval    macOS CLI that runs the real composer for evals
scripts/              App icon, demo video, narration and thumbnail tooling
docs/                 Plan, run checklist, demo script, DEV post draft
```

## Build and run

Requirements:

- Xcode 26 or later
- An iPhone on iOS 17 or later. MLX needs a real GPU; the simulator runs the UI with
  built-in songs only.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- The Metal toolchain: `xcodebuild -downloadComponent MetalToolchain`

Set your own `DEVELOPMENT_TEAM` in `project.yml`, then:

| Command | What it does |
|---|---|
| `make test` | GrowCore unit tests (37) |
| `make render` | Renders each layer stage to `out/*.wav` with loudness numbers |
| `make eval N=6` | Runs Gemma on the Mac: JSON validity, fallback rate, latency |
| `make sim` | Builds the iOS app for the simulator |
| `make device` | Builds, installs and launches on the first connected iPhone |

The first launch on the phone downloads the model (about 0.8 GB) from Hugging Face. Keep the
app open on Wi-Fi until the footer says "Gemma ready".

To rebuild a day's song on a Mac from data copied off the phone:

```
Packages/GrowCore/.build/release/growsong-render export days.json 2026-10-09 20 clip.wav song.wav
```

## Privacy

Location, motion, health data and sound clips never leave the phone. The only network
request the app makes is the one-time model download.

## Built with

- [Gemma 3 1B](https://ai.google.dev/gemma) (QAT, 4-bit), via
  [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm)
- [swift-huggingface](https://github.com/huggingface/swift-huggingface) and
  [swift-transformers](https://github.com/huggingface/swift-transformers)
- [Claude Code](https://claude.com/claude-code), which wrote the code in one long session:
  plan, code, test, review, fix
- [ElevenLabs](https://elevenlabs.io) for the demo video's narration only

## License

Code is MIT, see [LICENSE](LICENSE). Gemma weights are downloaded at runtime and are subject
to the [Gemma Terms of Use](https://ai.google.dev/gemma/terms).

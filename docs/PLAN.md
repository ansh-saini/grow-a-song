# Grow a Song: build plan

Your time outside becomes music. Every minute outdoors in daylight adds a layer to
today's track. A local Gemma model on the phone composes the song. Nothing leaves the
device.

Entry for DEV Hacktoberfest 2026 Week 1 ("Touch Grass"), due 2026-10-11.

## Hardware

- iPhone 13 Pro (A15, 6 GB, iOS 26.6): the whole app runs here.
- Apple Watch Series 8 (watchOS 26.5): optional bonus. Remote control, unlock haptics,
  workout session, measured daylight via HealthKit.

## Architecture

```
Packages/GrowCore      pure Swift, no Apple frameworks beyond Foundation/os
  Solar                NOAA solar elevation, daylight check (civil twilight)
  OutsideClassifier    is this minute "outside"? (daylight + on foot/open sky)
  OutsideTracker       accumulates outside seconds from samples
  LayerSchedule        minutes -> unlocked layers (drone, pad, bass, drums, melody, field)
  SongSpec             Gemma's output contract, JSON schema, lenient parse, fallback
  PromptBuilder        context -> prompt
  Theory / Sequencer   spec + seed -> 16-bar beat-based note pattern
  SongRenderer         realtime-safe synth + reverb, layer gating, tempo glide
  FieldClip            mic clip -> loopable texture
  CadenceTempo         running cadence -> musical BPM
  DayRecord            per-day persisted data
  WAVWriter            offline renders for the harness

App (iOS)              SwiftUI shell
  Outside/             LiveSession (CoreLocation + CoreMotion), MotionHistory (7-day backfill),
                       HealthDaylight (watch-measured timeInDaylight)
  Audio/               AVAudioEngine + AVAudioSourceNode around SongRenderer, field recorder, export
  Composer/            GemmaComposer: MLX Swift, Gemma 3 1B QAT 4-bit, JSON-schema guided generation
  Link/                WatchConnectivity
  UI/                  Today (growing rings), Week, Settings

Watch (watchOS)        progress ring, start/stop/capture, layer-unlock haptics, HKWorkoutSession

Tools/ComposerEval     macOS CLI: runs real Gemma on the Mac against sample contexts,
                       reports JSON validity and latency
```

## Harness

| Command | What it does |
|---|---|
| `make test` | GrowCore unit tests (fast, macOS) |
| `make render` | Renders each layer stage to `out/*.wav` and prints loudness metrics |
| `make eval` | Real Gemma on the Mac: spec validity, fallback rate, latency |
| `make sim` | Builds the iOS app for the simulator |
| `make device` | Builds, installs and launches on the paired iPhone |
| `make check` | test + render + sim |

Loop: plan, code, `make check`, review agent, fix, `make device`.

## Phone-only outside detection

A minute counts when the sun is above civil twilight (-6 deg) and one of:
on foot (walking/running/cycling per CoreMotion), or GPS accuracy <= 20 m while away
from home. Automotive never counts. A "test mode" toggle counts every minute, for
indoor testing.

## Daily target and layers

Target is configurable (default 30 min). Layers unlock at 0, 8, 25, 42, 67, 100 % of it.

## Cut list (in order)

Watch workout session, stride-synced tempo, week export, field note.

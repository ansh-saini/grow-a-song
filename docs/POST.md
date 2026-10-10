---
title: Grow a Song: my run wrote its own soundtrack, with Gemma running on my phone
published: false
tags: devchallenge, hf26challenge, ai, ios
---

*This is a submission for the [Hacktoberfest Open-Source AI Challenge, Week 1: Touch Grass](https://dev.to/challenges/hacktoberfest-week1-2026-10-05).*

## What I Built

On Friday morning I went for a 35 minute run. When I started, my song was a single low drone. By the time I got back it had pads, a bass line, drums, a kalimba melody, and ten seconds of the actual street I ran down mixed in underneath.

**Grow a Song** turns time outside into music. Every minute you spend outdoors in daylight adds a layer to today's track:

| Outside time (20 min target) | Layer |
|---|---|
| 0 min | drone |
| 2 min | pads |
| 5 min | bass |
| 8 min | drums |
| 13 min | melody |
| 20 min | a field recording of where you are |

Stay inside all day and your song stays thin. Get out and it fills in. You can't skip ahead and you can't buy layers. The only way to hear the whole song is to go outside.

The composer is **Gemma 3 1B, running on my iPhone 13 Pro**. Before each walk or run it looks at the time of day, how high the sun is, what you're about to do, and how much you've been outside this week, then picks the key, scale, tempo, chord progression, instruments, a title and a one-line liner note. My run got this:

> **Ephemeral Echoes**. D dorian, 160 bpm, chords 1 7 5 3, warm pads, pulse bass, driving drums, kalimba.
> *"The world stretches out beneath you, a slow, expectant invitation."*

No account, no server, no API key. After a one-time model download it works in airplane mode.

## Demo

{% youtube LCFFlzZQWFE %}

Here is the song from my run, exactly as the app rendered it, plus a version that replays the run with the layers arriving one at a time:

- [Ephemeral Echoes (full song)](https://res.cloudinary.com/dz05pa4ud/video/upload/v1791619582/2026-10-09_Ephemeral_Echoes_fvm7ke.m4a)
- [Ephemeral Echoes (how it grew, layer by layer)](https://res.cloudinary.com/dz05pa4ud/video/upload/v1791619583/2026-10-09_Ephemeral_Echoes_growth_ix2hzm.m4a)

The numbers from that morning, pulled off the phone:

- 35.1 minutes counted as outside, 3.4 km
- all 6 layers playing by the end (my target was 20 minutes)
- a 10 second clip recorded at 7:40 AM, now the top layer of the song
- Gemma's field note afterwards: *"You ran 3.2 km. 'Ephemeral Echoes' is now a part of the recording."* (Accurate in spirit. The distance is off by about 200 m, which is what you get from a 1B model writing journal entries.)

## Code

{% embed https://github.com/ansh-saini/grow-a-song %}

Swift, SwiftUI, AVAudioEngine, CoreLocation, CoreMotion, HealthKit and [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm). The music engine is a plain Swift package with 37 tests, so most of it runs and tests on a Mac without a phone.

## How I Built It

### Gemma composes, Swift plays

I didn't want a 1B model generating audio or MIDI note by note. Small models are good at taste and bad at bookkeeping. So Gemma makes about ten musical decisions and returns them as JSON:

```json
{"title": "Ephemeral Echoes", "key": "D", "scale": "dorian", "bpm": 160,
 "progression": [1, 7, 5, 3], "pad": "warm", "bass": "pulse",
 "drums": "driving", "melody": "kalimba", "energy": 1.0,
 "liner_note": "The world stretches out beneath you, a slow, expectant invitation."}
```

A deterministic sequencer turns that into 16 bars of notes (melody in an A A' B A shape so it repeats enough to stick), and a small synth written from scratch plays it: detuned saw pads, an FM kalimba, a kick that's just a sine wave sweeping down from 155 Hz, and a reverb. The same spec always produces the same song, which turned out to matter later.

### Getting reliable JSON out of a 1B model

My first eval on the Mac looked fine on the surface: 6 out of 6 songs were playable. Underneath, the schema-constrained decoding (MLX's `MLXGuidedGeneration`, built on XGrammar) was failing every single time, and a fallback parser was rescuing it.

Logging the partial output showed why. Gemma was emitting newline after newline. JSON allows unlimited whitespace, greedy decoding found that whitespace was always a legal next token, and it filled all 360 tokens with it. Adding the library's whitespace and closing-token biases fixed it:

| | Before | After |
|---|---|---|
| Schema-guided success | 0 / 6 | 6 / 6 |
| Average compose time (M2 Pro) | 9.5 s | 4.4 s |

The second problem was taste. Gemma picked D major pentatonic, chords 1 5 6 4, 60 bpm almost every time, including for a run. A 1B model leans hard on whichever option it reads first. So the prompt now shuffles the order of every option list, seeded by the current minute, and a small guard folds tempos into a range that fits the activity (a "75 bpm" run becomes 150). After that the same eval produced three keys, four scales and five different progressions in six songs.

### Knowing you're outside without a light sensor

An Apple Watch measures time in daylight with its ambient light sensor, and the app reads that from HealthKit when it's there. But I wanted the app to work for anyone with just a phone, and iPhone apps can't read the phone's light sensor.

So the phone infers it. A minute counts when:

- the sun is above civil twilight (-6 degrees), computed locally from time and location with the NOAA solar equations, and
- CoreMotion says you're walking, running or cycling, or the GPS fix is accurate to 20 m (usually means open sky) and you're away from home.

Driving never counts. On first launch, CoreMotion's 7-day activity history gives you a week of estimated songs straight away. With a watch, the measured number takes over.

### The bug that would have ended my run

I had a second AI agent review the code before the run. It found a real crash. iOS doesn't let background apps use the GPU. If I tapped Start and locked my phone while Gemma was still composing, MLX would hit that error and call `fatalError`, killing the app, the music and the minute counter all at once, a few seconds into the run.

The fix has three parts. Gemma only runs while the app is on screen, and a request made in the background waits until you open the app again. The screen stays awake for the few seconds composing takes. And every MLX call is wrapped in `withError` so a GPU failure becomes a Swift error and falls back to a built-in song instead of a crash. The music starts immediately with the drone either way, and Gemma's song takes over at the next 16-bar phrase boundary so nothing cuts off mid-note.

The same review caught that run progress was only saved when you tapped End, so it now saves every half minute.

### Getting the song off the phone

After the run I wanted the song on my laptop, but I'd never exported it. Because the renderer is deterministic, I copied the day's record and the field clip off the phone over a cable and rendered the identical song on the Mac with the same engine. That's the audio linked above.

### Built with an AI agent, tested by running

I built this in one long session with Claude Code: plan, code, test, review, fix. It set up a small harness (`make test`, `make render`, `make eval`, `make device`) so every change got checked against unit tests, rendered audio levels, and real Gemma output before it reached my phone. Then the real test was mine: put my shoes on and press Start.

## Why Does Open Innovation Matter?

Grow a Song needs your location, your movement, sometimes your health data, and a microphone. That's a lot to hand to a server so it can pick a chord progression.

With an open-weight model running locally, none of it leaves the phone:

- **Private by design.** GPS, motion, daylight minutes and your street recordings stay on the device. There's no backend to leak.
- **Works where runs happen.** Trails and parks often have no signal. After a 0.8 GB download, everything works offline.
- **Costs nothing to run.** No per-request bill means I can let Gemma compose before every single walk.
- **Swappable.** The model is one line of config. When a bigger Gemma fits comfortably on a phone, I can upgrade without changing anything else.

## My Agent Session

I built this with Claude Code in one long session. Here's the transcript, from the first idea to the demo video, with secrets and private paths removed:

{% agent_session 689 %}

## Prize Categories

- **Best Use of Gemma**: Gemma 3 1B (QAT, 4-bit) runs fully on device through MLX Swift LM and composes every song with schema-guided JSON output.
- **Best Use of ElevenLabs**: narration for the demo video. The app itself makes no network calls.

---

*Built with Claude Code. I directed the project, tested it on my own run, and reviewed and edited this post.*

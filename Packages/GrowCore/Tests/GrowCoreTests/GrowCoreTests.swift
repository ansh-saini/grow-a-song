import Foundation
import Testing
@testable import GrowCore

private func utc(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    return f.date(from: s)!
}

// Delhi
private let lat = 28.61, lon = 77.21

@Suite struct SolarTests {
    @Test func noonIsHighAndMidnightIsDark() {
        // 2026-10-09 12:00 IST = 06:30 UTC
        let noon = Solar.elevation(at: utc("2026-10-09T06:30:00Z"), latitude: lat, longitude: lon)
        #expect(noon > 50 && noon < 62)
        let midnight = Solar.elevation(at: utc("2026-10-08T18:30:00Z"), latitude: lat, longitude: lon)
        #expect(midnight < -30)
    }

    @Test func londonSummerSolsticeMatchesNOAA() {
        // NOAA calculator: ~61.9 deg at 12:00 UTC on 2024-06-21 in London.
        let e = Solar.elevation(at: utc("2024-06-21T12:00:00Z"), latitude: 51.5074, longitude: -0.1278)
        #expect(abs(e - 61.9) < 0.6)
    }

    @Test func dawnCrossesCivilTwilight() {
        // Delhi sunrise ~06:17 IST on Oct 9 -> civil dawn ~05:53 IST (00:23 UTC).
        #expect(!Solar.isLight(at: utc("2026-10-09T00:00:00Z"), latitude: lat, longitude: lon))
        #expect(Solar.isLight(at: utc("2026-10-09T00:45:00Z"), latitude: lat, longitude: lon))
    }
}

@Suite struct OutsideTests {
    let noon = utc("2026-10-09T06:30:00Z")
    let night = utc("2026-10-08T18:30:00Z")

    @Test func walkingInDaylightCounts() {
        let c = OutsideClassifier()
        #expect(c.isOutside(OutsideSample(date: noon, latitude: lat, longitude: lon, horizontalAccuracy: 50, motion: .walking)))
    }

    @Test func nightNeverCounts() {
        let c = OutsideClassifier()
        #expect(!c.isOutside(OutsideSample(date: night, latitude: lat, longitude: lon, horizontalAccuracy: 5, motion: .running)))
    }

    @Test func drivingNeverCounts() {
        let c = OutsideClassifier()
        #expect(!c.isOutside(OutsideSample(date: noon, latitude: lat, longitude: lon, horizontalAccuracy: 5, motion: .automotive)))
    }

    @Test func stationaryNeedsOpenSkyAndAwayFromHome() {
        let c = OutsideClassifier()
        #expect(c.isOutside(OutsideSample(date: noon, latitude: lat, longitude: lon, horizontalAccuracy: 8, motion: .stationary, distanceFromHome: 500)))
        #expect(!c.isOutside(OutsideSample(date: noon, latitude: lat, longitude: lon, horizontalAccuracy: 8, motion: .stationary, distanceFromHome: 20)))
        #expect(!c.isOutside(OutsideSample(date: noon, latitude: lat, longitude: lon, horizontalAccuracy: 65, motion: .stationary, distanceFromHome: 500)))
    }

    @Test func testModeCountsEverything() {
        let c = OutsideClassifier(testMode: true)
        #expect(c.isOutside(OutsideSample(date: night, motion: .automotive)))
    }

    @Test func trackerCreditsGapsAndCaps() {
        var t = OutsideTracker()
        let s = Date()
        t.ingest(s, outside: true)
        t.ingest(s.addingTimeInterval(5), outside: true)
        t.ingest(s.addingTimeInterval(10), outside: false)
        t.ingest(s.addingTimeInterval(15), outside: true)
        t.ingest(s.addingTimeInterval(615), outside: true)  // 10 min gap, capped at 60 s
        #expect(abs(t.seconds - 70) < 0.001)
    }

    @Test func motionHistoryOnlyCountsDaylightOnFoot() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let walkNoon = MotionHistoryEstimator.Interval(start: noon, end: noon.addingTimeInterval(1200), motion: .walking)
        let driveNoon = MotionHistoryEstimator.Interval(start: noon, end: noon.addingTimeInterval(1200), motion: .automotive)
        let walkNight = MotionHistoryEstimator.Interval(start: night, end: night.addingTimeInterval(1200), motion: .walking)
        let m = MotionHistoryEstimator.minutesByDay([walkNoon, driveNoon, walkNight], latitude: lat, longitude: lon, calendar: cal)
        #expect(abs((m["2026-10-09"] ?? 0) - 20) < 0.01)
        #expect(m["2026-10-08"] == nil)
    }
}

@Suite struct LayerTests {
    @Test func unlockOrder() {
        let s = LayerSchedule(targetMinutes: 30)
        #expect(s.unlocked(minutes: 0) == [.drone])
        #expect(s.unlocked(minutes: 2.4) == [.drone, .pad])
        #expect(s.highest(minutes: 13) == .drums)
        #expect(s.unlocked(minutes: 30).count == 6)
        let n = s.next(minutes: 10)
        #expect(n?.layer == .drums)
        #expect(abs((n?.remaining ?? 0) - 2.6) < 0.001)
        #expect(s.next(minutes: 31) == nil)
    }

    @Test func cadenceFolds() {
        #expect(CadenceTempo.bpm(stepsPerMinute: 168) == 168)
        #expect(CadenceTempo.bpm(stepsPerMinute: 180) == 90)
        #expect(CadenceTempo.bpm(stepsPerMinute: 70) == 140)
        #expect(CadenceTempo.bpm(stepsPerMinute: 10) == nil)
    }
}

@Suite struct SpecTests {
    @Test func parsesFencedModelOutput() {
        let text = """
        Here is your song:
        ```json
        {"title": "Dew on the Path", "key": "Eb", "scale": "lydian", "bpm": 150, "progression": [1, 2, 4, 1],
         "pad": "glass", "bass": "pluck", "drums": "driving", "melody": "kalimba", "energy": 0.8,
         "liner_note": "You run while the city is still {asleep}."}
        ```
        """
        let s = SongSpec.parse(text)
        #expect(s?.title == "Dew on the Path")
        #expect(s?.key == "D#")
        #expect(s?.scale == .lydian)
        #expect(s?.drums == .driving)
        #expect(s?.linerNote.contains("{asleep}") == true)
    }

    @Test func clampsAndDefaultsBadValues() {
        let s = SongSpec.parse(#"{"title":"","key":"H","scale":"blues","bpm":400,"progression":[0,9],"energy":7}"#)!
        #expect(s.title == SongSpec.default.title)
        #expect(s.key == SongSpec.default.key)
        #expect(s.scale == SongSpec.default.scale)
        #expect(s.bpm == 160)
        #expect(s.progression == SongSpec.default.progression)
        #expect(s.energy == 1)
    }

    @Test func acceptsFloatBpmAndMinorKeySuffix() {
        let s = SongSpec.parse(#"{"key":"Am","bpm":92.6}"#)!
        #expect(s.key == "A")
        #expect(s.bpm == 92)
    }

    @Test func garbageReturnsNil() {
        #expect(SongSpec.parse("no json here") == nil)
        #expect(SongSpec.parse("{ broken") == nil)
    }

    @Test func schemaIsValidJSON() throws {
        let obj = try JSONSerialization.jsonObject(with: Data(SongSpec.jsonSchema.utf8)) as? [String: Any]
        let props = obj?["properties"] as? [String: Any]
        #expect(props?.count == 11)
    }

    @Test func roundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(SongSpec.default)
        let back = try JSONDecoder().decode(SongSpec.self, from: data)
        #expect(back == SongSpec.default)
    }

    @Test func fallbackIsDeterministic() {
        #expect(SongSpec.fallback(seed: 42) == SongSpec.fallback(seed: 42))
        #expect(SongSpec.fallback(seed: 1).sanitized() == SongSpec.fallback(seed: 1))
    }

    @Test func promptMentionsContext() {
        let ctx = ComposerContext(
            date: Date(), activity: "run", minutesToday: 12, targetMinutes: 30,
            recentDays: [5, 40, 18], sunElevation: 4, stepsPerMinute: 166)
        let p = PromptBuilder.composePrompt(ctx)
        #expect(p.contains("starting a run"))
        #expect(p.contains("12 of 30"))
        #expect(p.contains("5, 40, 18"))
        #expect(p.contains("166 beats"))
        #expect(p.contains("sun low"))
    }
}

@Suite struct MusicTests {
    @Test func triadsStayInScale() {
        for scale in ScaleKind.allCases {
            let parent = Set(Theory.parent(scale))
            for d in 1...7 {
                for n in Theory.triad(degree: d, scale: scale) { #expect(parent.contains(n % 12)) }
            }
        }
    }

    @Test func patternIsDeterministicSortedAndCoversAllVoices() {
        for seed in UInt64(0)..<20 {
            let spec = SongSpec.fallback(seed: seed)
            let p1 = Sequencer.pattern(for: spec)
            let p2 = Sequencer.pattern(for: spec)
            #expect(p1.events == p2.events)
            #expect(zip(p1.events, p1.events.dropFirst()).allSatisfy { $0.beat <= $1.beat })
            #expect(p1.events.allSatisfy { $0.beat >= 0 && $0.beat < p1.lengthBeats })
            let kinds = Set(p1.events.map(\.voice))
            #expect(kinds == Set(VoiceKind.allCases))
        }
    }

    @Test func melodyStaysInScale() {
        for seed in UInt64(0)..<20 {
            let spec = SongSpec.fallback(seed: seed)
            let set = Set(Theory.melodySet(spec.scale))
            for e in Sequencer.pattern(for: spec).events where e.voice == .melody {
                #expect(set.contains(((e.midi - spec.rootSemitone) % 12 + 12) % 12))
            }
        }
    }
}

@Suite struct RendererTests {
    func rms(_ x: [Float]) -> Float {
        (x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))).squareRoot()
    }

    @Test func moreLayersAreLouderAndNeverClip() {
        var last: Float = 0
        for layer in [Layer.drone, .bass, .drums, .melody] {
            let r = SongRenderer(spec: .default, sampleRate: 22050)
            r.setUnlocked(Set(Layer.allCases.filter { $0 <= layer }), immediate: true)
            let (l, rr) = r.renderOffline(seconds: 8)
            let level = rms(l)
            #expect(level > last, "layer \(layer) should add energy")
            last = level
            #expect(l.allSatisfy { $0.isFinite && abs($0) <= 1 })
            #expect(rr.allSatisfy { $0.isFinite && abs($0) <= 1 })
        }
    }

    @Test func allStylesRenderSound() {
        for seed in UInt64(0)..<12 {
            let r = SongRenderer(spec: SongSpec.fallback(seed: seed), sampleRate: 22050)
            r.setUnlocked(Set(Layer.allCases), immediate: true)
            let (l, _) = r.renderOffline(seconds: 4)
            #expect(rms(l) > 0.02)
            #expect(l.allSatisfy { $0.isFinite })
        }
    }

    @Test func layersFadeInRatherThanJump() {
        let r = SongRenderer(spec: .default, sampleRate: 22050)
        r.setUnlocked([.drone], immediate: true)
        _ = r.renderOffline(seconds: 4)
        r.setUnlocked([.drone, .pad, .bass, .drums, .melody])
        let (l, _) = r.renderOffline(seconds: 8)
        let early = rms(Array(l[0..<11025]))
        let late = rms(Array(l[(l.count - 22050)...]))
        #expect(late > early * 1.5)
    }

    @Test func songSwapAndTempoChangeKeepPlaying() {
        let r = SongRenderer(spec: .default, sampleRate: 22050)
        r.setUnlocked(Set(Layer.allCases), immediate: true)
        _ = r.renderOffline(seconds: 3)
        r.setSong(SongSpec.fallback(seed: 9))
        r.setTempo(165)
        let (l, _) = r.renderOffline(seconds: 4)
        #expect(rms(l) > 0.02)
    }

    @Test func fieldClipPrepares() {
        let input = (0..<48000).map { Float(sin(Double($0) * 0.05)) * 0.1 + 0.3 }
        let out = FieldClip.prepare(input, inputRate: 48000, outputRate: 24000)
        #expect(abs(out.count - 24000) <= 1)
        #expect(out.first == 0)
        #expect((out.map(abs).max() ?? 0) <= 0.71)
        #expect(FieldClip.prepare([], inputRate: 48000, outputRate: 48000).isEmpty)
    }

    @Test func wavHeaderIsCorrect() {
        let d = WAVWriter.data(left: [0, 0.5], right: [0, -0.5], sampleRate: 44100)
        #expect(d.count == 44 + 8)
        #expect(String(decoding: d.prefix(4), as: UTF8.self) == "RIFF")
    }
}

@Suite struct StoreTests {
    @Test func persistsAndPicksBestMinutes() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("days-\(UUID()).json")
        let store = DayStore(url: url)
        store.update("2026-10-09") { $0.estimatedMinutes = 12; $0.sessionMinutes = 20 }
        let reloaded = DayStore(url: url)
        #expect(reloaded.record("2026-10-09").minutes == 20)
        reloaded.update("2026-10-09") { $0.measuredMinutes = 41 }
        #expect(reloaded.record("2026-10-09").minutes == 41)
        #expect(reloaded.record("2026-10-09").isMeasured)
        #expect(reloaded.record("2026-10-10").playableSpec == reloaded.record("2026-10-10").playableSpec)
    }

    @Test func lastDaysAreOldestFirst() {
        let store = DayStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("d-\(UUID()).json"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let days = store.lastDays(3, endingAt: utc("2026-10-09T10:00:00Z"), calendar: cal).map(\.day)
        #expect(days == ["2026-10-07", "2026-10-08", "2026-10-09"])
    }
}

@Suite struct GuardTests {
    @Test func tempoGuardFoldsAndClamps() {
        #expect(TempoGuard.bpm(60, activity: "run") == 140)
        #expect(TempoGuard.bpm(75, activity: "run") == 150)
        #expect(TempoGuard.bpm(160, activity: "walk") == 124)
        #expect(TempoGuard.bpm(100, activity: "walk") == 100)
        #expect(TempoGuard.bpm(200, activity: "day") == 100)
    }

    @Test func fieldNoteCleanup() {
        let raw = """
        Okay, here's a two-sentence field note in plain words:

        "You ran 27 minutes as the city woke. The melody arrived just as your legs found their rhythm!"
        """
        let c = PromptBuilder.cleanFieldNote(raw)
        #expect(c == "You ran 27 minutes as the city woke. The melody arrived just as your legs found their rhythm.")
    }

    @Test func promptOptionOrderVariesByMoment() {
        func p(_ minute: Double) -> String {
            PromptBuilder.composePrompt(ComposerContext(
                date: Date(timeIntervalSince1970: 1_790_000_000 + minute * 60), activity: "run",
                minutesToday: 0, targetMinutes: 30, recentDays: []))
        }
        #expect(p(0) == p(0))
        #expect(p(0) != p(1))
        #expect(p(0).contains("140 to 170"))
    }

    @Test func syntheticFieldIsAudible() {
        let f = FieldClip.synthetic(sampleRate: 22050, seconds: 4)
        #expect(f.count == 88200)
        #expect((f.map(abs).max() ?? 0) > 0.3)
    }

    @Test func songSwapWaitsForLoopEnd() {
        let r = SongRenderer(spec: .default, sampleRate: 8000)
        r.setUnlocked(Set(Layer.allCases), immediate: true)
        _ = r.renderOffline(seconds: 1)
        r.setSong(SongSpec.fallback(seed: 3))
        _ = r.renderOffline(seconds: 1)
        #expect(r.currentBeat > 2)  // still mid-loop, not reset
        r.setSong(SongSpec.fallback(seed: 4), immediate: true)
        _ = r.renderOffline(seconds: 0.1)
        #expect(r.currentBeat < 1)
    }
}

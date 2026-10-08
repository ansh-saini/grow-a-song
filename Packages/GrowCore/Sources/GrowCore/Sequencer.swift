import Foundation

public enum VoiceKind: Int, Sendable, CaseIterable {
    case drone, pad, bass, kick, snare, hat, melody

    public var layer: Layer {
        switch self {
        case .drone: .drone
        case .pad: .pad
        case .bass: .bass
        case .kick, .snare, .hat: .drums
        case .melody: .melody
        }
    }
}

/// A note in beats, so tempo can change while the song plays.
public struct NoteEvent: Sendable, Equatable {
    public var beat: Double
    public var length: Double
    public var midi: Int
    public var velocity: Float
    public var voice: VoiceKind
}

public struct Pattern: Sendable {
    public var bars: Int
    public var events: [NoteEvent]
    public var lengthBeats: Double { Double(bars * 4) }
}

public enum Theory {
    /// Seven-note parent scale for chords.
    public static func parent(_ s: ScaleKind) -> [Int] {
        switch s {
        case .major, .majorPentatonic: [0, 2, 4, 5, 7, 9, 11]
        case .minor, .minorPentatonic: [0, 2, 3, 5, 7, 8, 10]
        case .dorian: [0, 2, 3, 5, 7, 9, 10]
        case .lydian: [0, 2, 4, 6, 7, 9, 11]
        case .mixolydian: [0, 2, 4, 5, 7, 9, 10]
        }
    }

    /// Notes the melody may use. Pentatonic scales keep the melody hard to get wrong.
    public static func melodySet(_ s: ScaleKind) -> [Int] {
        switch s {
        case .majorPentatonic: [0, 2, 4, 7, 9]
        case .minorPentatonic: [0, 3, 5, 7, 10]
        default: parent(s)
        }
    }

    /// Semitone offsets (from the key root) of a triad built on a scale degree.
    public static func triad(degree: Int, scale: ScaleKind) -> [Int] {
        let p = parent(scale)
        let i = (degree - 1 + 7) % 7
        return [0, 2, 4].map { step in
            let idx = i + step
            return p[idx % 7] + 12 * (idx / 7)
        }
    }

    public static func frequency(midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }
}

/// Turns a SongSpec into a 16-bar pattern. Deterministic for a given spec.
public enum Sequencer {
    public static let bars = 16

    public static func pattern(for spec: SongSpec) -> Pattern {
        var rng = SplitMix64(seed: spec.seed)
        var ev: [NoteEvent] = []
        let root = spec.rootSemitone
        let prog = spec.progression
        let e = spec.energy

        // Drone: root and fifth, held across four bars.
        for bar in stride(from: 0, to: bars, by: 4) {
            let b = Double(bar * 4)
            ev.append(NoteEvent(beat: b, length: 16, midi: 36 + root, velocity: 0.55, voice: .drone))
            ev.append(NoteEvent(beat: b, length: 16, midi: 43 + root, velocity: 0.35, voice: .drone))
        }

        for bar in 0..<bars {
            let b = Double(bar * 4)
            let degree = prog[bar % prog.count]
            let triad = Theory.triad(degree: degree, scale: spec.scale)
            let chordRoot = triad[0]

            // Pads: close voicing around middle C.
            for (n, off) in triad.enumerated() {
                ev.append(NoteEvent(beat: b, length: 4, midi: 55 + root + off, velocity: n == 0 ? 0.5 : 0.42, voice: .pad))
            }

            // Bass.
            var bassNote = 36 + root + chordRoot
            if bassNote > 45 { bassNote -= 12 }
            switch spec.bass {
            case .sub:
                ev.append(NoteEvent(beat: b, length: 2.5, midi: bassNote, velocity: 0.8, voice: .bass))
                ev.append(NoteEvent(beat: b + 2.5, length: 1.4, midi: bassNote, velocity: 0.6, voice: .bass))
            case .pluck:
                let steps = e > 0.6 ? 8 : 4
                for s in 0..<steps {
                    let hop = (s % 4 == 3 && rng.chance(0.5)) ? 12 : 0
                    let len = 4.0 / Double(steps)
                    ev.append(NoteEvent(beat: b + Double(s) * len, length: len * 0.8, midi: bassNote + hop, velocity: s == 0 ? 0.85 : 0.6, voice: .bass))
                }
            case .pulse:
                for s in 0..<8 {
                    ev.append(NoteEvent(beat: b + Double(s) * 0.5, length: 0.4, midi: bassNote, velocity: s % 2 == 0 ? 0.75 : 0.5, voice: .bass))
                }
            }

            // Drums.
            switch spec.drums {
            case .soft:
                ev.append(NoteEvent(beat: b, length: 0.5, midi: 36, velocity: 0.8, voice: .kick))
                ev.append(NoteEvent(beat: b + 2, length: 0.5, midi: 36, velocity: 0.65, voice: .kick))
                ev.append(NoteEvent(beat: b + 3, length: 0.25, midi: 38, velocity: 0.35, voice: .snare))
                for s in 0..<4 {
                    ev.append(NoteEvent(beat: b + Double(s) + 0.5, length: 0.1, midi: 42, velocity: 0.3, voice: .hat))
                }
            case .driving:
                for s in 0..<4 {
                    ev.append(NoteEvent(beat: b + Double(s), length: 0.5, midi: 36, velocity: 0.9, voice: .kick))
                }
                ev.append(NoteEvent(beat: b + 1, length: 0.25, midi: 38, velocity: 0.7, voice: .snare))
                ev.append(NoteEvent(beat: b + 3, length: 0.25, midi: 38, velocity: 0.7, voice: .snare))
                let density = 0.5 + e * 0.5
                for s in 0..<16 where s % 2 == 1 || rng.chance(density * 0.5) {
                    ev.append(NoteEvent(beat: b + Double(s) * 0.25, length: 0.1, midi: 42, velocity: s % 4 == 2 ? 0.45 : 0.28, voice: .hat))
                }
            case .shuffle:
                ev.append(NoteEvent(beat: b, length: 0.5, midi: 36, velocity: 0.85, voice: .kick))
                ev.append(NoteEvent(beat: b + 2 + 2.0 / 3, length: 0.5, midi: 36, velocity: 0.6, voice: .kick))
                ev.append(NoteEvent(beat: b + 1, length: 0.25, midi: 38, velocity: 0.55, voice: .snare))
                ev.append(NoteEvent(beat: b + 3, length: 0.25, midi: 38, velocity: 0.6, voice: .snare))
                for s in 0..<4 {
                    ev.append(NoteEvent(beat: b + Double(s), length: 0.1, midi: 42, velocity: 0.32, voice: .hat))
                    ev.append(NoteEvent(beat: b + Double(s) + 2.0 / 3, length: 0.1, midi: 42, velocity: 0.22, voice: .hat))
                }
            }
        }

        ev += melody(spec: spec, rng: &rng)
        ev.sort { $0.beat < $1.beat }
        return Pattern(bars: bars, events: ev)
    }

    /// Phrases in an A A' B A shape so the melody repeats enough to be catchy.
    private static func melody(spec: SongSpec, rng: inout SplitMix64) -> [NoteEvent] {
        let set = Theory.melodySet(spec.scale)
        let root = spec.rootSemitone
        // Ladder of playable melody notes from G4 to C6, all in the scale.
        let ladder: [Int] = (60...86).filter { set.contains((($0 - root) % 12 + 12) % 12) }
        guard !ladder.isEmpty else { return [] }
        let density = 0.3 + spec.energy * 0.35

        func phrase(_ rng: inout SplitMix64) -> [NoteEvent] {
            var out: [NoteEvent] = []
            var idx = ladder.count / 2
            for bar in 0..<4 {
                let degree = spec.progression[bar % spec.progression.count]
                let chordPCs = Set(Theory.triad(degree: degree, scale: spec.scale).map { (root + $0) % 12 })
                var step = 0
                while step < 8 {
                    let onDownbeat = step == 0
                    if onDownbeat || rng.chance(density) {
                        idx = max(0, min(ladder.count - 1, idx + [-2, -1, -1, 1, 1, 2, 0][rng.int(7)]))
                        if onDownbeat {
                            // Snap the downbeat to the nearest chord tone.
                            if let near = ladder.indices.min(by: { a, b in
                                let ca = chordPCs.contains(ladder[a] % 12) ? 0 : 100
                                let cb = chordPCs.contains(ladder[b] % 12) ? 0 : 100
                                return ca + abs(a - idx) < cb + abs(b - idx)
                            }) { idx = near }
                        }
                        let span = rng.chance(0.3) ? 2 : 1
                        let len = Double(span) * 0.5
                        out.append(NoteEvent(
                            beat: Double(bar * 4) + Double(step) * 0.5, length: len * 0.9,
                            midi: ladder[idx], velocity: onDownbeat ? 0.7 : 0.5 + Float(rng.unit()) * 0.15,
                            voice: .melody))
                        step += span
                    } else {
                        step += 1
                    }
                }
            }
            return out
        }

        let a = phrase(&rng)
        var aPrime = a
        // Variation: change the last bar.
        let tail = phrase(&rng).filter { $0.beat >= 12 }
        aPrime.removeAll { $0.beat >= 12 }
        aPrime += tail
        let bPhrase = phrase(&rng)

        func shifted(_ p: [NoteEvent], bars: Int) -> [NoteEvent] {
            p.map { var n = $0; n.beat += Double(bars * 4); return n }
        }
        return shifted(a, bars: 0) + shifted(aPrime, bars: 4) + shifted(bPhrase, bars: 8) + shifted(a, bars: 12)
    }
}

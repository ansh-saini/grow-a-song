import Foundation

/// Realtime synth for a SongSpec. The audio thread calls `render`; every other
/// method is safe to call from any thread and takes effect on the next block.
public final class SongRenderer: @unchecked Sendable {
    public let sampleRate: Double

    // MARK: Audio-thread state

    private var spec: SongSpec
    private var pattern: Pattern
    private var beat: Double = 0
    private var nextEvent = 0
    private var bpm: Double
    private var targetBpm: Double
    private var layerGain = [Float](repeating: 0, count: Layer.allCases.count)
    private var layerTarget = [Float](repeating: 0, count: Layer.allCases.count)
    private var voices = [Voice](repeating: Voice(), count: 64)
    private var field: [Float] = []
    private var fieldPos = 0
    private var fieldLFO: Double = 0
    private var fieldLP: Float = 0
    private var reverb: Reverb
    private var noiseState: UInt32 = 0x1234_5678

    // MARK: Cross-thread handoff

    private let lock = NSLock()
    private var pendingSong: (SongSpec, Pattern)?
    private var pendingSongImmediate = false
    /// Buffers swapped out on the audio thread; released later off it.
    private var retired: [Any] = []
    private var pendingLayers: Set<Layer>?
    private var pendingImmediate = false
    private var pendingBpm: Double?
    private var pendingField: [Float]?

    /// Last rendered beat position, for UI pulses. Read-only outside the audio thread.
    public private(set) var currentBeat: Double = 0
    /// Smoothed output level 0...1, for UI meters.
    public private(set) var level: Float = 0

    public init(spec: SongSpec, sampleRate: Double) {
        self.sampleRate = sampleRate
        self.spec = spec
        self.pattern = Sequencer.pattern(for: spec)
        self.bpm = Double(spec.bpm)
        self.targetBpm = Double(spec.bpm)
        self.reverb = Reverb(sampleRate: sampleRate)
        layerTarget[Layer.drone.rawValue] = 1
        field = FieldClip.synthetic(sampleRate: sampleRate)
        retired.reserveCapacity(8)
    }

    /// Swaps the song. By default the swap waits for the end of the current
    /// 16-bar loop so it lands on a phrase boundary instead of cutting notes off.
    /// `keepTempo` leaves a stride-synced tempo alone.
    public func setSong(_ newSpec: SongSpec, immediate: Bool = false, keepTempo: Bool = false) {
        let p = Sequencer.pattern(for: newSpec)
        lock.lock()
        pendingSong = (newSpec, p)
        pendingSongImmediate = immediate
        if !keepTempo { pendingBpm = Double(newSpec.bpm) }
        retired.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Layers fade in over a few seconds unless `immediate`.
    public func setUnlocked(_ layers: Set<Layer>, immediate: Bool = false) {
        lock.lock()
        pendingLayers = layers
        pendingImmediate = immediate
        lock.unlock()
    }

    public func setTempo(_ newBpm: Double) {
        lock.lock()
        pendingBpm = min(170, max(60, newBpm))
        lock.unlock()
    }

    /// Mono samples already at `sampleRate`. See `FieldClip.prepare`.
    public func setFieldClip(_ samples: [Float]) {
        lock.lock()
        pendingField = samples
        retired.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    // MARK: Render

    private func applyPending(atLoopStart: Bool) {
        guard lock.try() else { return }
        defer { lock.unlock() }
        if let (s, p) = pendingSong, pendingSongImmediate || atLoopStart {
            if retired.count < 8 { retired.append(pattern) }
            spec = s
            pattern = p
            if pendingSongImmediate {
                beat = 0
                nextEvent = 0
                for i in voices.indices where voices[i].active { voices[i].release(at: voices[i].t) }
            }
            pendingSong = nil
        }
        if let layers = pendingLayers {
            for l in Layer.allCases {
                layerTarget[l.rawValue] = layers.contains(l) ? 1 : 0
                if pendingImmediate { layerGain[l.rawValue] = layerTarget[l.rawValue] }
            }
            pendingLayers = nil
        }
        if let b = pendingBpm {
            targetBpm = b
            pendingBpm = nil
        }
        if let f = pendingField {
            if retired.count < 8 { retired.append(field) }
            field = f
            fieldPos = 0
            pendingField = nil
        }
    }

    public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        applyPending(atLoopStart: false)
        let sr = Float(sampleRate)
        let dt = 1.0 / sampleRate
        let fadeUp = 1 - exp(-1 / (sr * 4.0))
        let fadeDown = 1 - exp(-1 / (sr * 1.5))
        let bpmGlide = 1 - exp(-1 / (sampleRate * 2.0))
        var peak: Float = 0

        for f in 0..<frames {
            bpm += (targetBpm - bpm) * bpmGlide
            for l in 0..<layerGain.count {
                let target = layerTarget[l]
                layerGain[l] += (target - layerGain[l]) * (target > layerGain[l] ? fadeUp : fadeDown)
            }

            while nextEvent < pattern.events.count && pattern.events[nextEvent].beat <= beat {
                trigger(pattern.events[nextEvent])
                nextEvent += 1
            }

            var outL: Float = 0, outR: Float = 0, send: Float = 0
            for i in voices.indices where voices[i].active {
                let g = layerGain[voices[i].kind.layer.rawValue]
                let s = voices[i].next(dt: dt, sr: sampleRate, style: spec, noise: &noiseState) * g
                let pan = voices[i].pan
                outL += s * (1 - pan) * 0.5
                outR += s * (1 + pan) * 0.5
                send += s * voices[i].kind.reverbSend
            }

            let fg = layerGain[Layer.field.rawValue]
            if !field.isEmpty && fg > 0.0005 {
                fieldLFO += 0.07 * dt
                let swell = Float(0.65 + 0.35 * sin(2 * .pi * fieldLFO))
                fieldLP += 0.25 * (field[fieldPos] - fieldLP)
                let s = fieldLP * swell * fg * Mix.field
                outL += s * 0.5
                outR += s * 0.5
                send += s * 0.6
                fieldPos = (fieldPos + 1) % field.count
            }

            let (wl, wr) = reverb.process(send)
            var l = outL + wl * 0.4
            var r = outR + wr * 0.4
            l = tanh(l * 1.25)
            r = tanh(r * 1.25)
            left[f] = l
            right[f] = r
            peak = max(peak, abs(l), abs(r))

            beat += bpm / 60 * dt
            if beat >= pattern.lengthBeats {
                beat -= pattern.lengthBeats
                nextEvent = 0
                applyPending(atLoopStart: true)
            }
        }
        currentBeat = beat
        level = level * 0.8 + peak * 0.2
    }

    private func trigger(_ e: NoteEvent) {
        let l = e.voice.layer.rawValue
        guard layerTarget[l] > 0 || layerGain[l] > 0.001 else { return }
        var slot = voices.firstIndex { !$0.active }
        if slot == nil {
            // Steal the oldest voice.
            var oldest = 0
            for i in voices.indices where voices[i].t > voices[oldest].t { oldest = i }
            slot = oldest
        }
        guard let i = slot else { return }
        let gate = e.length * 60 / bpm
        let pan: Float
        switch e.voice {
        case .pad:
            switch e.midi % 3 {
            case 0: pan = -0.5
            case 1: pan = 0
            default: pan = 0.5
            }
        case .hat: pan = 0.3
        case .melody: pan = -0.15
        case .snare: pan = 0.1
        default: pan = 0
        }
        voices[i] = Voice(kind: e.voice, midi: e.midi, velocity: e.velocity, gate: gate, pan: pan)
    }

    /// Renders without a device, for export and tests.
    public func renderOffline(seconds: Double) -> (left: [Float], right: [Float]) {
        let total = Int(seconds * sampleRate)
        var l = [Float](repeating: 0, count: total)
        var r = [Float](repeating: 0, count: total)
        var done = 0
        while done < total {
            let n = min(512, total - done)
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in
                    render(frames: n, left: lp.baseAddress! + done, right: rp.baseAddress! + done)
                }
            }
            done += n
        }
        return (l, r)
    }
}

enum Mix {
    static let field: Float = 0.55
}

extension VoiceKind {
    var mix: Float {
        switch self {
        case .drone: 0.32
        case .pad: 0.26
        case .bass: 0.42
        case .kick: 0.75
        case .snare: 0.32
        case .hat: 0.12
        case .melody: 0.24
        }
    }

    var reverbSend: Float {
        switch self {
        case .drone: 0.4
        case .pad: 0.55
        case .bass: 0.05
        case .kick: 0.05
        case .snare: 0.3
        case .hat: 0.15
        case .melody: 0.5
        }
    }
}

struct Voice {
    var active = false
    var kind: VoiceKind = .pad
    var freq: Double = 0
    var ph = (0.0, 0.0, 0.0)
    var t: Double = 0
    var gate: Double = 0
    var velocity: Float = 0
    var lp: Float = 0
    var lp2: Float = 0
    var pan: Float = 0
    var releaseLevel: Float = 0
    var released = false
    var lastEnv: Float = 0

    init() {}

    init(kind: VoiceKind, midi: Int, velocity: Float, gate: Double, pan: Float) {
        active = true
        self.kind = kind
        freq = Theory.frequency(midi: Double(midi))
        self.velocity = velocity
        self.gate = max(0.02, gate)
        self.pan = pan
    }

    mutating func release(at time: Double) {
        gate = min(gate, time)
    }

    /// (attack, decay, sustain, release) in seconds / level.
    func adsr(_ s: SongSpec) -> (Double, Double, Float, Double) {
        switch kind {
        case .drone: return (2.5, 1, 1, 3)
        case .pad: return (0.8, 2, 0.8, 1.6)
        case .bass:
            switch s.bass {
            case .sub: return (0.008, 0.4, 0.75, 0.12)
            case .pluck: return (0.003, 0.18, 0.25, 0.08)
            case .pulse: return (0.004, 0.12, 0.6, 0.05)
            }
        case .melody:
            switch s.melody {
            case .bell: return (0.002, 0.7, 0, 0.5)
            case .kalimba: return (0.002, 0.3, 0, 0.25)
            case .flute: return (0.06, 0.3, 0.8, 0.15)
            }
        case .kick, .snare, .hat: return (0.001, 1, 1, 0.01)
        }
    }

    mutating func next(dt: Double, sr: Double, style s: SongSpec, noise: inout UInt32) -> Float {
        let (a, d, sus, r) = adsr(s)
        var env: Float
        if t < gate {
            env = t < a ? Float(t / a) : sus + (1 - sus) * Float(exp(-(t - a) / d))
            lastEnv = env
        } else {
            if !released {
                released = true
                releaseLevel = lastEnv
            }
            env = releaseLevel * Float(exp(-(t - gate) / r))
            if env < 0.0001 { active = false; return 0 }
        }

        let twoPi = 2 * Double.pi
        var out: Float = 0
        switch kind {
        case .drone:
            ph.0 = frac(ph.0 + freq * dt)
            ph.1 = frac(ph.1 + freq * 1.003 * dt)
            out = Float(sin(twoPi * ph.0) + 0.35 * sin(twoPi * 2 * ph.1) + 0.12 * tri(ph.1))

        case .pad:
            let det = s.pad == .choir ? 0.004 : 0.006
            ph.0 = frac(ph.0 + freq * dt)
            ph.1 = frac(ph.1 + freq * (1 + det) * dt)
            ph.2 = frac(ph.2 + freq * (s.pad == .glass ? 2 : (1 - det)) * dt)
            let raw: Double
            let cutoff: Double
            switch s.pad {
            case .glass:
                raw = 0.5 * (saw(ph.0) + saw(ph.1)) + 0.4 * sin(twoPi * ph.2)
                cutoff = 1800
            case .warm:
                raw = 0.5 * (saw(ph.0) + saw(ph.1))
                cutoff = 750
            case .choir:
                let vib = 1 + 0.003 * sin(twoPi * 5 * t)
                ph.0 = frac(ph.0 + freq * (vib - 1) * dt)
                raw = (tri(ph.0) + tri(ph.1) + tri(ph.2)) / 2
                cutoff = 1400
            }
            out = lowpass(Float(raw), cutoff, sr)

        case .bass:
            ph.0 = frac(ph.0 + freq * dt)
            switch s.bass {
            case .sub:
                out = Float(tanh(1.4 * (sin(twoPi * ph.0) + 0.2 * sin(twoPi * 2 * ph.0))))
            case .pluck:
                let cutoff = 300 + 2400 * exp(-t / 0.12)
                out = lowpass(Float(saw(ph.0)), cutoff, sr)
            case .pulse:
                out = lowpass(ph.0 < 0.5 ? 0.7 : -0.7, 900, sr)
            }

        case .kick:
            let f = 45 + 110 * exp(-t / 0.035)
            ph.0 = frac(ph.0 + f * dt)
            out = Float(sin(twoPi * ph.0) * exp(-t / 0.28))
            if t > 0.9 { active = false }

        case .snare:
            ph.0 = frac(ph.0 + 190 * dt)
            let n = whiteNoise(&noise)
            out = lowpass(n, 5000, sr) * Float(exp(-t / 0.12)) * 0.7 + Float(sin(twoPi * ph.0) * exp(-t / 0.05)) * 0.5
            if s.drums == .soft { out *= 0.6 }
            if t > 0.6 { active = false }

        case .hat:
            let n = whiteNoise(&noise)
            lp += 0.35 * (n - lp)
            out = (n - lp) * Float(exp(-t / 0.035))
            if t > 0.3 { active = false }

        case .melody:
            ph.0 = frac(ph.0 + freq * dt)
            switch s.melody {
            case .bell:
                ph.1 = frac(ph.1 + freq * 3.5 * dt)
                let index = 2.2 * exp(-t / 0.35)
                out = Float(sin(twoPi * ph.0 + index * sin(twoPi * ph.1)))
            case .kalimba:
                ph.1 = frac(ph.1 + freq * 5.4 * dt)
                out = Float(sin(twoPi * ph.0) + 0.45 * sin(twoPi * ph.1) * exp(-t / 0.05))
            case .flute:
                let vib = t > 0.25 ? 1 + 0.004 * sin(twoPi * 5.2 * t) : 1
                ph.0 = frac(ph.0 + freq * (vib - 1) * dt)
                let body = 0.6 * sin(twoPi * ph.0) + 0.4 * tri(ph.0)
                out = lowpass(Float(body) + whiteNoise(&noise) * 0.04, 3000, sr)
            }
        }

        t += dt
        return out * env * velocity * kind.mix
    }

    private mutating func lowpass(_ x: Float, _ cutoff: Double, _ sr: Double) -> Float {
        let c = Float(1 - exp(-2 * Double.pi * cutoff / sr))
        lp += c * (x - lp)
        lp2 += c * (lp - lp2)
        return lp2
    }
}

@inline(__always) private func frac(_ x: Double) -> Double { x - floor(x) }
@inline(__always) private func saw(_ p: Double) -> Double { 2 * p - 1 }
@inline(__always) private func tri(_ p: Double) -> Double { 4 * abs(p - 0.5) - 1 }
@inline(__always) private func whiteNoise(_ s: inout UInt32) -> Float {
    s ^= s << 13
    s ^= s >> 17
    s ^= s << 5
    return Float(s) / Float(UInt32.max) * 2 - 1
}

/// Small Freeverb-style stereo reverb.
struct Reverb {
    private var combsL: [Comb]
    private var combsR: [Comb]
    private var apL: [AllPass]
    private var apR: [AllPass]

    init(sampleRate: Double) {
        let k = sampleRate / 44100
        func n(_ x: Int) -> Int { max(1, Int(Double(x) * k)) }
        combsL = [1116, 1277, 1422, 1557].map { Comb(size: n($0)) }
        combsR = [1139, 1300, 1445, 1580].map { Comb(size: n($0)) }
        apL = [556, 441].map { AllPass(size: n($0)) }
        apR = [579, 464].map { AllPass(size: n($0)) }
    }

    mutating func process(_ x: Float) -> (Float, Float) {
        let input = x * 0.12
        var l: Float = 0, r: Float = 0
        for i in combsL.indices { l += combsL[i].process(input) }
        for i in combsR.indices { r += combsR[i].process(input) }
        for i in apL.indices { l = apL[i].process(l) }
        for i in apR.indices { r = apR[i].process(r) }
        return (l, r)
    }

    struct Comb {
        var buf: [Float]
        var idx = 0
        var store: Float = 0
        init(size: Int) { buf = [Float](repeating: 0, count: size) }
        mutating func process(_ x: Float) -> Float {
            let out = buf[idx]
            store = out * 0.75 + store * 0.25
            buf[idx] = x + store * 0.84
            idx += 1
            if idx == buf.count { idx = 0 }
            return out
        }
    }

    struct AllPass {
        var buf: [Float]
        var idx = 0
        init(size: Int) { buf = [Float](repeating: 0, count: size) }
        mutating func process(_ x: Float) -> Float {
            let b = buf[idx]
            buf[idx] = x + b * 0.5
            idx += 1
            if idx == buf.count { idx = 0 }
            return b - x
        }
    }
}

public enum FieldClip {
    /// Wind-and-birds texture for when no clip was recorded, so the last layer is never silent.
    public static func synthetic(sampleRate sr: Double, seconds: Double = 8) -> [Float] {
        var out = [Float](repeating: 0, count: Int(sr * seconds))
        var rng = SplitMix64(seed: 7)
        var lp: Float = 0, lp2: Float = 0
        var chirpPhase = 0.0
        for i in out.indices {
            let n = Float(rng.unit() * 2 - 1)
            lp += 0.02 * (n - lp)
            lp2 += 0.01 * (lp - lp2)
            let t = Double(i) / sr
            let gust = Float(0.6 + 0.4 * sin(2 * .pi * 0.15 * t))
            var chirp: Float = 0
            let slot = t.truncatingRemainder(dividingBy: 2.7)
            if slot < 0.12 {
                chirpPhase += (3200 + 900 * sin(slot * 60)) / sr
                chirp = Float(sin(2 * .pi * chirpPhase)) * Float(sin(.pi * slot / 0.12)) * 0.25
            }
            out[i] = lp2 * 6 * gust + chirp
        }
        return prepare(out, inputRate: sr, outputRate: sr)
    }

    /// Resample, remove DC, normalize and fade a mono mic clip so it loops softly.
    public static func prepare(_ input: [Float], inputRate: Double, outputRate: Double) -> [Float] {
        guard input.count > 100, inputRate > 0, outputRate > 0 else { return [] }
        let ratio = inputRate / outputRate
        let outCount = Int(Double(input.count) / ratio)
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let pos = Double(i) * ratio
            let j = Int(pos)
            let fr = Float(pos - Double(j))
            let a = input[min(j, input.count - 1)]
            let b = input[min(j + 1, input.count - 1)]
            out[i] = a + (b - a) * fr
        }
        let mean = out.reduce(0, +) / Float(out.count)
        var peak: Float = 0
        for i in out.indices {
            out[i] -= mean
            peak = max(peak, abs(out[i]))
        }
        if peak > 0 { for i in out.indices { out[i] *= 0.7 / peak } }
        let fade = min(Int(outputRate * 0.5), out.count / 2)
        for i in 0..<fade {
            let g = Float(i) / Float(fade)
            out[i] *= g
            out[out.count - 1 - i] *= g
        }
        return out
    }
}

public enum WAVWriter {
    /// 16-bit PCM stereo.
    public static func data(left: [Float], right: [Float], sampleRate: Int) -> Data {
        let frames = min(left.count, right.count)
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let dataSize = UInt32(frames * 4)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 4)); u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        var pcm = [Int16](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            pcm[2 * i] = Int16(max(-1, min(1, left[i])) * 32767)
            pcm[2 * i + 1] = Int16(max(-1, min(1, right[i])) * 32767)
        }
        pcm.withUnsafeBufferPointer { d.append(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count)) }
        return d
    }
}

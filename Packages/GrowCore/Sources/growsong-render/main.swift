import Foundation
import GrowCore

// Renders each layer stage of a song to WAV and prints loudness numbers.
// Usage: growsong-render [outDir] [secondsPerStage] [spec.json]

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "out")
let seconds = args.count > 2 ? Double(args[2]) ?? 20 : 20
var spec = SongSpec.default
if args.count > 3, let data = FileManager.default.contents(atPath: args[3]),
   let s = SongSpec.parse(String(decoding: data, as: UTF8.self)) {
    spec = s
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let sr = 44100.0

func stats(_ x: [Float]) -> (rms: Float, peak: Float) {
    var sum: Float = 0, peak: Float = 0
    for v in x { sum += v * v; peak = max(peak, abs(v)) }
    return ((sum / Float(max(1, x.count))).squareRoot(), peak)
}

// Fake field clip: filtered noise with a few chirps, standing in for birdsong.
var clip = [Float](repeating: 0, count: Int(sr * 6))
var rng = SplitMix64(seed: 7)
var lp: Float = 0
for i in clip.indices {
    let n = Float(rng.unit() * 2 - 1)
    lp += 0.05 * (n - lp)
    let t = Double(i) / sr
    let chirp = (Int(t * 3) % 4 == 0) ? Float(sin(2 * .pi * (3000 + 800 * sin(t * 40)) * t)) * 0.2 : 0
    clip[i] = lp * 2 + chirp
}

print("spec: \(spec.title) | \(spec.key) \(spec.scale.rawValue) \(spec.bpm) bpm \(spec.progression)")
print(String(format: "%-8@ %8@ %8@", "stage" as NSString, "rms" as NSString, "peak" as NSString))
var allL: [Float] = [], allR: [Float] = []
for layer in Layer.allCases {
    let r = SongRenderer(spec: spec, sampleRate: sr)
    r.setFieldClip(FieldClip.prepare(clip, inputRate: sr, outputRate: sr))
    r.setUnlocked(Set(Layer.allCases.filter { $0 <= layer }), immediate: true)
    let (l, rr) = r.renderOffline(seconds: seconds)
    let s = stats(l)
    print(String(format: "%-8@ %8.3f %8.3f", layer.name as NSString, s.rms, s.peak))
    let url = outDir.appendingPathComponent("stage-\(layer.rawValue)-\(layer.name.lowercased().replacingOccurrences(of: " ", with: "-")).wav")
    try WAVWriter.data(left: l, right: rr, sampleRate: Int(sr)).write(to: url)
    allL += l; allR += rr
}

// One continuous growth render: layers unlock every `seconds`, fading in live.
let grow = SongRenderer(spec: spec, sampleRate: sr)
grow.setFieldClip(FieldClip.prepare(clip, inputRate: sr, outputRate: sr))
var gl: [Float] = [], gr: [Float] = []
for layer in Layer.allCases {
    grow.setUnlocked(Set(Layer.allCases.filter { $0 <= layer }))
    let (l, r) = grow.renderOffline(seconds: seconds)
    gl += l; gr += r
}
try WAVWriter.data(left: gl, right: gr, sampleRate: Int(sr)).write(to: outDir.appendingPathComponent("grow.wav"))
print("wrote \(outDir.path)/stage-*.wav and grow.wav")

import Foundation
import GrowCore

// Export mode reproduces the app's Export button for a day pulled off the phone:
//   growsong-render export <days.json> <yyyy-MM-dd> <targetMinutes> <clip.wav|-> <out.wav> [loops] [growthStageSeconds]
// It also writes <out>-growth.wav: the run compressed, layers unlocking one by one.
if CommandLine.arguments.count > 6, CommandLine.arguments[1] == "export" {
    let a = CommandLine.arguments
    let days = try JSONDecoder().decode([DayRecord].self, from: Data(contentsOf: URL(fileURLWithPath: a[2])))
    guard let day = days.first(where: { $0.day == a[3] }) else { print("no day \(a[3])"); exit(1) }
    let target = Double(a[4]) ?? 30
    let loops = a.count > 7 ? Double(a[7]) ?? 2 : 2
    let clip = a[5] == "-" ? nil : FileManager.default.contents(atPath: a[5]).flatMap(WAVReader.mono)
    let spec = day.playableSpec
    let layers = LayerSchedule(targetMinutes: target).unlocked(minutes: day.minutes)
    let sr = 44100.0
    let loopSeconds = Double(Sequencer.bars * 4) * 60 / Double(spec.bpm)

    // Same steps as AudioEngine.export in the app.
    let r = SongRenderer(spec: spec, sampleRate: sr)
    r.setUnlocked(layers, immediate: true)
    if let clip { r.setFieldClip(FieldClip.prepare(clip.samples, inputRate: clip.rate, outputRate: sr)) }
    let (l, rr) = r.renderOffline(seconds: loopSeconds * loops)
    try WAVWriter.data(left: l, right: rr, sampleRate: Int(sr)).write(to: URL(fileURLWithPath: a[6]))

    // Growth version: one loop per layer stage, fading in like the live session.
    let g = SongRenderer(spec: spec, sampleRate: sr)
    if let clip { g.setFieldClip(FieldClip.prepare(clip.samples, inputRate: clip.rate, outputRate: sr)) }
    var gl: [Float] = [], gr: [Float] = []
    let stageSeconds = a.count > 8 ? Double(a[8]) ?? loopSeconds : loopSeconds
    for layer in Layer.allCases where layers.contains(layer) {
        g.setUnlocked(Set(Layer.allCases.filter { $0 <= layer }))
        let (x, y) = g.renderOffline(seconds: stageSeconds)
        gl += x; gr += y
    }
    let growthURL = URL(fileURLWithPath: a[6]).deletingPathExtension().path + " (growth).wav"
    try WAVWriter.data(left: gl, right: gr, sampleRate: Int(sr)).write(to: URL(fileURLWithPath: growthURL))
    print("\(spec.title): \(spec.key) \(spec.scale.rawValue) \(spec.bpm) bpm, \(layers.count)/6 layers, \(Int(day.minutes)) min outside, field clip: \(clip != nil)")
    print(String(format: "wrote %@ (%.0fs) and growth version (%.0fs)", a[6], loopSeconds * loops, Double(gl.count) / sr))
    exit(0)
}


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

import Foundation
import GrowCore

// Runs the real on-device composer (Gemma via MLX) on the Mac against a spread
// of contexts and reports validity, fallback rate and latency.
// Usage: ComposerEval [count]

let count = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 6 : 6

func context(_ i: Int) -> ComposerContext {
    let hours = [5, 7, 10, 13, 17, 19, 21]
    let activities = ["run", "walk", "day"]
    var c = DateComponents()
    c.year = 2026; c.month = 10; c.day = 5 + i % 7; c.hour = hours[i % hours.count]; c.minute = 20
    let date = Calendar.current.date(from: c) ?? Date()
    return ComposerContext(
        date: date, activity: activities[i % 3], minutesToday: Double((i * 7) % 35),
        targetMinutes: 30, recentDays: [Double(i * 3 % 40), 12, Double(50 - i)],
        sunElevation: [-4, 3, 25, 55, 20, 2, -10][i % 7],
        stepsPerMinute: i % 3 == 0 ? 164 : nil)
}

let composer = GemmaComposer()
print("loading \(GemmaComposer.modelName)...")
let loadStart = Date()
do {
    try await composer.load { p in
        if Int(p * 100) % 10 == 0 { print(String(format: "  download %.0f%%", p * 100)) }
    }
} catch {
    print("LOAD FAILED: \(error)")
    exit(1)
}
print(String(format: "loaded in %.1fs\n", Date().timeIntervalSince(loadStart)))

var fromModel = 0, guided = 0, times: [Double] = []
var titles = Set<String>()
for i in 0..<count {
    let ctx = context(i)
    let r = await composer.compose(ctx)
    times.append(r.seconds)
    if r.fromModel { fromModel += 1; titles.insert(r.spec.title) }
    if r.guided { guided += 1 }
    let s = r.spec
    print(String(format: "[%d] %@ %@ | %.1fs | %@", i, ctx.activity, ctx.partOfDay, r.seconds, r.guided ? "guided" : (r.fromModel ? "parsed" : "FALLBACK")))
    print("    \"\(s.title)\" \(s.key) \(s.scale.rawValue) \(s.bpm)bpm \(s.progression) pad:\(s.pad.rawValue) bass:\(s.bass.rawValue) drums:\(s.drums.rawValue) mel:\(s.melody.rawValue) e:\(String(format: "%.2f", s.energy))")
    print("    \(s.linerNote)")
    if let e = r.error { print("    error: \(e)") }
}

let note = await composer.fieldNote(prompt: PromptBuilder.fieldNotePrompt(
    minutes: 27, distanceKm: 4.3, layersReached: .melody, songTitle: "Dew on the Path", partOfDay: "morning"))
print("\nfield note: \(note ?? "nil")")

let avg = times.reduce(0, +) / Double(max(1, times.count))
print(String(format: "\nSUMMARY model=%d/%d guided=%d/%d distinct_titles=%d avg=%.1fs max=%.1fs",
             fromModel, count, guided, count, titles.count, avg, times.max() ?? 0))
exit(fromModel == count ? 0 : 2)

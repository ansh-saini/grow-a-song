import Foundation

/// What Gemma knows when it composes. All of it stays on the phone.
public struct ComposerContext: Codable, Sendable {
    public var date: Date
    /// "run", "walk", or "day" when no session is active.
    public var activity: String
    public var minutesToday: Double
    public var targetMinutes: Double
    /// Outside minutes for the previous days, oldest first.
    public var recentDays: [Double]
    public var sunElevation: Double?
    public var stepsPerMinute: Double?

    public init(
        date: Date, activity: String, minutesToday: Double, targetMinutes: Double,
        recentDays: [Double], sunElevation: Double? = nil, stepsPerMinute: Double? = nil
    ) {
        self.date = date
        self.activity = activity
        self.minutesToday = minutesToday
        self.targetMinutes = targetMinutes
        self.recentDays = recentDays
        self.sunElevation = sunElevation
        self.stepsPerMinute = stepsPerMinute
    }

    public var partOfDay: String {
        let h = Calendar.current.component(.hour, from: date)
        switch h {
        case 4..<8: return "early morning"
        case 8..<12: return "morning"
        case 12..<15: return "midday"
        case 15..<18: return "afternoon"
        case 18..<21: return "evening"
        default: return "night"
        }
    }

    public var sunDescription: String? {
        guard let e = sunElevation else { return nil }
        switch e {
        case ..<(-6): return "dark"
        case ..<0: return "twilight, sun just below the horizon"
        case ..<10: return "sun low on the horizon"
        case ..<35: return "sun partway up"
        default: return "sun high overhead"
        }
    }
}

public enum PromptBuilder {
    public static let system = """
    You are the composer inside Grow a Song, an app that turns time spent outside into music. \
    You choose the musical character of today's song. Reply with one JSON object only.
    """

    public static func composePrompt(_ c: ComposerContext) -> String {
        let weekday = c.date.formatted(.dateTime.weekday(.wide))
        let recent = c.recentDays.map { String(Int($0.rounded())) }.joined(separator: ", ")
        var lines: [String] = []
        lines.append("It is \(weekday) \(c.partOfDay).")
        if let sun = c.sunDescription { lines.append("Outside: \(sun).") }
        switch c.activity {
        case "run": lines.append("The listener is starting a run.")
        case "walk": lines.append("The listener is starting a walk.")
        default: lines.append("The listener is going about their day.")
        }
        if let spm = c.stepsPerMinute, let bpm = CadenceTempo.bpm(stepsPerMinute: spm) {
            lines.append("Their stride is about \(Int(bpm)) beats per minute.")
        }
        lines.append(
            "So far today they have spent \(Int(c.minutesToday.rounded())) of \(Int(c.targetMinutes)) target minutes outside.")
        if !recent.isEmpty { lines.append("Minutes outside on recent days: \(recent).") }
        // A 1B model tends to pick whichever option is listed first, so shuffle the
        // option order per request. Same moment, same order; new moment, new order.
        var rng = SplitMix64(seed: seed(for: c))
        func opts(_ xs: [String]) -> String {
            var a = xs
            for i in stride(from: a.count - 1, to: 0, by: -1) { a.swapAt(i, rng.int(i + 1)) }
            return a.joined(separator: ", ")
        }
        let keys = opts(noteNames)
        let scales = opts(ScaleKind.allCases.map(\.rawValue))
        let pads = opts(PadStyle.allCases.map(\.rawValue))
        let basses = opts(BassStyle.allCases.map(\.rawValue))
        let drums = opts(DrumStyle.allCases.map(\.rawValue))
        let melodies = opts(MelodyStyle.allCases.map(\.rawValue))
        let range = TempoGuard.range(for: c.activity)
        lines.append("""

        Choose:
        - title: 2 to 4 evocative words that fit this exact moment (not the word sunrise unless the sun is rising)
        - key: one of \(keys)
        - scale: one of \(scales)
        - bpm: \(Int(range.lowerBound)) to \(Int(range.upperBound)) for this activity
        - progression: 4 scale degrees from 1 to 7, one chord per bar (be inventive, not always 1 5 6 4)
        - pad: one of \(pads)
        - bass: one of \(basses)
        - drums: one of \(drums)
        - melody: one of \(melodies)
        - energy: 0.0 calm to 1.0 intense
        - liner_note: one sentence, under 25 words, about this moment outside. Speak to the listener as "you".

        Match the mood to the time of day and activity. Early morning is fresh and bright, \
        midday is open, evening is warm, a run has drive, a walk wanders.
        """)
        return lines.joined(separator: "\n")
    }

    static func seed(for c: ComposerContext) -> UInt64 {
        let minute = UInt64(max(0, c.date.timeIntervalSince1970 / 60))
        return minute &* 0x9E37_79B9 &+ UInt64(c.activity.utf8.reduce(0) { $0 &* 31 &+ Int($1) })
    }

    /// Small models like to open with "Okay, here's..." and wrap the answer in quotes.
    public static func cleanFieldNote(_ raw: String) -> String {
        var lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        lines.removeAll { l in
            let lower = l.lowercased()
            return l.hasSuffix(":") || lower.hasPrefix("okay") || lower.hasPrefix("here") || lower.hasPrefix("sure")
                || lower.hasPrefix("**") || lower.hasPrefix("#")
        }
        var text = lines.joined(separator: " ")
        let quotes = CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019}")
        text = text.trimmingCharacters(in: quotes.union(.whitespaces))
        text = text.replacingOccurrences(of: "\u{2014}", with: ", ")
            .replacingOccurrences(of: "\u{2013}", with: ", ")
            .replacingOccurrences(of: "!", with: ".")
        return String(text.prefix(300))
    }

    /// After a session: a two-sentence field note for the day's journal.
    public static func fieldNotePrompt(
        minutes: Double, distanceKm: Double?, layersReached: Layer, songTitle: String, partOfDay: String
    ) -> String {
        var facts = "You spent \(Int(minutes.rounded())) minutes outside this \(partOfDay)"
        if let d = distanceKm, d > 0.05 { facts += " and covered \(String(format: "%.1f", d)) km" }
        facts += ". Your song \"\(songTitle)\" grew up to its \(layersReached.name.lowercased()) layer."
        return """
        \(facts)
        Write a field note of exactly two short sentences in second person about this time outside. \
        Plain words, no hashtags, no emoji, no exclamation marks. Output only the two sentences.
        """
    }
}

/// Keeps the tempo sensible for the activity, whatever the model picked.
public enum TempoGuard {
    public static func range(for activity: String) -> ClosedRange<Double> {
        switch activity {
        case "run": 140...170
        case "walk": 88...124
        default: 64...118
        }
    }

    /// Folds by octaves first (a model saying 75 for a run means 150), then clamps.
    public static func bpm(_ bpm: Int, activity: String) -> Int {
        let r = range(for: activity)
        var x = Double(bpm)
        while x < r.lowerBound && x * 2 <= r.upperBound { x *= 2 }
        while x > r.upperBound && x / 2 >= r.lowerBound { x /= 2 }
        return Int(min(r.upperBound, max(r.lowerBound, x)).rounded())
    }
}

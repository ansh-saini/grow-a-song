import Foundation

public enum ScaleKind: String, Codable, CaseIterable, Sendable {
    case majorPentatonic = "major_pentatonic"
    case minorPentatonic = "minor_pentatonic"
    case major, minor, dorian, lydian, mixolydian
}

public enum PadStyle: String, Codable, CaseIterable, Sendable { case glass, warm, choir }
public enum BassStyle: String, Codable, CaseIterable, Sendable { case sub, pluck, pulse }
public enum DrumStyle: String, Codable, CaseIterable, Sendable { case soft, driving, shuffle }
public enum MelodyStyle: String, Codable, CaseIterable, Sendable { case bell, flute, kalimba }

public let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

/// The composition Gemma writes. Gemma picks musical choices; the sequencer and
/// synth turn them into sound, so a small model only has to make taste decisions.
public struct SongSpec: Codable, Equatable, Sendable {
    public var title: String
    public var key: String
    public var scale: ScaleKind
    public var bpm: Int
    /// Scale degrees 1...7, one chord per bar.
    public var progression: [Int]
    public var pad: PadStyle
    public var bass: BassStyle
    public var drums: DrumStyle
    public var melody: MelodyStyle
    /// 0...1, how busy the parts are.
    public var energy: Double
    public var linerNote: String

    enum CodingKeys: String, CodingKey {
        case title, key, scale, bpm, progression, pad, bass, drums, melody, energy
        case linerNote = "liner_note"
    }

    public init(
        title: String, key: String, scale: ScaleKind, bpm: Int, progression: [Int],
        pad: PadStyle, bass: BassStyle, drums: DrumStyle, melody: MelodyStyle,
        energy: Double, linerNote: String
    ) {
        self.title = title
        self.key = key
        self.scale = scale
        self.bpm = bpm
        self.progression = progression
        self.pad = pad
        self.bass = bass
        self.drums = drums
        self.melody = melody
        self.energy = energy
        self.linerNote = linerNote
    }

    /// Lenient decode: every field is optional and unknown values fall back to defaults,
    /// so a slightly-off model answer still yields a playable song.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SongSpec.default
        func str(_ k: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil }

        title = str(.title) ?? d.title
        key = str(.key) ?? d.key
        scale = str(.scale).flatMap { ScaleKind(rawValue: $0.lowercased()) } ?? d.scale
        if let b = try? c.decodeIfPresent(Int.self, forKey: .bpm) {
            bpm = b
        } else if let b = try? c.decodeIfPresent(Double.self, forKey: .bpm) {
            bpm = Int(b)
        } else {
            bpm = d.bpm
        }
        progression = ((try? c.decodeIfPresent([Int].self, forKey: .progression)) ?? nil) ?? d.progression
        pad = str(.pad).flatMap { PadStyle(rawValue: $0.lowercased()) } ?? d.pad
        bass = str(.bass).flatMap { BassStyle(rawValue: $0.lowercased()) } ?? d.bass
        drums = str(.drums).flatMap { DrumStyle(rawValue: $0.lowercased()) } ?? d.drums
        melody = str(.melody).flatMap { MelodyStyle(rawValue: $0.lowercased()) } ?? d.melody
        energy = ((try? c.decodeIfPresent(Double.self, forKey: .energy)) ?? nil) ?? d.energy
        linerNote = str(.linerNote) ?? d.linerNote
        self = sanitized()
    }

    public static let `default` = SongSpec(
        title: "First Light", key: "D", scale: .majorPentatonic, bpm: 96,
        progression: [1, 5, 6, 4], pad: .warm, bass: .sub, drums: .soft, melody: .bell,
        energy: 0.5, linerNote: "A slow song for stepping outside.")

    /// Clamps every field into a range the sequencer can play.
    public func sanitized() -> SongSpec {
        var s = self
        s.title = String(s.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        if s.title.isEmpty { s.title = SongSpec.default.title }
        let k = s.key.trimmingCharacters(in: .whitespaces).uppercased()
            .replacingOccurrences(of: "♯", with: "#")
        s.key = SongSpec.normalizeKey(k) ?? SongSpec.default.key
        s.bpm = min(160, max(60, s.bpm))
        s.progression = s.progression.filter { (1...7).contains($0) }.prefix(8).map { $0 }
        if s.progression.isEmpty { s.progression = SongSpec.default.progression }
        if !s.energy.isFinite { s.energy = 0.5 }
        s.energy = min(1, max(0, s.energy))
        s.linerNote = String(s.linerNote.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        return s
    }

    /// Accepts "C#", "Db", "c#m" style keys and returns a name from `noteNames`.
    static func normalizeKey(_ raw: String) -> String? {
        var k = raw
        for suffix in ["MINOR", "MAJOR", "MIN", "MAJ", "M"] where k.hasSuffix(suffix) && k.count > suffix.count {
            k = String(k.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        let flats = ["DB": "C#", "EB": "D#", "GB": "F#", "AB": "G#", "BB": "A#"]
        if let f = flats[k] { return f }
        return noteNames.first { $0 == k }
    }

    public var rootSemitone: Int { noteNames.firstIndex(of: key) ?? 2 }

    /// Pulls the first JSON object out of model text (handles ```json fences and chatter).
    public static func parse(_ text: String) -> SongSpec? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var end: String.Index?
        var i = start
        while i < text.endIndex {
            let ch = text[i]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { end = i; break }
            }
            i = text.index(after: i)
        }
        guard let end, let data = String(text[start...end]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SongSpec.self, from: data)
    }

    /// Deterministic variation for days Gemma did not compose (history, or model unavailable).
    public static func fallback(seed: UInt64) -> SongSpec {
        var rng = SplitMix64(seed: seed)
        let titles = ["First Light", "Green Hour", "Long Shadow", "Open Sky", "Low Sun", "Footpath", "Wind Map"]
        let progressions = [[1, 5, 6, 4], [1, 4, 6, 5], [6, 4, 1, 5], [1, 6, 4, 5], [2, 5, 1, 6]]
        return SongSpec(
            title: titles[rng.int(titles.count)],
            key: noteNames[rng.int(12)],
            scale: [.majorPentatonic, .minorPentatonic, .dorian, .lydian][rng.int(4)],
            bpm: 84 + rng.int(40),
            progression: progressions[rng.int(progressions.count)],
            pad: PadStyle.allCases[rng.int(3)],
            bass: BassStyle.allCases[rng.int(3)],
            drums: DrumStyle.allCases[rng.int(3)],
            melody: MelodyStyle.allCases[rng.int(3)],
            energy: 0.3 + rng.unit() * 0.5,
            linerNote: "Composed without the model, from the date alone.")
    }

    /// JSON Schema used to constrain Gemma's output token by token.
    public static let jsonSchema: String = {
        func e<T: RawRepresentable & CaseIterable>(_: T.Type) -> String where T.RawValue == String {
            "[" + T.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ",") + "]"
        }
        let keys = "[" + noteNames.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        return """
        {"type":"object","properties":{\
        "title":{"type":"string","maxLength":40},\
        "key":{"type":"string","enum":\(keys)},\
        "scale":{"type":"string","enum":\(e(ScaleKind.self))},\
        "bpm":{"type":"integer","minimum":60,"maximum":160},\
        "progression":{"type":"array","items":{"type":"integer","minimum":1,"maximum":7},"minItems":4,"maxItems":4},\
        "pad":{"type":"string","enum":\(e(PadStyle.self))},\
        "bass":{"type":"string","enum":\(e(BassStyle.self))},\
        "drums":{"type":"string","enum":\(e(DrumStyle.self))},\
        "melody":{"type":"string","enum":\(e(MelodyStyle.self))},\
        "energy":{"type":"number","minimum":0,"maximum":1},\
        "liner_note":{"type":"string","maxLength":200}},\
        "required":["title","key","scale","bpm","progression","pad","bass","drums","melody","energy","liner_note"],\
        "additionalProperties":false}
        """
    }()
}

/// Small deterministic RNG so the same seed always gives the same song.
public struct SplitMix64: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    public mutating func int(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
    public mutating func chance(_ p: Double) -> Bool { unit() < p }
}

public extension SongSpec {
    /// Stable seed from the spec, so the same spec always plays the same notes.
    var seed: UInt64 {
        var h: UInt64 = 1469598103934665603
        for b in "\(title)|\(key)|\(scale.rawValue)|\(progression)".utf8 {
            h = (h ^ UInt64(b)) &* 1099511628211
        }
        return h
    }
}

import Foundation

/// Everything the app remembers about one day.
public struct DayRecord: Codable, Equatable, Sendable, Identifiable {
    public var day: String
    /// From the watch's daylight sensor via HealthKit.
    public var measuredMinutes: Double?
    /// From phone motion history.
    public var estimatedMinutes: Double = 0
    /// Sum of finished live sessions.
    public var sessionMinutes: Double = 0
    public var spec: SongSpec?
    public var composedByModel = false
    public var clipFile: String?
    public var fieldNote: String?
    public var distanceKm: Double?

    public var id: String { day }

    public init(day: String) { self.day = day }

    public var minutes: Double {
        if let m = measuredMinutes, m > 0 { return max(m, sessionMinutes) }
        return max(estimatedMinutes, sessionMinutes)
    }

    public var isMeasured: Bool { (measuredMinutes ?? 0) > 0 }

    public var date: Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)
    }

    /// Spec to play: Gemma's if it composed one, otherwise a stable one from the date.
    public var playableSpec: SongSpec {
        if let spec { return spec }
        var h: UInt64 = 14695981039346656037
        for b in day.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return SongSpec.fallback(seed: h)
    }
}

/// JSON file store. Small data, so a single file is enough.
public final class DayStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var records: [String: DayRecord] = [:]

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([DayRecord].self, from: data) {
            records = Dictionary(list.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    public func record(_ day: String) -> DayRecord {
        lock.lock(); defer { lock.unlock() }
        return records[day] ?? DayRecord(day: day)
    }

    public func update(_ day: String, _ change: (inout DayRecord) -> Void) {
        lock.lock()
        var r = records[day] ?? DayRecord(day: day)
        change(&r)
        records[day] = r
        let list = records.values.sorted { $0.day < $1.day }
        lock.unlock()
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// The last `count` days ending today, oldest first.
    public func lastDays(_ count: Int, endingAt end: Date = Date(), calendar: Calendar = .current) -> [DayRecord] {
        (0..<count).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: end).map { record(DayKey.string($0, calendar: calendar)) }
        }
    }
}

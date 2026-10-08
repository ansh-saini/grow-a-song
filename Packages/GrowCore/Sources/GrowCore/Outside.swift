import Foundation

public enum MotionKind: String, Codable, Sendable {
    case stationary, walking, running, cycling, automotive, unknown

    public var isOnFoot: Bool { self == .walking || self == .running || self == .cycling }
}

/// One snapshot of phone sensors, taken every few seconds during a session.
public struct OutsideSample: Sendable {
    public var date: Date
    public var latitude: Double?
    public var longitude: Double?
    /// GPS horizontal accuracy in meters. Small values usually mean open sky.
    public var horizontalAccuracy: Double?
    public var motion: MotionKind
    /// Distance from the saved home location, if one is set.
    public var distanceFromHome: Double?

    public init(
        date: Date, latitude: Double? = nil, longitude: Double? = nil,
        horizontalAccuracy: Double? = nil, motion: MotionKind = .unknown,
        distanceFromHome: Double? = nil
    ) {
        self.date = date
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.motion = motion
        self.distanceFromHome = distanceFromHome
    }
}

/// Decides whether a sample counts as time outside in daylight.
/// The phone has no light sensor apps can read, so this infers it.
public struct OutsideClassifier: Sendable {
    public var maxAccuracy: Double = 20
    public var homeRadius: Double = 120
    /// Counts every sample. For testing indoors.
    public var testMode: Bool = false

    public init(testMode: Bool = false) { self.testMode = testMode }

    public func isOutside(_ s: OutsideSample) -> Bool {
        if testMode { return true }
        if s.motion == .automotive { return false }

        if let lat = s.latitude, let lon = s.longitude {
            if !Solar.isLight(at: s.date, latitude: lat, longitude: lon) { return false }
        } else {
            // No fix yet: fall back to a conservative local-hour window.
            let hour = Calendar.current.component(.hour, from: s.date)
            if hour < 6 || hour >= 19 { return false }
        }

        if s.motion.isOnFoot { return true }

        let openSky = (s.horizontalAccuracy.map { $0 > 0 && $0 <= maxAccuracy }) ?? false
        let awayFromHome = (s.distanceFromHome.map { $0 > homeRadius }) ?? true
        return openSky && awayFromHome
    }
}

/// Turns a stream of samples into outside seconds.
public struct OutsideTracker: Sendable {
    public private(set) var seconds: Double = 0
    private var lastDate: Date?
    /// A gap longer than this between samples is credited at most this much.
    public var maxCreditPerGap: Double = 60

    public init() {}

    public var minutes: Double { seconds / 60 }

    public mutating func ingest(_ date: Date, outside: Bool) {
        defer { lastDate = date }
        guard let last = lastDate, outside else { return }
        let dt = date.timeIntervalSince(last)
        guard dt > 0 else { return }
        seconds += min(dt, maxCreditPerGap)
    }
}

/// Estimates outside minutes for past days from CoreMotion history.
/// Counts on-foot intervals that happened in daylight.
public enum MotionHistoryEstimator {
    public struct Interval: Sendable {
        public var start: Date
        public var end: Date
        public var motion: MotionKind
        public init(start: Date, end: Date, motion: MotionKind) {
            self.start = start
            self.end = end
            self.motion = motion
        }
    }

    /// Minutes per calendar day (key "yyyy-MM-dd" in the given calendar's time zone).
    public static func minutesByDay(
        _ intervals: [Interval], latitude: Double, longitude: Double,
        calendar: Calendar = .current
    ) -> [String: Double] {
        var out: [String: Double] = [:]
        for iv in intervals where iv.motion.isOnFoot {
            // Walk the interval in one-minute steps so daylight edges are respected.
            var t = iv.start
            while t < iv.end {
                let step = min(60, iv.end.timeIntervalSince(t))
                if Solar.isLight(at: t, latitude: latitude, longitude: longitude) {
                    out[DayKey.string(t, calendar: calendar), default: 0] += step / 60
                }
                t = t.addingTimeInterval(step)
            }
        }
        return out
    }
}

public enum DayKey {
    public static func string(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

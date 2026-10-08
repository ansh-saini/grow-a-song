import CoreMotion
import Foundation
import GrowCore
import HealthKit

/// Estimates past days from CoreMotion's 7-day activity history.
/// Works on any iPhone, no watch needed.
enum MotionHistory {
    static func minutesByDay(latitude: Double, longitude: Double) async -> [String: Double] {
        guard CMMotionActivityManager.isActivityAvailable() else { return [:] }
        let manager = CMMotionActivityManager()
        let end = Date()
        let start = Calendar.current.startOfDay(for: end.addingTimeInterval(-6 * 86400))
        let activities: [CMMotionActivity] = await withCheckedContinuation { cont in
            manager.queryActivityStarting(from: start, to: end, to: .main) { list, _ in
                cont.resume(returning: list ?? [])
            }
        }
        var intervals: [MotionHistoryEstimator.Interval] = []
        for (i, a) in activities.enumerated() where a.confidence != .low {
            let next = i + 1 < activities.count ? activities[i + 1].startDate : end
            // Ignore implausibly long single readings (phone left on a table reads as "walking" rarely, but cap anyway).
            let capped = min(next, a.startDate.addingTimeInterval(3 * 3600))
            intervals.append(.init(start: a.startDate, end: capped, motion: MotionKind(a)))
        }
        return MotionHistoryEstimator.minutesByDay(intervals, latitude: latitude, longitude: longitude)
    }
}

/// Reads daylight minutes the Apple Watch measured with its light sensor.
/// Returns nothing when there is no watch, and the app falls back to the phone.
final class HealthDaylight: @unchecked Sendable {
    private let store = HKHealthStore()
    private var daylightType: HKQuantityType { HKQuantityType(.timeInDaylight) }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAccess() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: [daylightType])
            return true
        } catch {
            return false
        }
    }

    func minutesByDay(days: Int = 7) async -> [String: Double] {
        guard isAvailable else { return [:] }
        let cal = Calendar.current
        let end = Date()
        let start = cal.startOfDay(for: end.addingTimeInterval(-Double(days - 1) * 86400))
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        return await withCheckedContinuation { cont in
            let q = HKStatisticsCollectionQuery(
                quantityType: daylightType, quantitySamplePredicate: predicate,
                options: .cumulativeSum, anchorDate: start, intervalComponents: DateComponents(day: 1))
            q.initialResultsHandler = { _, results, _ in
                var out: [String: Double] = [:]
                results?.enumerateStatistics(from: start, to: end) { stats, _ in
                    if let sum = stats.sumQuantity() {
                        out[DayKey.string(stats.startDate)] = sum.doubleValue(for: .minute())
                    }
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }
}

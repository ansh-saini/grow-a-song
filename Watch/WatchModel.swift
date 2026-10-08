import Foundation
import HealthKit
import Observation
import WatchConnectivity
import WatchKit

/// Watch side: shows the song growing, taps your wrist when a layer unlocks,
/// and runs a workout session so it stays awake during a run.
@MainActor
@Observable
final class WatchModel: NSObject {
    var minutes: Double = 0
    var target: Double = 30
    var layers = 1
    var title = "Grow a Song"
    var active = false
    var activity = ""
    var nextName = ""
    var nextIn: Double = 0
    var outside = false
    var reachable = false
    var lastUnlock: String?

    @ObservationIgnored private let health = HKHealthStore()
    @ObservationIgnored private var workout: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ cmd: String) {
        guard WCSession.default.activationState == .activated else { return }
        WCSession.default.sendMessage(["cmd": cmd], replyHandler: { _ in }, errorHandler: { _ in })
    }

    func start(_ kind: String) {
        send("start-\(kind)")
        startWorkout(running: kind == "run")
    }

    func stop() {
        send("stop")
        endWorkout()
    }

    fileprivate func apply(_ s: [String: Any]) {
        if s["event"] as? String == "unlock" {
            lastUnlock = s["layer"] as? String
            WKInterfaceDevice.current().play(.success)
            return
        }
        let newLayers = s["layers"] as? Int ?? layers
        minutes = s["minutes"] as? Double ?? minutes
        target = s["target"] as? Double ?? target
        title = s["title"] as? String ?? title
        active = s["active"] as? Bool ?? active
        activity = s["activity"] as? String ?? activity
        nextName = s["next"] as? String ?? nextName
        nextIn = s["nextIn"] as? Double ?? nextIn
        outside = s["outside"] as? Bool ?? outside
        layers = newLayers
        if !active { endWorkout() }
    }

    // MARK: Workout (keeps the app running for haptics, logs the run to Health)

    private func startWorkout(running: Bool) {
        guard HKHealthStore.isHealthDataAvailable(), workout == nil else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = running ? .running : .walking
        config.locationType = .outdoor
        Task {
            try? await health.requestAuthorization(
                toShare: [HKObjectType.workoutType()],
                read: [HKQuantityType(.heartRate), HKQuantityType(.timeInDaylight)])
            guard let session = try? HKWorkoutSession(healthStore: health, configuration: config) else { return }
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: health, workoutConfiguration: config)
            session.startActivity(with: Date())
            try? await builder.beginCollection(at: Date())
            self.workout = session
            self.builder = builder
        }
    }

    private func endWorkout() {
        guard let session = workout, let builder else { return }
        workout = nil
        self.builder = nil
        session.end()
        Task {
            try? await builder.endCollection(at: Date())
            _ = try? await builder.finishWorkout()
        }
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let ctx = session.receivedApplicationContext
        let reachable = session.isReachable
        Task { @MainActor in
            self.reachable = reachable
            if !ctx.isEmpty { self.apply(ctx) }
            self.send("sync")
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.reachable = reachable }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let ctx = applicationContext as [String: Any]
        nonisolated(unsafe) let copy = ctx
        Task { @MainActor in self.apply(copy) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        nonisolated(unsafe) let copy = message
        Task { @MainActor in self.apply(copy) }
    }
}

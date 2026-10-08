import CoreLocation
import CoreMotion
import Foundation
import GrowCore

/// Tracks one outing ("I'm outside") with location, motion and pedometer.
/// Everything is processed on device; nothing is uploaded.
@MainActor
final class LiveSession: NSObject, CLLocationManagerDelegate {
    private let location = CLLocationManager()
    private let activity = CMMotionActivityManager()
    private let pedometer = CMPedometer()
    private var timer: Timer?

    private(set) var tracker = OutsideTracker()
    private(set) var lastLocation: CLLocation?
    private(set) var motion: MotionKind = .unknown
    private(set) var distanceMeters: Double = 0
    /// Steps per minute from the pedometer, when moving.
    private(set) var cadence: Double?
    private(set) var lastSampleOutside = false
    private(set) var isRunning = false

    var classifier = OutsideClassifier()
    var home: CLLocation?
    /// Called every tick with the updated tracker.
    var onTick: (() -> Void)?

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.activityType = .fitness
        location.pausesLocationUpdatesAutomatically = false
    }

    func requestPermissions() {
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
    }

    /// One-shot fix, used for daylight math on history and for "set home".
    func requestOneFix() {
        requestPermissions()
        location.requestLocation()
    }

    var knownLocation: CLLocation? { lastLocation ?? location.location }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        tracker = OutsideTracker()
        distanceMeters = 0
        cadence = nil
        requestPermissions()
        location.allowsBackgroundLocationUpdates = true
        location.showsBackgroundLocationIndicator = true
        location.startUpdatingLocation()

        if CMMotionActivityManager.isActivityAvailable() {
            activity.startActivityUpdates(to: .main) { [weak self] a in
                guard let self, let a else { return }
                MainActor.assumeIsolated { self.motion = MotionKind(a) }
            }
        }
        if CMPedometer.isDistanceAvailable() || CMPedometer.isCadenceAvailable() {
            pedometer.startUpdates(from: Date()) { [weak self] data, _ in
                guard let data else { return }
                let dist = data.distance?.doubleValue
                let cad = data.currentCadence?.doubleValue  // steps per second
                Task { @MainActor in
                    guard let self else { return }
                    if let dist { self.distanceMeters = dist }
                    self.cadence = cad.map { $0 * 60 }
                }
            }
        }

        tracker.ingest(Date(), outside: false)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        guard isRunning else { return }
        tick()
        isRunning = false
        timer?.invalidate()
        timer = nil
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
        activity.stopActivityUpdates()
        pedometer.stopUpdates()
    }

    private func tick() {
        let now = Date()
        var sample = OutsideSample(date: now, motion: motion)
        if let loc = lastLocation, now.timeIntervalSince(loc.timestamp) < 60 {
            sample.latitude = loc.coordinate.latitude
            sample.longitude = loc.coordinate.longitude
            sample.horizontalAccuracy = loc.horizontalAccuracy
            if let home { sample.distanceFromHome = loc.distance(from: home) }
        } else if let loc = knownLocation {
            // Stale fix is still fine for sun position.
            sample.latitude = loc.coordinate.latitude
            sample.longitude = loc.coordinate.longitude
        }
        lastSampleOutside = classifier.isOutside(sample)
        tracker.ingest(now, outside: lastSampleOutside)
        onTick?()
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in
            self.lastLocation = last
            UserDefaults.standard.set(last.coordinate.latitude, forKey: "lastLat")
            UserDefaults.standard.set(last.coordinate.longitude, forKey: "lastLon")
            self.onLocation?(last)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.onAuthorization?() }
    }

    var onLocation: ((CLLocation) -> Void)?
    var onAuthorization: (() -> Void)?

    /// Last coordinate seen in any session, persisted for daylight math.
    static var savedCoordinate: (Double, Double)? {
        let d = UserDefaults.standard
        guard d.object(forKey: "lastLat") != nil else { return nil }
        return (d.double(forKey: "lastLat"), d.double(forKey: "lastLon"))
    }
}

extension MotionKind {
    init(_ a: CMMotionActivity) {
        if a.automotive { self = .automotive }
        else if a.running { self = .running }
        else if a.cycling { self = .cycling }
        else if a.walking { self = .walking }
        else if a.stationary { self = .stationary }
        else { self = .unknown }
    }
}

import CoreLocation
import Foundation
import GrowCore
import Observation
import UIKit

enum ModelState: Equatable {
    case idle
    case downloading(Double)
    case ready
    case composing
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Gemma not loaded"
        case .downloading(let p): p < 0.999 ? "Getting Gemma \(Int(p * 100))%" : "Loading Gemma"
        case .ready: "Gemma ready, on device"
        case .composing: "Gemma is composing"
        case .failed: "Gemma unavailable, using built-in songs"
        }
    }
}

enum Activity: String { case run, walk }

@MainActor
@Observable
final class AppModel {
    // Services
    @ObservationIgnored let store: DayStore
    @ObservationIgnored let composer = GemmaComposer()
    @ObservationIgnored let audio = AudioEngine()
    @ObservationIgnored let live = LiveSession()
    @ObservationIgnored let health = HealthDaylight()
    @ObservationIgnored let link = WatchLink()
    @ObservationIgnored let recorder = FieldRecorder()

    // Day data
    var today: DayRecord
    var week: [DayRecord] = []

    // Session
    var activity: Activity?
    var sessionStart: Date?
    var sessionMinutes: Double = 0
    var baselineMinutes: Double = 0
    var isOutsideNow = false
    var distanceKm: Double = 0
    var cadence: Double?

    // Playback
    var isPlaying = false
    var playingDay: String?
    var unlocked: Set<Layer> = [.drone]
    var announcement: String?
    var isCapturing = false
    var exportURL: URL?
    var isExporting = false

    // Model
    var modelState: ModelState = .idle
    var lastComposeInfo: String?

    // Settings
    var targetMinutes: Double { didSet { UserDefaults.standard.set(targetMinutes, forKey: "targetMinutes"); refreshLayers() } }
    var testMode: Bool { didSet { UserDefaults.standard.set(testMode, forKey: "testMode"); live.classifier.testMode = testMode } }
    var strideSync: Bool { didSet { UserDefaults.standard.set(strideSync, forKey: "strideSync") } }
    var hasHome: Bool

    @ObservationIgnored private var fieldSamples: [Float]?
    @ObservationIgnored private var lastTempoChange = Date.distantPast
    @ObservationIgnored private var autoCaptured = false
    @ObservationIgnored private var pendingCompose: String?
    @ObservationIgnored private var pendingFieldNote: String?
    @ObservationIgnored private var storedSessionMinutesAtStart: Double = 0
    @ObservationIgnored private var lastSavedMinutes: Double = 0
    @ObservationIgnored private var didEstimateWithLocation = LiveSession.savedCoordinate != nil

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        store = DayStore(url: docs.appendingPathComponent("days.json"))
        let d = UserDefaults.standard
        targetMinutes = d.object(forKey: "targetMinutes") as? Double ?? 30
        testMode = d.bool(forKey: "testMode")
        strideSync = d.object(forKey: "strideSync") as? Bool ?? true
        hasHome = d.object(forKey: "homeLat") != nil
        today = store.record(DayKey.string(Date()))
        live.classifier.testMode = testMode
        if hasHome {
            live.home = CLLocation(latitude: d.double(forKey: "homeLat"), longitude: d.double(forKey: "homeLon"))
        }
        live.onTick = { [weak self] in self?.sessionTick() }
        live.onAuthorization = { [weak self] in self?.live.requestOneFix() }
        live.onLocation = { [weak self] _ in
            // First fix after install: now daylight math works, so estimate the past week.
            guard let self, !self.didEstimateWithLocation else { return }
            self.didEstimateWithLocation = true
            Task { await self.refreshHistory() }
        }
        audio.onRemoteToggle = { [weak self] in self?.togglePlay() }
        audio.onHeadphonesRemoved = { [weak self] in
            guard let self else { return }
            self.audio.stop(fadeSeconds: 0.2)
            self.isPlaying = false
            self.announcement = "Paused: headphones disconnected"
        }
        link.onCommand = { [weak self] cmd in self?.handleWatch(cmd) }
        link.activate()
        reloadDays()
    }

    var schedule: LayerSchedule { LayerSchedule(targetMinutes: targetMinutes) }
    var isSessionActive: Bool { activity != nil }
    var minutesNow: Double { isSessionActive ? baselineMinutes + sessionMinutes : today.minutes }
    var todaySpec: SongSpec { today.playableSpec }

    // MARK: Launch

    func onLaunch() async {
        live.requestOneFix()
        await refreshHistory()
        await prepareModel()
        if !today.composedByModel, !isSessionActive {
            await compose(activity: "day")
        }
    }

    func refreshHistory() async {
        // `-noHealth YES` launch argument skips the Health sheet for simulator smoke tests.
        if health.isAvailable, !UserDefaults.standard.bool(forKey: "noHealth"), await health.requestAccess() {
            let measured = await health.minutesByDay()
            for (day, m) in measured { store.update(day) { $0.measuredMinutes = m } }
        }
        let coord = LiveSession.savedCoordinate ?? live.knownLocation.map { ($0.coordinate.latitude, $0.coordinate.longitude) }
        if let (lat, lon) = coord {
            let estimated = await MotionHistory.minutesByDay(latitude: lat, longitude: lon)
            for (day, m) in estimated { store.update(day) { $0.estimatedMinutes = m } }
        }
        reloadDays()
    }

    func reloadDays() {
        today = store.record(DayKey.string(Date()))
        week = store.lastDays(7)
        refreshLayers()
    }

    func prepareModel() async {
        #if targetEnvironment(simulator)
        modelState = .failed("MLX needs a real device GPU; the simulator has none.")
        return
        #endif
        if case .ready = modelState { return }
        modelState = .downloading(0)
        do {
            try await composer.load { p in
                Task { @MainActor [weak self] in
                    if case .downloading = self?.modelState { self?.modelState = .downloading(p) }
                }
            }
            modelState = .ready
            log("model ready")
        } catch {
            modelState = .failed(String(describing: error))
            log("model failed: \(error)")
        }
    }

    // MARK: Composing

    /// Gemma needs the GPU, and iOS denies GPU work to background apps, so composing
    /// only happens while the app is on screen. Requests made in the background wait.
    func compose(activity: String) async {
        if case .failed = modelState { return }
        guard UIApplication.shared.applicationState == .active else {
            pendingCompose = activity
            return
        }
        if modelState == .composing { return }
        modelState = .composing
        // Keep the screen awake for the few seconds Gemma needs.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let recent = week.dropLast().map(\.minutes)
        let loc = live.knownLocation
        let sun = loc.map { Solar.elevation(at: Date(), latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        let ctx = ComposerContext(
            date: Date(), activity: activity, minutesToday: minutesNow, targetMinutes: targetMinutes,
            recentDays: Array(recent.suffix(6)), sunElevation: sun, stepsPerMinute: cadence)
        let result = await composer.compose(ctx)
        log("compose \(activity): model=\(result.fromModel) guided=\(result.guided) \(String(format: "%.1f", result.seconds))s \"\(result.spec.title)\" \(result.spec.key) \(result.spec.scale.rawValue) \(result.spec.bpm)bpm err=\(result.error ?? "-")")
        let loaded = await composer.isLoaded
        if result.fromModel || loaded {
            modelState = .ready
        } else {
            modelState = .failed(result.error ?? "Model did not load")
        }
        if result.fromModel {
            store.update(today.day) {
                $0.spec = result.spec
                $0.composedByModel = true
            }
            reloadDays()
            lastComposeInfo = String(format: "Composed in %.1fs%@", result.seconds, result.guided ? " (schema-guided)" : "")
        } else {
            lastComposeInfo = "Used built-in song: \(result.error ?? "no model output")"
        }
        if isPlaying, playingDay == today.day, result.fromModel {
            // During a session the new song comes in at the next phrase boundary and keeps
            // a stride-synced tempo; otherwise swap right away.
            let strideLocked = strideSync && self.activity == .run && lastTempoChange != .distantPast
            audio.renderer?.setSong(todaySpec, immediate: !isSessionActive, keepTempo: strideLocked)
            audio.updateNowPlaying(title: todaySpec.title, subtitle: layerSubtitle)
        }
        // Free ~1 GB while a session runs in the background; it reloads from disk in seconds.
        if isSessionActive { await composer.unload() }
        pushToWatch()
    }

    /// Runs work that had to wait for the app to come to the foreground.
    func becameActive() {
        if let a = pendingCompose {
            pendingCompose = nil
            Task { await compose(activity: a) }
        }
        if let prompt = pendingFieldNote {
            pendingFieldNote = nil
            Task { await writeFieldNote(prompt) }
        }
    }

    // MARK: Session

    func startSession(_ a: Activity) {
        guard !isSessionActive else { return }
        reloadDays()
        activity = a
        sessionStart = Date()
        baselineMinutes = today.minutes
        storedSessionMinutesAtStart = today.sessionMinutes
        lastSavedMinutes = 0
        lastTempoChange = .distantPast
        sessionMinutes = 0
        distanceKm = 0
        autoCaptured = false
        live.start()
        fieldSamples = loadTodayClip()
        unlocked = schedule.unlocked(minutes: minutesNow)
        playToday(immediate: true)
        Task {
            _ = await FieldRecorder.requestPermission()
            await compose(activity: a.rawValue)
        }
        pushToWatch()
    }

    func stopSession() {
        guard isSessionActive else { return }
        live.stop()
        let minutes = sessionMinutes
        let km = distanceKm
        let reached = schedule.highest(minutes: minutesNow)
        saveSessionProgress(final: true)
        store.update(today.day) { $0.distanceKm = ($0.distanceKm ?? 0) + km }
        activity = nil
        sessionStart = nil
        reloadDays()
        pushToWatch()

        let title = todaySpec.title
        let part = ComposerContext(date: Date(), activity: "day", minutesToday: 0, targetMinutes: 1, recentDays: []).partOfDay
        guard minutes >= 1 else { return }
        let prompt = PromptBuilder.fieldNotePrompt(
            minutes: minutes, distanceKm: km, layersReached: reached, songTitle: title, partOfDay: part)
        if UIApplication.shared.applicationState == .active {
            Task { await writeFieldNote(prompt) }
        } else {
            pendingFieldNote = prompt
        }
    }

    private func writeFieldNote(_ prompt: String) async {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        if let note = await composer.fieldNote(prompt: prompt) {
            store.update(today.day) { $0.fieldNote = note }
            reloadDays()
        }
    }

    /// Persists progress during the session so a crash or memory kill loses at most a minute.
    /// Stored as a day total so ending the session never drops layers you already heard.
    private func saveSessionProgress(final: Bool = false) {
        let m = sessionMinutes
        guard final || m - lastSavedMinutes >= 0.5 else { return }
        lastSavedMinutes = m
        let total = max(storedSessionMinutesAtStart + m, baselineMinutes + m)
        store.update(today.day) { $0.sessionMinutes = max($0.sessionMinutes, total) }
    }

    private func sessionTick() {
        sessionMinutes = live.tracker.minutes
        isOutsideNow = live.lastSampleOutside
        distanceKm = live.distanceMeters / 1000
        cadence = live.cadence

        let newUnlocked = schedule.unlocked(minutes: minutesNow)
        if newUnlocked != unlocked {
            let added = newUnlocked.subtracting(unlocked).max()
            unlocked = newUnlocked
            audio.setLayers(unlocked)
            if let added {
                log("unlock \(added.name) at \(String(format: "%.1f", minutesNow)) min")
                announcement = "\(added.name) unlocked"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                link.push(["event": "unlock", "layer": added.name])
            }
        }

        if strideSync, activity == .run, let spm = cadence, let bpm = CadenceTempo.bpm(stepsPerMinute: spm),
           Date().timeIntervalSince(lastTempoChange) > 20 {
            lastTempoChange = Date()
            audio.setTempo(bpm)
        }

        saveSessionProgress()

        // Grab a sound of the place once the walk is under way, if the phone is still in hand.
        if !autoCaptured, sessionMinutes >= 0.75, UIApplication.shared.applicationState == .active {
            autoCaptured = true
            Task { await captureSound() }
        }

        audio.updateNowPlaying(title: todaySpec.title, subtitle: layerSubtitle)
        pushToWatch()
    }

    var layerSubtitle: String {
        "\(unlocked.count) of \(Layer.allCases.count) layers · \(Int(minutesNow)) min outside"
    }

    // MARK: Field sound

    func captureSound() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        guard await FieldRecorder.requestPermission(), let clip = await recorder.record(seconds: 10) else {
            announcement = "Microphone unavailable"
            return
        }
        let prepared = FieldClip.prepare(clip.samples, inputRate: clip.rate, outputRate: audio.sampleRate)
        fieldSamples = prepared
        audio.setField(prepared)
        if let name = FieldRecorder.save(clip.samples, rate: clip.rate, day: today.day) {
            store.update(today.day) { $0.clipFile = name }
            reloadDays()
        }
        announcement = "Captured the sound of this place"
    }

    private func loadTodayClip() -> [Float]? {
        guard let name = today.clipFile, let clip = FieldRecorder.load(name) else { return nil }
        return FieldClip.prepare(clip.samples, inputRate: clip.rate, outputRate: audio.sampleRate)
    }

    // MARK: Playback

    func refreshLayers() {
        unlocked = schedule.unlocked(minutes: minutesNow)
        if isPlaying, playingDay == today.day { audio.setLayers(unlocked) }
    }

    func playToday(immediate: Bool = false) {
        playingDay = today.day
        if fieldSamples == nil { fieldSamples = loadTodayClip() }
        do {
            try audio.play(spec: todaySpec, layers: unlocked, field: fieldSamples, immediate: immediate)
            isPlaying = true
            audio.updateNowPlaying(title: todaySpec.title, subtitle: layerSubtitle)
        } catch {
            announcement = "Audio failed: \(error.localizedDescription)"
        }
    }

    func play(day: DayRecord) {
        playingDay = day.day
        let layers = schedule.unlocked(minutes: day.minutes)
        let field = day.clipFile.flatMap(FieldRecorder.load).map {
            FieldClip.prepare($0.samples, inputRate: $0.rate, outputRate: audio.sampleRate)
        }
        do {
            try audio.play(spec: day.playableSpec, layers: layers, field: field, immediate: true)
            isPlaying = true
            audio.updateNowPlaying(title: day.playableSpec.title, subtitle: "\(layers.count) of 6 layers · \(Int(day.minutes)) min outside")
        } catch {
            announcement = "Audio failed: \(error.localizedDescription)"
        }
    }

    func togglePlay() {
        if isPlaying {
            audio.stop()
            isPlaying = false
            playingDay = nil
        } else {
            playToday()
        }
    }

    func export(day: DayRecord) async {
        isExporting = true
        defer { isExporting = false }
        let layers = schedule.unlocked(minutes: day.minutes)
        let clip = day.clipFile.flatMap(FieldRecorder.load)
        let spec = day.playableSpec
        let seconds = Double(Sequencer.bars * 4) * 60 / Double(spec.bpm) * 2
        exportURL = try? await AudioEngine.export(
            spec: spec, layers: layers, clip: clip, seconds: seconds, name: "\(day.day) \(spec.title)")
    }

    // MARK: Settings

    func setHomeHere() {
        guard let loc = live.knownLocation else { return }
        UserDefaults.standard.set(loc.coordinate.latitude, forKey: "homeLat")
        UserDefaults.standard.set(loc.coordinate.longitude, forKey: "homeLon")
        live.home = loc
        hasHome = true
    }

    // MARK: Watch

    private func handleWatch(_ cmd: String) {
        switch cmd {
        case "start-run": startSession(.run)
        case "start-walk": startSession(.walk)
        case "stop": stopSession()
        case "capture": Task { await captureSound() }
        case "sync": pushToWatch()
        default: break
        }
    }

    func pushToWatch() {
        let next = schedule.next(minutes: minutesNow)
        link.push([
            "minutes": minutesNow,
            "target": targetMinutes,
            "layers": unlocked.count,
            "title": todaySpec.title,
            "active": isSessionActive,
            "activity": activity?.rawValue ?? "",
            "next": next?.layer.name ?? "",
            "nextIn": next?.remaining ?? 0,
            "outside": isOutsideNow,
        ])
    }
}

/// Console logging for `devicectl ... --console` during development.
func log(_ message: String) {
    print("[grow] \(Date().formatted(date: .omitted, time: .standard)) \(message)")
}

import AVFoundation
import Foundation
import GrowCore
import MediaPlayer

/// Plays a SongRenderer through AVAudioEngine. Keeps running with the screen locked.
@MainActor
final class AudioEngine {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private(set) var renderer: SongRenderer?
    private(set) var isPlaying = false
    private var fadeTask: Task<Void, Never>?

    var onRemoteToggle: (() -> Void)?
    var onHeadphonesRemoved: (() -> Void)?

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
                // Resume after calls and Siri. The song is a live stream, so resuming is always right.
                if type == .ended, self.isPlaying {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    try? self.engine.start()
                }
            }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                // AirPods out: stop rather than blast the song from a pocket speaker.
                guard let self, let reasonRaw,
                      AVAudioSession.RouteChangeReason(rawValue: reasonRaw) == .oldDeviceUnavailable,
                      self.isPlaying else { return }
                self.onHeadphonesRemoved?()
            }
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, !self.engine.isRunning else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                try? self.engine.start()
            }
        }
        setupRemoteCommands()
    }

    static func configureSession() throws {
        let s = AVAudioSession.sharedInstance()
        // playAndRecord so the field recorder can use the mic without switching categories mid-song.
        // A2DP keeps AirPods in high quality; the phone's own mic does the recording.
        try s.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .defaultToSpeaker])
        try s.setActive(true)
    }

    var sampleRate: Double {
        let sr = AVAudioSession.sharedInstance().sampleRate
        return sr > 0 ? sr : 48000
    }

    /// Starts (or retargets) playback. Layers fade in unless `immediate`.
    func play(spec: SongSpec, layers: Set<Layer>, field: [Float]?, immediate: Bool) throws {
        if let renderer, isPlaying {
            renderer.setSong(spec, immediate: immediate)
            renderer.setUnlocked(layers, immediate: immediate)
            if let field { renderer.setFieldClip(field) }
            return
        }
        try Self.configureSession()
        let sr = sampleRate
        let r = SongRenderer(spec: spec, sampleRate: sr)
        r.setUnlocked(layers, immediate: true)
        if let field { r.setFieldClip(field) }
        renderer = r

        if let old = source {
            engine.detach(old)
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard buffers.count >= 2,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let rr = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            r.render(frames: Int(frameCount), left: l, right: rr)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
        engine.mainMixerNode.outputVolume = 0
        try engine.start()
        isPlaying = true
        fade(to: 1, seconds: 1.5)
    }

    func setLayers(_ layers: Set<Layer>) { renderer?.setUnlocked(layers) }
    func setTempo(_ bpm: Double) { renderer?.setTempo(bpm) }
    func setField(_ samples: [Float]) { renderer?.setFieldClip(samples) }

    func stop(fadeSeconds: Double = 2) {
        guard isPlaying else { return }
        isPlaying = false
        fadeTask?.cancel()
        fadeTask = Task { [engine] in
            let steps = 20
            let startVol = engine.mainMixerNode.outputVolume
            for i in 0...steps {
                engine.mainMixerNode.outputVolume = startVol * (1 - Float(i) / Float(steps))
                try? await Task.sleep(for: .milliseconds(Int(fadeSeconds * 1000) / steps))
                if Task.isCancelled { return }
            }
            engine.stop()
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
    }

    private func fade(to target: Float, seconds: Double) {
        fadeTask?.cancel()
        fadeTask = Task { [engine] in
            let steps = 20
            let startVol = engine.mainMixerNode.outputVolume
            for i in 1...steps {
                engine.mainMixerNode.outputVolume = startVol + (target - startVol) * Float(i) / Float(steps)
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000) / steps))
                if Task.isCancelled { return }
            }
        }
    }

    // MARK: Now Playing (lock screen + AirPods controls)

    func updateNowPlaying(title: String, subtitle: String) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: subtitle,
            MPMediaItemPropertyAlbumTitle: "Grow a Song",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        for cmd in [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand] {
            cmd.isEnabled = true
            cmd.addTarget { [weak self] _ in
                MainActor.assumeIsolated { self?.onRemoteToggle?() }
                return .success
            }
        }
    }

    // MARK: Export

    /// Renders `seconds` of a song offline to a WAV file for sharing.
    nonisolated static func export(spec: SongSpec, layers: Set<Layer>, clip: (samples: [Float], rate: Double)?, seconds: Double, name: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let sr = 44100.0
            let r = SongRenderer(spec: spec, sampleRate: sr)
            r.setUnlocked(layers, immediate: true)
            if let clip { r.setFieldClip(FieldClip.prepare(clip.samples, inputRate: clip.rate, outputRate: sr)) }
            let (l, rr) = r.renderOffline(seconds: seconds)
            let safe = name.replacingOccurrences(of: "[^A-Za-z0-9 -]", with: "", options: .regularExpression)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).wav")
            try WAVWriter.data(left: l, right: rr, sampleRate: Int(sr)).write(to: url)
            return url
        }.value
    }
}

/// Records a short clip from the phone mic.
@MainActor
final class FieldRecorder {
    private(set) var isRecording = false

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Returns mono samples and their sample rate.
    func record(seconds: Double = 10) async -> (samples: [Float], rate: Double)? {
        guard !isRecording, AVAudioApplication.shared.recordPermission == .granted else { return nil }
        isRecording = true
        defer { isRecording = false }
        do { try AudioEngine.configureSession() } catch { return nil }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        let collector = SampleCollector(limit: Int(format.sampleRate * seconds))
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let ch = buffer.floatChannelData?[0] else { return }
            collector.append(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
        }
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            return nil
        }
        try? await Task.sleep(for: .seconds(seconds + 0.2))
        input.removeTap(onBus: 0)
        engine.stop()
        let samples = collector.samples
        return samples.count > 1000 ? (samples, format.sampleRate) : nil
    }

    /// Saves a clip as mono 16-bit WAV (duplicated to stereo) under Documents/clips.
    static func save(_ samples: [Float], rate: Double, day: String) -> String? {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("clips")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(day).wav"
        let data = WAVWriter.data(left: samples, right: samples, sampleRate: Int(rate))
        do {
            try data.write(to: dir.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
    }

    /// Loads a saved clip back as mono samples at 48 kHz-or-whatever rate it was saved with.
    static func load(_ name: String) -> (samples: [Float], rate: Double)? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("clips").appendingPathComponent(name)
        guard let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil,
              let ch = buf.floatChannelData?[0] else { return nil }
        return (Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength))), file.processingFormat.sampleRate)
    }
}

/// Thread-safe sample buffer for the mic tap.
final class SampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [Float] = []
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
        data.reserveCapacity(limit)
    }

    func append(_ chunk: UnsafeBufferPointer<Float>) {
        lock.lock(); defer { lock.unlock() }
        let room = limit - data.count
        guard room > 0 else { return }
        data.append(contentsOf: chunk.prefix(room))
    }

    var samples: [Float] {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

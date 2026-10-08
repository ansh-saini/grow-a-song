import GrowCore
import SwiftUI

struct TodayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                LayerRings(
                    unlocked: model.unlocked,
                    progress: model.schedule.progress(minutes: model.minutesNow),
                    pulsing: model.isPlaying && model.playingDay == model.today.day
                ) {
                    VStack(spacing: 2) {
                        Text("\(Int(model.minutesNow))")
                            .font(.system(size: 56, weight: .semibold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("of \(Int(model.targetMinutes)) min outside")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 300)
                .animation(.easeInOut(duration: 0.6), value: model.unlocked)

                nextLayer
                controls
                if let note = model.today.fieldNote { fieldNote(note) }
                footer
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .overlay(alignment: .top) { announcementBanner }
        .background(Theme.background.ignoresSafeArea())
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(Date().formatted(.dateTime.weekday(.wide).month().day()).uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Text(model.todaySpec.title)
                .font(.system(.title, design: .serif).weight(.semibold))
                .multilineTextAlignment(.center)
            Text(model.todaySpec.linerNote)
                .font(.subheadline)
                .italic()
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("\(model.todaySpec.key) \(model.todaySpec.scale.rawValue.replacingOccurrences(of: "_", with: " ")) · \(model.todaySpec.bpm) bpm · \(model.today.composedByModel ? "composed by Gemma" : "built-in")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var nextLayer: some View {
        if let next = model.schedule.next(minutes: model.minutesNow) {
            Label {
                Text("\(next.layer.name) in \(formatMinutes(next.remaining))")
            } icon: {
                Image(systemName: "leaf")
            }
            .font(.headline)
            .foregroundStyle(Theme.color(next.layer))
        } else {
            Label("Song complete. Every layer is playing.", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(Theme.accent)
        }
        if model.isSessionActive {
            HStack(spacing: 14) {
                Label(model.isOutsideNow ? "Counting" : "Not counting", systemImage: model.isOutsideNow ? "sun.max.fill" : "moon.zzz")
                    .foregroundStyle(model.isOutsideNow ? Theme.accent : .secondary)
                if model.distanceKm > 0.01 {
                    Label(String(format: "%.2f km", model.distanceKm), systemImage: "figure.run")
                }
                if let c = model.cadence, model.activity == .run {
                    Label("\(Int(c)) spm", systemImage: "metronome")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var controls: some View {
        if model.isSessionActive {
            VStack(spacing: 12) {
                if let start = model.sessionStart {
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        Text(Duration.seconds(ctx.date.timeIntervalSince(start)).formatted(.time(pattern: .minuteSecond)))
                            .font(.system(.title2, design: .monospaced))
                    }
                }
                HStack(spacing: 12) {
                    Button {
                        Task { await model.captureSound() }
                    } label: {
                        Label(model.isCapturing ? "Listening" : "Capture sound", systemImage: "waveform")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isCapturing)

                    Button(role: .destructive) {
                        model.stopSession()
                    } label: {
                        Label("End", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .controlSize(.large)
            }
        } else {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Button { model.startSession(.run) } label: {
                        Label("Start run", systemImage: "figure.run").frame(maxWidth: .infinity)
                    }
                    Button { model.startSession(.walk) } label: {
                        Label("Start walk", systemImage: "figure.walk").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.large)

                Button {
                    model.togglePlay()
                } label: {
                    Label(model.isPlaying ? "Pause" : "Play today's song", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    Task { await model.compose(activity: "day") }
                } label: {
                    Label("Recompose with Gemma", systemImage: "wand.and.stars")
                }
                .font(.footnote)
                .disabled(model.modelState != .ready)
            }
        }
    }

    private func fieldNote(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FIELD NOTE").font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
            Text(note).font(.system(.callout, design: .serif))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private var footer: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                if case .downloading(let p) = model.modelState {
                    ProgressView(value: p).frame(width: 80)
                } else if model.modelState == .composing {
                    ProgressView().controlSize(.mini)
                }
                Text(model.modelState.label)
            }
            if let info = model.lastComposeInfo { Text(info) }
            Text(model.today.isMeasured ? "Daylight measured by Apple Watch" : "Estimated from phone motion and GPS")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    @ViewBuilder private var announcementBanner: some View {
        if let text = model.announcement {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation { model.announcement = nil }
                }
        }
    }
}

func formatMinutes(_ m: Double) -> String {
    if m < 1 { return "\(max(1, Int((m * 60).rounded()))) s" }
    return "\(Int(m.rounded(.up))) min"
}

/// Six rings, one per layer. Inner is the drone, outer is the field recording.
struct LayerRings<Center: View>: View {
    var unlocked: Set<Layer>
    var progress: Double
    var pulsing: Bool
    @ViewBuilder var center: Center

    var body: some View {
        TimelineView(.animation(paused: !pulsing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let size = min(geo.size.width, geo.size.height)
                ZStack {
                    ForEach(Layer.allCases, id: \.self) { layer in
                        let i = CGFloat(layer.rawValue)
                        let diameter = size * (0.5 + i * 0.1)
                        let on = unlocked.contains(layer)
                        let wobble = pulsing && on ? 1 + 0.012 * sin(t * 2.2 + Double(i)) : 1
                        Circle()
                            .stroke(Theme.color(layer).opacity(on ? 0.9 : 0.12), style: StrokeStyle(lineWidth: on ? 9 : 3, lineCap: .round))
                            .frame(width: diameter, height: diameter)
                            .scaleEffect(wobble)
                            .shadow(color: on ? Theme.color(layer).opacity(0.5) : .clear, radius: on ? 6 : 0)
                    }
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(.white.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: size * 1.03, height: size * 1.03)
                    center
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

enum Theme {
    static let background = LinearGradient(
        colors: [Color(red: 0.05, green: 0.09, blue: 0.08), Color(red: 0.02, green: 0.03, blue: 0.04)],
        startPoint: .top, endPoint: .bottom)
    static let accent = Color(red: 0.45, green: 0.85, blue: 0.55)

    static func color(_ layer: Layer) -> Color {
        switch layer {
        case .drone: Color(red: 0.40, green: 0.55, blue: 0.95)
        case .pad: Color(red: 0.55, green: 0.45, blue: 0.95)
        case .bass: Color(red: 0.95, green: 0.45, blue: 0.55)
        case .drums: Color(red: 0.98, green: 0.65, blue: 0.30)
        case .melody: Color(red: 0.98, green: 0.88, blue: 0.40)
        case .field: Color(red: 0.45, green: 0.85, blue: 0.55)
        }
    }
}

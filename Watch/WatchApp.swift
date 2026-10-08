import SwiftUI

@main
struct GrowASongWatchApp: App {
    @State private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(model)
                .task { model.activate() }
        }
    }
}

struct WatchRootView: View {
    @Environment(WatchModel.self) private var model

    private let colors: [Color] = [
        Color(red: 0.40, green: 0.55, blue: 0.95), Color(red: 0.55, green: 0.45, blue: 0.95),
        Color(red: 0.95, green: 0.45, blue: 0.55), Color(red: 0.98, green: 0.65, blue: 0.30),
        Color(red: 0.98, green: 0.88, blue: 0.40), Color(red: 0.45, green: 0.85, blue: 0.55),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ZStack {
                    ForEach(0..<6, id: \.self) { i in
                        let on = i < model.layers
                        Circle()
                            .stroke(colors[i].opacity(on ? 0.95 : 0.15), lineWidth: on ? 5 : 2)
                            .frame(width: 44 + CGFloat(i) * 18, height: 44 + CGFloat(i) * 18)
                    }
                    VStack(spacing: 0) {
                        Text("\(Int(model.minutes))").font(.system(.title2, design: .rounded).weight(.semibold))
                        Text("of \(Int(model.target))").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 140)
                .animation(.easeInOut, value: model.layers)

                Text(model.title).font(.headline).multilineTextAlignment(.center)
                if !model.nextName.isEmpty {
                    Text("\(model.nextName) in \(max(1, Int(model.nextIn.rounded(.up)))) min")
                        .font(.footnote)
                        .foregroundStyle(colors[min(5, model.layers)])
                } else {
                    Text("Song complete").font(.footnote).foregroundStyle(colors[5])
                }

                if model.active {
                    Label(model.outside ? "Counting" : "Not counting", systemImage: model.outside ? "sun.max.fill" : "moon.zzz")
                        .font(.caption2)
                        .foregroundStyle(model.outside ? colors[5] : .secondary)
                    Button("Capture sound", systemImage: "waveform") { model.send("capture") }
                    Button("End", systemImage: "stop.fill", role: .destructive) { model.stop() }
                        .tint(.red)
                } else {
                    Button("Start run", systemImage: "figure.run") { model.start("run") }
                        .tint(colors[5])
                    Button("Start walk", systemImage: "figure.walk") { model.start("walk") }
                }
                if !model.reachable {
                    Text("Open Grow a Song on your iPhone").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

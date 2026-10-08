import GrowCore
import SwiftUI

struct WeekView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section {
                    chart
                        .frame(height: 140)
                        .listRowBackground(Color.clear)
                } footer: {
                    Text("Each day's song only grows as far as your time outside that day.")
                }

                Section("Songs") {
                    ForEach(model.week.reversed()) { day in
                        row(day)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Your week")
            .refreshable { await model.refreshHistory() }
            .sheet(item: Binding(get: { model.exportURL.map(ExportItem.init) }, set: { _ in model.exportURL = nil })) { item in
                ShareSheet(url: item.url)
            }
        }
    }

    private var chart: some View {
        GeometryReader { geo in
            let maxM = max(model.targetMinutes, model.week.map(\.minutes).max() ?? 1)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(model.week) { day in
                    let layers = model.schedule.unlocked(minutes: day.minutes)
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.color(layers.max() ?? .drone).gradient)
                            .frame(height: max(4, (geo.size.height - 24) * day.minutes / maxM))
                        Text(day.date?.formatted(.dateTime.weekday(.narrow)) ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.white.opacity(0.25))
                    .frame(height: 1)
                    .offset(y: -24 - (geo.size.height - 24) * model.targetMinutes / maxM)
            }
        }
    }

    private func row(_ day: DayRecord) -> some View {
        let layers = model.schedule.unlocked(minutes: day.minutes)
        let playing = model.isPlaying && model.playingDay == day.day
        return HStack(spacing: 12) {
            Button {
                if playing { model.togglePlay() } else { model.play(day: day) }
            } label: {
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(Theme.color(layers.max() ?? .drone))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(day.playableSpec.title).font(.headline)
                Text("\(day.date?.formatted(.dateTime.weekday(.wide)) ?? day.day) · \(Int(day.minutes)) min · \(layers.count)/6 layers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(day.isMeasured ? "Watch measured" : "Phone estimate")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                Task { await model.export(day: day) }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(model.isExporting)
        }
        .listRowBackground(Color.white.opacity(0.05))
    }
}

struct ExportItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

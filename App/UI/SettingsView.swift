import GrowCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Picker("Daily target", selection: $model.targetMinutes) {
                        ForEach([10.0, 20, 30, 45, 60, 90], id: \.self) { m in
                            Text("\(Int(m)) min").tag(m)
                        }
                    }
                } footer: {
                    Text("Layers unlock at 0, 8, 25, 42, 67 and 100 percent of your target.")
                }

                Section {
                    Toggle("Match tempo to my stride", isOn: $model.strideSync)
                } footer: {
                    Text("During runs the song speeds up or slows down to your cadence.")
                }

                Section {
                    Button(model.hasHome ? "Update home to here" : "Set home to here") { model.setHomeHere() }
                } footer: {
                    Text("Standing still only counts as outside when you are away from home and the GPS has a clear view of the sky.")
                }

                Section {
                    Toggle("Test mode (count every minute)", isOn: $model.testMode)
                } footer: {
                    Text("For trying the app indoors. Turn it off before a real walk.")
                }

                Section("Composer") {
                    LabeledContent("Model", value: GemmaComposer.modelName)
                    LabeledContent("Status", value: model.modelState.label)
                    if case .failed(let e) = model.modelState {
                        Text(e).font(.caption2).foregroundStyle(.secondary)
                        Button("Retry") { Task { await model.prepareModel() } }
                    }
                }

                Section("Privacy") {
                    Text("Location, motion, health data and your sound clips stay on this phone. Gemma runs on device with MLX. After the one-time model download, the app works offline.")
                        .font(.footnote)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Settings")
        }
    }
}

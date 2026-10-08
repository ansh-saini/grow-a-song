import SwiftUI

@main
struct GrowASongApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                TodayView()
                    .tabItem { Label("Today", systemImage: "leaf.fill") }
                WeekView()
                    .tabItem { Label("Week", systemImage: "calendar") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .tint(Theme.accent)
            .environment(model)
            .preferredColorScheme(.dark)
            .task { await model.onLaunch() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.becameActive() }
            }
        }
    }
}

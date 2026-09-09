import SwiftUI

@main
struct ChymeApp: App {
    @StateObject private var clock = ClockController()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            TabView(selection: $clock.tab) {
                NavigationStack { AlarmsView() }.tabItem { Label("Alarms", systemImage: "alarm.fill") }.tag("alarms")
                NavigationStack { TimersView() }.tabItem { Label("Timers", systemImage: "timer") }.tag("timers")
                NavigationStack { StopwatchView() }.tabItem { Label("Stopwatch", systemImage: "stopwatch.fill") }.tag("stopwatch")
                NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "gearshape") }.tag("settings")
            }
            .tint(.orange).environmentObject(clock)
            .onOpenURL { clock.open($0) }
            .task { await clock.refresh(quiet: true) }
            .onChange(of: phase) { _, value in if value == .active { Task { await clock.refresh(quiet: true) } } }
            .alert("Couldn’t Complete Change", isPresented: Binding(get: { clock.error != nil }, set: { if !$0 { clock.error = nil } })) {
                Button("OK") { clock.error = nil }
            } message: { Text(clock.error ?? "") }
        }
    }
}

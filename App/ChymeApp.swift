import SwiftUI

@main
struct ChymeApp: App {
    init() {
        EventLog.configure(url: "https://lbvaosyfikkpvcwksiph.supabase.co", apiKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxidmFvc3lmaWtrcHZjd2tzaXBoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzUwMDg0MDksImV4cCI6MjA5MDU4NDQwOX0.Gh9whjmUPz4rdKYr5yo8ZHS0nSNpkQUOwdIladX6mG4", project: "chyme")   // append-only event log (public.event_log)
    }
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

import SwiftUI

@main
struct ChymeWatchApp: App {
    @StateObject private var clock = ClockController()
    @StateObject private var connection = ChymeConnectivity.shared
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    NavigationLink(value: "timers") { Label("Timers", systemImage: "timer").foregroundStyle(.orange) }
                    NavigationLink(value: "alarms") { Label("Alarms", systemImage: "alarm.fill") }
                    NavigationLink(value: "stopwatch") { Label("Stopwatch", systemImage: "stopwatch.fill") }
                    NavigationLink(value: "settings") { Label("Settings", systemImage: "gearshape") }
                    Section {
                        Label(connection.reachable ? "iPhone Connected" : "iPhone Unavailable", systemImage: connection.reachable ? "iphone" : "iphone.slash")
                            .font(.caption).foregroundStyle(.secondary)
                        if let date = clock.lastSync { Text("Updated \(date.formatted(date: .omitted, time: .shortened))").font(.caption2) }
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await clock.refresh() } }.disabled(clock.busy)
                    }
                }.navigationTitle("Chymee")
                .navigationDestination(for: String.self) { destination in screen(destination) }
                .sheet(isPresented: Binding(get: { clock.tab != "home" }, set: { if !$0 { clock.tab = "home" } })) {
                    NavigationStack {
                        screen(clock.tab)
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { clock.tab = "home" } } }
                    }.environmentObject(clock)
                }
            }
            .tint(.orange).environmentObject(clock)
            .onOpenURL { clock.open($0) }
            .task { await clock.refresh(quiet: true) }
            .onChange(of: phase) { _, value in if value == .active { Task { await clock.refresh(quiet: true) } } }
            .onChange(of: connection.reachable) { _, value in if value { Task { await clock.refresh(quiet: true) } } }
            .alert("iPhone Confirmation Needed", isPresented: Binding(get: { clock.error != nil }, set: { if !$0 { clock.error = nil } })) {
                Button("OK") { clock.error = nil }
            } message: { Text(clock.error ?? "") }
        }
    }
    @ViewBuilder private func screen(_ destination: String) -> some View {
        switch destination {
        case "alarms": AlarmsView()
        case "stopwatch": StopwatchView()
        case "settings": SettingsView()
        default: TimersView()
        }
    }
}

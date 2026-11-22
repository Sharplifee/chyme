import SwiftUI
import WatchKit

@main
struct ChymeWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @StateObject private var clock = ClockController()
    @StateObject private var engine = WatchEngine.shared
    @Environment(\.scenePhase) private var phase

    init() {
        EventLog.configure(url: "https://lbvaosyfikkpvcwksiph.supabase.co", apiKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxidmFvc3lmaWtrcHZjd2tzaXBoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzUwMDg0MDksImV4cCI6MjA5MDU4NDQwOX0.Gh9whjmUPz4rdKYr5yo8ZHS0nSNpkQUOwdIladX6mG4", project: "chyme")   // append-only event log (public.event_log)
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    NavigationLink(value: "timers") { row("Timers", "timer", detail: timerDetail).foregroundStyle(.orange) }
                    NavigationLink(value: "alarms") { row("Alarms", "alarm.fill", detail: alarmDetail) }
                    NavigationLink(value: "stopwatch") { row("Stopwatch", "stopwatch.fill", detail: nil) }
                    NavigationLink(value: "settings") { row("Settings", "gearshape", detail: nil) }
                    Section {
                        Label("Runs on this watch. iPhone not needed.", systemImage: "applewatch")
                            .font(.caption2).foregroundStyle(.secondary)
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
            .overlay { if !engine.ringing.isEmpty { RingingView() } }
            .onOpenURL { clock.open($0) }
            .onChange(of: phase) { _, value in if value == .active { WatchEngine.shared.activated() } }
            .alert("Couldn’t Complete Change", isPresented: Binding(get: { clock.error != nil }, set: { if !$0 { clock.error = nil } })) {
                Button("OK") { clock.error = nil }
            } message: { Text(clock.error ?? "") }
        }
    }

    private var timerDetail: String? {
        let running = engine.timers.filter { !$0.isPaused }.count
        return engine.timers.isEmpty ? nil : (running == 0 ? "Paused" : "\(running) running")
    }
    private var alarmDetail: String? {
        let on = engine.alarms.filter(\.isEnabled).count
        return on == 0 ? nil : "\(on) on"
    }
    private func row(_ title: String, _ symbol: String, detail: String?) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
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

/// Covers the screen while something rings on this watch: what it is, when it
/// will stop by itself, and one big Stop.
struct RingingView: View {
    @ObservedObject private var engine = WatchEngine.shared
    var body: some View {
        let rings = engine.ringing.values.sorted { $0.startedAt < $1.startedAt }
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 8) {
                Image(systemName: "bell.and.waves.left.and.right.fill").font(.title2).foregroundStyle(.orange)
                Text(rings.map(\.label).joined(separator: ", ")).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                if let first = rings.first {
                    if first.untilStopped {
                        Text("Rings until stopped").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("Stops by itself in \(Text(timerInterval: Date()...max(Date(), first.stopAt), countsDown: true))")
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Button { engine.stopAll() } label: {
                    Text("Stop").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).tint(.orange)
            }.padding()
        }
        .accessibilityAddTraits(.isModal)
    }
}

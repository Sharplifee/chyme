import SwiftUI
import Combine

@MainActor
final class ClockController: ObservableObject {
    @Published var snapshot = ClockSnapshot(alarms: ChymeStore().loadAlarms(), timers: ChymeStore().loadTimers())
    @Published var busy = false
    @Published var error: String?
    @Published var lastSync: Date?
    @Published var tab = "timers"
    @Published var suggestedDuration: Int?

    init() {
        let link = ChymeConnectivity.shared
        #if os(watchOS)
        tab = "home"
        lastSync = UserDefaults.standard.object(forKey: "clock.snapshotDate") as? Date
        link.receiveSnapshot = { [weak self] in self?.accept($0) }
        #else
        let engine = AlarmEngine.shared
        engine.onChange = { [weak self] in self?.accept($0) }
        link.execute = { await engine.perform($0) }
        link.onActivation = { engine.refresh() }
        engine.start()
        #endif
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--qa-screen"), arguments.indices.contains(index + 1),
           ["timers", "alarms", "stopwatch", "settings"].contains(arguments[index + 1]) {
            tab = arguments[index + 1]
        }
        #endif
    }
    private func accept(_ value: ClockSnapshot) {
        guard lastSync == nil || value.date >= lastSync! else { return }
        snapshot = value; lastSync = value.date
        ChymeStore().save(alarms: value.alarms); ChymeStore().save(timers: value.timers)
    }
    @discardableResult func send(_ command: ClockCommand) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        #if os(watchOS)
        let reply = await ChymeConnectivity.shared.request(command)
        #else
        let reply = await AlarmEngine.shared.perform(command)
        #endif
        if let snapshot = reply.snapshot { accept(snapshot) }
        if let message = reply.error { error = message; return false }
        return true
    }
    func refresh(quiet: Bool = false) async {
        #if os(watchOS)
        if quiet && !ChymeConnectivity.shared.reachable { return }
        #endif
        _ = await send(ClockCommand(action: "sync"))
    }
    func open(_ url: URL) {
        guard url.scheme == "chymee" else { return }
        let destination = url.host ?? "timers"
        if ["timers", "alarms", "stopwatch", "settings"].contains(destination) { tab = destination }
        if destination == "timers", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let raw = components.queryItems?.first(where: { $0.name == "seconds" })?.value,
           let seconds = Int(raw), (1...86399).contains(seconds) { suggestedDuration = seconds }
    }
}

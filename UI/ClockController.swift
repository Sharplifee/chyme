import SwiftUI
import Combine

@MainActor
final class ClockController: ObservableObject {
    /// This device's own alarms and timers. Nothing here is read from the other device.
    @Published var snapshot = ClockSnapshot(alarms: [], timers: [])
    @Published var busy = false
    @Published var error: String?
    @Published var lastSync: Date?
    @Published var tab = "timers"
    @Published var suggestedDuration: Int?

    init() {
        let link = ChymeConnectivity.shared
        #if os(watchOS)
        tab = "home"
        let engine = WatchEngine.shared
        engine.onChange = { [weak self] in self?.accept($0) }
        link.onLinked = { _ = await engine.perform($0) }
        engine.start()
        #else
        let engine = AlarmEngine.shared
        engine.onChange = { [weak self] in self?.accept($0) }
        link.onLinked = { _ = await engine.perform($0) }
        engine.start()
        #endif
        snapshot = engine.snapshot
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--qa-screen"), arguments.indices.contains(index + 1),
           ["timers", "alarms", "stopwatch", "settings"].contains(arguments[index + 1]) {
            tab = arguments[index + 1]
        }
        #endif
    }
    private func accept(_ value: ClockSnapshot) {
        snapshot = value; lastSync = value.date
    }
    @discardableResult func send(_ command: ClockCommand) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        #if os(watchOS)
        let reply = await WatchEngine.shared.perform(command)
        #else
        let reply = await AlarmEngine.shared.perform(command)
        #endif
        if let snapshot = reply.snapshot { accept(snapshot) }
        if let message = reply.error { error = message; return false }
        return true
    }
    func refresh(quiet: Bool = false) async {
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

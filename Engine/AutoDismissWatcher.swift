import AlarmKit
import Combine
import Foundation
import UIKit

/// Best-effort stop execution. iOS does not guarantee runtime at an alarm's deadline.
@MainActor
final class AutoDismissWatcher: ObservableObject {
    static let shared = AutoDismissWatcher()
    @Published private(set) var events: [String] = UserDefaults.standard.stringArray(forKey: "autoStop.events") ?? []
    private var deadlines: [String: Date] = UserDefaults.standard.dictionary(forKey: "autoStop.deadlines") as? [String: Date] ?? [:]
    private var observation: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    private var stoppers: [UUID: Task<Void, Never>] = [:]
    private var runtime: [UUID: UIBackgroundTaskIdentifier] = [:]
    private var policyLookup: (@Sendable (UUID) -> AutoDismiss?)?

    func start(policyLookup: @escaping @Sendable (UUID) -> AutoDismiss?) {
        self.policyLookup = policyLookup
        guard observation == nil else { return }
        record("Monitor started; saved deadlines: \(deadlines.count)")
        refresh()
        observation = Task {
            for await alarms in AlarmManager.shared.alarmUpdates { handle(alarms) }
        }
        // Belt and braces: while the keep-alive holds the process up, poll the
        // system every half second so a ringing alert is caught even if the
        // update stream is late in the background.
        poller = Task {
            while !Task.isCancelled {
                // Tight loop only while an alert is ringing; otherwise a relaxed
                // 2s cadence is plenty to catch the transition into .alerting
                // (a 1s cutoff still lands within ~2.5s of ring start, and the
                // alarmUpdates stream normally beats the poll anyway).
                let active = !deadlines.isEmpty
                try? await Task.sleep(for: .milliseconds(active ? 250 : 2000))
                if KeepAlive.shared.running || active { refresh() }
            }
        }
    }

    func refresh() {
        guard policyLookup != nil else { return }
        do { handle(try AlarmManager.shared.alarms) }
        catch { record("Could not read system alarms: \(error.localizedDescription)") }
    }

    private func handle(_ alarms: [Alarm]) {
        let alerting = Set(alarms.filter { $0.state == .alerting }.map(\.id))
        for key in Array(deadlines.keys) {
            guard let id = UUID(uuidString: key), !alerting.contains(id) else { continue }
            deadlines[key] = nil
            stoppers.removeValue(forKey: id)?.cancel()
            endRuntime(id)
        }
        persist()
        for id in alerting where stoppers[id] == nil {
            // A system update may arrive before the scheduling transaction saves its policy.
            // Do not mark the alert as handled until the policy is available.
            guard let policy = policyLookup?(id), policy.isEnabled else { continue }
            let deadline: Date
            if let saved = deadlines[id.uuidString] {
                deadline = saved
            } else {
                // Anchor on when the alert actually began, not when we first saw it.
                // Timers know their fire time; alarms fire at a wall-clock minute, so
                // round back to the start of the current minute if we're mid-minute.
                let timerEnd = ChymeStore().loadTimers().first { $0.id == id }?.endsAt
                let now = Date()
                let start: Date
                if let timerEnd { start = min(timerEnd, now) }
                else if ChymeStore().loadAlarms().contains(where: { $0.id == id }) {
                    start = Calendar.current.date(bySetting: .second, value: 0, of: now) ?? now
                } else { start = now }
                deadline = start.addingTimeInterval(Double(policy.seconds))
                deadlines[id.uuidString] = deadline
                persist()
                record("Alert \(id): stop after \(policy.seconds)s; deadline \(deadline.ISO8601Format()); app state \(UIApplication.shared.applicationState.rawValue)")
            }
            stoppers[id] = Task { await stop(id, at: deadline) }
        }
    }

    private func stop(_ id: UUID, at deadline: Date) async {
        defer {
            stoppers[id] = nil
            endRuntime(id)
        }
        let delay = max(0, deadline.timeIntervalSinceNow)
        do {
            // Background tasks are bounded; do not consume a task for a long idle wait.
            if delay > 20 { try await Task.sleep(for: .seconds(delay - 20)) }
            // Short cutoffs (1-5s): skip straight to the stop loop below.
            guard !Task.isCancelled else { return }
            runtime[id] = UIApplication.shared.beginBackgroundTask(withName: "Finish alarm stop") { @Sendable [weak self] in
                Task { @MainActor in
                    self?.record("Background runtime expired before stop completed: \(id)")
                    self?.endRuntime(id)
                }
            }
            if runtime[id] == .invalid { record("Background runtime unavailable: \(id)") }
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 { try await Task.sleep(for: .milliseconds(Int(remaining * 1000))) }
            for attempt in 1...5 {
                try Task.checkCancellation()
                do {
                    guard try AlarmManager.shared.alarms.contains(where: { $0.id == id && $0.state == .alerting }) else {
                        deadlines[id.uuidString] = nil; persist()
                        record("Alert already stopped: \(id)")
                        return
                    }
                    try AlarmManager.shared.stop(id: id)
                    deadlines[id.uuidString] = nil; persist()
                    record("System accepted stop: \(id); lateness \(max(0, Date().timeIntervalSince(deadline)))s")
                    return
                } catch {
                    record("Stop attempt \(attempt) failed for \(id): \(error.localizedDescription)")
                    if attempt < 5 { try await Task.sleep(for: .milliseconds(400)) }
                }
            }
        } catch is CancellationError {
            // System state changed, or the observation was superseded.
        } catch { record("Stop task failed for \(id): \(error.localizedDescription)") }
    }

    private func endRuntime(_ id: UUID) {
        if let token = runtime.removeValue(forKey: id), token != .invalid {
            UIApplication.shared.endBackgroundTask(token)
        }
    }
    private func persist() { UserDefaults.standard.set(deadlines, forKey: "autoStop.deadlines") }
    func record(_ message: String) {
        events.append("\(Date().ISO8601Format())  \(message)")
        if events.count > 100 { events.removeFirst(events.count - 100) }
        UserDefaults.standard.set(events, forKey: "autoStop.events")
    }
}

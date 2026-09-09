import Foundation
import Combine
#if canImport(AlarmKit)
import AlarmKit
import ActivityKit
#endif

@MainActor
public final class AlarmEngine: ObservableObject {
    public static let shared = AlarmEngine()
    @Published public private(set) var alarms: [ChymeAlarm]
    @Published public private(set) var timers: [ChymeTimer]
    private let store = ChymeStore()
    private var observation: Task<Void, Never>?
    private var activityObservation: Task<Void, Never>?
    private var activityTasks: [String: Task<Void, Never>] = [:]
    private var replies: [UUID: ClockReply] = [:]
    private var processing: Set<UUID> = []
    private var knownStates: [UUID: String] = [:]

    private init() {
        alarms = store.loadAlarms()
        timers = store.loadTimers()
    }
    public var snapshot: ClockSnapshot { ClockSnapshot(alarms: alarms, timers: timers) }
    public var onChange: ((ClockSnapshot) -> Void)?

    public func start() {
        guard observation == nil else { return }
        #if canImport(AlarmKit)
        AutoDismissWatcher.shared.start { id in
            let store = ChymeStore()
            return store.loadAlarms().first { $0.id == id }?.autoDismiss
                ?? store.loadTimers().first { $0.id == id }?.autoDismiss
        }
        for activity in Activity<AlarmAttributes<ChymeMetadata>>.activities { observe(activity) }
        activityObservation = Task {
            for await activity in Activity<AlarmAttributes<ChymeMetadata>>.activityUpdates { observe(activity) }
        }
        observation = Task {
            for await current in AlarmManager.shared.alarmUpdates { reconcile(current) }
        }
        #endif
        publish()
    }
    private func publish() {
        store.save(alarms: alarms); store.save(timers: timers)
        onChange?(snapshot)
        ChymeConnectivity.shared.publish(snapshot)
    }
    public func refresh() {
        #if canImport(AlarmKit)
        if let current = (try? AlarmManager.shared.alarms) { reconcile(current) }
        for activity in Activity<AlarmAttributes<ChymeMetadata>>.activities { apply(activity.content.state) }
        #endif
        publish()
    }
    public func perform(_ command: ClockCommand) async -> ClockReply {
        if let reply = replies[command.requestID] { return reply }
        guard processing.insert(command.requestID).inserted else {
            return ClockReply(error: "This change is already being processed. Refresh in a moment.")
        }
        defer { processing.remove(command.requestID) }
        do {
            switch command.action {
            case "sync": refresh()
            case "saveAlarm":
                guard var alarm = command.alarm, (0..<1440).contains(alarm.minuteOfDay),
                      alarm.repeatDays.allSatisfy({ (1...7).contains($0) }) else { throw ClockError.invalid }
                alarm.soundName = ChymeSound.resolved(alarm.soundName)
                if alarm.isEnabled {
                    try await authorize()
                    #if canImport(AlarmKit)
                    try await AlarmKitBridge.scheduleFixed(id: alarm.id, hour: alarm.hour, minute: alarm.minute,
                        weekdays: alarm.repeatDays, label: alarm.label, sound: alarm.soundName, allowSnooze: alarm.snoozeEnabled)
                    #endif
                } else { try cancel(alarm.id) }
                alarms.removeAll { $0.id == alarm.id }; alarms.append(alarm)
                alarms.sort { $0.minuteOfDay < $1.minuteOfDay }
            case "deleteAlarm":
                guard let id = command.id else { throw ClockError.invalid }
                try cancel(id); alarms.removeAll { $0.id == id }
            case "startTimer":
                guard var timer = command.timer, timer.duration.isFinite, timer.duration >= 1,
                      timer.duration <= 86399 else { throw ClockError.invalid }
                try await authorize()
                timer.soundName = ChymeSound.resolved(timer.soundName)
                timer.endsAt = .now.addingTimeInterval(timer.duration); timer.pausedRemaining = nil
                #if canImport(AlarmKit)
                try await AlarmKitBridge.scheduleCountdown(id: timer.id, duration: timer.duration, label: timer.label, sound: timer.soundName)
                #endif
                timers.removeAll { $0.id == timer.id }; timers.append(timer)
            case "cancelTimer":
                guard let id = command.id else { throw ClockError.invalid }
                try cancel(id); timers.removeAll { $0.id == id }
            case "pauseTimer", "resumeTimer":
                guard let id = command.id, let index = timers.firstIndex(where: { $0.id == id }) else { throw ClockError.invalid }
                #if canImport(AlarmKit)
                if command.action == "pauseTimer" {
                    try AlarmManager.shared.pause(id: id)
                    timers[index].pausedRemaining = timers[index].remaining()
                    timers[index].endsAt = nil
                } else {
                    let remaining = timers[index].remaining()
                    try AlarmManager.shared.resume(id: id)
                    timers[index].endsAt = .now.addingTimeInterval(remaining)
                    timers[index].pausedRemaining = nil
                }
                #endif
            default: throw ClockError.invalid
            }
            publish()
            let reply = ClockReply(snapshot: snapshot)
            if replies.count > 100 { replies.removeAll() }
            replies[command.requestID] = reply
            return reply
        } catch { return ClockReply(snapshot: snapshot, error: error.localizedDescription) }
    }
    private func authorize() async throws {
        #if canImport(AlarmKit)
        if AlarmManager.shared.authorizationState == .notDetermined {
            _ = try await AlarmManager.shared.requestAuthorization()
        }
        guard AlarmManager.shared.authorizationState == .authorized else { throw ClockError.permission }
        #else
        throw ClockError.unavailable
        #endif
    }
    private func cancel(_ id: UUID) throws {
        #if canImport(AlarmKit)
        let active = try AlarmManager.shared.alarms
        if active.contains(where: { $0.id == id }) { try AlarmManager.shared.cancel(id: id) }
        #endif
    }
    #if canImport(AlarmKit)
    private func observe(_ activity: Activity<AlarmAttributes<ChymeMetadata>>) {
        guard activityTasks[activity.id] == nil else { return }
        apply(activity.content.state)
        activityTasks[activity.id] = Task {
            for await content in activity.contentUpdates {
                apply(content.state)
                publish()
            }
            activityTasks[activity.id] = nil
        }
    }
    /// System countdown state remains authoritative after Lock Screen/Watch actions.
    private func apply(_ state: AlarmPresentationState) {
        guard let index = timers.firstIndex(where: { $0.id == state.alarmID }) else { return }
        switch state.mode {
        case .countdown(let value):
            timers[index].endsAt = value.fireDate
            timers[index].pausedRemaining = nil
        case .paused(let value):
            timers[index].pausedRemaining = max(0, value.totalCountdownDuration - value.previouslyElapsedDuration)
            timers[index].endsAt = nil
        case .alert:
            timers[index].endsAt = .now
            timers[index].pausedRemaining = nil
        @unknown default: break
        }
    }

    private func reconcile(_ current: [Alarm]) {
        let ids = Set(current.map(\.id))
        timers.removeAll { !ids.contains($0.id) }
        for index in alarms.indices where alarms[index].isEnabled && !ids.contains(alarms[index].id) {
            alarms[index].isEnabled = false
        }
        for alarm in current {
            guard let index = timers.firstIndex(where: { $0.id == alarm.id }) else { continue }
            let previous = knownStates[alarm.id]
            switch alarm.state {
            case .paused:
                if !timers[index].isPaused {
                    timers[index].pausedRemaining = timers[index].remaining(); timers[index].endsAt = nil
                }
                knownStates[alarm.id] = "paused"
            case .countdown:
                if timers[index].isPaused {
                    timers[index].endsAt = .now.addingTimeInterval(timers[index].remaining())
                    timers[index].pausedRemaining = nil
                } else if previous == "alerting" {
                    timers[index].endsAt = .now.addingTimeInterval(300)
                }
                knownStates[alarm.id] = "countdown"
            case .alerting:
                timers[index].endsAt = .now; timers[index].pausedRemaining = nil
                knownStates[alarm.id] = "alerting"
            default: break
            }
        }
        for activity in Activity<AlarmAttributes<ChymeMetadata>>.activities { apply(activity.content.state) }
        publish()
    }
    #endif
}

enum ClockError: LocalizedError {
    case permission, unavailable, invalid
    var errorDescription: String? {
        switch self {
        case .permission: return "Allow alarms for Chymee in iPhone Settings, then try again. Nothing was scheduled."
        case .unavailable: return "System alarms require a supported iPhone or iPad."
        case .invalid: return "This item is no longer available, or its time is invalid. Refresh and try again."
        }
    }
}

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
    /// Recently cancelled ids, so a late duplicate from the watch can't revive one.
    private var cancelled: [UUID] = []
    private var intentObserver: NSObjectProtocol?

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
            // Any alert we own uses its own cutoff; anything else that is ours
            // (e.g. a stopwatch alert whose record was reset) falls back to the
            // device default so nothing of ours can ever ring unbounded.
            return store.loadAlarms().first { $0.id == id }?.autoDismiss
                ?? store.loadTimers().first { $0.id == id }?.autoDismiss
                ?? store.defaultAutoDismiss
        }
        purgeOrphanedSystemAlarms()
        intentObserver = NotificationCenter.default.addObserver(forName: ChymeIntentSignal.name, object: nil, queue: .main) { note in
            guard let action = note.userInfo?["action"] as? String,
                  let id = (note.userInfo?["id"] as? String).flatMap(UUID.init(uuidString:)) else { return }
            Task { @MainActor in AlarmEngine.shared.mirrorIntent(action, id) }
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
    /// Hold the process up only while something can ring with an auto-stop.
    private var needsKeepAlive: Bool {
        alarms.contains { $0.isEnabled && $0.autoDismiss.isEnabled }
            || timers.contains { $0.autoDismiss.isEnabled }
    }

    private func publish() {
        store.save(alarms: alarms); store.save(timers: timers)
        KeepAlive.shared.update(needed: needsKeepAlive)
        AutoDismissWatcher.shared.refresh()
        onChange?(snapshot)
    }
    /// A Lock Screen or Dynamic Island button acted on one of our alerts.
    /// If that item lives on both devices, do the same on the watch.
    private func mirrorIntent(_ action: String, _ id: UUID) {
        EventLog.action("ios.alert." + action, ["id": id.uuidString])
        if let timer = timers.first(where: { $0.id == id }) {
            guard timer.isLinked else { return }
            switch action {
            case "pause": ChymeConnectivity.shared.sendLinked(ClockCommand(action: "pauseTimer", id: id))
            case "resume": ChymeConnectivity.shared.sendLinked(ClockCommand(action: "resumeTimer", id: id))
            default: ChymeConnectivity.shared.sendLinked(ClockCommand(action: "cancelTimer", id: id))
            }
        } else if alarms.first(where: { $0.id == id })?.isLinked == true, action == "stop" {
            ChymeConnectivity.shared.sendLinked(ClockCommand(action: "stopAlert", id: id))
        }
    }
    /// Mirror a change to the watch — only for items the user marked Both Devices,
    /// and never for a change that itself came from the watch.
    private func mirror(_ command: ClockCommand, when linked: Bool, origin: ClockCommand) {
        guard linked, origin.remote != true else { return }
        ChymeConnectivity.shared.sendLinked(command)
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
        let remote = command.remote == true
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
                        weekdays: alarm.repeatDays, label: alarm.label, sound: alarm.soundName, allowSnooze: alarm.snoozeEnabled,
                        cutoffSeconds: alarm.autoDismiss.seconds)
                    // Detached: a stopper failure must never surface as
                    // "Couldn't Complete Change" on the user's save.
                    #endif
                } else { try cancel(alarm.id) }
                let wasLinked = alarms.first { $0.id == alarm.id }?.isLinked ?? false
                alarms.removeAll { $0.id == alarm.id }; alarms.append(alarm)
                alarms.sort { $0.minuteOfDay < $1.minuteOfDay }
                mirror(ClockCommand(action: "saveAlarm", alarm: alarm), when: alarm.isLinked || wasLinked, origin: command)
                EventLog.action("ios.alarm.save", ["id": alarm.id.uuidString, "enabled": alarm.isEnabled,
                                                   "cutoff": alarm.autoDismiss.seconds, "linked": alarm.isLinked, "remote": remote])
            case "deleteAlarm":
                guard let id = command.id else { throw ClockError.invalid }
                let wasLinked = alarms.first { $0.id == id }?.isLinked ?? false
                try cancel(id); alarms.removeAll { $0.id == id }
                mirror(ClockCommand(action: "deleteAlarm", id: id), when: wasLinked, origin: command)
                EventLog.action("ios.alarm.delete", ["id": id.uuidString, "linked": wasLinked, "remote": remote])
            case "startTimer":
                guard var timer = command.timer, timer.duration.isFinite, timer.duration >= 1,
                      timer.duration <= 86399 else { throw ClockError.invalid }
                var countdown = timer.duration
                if remote {
                    // A linked timer started on the watch: count down to the same end moment.
                    guard !cancelled.contains(timer.id), !timers.contains(where: { $0.id == timer.id }),
                          let end = timer.endsAt, end.timeIntervalSinceNow >= 1 else { break }
                    countdown = end.timeIntervalSinceNow
                }
                try await authorize()
                timer.soundName = ChymeSound.resolved(timer.soundName)
                timer.endsAt = .now.addingTimeInterval(countdown); timer.pausedRemaining = nil
                #if canImport(AlarmKit)
                try await AlarmKitBridge.scheduleCountdown(id: timer.id, duration: countdown, label: timer.label, sound: timer.soundName,
                                                           cutoffSeconds: timer.autoDismiss.seconds)
                #endif
                timers.removeAll { $0.id == timer.id }; timers.append(timer)
                mirror(ClockCommand(action: "startTimer", timer: timer), when: timer.isLinked, origin: command)
                EventLog.action("ios.timer.start", ["id": timer.id.uuidString, "seconds": Int(countdown),
                                                    "cutoff": timer.autoDismiss.seconds, "linked": timer.isLinked, "remote": remote])
            case "cancelTimer":
                guard let id = command.id else { throw ClockError.invalid }
                let wasLinked = timers.first { $0.id == id }?.isLinked ?? false
                try cancel(id); timers.removeAll { $0.id == id }
                cancelled.append(id)
                if cancelled.count > 60 { cancelled.removeFirst(30) }
                mirror(ClockCommand(action: "cancelTimer", id: id), when: wasLinked, origin: command)
                EventLog.action("ios.timer.cancel", ["id": id.uuidString, "linked": wasLinked, "remote": remote])
            case "pauseTimer", "resumeTimer":
                guard let id = command.id else { throw ClockError.invalid }
                guard let index = timers.firstIndex(where: { $0.id == id }) else {
                    if remote { break }
                    throw ClockError.invalid
                }
                // Already in the requested state (the watch and iPhone crossed): nothing to do.
                if (command.action == "pauseTimer") == timers[index].isPaused { break }
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
                mirror(ClockCommand(action: command.action, id: id), when: timers[index].isLinked, origin: command)
            case "stopAlert":
                // A linked alarm was silenced on the watch: silence it here too.
                guard let id = command.id else { throw ClockError.invalid }
                #if canImport(AlarmKit)
                try? AlarmManager.shared.stop(id: id)
                #endif
                EventLog.action("ios.alert.stop", ["id": id.uuidString, "remote": remote])
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
        Task { @MainActor in await SilentStopper.disarm(target: id) }
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
            timers[index].endsAt = min(timers[index].endsAt ?? .now, .now)
            timers[index].pausedRemaining = nil
        @unknown default: break
        }
    }

    /// Any AlarmKit alarm that isn't one of ours, or a stopper for one of ours, is a
    /// leak from an earlier build. Leaks count against AlarmKit's per-app limit and
    /// are why saving failed with "AlarmKit.Alarm error 0".
    private func purgeOrphanedSystemAlarms() {
        guard let current = try? AlarmManager.shared.alarms else { return }
        let owned = Set(alarms.filter(\.isEnabled).map(\.id)).union(timers.map(\.id))
        // Silent stoppers are retired (they never woke the app; they only added
        // a second alert). Anything not owned — including old stoppers — goes.
        for alarm in current where !owned.contains(alarm.id) {
            try? AlarmManager.shared.cancel(id: alarm.id)
        }
        SilentStopper.purge(existing: Set((try? AlarmManager.shared.alarms)?.map(\.id) ?? []))
    }

    private func reconcile(_ current: [Alarm]) {
        // A silent stopper reaching .alerting is the system handing us execution
        // time precisely when the real alert is ringing. Use it and get out.
        for alarm in current where alarm.state == .alerting && SilentStopper.isStopper(alarm.id) {
            SilentStopper.fire(stopperID: alarm.id)
        }
        let ids = Set(current.map(\.id))
        SilentStopper.purge(existing: ids)
        timers.removeAll { !ids.contains($0.id) }
        // A one-shot alarm disappears from AlarmKit once it has rung (or been
        // auto-stopped); mirror that in the UI so the toggle doesn't lie.
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
                timers[index].endsAt = min(timers[index].endsAt ?? .now, .now); timers[index].pausedRemaining = nil
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

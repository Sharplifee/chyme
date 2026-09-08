import Foundation
#if canImport(AlarmKit)
import AlarmKit
#endif

/// Single source of truth for scheduling. Runs on the phone (and Catalyst);
/// the watch drives it over WatchConnectivity rather than scheduling itself,
/// because AlarmKit has no watchOS target.
@MainActor
public final class AlarmEngine: ObservableObject {

    public static let shared = AlarmEngine()

    @Published public private(set) var alarms: [ChymeAlarm] = []
    @Published public private(set) var timers: [ChymeTimer] = []

    private var autoDismissWork: [UUID: Task<Void, Never>] = [:]
    private let store = ChymeStore()

    private init() {
        alarms = store.loadAlarms()
        timers = store.loadTimers()
    }

    // MARK: - Authorization

    public func ensureAuthorized() async -> Bool {
        #if canImport(AlarmKit)
        switch AlarmManager.shared.authorizationState {
        case .authorized:
            return true
        case .notDetermined:
            do {
                let state = try await AlarmManager.shared.requestAuthorization()
                return state == .authorized
            } catch {
                return false
            }
        default:
            return false
        }
        #else
        return false
        #endif
    }

    // MARK: - Alarms

    public func upsert(_ alarm: ChymeAlarm) async {
        if let i = alarms.firstIndex(where: { $0.id == alarm.id }) {
            alarms[i] = alarm
        } else {
            alarms.append(alarm)
        }
        alarms.sort { $0.minuteOfDay < $1.minuteOfDay }
        store.save(alarms: alarms)
        await reschedule(alarm)
    }

    public func delete(alarmID: UUID) async {
        alarms.removeAll { $0.id == alarmID }
        store.save(alarms: alarms)
        cancelAutoDismiss(for: alarmID)
        await cancelScheduled(id: alarmID)
    }

    public func setEnabled(_ enabled: Bool, alarmID: UUID) async {
        guard let i = alarms.firstIndex(where: { $0.id == alarmID }) else { return }
        alarms[i].isEnabled = enabled
        store.save(alarms: alarms)
        if enabled {
            await reschedule(alarms[i])
        } else {
            await cancelScheduled(id: alarmID)
        }
    }

    // MARK: - Timers

    /// The complication path: one call, already-known duration, starts immediately.
    @discardableResult
    public func startTimer(duration: TimeInterval,
                           autoDismiss: AutoDismiss = .fiveMinutes,
                           label: String = "Timer",
                           soundName: String = ChymeSound.default.name) async -> ChymeTimer? {
        guard await ensureAuthorized() else { return nil }
        let timer = ChymeTimer(label: label, duration: duration,
                               autoDismiss: autoDismiss, soundName: soundName)
        timers.append(timer)
        store.save(timers: timers)

        #if canImport(AlarmKit)
        do {
            try await scheduleCountdown(timer)
        } catch {
            timers.removeAll { $0.id == timer.id }
            store.save(timers: timers)
            return nil
        }
        #endif

        armAutoDismiss(id: timer.id, firesIn: duration, policy: autoDismiss)
        return timer
    }

    public func cancelTimer(_ id: UUID) async {
        timers.removeAll { $0.id == id }
        store.save(timers: timers)
        cancelAutoDismiss(for: id)
        await cancelScheduled(id: id)
    }

    // MARK: - Auto-dismiss

    /// Arms the stop that makes this app worth building: once the alarm starts
    /// sounding, wait `policy.seconds` and then stop it, whether or not anyone
    /// is there to touch it.
    private func armAutoDismiss(id: UUID, firesIn: TimeInterval, policy: AutoDismiss) {
        cancelAutoDismiss(for: id)
        guard policy.isEnabled else { return }
        let delay = firesIn + TimeInterval(policy.seconds)
        autoDismissWork[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.cancelScheduled(id: id)
            await MainActor.run { self?.autoDismissWork[id] = nil }
        }
    }

    private func cancelAutoDismiss(for id: UUID) {
        autoDismissWork[id]?.cancel()
        autoDismissWork[id] = nil
    }

    // MARK: - AlarmKit bridge

    private func reschedule(_ alarm: ChymeAlarm) async {
        await cancelScheduled(id: alarm.id)
        guard alarm.isEnabled, await ensureAuthorized() else { return }
        #if canImport(AlarmKit)
        try? await scheduleSchedule(alarm)
        #endif
        if let next = nextFireInterval(for: alarm) {
            armAutoDismiss(id: alarm.id, firesIn: next, policy: alarm.autoDismiss)
        }
    }

    public func nextFireInterval(for alarm: ChymeAlarm,
                                 from now: Date = Date(),
                                 calendar: Calendar = .current) -> TimeInterval? {
        var comps = DateComponents()
        comps.hour = alarm.hour
        comps.minute = alarm.minute
        comps.second = 0
        if alarm.repeatDays.isEmpty {
            guard let next = calendar.nextDate(after: now,
                                               matching: comps,
                                               matchingPolicy: .nextTime) else { return nil }
            return next.timeIntervalSince(now)
        }
        var best: Date?
        for weekday in alarm.repeatDays {
            var c = comps
            c.weekday = weekday
            if let d = calendar.nextDate(after: now, matching: c, matchingPolicy: .nextTime) {
                if best == nil || d < best! { best = d }
            }
        }
        return best.map { $0.timeIntervalSince(now) }
    }

    private func cancelScheduled(id: UUID) async {
        #if canImport(AlarmKit)
        try? AlarmManager.shared.cancel(id: id)
        #endif
    }

    #if canImport(AlarmKit)
    private func scheduleCountdown(_ timer: ChymeTimer) async throws {
        // Countdown-style AlarmKit alarm: fires `duration` from now.
        try await AlarmKitBridge.scheduleCountdown(id: timer.id,
                                                   duration: timer.duration,
                                                   label: timer.label,
                                                   sound: timer.soundName)
    }

    private func scheduleSchedule(_ alarm: ChymeAlarm) async throws {
        try await AlarmKitBridge.scheduleFixed(id: alarm.id,
                                               hour: alarm.hour,
                                               minute: alarm.minute,
                                               weekdays: alarm.repeatDays,
                                               label: alarm.label,
                                               sound: alarm.soundName,
                                               allowSnooze: alarm.snoozeEnabled)
    }
    #endif
}

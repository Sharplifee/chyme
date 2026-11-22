import Foundation
import WatchKit
import Combine
import UserNotifications
import WidgetKit

/// Read by the session's haptic repeat handler, which the system calls off the
/// main thread. When it goes false the handler returns 0 and the buzzing ends.
final class RingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isOn: Bool { lock.lock(); defer { lock.unlock() }; return on }
    func set(_ value: Bool) { lock.lock(); on = value; lock.unlock() }
}

/// While Chymee is on screen the engine rings by itself, so the backup
/// notification for the same moment stays quiet.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
}

/// Everything the watch does, it does here and by itself: its own alarms, any
/// number of its own timers, the stopwatch alert, ringing, and the automatic
/// stop at each item's "Stop Ringing After" time. The iPhone is never asked.
///
/// How an alert is delivered:
///  1. Chymee on screen: the engine sees the moment arrive and buzzes directly.
///  2. Chymee not on screen: watchOS starts the Smart Alarm session scheduled
///     for the next item, wakes the engine, and the engine buzzes through the
///     session until the cutoff, then ends the session. watchOS allows one
///     scheduled session, and only lets the app schedule it while on screen,
///     so the session always belongs to whichever item is due next.
///  3. Every item also has a local notification as a backup, so later items
///     still alert (one tap and tone, which ends by itself) even if the watch
///     never reopens Chymee to move the session forward.
@MainActor
final class WatchEngine: NSObject, ObservableObject {
    static let shared = WatchEngine()

    struct Ring: Equatable {
        var label: String
        var startedAt: Date
        var stopAt: Date
        var untilStopped: Bool
    }

    @Published private(set) var alarms: [ChymeAlarm] = []
    @Published private(set) var timers: [ChymeTimer] = []
    @Published private(set) var ringing: [UUID: Ring] = [:]
    var onChange: ((ClockSnapshot) -> Void)?
    var snapshot: ClockSnapshot { ClockSnapshot(alarms: alarms, timers: timers) }

    /// Next ring moment of every enabled alarm.
    private var alarmFire: [UUID: Date] = [:]
    /// Recently cancelled ids, so a late duplicate from the iPhone can't revive one.
    private var cancelled: [UUID] = []
    private var session: WKExtendedRuntimeSession?
    private var sessionItem: UUID?
    private var sessionTarget: Date?
    private var sessionNotifying = false
    private var sessionFailures = 0
    private let flag = RingFlag()
    private var loop: Task<Void, Never>?
    private var hapticLoop: Task<Void, Never>?
    private var started = false
    private var lastComplication: ComplicationState?
    private let defaults = UserDefaults.standard
    private static let presenter = NotificationPresenter()

    private enum Key {
        static let alarms = "watch.alarms.v2"
        static let timers = "watch.timers.v2"
        static let fires = "watch.alarmFire.v2"
        static let legacyTimer = "watch.localTimer"
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        load()
        UNUserNotificationCenter.current().delegate = Self.presenter
        Self.askPermission()
        check()
        reschedule()
        publishState()
        loop = Task { @MainActor in
            let engine = WatchEngine.shared
            while !Task.isCancelled {
                engine.check()
                let idle = engine.timers.isEmpty && engine.alarmFire.isEmpty && engine.ringing.isEmpty
                let wait = engine.ringing.isEmpty ? (idle ? 2000 : 250) : 100
                try? await Task.sleep(for: .milliseconds(wait))
            }
        }
        EventLog.action("watch.engine.start", ["alarms": alarms.count, "timers": timers.count])
    }

    /// Chymee came on screen: the only moment watchOS lets us (re)schedule the session.
    func activated() {
        start()
        sessionFailures = 0
        // Re-derive upcoming alarm moments in case the time zone or clock moved.
        let now = Date()
        for alarm in alarms where alarm.isEnabled && ringing[alarm.id] == nil {
            if let fire = alarmFire[alarm.id], fire <= now { continue }   // due: let check() ring it
            alarmFire[alarm.id] = alarm.nextFire(after: now)
        }
        check()
        save()
        reschedule()
        publishState()
    }

    /// watchOS relaunched Chymee for the scheduled session.
    func adopt(_ incoming: WKExtendedRuntimeSession) {
        start()
        incoming.delegate = self
        session = incoming
        sessionNotifying = false
        EventLog.action("watch.session.adopt", ["state": incoming.state.rawValue])
        if incoming.state == .running { sessionStarted() }
    }

    // MARK: - Commands (same vocabulary the iPhone engine speaks)

    func perform(_ command: ClockCommand) async -> ClockReply {
        start()
        let remote = command.remote == true
        let now = Date()
        switch command.action {
        case "sync":
            check()
        case "saveAlarm":
            guard var alarm = command.alarm, (0..<1440).contains(alarm.minuteOfDay),
                  alarm.repeatDays.allSatisfy({ (1...7).contains($0) }) else { return invalid() }
            let wasLinked = alarms.first { $0.id == alarm.id }?.isLinked ?? false
            alarm.soundName = ChymeSound.resolved(alarm.soundName)
            silence(alarm.id, reason: "edited")
            alarms.removeAll { $0.id == alarm.id }
            alarms.append(alarm)
            alarms.sort { $0.minuteOfDay < $1.minuteOfDay }
            alarmFire[alarm.id] = alarm.isEnabled ? alarm.nextFire(after: now) : nil
            if !remote && (alarm.isLinked || wasLinked) {
                ChymeConnectivity.shared.sendLinked(ClockCommand(action: "saveAlarm", alarm: alarm))
            }
            EventLog.action("watch.alarm.save", ["id": alarm.id.uuidString, "enabled": alarm.isEnabled,
                                                 "cutoff": alarm.autoDismiss.seconds, "linked": alarm.isLinked, "remote": remote])
        case "deleteAlarm":
            guard let id = command.id else { return invalid() }
            let wasLinked = alarms.first { $0.id == id }?.isLinked ?? false
            silence(id, reason: "deleted")
            alarms.removeAll { $0.id == id }
            alarmFire[id] = nil
            if !remote && wasLinked { ChymeConnectivity.shared.sendLinked(ClockCommand(action: "deleteAlarm", id: id)) }
            EventLog.action("watch.alarm.delete", ["id": id.uuidString, "linked": wasLinked, "remote": remote])
        case "startTimer":
            guard var timer = command.timer, timer.duration.isFinite, timer.duration >= 1,
                  timer.duration <= 86399 else { return invalid() }
            if remote {
                // A linked timer started on the iPhone: keep its end moment so both finish together.
                guard !cancelled.contains(timer.id), !timers.contains(where: { $0.id == timer.id }),
                      let end = timer.endsAt, end > now else { break }
            } else {
                timer.endsAt = now.addingTimeInterval(timer.duration)
            }
            timer.pausedRemaining = nil
            timer.soundName = ChymeSound.resolved(timer.soundName)
            timers.removeAll { $0.id == timer.id }
            timers.append(timer)
            if !remote && timer.isLinked {
                ChymeConnectivity.shared.sendLinked(ClockCommand(action: "startTimer", timer: timer))
            }
            EventLog.action("watch.timer.start", ["id": timer.id.uuidString, "seconds": Int(timer.duration),
                                                  "cutoff": timer.autoDismiss.seconds, "linked": timer.isLinked, "remote": remote])
        case "cancelTimer":
            guard let id = command.id else { return invalid() }
            let wasLinked = timers.first { $0.id == id }?.isLinked ?? false
            silence(id, reason: "cancelled")
            timers.removeAll { $0.id == id }
            cancelled.append(id)
            if cancelled.count > 60 { cancelled.removeFirst(30) }
            if !remote && wasLinked { ChymeConnectivity.shared.sendLinked(ClockCommand(action: "cancelTimer", id: id)) }
            EventLog.action("watch.timer.cancel", ["id": id.uuidString, "linked": wasLinked, "remote": remote])
        case "pauseTimer", "resumeTimer":
            guard let id = command.id else { return invalid() }
            guard let index = timers.firstIndex(where: { $0.id == id }) else {
                if remote { break }
                return invalid()
            }
            if command.action == "pauseTimer" {
                guard !timers[index].isPaused else { break }
                timers[index].pausedRemaining = timers[index].remaining(at: now)
                timers[index].endsAt = nil
            } else {
                guard timers[index].isPaused else { break }
                timers[index].endsAt = now.addingTimeInterval(timers[index].remaining(at: now))
                timers[index].pausedRemaining = nil
            }
            if !remote && timers[index].isLinked {
                ChymeConnectivity.shared.sendLinked(ClockCommand(action: command.action, id: id))
            }
            EventLog.action("watch.timer." + (command.action == "pauseTimer" ? "pause" : "resume"),
                            ["id": id.uuidString, "remote": remote])
        case "stopAlert":
            if let id = command.id, ringing[id] != nil { endRing(id, reason: "stopped-on-iphone", byUser: false) }
        default:
            return invalid()
        }
        changed()
        return ClockReply(snapshot: snapshot)
    }

    /// The Stop button while something rings on this watch.
    func stop(_ id: UUID) {
        guard ringing[id] != nil else { return }
        endRing(id, reason: "stopped", byUser: true)
        changed()
    }

    func stopAll() {
        for id in Array(ringing.keys) { endRing(id, reason: "stopped", byUser: true) }
        changed()
    }

    private func invalid() -> ClockReply {
        ClockReply(snapshot: snapshot, error: "This item is no longer available, or its time is invalid.")
    }

    // MARK: - Ringing and the automatic stop

    private func check() {
        let now = Date()
        var dirty = false
        for timer in timers where ringing[timer.id] == nil {
            guard let end = timer.endsAt, end <= now else { continue }
            if !beginRing(id: timer.id, label: timer.label, cutoff: timer.autoDismiss, firedAt: end, now: now) {
                finish(timer.id, now: now)
            }
            dirty = true
        }
        for alarm in alarms where alarm.isEnabled && ringing[alarm.id] == nil {
            guard let fire = alarmFire[alarm.id] else {
                alarmFire[alarm.id] = alarm.nextFire(after: now)
                dirty = true
                continue
            }
            guard fire <= now else { continue }
            if !beginRing(id: alarm.id, label: alarm.label, cutoff: alarm.autoDismiss, firedAt: fire, now: now) {
                finish(alarm.id, now: now)
            }
            dirty = true
        }
        for (id, ring) in ringing where ring.stopAt <= now {
            endRing(id, reason: ring.untilStopped ? "limit" : "auto-stop", byUser: false)
            dirty = true
        }
        if dirty { changed() }
    }

    /// Returns false when the item's whole ring window has already passed.
    private func beginRing(id: UUID, label: String, cutoff: AutoDismiss, firedAt: Date, now: Date) -> Bool {
        // "Until stopped" is bounded by the 30 minutes watchOS gives a session.
        let window = cutoff.isEnabled ? TimeInterval(cutoff.seconds) : 1800
        let stopAt = firedAt.addingTimeInterval(window)
        guard stopAt > now else {
            EventLog.action("watch.ring.missed", ["id": id.uuidString, "late_s": Int(now.timeIntervalSince(firedAt))])
            return false
        }
        ringing[id] = Ring(label: label, startedAt: now, stopAt: stopAt, untilStopped: !cutoff.isEnabled)
        clearNotifications(for: id)
        EventLog.action("watch.ring.start", ["id": id.uuidString, "label": label, "cutoff": cutoff.seconds,
                                             "late_ms": Int(now.timeIntervalSince(firedAt) * 1000),
                                             "via_session": session?.state == .running])
        updateHaptics()
        return true
    }

    private func endRing(_ id: UUID, reason: String, byUser: Bool) {
        guard let ring = ringing.removeValue(forKey: id) else { return }
        let now = Date()
        if byUser {
            // A linked item silenced here is silenced on the iPhone too.
            if timers.first(where: { $0.id == id })?.isLinked == true {
                ChymeConnectivity.shared.sendLinked(ClockCommand(action: "cancelTimer", id: id))
            } else if alarms.first(where: { $0.id == id })?.isLinked == true {
                ChymeConnectivity.shared.sendLinked(ClockCommand(action: "stopAlert", id: id))
            }
        }
        finish(id, now: now)
        EventLog.action("watch.ring.stop", ["id": id.uuidString, "reason": reason,
                                            "rang_ms": Int(now.timeIntervalSince(ring.startedAt) * 1000)])
        updateHaptics()
    }

    /// Stop the buzzing for an item that is being edited, cancelled or deleted.
    private func silence(_ id: UUID, reason: String) {
        guard let ring = ringing.removeValue(forKey: id) else { return }
        EventLog.action("watch.ring.stop", ["id": id.uuidString, "reason": reason,
                                            "rang_ms": Int(Date().timeIntervalSince(ring.startedAt) * 1000)])
        updateHaptics()
    }

    /// What happens to an item once its ring is over.
    private func finish(_ id: UUID, now: Date) {
        if timers.contains(where: { $0.id == id }) {
            timers.removeAll { $0.id == id }
        } else if let index = alarms.firstIndex(where: { $0.id == id }) {
            if alarms[index].repeatDays.isEmpty {
                alarms[index].isEnabled = false
                alarmFire[id] = nil
            } else {
                alarmFire[id] = alarms[index].nextFire(after: now)
            }
        }
    }

    private func updateHaptics() {
        let active = !ringing.isEmpty
        flag.set(active)
        if active {
            if let live = session, live.state == .running {
                hapticLoop?.cancel(); hapticLoop = nil
                if !sessionNotifying {
                    sessionNotifying = true
                    Self.notify(live, flag: flag)
                }
            } else if hapticLoop == nil {
                hapticLoop = Task { @MainActor in
                    let engine = WatchEngine.shared
                    while !engine.ringing.isEmpty && !Task.isCancelled && engine.session?.state != .running {
                        WKInterfaceDevice.current().play(.notification)
                        try? await Task.sleep(for: .milliseconds(1500))
                    }
                    if !Task.isCancelled { engine.hapticLoop = nil }
                }
            }
        } else {
            hapticLoop?.cancel(); hapticLoop = nil
            if let live = session, live.state == .running { endSession(live) }
        }
    }

    /// The repeat handler runs on a system queue. It is built here, outside the
    /// main actor, because a main-actor closure traps when called off-main.
    nonisolated private static func notify(_ session: WKExtendedRuntimeSession, flag: RingFlag) {
        session.notifyUser(hapticType: .notification) { @Sendable next in
            guard flag.isOn else { return 0 }      // the automatic stop
            next.pointee = .notification
            return 1.5
        }
    }

    private func endSession(_ live: WKExtendedRuntimeSession) {
        sessionNotifying = false
        live.invalidate()
    }

    // MARK: - Smart Alarm session

    private struct Upcoming { var id: UUID; var date: Date; var label: String }

    private var upcoming: [Upcoming] {
        timers.compactMap { timer in timer.endsAt.map { Upcoming(id: timer.id, date: $0, label: timer.label) } }
            + alarms.filter(\.isEnabled).compactMap { alarm in
                alarmFire[alarm.id].map { Upcoming(id: alarm.id, date: $0, label: alarm.label) }
            }
    }

    private func reschedule() {
        syncSession()
        syncNotifications()
    }

    private func syncSession() {
        if let live = session, live.state == .running { return }
        guard WKApplication.shared().applicationState == .active, sessionFailures < 3 else { return }
        let now = Date()
        let limit = now.addingTimeInterval(36 * 3600 - 120)
        let next = upcoming.filter { $0.date > now && $0.date < limit && ringing[$0.id] == nil }
            .min { $0.date < $1.date }
        if let current = session, current.state == .scheduled || current.state == .notStarted {
            if let next, sessionItem == next.id, let target = sessionTarget,
               abs(target.timeIntervalSince(next.date)) < 0.5 { return }
            session = nil
            current.invalidate()
        }
        guard let next else {
            sessionItem = nil; sessionTarget = nil
            return
        }
        let fresh = WKExtendedRuntimeSession()
        fresh.delegate = self
        fresh.start(at: next.date)
        session = fresh
        sessionItem = next.id
        sessionTarget = next.date
        sessionNotifying = false
        EventLog.action("watch.session.schedule", ["id": next.id.uuidString,
                                                   "in_s": Int(next.date.timeIntervalSince(now))])
    }

    private func sessionStarted() {
        EventLog.action("watch.session.start", ["ringing": ringing.count])
        check()
        if ringing.isEmpty {
            // Started a hair early, or for an item cancelled while Chymee was not running.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1500))
                let engine = WatchEngine.shared
                engine.check()
                if engine.ringing.isEmpty, let live = engine.session, live.state == .running {
                    EventLog.action("watch.session.stale")
                    engine.endSession(live)
                } else {
                    engine.updateHaptics()
                }
            }
        } else {
            updateHaptics()
        }
    }

    private func sessionExpiring() {
        for id in Array(ringing.keys) { endRing(id, reason: "session-limit", byUser: false) }
        changed()
    }

    private func sessionEnded(_ ended: ObjectIdentifier, reason: Int, error: String?) {
        EventLog.action("watch.session.end", ["reason": reason, "error": error ?? "", "ringing": ringing.count])
        guard let current = session, ObjectIdentifier(current) == ended else { return }
        let wasRinging = sessionNotifying
        session = nil
        sessionNotifying = false
        if error != nil { sessionFailures += 1 }
        if wasRinging && !ringing.isEmpty {
            // The wearer tapped Stop on the system alarm alert.
            for id in Array(ringing.keys) { endRing(id, reason: "dismissed", byUser: true) }
        }
        changed()
    }

    // MARK: - Backup notifications

    nonisolated private static func askPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { @Sendable _, _ in }
    }

    private func identifiers(for id: UUID) -> [String] {
        ["chymee.\(id.uuidString)"] + (1...7).map { "chymee.\(id.uuidString).\($0)" }
    }

    private func clearNotifications(for id: UUID) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers(for: id))
        center.removeDeliveredNotifications(withIdentifiers: identifiers(for: id))
    }

    private func syncNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        let now = Date()
        // The item that owns the session gets its backup two seconds late, so
        // the session can cancel it first and the wearer is not alerted twice.
        func lag(_ id: UUID) -> TimeInterval { id == sessionItem ? 2 : 0 }
        func content(_ title: String, _ body: String) -> UNMutableNotificationContent {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            return content
        }
        for timer in timers where ringing[timer.id] == nil {
            guard let end = timer.endsAt, end > now else { continue }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, end.timeIntervalSince(now) + lag(timer.id)), repeats: false)
            center.add(UNNotificationRequest(identifier: "chymee.\(timer.id.uuidString)",
                                             content: content(timer.label, "Timer done"), trigger: trigger),
                       withCompletionHandler: nil)
        }
        for alarm in alarms where alarm.isEnabled && ringing[alarm.id] == nil {
            let body = "Alarm · " + ClockText.time(alarm.minuteOfDay)
            if alarm.repeatDays.isEmpty {
                guard let fire = alarmFire[alarm.id], fire > now else { continue }
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fire.timeIntervalSince(now) + lag(alarm.id)), repeats: false)
                center.add(UNNotificationRequest(identifier: "chymee.\(alarm.id.uuidString)",
                                                 content: content(alarm.label, body), trigger: trigger),
                           withCompletionHandler: nil)
            } else {
                for day in alarm.repeatDays {
                    var parts = DateComponents()
                    parts.weekday = day; parts.hour = alarm.hour; parts.minute = alarm.minute
                    parts.second = Int(lag(alarm.id))
                    let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)
                    center.add(UNNotificationRequest(identifier: "chymee.\(alarm.id.uuidString).\(day)",
                                                     content: content(alarm.label, body), trigger: trigger),
                               withCompletionHandler: nil)
                }
            }
        }
    }

    // MARK: - State out: UI and complications

    private func changed() {
        save()
        reschedule()
        publishState()
    }

    private func publishState() {
        onChange?(snapshot)
        refreshComplications()
    }

    /// Push what the watch face should show. Called on every change, and by
    /// the stopwatch screen when it starts, stops or resets.
    func refreshComplications() {
        var state = ComplicationState()
        state.timers = timers.map { .init(label: $0.label, endsAt: $0.endsAt, pausedRemaining: $0.pausedRemaining) }
        let next = alarms.filter(\.isEnabled)
            .compactMap { alarm in alarmFire[alarm.id].map { (date: $0, label: alarm.label) } }
            .min { $0.date < $1.date }
        state.nextAlarm = next?.date
        state.nextAlarmLabel = next?.label
        if let data = defaults.data(forKey: "stopwatch.v2"),
           let watch = try? JSONDecoder().decode(StopwatchState.self, from: data) {
            if let began = watch.startedAt {
                state.stopwatchAnchor = began.addingTimeInterval(-watch.elapsed)
            } else if watch.elapsed > 0 {
                state.stopwatchPaused = watch.elapsed
            }
        }
        state.updated = Date(timeIntervalSince1970: 0)
        guard state != lastComplication else { return }
        lastComplication = state
        state.updated = .now
        let status = SharedState.save(state)
        WidgetCenter.shared.reloadAllTimelines()
        if status != 0 { EventLog.action("watch.complication.save_failed", ["status": Int(status)]) }
    }

    // MARK: - Persistence

    private func load() {
        alarms = decode(Key.alarms) ?? []
        timers = decode(Key.timers) ?? []
        let stored = defaults.dictionary(forKey: Key.fires) as? [String: Double] ?? [:]
        for (key, value) in stored {
            if let id = UUID(uuidString: key) { alarmFire[id] = Date(timeIntervalSince1970: value) }
        }
        // A timer left running by the previous build's single-timer engine.
        if let data = defaults.data(forKey: Key.legacyTimer) {
            if let old = try? JSONDecoder().decode(ChymeTimer.self, from: data),
               !timers.contains(where: { $0.id == old.id }) { timers.append(old) }
            defaults.removeObject(forKey: Key.legacyTimer)
        }
    }

    private func save() {
        encode(alarms, Key.alarms)
        encode(timers, Key.timers)
        var stored: [String: Double] = [:]
        for (id, date) in alarmFire { stored[id.uuidString] = date.timeIntervalSince1970 }
        defaults.set(stored, forKey: Key.fires)
    }

    private func decode<T: Decodable>(_ key: String) -> [T]? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([T].self, from: $0) }
    }

    private func encode<T: Encodable>(_ value: [T], _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}

extension WatchEngine: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in WatchEngine.shared.sessionStarted() }
    }
    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in WatchEngine.shared.sessionExpiring() }
    }
    nonisolated func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                            didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                            error: Error?) {
        let ended = ObjectIdentifier(extendedRuntimeSession)
        let code = reason.rawValue
        let message = error?.localizedDescription
        Task { @MainActor in WatchEngine.shared.sessionEnded(ended, reason: code, error: message) }
    }
}

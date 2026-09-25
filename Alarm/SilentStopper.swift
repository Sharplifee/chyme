import Foundation
#if canImport(AlarmKit)
import AlarmKit

/// AlarmKit has no alert-duration API, and an in-app observer cannot stop a
/// ringing alarm because the app is suspended when the alarm fires.
///
/// So every alert Chyme schedules is paired with a second, silent AlarmKit alarm
/// set for fire-time plus the user's cutoff. When the system fires that stopper,
/// it brings this process up to render the stopper's Live Activity — and in that
/// window the engine stops the real alarm and then stops the stopper itself.
///
/// Applies identically to alarms, timers and the stopwatch alert.
@MainActor
enum SilentStopper {

    nonisolated static let soundFile = "silence.wav"

    /// stopper id -> id of the alert it silences.
    private static let mapKey = "silentStopperMap"

    private static var defaults: UserDefaults { .standard }

    static func map() -> [String: String] {
        defaults.dictionary(forKey: mapKey) as? [String: String] ?? [:]
    }

    static func target(of stopperID: UUID) -> UUID? {
        map()[stopperID.uuidString].flatMap(UUID.init(uuidString:))
    }

    static func stopper(for targetID: UUID) -> UUID? {
        map().first { $0.value == targetID.uuidString }
            .flatMap { UUID(uuidString: $0.key) }
    }

    private static func remember(stopper: UUID, target: UUID) {
        var m = map()
        m[stopper.uuidString] = target.uuidString
        defaults.set(m, forKey: mapKey)
    }

    private static func forget(stopper: UUID) {
        var m = map()
        m.removeValue(forKey: stopper.uuidString)
        defaults.set(m, forKey: mapKey)
    }

    // MARK: - Scheduling

    /// Countdown alerts (timers, stopwatch alert): stopper fires `duration + cutoff`
    /// from now, so it lands `cutoff` after the alert starts ringing.
    /// Master switch. If the paired-stopper approach misbehaves on device the
    /// user can turn it off in Settings without losing alarms entirely.
    static var isEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: "silentStopperEnabled") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "silentStopperEnabled") }
    }

    static func arm(target: UUID, firesIn duration: TimeInterval, cutoff: AutoDismiss) async {
        guard isEnabled else { return }
        await disarm(target: target)
        guard cutoff.isEnabled else { return }
        let id = UUID()
        do {
            try await AlarmKitBridge.scheduleSilent(
                id: id,
                after: duration + TimeInterval(cutoff.seconds)
            )
            remember(stopper: id, target: target)
        } catch {
            // No stopper is better than a wrong one; the alert still rings.
        }
    }

    /// Wall-clock alarms: stopper repeats on the same weekdays, `cutoff` later.
    static func arm(target: UUID,
                    hour: Int,
                    minute: Int,
                    weekdays: Set<Int>,
                    cutoff: AutoDismiss) async {
        guard isEnabled else { return }
        await disarm(target: target)
        guard cutoff.isEnabled else { return }

        let offsetMinutes = Int(ceil(Double(cutoff.seconds) / 60.0))
        let total = hour * 60 + minute + offsetMinutes
        let rolledOver = total >= 1440
        let stopHour = (total % 1440) / 60
        let stopMinute = (total % 1440) % 60

        // If the cutoff pushes past midnight the stopper belongs on the next day.
        let stopDays: Set<Int> = weekdays.isEmpty
            ? []
            : Set(weekdays.map { rolledOver ? ($0 % 7) + 1 : $0 })

        let id = UUID()
        do {
            try await AlarmKitBridge.scheduleSilentFixed(
                id: id, hour: stopHour, minute: stopMinute, weekdays: stopDays
            )
            remember(stopper: id, target: target)
        } catch {
        }
    }

    // MARK: - Teardown

    static func disarm(target: UUID) async {
        guard let id = stopper(for: target) else { return }
        try? AlarmManager.shared.stop(id: id)
        try? AlarmManager.shared.cancel(id: id)
        forget(stopper: id)
    }

    /// Called when a stopper is seen alerting: kill the real alert, then itself.
    static func fire(stopperID: UUID) {
        if let target = target(of: stopperID) {
            try? AlarmManager.shared.stop(id: target)
            try? AlarmManager.shared.cancel(id: target)
        }
        try? AlarmManager.shared.stop(id: stopperID)
        try? AlarmManager.shared.cancel(id: stopperID)
        forget(stopper: stopperID)
    }

    static func isStopper(_ id: UUID) -> Bool {
        map()[id.uuidString] != nil
    }
}
#endif

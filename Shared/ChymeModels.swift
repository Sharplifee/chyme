import Foundation

/// Requested alert duration. Automatic stopping requires the iPhone process to remain active.
public struct AutoDismiss: Codable, Hashable, Sendable {
    public var seconds: Int

    public static let tenSeconds = AutoDismiss(seconds: 10)
    public static let twentySeconds = AutoDismiss(seconds: 20)
    public static let thirtySeconds = AutoDismiss(seconds: 30)
    public static let oneMinute = AutoDismiss(seconds: 60)
    public static let twoMinutes = AutoDismiss(seconds: 120)
    public static let fiveMinutes = AutoDismiss(seconds: 300)
    public static let tenMinutes = AutoDismiss(seconds: 600)
    public static let never = AutoDismiss(seconds: 0)   // ring until stopped

    public var isEnabled: Bool { seconds > 0 }

    public init(seconds: Int) { self.seconds = seconds }

    public var label: String {
        guard isEnabled else { return "Until stopped" }
        let m = seconds / 60
        let s = seconds % 60
        if s == 0 { return "\(m) min" }
        if m == 0 { return "\(s) sec" }
        return "\(m)m \(s)s"
    }

    public static let presets: [AutoDismiss] = [
        .tenSeconds, .twentySeconds, .thirtySeconds,
        .oneMinute, .twoMinutes, .fiveMinutes, .tenMinutes, .never
    ]
}

public struct ChymeAlarm: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var label: String
    /// Minutes since midnight, local time.
    public var minuteOfDay: Int
    /// 1 = Sunday ... 7 = Saturday. Empty means one-shot.
    public var repeatDays: Set<Int>
    public var isEnabled: Bool
    public var soundName: String
    public var snoozeEnabled: Bool
    public var autoDismiss: AutoDismiss

    public init(id: UUID = UUID(),
                label: String = "Alarm",
                minuteOfDay: Int,
                repeatDays: Set<Int> = [],
                isEnabled: Bool = true,
                soundName: String = "System",
                snoozeEnabled: Bool = true,
                autoDismiss: AutoDismiss = .fiveMinutes) {
        self.id = id
        self.label = label
        self.minuteOfDay = minuteOfDay
        self.repeatDays = repeatDays
        self.isEnabled = isEnabled
        self.soundName = soundName
        self.snoozeEnabled = snoozeEnabled
        self.autoDismiss = autoDismiss
    }

    public var hour: Int { minuteOfDay / 60 }
    public var minute: Int { minuteOfDay % 60 }
}

public struct ChymeTimer: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var label: String
    public var duration: TimeInterval
    public var autoDismiss: AutoDismiss
    public var soundName: String
    public var endsAt: Date?
    public var pausedRemaining: TimeInterval?

    public init(id: UUID = UUID(),
                label: String = "Timer",
                duration: TimeInterval,
                autoDismiss: AutoDismiss = .fiveMinutes,
                soundName: String = "System") {
        self.id = id
        self.label = label
        self.duration = duration
        self.endsAt = Date().addingTimeInterval(duration)
        self.pausedRemaining = nil
        self.autoDismiss = autoDismiss
        self.soundName = soundName
    }
}

/// Durations offered on the Digital Crown when a timer is started from the watch
/// complication. Tap the complication, scroll, tap again — no app navigation.
public enum CrownDurations {
    public static let values: [TimeInterval] = {
        var v: [TimeInterval] = []
        for m in 1...15 { v.append(TimeInterval(m * 60)) }          // 1-15 min
        for m in stride(from: 20, through: 60, by: 5) { v.append(TimeInterval(m * 60)) }
        for m in stride(from: 75, through: 180, by: 15) { v.append(TimeInterval(m * 60)) }
        return v
    }()

    public static func label(for seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m) min"
    }
}


/// Alert sounds offered for alarms, timers and the stopwatch alert.
public struct ChymeSound: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var id: String { name }
    public init(_ name: String) { self.name = name }

    public static let all = [ChymeSound("System"), ChymeSound("Bell"), ChymeSound("Pulse"), ChymeSound("Dawn")]
    public static let `default` = ChymeSound("System")
    public static func resolved(_ name: String) -> String {
        all.contains(where: { $0.name == name }) ? name : "System"
    }
}

extension ChymeTimer {
    public func remaining(at date: Date = .now) -> TimeInterval {
        max(0, pausedRemaining ?? endsAt?.timeIntervalSince(date) ?? 0)
    }
    public var isPaused: Bool { pausedRemaining != nil }
}

public enum ClockText {
    public static func duration(_ seconds: TimeInterval, hundredths: Bool = false) -> String {
        let value = max(0, seconds), total = Int(value)
        let base = total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
        return hundredths ? base + String(format: ".%02d", Int(value * 100) % 100) : base
    }
    public static func time(_ minutes: Int) -> String {
        let date = Calendar.current.startOfDay(for: .now).addingTimeInterval(Double(minutes * 60))
        return date.formatted(date: .omitted, time: .shortened)
    }
    public static func repeatLabel(_ days: Set<Int>) -> String {
        if days.isEmpty { return "Never" }
        if days.count == 7 { return "Every day" }
        if days == Set(2...6) { return "Weekdays" }
        if days == [1, 7] { return "Weekends" }
        return days.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
    }
}

public struct ClockSnapshot: Codable, Sendable {
    public var alarms: [ChymeAlarm]
    public var timers: [ChymeTimer]
    public var date: Date = .now
}

public struct ClockCommand: Codable, Sendable {
    public var requestID = UUID()
    public var action: String
    public var id: UUID? = nil
    public var alarm: ChymeAlarm? = nil
    public var timer: ChymeTimer? = nil
}

public struct ClockReply: Codable, Sendable {
    public var snapshot: ClockSnapshot?
    public var error: String?
}

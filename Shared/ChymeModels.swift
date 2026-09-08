import Foundation

/// How long a ringing alarm or timer is allowed to sound before it stops itself.
/// This is the whole point of Chyme: nothing rings forever.
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
                soundName: String = "Radial",
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

    public init(id: UUID = UUID(),
                label: String = "Timer",
                duration: TimeInterval,
                autoDismiss: AutoDismiss = .fiveMinutes,
                soundName: String = "Radial") {
        self.id = id
        self.label = label
        self.duration = duration
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

    public static let all: [ChymeSound] = [
        "Radial", "Ripples", "Sencha", "Signal", "Silk", "Slow Rise",
        "Stargaze", "Summit", "Twinkle", "Uplift", "Waves",
        "Beacon", "Bulletin", "By The Seaside", "Chimes", "Circuit",
        "Constellation", "Cosmic", "Crystals", "Hillside", "Illuminate"
    ].map(ChymeSound.init)

    public static let `default` = ChymeSound("Radial")
}

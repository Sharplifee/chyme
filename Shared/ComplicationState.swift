import Foundation
import Security

/// What the watch complications draw. The watch app writes it every time
/// something changes; the complication extension reads it when it builds a
/// timeline. Countdowns and the stopwatch are stored as anchors (an end date,
/// a start date) so the face keeps ticking by itself between reloads.
public struct ComplicationState: Codable, Sendable, Equatable {
    public struct TimerItem: Codable, Sendable, Equatable {
        public var label: String
        public var endsAt: Date?
        public var pausedRemaining: TimeInterval?
        public init(label: String, endsAt: Date?, pausedRemaining: TimeInterval?) {
            self.label = label; self.endsAt = endsAt; self.pausedRemaining = pausedRemaining
        }
    }
    public var timers: [TimerItem] = []
    public var nextAlarm: Date?
    public var nextAlarmLabel: String?
    /// Running stopwatch: the moment it would have read 0:00.
    public var stopwatchAnchor: Date?
    /// Paused stopwatch with time on it.
    public var stopwatchPaused: TimeInterval?
    public var updated: Date = .now

    public init() {}

    /// The running timer that ends soonest after `date`.
    public func runningTimer(at date: Date) -> TimerItem? {
        timers.filter { ($0.endsAt ?? .distantPast) > date }
            .min { ($0.endsAt ?? .distantFuture) < ($1.endsAt ?? .distantFuture) }
    }
    public var pausedTimer: TimerItem? { timers.first { $0.pausedRemaining != nil } }

    /// Moments at which the face has to change what it shows.
    public func boundaries(after date: Date) -> [Date] {
        var out = timers.compactMap(\.endsAt).filter { $0 > date }
        if let alarm = nextAlarm, alarm > date { out.append(alarm.addingTimeInterval(60)) }
        return Array(Set(out)).sorted()
    }
}

/// Shared storage between the watch app and its complication extension.
///
/// Both targets carry the same keychain access group as their first
/// `keychain-access-groups` entitlement, which makes it the default group:
/// an item written by one is readable by the other. No App Group needed.
public enum SharedState {
    private static let service = "com.connor.chyme.complication"
    private static let account = "state.v1"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    @discardableResult
    public static func save(_ state: ComplicationState) -> OSStatus {
        guard let data = try? JSONEncoder().encode(state) else { return errSecParam }
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return update }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemDelete(query as CFDictionary)
        return SecItemAdd(add as CFDictionary, nil)
    }

    public static func load() -> ComplicationState {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let state = try? JSONDecoder().decode(ComplicationState.self, from: data) else {
            return ComplicationState()
        }
        return state
    }

    /// Writes then reads back. Shown in watch Settings so a broken share is visible.
    public static func selfTest() -> String {
        let status = save(load())
        guard status == errSecSuccess else { return "Write failed (\(status))" }
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let read = SecItemCopyMatching(q as CFDictionary, &out)
        return read == errSecSuccess ? "Working" : "Read failed (\(read))"
    }
}

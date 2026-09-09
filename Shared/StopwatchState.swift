import Foundation

/// Persist an anchor, not display ticks: backgrounding does not lose elapsed time.
public struct StopwatchState: Codable, Sendable {
    public var elapsed: TimeInterval = 0
    public var startedAt: Date?
    public var preset: TimeInterval = 0
    public var splits: [TimeInterval] = []
    public var alertID: UUID?
    public var running: Bool { startedAt != nil }
    public func value(at now: Date = .now) -> TimeInterval {
        max(0, elapsed + (startedAt.map { now.timeIntervalSince($0) } ?? 0))
    }
    public mutating func start(at now: Date = .now) { if !running { startedAt = now } }
    public mutating func pause(at now: Date = .now) { elapsed = value(at: now); startedAt = nil }
    public mutating func lap(at now: Date = .now) { if running { splits.append(max(0, value(at: now) - preset)) } }
    public mutating func reset() { elapsed = preset; startedAt = nil; splits = []; alertID = nil }
    public var lapDurations: [TimeInterval] {
        splits.enumerated().map { $0.element - ($0.offset == 0 ? 0 : splits[$0.offset - 1]) }
    }
}

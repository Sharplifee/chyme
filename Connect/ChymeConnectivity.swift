import Foundation
import Combine
import WatchConnectivity

/// The only thing that crosses between iPhone and Apple Watch: changes to
/// items the user marked "Both Devices". Each device schedules and rings its
/// own copy, so neither needs the other to be nearby, awake, or installed.
/// Items that are not linked never leave the device that made them.
@MainActor
public final class ChymeConnectivity: NSObject, ObservableObject, WCSessionDelegate {
    public static let shared = ChymeConnectivity()
    @Published public private(set) var reachable = false
    /// Applies a linked change that arrived from the other device.
    public var onLinked: ((ClockCommand) async -> Void)?
    private var backlog: [Data] = []
    private var seen: [UUID] = []

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    /// Queue a linked change for the other device. Delivery is guaranteed and
    /// ordered (`transferUserInfo`); when the other side is live it also goes
    /// immediately. Receivers drop the duplicate by request id.
    public func sendLinked(_ command: ClockCommand) {
        var outgoing = command
        outgoing.remote = true
        guard WCSession.isSupported(), let data = try? JSONEncoder().encode(outgoing) else { return }
        guard WCSession.default.activationState == .activated else { backlog.append(data); return }
        Self.transmit(data, live: WCSession.default.isReachable)
    }

    /// Built outside the main actor: WatchConnectivity calls its handlers on
    /// its own queue, and a main-actor closure traps when called there.
    nonisolated private static func transmit(_ data: Data, live: Bool) {
        WCSession.default.transferUserInfo(["link": data])
        if live {
            WCSession.default.sendMessage(["link": data], replyHandler: nil, errorHandler: { @Sendable _ in })
        }
    }

    private func receive(_ command: ClockCommand) {
        guard !seen.contains(command.requestID) else { return }
        seen.append(command.requestID)
        if seen.count > 200 { seen.removeFirst(100) }
        var incoming = command
        incoming.remote = true
        Task { await self.onLinked?(incoming) }
    }

    nonisolated private static func decode(_ payload: [String: Any]) -> ClockCommand? {
        (payload["link"] as? Data).flatMap { try? JSONDecoder().decode(ClockCommand.self, from: $0) }
    }

    nonisolated public func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let connected = session.isReachable
        Task { @MainActor in
            self.reachable = connected
            let waiting = self.backlog
            self.backlog.removeAll()
            if state == .activated { for data in waiting { Self.transmit(data, live: connected) } }
        }
    }
    nonisolated public func sessionReachabilityDidChange(_ session: WCSession) {
        let connected = session.isReachable
        Task { @MainActor in self.reachable = connected }
    }
    nonisolated public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let command = Self.decode(userInfo) else { return }
        Task { @MainActor in self.receive(command) }
    }
    nonisolated public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let command = Self.decode(message) else { return }
        Task { @MainActor in self.receive(command) }
    }
    /// Older builds asked the iPhone to run every watch action. Answer so they
    /// fail fast instead of hanging; current builds never send this.
    nonisolated public func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler([:])
        guard let command = Self.decode(message) else { return }
        Task { @MainActor in self.receive(command) }
    }
    #if os(iOS)
    nonisolated public func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated public func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}

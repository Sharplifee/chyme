import Foundation
import Combine
import WatchConnectivity

/// Commands are acknowledged, never queued to execute minutes after a tap.
@MainActor
public final class ChymeConnectivity: NSObject, ObservableObject, WCSessionDelegate {
    public static let shared = ChymeConnectivity()
    @Published public private(set) var reachable = false
    public var receiveSnapshot: ((ClockSnapshot) -> Void)?
    public var onActivation: (() -> Void)?
    private var latestSnapshot: ClockSnapshot?
    public var execute: ((ClockCommand) async -> ClockReply)?
    private var pending: [UUID: CheckedContinuation<ClockReply, Never>] = [:]

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    public func publish(_ snapshot: ClockSnapshot) {
        latestSnapshot = snapshot
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? WCSession.default.updateApplicationContext(["snapshot": data])
    }

    public func request(_ command: ClockCommand) async -> ClockReply {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isReachable else {
            return ClockReply(error: "Open Chymee on your nearby iPhone, then try again.")
        }
        guard let data = try? JSONEncoder().encode(command) else {
            return ClockReply(error: "This change could not be sent. Please try again.")
        }
        return await withCheckedContinuation { continuation in
            pending[command.requestID] = continuation
            WCSession.default.sendMessage(["command": data], replyHandler: { payload in
                let reply = (payload["reply"] as? Data).flatMap { try? JSONDecoder().decode(ClockReply.self, from: $0) }
                Task { @MainActor in
                    self.finish(command.requestID, reply ?? ClockReply(error: "The iPhone response could not be read. Refresh before retrying."))
                }
            }, errorHandler: { _ in
                Task { @MainActor in
                    self.finish(command.requestID, ClockReply(error: "Connection interrupted. Refresh to check whether your change was saved."))
                }
            })
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                self.finish(command.requestID, ClockReply(error: "iPhone has not confirmed this change. Refresh before retrying."))
            }
        }
    }

    private func accept(_ snapshot: ClockSnapshot) {
        #if os(watchOS)
        let previous = UserDefaults.standard.object(forKey: "clock.snapshotDate") as? Date
        guard previous == nil || snapshot.date >= previous! else { return }
        ChymeStore().save(alarms: snapshot.alarms)
        ChymeStore().save(timers: snapshot.timers)
        UserDefaults.standard.set(snapshot.date, forKey: "clock.snapshotDate")
        #endif
        receiveSnapshot?(snapshot)
    }

    private func finish(_ id: UUID, _ reply: ClockReply) {
        pending.removeValue(forKey: id)?.resume(returning: reply)
    }

    nonisolated public func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let connected = session.isReachable
        let snapshot = (session.receivedApplicationContext["snapshot"] as? Data).flatMap { try? JSONDecoder().decode(ClockSnapshot.self, from: $0) }
        Task { @MainActor in
            self.reachable = connected
            if let snapshot { self.accept(snapshot) }
            if let latest = self.latestSnapshot { self.publish(latest) }
            self.onActivation?()
        }
    }
    nonisolated public func sessionReachabilityDidChange(_ session: WCSession) {
        let connected = session.isReachable
        Task { @MainActor in self.reachable = connected }
    }
    nonisolated public func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        guard let data = context["snapshot"] as? Data,
              let snapshot = try? JSONDecoder().decode(ClockSnapshot.self, from: data) else { return }
        Task { @MainActor in self.accept(snapshot) }
    }
    nonisolated public func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let data = message["command"] as? Data,
              let command = try? JSONDecoder().decode(ClockCommand.self, from: data) else {
            replyHandler([:]); return
        }
        let responder = ReplySender(replyHandler)
        Task { @MainActor in
            let reply = await self.execute?(command) ?? ClockReply(error: "Open Chymee on iPhone to connect.")
            responder.send(reply)
        }
    }
    #if os(iOS)
    nonisolated public func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated public func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}

private final class ReplySender: @unchecked Sendable {
    let handler: ([String: Any]) -> Void
    init(_ handler: @escaping ([String: Any]) -> Void) { self.handler = handler }
    func send(_ reply: ClockReply) { handler(["reply": (try? JSONEncoder().encode(reply)) ?? Data()]) }
}

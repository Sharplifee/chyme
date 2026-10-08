import Foundation
import WatchKit
import Combine

/// Timers started ON THE WATCH run on the watch itself — no iPhone round trip —
/// using a Smart Alarm extended-runtime session scheduled for the fire time.
/// At fire time watchOS launches/wakes Chymee, we play the alarm haptic on a
/// repeat, and because our code is running we stop it ourselves exactly
/// `autoDismiss` seconds later by ending the session. That is the auto-stop.
///
/// watchOS allows one scheduled session per app, so a second watch timer while
/// one is pending falls back to the iPhone (AlarmKit) path.
@MainActor
final class WatchTimerEngine: NSObject, ObservableObject {
    static let shared = WatchTimerEngine()

    @Published private(set) var timer: ChymeTimer?
    @Published private(set) var ringing = false

    private var session: WKExtendedRuntimeSession?
    private var stopTask: Task<Void, Never>?
    private let key = "watch.localTimer"

    override init() {
        super.init()
        if let d = UserDefaults.standard.data(forKey: key),
           let t = try? JSONDecoder().decode(ChymeTimer.self, from: d),
           let end = t.endsAt, end.addingTimeInterval(1800) > .now {
            timer = t
        }
    }

    var isBusy: Bool { session != nil && timer != nil }

    /// Returns nil on success, or a reason the watch couldn't take it.
    func start(_ incoming: ChymeTimer) -> String? {
        guard !isBusy else { return "busy" }
        var t = incoming
        t.endsAt = Date().addingTimeInterval(t.duration)
        t.pausedRemaining = nil
        let s = WKExtendedRuntimeSession()
        s.delegate = self
        s.start(at: t.endsAt!)
        session = s
        timer = t
        save()
        return nil
    }

    func cancel() {
        stopTask?.cancel(); stopTask = nil
        session?.invalidate()
        clear()
    }

    /// Called by the app delegate when watchOS relaunches Chymee for the session.
    func adopt(_ s: WKExtendedRuntimeSession) {
        s.delegate = self
        session = s
        if s.state == .running { ring() }
    }

    private func ring() {
        guard let s = session, !ringing else { return }
        ringing = true
        WKInterfaceDevice.current().play(.notification)
        s.notifyUser(hapticType: .notification) { next in
            next.pointee = .notification
            return 1.5                      // repeat every 1.5 s until we stop it
        }
        let cutoff = timer?.autoDismiss ?? .never
        if cutoff.isEnabled {
            stopTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(cutoff.seconds))
                guard !Task.isCancelled else { return }
                WatchTimerEngine.shared.cancel()    // the auto-stop
            }
        }
    }

    private func clear() {
        ringing = false
        session = nil
        timer = nil
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func save() {
        if let t = timer, let d = try? JSONEncoder().encode(t) { UserDefaults.standard.set(d, forKey: key) }
    }
}

extension WatchTimerEngine: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ s: WKExtendedRuntimeSession) {
        Task { @MainActor in WatchTimerEngine.shared.ring() }
    }
    nonisolated func extendedRuntimeSessionWillExpire(_ s: WKExtendedRuntimeSession) {
        Task { @MainActor in WatchTimerEngine.shared.cancel() }
    }
    nonisolated func extendedRuntimeSession(_ s: WKExtendedRuntimeSession,
                                            didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                            error: Error?) {
        let ended = ObjectIdentifier(s)
        Task { @MainActor in
            let e = WatchTimerEngine.shared
            if e.session == nil || ObjectIdentifier(e.session!) == ended {
                e.stopTask?.cancel(); e.stopTask = nil
                e.clear()
            }
        }
    }
}

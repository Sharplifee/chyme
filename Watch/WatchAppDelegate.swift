import WatchKit
import WatchConnectivity

/// Finish WatchConnectivity wakes only after the session has drained its content.
@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    private var tasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    private var activationObservation: NSKeyValueObservation?
    private var contentObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching() {
        _ = ChymeConnectivity.shared
        ChymeConnectivity.shared.onLinked = { _ = await WatchEngine.shared.perform($0) }
        WatchEngine.shared.start()
        activationObservation = WCSession.default.observe(\.activationState) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.finishTransfers() }
        }
        contentObservation = WCSession.default.observe(\.hasContentPending) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.finishTransfers() }
        }
    }

    func applicationDidBecomeActive() {
        WatchEngine.shared.activated()
    }

    /// watchOS relaunched us for the scheduled Smart Alarm session (an alarm or
    /// timer came due while Chymee wasn't running). Must set the delegate now.
    func handle(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        WatchEngine.shared.adopt(extendedRuntimeSession)
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let transfer = task as? WKWatchConnectivityRefreshBackgroundTask {
                tasks.append(transfer)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
        finishTransfers()
    }

    private func finishTransfers() {
        guard WCSession.default.activationState != .activated || !WCSession.default.hasContentPending else { return }
        for task in tasks { task.setTaskCompletedWithSnapshot(false) }
        tasks.removeAll()
    }
}

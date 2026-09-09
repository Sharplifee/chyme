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
        activationObservation = WCSession.default.observe(\.activationState) { [weak self] _, _ in
            Task { @MainActor in self?.finishTransfers() }
        }
        contentObservation = WCSession.default.observe(\.hasContentPending) { [weak self] _, _ in
            Task { @MainActor in self?.finishTransfers() }
        }
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

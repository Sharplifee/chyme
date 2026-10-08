import AVFoundation
import UIKit

/// Why auto-stop never worked: when an AlarmKit alert fires, Chymee's process is
/// suspended, so nothing of ours runs to call `AlarmManager.stop(id:)` after the
/// cutoff. (The old "silent stopper" alarms didn't wake the app either — they
/// only added a second alert.)
///
/// Fix: while any alarm or timer with an auto-stop cutoff is armed, hold a
/// silent, mix-with-others audio session. An app with active background audio
/// is not suspended, so the watcher's clock keeps ticking and it can stop the
/// ringing alert at exactly fire time + cutoff. If iOS kills the app anyway the
/// failure mode is safe: the alarm simply rings until stopped, like Apple's.
@MainActor
final class KeepAlive {
    static let shared = KeepAlive()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var configured = false
    private(set) var running = false
    private var bridge: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []

    func update(needed: Bool) {
        needed ? start() : stop()
    }

    private func start() {
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if !configured {
                engine.attach(player)
                let format = engine.outputNode.inputFormat(forBus: 0)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                engine.mainMixerNode.outputVolume = 0
                observe()
                configured = true
            }
            let format = engine.outputNode.inputFormat(forBus: 0)
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) {
                buffer.frameLength = buffer.frameCapacity          // zero-filled = silence
                player.scheduleBuffer(buffer, at: nil, options: .loops)
            }
            try engine.start()
            player.play()
            running = true
            AutoDismissWatcher.shared.record("Keep-alive on (silent background audio)")
        } catch {
            AutoDismissWatcher.shared.record("Keep-alive failed to start: \(error.localizedDescription)")
        }
    }

    private func stop() {
        guard running else { return }
        player.stop(); engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        running = false
        AutoDismissWatcher.shared.record("Keep-alive off (nothing armed)")
    }

    /// An alarm going off can interrupt our session. Bridge the gap with a
    /// background task (~30 s) and resume the silent audio as soon as allowed.
    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            Task { @MainActor in KeepAlive.shared.interrupted(began: type == .began) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in KeepAlive.shared.restart() }
        })
    }

    private func interrupted(began: Bool) {
        if began {
            if bridge == .invalid {
                bridge = UIApplication.shared.beginBackgroundTask(withName: "Chymee auto-stop bridge") {
                    Task { @MainActor in KeepAlive.shared.endBridge() }
                }
            }
            AutoDismissWatcher.shared.record("Audio interrupted — bridging with background time")
            // Try to come straight back; mixWithOthers usually allows it.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                KeepAlive.shared.restart()
            }
        } else {
            restart()
        }
    }

    private func restart() {
        guard running || configured else { return }
        running = false
        start()
        if running { endBridge() }
    }

    private func endBridge() {
        if bridge != .invalid { UIApplication.shared.endBackgroundTask(bridge); bridge = .invalid }
    }
}

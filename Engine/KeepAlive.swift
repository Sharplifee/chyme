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

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var configured = false
    private var observing = false
    private(set) var running = false
    /// True only while something with a cutoff is armed. Interruptions and
    /// media resets must never revive the keep-alive once nothing needs it.
    private var wanted = false
    private var bridge: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []
    private var retry: Task<Void, Never>?
    private var loggedFailure = false

    func update(needed: Bool) {
        wanted = needed
        needed ? start() : stop()
    }

    private func start() {
        guard wanted, !running else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if !observing { observe(); observing = true }
            if !configured {
                engine.attach(player)
                let format = engine.outputNode.inputFormat(forBus: 0)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                engine.mainMixerNode.outputVolume = 0
                configured = true
            }
            let format = engine.outputNode.inputFormat(forBus: 0)
            player.stop()   // drop any buffer queued by a failed attempt; retries must not pile up
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) {
                buffer.frameLength = buffer.frameCapacity          // zero-filled = silence
                player.scheduleBuffer(buffer, at: nil, options: .loops)
            }
            try engine.start()
            player.play()
            running = true
            loggedFailure = false
            AutoDismissWatcher.shared.record("Keep-alive on (silent background audio)")
        } catch {
            // Logged once per outage; retries happen every half second.
            if !loggedFailure {
                AutoDismissWatcher.shared.record("Keep-alive failed to start: \(error.localizedDescription)")
                loggedFailure = true
            }
        }
    }

    private func stop() {
        retry?.cancel(); retry = nil
        endBridge()
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
            Task { @MainActor in KeepAlive.shared.rebuild() }
        })
    }

    private func interrupted(began: Bool) {
        guard wanted else { return }
        if began {
            running = false
            if bridge == .invalid {
                bridge = UIApplication.shared.beginBackgroundTask(withName: "Chymee auto-stop bridge") {
                    Task { @MainActor in KeepAlive.shared.endBridge() }
                }
            }
            AutoDismissWatcher.shared.record("Audio interrupted — bridging with background time and retrying")
            // The ringing alert itself is usually the interruption. Keep trying
            // to take the silent session back for as long as the bridge lasts,
            // not just once, so long cutoffs still get their stop.
            retry?.cancel()
            retry = Task { @MainActor in
                for _ in 0..<120 {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    KeepAlive.shared.restart()
                    if KeepAlive.shared.running { return }
                }
            }
        } else {
            retry?.cancel(); retry = nil
            restart()
        }
    }

    private func restart() {
        guard wanted else { return }
        running = false
        start()
        if running {
            retry?.cancel(); retry = nil
            endBridge()
        }
    }

    /// After a media-services reset the old engine is dead; build a new one.
    private func rebuild() {
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        configured = false
        running = false
        restart()
    }

    private func endBridge() {
        if bridge != .invalid { UIApplication.shared.endBackgroundTask(bridge); bridge = .invalid }
    }
}

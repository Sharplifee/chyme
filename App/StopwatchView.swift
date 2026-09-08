import SwiftUI

struct StopwatchView: View {
    @EnvironmentObject var engine: AlarmEngine

    @State private var elapsed: TimeInterval = 0
    @State private var running = false
    @State private var laps: [TimeInterval] = []
    @State private var start: Date?

    // Preset start value — the stopwatch counts up from here.
    @State private var offset: TimeInterval = 0
    @State private var showPreset = false
    @State private var pHours = 0, pMinutes = 0, pSeconds = 0

    // Stopwatch alert: ring when the watch reaches a target, and stop itself
    // after its own auto-dismiss, exactly like alarms and timers.
    @State private var alertEnabled = false
    @State private var alertAt: TimeInterval = 600
    @State private var alertSound: String = ChymeSound.default.name
    @State private var alertDismiss: AutoDismiss = ChymeStore().defaultAutoDismiss
    @State private var alertFired = false
    @State private var alertID: UUID?

    private let tick = Timer.publish(every: 0.03, on: .main, in: .common).autoconnect()
    private var hasStarted: Bool { running || elapsed > offset }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text(format(elapsed))
                        .font(.system(size: 58, weight: .thin, design: .rounded))
                        .monospacedDigit()

                    if offset > 0 {
                        Text("started from \(format(offset))")
                            .font(.footnote).foregroundStyle(.orange)
                    }

                    if showPreset {
                        HStack(spacing: 0) {
                            wheel($pHours, 0..<24, "hours")
                            wheel($pMinutes, 0..<60, "min")
                            wheel($pSeconds, 0..<60, "sec")
                        }
                        .frame(height: 150)
                        Button("Set start time") { applyPreset() }
                            .buttonStyle(.bordered).tint(.orange)
                    } else if !hasStarted {
                        Button {
                            showPreset = true
                        } label: {
                            Label(offset > 0 ? "Change start time" : "Start from a preset time",
                                  systemImage: "dial.medium")
                        }
                        .buttonStyle(.bordered).tint(.orange)
                    }

                    HStack(spacing: 40) {
                        Button(running ? "Lap" : "Reset") {
                            if running { laps.insert(elapsed, at: 0) }
                            else { resetAll() }
                        }
                        .buttonStyle(.bordered)

                        Button(running ? "Stop" : "Start") { toggleRun() }
                            .buttonStyle(.borderedProminent)
                            .tint(running ? .red : .green)
                    }

                    alertSection

                    if !laps.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(laps.enumerated()), id: \.offset) { i, lap in
                                HStack {
                                    Text("Lap \(laps.count - i)")
                                    Spacer()
                                    Text(format(lap)).monospacedDigit()
                                }
                                .padding(.vertical, 8)
                                Divider()
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding()
            }
            .navigationTitle("Stopwatch")
            .onReceive(tick) { _ in
                guard running, let s = start else { return }
                elapsed = Date().timeIntervalSince(s)
            }
            .onAppear { if elapsed == 0 { elapsed = offset } }
        }
    }

    @ViewBuilder private var alertSection: some View {
        VStack(spacing: 10) {
            Toggle("Alert at a time", isOn: $alertEnabled)
                .tint(.orange)
                .disabled(running)

            if alertEnabled {
                Picker("Alert at", selection: $alertAt) {
                    ForEach(CrownDurations.values, id: \.self) {
                        Text(CrownDurations.label(for: $0)).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .disabled(running)

                NavigationLink {
                    SoundPickerView(selection: $alertSound)
                } label: {
                    HStack { Text("Sound"); Spacer()
                        Text(alertSound).foregroundStyle(.secondary) }
                }

                NavigationLink {
                    AutoDismissPickerView(selection: $alertDismiss)
                } label: {
                    HStack { Text("Stop ringing after"); Spacer()
                        Text(alertDismiss.label).foregroundStyle(.orange) }
                }
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func wheel(_ value: Binding<Int>, _ range: Range<Int>, _ unit: String) -> some View {
        HStack(spacing: 2) {
            Picker("", selection: value) {
                ForEach(range, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.wheel).frame(width: 60).clipped()
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func toggleRun() {
        running.toggle()
        if running {
            showPreset = false
            start = Date().addingTimeInterval(-elapsed)
            scheduleAlertIfNeeded()
        } else {
            start = nil
            cancelAlert()
        }
    }

    /// The alert is a real AlarmKit countdown so it rings with system priority and
    /// carries its own auto-dismiss, the same as an alarm or a timer.
    private func scheduleAlertIfNeeded() {
        guard alertEnabled, !alertFired else { return }
        let remaining = alertAt - elapsed
        guard remaining > 0 else { return }
        Task {
            let t = await engine.startTimer(duration: remaining,
                                            autoDismiss: alertDismiss,
                                            label: "Stopwatch",
                                            soundName: alertSound)
            await MainActor.run { alertID = t?.id; alertFired = true }
        }
    }

    private func cancelAlert() {
        guard let id = alertID else { return }
        Task { await engine.cancelTimer(id) }
        alertID = nil
        alertFired = false
    }

    private func resetAll() {
        elapsed = offset
        laps = []
        cancelAlert()
    }

    private func applyPreset() {
        offset = TimeInterval(pHours * 3600 + pMinutes * 60 + pSeconds)
        elapsed = offset
        laps = []
        showPreset = false
    }

    private func format(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let cs = Int((t - floor(t)) * 100)
        if h > 0 { return String(format: "%d:%02d:%02d.%02d", h, m, s, cs) }
        return String(format: "%02d:%02d.%02d", m, s, cs)
    }
}

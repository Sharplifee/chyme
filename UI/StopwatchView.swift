import SwiftUI

struct StopwatchView: View {
    @EnvironmentObject private var clock: ClockController
    @Environment(\.scenePhase) private var scenePhase
    @State private var state: StopwatchState = {
        guard let data = UserDefaults.standard.data(forKey: "stopwatch.v2"),
              let value = try? JSONDecoder().decode(StopwatchState.self, from: data) else { return StopwatchState() }
        return value
    }()
    @State private var preset = 0
    @State private var showPreset = false
    @AppStorage("stopwatch.alertEnabled") private var alertEnabled = false
    @AppStorage("stopwatch.alertSeconds") private var alertSeconds = 600
    @AppStorage("stopwatch.alertDismiss") private var alertDismissSeconds = 300
    private var alertDismiss: AutoDismiss { AutoDismiss(seconds: alertDismissSeconds) }
    private var dismissBinding: Binding<AutoDismiss> { Binding(get: { alertDismiss }, set: { alertDismissSeconds = $0.seconds }) }
    @AppStorage("stopwatch.alertSound") private var alertSound = "System"

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                TimelineView(.animation(minimumInterval: 0.05, paused: !state.running || scenePhase != .active)) { context in
                    Text(ClockText.duration(state.value(at: context.date), hundredths: true))
                        #if os(watchOS)
                        .font(.system(.title2, design: .rounded, weight: .light))
                        #else
                        .font(.system(size: 64, weight: .ultraLight, design: .rounded))
                        #endif
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                        .accessibilityLabel("Elapsed time").accessibilityValue(ClockText.duration(state.value(at: context.date)))
                }.padding(.top, 24)
                HStack(spacing: 16) {
                    ClockAction(title: state.running ? "Lap" : "Reset", symbol: state.running ? "flag.fill" : "arrow.counterclockwise", color: .gray) {
                        Task {
                            if state.running { state.lap() }
                            else {
                                if let id = state.alertID, !(await clock.send(ClockCommand(action: "cancelTimer", id: id))) { return }
                                state.reset()
                            }
                            save()
                        }
                    }
                    ClockAction(title: state.running ? "Stop" : "Start", symbol: state.running ? "pause.fill" : "play.fill", color: state.running ? .red : .green) {
                        Task { await toggle() }
                    }
                }.disabled(clock.busy)
                if state.preset > 0 { Text("Starting from \(ClockText.duration(state.preset))").font(.footnote).foregroundStyle(.secondary) }
                if !state.running && state.splits.isEmpty {
                    Button("Set Starting Time", systemImage: "dial.medium") { preset = Int(state.preset); showPreset = true }
                        .buttonStyle(.bordered)
                }
                DisclosureGroup("Stopwatch Alert") {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("Alert at a Time", isOn: $alertEnabled)
                        if alertEnabled {
                            DurationPicker(seconds: $alertSeconds)
                            NavigationLink { SoundPickerView(selection: $alertSound) } label: { LabeledContent("Sound", value: alertSound) }
                            NavigationLink { AutoDismissPickerView(selection: dismissBinding) } label: { LabeledContent("Stop Ringing After", value: alertDismiss.label) }
                        }
                    }.padding(.top, 12).disabled(state.running || clock.busy)
                }.padding().background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
                VStack(spacing: 0) {
                    ForEach(Array(state.lapDurations.enumerated().reversed()), id: \.offset) { index, duration in
                        HStack {
                            Text("Lap \(index + 1)")
                            Spacer()
                            Text(ClockText.duration(duration, hundredths: true)).monospacedDigit()
                        }.font(.body).padding(.vertical, 12)
                        Divider()
                    }
                }
            }.padding().frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
        }
        .navigationTitle("Stopwatch")
        .sheet(isPresented: $showPreset) {
            NavigationStack {
                Form {
                    DurationPicker(seconds: $preset)
                    Button("Set Starting Time") {
                        state.preset = Double(preset); state.reset(); save(); showPreset = false
                    }.disabled(state.alertID != nil)
                }.navigationTitle("Starting Time")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showPreset = false } } }
            }
        }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: "stopwatch.v2") }
    }
    private func toggle() async {
        if state.running {
            if let id = state.alertID {
                guard await clock.send(ClockCommand(action: "cancelTimer", id: id)) else { return }
                state.alertID = nil
            }
            state.pause()
        } else {
            if alertEnabled {
                let remaining = Double(alertSeconds) - state.value()
                guard remaining > 0 else { clock.error = "Choose an alert time later than the stopwatch’s current time."; return }
                let timer = ChymeTimer(label: "Stopwatch", duration: remaining, autoDismiss: alertDismiss, soundName: alertSound)
                guard await clock.send(ClockCommand(action: "startTimer", timer: timer)) else { return }
                state.alertID = timer.id
            }
            state.start()
        }
        save()
    }
}

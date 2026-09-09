import SwiftUI

struct TimersView: View {
    @EnvironmentObject private var clock: ClockController
    @State private var seconds = Int(ChymeStore().defaultComplicationDuration)
    @State private var label = ""
    @State private var autoDismiss = ChymeStore().defaultAutoDismiss
    @State private var sound = ChymeSound.default.name
    var body: some View {
        List {
            if !clock.snapshot.timers.isEmpty {
                Section("Active Timers") {
                    ForEach(clock.snapshot.timers) { timer in TimerCard(timer: timer) }
                }
            }
            Section("New Timer") {
                DurationPicker(seconds: $seconds)
                TextField("Label", text: $label)
                NavigationLink { SoundPickerView(selection: $sound) } label: { LabeledContent("Sound", value: sound) }
                NavigationLink { AutoDismissPickerView(selection: $autoDismiss) } label: { LabeledContent("Stop Ringing After", value: autoDismiss.label) }
                ClockAction(title: clock.busy ? "Starting…" : "Start Timer", symbol: "play.fill", color: .green) {
                    let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    let timer = ChymeTimer(label: name.isEmpty ? "Timer" : name, duration: Double(seconds), autoDismiss: autoDismiss, soundName: sound)
                    Task { await clock.send(ClockCommand(action: "startTimer", timer: timer)) }
                }.disabled(seconds == 0 || clock.busy).listRowBackground(Color.clear)
            }
            Section("Quick Set") {
                #if os(watchOS)
                ForEach([60, 180, 300, 600, 900, 1800, 3600], id: \.self) { value in
                    Button(CrownDurations.label(for: Double(value))) { seconds = value }
                }
                #else
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 12) {
                    ForEach([60, 180, 300, 600, 900, 1800, 3600], id: \.self) { value in
                        Button(CrownDurations.label(for: Double(value))) { seconds = value }
                            .buttonStyle(.bordered).frame(minHeight: 44)
                    }
                }.padding(.vertical, 8)
                #endif
            }
        }
        .navigationTitle("Timers")
        .onChange(of: clock.suggestedDuration) { _, value in
            if let value { seconds = value; clock.suggestedDuration = nil }
        }
        .onAppear { if let value = clock.suggestedDuration { seconds = value; clock.suggestedDuration = nil } }
    }
}

struct TimerCard: View {
    @EnvironmentObject private var clock: ClockController
    let timer: ChymeTimer
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = timer.remaining(at: context.date)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(timer.label).font(.headline)
                    Spacer()
                    if timer.isPaused { Text("Paused").font(.caption).foregroundStyle(.secondary) }
                }
                Text(timer.endsAt == nil && !timer.isPaused ? "Refresh Timer" : ClockText.duration(remaining))
                    .font(.system(.largeTitle, design: .rounded, weight: .light))
                    .monospacedDigit().foregroundStyle(.orange)
                    .contentTransition(.numericText()).minimumScaleFactor(0.6).lineLimit(1)
                if remaining == 0 && timer.endsAt != nil { Text("Time’s up").font(.subheadline) }
                HStack {
                    if remaining > 0 {
                        Button(timer.isPaused ? "Resume" : "Pause", systemImage: timer.isPaused ? "play.fill" : "pause.fill") {
                            Task { await clock.send(ClockCommand(action: timer.isPaused ? "resumeTimer" : "pauseTimer", id: timer.id)) }
                        }.buttonStyle(.bordered).tint(.orange)
                    }
                    Spacer()
                    Button(remaining == 0 ? "Stop" : "Cancel", systemImage: "xmark") {
                        Task { await clock.send(ClockCommand(action: "cancelTimer", id: timer.id)) }
                    }.buttonStyle(.bordered).tint(.secondary)
                }.disabled(clock.busy)
            }.padding(.vertical, 8)
        }
    }
}

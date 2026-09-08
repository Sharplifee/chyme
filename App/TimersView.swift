import SwiftUI

struct TimersView: View {
    @EnvironmentObject var engine: AlarmEngine
    @State private var duration: TimeInterval = 300
    @State private var autoDismiss: AutoDismiss = ChymeStore().defaultAutoDismiss
    @State private var soundName: String = ChymeSound.default.name

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Duration", selection: $duration) {
                        ForEach(CrownDurations.values, id: \.self) {
                            Text(CrownDurations.label(for: $0)).tag($0)
                        }
                    }
                    .pickerStyle(.wheel)
                }

                Section {
                    NavigationLink {
                        SoundPickerView(selection: $soundName)
                    } label: {
                        HStack { Text("When timer ends"); Spacer()
                            Text(soundName).foregroundStyle(.secondary) }
                    }
                    NavigationLink {
                        AutoDismissPickerView(selection: $autoDismiss)
                    } label: {
                        HStack { Text("Stop ringing after"); Spacer()
                            Text(autoDismiss.label).foregroundStyle(.orange) }
                    }
                }

                Section {
                    Button("Start") {
                        Task {
                            await engine.startTimer(duration: duration,
                                                    autoDismiss: autoDismiss,
                                                    label: "Timer",
                                                    soundName: soundName)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.green)
                }

                if !engine.timers.isEmpty {
                    Section("Running") {
                        ForEach(engine.timers) { t in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(CrownDurations.label(for: t.duration))
                                    Text("\(t.soundName) · stops after \(t.autoDismiss.label)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Cancel") { Task { await engine.cancelTimer(t.id) } }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Timers")
        }
    }
}

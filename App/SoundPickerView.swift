import SwiftUI

/// Shared sound picker used by alarms, timers and the stopwatch alert.
struct SoundPickerView: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(ChymeSound.all) { sound in
                    Button {
                        selection = sound.name
                    } label: {
                        HStack {
                            Text(sound.name).foregroundStyle(.primary)
                            Spacer()
                            if selection == sound.name {
                                Image(systemName: "checkmark").foregroundStyle(.orange)
                            }
                        }
                    }
                }
            } header: {
                Text("Alert sound")
            } footer: {
                Text("Plays when the alarm, timer or stopwatch alert fires.")
            }
        }
        .navigationTitle("Sound")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Shared auto-dismiss picker. Every alerting feature in Chyme uses this.
struct AutoDismissPickerView: View {
    @Binding var selection: AutoDismiss

    var body: some View {
        List {
            Section {
                ForEach(AutoDismiss.presets, id: \.self) { preset in
                    Button {
                        selection = preset
                    } label: {
                        HStack {
                            Text(preset.label).foregroundStyle(.primary)
                            Spacer()
                            if selection == preset {
                                Image(systemName: "checkmark").foregroundStyle(.orange)
                            }
                        }
                    }
                }
            } header: {
                Text("Stop ringing after")
            } footer: {
                Text("Chyme stops the alert itself once this time has passed. “Until stopped” behaves like every other clock app.")
            }
        }
        .navigationTitle("Stop ringing after")
        .navigationBarTitleDisplayMode(.inline)
    }
}

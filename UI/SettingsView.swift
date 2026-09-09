import SwiftUI

struct SettingsView: View {
    @State private var duration = Int(ChymeStore().defaultComplicationDuration)
    @State private var dismiss = ChymeStore().defaultAutoDismiss
    var body: some View {
        Form {
            Section("Defaults on This Device") {
                NavigationLink { DurationPicker(seconds: $duration).padding().navigationTitle("Default Timer") } label: {
                    LabeledContent("Timer", value: ClockText.duration(Double(duration)))
                }
                NavigationLink { AutoDismissPickerView(selection: $dismiss) } label: { LabeledContent("Stop Ringing After", value: dismiss.label) }
            }
            Section("Watch Face") {
                Label("Timer · Alarms · Stopwatch", systemImage: "applewatch")
                Text("Touch and hold your watch face, tap Edit, then select a complication slot and choose Chymee. Edit the Timer complication to choose its duration. Available shapes depend on your watch face.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Connected Alarms") {
                Text("iPhone schedules your alarms and timers. Keep it nearby to create or change them from Watch. Scheduled alerts are managed by iOS and can appear on the paired Watch even while Chymee is in the background. The stopwatch works independently on each device.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Settings")
        .onChange(of: duration) { _, value in ChymeStore().defaultComplicationDuration = Double(max(1, value)) }
        .onChange(of: dismiss) { _, value in ChymeStore().defaultAutoDismiss = value }
    }
}

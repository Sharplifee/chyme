import SwiftUI

struct SettingsView: View {
    @State private var duration = Int(ChymeStore().defaultComplicationDuration)
    @State private var dismiss = ChymeStore().defaultAutoDismiss
    #if os(watchOS)
    @State private var complicationCheck = "Checking…"
    #endif
    var body: some View {
        Form {
            Section("Defaults on This Device") {
                NavigationLink { DurationPicker(seconds: $duration).padding().navigationTitle("Default Timer") } label: {
                    LabeledContent("Timer", value: ClockText.duration(Double(duration)))
                }
                NavigationLink { AutoDismissPickerView(selection: $dismiss) } label: { LabeledContent("Stop Ringing After", value: dismiss.label) }
            }
            #if os(iOS)
            Section {
                NavigationLink("Alert Diagnostics") { AlertDiagnosticsView() }
            }
            #endif
            Section("Watch Face") {
                Label("Chymee · Timer · Alarms · Stopwatch", systemImage: "applewatch")
                Text("Touch and hold your watch face, tap Edit, then select any complication slot and choose Chymee. Each one is live: a running timer counts down, a running stopwatch counts up, and Alarms shows the next alarm on the watch. The Chymee complication shows whichever is active. They fit every slot shape: circle, corner, one line, and rectangle.")
                    .font(.footnote).foregroundStyle(.secondary)
                #if os(watchOS)
                LabeledContent("Live data", value: complicationCheck)
                #endif
            }
            Section("iPhone and Apple Watch") {
                Text("Each device runs its own alarms, timers and stopwatch. Neither needs the other, and starting or cancelling something on one leaves the other alone. Turn on Also on \(DeviceText.other) for an alarm or timer you want on both: that one item is then kept in step, and cancelling it on either device cancels it on both.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Settings")
        #if os(watchOS)
        .onAppear { complicationCheck = SharedState.selfTest() }
        #endif
        .onChange(of: duration) { _, value in ChymeStore().defaultComplicationDuration = Double(max(1, value)) }
        .onChange(of: dismiss) { _, value in ChymeStore().defaultAutoDismiss = value }
    }
}

#if os(iOS)
private struct AlertDiagnosticsView: View {
    @ObservedObject private var monitor = AutoDismissWatcher.shared
    private var report: String { monitor.events.joined(separator: "\n") }
    var body: some View {
        ScrollView {
            Text(report.isEmpty ? "No alert events recorded yet." : report)
                .font(.caption.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle("Alert Diagnostics")
        .toolbar { ShareLink(item: report) { Label("Share", systemImage: "square.and.arrow.up") } }
    }
}
#endif

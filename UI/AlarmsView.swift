import SwiftUI

struct AlarmsView: View {
    @EnvironmentObject private var clock: ClockController
    @State private var editing: ChymeAlarm?
    @State private var deleting: ChymeAlarm?
    var body: some View {
        List {
            if clock.snapshot.alarms.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "alarm").font(.largeTitle).foregroundStyle(.orange)
                    Text("No Alarms").font(.headline)
                    Text("Add an alarm for your next morning or moment.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Add Alarm", systemImage: "plus") { add() }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity).padding(.vertical, 24).listRowBackground(Color.clear)
            }
            ForEach(clock.snapshot.alarms) { alarm in
                HStack(spacing: 12) {
                    Button { editing = alarm } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(ClockText.time(alarm.minuteOfDay))
                                #if os(watchOS)
                                .font(.title2)
                                #else
                                .font(.system(.largeTitle, design: .rounded, weight: .light))
                                #endif
                                .monospacedDigit().foregroundStyle(alarm.isEnabled ? .primary : .secondary)
                            Text(alarm.label).font(.subheadline).foregroundStyle(.primary)
                            Text(ClockText.repeatLabel(alarm.repeatDays)).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Edit \(alarm.label), \(ClockText.time(alarm.minuteOfDay))")
                    Toggle("Enable \(alarm.label)", isOn: Binding(get: { alarm.isEnabled }, set: { value in
                        var changed = alarm; changed.isEnabled = value
                        Task { await clock.send(ClockCommand(action: "saveAlarm", alarm: changed)) }
                    })).labelsHidden().tint(.orange).disabled(clock.busy)
                }
                .padding(.vertical, 8)
                .swipeActions { Button("Delete", role: .destructive) { deleting = alarm } }
            }
        }
        .navigationTitle("Alarms")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Add Alarm", systemImage: "plus") { add() } } }
        .sheet(item: $editing) { alarm in NavigationStack { AlarmEditor(alarm: alarm) }.environmentObject(clock) }
        .confirmationDialog("Delete this alarm?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Alarm", role: .destructive) {
                if let alarm = deleting { Task { await clock.send(ClockCommand(action: "deleteAlarm", id: alarm.id)) } }
                deleting = nil
            }
        }
    }
    private func add() { editing = ChymeAlarm(minuteOfDay: 420, soundName: ChymeSound.default.name, autoDismiss: ChymeStore().defaultAutoDismiss) }
}

struct AlarmEditor: View {
    @EnvironmentObject private var clock: ClockController
    @Environment(\.dismiss) private var dismiss
    @State var alarm: ChymeAlarm
    var time: Binding<Date> {
        Binding(get: { Calendar.current.startOfDay(for: .now).addingTimeInterval(Double(alarm.minuteOfDay * 60)) }, set: {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
            alarm.minuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }
    var body: some View {
        Form {
            Section {
                #if os(watchOS)
                Picker("Hour", selection: Binding(get: { alarm.hour }, set: { alarm.minuteOfDay = $0 * 60 + alarm.minute })) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                Picker("Minute", selection: Binding(get: { alarm.minute }, set: { alarm.minuteOfDay = alarm.hour * 60 + $0 })) {
                    ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                #else
                DatePicker("Time", selection: time, displayedComponents: .hourAndMinute).datePickerStyle(.wheel).labelsHidden()
                #endif
            }
            Section {
                TextField("Label", text: $alarm.label)
                NavigationLink { RepeatPicker(days: $alarm.repeatDays) } label: {
                    LabeledContent("Repeat", value: ClockText.repeatLabel(alarm.repeatDays))
                }
                NavigationLink { SoundPickerView(selection: $alarm.soundName) } label: {
                    LabeledContent("Sound", value: ChymeSound.resolved(alarm.soundName))
                }
                Toggle("Snooze", isOn: $alarm.snoozeEnabled).tint(.orange)
                NavigationLink { AutoDismissPickerView(selection: $alarm.autoDismiss) } label: {
                    LabeledContent("Stop Ringing After", value: alarm.autoDismiss.label)
                }
            }
        }
        .navigationTitle("Edit Alarm")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    alarm.label = alarm.label.trimmingCharacters(in: .whitespacesAndNewlines)
                    if alarm.label.isEmpty { alarm.label = "Alarm" }
                    Task { if await clock.send(ClockCommand(action: "saveAlarm", alarm: alarm)) { dismiss() } }
                }.disabled(clock.busy)
            }
        }
        .alert("Couldn’t Save Alarm", isPresented: Binding(get: { clock.error != nil }, set: { if !$0 { clock.error = nil } })) {
            Button("OK") { clock.error = nil }
        } message: { Text(clock.error ?? "") }
    }
}

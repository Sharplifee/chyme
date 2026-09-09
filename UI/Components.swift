import SwiftUI

struct DurationPicker: View {
    @Binding var seconds: Int
    var maximumHours: Int = 23
    private func part(_ divisor: Int, modulus: Int) -> Binding<Int> {
        Binding(get: { seconds / divisor % modulus }, set: { seconds += ($0 - seconds / divisor % modulus) * divisor })
    }
    var body: some View {
        HStack(spacing: 0) {
            column("Hours", short: "hr", value: part(3600, modulus: maximumHours + 1), range: 0..<(maximumHours + 1))
            column("Minutes", short: "min", value: part(60, modulus: 60), range: 0..<60)
            column("Seconds", short: "sec", value: part(1, modulus: 60), range: 0..<60)
        }
        #if os(watchOS)
        .frame(height: 100)
        #else
        .frame(height: 170)
        #endif
    }
    private func column(_ title: String, short: String, value: Binding<Int>, range: Range<Int>) -> some View {
        VStack(spacing: 0) {
            Picker(title, selection: value) { ForEach(range, id: \.self) { Text("\($0)").tag($0) } }
                .pickerStyle(.wheel).labelsHidden()
                .accessibilityLabel(title)
            Text(short).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

struct ClockAction: View {
    let title: String
    let symbol: String
    var color: Color = .orange
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent).tint(color)
    }
}

struct RepeatPicker: View {
    @Binding var days: Set<Int>
    var body: some View {
        List {
            Button("Every day") { days = Set(1...7) }
            Button("Weekdays") { days = Set(2...6) }
            Button("Never") { days = [] }
            Section {
                ForEach([2,3,4,5,6,7,1], id: \.self) { day in
                    Button {
                        if days.contains(day) { days.remove(day) } else { days.insert(day) }
                    } label: {
                        HStack {
                            Text(Calendar.current.weekdaySymbols[day - 1]).foregroundStyle(.primary)
                            Spacer()
                            if days.contains(day) { Image(systemName: "checkmark").foregroundStyle(.orange) }
                        }
                    }.accessibilityValue(days.contains(day) ? "Selected" : "Not selected")
                }
            }
        }.navigationTitle("Repeat")
    }
}

struct AutoDismissPickerView: View {
    @Binding var selection: AutoDismiss
    @State private var customSeconds = 300
    private var enabled: Binding<Bool> {
        Binding(get: { selection.isEnabled }, set: { value in
            selection = AutoDismiss(seconds: value ? max(1, customSeconds) : 0)
        })
    }
    var body: some View {
        Form {
            Section {
                Toggle("Stop Automatically", isOn: enabled).tint(.orange)
                if selection.isEnabled {
                    DurationPicker(seconds: $customSeconds, maximumHours: 99)
                    Text("Stop after " + AutoDismiss(seconds: max(1, customSeconds)).label)
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                #if os(watchOS)
                Text("Tap hours, minutes, or seconds, then turn the Digital Crown. Minimum duration is 1 second.")
                #else
                Text("Choose hours, minutes, and seconds. Minimum duration is 1 second.")
                #endif
            }
            Section {
                Text("Automatic stopping requires Chymee to remain active on iPhone. If iOS suspends the app, the alert may continue until stopped.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Stop Ringing After")
        .onAppear { customSeconds = min(359999, max(1, selection.isEnabled ? selection.seconds : 300)) }
        .onChange(of: customSeconds) { _, value in
            if selection.isEnabled { selection = AutoDismiss(seconds: max(1, value)) }
        }
    }
}

import SwiftUI

struct DurationPicker: View {
    @Binding var seconds: Int
    private func part(_ divisor: Int, modulus: Int) -> Binding<Int> {
        Binding(get: { seconds / divisor % modulus }, set: { seconds += ($0 - seconds / divisor % modulus) * divisor })
    }
    var body: some View {
        HStack(spacing: 0) {
            column("Hours", short: "hr", value: part(3600, modulus: 24), range: 0..<24)
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
    var body: some View {
        List {
            Section {
                ForEach(AutoDismiss.presets, id: \.self) { value in
                    Button { selection = value } label: {
                        HStack {
                            Text(value.label).foregroundStyle(.primary); Spacer()
                            if selection == value { Image(systemName: "checkmark").foregroundStyle(.orange) }
                        }
                    }.accessibilityValue(selection == value ? "Selected" : "Not selected")
                }
            } footer: {
                Text("Automatic stopping requires Chymee to remain active on iPhone. If iOS suspends the app, the alert may continue until stopped.")
            }
        }.navigationTitle("Stop Ringing After")
    }
}

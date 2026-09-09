import WidgetKit
import SwiftUI
import AppIntents

struct TimerConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Timer"
    static let description = IntentDescription("Choose the duration to open on your watch.")
    @Parameter(title: "Minutes", default: 5) var minutes: Int
}
struct ClockEntry: TimelineEntry {
    let date: Date
    var minutes: Int = 5
}
struct ConfiguredTimerProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ClockEntry { ClockEntry(date: .now) }
    func snapshot(for configuration: TimerConfiguration, in context: Context) async -> ClockEntry {
        ClockEntry(date: .now, minutes: min(1439, max(1, configuration.minutes)))
    }
    func timeline(for configuration: TimerConfiguration, in context: Context) async -> Timeline<ClockEntry> {
        Timeline(entries: [await snapshot(for: configuration, in: context)], policy: .never)
    }
}
struct ClockProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClockEntry { ClockEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (ClockEntry) -> Void) { completion(ClockEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ClockEntry>) -> Void) {
        completion(Timeline(entries: [ClockEntry(date: .now)], policy: .never))
    }
}
struct ClockComplicationFace: View {
    @Environment(\.widgetFamily) private var family
    let title: String
    let subtitle: String
    let symbol: String
    let url: URL
    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack { AccessoryWidgetBackground(); Image(systemName: symbol).font(.title2) }
            case .accessoryCorner:
                Image(systemName: symbol).font(.title2).widgetLabel { Text(subtitle) }
            case .accessoryInline:
                Label(subtitle, systemImage: symbol)
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    Image(systemName: symbol).font(.title2)
                    VStack(alignment: .leading) {
                        Text(title).font(.headline)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            default: Image(systemName: symbol)
            }
        }
        .widgetURL(url)
        .containerBackground(.clear, for: .widget)
        .accessibilityLabel("Chymee \(title). \(subtitle)")
    }
}
struct ChymeTimerComplication: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ChymeTimerComplication", intent: TimerConfiguration.self, provider: ConfiguredTimerProvider()) { entry in
            ClockComplicationFace(title: "Timer", subtitle: "\(entry.minutes) min", symbol: "timer",
                url: URL(string: "chymee://timers?seconds=\(entry.minutes * 60)")!)
        }
        .configurationDisplayName("Timer")
        .description("Choose a duration. Tap to review and start it.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}
struct AlarmsComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ChymeeAlarms", provider: ClockProvider()) { _ in
            ClockComplicationFace(title: "Alarms", subtitle: "Open alarms", symbol: "alarm.fill", url: URL(string: "chymee://alarms")!)
        }.configurationDisplayName("Alarms").description("Add, edit, and switch your alarms on or off.")
            .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}
struct StopwatchComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ChymeeStopwatch", provider: ClockProvider()) { _ in
            ClockComplicationFace(title: "Stopwatch", subtitle: "Open stopwatch", symbol: "stopwatch.fill", url: URL(string: "chymee://stopwatch")!)
        }.configurationDisplayName("Stopwatch").description("Open your stopwatch and record a lap.")
            .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}
@main struct ChymeWatchWidgetBundle: WidgetBundle {
    var body: some Widget { ChymeTimerComplication(); AlarmsComplication(); StopwatchComplication() }
}

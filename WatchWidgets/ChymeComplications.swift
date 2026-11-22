import WidgetKit
import SwiftUI
import AppIntents

// Live complications for every slot shape watchOS has (circle, corner, one
// line, rectangle). The watch app writes its state to shared storage and asks
// WidgetKit to reload; countdowns and the stopwatch are drawn from anchors, so
// they keep ticking on the face by themselves between reloads.

struct TimerConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Timer"
    static let description = IntentDescription("Choose the duration this complication opens when no timer is running.")
    @Parameter(title: "Minutes", default: 5) var minutes: Int
}

struct ClockEntry: TimelineEntry {
    let date: Date
    var minutes: Int = 5
    var state = ComplicationState()
}

/// What one complication draws at one moment.
enum LiveContent {
    case countdown(label: String, end: Date)
    case countUp(label: String, anchor: Date)
    case clock(label: String, date: Date)
    case fixed(label: String, text: String)
    case idle(title: String, subtitle: String)

    var isLive: Bool { if case .idle = self { return false } else { return true } }
}

enum ComplicationKind { case timer, alarms, stopwatch, everything }

extension ComplicationState {
    func timerContent(at date: Date, minutes: Int) -> LiveContent {
        if let running = runningTimer(at: date), let end = running.endsAt {
            return .countdown(label: running.label, end: end)
        }
        if let paused = pausedTimer, let left = paused.pausedRemaining {
            return .fixed(label: paused.label + " paused", text: ClockText.duration(left))
        }
        return .idle(title: "Timer", subtitle: "\(minutes) min")
    }
    func stopwatchContent(at date: Date) -> LiveContent {
        if let anchor = stopwatchAnchor, anchor <= date { return .countUp(label: "Stopwatch", anchor: anchor) }
        if let paused = stopwatchPaused { return .fixed(label: "Stopwatch paused", text: ClockText.duration(paused)) }
        return .idle(title: "Stopwatch", subtitle: "Start")
    }
    func alarmContent(at date: Date) -> LiveContent {
        if let alarm = nextAlarm, alarm.addingTimeInterval(60) > date {
            return .clock(label: nextAlarmLabel ?? "Alarm", date: alarm)
        }
        return .idle(title: "Alarms", subtitle: "None set")
    }
    /// Whatever is active right now: a running timer, else the stopwatch, else the next alarm.
    func anyContent(at date: Date, minutes: Int) -> (LiveContent, String, URL) {
        let timer = timerContent(at: date, minutes: minutes)
        if case .countdown = timer { return (timer, "timer", URL(string: "chymee://timers")!) }
        let stopwatch = stopwatchContent(at: date)
        if case .countUp = stopwatch { return (stopwatch, "stopwatch.fill", URL(string: "chymee://stopwatch")!) }
        let alarm = alarmContent(at: date)
        if alarm.isLive { return (alarm, "alarm.fill", URL(string: "chymee://alarms")!) }
        if timer.isLive { return (timer, "timer", URL(string: "chymee://timers")!) }
        if stopwatch.isLive { return (stopwatch, "stopwatch.fill", URL(string: "chymee://stopwatch")!) }
        return (.idle(title: "Chymee", subtitle: "\(minutes) min"), "timer", URL(string: "chymee://timers?seconds=\(minutes * 60)")!)
    }
}

/// One entry now, plus one at every moment the face must change (a timer
/// ending, an alarm passing), so nothing stale is left showing.
private func entries(minutes: Int) -> Timeline<ClockEntry> {
    let state = SharedState.load()
    let now = Date()
    var dates = [now]
    dates.append(contentsOf: state.boundaries(after: now).prefix(8).map { $0.addingTimeInterval(0.5) })
    let list = dates.map { ClockEntry(date: $0, minutes: minutes, state: state) }
    // The app reloads on every change; the hourly refresh is only a safety net.
    return Timeline(entries: list, policy: .after((dates.last ?? now).addingTimeInterval(3600)))
}

struct ConfiguredTimerProvider: AppIntentTimelineProvider {
    func recommendations() -> [AppIntentRecommendation<TimerConfiguration>] {
        [1, 3, 5, 10, 15, 30].map { minutes in
            let configuration = TimerConfiguration()
            configuration.minutes = minutes
            // LocalizedStringResource traps when built from a runtime interpolation;
            // go through the string-literal initialiser with an already-formed String.
            let text = "\(minutes) minute timer"
            return AppIntentRecommendation(intent: configuration,
                                           description: LocalizedStringResource(stringLiteral: text))
        }
    }
    func placeholder(in context: Context) -> ClockEntry { ClockEntry(date: .now) }
    func snapshot(for configuration: TimerConfiguration, in context: Context) async -> ClockEntry {
        ClockEntry(date: .now, minutes: min(1439, max(1, configuration.minutes)), state: SharedState.load())
    }
    func timeline(for configuration: TimerConfiguration, in context: Context) async -> Timeline<ClockEntry> {
        entries(minutes: min(1439, max(1, configuration.minutes)))
    }
}

struct ClockProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClockEntry { ClockEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (ClockEntry) -> Void) {
        completion(ClockEntry(date: .now, state: SharedState.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ClockEntry>) -> Void) {
        completion(entries(minutes: 5))
    }
}

struct ClockComplicationFace: View {
    @Environment(\.widgetFamily) private var family
    let content: LiveContent
    let symbol: String
    let url: URL
    let now: Date

    /// The moving part: a countdown, a count-up, a clock time, or plain text.
    private var value: Text {
        switch content {
        case .countdown(_, let end): return Text(timerInterval: now...max(now, end), countsDown: true)
        case .countUp(_, let anchor): return Text(anchor, style: .timer)
        case .clock(_, let date): return Text(date, style: .time)
        case .fixed(_, let text): return Text(text)
        case .idle(_, let subtitle): return Text(subtitle)
        }
    }
    private var title: String {
        switch content {
        case .countdown(let label, _), .countUp(let label, _), .clock(let label, _), .fixed(let label, _): return label
        case .idle(let title, _): return title
        }
    }
    private var spoken: String {
        switch content {
        case .countdown(let label, let end): return "\(label), ends \(end.formatted(date: .omitted, time: .shortened))"
        case .countUp(let label, _): return "\(label) running"
        case .clock(let label, let date): return "\(label), \(date.formatted(date: .omitted, time: .shortened))"
        case .fixed(let label, let text): return "\(label), \(text)"
        case .idle(let title, let subtitle): return "\(title), \(subtitle)"
        }
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    if content.isLive {
                        VStack(spacing: 0) {
                            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                            value.font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                                .multilineTextAlignment(.center).minimumScaleFactor(0.5).lineLimit(1)
                        }.padding(.horizontal, 3)
                    } else {
                        Image(systemName: symbol).font(.title2)
                    }
                }
            case .accessoryCorner:
                Image(systemName: symbol).font(.title2).widgetLabel { value.monospacedDigit() }
            case .accessoryInline:
                Label { value.monospacedDigit() } icon: { Image(systemName: symbol) }
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    Image(systemName: symbol).font(.title2)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(.headline).lineLimit(1)
                        value.font(content.isLive ? .system(.title3, design: .rounded).weight(.medium) : .caption)
                            .monospacedDigit().foregroundStyle(content.isLive ? .primary : .secondary).lineLimit(1)
                        if case .countdown(_, let end) = content {
                            Text("Ends \(end.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            default:
                Image(systemName: symbol)
            }
        }
        .widgetURL(url)
        .containerBackground(.clear, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chymee. \(spoken)")
    }
}

private let allFamilies: [WidgetFamily] = [.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular]

struct ChymeLiveComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ChymeeLive", provider: ClockProvider()) { entry in
            let resolved = entry.state.anyContent(at: entry.date, minutes: entry.minutes)
            ClockComplicationFace(content: resolved.0, symbol: resolved.1, url: resolved.2, now: entry.date)
        }
        .configurationDisplayName("Chymee")
        .description("Shows whatever is active on this watch: a running timer, the stopwatch, or your next alarm.")
        .supportedFamilies(allFamilies)
    }
}
struct ChymeTimerComplication: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ChymeTimerComplication", intent: TimerConfiguration.self, provider: ConfiguredTimerProvider()) { entry in
            let content = entry.state.timerContent(at: entry.date, minutes: entry.minutes)
            ClockComplicationFace(content: content, symbol: "timer",
                url: content.isLive ? URL(string: "chymee://timers")! : URL(string: "chymee://timers?seconds=\(entry.minutes * 60)")!,
                now: entry.date)
        }
        .configurationDisplayName("Timer")
        .description("Counts down the running timer. With none running, tap to open your chosen duration.")
        .supportedFamilies(allFamilies)
    }
}
struct AlarmsComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ChymeeAlarms", provider: ClockProvider()) { entry in
            ClockComplicationFace(content: entry.state.alarmContent(at: entry.date), symbol: "alarm.fill",
                                  url: URL(string: "chymee://alarms")!, now: entry.date)
        }
        .configurationDisplayName("Alarms")
        .description("Shows the next alarm set on this watch.")
        .supportedFamilies(allFamilies)
    }
}
struct StopwatchComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ChymeeStopwatch", provider: ClockProvider()) { entry in
            ClockComplicationFace(content: entry.state.stopwatchContent(at: entry.date), symbol: "stopwatch.fill",
                                  url: URL(string: "chymee://stopwatch")!, now: entry.date)
        }
        .configurationDisplayName("Stopwatch")
        .description("Counts up while the stopwatch on this watch is running.")
        .supportedFamilies(allFamilies)
    }
}
@main struct ChymeWatchWidgetBundle: WidgetBundle {
    var body: some Widget { ChymeLiveComplication(); ChymeTimerComplication(); AlarmsComplication(); StopwatchComplication() }
}

import WidgetKit
import SwiftUI
import ActivityKit
#if canImport(AlarmKit)
import AlarmKit

struct ChymeAlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<ChymeMetadata>.self) { context in
            HStack(spacing: 16) {
                Image(systemName: "timer").font(.title).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text(context.attributes.presentation.alert.title).font(.headline)
                    ClockActivityTime(state: context.state).font(.system(.title, design: .rounded)).monospacedDigit()
                }
                Spacer()
                if let id = context.attributes.metadata?.id {
                    ClockActivityControls(id: id, state: context.state)
                }
            }.padding().activityBackgroundTint(.black).activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "timer").foregroundStyle(.orange) }
                DynamicIslandExpandedRegion(.trailing) { ClockActivityTime(state: context.state).monospacedDigit() }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.attributes.presentation.alert.title).font(.headline)
                        Spacer()
                        if let id = context.attributes.metadata?.id {
                            ClockActivityControls(id: id, state: context.state)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "timer").foregroundStyle(.orange)
            } compactTrailing: {
                ClockActivityTime(state: context.state).monospacedDigit().frame(maxWidth: 70)
            } minimal: {
                Image(systemName: "timer").foregroundStyle(.orange)
            }
            .keylineTint(.orange).widgetURL(URL(string: "chymee://timers"))
        }
    }
}
struct ClockActivityControls: View {
    let id: UUID
    let state: AlarmPresentationState
    var body: some View {
        HStack {
            switch state.mode {
            case .countdown:
                Button(intent: ChymePauseIntent(alarmID: id)) { Image(systemName: "pause.fill") }
                    .accessibilityLabel("Pause")
                Button(intent: ChymeCancelIntent(alarmID: id)) { Image(systemName: "xmark") }
                    .accessibilityLabel("Cancel timer")
            case .paused:
                Button(intent: ChymeResumeIntent(alarmID: id)) { Image(systemName: "play.fill") }
                    .accessibilityLabel("Resume")
                Button(intent: ChymeCancelIntent(alarmID: id)) { Image(systemName: "xmark") }
                    .accessibilityLabel("Cancel timer")
            case .alert:
                Button(intent: ChymeStopIntent(alarmID: id)) { Image(systemName: "stop.fill") }
                    .accessibilityLabel("Stop")
            @unknown default: EmptyView()
            }
        }.buttonStyle(.bordered).tint(.orange)
    }
}
struct ClockActivityTime: View {
    let state: AlarmPresentationState
    var body: some View {
        switch state.mode {
        case .countdown(let value):
            Text(timerInterval: value.startDate...value.fireDate, countsDown: true)
        case .paused: Text("Paused")
        case .alert: Text("Time’s up")
        @unknown default: Text("Chymee")
        }
    }
}
@main struct ChymeWidgetBundle: WidgetBundle { var body: some Widget { ChymeAlarmLiveActivity() } }
#endif

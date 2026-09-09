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
                    Button(intent: ChymeStopIntent(alarmID: id)) { Image(systemName: "stop.fill").padding(12) }
                        .buttonStyle(.bordered).tint(.orange).accessibilityLabel("Stop")
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
                            Button(intent: ChymeStopIntent(alarmID: id)) { Label("Stop", systemImage: "stop.fill") }
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

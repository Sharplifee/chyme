# Chymee native release validation

The existing GitHub workflow generates the project, archives and signs the iOS and Watch targets, exports the distribution builds, and uploads to TestFlight. The additional simulator and core-test release gates have been removed. The checks below can be exercised using the internal TestFlight build.

## System integration

| Behavior | Implementation | Verification boundary |
| --- | --- | --- |
| Scheduled alarms and timers | AlarmKit authorization, relative recurrence and countdown scheduling | Locked-device delivery requires physical-device testing |
| Mirrored Watch alerts | AlarmKit system presentation on a paired Watch | Test paired, wrist-down, locked-phone and disconnected cases |
| Watch creation/editing | Acknowledged WatchConnectivity commands to the iPhone | Requires a reachable paired iPhone; commands are not queued for a surprising late execution |
| Background state delivery | Latest application context, activation retry, persistent Watch snapshot, WatchConnectivity background-task completion | Delivery timing is controlled by the system |
| Lock Screen/Dynamic Island | ActivityKit countdown/paused state and App Intents for pause, resume, cancel and stop | Exercise each control on physical hardware |
| Countdown recovery | Read and observe system Live Activity state after background controls | Verify pause/resume while Chymee is suspended |
| Watch complications | Timer duration recommendations and Timer, Alarms, Stopwatch launchers in circular, corner, inline and rectangular families | Launchers do not display live synchronized alarm/timer state |
| Stopwatch | Persisted timestamps, elapsed time, laps and optional phone-scheduled alert | Stopwatch state is independent per device; stopping remains local if alert cancellation cannot reach iPhone |
| Timed automatic stopping | Persisted observed deadlines, bounded background execution, three stop attempts and local diagnostics | Not guaranteed while iOS suspends or terminates Chymee; no unrestricted background execution is claimed |

## Physical-device acceptance pass

Use the newly uploaded TestFlight build on an iPhone and its paired Watch, launched normally without the Xcode debugger.

1. Allow alarms; schedule a one-minute timer; lock the phone and lower the Watch wrist. Confirm alert delivery and dismiss from Watch.
2. Repeat with Silent Mode, Focus and Low Power Mode. Record actual results rather than inferring them from simulator success.
3. Pause/resume from the Lock Screen and Watch; reopen both apps and compare remaining time. Cancel and confirm removal on refresh.
4. Create, edit, disable, delete and snooze a repeating alarm. Confirm stopping one occurrence preserves its repeat schedule.
5. Deny/revoke alarm permission. Confirm a clear error and no false success state.
6. Disconnect the phone. Confirm Watch scheduling reports the connection problem and the independent stopwatch still starts, laps, stops and survives relaunch.
7. Reconnect after changing alarms on the phone. Confirm the Watch refreshes and does not execute an old failed timer-start tap.
8. Select each complication family supported by the face. Configure different Timer durations, then confirm each opens the selected duration.
9. Verify all three bundled sounds and System sound, VoiceOver labels, larger text, and narrow Watch layouts.
10. Test timed automatic stopping with the iPhone active, then suspended. The suspended case remains a documented limitation, not an acceptance claim.

References: [AlarmKit overview](https://developer.apple.com/videos/play/wwdc2025/230/), [WatchConnectivity sample](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity).

For failed auto-stop tests, Chymee on iPhone → Settings → Alert Diagnostics records observation, deadline, runtime expiry and stop API results. A successful stop API response is recorded as accepted, not as verified audible silence.

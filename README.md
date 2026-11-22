# chime
Clock clone - AlarmKit alarms, timers, stopwatch with per-alarm auto-dismiss. iPhone + Apple Watch + Mac Catalyst.


## Devices are independent

- iPhone and Apple Watch each run their own alarms, timers and stopwatch. Neither needs the other.
- iPhone: AlarmKit schedules and rings; `AutoDismissWatcher` + `KeepAlive` stop the alert at the item's "Stop Ringing After" time.
- Watch: `Watch/WatchEngine.swift` schedules, rings and auto-stops by itself (Smart Alarm extended-runtime session for the next item, local notifications as backup for the rest).
- "Also on iPhone / Apple Watch" marks one alarm or timer as linked: both devices run their own copy and changes (save, delete, pause, resume, cancel, stop) are mirrored over WatchConnectivity (`Connect/ChymeConnectivity.swift`). Unlinked items never leave the device.
- Watch complications (`WatchWidgets/`) are live in all four accessory families. The watch app shares state with the complication extension through a shared keychain access group (`Shared/ComplicationState.swift`), so no App Group is required.

import Foundation
func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
let zero = Date(timeIntervalSince1970: 1000)
var watch = StopwatchState()
watch.preset = 30; watch.reset(); watch.start(at: zero)
check(watch.value(at: zero.addingTimeInterval(10)) == 40, "Preset must count upward")
watch.lap(at: zero.addingTimeInterval(10)); watch.lap(at: zero.addingTimeInterval(25))
check(watch.lapDurations == [10, 15], "Laps must be intervals, not cumulative")
watch.pause(at: zero.addingTimeInterval(30)); watch.start(at: zero.addingTimeInterval(90))
check(watch.value(at: zero.addingTimeInterval(100)) == 70, "Pause must exclude stopped time")
let data = try JSONEncoder().encode(watch)
let restored = try JSONDecoder().decode(StopwatchState.self, from: data)
check(restored.value(at: zero.addingTimeInterval(100)) == 70, "Relaunch must preserve stopwatch")
let legacy = """
{"id":"00000000-0000-0000-0000-000000000001","label":"Timer","duration":300,"autoDismiss":{"seconds":300},"soundName":"Radial"}
""".data(using: .utf8)!
let migrated = try JSONDecoder().decode(ChymeTimer.self, from: legacy)
check(migrated.endsAt == nil, "Legacy timers must decode without invented deadlines")
var timer = ChymeTimer(duration: 300)
timer.endsAt = zero.addingTimeInterval(300)
check(timer.remaining(at: zero.addingTimeInterval(120)) == 180, "Countdown")
timer.pausedRemaining = 180; timer.endsAt = nil
check(timer.remaining(at: zero.addingTimeInterval(900)) == 180, "Paused timer")
check(ClockText.duration(3661) == "1:01:01", "Hours")
check(ClockText.duration(-1) == "00:00", "No negative timer")
check(ChymeSound.resolved("Radial") == "System", "Legacy sound migration")
print("PASS: stopwatch laps, pause, persistence, timer migration/countdown, formatting, sound migration")

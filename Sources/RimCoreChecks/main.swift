import Foundation
import RimCore

var failures = 0
var passed = 0

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        passed += 1
    } else {
        failures += 1
        print("FAIL: \(name) \(detail())")
    }
}

/// Feeds a straight one-finger stroke through the engine and collects every action.
func stroke(
    _ engine: GestureEngine,
    from: (Double, Double),
    to: (Double, Double),
    frames: Int = 40,
    start: TimeInterval = 100,
    duration: TimeInterval = 0.4,
    modifiers: ModifierState = ModifierState(),
    typing: TimeInterval? = nil,
    lift: Bool = true
) -> [GestureAction] {
    var out: [GestureAction] = []
    for i in 0...frames {
        let t = Double(i) / Double(frames)
        let point = TouchPoint(id: 1, x: from.0 + (to.0 - from.0) * t, y: from.1 + (to.1 - from.1) * t)
        out += engine.process(touches: [point], now: start + duration * t, modifiers: modifiers, lastTypingTime: typing)
    }
    if lift {
        out += engine.process(touches: [], now: start + duration + 0.01)
        out += engine.tick(now: start + duration + 1)
    }
    return out
}

func tap(_ engine: GestureEngine, x: Double, y: Double, at time: TimeInterval) -> [GestureAction] {
    var out = engine.process(touches: [TouchPoint(id: 7, x: x, y: y)], now: time)
    out += engine.process(touches: [], now: time + 0.05)
    // The corner is on the right edge, so a tap there also records the pointer position.
    // That is bookkeeping for a possible slide and has no effect the user can see.
    return out.filter { $0 != .edgeTouchDown }
}

func totalDelta(_ actions: [GestureAction], _ target: SlideTarget) -> Double {
    actions.reduce(0) { sum, action in
        if case .adjust(let t, let delta, _) = action, t == target { return sum + delta }
        return sum
    }
}

func grids(_ actions: [GestureAction]) -> Set<Double> {
    Set(actions.compactMap { action in
        if case .adjust(_, _, let grid) = action { return grid }
        return nil
    })
}

// Right edge controls volume, left edge controls brightness.
do {
    let actions = stroke(GestureEngine(), from: (0.98, 0.3), to: (0.98, 0.7))
    check("right edge begins a volume slide", actions.contains(.slideBegan(.volume)))
    check("slide up raises volume", totalDelta(actions, .volume) > 0)
    check("slide ends on lift", actions.last == .slideEnded(.volume))
    check("edge touch is reported first", actions.first == .edgeTouchDown)

    let down = stroke(GestureEngine(), from: (0.02, 0.7), to: (0.02, 0.3))
    check("left edge controls brightness", down.contains(.slideBegan(.brightness)))
    check("slide down lowers brightness", totalDelta(down, .brightness) < 0)
}

// Swap Sides.
do {
    var config = GestureConfig()
    config.swapSides = true
    let actions = stroke(GestureEngine(config: config), from: (0.98, 0.3), to: (0.98, 0.7))
    check("swap puts brightness on the right", actions.contains(.slideBegan(.brightness)))
}

// The middle of the trackpad does nothing.
do {
    let actions = stroke(GestureEngine(), from: (0.5, 0.3), to: (0.5, 0.8))
    check("centre touch produces no actions", actions.isEmpty, "\(actions)")
}

// Horizontal movement from the edge is ordinary pointer use.
do {
    let actions = stroke(GestureEngine(), from: (0.98, 0.5), to: (0.6, 0.5))
    check("horizontal move from the edge does not slide", !actions.contains(.slideBegan(.volume)))
}

// Finger stationary on the edge never begins a slide.
do {
    let actions = stroke(GestureEngine(), from: (0.98, 0.5), to: (0.98, 0.505))
    check("travel under the threshold does not slide", !actions.contains(.slideBegan(.volume)))
}

// Fine Control and Precise Sliding use quarter steps.
do {
    let normal = stroke(GestureEngine(), from: (0.98, 0.3), to: (0.98, 0.7))
    check("default grid is 1/16", grids(normal) == [GestureConfig.normalGrid], "\(grids(normal))")

    let fine = stroke(
        GestureEngine(), from: (0.98, 0.3), to: (0.98, 0.7),
        modifiers: ModifierState(shift: true, option: true)
    )
    check("Shift-Option gives quarter steps", grids(fine) == [GestureConfig.fineGrid], "\(grids(fine))")

    let shiftOnly = stroke(
        GestureEngine(), from: (0.98, 0.3), to: (0.98, 0.7),
        modifiers: ModifierState(shift: true)
    )
    check("Shift alone is not enough", grids(shiftOnly) == [GestureConfig.normalGrid])

    var config = GestureConfig()
    config.preciseSliding = true
    let precise = stroke(GestureEngine(config: config), from: (0.98, 0.3), to: (0.98, 0.7))
    check("Precise Sliding needs no keys", grids(precise) == [GestureConfig.fineGrid])
}

// Deltas are always whole grid multiples and sum to the expected travel.
do {
    let actions = stroke(GestureEngine(), from: (0.98, 0.2), to: (0.98, 0.7))
    let expected = 0.5 * GestureConfig().slideGain
    let total = totalDelta(actions, .volume)
    check("total change tracks travel", abs(total - expected) < 0.15, "total=\(total) expected=\(expected)")
    for action in actions {
        if case .adjust(_, let delta, let grid) = action {
            let multiple = delta / grid
            check("delta is a grid multiple", abs(multiple - multiple.rounded()) < 1e-9)
        }
    }
}

// Sensor noise on a stationary finger produces no level changes after activation.
do {
    let engine = GestureEngine()
    var out = stroke(engine, from: (0.98, 0.3), to: (0.98, 0.4), lift: false)
    let before = out.count
    for i in 0..<300 {
        let wobble = i % 2 == 0 ? 0.0005 : -0.0005
        out += engine.process(touches: [TouchPoint(id: 1, x: 0.98, y: 0.4 + wobble)], now: 101 + Double(i) * 0.01)
    }
    check("jitter does not change the level", out.count == before, "new=\(out.count - before)")
}

// Active Area.
do {
    var config = GestureConfig()
    config.activeArea = 0.25
    let high = stroke(GestureEngine(config: config), from: (0.98, 0.5), to: (0.98, 0.7))
    check("Active Area rejects a high start", !high.contains(.slideBegan(.volume)))
    let low = stroke(GestureEngine(config: config), from: (0.98, 0.15), to: (0.98, 0.5))
    check("Active Area accepts a low start, and it may leave the area", low.contains(.slideBegan(.volume)))
}

// Require modifier.
do {
    var config = GestureConfig()
    config.requireModifier = true
    let none = stroke(GestureEngine(config: config), from: (0.98, 0.3), to: (0.98, 0.7))
    check("no modifier, no slide", !none.contains(.slideBegan(.volume)))
    let held = stroke(
        GestureEngine(config: config), from: (0.98, 0.3), to: (0.98, 0.7),
        modifiers: ModifierState(option: true)
    )
    check("Option allows the slide", held.contains(.slideBegan(.volume)))
    let fn = stroke(
        GestureEngine(config: config), from: (0.98, 0.3), to: (0.98, 0.7),
        modifiers: ModifierState(function: true)
    )
    check("Fn allows the slide", fn.contains(.slideBegan(.volume)))
}

// Typing guard.
do {
    let blocked = stroke(GestureEngine(), from: (0.98, 0.3), to: (0.98, 0.7), start: 100, typing: 99.9)
    check("recent typing blocks a slide", !blocked.contains(.slideBegan(.volume)))
    let allowed = stroke(GestureEngine(), from: (0.98, 0.3), to: (0.98, 0.7), start: 100, typing: 99.0)
    check("old typing does not block", allowed.contains(.slideBegan(.volume)))
}

// Quick Mute.
do {
    let engine = GestureEngine()
    var out = tap(engine, x: 0.97, y: 0.97, at: 100)
    check("one corner tap does nothing", out.isEmpty, "\(out)")
    out = tap(engine, x: 0.97, y: 0.97, at: 100.2)
    check("double tap toggles mute", out == [.toggleMute, .suppressClicks], "\(out)")

    let slow = GestureEngine()
    _ = tap(slow, x: 0.97, y: 0.97, at: 100)
    let late = tap(slow, x: 0.97, y: 0.97, at: 101)
    check("slow taps do not mute", late.isEmpty, "\(late)")

    var config = GestureConfig()
    config.quickMuteEnabled = false
    let off = GestureEngine(config: config)
    _ = tap(off, x: 0.97, y: 0.97, at: 100)
    check("disabled Quick Mute is ignored", !tap(off, x: 0.97, y: 0.97, at: 100.2).contains(.toggleMute))

    let centre = GestureEngine()
    _ = tap(centre, x: 0.5, y: 0.5, at: 100)
    check("double tap elsewhere does not mute", tap(centre, x: 0.5, y: 0.5, at: 100.2).isEmpty)
}

// Sliding from the top-right corner still works.
do {
    let actions = stroke(GestureEngine(), from: (0.98, 0.95), to: (0.98, 0.5))
    check("slide can start in the corner", actions.contains(.slideBegan(.volume)))
    check("a corner slide is not a mute", !actions.contains(.toggleMute))
}

// Media Strip.
do {
    let right = stroke(GestureEngine(), from: (0.3, 0.05), to: (0.7, 0.05))
    check("swipe right is next", right == [.media(.next)], "\(right)")
    let left = stroke(GestureEngine(), from: (0.7, 0.05), to: (0.3, 0.05))
    check("swipe left is previous", left == [.media(.previous)], "\(left)")

    var config = GestureConfig()
    config.invertMediaSwipe = true
    let inverted = stroke(GestureEngine(config: config), from: (0.3, 0.05), to: (0.7, 0.05))
    check("Reverse Swipe flips direction", inverted == [.media(.previous)], "\(inverted)")

    let short = stroke(GestureEngine(), from: (0.4, 0.05), to: (0.45, 0.05))
    check("short swipe does nothing", short.isEmpty, "\(short)")

    let edgeInStrip = stroke(GestureEngine(), from: (0.98, 0.05), to: (0.98, 0.5))
    check("edge slide cannot start in the strip", !edgeInStrip.contains(.slideBegan(.volume)))

    let tapOff = GestureEngine()
    _ = tap(tapOff, x: 0.5, y: 0.05, at: 100)
    check("play/pause is off by default", tap(tapOff, x: 0.5, y: 0.05, at: 100.2).isEmpty)

    var tapConfig = GestureConfig()
    tapConfig.mediaTapEnabled = true
    let tapOn = GestureEngine(config: tapConfig)
    _ = tap(tapOn, x: 0.5, y: 0.05, at: 100)
    let result = tap(tapOn, x: 0.5, y: 0.05, at: 100.2)
    check("double tap plays or pauses", result == [.media(.playPause), .suppressClicks], "\(result)")
}

// Two fingers are ordinary scrolling and must never be taken over.
do {
    let engine = GestureEngine()
    let a = TouchPoint(id: 1, x: 0.98, y: 0.3)
    let b = TouchPoint(id: 2, x: 0.5, y: 0.3)
    var out = engine.process(touches: [a, b], now: 100)
    out += engine.process(touches: [TouchPoint(id: 1, x: 0.98, y: 0.7)], now: 100.1)
    check("two-finger start stays blocked after one lifts", out.isEmpty, "\(out)")
    out += engine.process(touches: [], now: 100.2)
    out += stroke(engine, from: (0.98, 0.3), to: (0.98, 0.7), start: 101)
    check("cleared once all fingers lift", out.contains(.slideBegan(.volume)))

    let joined = GestureEngine()
    _ = joined.process(touches: [TouchPoint(id: 1, x: 0.98, y: 0.3)], now: 100)
    let late = joined.process(touches: [TouchPoint(id: 1, x: 0.98, y: 0.3), b], now: 100.05)
    check("a second finger cancels a pending slide", late.isEmpty)
    let after = joined.process(touches: [TouchPoint(id: 1, x: 0.98, y: 0.7)], now: 100.1)
    check("no slide after the cancel", after.isEmpty, "\(after)")
}

// A resting finger arriving mid-slide does not interrupt it.
do {
    let engine = GestureEngine()
    let begun = stroke(engine, from: (0.98, 0.2), to: (0.98, 0.4), lift: false)
    check("slide active", begun.contains(.slideBegan(.volume)))
    let thumb = TouchPoint(id: 9, x: 0.4, y: 0.05)
    let out = engine.process(touches: [TouchPoint(id: 1, x: 0.98, y: 0.6), thumb], now: 101)
    check("slide survives a second finger", totalDelta(out, .volume) > 0, "\(out)")
    check("and does not end", !out.contains(.slideEnded(.volume)))
}

// Lost finger recovery.
do {
    let engine = GestureEngine()
    _ = stroke(engine, from: (0.98, 0.2), to: (0.98, 0.4), lift: false)
    var out = engine.process(touches: [], now: 101)
    check("drop does not end immediately", out.isEmpty)
    check("a deadline is scheduled", engine.nextDeadline != nil)
    out = engine.process(touches: [TouchPoint(id: 2, x: 0.98, y: 0.41)], now: 101.05)
    check("recovered id does not end the slide", !out.contains(.slideEnded(.volume)))
    check("recovery does not jump the level", totalDelta(out, .volume) == 0)
    check("deadline cleared", engine.nextDeadline == nil)
    out = engine.process(touches: [TouchPoint(id: 2, x: 0.98, y: 0.6)], now: 101.1)
    check("slide continues on the new id", totalDelta(out, .volume) > 0)

    let gone = GestureEngine()
    _ = stroke(gone, from: (0.98, 0.2), to: (0.98, 0.4), lift: false)
    _ = gone.process(touches: [], now: 101)
    check("tick waits out the grace period", gone.tick(now: 101.05).isEmpty)
    check("tick then ends the slide", gone.tick(now: 101.2) == [.slideEnded(.volume)])
    check("tick is idempotent", gone.tick(now: 102).isEmpty)
}

// Leaving the edge ends a slide, and does not start another until lift.
do {
    let engine = GestureEngine()
    _ = stroke(engine, from: (0.98, 0.2), to: (0.98, 0.5), lift: false)
    var out = engine.process(touches: [TouchPoint(id: 1, x: 0.95, y: 0.55)], now: 101)
    check("small sideways drift keeps sliding", !out.contains(.slideEnded(.volume)))
    out = engine.process(touches: [TouchPoint(id: 1, x: 0.5, y: 0.55)], now: 101.1)
    check("leaving the edge ends the slide", out == [.slideEnded(.volume)], "\(out)")
    out = engine.process(touches: [TouchPoint(id: 1, x: 0.98, y: 0.3)], now: 101.2)
    out += engine.process(touches: [TouchPoint(id: 1, x: 0.98, y: 0.7)], now: 101.3)
    check("no restart until all fingers lift", out.isEmpty, "\(out)")
}

// Reset must report an active slide, because the app has to release the frozen cursor.
do {
    let engine = GestureEngine()
    _ = stroke(engine, from: (0.98, 0.2), to: (0.98, 0.5), lift: false)
    check("reset ends an active slide", engine.reset() == [.slideEnded(.volume)])
    check("second reset is empty", engine.reset().isEmpty)
}

// Level steps, with and without a volume limit.
do {
    let grid = GestureConfig.normalGrid
    check("step snaps to the grid", LevelStep.next(current: 0.5, delta: grid, grid: grid) == 0.5625)
    check("step stops at full", LevelStep.next(current: 1, delta: grid, grid: grid) == 1)
    check("step stops at zero", LevelStep.next(current: 0, delta: -grid, grid: grid) == 0)
    check("step stops at the limit", LevelStep.next(current: 0.69, delta: grid, grid: grid, limit: 0.7) == 0.7)
    check("step holds at the limit", LevelStep.next(current: 0.7, delta: grid, grid: grid, limit: 0.7) == 0.7)
    check("step can leave the limit downward", LevelStep.next(current: 0.7, delta: -grid, grid: grid, limit: 0.7) == 0.625)
    check("level above the limit is pulled down", LevelStep.next(current: 0.9, delta: grid, grid: grid, limit: 0.7) == 0.7)
    check("limit above full is ignored", LevelStep.next(current: 1, delta: grid, grid: grid, limit: 2) == 1)
}

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)

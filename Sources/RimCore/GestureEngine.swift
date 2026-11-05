import Foundation

/// One finger in contact with the surface. Coordinates are normalized: x 0 = left, y 0 = bottom.
public struct TouchPoint: Equatable, Sendable {
    public var id: Int32
    public var x: Double
    public var y: Double

    public init(id: Int32, x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }
}

public struct ModifierState: Equatable, Sendable {
    public var shift: Bool
    public var option: Bool
    public var function: Bool

    public init(shift: Bool = false, option: Bool = false, function: Bool = false) {
        self.shift = shift
        self.option = option
        self.function = function
    }
}

public enum SlideTarget: Equatable, Sendable { case volume, brightness }
public enum MediaCommand: Equatable, Sendable { case next, previous, playPause }

public enum GestureAction: Equatable, Sendable {
    /// A finger landed somewhere a slide could start. The pointer position should be remembered.
    case edgeTouchDown
    case slideBegan(SlideTarget)
    /// Change the level by `delta`, which is always a whole multiple of `grid`.
    case adjust(SlideTarget, delta: Double, grid: Double)
    case slideEnded(SlideTarget)
    case toggleMute
    case media(MediaCommand)
    /// A double-tap fired, so the tap-to-click it generates should not reach other apps.
    case suppressClicks
}

public struct GestureConfig: Equatable, Sendable {
    public var edgeWidth = 0.05
    public var sensitivity = 1.0
    public var swapSides = false
    /// Slides may only start in this bottom fraction of the surface: 1, 0.75, 0.5 or 0.25.
    public var activeArea = 1.0
    public var requireModifier = false
    public var preciseSliding = false
    public var quickMuteEnabled = true
    public var mediaStripEnabled = true
    public var mediaTapEnabled = false
    public var invertMediaSwipe = false
    public var typingGuard: TimeInterval = 0.4

    // Tuning values. These are this project's own choices, not recovered from any other app.
    public var activationTravel = 0.015
    public var slideGain = 1.4
    public var noiseFloor = 0.0015
    public var edgeExitTolerance = 0.12
    public var cornerSize = 0.14
    public var stripHeight = 0.10
    public var swipeThreshold = 0.16
    public var tapMaxDuration: TimeInterval = 0.25
    public var tapMaxTravel = 0.03
    public var doubleTapWindow: TimeInterval = 0.35
    public var lostFingerGrace: TimeInterval = 0.12

    public static let normalGrid = 1.0 / 16.0
    public static let fineGrid = 1.0 / 64.0

    public init() {}
}

/// Turns contact frames from one device into high-level actions.
/// Not thread safe: call it from a single thread.
public final class GestureEngine {
    private enum Zone { case corner, strip }

    private enum Mode: Equatable {
        case pending
        case sliding(SlideTarget)
    }

    private struct Session {
        var fingerID: Int32
        var mode: Mode = .pending
        var startX: Double
        var startY: Double
        var startTime: TimeInterval
        var lastY: Double
        var lastX: Double
        var maxTravel = 0.0
        var isLeftEdge: Bool
        var canSlide: Bool
        var tapZone: Zone?
        var inStrip: Bool
        var didSwipe = false
        var accumulator = 0.0
        var lostAt: TimeInterval?
    }

    public var config: GestureConfig
    private var session: Session?
    /// Set after a multi-finger touch or an ended slide, and cleared when every finger lifts.
    private var blocked = false
    private var lastTap: (zone: Zone, time: TimeInterval)?

    public init(config: GestureConfig = GestureConfig()) {
        self.config = config
    }

    /// When a slide has lost its finger, the time `tick` should next be called.
    public var nextDeadline: TimeInterval? {
        session?.lostAt.map { $0 + config.lostFingerGrace }
    }

    public func process(
        touches: [TouchPoint],
        now: TimeInterval,
        modifiers: ModifierState = ModifierState(),
        lastTypingTime: TimeInterval? = nil
    ) -> [GestureAction] {
        var out: [GestureAction] = []

        if touches.isEmpty {
            blocked = false
            if let current = session {
                if case .sliding = current.mode {
                    if current.lostAt == nil { session?.lostAt = now }
                } else {
                    finishPending(now: now, out: &out)
                }
            }
            return out
        }

        guard let current = session else {
            if blocked { return out }
            if touches.count > 1 {
                blocked = true
                return out
            }
            begin(touches[0], now: now, modifiers: modifiers, lastTypingTime: lastTypingTime, out: &out)
            return out
        }

        switch current.mode {
        case .sliding(let target):
            if let touch = touches.first(where: { $0.id == current.fingerID }) {
                session?.lostAt = nil
                updateSlide(touch, target: target, modifiers: modifiers, out: &out)
            } else if touches.count == 1,
                      abs(touches[0].x - current.lastX) < 0.10,
                      abs(touches[0].y - current.lastY) < 0.15 {
                // The surface reassigned the finger's id, or dropped it briefly. Keep the slide going.
                session?.fingerID = touches[0].id
                session?.lastX = touches[0].x
                session?.lastY = touches[0].y
                session?.lostAt = nil
            } else {
                let lostAt = current.lostAt ?? now
                session?.lostAt = lostAt
                if now - lostAt >= config.lostFingerGrace {
                    endSlide(target, out: &out)
                    blocked = true
                }
            }

        case .pending:
            if touches.count > 1 {
                session = nil
                blocked = true
                lastTap = nil
            } else if touches[0].id == current.fingerID {
                updatePending(touches[0], out: &out)
            } else {
                finishPending(now: now, out: &out)
                begin(touches[0], now: now, modifiers: modifiers, lastTypingTime: lastTypingTime, out: &out)
            }
        }
        return out
    }

    /// Ends a slide whose finger never came back. Harmless to call at any time.
    public func tick(now: TimeInterval) -> [GestureAction] {
        var out: [GestureAction] = []
        if let current = session, let lostAt = current.lostAt,
           now - lostAt >= config.lostFingerGrace,
           case .sliding(let target) = current.mode {
            endSlide(target, out: &out)
        }
        return out
    }

    /// Drops all state, for example when the device goes away. Reports a slide it had to end.
    public func reset() -> [GestureAction] {
        var out: [GestureAction] = []
        if let current = session, case .sliding(let target) = current.mode {
            out.append(.slideEnded(target))
        }
        session = nil
        blocked = false
        lastTap = nil
        return out
    }

    private func begin(
        _ touch: TouchPoint,
        now: TimeInterval,
        modifiers: ModifierState,
        lastTypingTime: TimeInterval?,
        out: inout [GestureAction]
    ) {
        let isLeft = touch.x < config.edgeWidth
        let isRight = touch.x > 1 - config.edgeWidth
        let typing = lastTypingTime.map { now - $0 < config.typingGuard } ?? false
        let belowStrip = touch.y < config.stripHeight
        let inCorner = touch.x >= 1 - config.cornerSize && touch.y >= 1 - config.cornerSize
        let inStrip = config.mediaStripEnabled && belowStrip && !isLeft && !isRight && !typing

        let modifierOK = !config.requireModifier || modifiers.function || modifiers.option
        let canSlide = (isLeft || isRight)
            && !typing
            && modifierOK
            && touch.y <= config.activeArea
            && !(config.mediaStripEnabled && belowStrip)

        var tapZone: Zone?
        if config.quickMuteEnabled && inCorner && !typing {
            tapZone = .corner
        } else if inStrip && config.mediaTapEnabled {
            tapZone = .strip
        }

        session = Session(
            fingerID: touch.id,
            startX: touch.x,
            startY: touch.y,
            startTime: now,
            lastY: touch.y,
            lastX: touch.x,
            isLeftEdge: isLeft,
            canSlide: canSlide,
            tapZone: tapZone,
            inStrip: inStrip
        )
        if canSlide { out.append(.edgeTouchDown) }
    }

    private func updatePending(_ touch: TouchPoint, out: inout [GestureAction]) {
        guard var current = session else { return }
        let dx = touch.x - current.startX
        let dy = touch.y - current.startY
        current.maxTravel = max(current.maxTravel, (dx * dx + dy * dy).squareRoot())
        current.lastX = touch.x
        current.lastY = touch.y

        if current.canSlide {
            if abs(dy) >= config.activationTravel && abs(dy) > abs(dx) {
                let target = target(isLeftEdge: current.isLeftEdge)
                current.mode = .sliding(target)
                out.append(.slideBegan(target))
            } else if abs(dx) > config.activationTravel * 2 {
                current.canSlide = false
            }
        }

        if current.inStrip && !current.didSwipe
            && abs(dx) >= config.swipeThreshold && abs(dx) > abs(dy) {
            current.didSwipe = true
            let isNext = (dx > 0) != config.invertMediaSwipe
            out.append(.media(isNext ? .next : .previous))
        }
        session = current
    }

    private func updateSlide(
        _ touch: TouchPoint,
        target: SlideTarget,
        modifiers: ModifierState,
        out: inout [GestureAction]
    ) {
        guard var current = session else { return }
        let limit = config.edgeWidth + config.edgeExitTolerance
        let leftStrip = current.isLeftEdge ? touch.x > limit : touch.x < 1 - limit
        if leftStrip {
            endSlide(target, out: &out)
            blocked = true
            return
        }

        current.lastX = touch.x
        let dy = touch.y - current.lastY
        // Very small movements are sensor noise. Ignoring them keeps slow slides from jittering.
        guard abs(dy) >= config.noiseFloor else {
            session = current
            return
        }
        current.lastY = touch.y

        let fine = config.preciseSliding || (modifiers.shift && modifiers.option)
        let grid = fine ? GestureConfig.fineGrid : GestureConfig.normalGrid
        current.accumulator += dy * config.sensitivity * config.slideGain
        let steps = (current.accumulator / grid).rounded(.towardZero)
        if steps != 0 {
            let delta = steps * grid
            current.accumulator -= delta
            out.append(.adjust(target, delta: delta, grid: grid))
        }
        session = current
    }

    private func endSlide(_ target: SlideTarget, out: inout [GestureAction]) {
        session = nil
        out.append(.slideEnded(target))
    }

    private func finishPending(now: TimeInterval, out: inout [GestureAction]) {
        guard let current = session else { return }
        session = nil

        let isTap = !current.didSwipe
            && now - current.startTime <= config.tapMaxDuration
            && current.maxTravel <= config.tapMaxTravel
        guard isTap, let zone = current.tapZone else {
            lastTap = nil
            return
        }

        if let previous = lastTap, previous.zone == zone, now - previous.time <= config.doubleTapWindow {
            lastTap = nil
            out.append(zone == .corner ? .toggleMute : .media(.playPause))
            out.append(.suppressClicks)
        } else {
            lastTap = (zone, now)
        }
    }

    private func target(isLeftEdge: Bool) -> SlideTarget {
        // Default layout: brightness on the left, volume on the right.
        isLeftEdge != config.swapSides ? .brightness : .volume
    }
}

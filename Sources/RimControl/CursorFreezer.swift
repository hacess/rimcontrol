import AppKit

/// Keeps the pointer hidden and still during a slide, and drops the tap-to-click from a double-tap.
final class CursorFreezer {
    private typealias ConnectionGetter = @convention(c) () -> Int32
    private typealias PropertySetter = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    private var touchDownLocation: CGPoint?
    private var isFrozen = false
    private var didEnableBackgroundCursor = false
    private var suppressClicksUntil: TimeInterval = 0
    private var cursorTap: CFMachPort?
    private var clickTap: CFMachPort?

    /// Installs the event taps. Fails until Accessibility has been granted.
    @discardableResult
    func installTaps() -> Bool {
        if cursorTap != nil && clickTap != nil { return true }
        let pointerTypes: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        ]
        cursorTap = makeTap(types: pointerTypes) { freezer, _ in freezer.isFrozen }
        clickTap = makeTap(types: [.leftMouseDown, .leftMouseUp]) { freezer, _ in
            ProcessInfo.processInfo.systemUptime < freezer.suppressClicksUntil
        }
        // The pointer tap sees every mouse move, so it only runs during a slide.
        if let cursorTap { CGEvent.tapEnable(tap: cursorTap, enable: false) }
        if cursorTap == nil || clickTap == nil {
            NSLog("[RimControl] Could not create event taps. Is Accessibility granted to this build?")
        }
        return cursorTap != nil && clickTap != nil
    }

    private struct TapContext {
        weak var freezer: CursorFreezer?
        let shouldDrop: (CursorFreezer, CGEventType) -> Bool
        var port: CFMachPort?
    }

    private final class TapBox {
        var context: TapContext
        init(_ context: TapContext) { self.context = context }
    }

    private func makeTap(
        types: [CGEventType],
        shouldDrop: @escaping (CursorFreezer, CGEventType) -> Bool
    ) -> CFMachPort? {
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        // The box lives as long as the app, like the tap it serves.
        let box = TapBox(TapContext(freezer: self, shouldDrop: shouldDrop, port: nil))
        let refcon = Unmanaged.passRetained(box).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let box = Unmanaged<TapBox>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    // macOS turns slow taps off. Only turn this back on if it should be running.
                    if let port = box.context.port, let freezer = box.context.freezer,
                       port != freezer.cursorTap || freezer.isFrozen {
                        CGEvent.tapEnable(tap: port, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                if let freezer = box.context.freezer, box.context.shouldDrop(freezer, type) {
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            Unmanaged<TapBox>.fromOpaque(refcon).release()
            return nil
        }
        box.context.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return port
    }

    func noteTouchDown() {
        touchDownLocation = CGEvent(source: nil)?.location
    }

    func suppressClicks(for duration: TimeInterval = 0.4) {
        suppressClicksUntil = ProcessInfo.processInfo.systemUptime + duration
    }

    func freeze() {
        guard !isFrozen else { return }
        isFrozen = true
        enableBackgroundCursorControl()

        // The finger moved a little before the slide was recognized, which also moved the pointer.
        if let start = touchDownLocation, let now = CGEvent(source: nil)?.location,
           hypot(now.x - start.x, now.y - start.y) < 200 {
            CGWarpMouseCursorPosition(start)
        }
        CGAssociateMouseAndMouseCursorPosition(0)
        CGDisplayHideCursor(CGMainDisplayID())
        if let cursorTap { CGEvent.tapEnable(tap: cursorTap, enable: true) }
    }

    func release() {
        guard isFrozen else { return }
        isFrozen = false
        if let cursorTap { CGEvent.tapEnable(tap: cursorTap, enable: false) }
        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(CGMainDisplayID())
    }

    /// A background app may not hide the cursor without this private connection property.
    /// If the symbols ever disappear, the pointer is still held still but stays visible.
    private func enableBackgroundCursorControl() {
        guard !didEnableBackgroundCursor else { return }
        didEnableBackgroundCursor = true
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let getSymbol = dlsym(handle, "_CGSDefaultConnection"),
              let setSymbol = dlsym(handle, "CGSSetConnectionProperty") else { return }
        let getConnection = unsafeBitCast(getSymbol, to: ConnectionGetter.self)
        let setProperty = unsafeBitCast(setSymbol, to: PropertySetter.self)
        let connection = getConnection()
        _ = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}

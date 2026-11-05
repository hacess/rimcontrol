import AppKit
import CoreFoundation
import IOKit
import RimCore

/// Runtime bindings to the private MultitouchSupport framework.
/// Apple does not document these, so every symbol is optional and checked at startup.
final class MultitouchSymbols {
    typealias ContactCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeRawPointer?, Int32, Double, Int32, UnsafeMutableRawPointer?
    ) -> Int32

    let createList: @convention(c) () -> Unmanaged<CFArray>?
    let register: @convention(c) (UnsafeMutableRawPointer, ContactCallback, UnsafeMutableRawPointer?) -> Void
    let unregister: @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
    let start: @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    let stop: @convention(c) (UnsafeMutableRawPointer) -> Int32
    let getFamilyID: @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> Int32
    let getDeviceID: @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32

    let actuatorCreate: (@convention(c) (UInt64) -> UnsafeMutableRawPointer?)?
    let actuatorOpen: (@convention(c) (UnsafeMutableRawPointer) -> Int32)?
    let actuatorActuate: (@convention(c) (UnsafeMutableRawPointer, Int32, UInt32, Float, Float) -> Int32)?

    static let shared = MultitouchSymbols()

    private init?() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_LAZY) else { return nil }

        func required<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }

        guard
            let createList = required("MTDeviceCreateList", (@convention(c) () -> Unmanaged<CFArray>?).self),
            let register = required(
                "MTRegisterContactFrameCallbackWithRefcon",
                (@convention(c) (UnsafeMutableRawPointer, ContactCallback, UnsafeMutableRawPointer?) -> Void).self),
            let unregister = required(
                "MTUnregisterContactFrameCallback",
                (@convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void).self),
            let start = required("MTDeviceStart", (@convention(c) (UnsafeMutableRawPointer, Int32) -> Int32).self),
            let stop = required("MTDeviceStop", (@convention(c) (UnsafeMutableRawPointer) -> Int32).self),
            let getFamilyID = required(
                "MTDeviceGetFamilyID",
                (@convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> Int32).self),
            let getDeviceID = required(
                "MTDeviceGetDeviceID",
                (@convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32).self)
        else { return nil }

        self.createList = createList
        self.register = register
        self.unregister = unregister
        self.start = start
        self.stop = stop
        self.getFamilyID = getFamilyID
        self.getDeviceID = getDeviceID
        actuatorCreate = required("MTActuatorCreateFromDeviceID", (@convention(c) (UInt64) -> UnsafeMutableRawPointer?).self)
        actuatorOpen = required("MTActuatorOpen", (@convention(c) (UnsafeMutableRawPointer) -> Int32).self)
        actuatorActuate = required(
            "MTActuatorActuate",
            (@convention(c) (UnsafeMutableRawPointer, Int32, UInt32, Float, Float) -> Int32).self)
    }
}

/// Layout of the framework's touch record, as widely documented by open source projects.
/// macOS gives no way to check it at runtime, so `--trace-touches` exists to confirm it by hand.
private enum TouchLayout {
    static let stride = 96
    static let pathID = 16
    static let state = 20
    static let normalizedX = 32
    static let normalizedY = 36
    static let makeTouch: Int32 = 3
    static let touching: Int32 = 4
}

struct MultitouchDeviceInfo {
    let device: UnsafeMutableRawPointer
    let familyID: Int32
    let deviceID: UInt64

    /// Magic Mouse family IDs from public open source device tables.
    var isMagicMouse: Bool { familyID == 112 || familyID == 113 }
}

/// Owns device discovery and delivers contact frames on the main thread.
final class MultitouchManager {
    typealias FrameHandler = (UnsafeMutableRawPointer, [TouchPoint], TimeInterval) -> Void

    private(set) var devices: [MultitouchDeviceInfo] = []
    private var deviceList: CFArray?
    private var notificationPort: IONotificationPortRef?
    private var matchIterator: io_iterator_t = 0
    private var wakeObserver: NSObjectProtocol?
    private var pendingRescan: DispatchWorkItem?
    private var includeMagicMouse = false

    var onFrame: FrameHandler?
    var onDevicesChanged: (() -> Void)?

    fileprivate static var current: MultitouchManager?

    private static let callback: MultitouchSymbols.ContactCallback = { device, touches, count, _, _, _ in
        guard let device, let manager = MultitouchManager.current else { return 0 }
        var points: [TouchPoint] = []
        if let touches, count > 0 {
            points.reserveCapacity(Int(count))
            for index in 0..<Int(count) {
                let record = touches + index * TouchLayout.stride
                let state = record.load(fromByteOffset: TouchLayout.state, as: Int32.self)
                guard state == TouchLayout.makeTouch || state == TouchLayout.touching else { continue }
                points.append(TouchPoint(
                    id: record.load(fromByteOffset: TouchLayout.pathID, as: Int32.self),
                    x: Double(record.load(fromByteOffset: TouchLayout.normalizedX, as: Float.self)),
                    y: Double(record.load(fromByteOffset: TouchLayout.normalizedY, as: Float.self))
                ))
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        // This runs on a private framework thread. All app state belongs to the main thread.
        DispatchQueue.main.async { manager.onFrame?(device, points, now) }
        return 0
    }

    /// Lists every device without starting it. Used for diagnostics too.
    static func enumerate() -> (list: CFArray, devices: [MultitouchDeviceInfo])? {
        guard let symbols = MultitouchSymbols.shared,
              let list = symbols.createList()?.takeRetainedValue() else { return nil }
        var found: [MultitouchDeviceInfo] = []
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            var family: Int32 = 0
            var id: UInt64 = 0
            _ = symbols.getFamilyID(device, &family)
            _ = symbols.getDeviceID(device, &id)
            found.append(MultitouchDeviceInfo(device: device, familyID: family, deviceID: id))
        }
        return (list, found)
    }

    func start(includeMagicMouse: Bool) {
        self.includeMagicMouse = includeMagicMouse
        MultitouchManager.current = self
        rebuild()
        watchForChanges()
    }

    func setIncludeMagicMouse(_ value: Bool) {
        guard value != includeMagicMouse else { return }
        includeMagicMouse = value
        rebuild()
    }

    func stopAll() {
        guard let symbols = MultitouchSymbols.shared else { return }
        for info in devices {
            symbols.unregister(info.device, MultitouchManager.callback)
            _ = symbols.stop(info.device)
        }
        devices = []
        deviceList = nil
    }

    private func rebuild() {
        stopAll()
        guard let symbols = MultitouchSymbols.shared, let found = MultitouchManager.enumerate() else {
            NSLog("[RimControl] Multitouch is unavailable on this system")
            onDevicesChanged?()
            return
        }
        deviceList = found.list
        devices = found.devices.filter { includeMagicMouse || !$0.isMagicMouse }
        for info in devices {
            symbols.register(info.device, MultitouchManager.callback, nil)
            let status = symbols.start(info.device, 0)
            if status != 0 { NSLog("[RimControl] MTDeviceStart failed: \(status)") }
        }
        NSLog("[RimControl] Listening to \(devices.count) device(s): \(devices.map(\.familyID))")
        onDevicesChanged?()
    }

    /// Picks the trackpad back up after it reconnects or the Mac wakes.
    private func watchForChanges() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleRescan() }

        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notificationPort = port

        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            IOServiceMatching("AppleMultitouchDevice"),
            { refcon, iterator in
                MultitouchManager.drain(iterator)
                guard let refcon else { return }
                Unmanaged<MultitouchManager>.fromOpaque(refcon).takeUnretainedValue().scheduleRescan()
            },
            context,
            &matchIterator
        )
        // The iterator must be drained once to arm the notification.
        if status == KERN_SUCCESS { MultitouchManager.drain(matchIterator) }
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }

    private func scheduleRescan() {
        pendingRescan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        pendingRescan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}

/// Plays haptics, using the trackpad's actuator directly when possible.
final class Haptics {
    enum Strength: String, CaseIterable, Identifiable {
        case off = "Off", subtle = "Subtle", standard = "Standard", strong = "Strong"
        var id: String { rawValue }

        /// Actuation waveform IDs. These are undocumented and from public open source use.
        var actuationID: Int32? {
            switch self {
            case .off: return nil
            case .subtle: return 3
            case .standard: return 4
            case .strong: return 6
            }
        }
    }

    private var actuator: UnsafeMutableRawPointer?

    func attach(deviceID: UInt64?) {
        actuator = nil
        guard let deviceID, let symbols = MultitouchSymbols.shared,
              let create = symbols.actuatorCreate, let open = symbols.actuatorOpen,
              let candidate = create(deviceID), open(candidate) == 0 else { return }
        actuator = candidate
    }

    func tick(_ strength: Strength) {
        guard let id = strength.actuationID else { return }
        play(id)
    }

    /// The stronger buzz for muting, so it can be felt without looking.
    func buzz(_ strength: Strength) {
        guard strength != .off else { return }
        play(6)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in self?.play(6) }
    }

    private func play(_ id: Int32) {
        if let actuator, let actuate = MultitouchSymbols.shared?.actuatorActuate,
           actuate(actuator, id, 0, 0, 0) == 0 {
            return
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

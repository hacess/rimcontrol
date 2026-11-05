import AppKit
import Combine
import RimCore

enum Key {
    static let swapSides = "swapSides"
    static let quickMute = "quickMuteEnabled"
    static let mediaStrip = "mediaStripEnabled"
    static let mediaTap = "mediaTapEnabled"
    static let invertMediaSwipe = "invertMediaSwipe"
    static let preciseSliding = "preciseSliding"
    static let haptic = "hapticStrength"
    static let activeArea = "activeArea"
    static let requireModifier = "requireModifier"
    static let freezeCursor = "freezeCursor"
    static let edgeWidth = "edgeWidth"
    static let sensitivity = "sensitivity"
    static let appearance = "appearance"
    static let classicHUD = "classicHUD"
    static let magicMouse = "magicMouseEnabled"
    /// Maximum volume for each output, by device UID. An output with no entry has no limit.
    static let volumeLimits = "volumeLimits"
    static let guideShown = "guideShown"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            swapSides: false,
            quickMute: true,
            mediaStrip: true,
            mediaTap: false,
            invertMediaSwipe: false,
            preciseSliding: false,
            haptic: Haptics.Strength.subtle.rawValue,
            activeArea: 1.0,
            requireModifier: false,
            freezeCursor: true,
            edgeWidth: 0.05,
            sensitivity: 1.0,
            appearance: "system",
            classicHUD: false,
            magicMouse: false,
            guideShown: false,
        ])
    }
}

/// Gestures the first-run guide watches for.
enum PracticeGesture: Hashable {
    case brightness, volume, mute, media
}

/// Live levels shown in the menu.
final class LevelsModel: ObservableObject {
    @Published var outputs: [AudioOutput] = []
    @Published var currentOutputID: UInt32?
    @Published var volumeLimit: Double?
    @Published var practiced = Set<PracticeGesture>()

    var currentOutput: AudioOutput? {
        outputs.first { $0.id == currentOutputID }
    }

    @Published var volume = 0.0
    @Published var brightness = 0.0
    @Published var hasVolume = true
    @Published var hasBrightness = true
    @Published var isTrusted = false
    @Published var deviceCount = 0
}

final class AppController {
    let levels = LevelsModel()
    let volume = VolumeController()
    let brightness = BrightnessController()

    private let outputWatcher = OutputWatcher()
    /// The level last pulled down to the limit. A device that rounds back up to it stays there,
    /// rather than the app setting it over and over.
    private var lastClampedFrom: Double?
    private let multitouch = MultitouchManager()
    private let haptics = Haptics()
    private let cursor = CursorFreezer()
    private let overlay = OverlayHUD()
    private let classic = ClassicHUD()

    private var engines: [UnsafeMutableRawPointer: GestureEngine] = [:]
    private var mouseDevices = Set<UnsafeMutableRawPointer>()
    private var deadlineWork: [UnsafeMutableRawPointer: DispatchWorkItem] = [:]
    private var config = GestureConfig()
    private var hapticStrength = Haptics.Strength.subtle
    private var freezeCursor = true
    private var useClassicHUD = false
    private var slideLevel: Double?
    private var activeSlides = 0

    private var lastTypingTime: TimeInterval?
    private var keyMonitor: Any?
    private var trustTimer: Timer?
    private var defaultsObserver: NSObjectProtocol?

    func start() {
        loadSettings()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.loadSettings() }

        multitouch.onFrame = { [weak self] device, touches, now in
            self?.handleFrame(device: device, touches: touches, now: now)
        }
        multitouch.onDevicesChanged = { [weak self] in self?.devicesChanged() }
        multitouch.start(includeMagicMouse: UserDefaults.standard.bool(forKey: Key.magicMouse))

        outputWatcher.onVolumeChanged = { [weak self] in self?.volumeDidChange() }
        outputWatcher.onOutputsChanged = { [weak self] in self?.refreshLevels() }
        outputWatcher.start()

        refreshLevels()
        waitForAccessibility()
    }

    func stop() {
        cursor.release()
        multitouch.stopAll()
    }

    // MARK: Settings

    private func loadSettings() {
        let defaults = UserDefaults.standard
        var new = GestureConfig()
        new.swapSides = defaults.bool(forKey: Key.swapSides)
        new.quickMuteEnabled = defaults.bool(forKey: Key.quickMute)
        new.mediaStripEnabled = defaults.bool(forKey: Key.mediaStrip)
        new.mediaTapEnabled = defaults.bool(forKey: Key.mediaTap)
        new.invertMediaSwipe = defaults.bool(forKey: Key.invertMediaSwipe)
        new.preciseSliding = defaults.bool(forKey: Key.preciseSliding)
        new.activeArea = defaults.double(forKey: Key.activeArea)
        new.requireModifier = defaults.bool(forKey: Key.requireModifier)
        new.edgeWidth = defaults.double(forKey: Key.edgeWidth)
        new.sensitivity = defaults.double(forKey: Key.sensitivity)
        config = new

        for (device, engine) in engines {
            engine.config = effectiveConfig(for: device)
        }

        hapticStrength = Haptics.Strength(rawValue: defaults.string(forKey: Key.haptic) ?? "") ?? .subtle
        freezeCursor = defaults.bool(forKey: Key.freezeCursor)
        useClassicHUD = defaults.bool(forKey: Key.classicHUD)
        multitouch.setIncludeMagicMouse(defaults.bool(forKey: Key.magicMouse))
        applyAppearance(defaults.string(forKey: Key.appearance) ?? "system")
        syncVolumeLimit()
    }

    private func applyAppearance(_ value: String) {
        let appearance: NSAppearance?
        switch value {
        case "light": appearance = NSAppearance(named: .aqua)
        case "dark": appearance = NSAppearance(named: .darkAqua)
        default: appearance = nil
        }
        if NSApp.appearance != appearance { NSApp.appearance = appearance }
    }

    /// The Magic Mouse has no corner or strip to speak of, and needs wider edges to be usable.
    private func effectiveConfig(for device: UnsafeMutableRawPointer) -> GestureConfig {
        guard mouseDevices.contains(device) else { return config }
        var mouse = config
        mouse.quickMuteEnabled = false
        mouse.mediaStripEnabled = false
        mouse.edgeWidth = 0.25
        mouse.activeArea = 1
        return mouse
    }

    // MARK: Devices

    private func devicesChanged() {
        // Devices may have been replaced, so a slide in progress can never finish by itself.
        for engine in engines.values {
            for action in engine.reset() { apply(action) }
        }
        engines = [:]
        deadlineWork.values.forEach { $0.cancel() }
        deadlineWork = [:]
        activeSlides = 0
        cursor.release()

        mouseDevices = Set(multitouch.devices.filter(\.isMagicMouse).map(\.device))
        let trackpad = multitouch.devices.first { !$0.isMagicMouse }
        haptics.attach(deviceID: trackpad?.deviceID)
        levels.deviceCount = multitouch.devices.count
    }

    // MARK: Accessibility

    private func waitForAccessibility() {
        let trusted = AXIsProcessTrusted()
        levels.isTrusted = trusted
        if trusted {
            accessibilityGranted()
            return
        }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.levels.isTrusted = true
            self?.accessibilityGranted()
        }
    }

    private func accessibilityGranted() {
        cursor.installTaps()
        // Only the time of each key press is used. Which key was pressed is never read.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.lastTypingTime = ProcessInfo.processInfo.systemUptime
        }
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Gestures

    private func handleFrame(device: UnsafeMutableRawPointer, touches: [TouchPoint], now: TimeInterval) {
        let engine: GestureEngine
        if let existing = engines[device] {
            engine = existing
        } else if touches.isEmpty {
            return // Nothing to do, and no reason to keep state for an idle device.
        } else {
            engine = GestureEngine(config: effectiveConfig(for: device))
            engines[device] = engine
        }

        let flags = CGEventSource.flagsState(.hidSystemState)
        let modifiers = ModifierState(
            shift: flags.contains(.maskShift),
            option: flags.contains(.maskAlternate),
            function: flags.contains(.maskSecondaryFn))

        for action in engine.process(
            touches: touches, now: now, modifiers: modifiers, lastTypingTime: lastTypingTime) {
            apply(action)
        }
        scheduleDeadline(device: device, engine: engine)
    }

    /// A finger that vanishes produces no more frames, so a timer has to end its slide.
    private func scheduleDeadline(device: UnsafeMutableRawPointer, engine: GestureEngine) {
        deadlineWork[device]?.cancel()
        deadlineWork[device] = nil
        guard let deadline = engine.nextDeadline else { return }
        let work = DispatchWorkItem { [weak self, weak engine] in
            guard let self, let engine else { return }
            for action in engine.tick(now: ProcessInfo.processInfo.systemUptime) {
                self.apply(action)
            }
        }
        deadlineWork[device] = work
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime) + 0.005
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func apply(_ action: GestureAction) {
        switch action {
        case .edgeTouchDown:
            cursor.noteTouchDown()

        case .slideBegan(let target):
            activeSlides += 1
            slideLevel = currentLevel(target)
            if slideLevel == nil {
                // Nothing can change, so say why and leave the pointer free.
                showUnavailable(target)
            } else if freezeCursor {
                cursor.freeze()
            }

        case .adjust(let target, let delta, let grid):
            adjust(target, delta: delta, grid: grid)

        case .slideEnded:
            activeSlides = max(0, activeSlides - 1)
            if activeSlides == 0 {
                cursor.release()
                slideLevel = nil
            }

        case .toggleMute:
            guard volume.canMute() else {
                showNotice(symbol: "speaker.slash.fill", title: "No mute control", detail: outputName)
                return
            }
            let muted = !volume.isMuted()
            volume.setMuted(muted)
            haptics.buzz(hapticStrength)
            showHUD(kind: .volume(muted: muted), level: volume.volume() ?? 0)
            practiced(.mute)

        case .media(let command):
            // macOS drops these key events without Accessibility access.
            guard levels.isTrusted else {
                showNotice(symbol: "lock.shield.fill", title: "Media keys need access",
                           detail: "Allow Accessibility in the RimControl menu")
                return
            }
            switch command {
            case .next:
                MediaKeys.send(.next)
                showNotice(symbol: "forward.fill", title: "Next track")
            case .previous:
                MediaKeys.send(.previous)
                showNotice(symbol: "backward.fill", title: "Previous track")
            case .playPause:
                MediaKeys.send(.playPause)
                showNotice(symbol: "playpause.fill", title: "Play or pause")
            }
            haptics.tick(hapticStrength)
            practiced(.media)

        case .suppressClicks:
            cursor.suppressClicks()
        }
    }

    private func currentLevel(_ target: SlideTarget) -> Double? {
        switch target {
        case .volume: return volume.isAdjustable() ? volume.volume() : nil
        case .brightness: return brightness.brightness()
        }
    }

    private func adjust(_ target: SlideTarget, delta: Double, grid: Double) {
        guard let current = slideLevel ?? currentLevel(target) else { return }
        let limit = target == .volume ? levels.volumeLimit ?? 1 : 1
        let new = LevelStep.next(current: current, delta: delta, grid: grid, limit: limit)
        // Only touch the system, the HUD and the haptics when the level really changes.
        guard abs(new - current) > 1e-6 else {
            if delta > 0 && limit < 1 { showHUD(kind: .volumeLimit, level: limit) }
            return
        }
        slideLevel = new

        switch target {
        case .volume:
            volume.setVolume(new)
            let muted = volume.isMuted()
            if muted && new > 0 { volume.setMuted(false) }
            levels.volume = new
            showHUD(kind: .volume(muted: false), level: new)
            practiced(.volume)
        case .brightness:
            brightness.setBrightness(new)
            levels.brightness = new
            showHUD(kind: .brightness, level: new)
            practiced(.brightness)
        }
        haptics.tick(hapticStrength)
    }

    private func practiced(_ gesture: PracticeGesture) {
        if !levels.practiced.contains(gesture) { levels.practiced.insert(gesture) }
    }

    private func showHUD(kind: HUDKind, level: Double) {
        if useClassicHUD {
            classic.show(kind: kind, level: level, displayID: brightness.displayID)
        } else {
            overlay.show(kind: kind, level: level)
        }
    }

    /// Messages use the banner in both HUD styles, because the Classic square can't show text.
    private func showNotice(symbol: String, title: String, detail: String? = nil) {
        overlay.show(kind: .notice(symbol: symbol, title: title, detail: detail), level: 0)
    }

    private var outputName: String {
        levels.currentOutput?.name ?? "This output"
    }

    private func showUnavailable(_ target: SlideTarget) {
        switch target {
        case .volume:
            showNotice(symbol: "speaker.slash.fill", title: "No volume control", detail: outputName)
        case .brightness:
            showNotice(symbol: "sun.max.fill", title: "No brightness control",
                       detail: "This display can't be adjusted")
        }
    }

    // MARK: Audio outputs

    private func refreshOutputs() {
        let outputs = volume.outputs()
        if levels.outputs != outputs { levels.outputs = outputs }
        let device = volume.outputDevice()
        if levels.currentOutputID != device { levels.currentOutputID = device }
        outputWatcher.watch(device)
        syncVolumeLimit()
    }

    func selectOutput(_ id: UInt32) {
        volume.setOutput(id)
        refreshLevels()
    }

    /// Sets the maximum volume for the current output, or removes it when `limit` is nil.
    func setVolumeLimit(_ limit: Double?) {
        guard let uid = levels.currentOutput?.uid else { return }
        let defaults = UserDefaults.standard
        var limits = defaults.dictionary(forKey: Key.volumeLimits) as? [String: Double] ?? [:]
        limits[uid] = limit
        defaults.set(limits, forKey: Key.volumeLimits)
        syncVolumeLimit()
    }

    private func syncVolumeLimit() {
        let limits = UserDefaults.standard.dictionary(forKey: Key.volumeLimits) as? [String: Double]
        let limit = levels.currentOutput.flatMap { limits?[$0.uid] }
        if levels.volumeLimit != limit { levels.volumeLimit = limit }
        enforceVolumeLimit(announce: false)
    }

    /// Volume can also change through the volume keys and other apps, so the limit is applied here too.
    private func volumeDidChange() {
        enforceVolumeLimit(announce: true)
        if let current = volume.volume() { levels.volume = current }
    }

    private func enforceVolumeLimit(announce: Bool) {
        guard let limit = levels.volumeLimit, let current = volume.volume() else {
            lastClampedFrom = nil
            return
        }
        guard current > limit + 0.001 else {
            lastClampedFrom = nil
            return
        }
        if let last = lastClampedFrom, abs(last - current) <= 0.001 { return }
        lastClampedFrom = current
        volume.setVolume(limit)
        levels.volume = limit
        if announce { showHUD(kind: .volumeLimit, level: limit) }
    }

    // MARK: Menu

    func refreshLevels() {
        refreshOutputs()
        let currentVolume = currentLevel(.volume)
        let currentBrightness = brightness.brightness()
        levels.hasVolume = currentVolume != nil
        levels.hasBrightness = currentBrightness != nil
        levels.volume = currentVolume ?? 0
        levels.brightness = currentBrightness ?? 0
    }

    func setVolumeFromMenu(_ value: Double) {
        let value = min(value, levels.volumeLimit ?? 1)
        volume.setVolume(value)
        if value > 0 && volume.isMuted() { volume.setMuted(false) }
        levels.volume = value
    }

    func setBrightnessFromMenu(_ value: Double) {
        brightness.setBrightness(value)
        levels.brightness = value
    }
}

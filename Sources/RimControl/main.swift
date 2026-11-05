import AppKit
import SwiftUI
import RimCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let controller = AppController()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?
    private var guideWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.make()
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let hosting = NSHostingController(rootView: MenuPanel(
            controller: controller,
            openSettings: { [weak self] in self?.showSettings() },
            levels: controller.levels
        ))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        self.popover = popover

        // First launch: the guide asks for the permission. After that, the menu does.
        if !UserDefaults.standard.bool(forKey: Key.guideShown) {
            showGuide()
        } else if !AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.togglePopover(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            controller.refreshLevels()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showSettings() {
        popover?.performClose(nil)
        if settingsWindow == nil {
            let root = SettingsPanel(
                controller: controller, levels: controller.levels,
                openGuide: { [weak self] in self?.showGuide() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "RimControl Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showGuide() {
        // Recorded on opening, so someone who closes it early is never asked again.
        UserDefaults.standard.set(true, forKey: Key.guideShown)
        NSApp.activate(ignoringOtherApps: true)
        if let guideWindow, guideWindow.isVisible {
            guideWindow.makeKeyAndOrderFront(nil)
            return
        }

        controller.levels.practiced = []
        let root = GuideView(controller: controller, levels: controller.levels) { [weak self] in
            self?.guideWindow?.close()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Welcome to RimControl"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        guideWindow = window
        window.makeKeyAndOrderFront(nil)
    }
}

/// Read-only check of every system integration. Changes nothing on the Mac.
func runDiagnostics() -> Int32 {
    print("Multitouch symbols: \(MultitouchSymbols.shared != nil ? "ok" : "MISSING")")
    if let found = MultitouchManager.enumerate() {
        for device in found.devices {
            let kind = device.isMagicMouse ? "magic mouse" : "trackpad"
            print("  device family=\(device.familyID) id=\(device.deviceID) (\(kind))")
        }
        print("Devices: \(found.devices.count)")
    } else {
        print("Devices: none")
    }
    let symbols = MultitouchSymbols.shared
    print("Actuator symbols: \(symbols?.actuatorCreate != nil && symbols?.actuatorOpen != nil && symbols?.actuatorActuate != nil ? "ok" : "MISSING")")

    let volume = VolumeController()
    print("Volume: \(volume.volume().map { String(format: "%.3f", $0) } ?? "not available"), muted: \(volume.isMuted()), adjustable: \(volume.isAdjustable()), can mute: \(volume.canMute())")
    let currentOutput = volume.outputDevice()
    for output in volume.outputs() {
        print("  output \(output.id == currentOutput ? "*" : " ") \(output.name) [\(output.symbol)]")
    }

    let brightness = BrightnessController()
    print("Brightness: \(brightness.brightness().map { String(format: "%.3f", $0) } ?? "not available") on display \(brightness.displayID)")

    print("Accessibility granted: \(AXIsProcessTrusted())")
    return MultitouchSymbols.shared == nil ? 1 : 0
}

/// Prints live contacts so the undocumented touch layout can be confirmed by hand.
func runTouchTrace() -> Never {
    let manager = MultitouchManager()
    manager.onFrame = { _, touches, _ in
        guard !touches.isEmpty else { return }
        print(touches.map { String(format: "id=%d x=%.3f y=%.3f", $0.id, $0.x, $0.y) }.joined(separator: " | "))
    }
    manager.start(includeMagicMouse: true)
    print("Touch the trackpad. Bottom-left should read near x=0 y=0. Press Ctrl-C to stop.")
    RunLoop.main.run()
    exit(0)
}

let arguments = CommandLine.arguments
if arguments.contains("--diagnose") {
    exit(runDiagnostics())
}
if let index = arguments.firstIndex(of: "--snapshot-ui"), index + 1 < arguments.count {
    Key.registerDefaults()
    renderSnapshots(to: arguments[index + 1])
    exit(0)
}
if arguments.contains("--trace-touches") {
    setvbuf(stdout, nil, _IOLBF, 0)
    runTouchTrace()
}

Key.registerDefaults()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

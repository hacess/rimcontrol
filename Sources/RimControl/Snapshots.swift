import AppKit
import SwiftUI

/// Renders each screen to a PNG for design review. Uses sample levels, stays offscreen and changes nothing.
/// Live blur cannot be captured this way, so translucent surfaces appear over a flat background.
func renderSnapshots(to directory: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    let controller = AppController()
    let levels = controller.levels
    levels.volume = 0.62
    levels.brightness = 0.38
    levels.isTrusted = true
    levels.deviceCount = 1
    levels.outputs = [
        AudioOutput(id: 1, uid: "built-in", name: "MacBook Pro Speakers", symbol: "laptopcomputer"),
        AudioOutput(id: 2, uid: "bluetooth", name: "AirPods Pro", symbol: "headphones"),
    ]
    levels.currentOutputID = 2
    levels.volumeLimit = 0.7
    levels.practiced = [.brightness]

    func save<V: View>(_ view: V, name: String, dark: Bool) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = appearance
        let size = hosting.fittingSize

        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let path = "\(directory)/\(name)-\(dark ? "dark" : "light").png"
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
        print(path)
    }

    for dark in [false, true] {
        save(MenuPanel(controller: controller, openSettings: {}, levels: levels), name: "menu", dark: dark)
        for page in SettingsPage.allCases {
            save(SettingsPanel(controller: controller, levels: levels, page: page),
                 name: "settings-\(page.rawValue.lowercased())", dark: dark)
        }
        for (name, kind, level) in [
            ("hud", HUDKind.volume(muted: false), 0.62),
            ("hud-limit", .volumeLimit, 0.7),
            ("hud-next", .notice(symbol: "forward.fill", title: "Next track", detail: nil), 0),
            ("hud-unavailable", .notice(symbol: "speaker.slash.fill", title: "No volume control", detail: "LG HDR 4K"), 0),
        ] {
            let model = OverlayModel()
            model.kind = kind
            model.level = level
            save(OverlayView(model: model), name: name, dark: dark)
        }
        for step in 0..<5 {
            save(GuideView(controller: controller, levels: levels, startAt: step, onFinish: {}),
                 name: "guide-\(step + 1)", dark: dark)
        }
    }
}

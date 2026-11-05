import AppKit

/// The menu bar version of the app icon: a trackpad with its two lit edges.
/// It is drawn in code so it stays sharp on every display, and macOS tints it as a template image.
enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let trackpad = NSBezierPath(
                roundedRect: NSRect(x: 2.5, y: 3.5, width: 13, height: 11),
                xRadius: 2.5,
                yRadius: 2.5
            )
            trackpad.lineWidth = 1
            NSColor.black.setStroke()
            trackpad.stroke()

            // Clear a gap around the fingertip so the two shapes stay apart at small sizes.
            let fingertip = NSPoint(x: 15.5, y: 6)
            NSGraphicsContext.current?.compositingOperation = .clear
            circle(at: fingertip, radius: 2.8).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            NSColor.black.setFill()
            circle(at: fingertip, radius: 1.8).fill()
            // These stop above the rounded corners, where a thicker line would look like a bulge.
            bar(x: 15.5, top: 9.2, bottom: 12.2).fill()
            bar(x: 2.5, top: 9.8, bottom: 12.2).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "RimControl"
        return image
    }

    private static func circle(at center: NSPoint, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func bar(x: CGFloat, top: CGFloat, bottom: CGFloat) -> NSBezierPath {
        NSBezierPath(
            roundedRect: NSRect(x: x - 1, y: top, width: 2, height: bottom - top),
            xRadius: 1,
            yRadius: 1
        )
    }
}

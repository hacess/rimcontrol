import AppKit
import SwiftUI

enum HUDKind: Equatable {
    case volume(muted: Bool)
    case brightness
    /// The volume is being held at the limit set for this output.
    case volumeLimit
    /// A short message with no level, always shown in the banner.
    case notice(symbol: String, title: String, detail: String?)
}

@objc private protocol OSDUIHelperProtocol {
    @objc(showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:)
    func showImage(
        _ image: Int64,
        onDisplayID displayID: UInt32,
        priority: UInt32,
        msecUntilFade: UInt32,
        filledChiclets: UInt32,
        totalChiclets: UInt32,
        locked: Bool
    )
}

/// The old centred square, drawn by the system's undocumented OSD helper.
final class ClassicHUD {
    private var connection: NSXPCConnection?

    private func proxy() -> OSDUIHelperProtocol? {
        if connection == nil {
            let new = NSXPCConnection(machServiceName: "com.apple.OSDUIHelper", options: [])
            new.remoteObjectInterface = NSXPCInterface(with: OSDUIHelperProtocol.self)
            new.invalidationHandler = { [weak self] in
                DispatchQueue.main.async { self?.connection = nil }
            }
            new.resume()
            connection = new
        }
        return connection?.remoteObjectProxyWithErrorHandler { error in
            NSLog("[RimControl] OSD XPC error: \(error)")
        } as? OSDUIHelperProtocol
    }

    func show(kind: HUDKind, level: Double, displayID: CGDirectDisplayID) {
        // Image IDs are from public open source use of this service.
        let image: Int64
        switch kind {
        case .brightness: image = 1
        case .volume(let muted): image = muted ? 4 : 3
        case .volumeLimit: image = 3
        case .notice: return // This square can't show text.
        }
        var filled = UInt32((min(max(level, 0), 1) * 64).rounded())
        if case .volume(true) = kind { filled = 0 }
        proxy()?.showImage(
            image, onDisplayID: displayID, priority: 0x1F4, msecUntilFade: 1500,
            filledChiclets: filled, totalChiclets: 64, locked: false)
    }
}

final class OverlayModel: ObservableObject {
    @Published var kind: HUDKind = .volume(muted: false)
    @Published var level = 0.0
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isMuted: Bool {
        if case .volume(true) = model.kind { return true }
        return false
    }

    private var symbol: String {
        switch model.kind {
        case .brightness: return "sun.max.fill"
        case .volume(let muted):
            if muted || model.level == 0 { return "speaker.slash.fill" }
            return model.level < 0.34 ? "speaker.wave.1.fill"
                : model.level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case .volumeLimit:
            return "speaker.wave.2.fill"
        case .notice(let symbol, _, _):
            return symbol
        }
    }

    private var title: String {
        switch model.kind {
        case .brightness: return "Brightness"
        case .volume: return "Volume"
        case .volumeLimit: return "Volume limit"
        case .notice(_, let title, _): return title
        }
    }

    private var readout: String {
        if case .notice(_, _, let detail) = model.kind { return detail ?? "" }
        return isMuted ? "Muted" : "\(Int((model.level * 100).rounded()))%"
    }

    private var isNotice: Bool {
        if case .notice = model.kind { return true }
        return false
    }

    private var fill: Double {
        isMuted ? 0 : min(max(model.level, 0), 1)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 24)
            if isNotice {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    if !readout.isEmpty {
                        Text(readout)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(readout)
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.16))
                            Capsule().fill(.primary).frame(width: proxy.size.width * fill)
                        }
                    }
                    .frame(height: 5)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: fill)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(width: 260, height: 58)
        .background(VisualEffect(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
        )
        .padding(4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(readout)")
    }
}

/// This app's own level indicator, used on every macOS version.
final class OverlayHUD {
    private let model = OverlayModel()
    private lazy var panel: NSPanel = {
        let size = NSSize(width: 268, height: 66)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
        return panel
    }()
    private var hideWork: DispatchWorkItem?

    func show(kind: HUDKind, level: Double) {
        model.kind = kind
        model.level = level

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.maxX - panel.frame.width - 12,
                y: frame.maxY - panel.frame.height - 8))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.invalidateShadow()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                // A new slide may have started during the fade.
                if self?.panel.alphaValue == 0 { self?.panel.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}

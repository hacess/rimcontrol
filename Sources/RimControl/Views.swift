import AppKit
import SwiftUI

// MARK: - Design tokens

enum Theme {
    // Darker than the system colours, so white symbols on these tiles stay legible.
    static let brightness = Color(red: 0.88, green: 0.42, blue: 0.04)
    static let volume = Color.blue
    static let mute = Color.red
    static let media = Color.purple
    static let precise = Color(red: 0.0, green: 0.52, blue: 0.56)
    static let haptics = Color.pink
    static let neutral = Color.gray

    static let surface = Color.primary.opacity(0.05)
    static let hairline = Color.primary.opacity(0.10)
    static let cardRadius: CGFloat = 10
    static let motion = Animation.easeOut(duration: 0.18)
}

// MARK: - Shared components

struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        // Without this the panel looks washed out, because a menu bar app is never the active app.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// The app's mark: a trackpad outline with its two control edges lit.
struct BrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.25, green: 0.33, blue: 0.95), Color(red: 0.12, green: 0.16, blue: 0.55)],
                    startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.09, style: .continuous)
                .strokeBorder(.white.opacity(0.55), lineWidth: max(1, size * 0.04))
                .frame(width: size * 0.66, height: size * 0.50)
            HStack(spacing: size * 0.34) {
                Capsule().fill(.white).frame(width: size * 0.06, height: size * 0.30)
                Capsule().fill(.white).frame(width: size * 0.06, height: size * 0.30)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}

/// A status dot paired with text, so the state never depends on colour alone.
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Theme.surface, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// A borderless button with hover and press feedback that never shifts the layout.
struct QuietButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A level track with a large drag area. Supports arrow keys and VoiceOver.
struct LevelTrack: View {
    let title: String
    let tint: Color
    let enabled: Bool
    @Binding var value: Double

    @State private var hovering = false
    @State private var dragging = false

    private static let keyStep = 1.0 / 16.0

    private func adjust(by delta: Double) {
        value = min(max(value + delta, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let knob: CGFloat = 16
            let travel = max(proxy.size.width - knob, 1)
            let offset = travel * min(max(value, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 6)
                Capsule()
                    .fill(enabled ? tint : Color.secondary.opacity(0.4))
                    .frame(width: offset + knob / 2, height: 6)
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .overlay(Circle().strokeBorder(.black.opacity(0.14), lineWidth: 0.5))
                    .shadow(color: .black.opacity(dragging ? 0.34 : hovering ? 0.28 : 0.2), radius: 2, y: 1)
                    .offset(x: offset)
                    .opacity(enabled ? 1 : 0.6)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard enabled else { return }
                        dragging = true
                        value = min(max((gesture.location.x - knob / 2) / travel, 0), 1)
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: 20)
        .onHover { hovering = $0 }
        // Like a native slider, this only takes focus when Keyboard Navigation is on in System Settings.
        // Otherwise the first track grabs focus and shows a ring whenever the window opens.
        .focusable(enabled && NSApplication.shared.isFullKeyboardAccessEnabled)
        .onMoveCommand { direction in
            guard enabled else { return }
            switch direction {
            case .left, .down: adjust(by: -Self.keyStep)
            case .right, .up: adjust(by: Self.keyStep)
            @unknown default: break
            }
        }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            switch direction {
            case .increment: adjust(by: Self.keyStep)
            case .decrement: adjust(by: -Self.keyStep)
            @unknown default: break
            }
        }
    }
}

// MARK: - Menu bar panel

struct MenuPanel: View {
    let controller: AppController
    let openSettings: () -> Void

    @ObservedObject var levels: LevelsModel
    @AppStorage(Key.swapSides) private var swapSides = false
    @AppStorage(Key.quickMute) private var quickMute = true
    @AppStorage(Key.mediaStrip) private var mediaStrip = true
    @AppStorage(Key.mediaTap) private var mediaTap = false
    @AppStorage(Key.invertMediaSwipe) private var invertSwipe = false
    @AppStorage(Key.preciseSliding) private var precise = false
    @AppStorage(Key.haptic) private var haptic = Haptics.Strength.subtle.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var status: (text: String, color: Color) {
        if levels.deviceCount == 0 { return ("No trackpad", .red) }
        if !levels.isTrusted { return ("Needs access", .orange) }
        return ("Active", .green)
    }

    private var brightnessRow: some View {
        LevelRow(
            title: "Brightness",
            edge: swapSides ? "Right edge" : "Left edge",
            symbol: "sun.max.fill",
            tint: Theme.brightness,
            enabled: levels.hasBrightness,
            value: Binding(get: { levels.brightness }, set: { controller.setBrightnessFromMenu($0) })
        )
    }

    private var volumeRow: some View {
        LevelRow(
            title: "Volume",
            edge: (swapSides ? "Left edge" : "Right edge")
                + (levels.volumeLimit.map { " · max \(Int(($0 * 100).rounded()))%" } ?? ""),
            symbol: "speaker.wave.2.fill",
            tint: Theme.volume,
            enabled: levels.hasVolume,
            value: Binding(get: { levels.volume }, set: { controller.setVolumeFromMenu($0) })
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !levels.isTrusted {
                PermissionCard { controller.requestAccessibility() }
            }

            VStack(spacing: 12) {
                if swapSides {
                    volumeRow
                    brightnessRow
                } else {
                    brightnessRow
                    volumeRow
                }
                // One output leaves nothing to choose.
                if levels.outputs.count > 1 {
                    HStack(spacing: 10) {
                        IconTile(symbol: levels.currentOutput?.symbol ?? "hifispeaker.fill", color: Theme.neutral)
                        Text("Output").font(.system(size: 13, weight: .medium))
                        OutputPicker(controller: controller, levels: levels)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .padding(12)
            .cardBackground()

            VStack(spacing: 0) {
                FeatureRow(
                    title: "Quick Mute", subtitle: "Double-tap the top-right corner",
                    symbol: "speaker.slash.fill", tint: Theme.mute, isOn: $quickMute)
                CardDivider()
                FeatureRow(
                    title: "Media Strip", subtitle: "Swipe the bottom edge to skip",
                    symbol: "forward.fill", tint: Theme.media, isOn: $mediaStrip)
                if mediaStrip {
                    VStack(spacing: 0) {
                        SubOptionRow(title: "Double-tap to play or pause", isOn: $mediaTap)
                        SubOptionRow(title: "Reverse swipe direction", isOn: $invertSwipe)
                    }
                    .padding(.bottom, 4)
                    .transition(.opacity)
                }
                CardDivider()
                FeatureRow(
                    title: "Precise Sliding", subtitle: "Always move in quarter steps",
                    symbol: "dial.low.fill", tint: Theme.precise, isOn: $precise)
                CardDivider()
                hapticRow
            }
            .cardBackground()
            .animation(reduceMotion ? nil : Theme.motion, value: mediaStrip)

            footer
        }
        .padding(12)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            BrandMark(size: 24)
            Text("RimControl").font(.system(size: 13, weight: .semibold))
            Spacer()
            StatusPill(text: status.text, color: status.color)
        }
    }

    private var hapticRow: some View {
        HStack(spacing: 10) {
            IconTile(symbol: "waveform", color: Theme.haptics)
            Text("Haptics").font(.system(size: 13, weight: .medium))
            Spacer(minLength: 8)
            Picker("Haptics", selection: $haptic) {
                ForEach(Haptics.Strength.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Button(action: openSettings) {
                Label("Settings…", systemImage: "gearshape").font(.system(size: 12))
            }
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Text("Quit").font(.system(size: 12))
            }
        }
        .buttonStyle(QuietButtonStyle())
    }
}

/// Chooses where sound goes. The same setting as Sound in System Settings.
struct OutputPicker: View {
    let controller: AppController
    @ObservedObject var levels: LevelsModel

    var body: some View {
        Picker("Output", selection: Binding(
            get: { levels.currentOutputID ?? 0 },
            set: { controller.selectOutput($0) }
        )) {
            ForEach(levels.outputs) { Text($0.name).tag($0.id) }
        }
        .labelsHidden()
    }
}

extension View {
    func cardBackground() -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
    }
}

private struct CardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 48)
    }
}

private struct LevelRow: View {
    let title: String
    let edge: String
    let symbol: String
    let tint: Color
    let enabled: Bool
    @Binding var value: Double

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconTile(symbol: symbol, color: enabled ? tint : Theme.neutral)
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(enabled ? edge : "Not available")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if enabled {
                        Text("\(Int((value * 100).rounded()))%")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                LevelTrack(title: title, tint: tint, enabled: enabled, value: $value)
            }
        }
    }
}

private struct FeatureRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, color: isOn ? tint : Theme.neutral)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct SubOptionRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.leading, 48)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
    }
}

struct PermissionCard: View {
    let request: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                IconTile(symbol: "lock.shield.fill", color: Theme.brightness)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow Accessibility access").font(.system(size: 13, weight: .medium))
                    Text("Needed for media keys, holding the pointer still and pausing gestures while you type. RimControl never reads what you type.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Allow Access…", action: request)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .cardBackground()
    }
}

// MARK: - Settings window

enum SettingsPage: String, CaseIterable, Identifiable {
    case edges = "Edges"
    case behavior = "Behavior"
    case audio = "Audio"
    case appearance = "Appearance"
    case general = "General"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .edges: return "rectangle.split.3x1.fill"
        case .behavior: return "hand.point.up.left.fill"
        case .audio: return "hifispeaker.fill"
        case .appearance: return "paintbrush.fill"
        case .general: return "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .edges: return .blue
        case .behavior: return .indigo
        case .audio: return .pink
        case .appearance: return .purple
        case .general: return .gray
        }
    }
}

struct SettingsPanel: View {
    let controller: AppController
    @ObservedObject var levels: LevelsModel
    var openGuide: () -> Void = {}
    @State var page: SettingsPage = .edges

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.hairline).frame(width: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(page.rawValue)
                        .font(.system(size: 20, weight: .semibold))
                    pageContent
                }
                .padding(.horizontal, 24)
                .padding(.top, 36)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 680, height: 540)
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                BrandMark(size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text("RimControl").font(.system(size: 13, weight: .semibold))
                    Text("Trackpad edges").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)

            ForEach(SettingsPage.allCases) { item in
                SidebarRow(page: item, isSelected: item == page) { page = item }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 44)
        .frame(width: 190)
        .frame(maxHeight: .infinity)
        .background(VisualEffect(material: .sidebar))
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .edges: EdgesPage()
        case .behavior: BehaviorPage()
        case .audio: AudioPage(controller: controller, levels: levels)
        case .appearance: AppearancePage()
        case .general: GeneralPage(controller: controller, levels: levels, openGuide: openGuide)
        }
    }
}

private struct SidebarRow: View {
    let page: SettingsPage
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                IconTile(symbol: page.symbol, color: page.tint, size: 20)
                Text(page.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.12 : hovering ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SettingsSection<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            CardStack { content }
                .cardBackground()
        }
    }
}

/// Stacks rows in a card. Each row draws its own divider through `showsDivider`.
private struct CardStack<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var showsDivider = true
    @ViewBuilder let control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                control
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            if showsDivider {
                Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 12)
            }
        }
    }
}

private struct ToggleRow: View {
    let title: String
    var subtitle: String?
    var showsDivider = true
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title: title, subtitle: subtitle, showsDivider: showsDivider) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

private struct SliderRow: View {
    let title: String
    let readout: String
    let range: ClosedRange<Double>
    var showsDivider = true
    @Binding var value: Double

    var body: some View {
        SettingRow(title: title, showsDivider: showsDivider) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 170)
                    .accessibilityLabel(title)
                    .accessibilityValue(readout)
                Text(readout)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: Edges page

enum DiagramFocus { case edges, corner, strip }

/// A live diagram of which parts of the trackpad do what, drawn from the current settings.
struct TrackpadDiagram: View {
    let swapSides: Bool
    let activeArea: Double
    let edgeWidth: Double
    let quickMute: Bool
    let mediaStrip: Bool
    /// When set, the other zones fade back so this one stands out.
    var focus: DiagramFocus?

    private func zoneOpacity(_ zone: DiagramFocus) -> Double {
        focus == nil || focus == zone ? 1 : 0.2
    }

    private let width: CGFloat = 250
    private let height: CGFloat = 156

    private var leftColor: Color { swapSides ? Theme.volume : Theme.brightness }
    private var rightColor: Color { swapSides ? Theme.brightness : Theme.volume }
    private var leftSymbol: String { swapSides ? "speaker.wave.2.fill" : "sun.max.fill" }
    private var rightSymbol: String { swapSides ? "sun.max.fill" : "speaker.wave.2.fill" }

    /// Slides cannot begin inside the media strip, so the bars stop above it.
    private var barBottomInset: CGFloat { mediaStrip ? height * 0.10 : 0 }
    private var barHeight: CGFloat {
        max(0, height * activeArea - barBottomInset)
    }
    private var barWidth: CGFloat { width * edgeWidth }

    private func bar(_ color: Color, symbol: String) -> some View {
        Rectangle()
            .fill(color.opacity(0.85))
            .frame(width: barWidth, height: barHeight)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: min(11, max(7, barWidth * 0.62)), weight: .semibold))
                    .foregroundStyle(.white)
            )
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.06))

            VStack {
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    bar(leftColor, symbol: leftSymbol)
                    Spacer(minLength: 0)
                    bar(rightColor, symbol: rightSymbol)
                }
                .padding(.bottom, barBottomInset)
            }
            .opacity(zoneOpacity(.edges))

            if mediaStrip {
                VStack {
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(Theme.media.opacity(0.75))
                        .frame(height: height * 0.10)
                        .overlay(
                            Image(systemName: "forward.fill")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                }
                .opacity(zoneOpacity(.strip))
            }

            if quickMute {
                VStack {
                    HStack {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(Theme.mute)
                            .frame(width: width * 0.14, height: width * 0.14)
                            .overlay(
                                Image(systemName: "speaker.slash.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white)
                            )
                    }
                    Spacer(minLength: 0)
                }
                .opacity(zoneOpacity(.corner))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts = ["Trackpad diagram.", swapSides ? "Volume on the left, brightness on the right." : "Brightness on the left, volume on the right."]
        if quickMute { parts.append("Quick Mute in the top-right corner.") }
        if mediaStrip { parts.append("Media strip along the bottom.") }
        return parts.joined(separator: " ")
    }
}

private struct LegendItem: View {
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2.5).fill(color).frame(width: 10, height: 10).padding(.top, 3)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct EdgesPage: View {
    @AppStorage(Key.swapSides) private var swapSides = false
    @AppStorage(Key.activeArea) private var activeArea = 1.0
    @AppStorage(Key.edgeWidth) private var edgeWidth = 0.05
    @AppStorage(Key.sensitivity) private var sensitivity = 1.0
    @AppStorage(Key.quickMute) private var quickMute = true
    @AppStorage(Key.mediaStrip) private var mediaStrip = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var diagramState: [Double] {
        [swapSides ? 1 : 0, activeArea, edgeWidth, quickMute ? 1 : 0, mediaStrip ? 1 : 0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 20) {
                TrackpadDiagram(
                    swapSides: swapSides, activeArea: activeArea, edgeWidth: edgeWidth,
                    quickMute: quickMute, mediaStrip: mediaStrip)
                    .animation(reduceMotion ? nil : Theme.motion, value: diagramState)
                VStack(alignment: .leading, spacing: 10) {
                    LegendItem(color: Theme.brightness, title: "Brightness",
                               detail: swapSides ? "Slide on the right edge" : "Slide on the left edge")
                    LegendItem(color: Theme.volume, title: "Volume",
                               detail: swapSides ? "Slide on the left edge" : "Slide on the right edge")
                    if quickMute {
                        LegendItem(color: Theme.mute, title: "Quick Mute", detail: "Double-tap the corner")
                    }
                    if mediaStrip {
                        LegendItem(color: Theme.media, title: "Media Strip", detail: "Swipe to skip tracks")
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()

            SettingsSection {
                ToggleRow(title: "Swap sides", subtitle: "Put brightness on the right edge", isOn: $swapSides)
                SettingRow(title: "Active area", subtitle: "Where along the edge a slide can start") {
                    Picker("Active area", selection: $activeArea) {
                        Text("Full edge").tag(1.0)
                        Text("Bottom ¾").tag(0.75)
                        Text("Bottom half").tag(0.5)
                        Text("Bottom quarter").tag(0.25)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SliderRow(
                    title: "Edge width", readout: "\(Int((edgeWidth * 100).rounded()))%",
                    range: 0.03...0.15, value: $edgeWidth)
                SliderRow(
                    title: "Sensitivity", readout: String(format: "%.1f×", sensitivity),
                    range: 0.5...2.5, showsDivider: false, value: $sensitivity)
            }
        }
    }
}

// MARK: Behavior page

private struct BehaviorPage: View {
    @AppStorage(Key.freezeCursor) private var freezeCursor = true
    @AppStorage(Key.requireModifier) private var requireModifier = false
    @AppStorage(Key.magicMouse) private var magicMouse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(title: "While sliding") {
                ToggleRow(
                    title: "Hide the pointer and hold it still",
                    subtitle: "The pointer stays where it was when the slide began",
                    isOn: $freezeCursor)
                SettingRow(title: "Fine control", subtitle: "Hold these keys during a slide for quarter steps", showsDivider: false) {
                    HStack(spacing: 4) {
                        KeyCap("⇧")
                        KeyCap("⌥")
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Shift and Option")
                }
            }
            SettingsSection(title: "Starting a slide") {
                ToggleRow(
                    title: "Require a modifier key",
                    subtitle: "Only slide while holding Fn or Option",
                    showsDivider: false,
                    isOn: $requireModifier)
            }
            SettingsSection(title: "Devices") {
                ToggleRow(
                    title: "Magic Mouse",
                    subtitle: "Also slide on the mouse's top edges",
                    showsDivider: false,
                    isOn: $magicMouse)
            }
        }
    }
}

private struct KeyCap: View {
    let symbol: String
    init(_ symbol: String) { self.symbol = symbol }

    var body: some View {
        Text(symbol)
            .font(.system(size: 13, weight: .medium))
            .frame(width: 26, height: 24)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
    }
}

// MARK: Audio page

private struct AudioPage: View {
    let controller: AppController
    @ObservedObject var levels: LevelsModel

    private var outputName: String { levels.currentOutput?.name ?? "This output" }

    /// Limits move in 5% steps, so the slider's readout stays a round number.
    private var limitValue: Binding<Double> {
        Binding(
            get: { levels.volumeLimit ?? 1 },
            set: { controller.setVolumeLimit(($0 * 20).rounded() / 20) })
    }

    private var limitEnabled: Binding<Bool> {
        Binding(
            get: { levels.volumeLimit != nil },
            set: { controller.setVolumeLimit($0 ? 0.75 : nil) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(title: "Output") {
                SettingRow(title: "Play sound through", showsDivider: false) {
                    if levels.outputs.isEmpty {
                        Text("None found").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        OutputPicker(controller: controller, levels: levels).frame(maxWidth: 260)
                    }
                }
            }
            SettingsSection(title: "Volume limit") {
                if levels.hasVolume {
                    ToggleRow(
                        title: "Limit the volume of \(outputName)",
                        subtitle: "Also covers the volume keys and other apps while RimControl is running. Each output has its own limit.",
                        showsDivider: levels.volumeLimit != nil,
                        isOn: limitEnabled)
                    if let limit = levels.volumeLimit {
                        SliderRow(
                            title: "Maximum volume", readout: "\(Int((limit * 100).rounded()))%",
                            range: 0.1...1, showsDivider: false, value: limitValue)
                    }
                } else {
                    SettingRow(
                        title: "\(outputName) has no volume control",
                        subtitle: "Choose another output to set a limit.",
                        showsDivider: false) { EmptyView() }
                }
            }
        }
    }
}

// MARK: Appearance page

private struct ChoiceCard<Preview: View>: View {
    let title: String
    var subtitle: String?
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let preview: Preview

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                preview
                    .frame(height: 76)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 0.5)
                    )
                HStack(spacing: 5) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(.system(size: 12, weight: .medium))
                        if let subtitle {
                            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Theme.hairline, lineWidth: isSelected ? 2 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct MiniWindow: View {
    let dark: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(dark ? Color(white: 0.16) : Color(white: 0.96))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(dark ? Color(white: 0.4) : Color(white: 0.75)).frame(width: 5, height: 5)
                    }
                }
                Capsule().fill(dark ? Color(white: 0.5) : Color(white: 0.55)).frame(width: 46, height: 4)
                Capsule().fill(dark ? Color(white: 0.3) : Color(white: 0.8)).frame(width: 66, height: 4)
                Capsule().fill(Color.accentColor).frame(width: 30, height: 4)
            }
            .padding(9)
        }
    }
}

private struct MiniHUD: View {
    let classic: Bool

    var body: some View {
        ZStack(alignment: classic ? .center : .topTrailing) {
            LinearGradient(
                colors: [Color.blue.opacity(0.35), Color.purple.opacity(0.35)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            if classic {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.black.opacity(0.45))
                    .frame(width: 44, height: 44)
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.white)
                            Capsule().fill(.white).frame(width: 28, height: 3)
                        }
                    )
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.white)
                    Capsule().fill(.white).frame(width: 40, height: 3)
                }
                .padding(.horizontal, 7)
                .frame(height: 16)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(6)
            }
        }
    }
}

private struct AppearancePage: View {
    @AppStorage(Key.appearance) private var appearance = "system"
    @AppStorage(Key.classicHUD) private var classicHUD = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Theme")
                HStack(spacing: 10) {
                    ChoiceCard(title: "System", isSelected: appearance == "system", action: { appearance = "system" }) {
                        HStack(spacing: 0) {
                            MiniWindow(dark: false)
                            MiniWindow(dark: true)
                        }
                    }
                    ChoiceCard(title: "Light", isSelected: appearance == "light", action: { appearance = "light" }) {
                        MiniWindow(dark: false)
                    }
                    ChoiceCard(title: "Dark", isSelected: appearance == "dark", action: { appearance = "dark" }) {
                        MiniWindow(dark: true)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Level display")
                HStack(spacing: 10) {
                    ChoiceCard(
                        title: "Modern", subtitle: "A banner in the corner",
                        isSelected: !classicHUD, action: { classicHUD = false }
                    ) { MiniHUD(classic: false) }
                    ChoiceCard(
                        title: "Classic", subtitle: "The system's centred square",
                        isSelected: classicHUD, action: { classicHUD = true }
                    ) { MiniHUD(classic: true) }
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }
}

// MARK: General page

private struct GeneralPage: View {
    let controller: AppController
    @ObservedObject var levels: LevelsModel
    let openGuide: () -> Void
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(title: "Startup") {
                ToggleRow(title: "Open at login", showsDivider: false, isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { LaunchAtLogin.set($0) }
            }
            SettingsSection(title: "Status") {
                SettingRow(title: "Accessibility", subtitle: "Needed for media keys and holding the pointer still") {
                    if levels.isTrusted {
                        StatusPill(text: "Allowed", color: .green)
                    } else {
                        Button("Allow Access…") { controller.requestAccessibility() }
                            .controlSize(.small)
                    }
                }
                SettingRow(title: "Trackpad", showsDivider: false) {
                    StatusPill(
                        text: levels.deviceCount == 0 ? "Not found" : "Connected",
                        color: levels.deviceCount == 0 ? .red : .green)
                }
            }
            SettingsSection(title: "About") {
                SettingRow(title: "Gesture guide", subtitle: "Walk through each gesture again") {
                    Button("Show Guide…", action: openGuide)
                        .controlSize(.small)
                }
                SettingRow(title: "Version", showsDivider: false) {
                    Text(version)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

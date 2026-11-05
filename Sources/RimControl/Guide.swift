import SwiftUI

/// The first-run walkthrough. Each step ticks off when the real gesture is performed.
struct GuideView: View {
    private enum Step: Hashable { case welcome, edges, mute, media, finish }

    let controller: AppController
    let onFinish: () -> Void
    @ObservedObject var levels: LevelsModel

    @AppStorage(Key.swapSides) private var swapSides = false
    @AppStorage(Key.activeArea) private var activeArea = 1.0
    @AppStorage(Key.edgeWidth) private var edgeWidth = 0.05
    @AppStorage(Key.quickMute) private var quickMute = true
    @AppStorage(Key.mediaStrip) private var mediaStrip = true
    @AppStorage(Key.mediaTap) private var mediaTap = false
    @AppStorage(Key.invertMediaSwipe) private var invertSwipe = false
    @AppStorage(Key.requireModifier) private var requireModifier = false

    @State private var index: Int
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    init(controller: AppController, levels: LevelsModel, startAt index: Int = 0, onFinish: @escaping () -> Void) {
        self.controller = controller
        self.levels = levels
        self.onFinish = onFinish
        _index = State(initialValue: index)
    }

    /// Features switched off in Settings have nothing to practise, so their steps are left out.
    private var steps: [Step] {
        var steps: [Step] = [.welcome, .edges]
        if quickMute { steps.append(.mute) }
        if mediaStrip { steps.append(.media) }
        steps.append(.finish)
        return steps
    }

    private var position: Int { min(index, steps.count - 1) }
    private var isLast: Bool { position == steps.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 44)
                .padding(.top, 32)
            footer
        }
        .frame(width: 540, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        switch steps[position] {
        case .welcome: welcome
        case .edges: edges
        case .mute: mute
        case .media: media
        case .finish: finish
        }
    }

    private func diagram(_ focus: DiagramFocus) -> some View {
        TrackpadDiagram(
            swapSides: swapSides, activeArea: activeArea, edgeWidth: edgeWidth,
            quickMute: quickMute, mediaStrip: mediaStrip, focus: focus)
    }

    private func heading(_ title: String, _ message: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 20, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            BrandMark(size: 64)
            heading(
                "Welcome to RimControl",
                "The edges of your trackpad become volume, brightness and media controls. This takes about a minute.")
            if levels.isTrusted {
                StatusPill(text: "Accessibility allowed", color: .green)
            } else {
                PermissionCard { controller.requestAccessibility() }
            }
            if levels.deviceCount == 0 {
                Text("No trackpad found. Connect one to try the gestures.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var edges: some View {
        VStack(spacing: 18) {
            diagram(.edges)
            heading(
                "Slide along an edge",
                "Use one finger on the \(swapSides ? "right" : "left") edge for brightness, and the \(swapSides ? "left" : "right") edge for volume."
                    + (requireModifier ? " Hold Fn or Option while you slide." : ""))
            HStack(spacing: 8) {
                PracticeChip(title: "Brightness", done: levels.practiced.contains(.brightness))
                PracticeChip(title: "Volume", done: levels.practiced.contains(.volume))
            }
            Spacer(minLength: 0)
        }
    }

    private var mute: some View {
        VStack(spacing: 18) {
            diagram(.corner)
            heading(
                "Double-tap the top-right corner",
                "This mutes your sound. Double-tap again to turn it back on.")
            PracticeChip(title: "Quick Mute", done: levels.practiced.contains(.mute))
            Spacer(minLength: 0)
        }
    }

    private var media: some View {
        VStack(spacing: 18) {
            diagram(.strip)
            heading(
                "Swipe along the bottom edge",
                "Swipe \(invertSwipe ? "left" : "right") for the next track and \(invertSwipe ? "right" : "left") for the previous one."
                    + (mediaTap ? " Double-tap to play or pause." : "")
                    + " Start some music first to hear it work.")
            PracticeChip(title: "Media Strip", done: levels.practiced.contains(.media))
            Spacer(minLength: 0)
        }
    }

    private var finish: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            heading(
                "You're all set",
                "RimControl lives in the menu bar. Open it from there to change settings or pick an audio output.")
            Toggle("Open RimControl at login", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 13))
                .onChange(of: launchAtLogin) { LaunchAtLogin.set($0) }
            Spacer(minLength: 0)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("Step \(position + 1) of \(steps.count)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            if position > 0 {
                Button("Back") { index = position - 1 }
            }
            Button(isLast ? "Done" : "Next") {
                if isLast { onFinish() } else { index = position + 1 }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

/// Shows whether a gesture has been tried. The icon and wording both carry the state, not just colour.
private struct PracticeChip: View {
    let title: String
    let done: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : "hand.point.up.left")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .frame(width: 14)
            Text(done ? "\(title) works" : "Try \(title)")
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.surface, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

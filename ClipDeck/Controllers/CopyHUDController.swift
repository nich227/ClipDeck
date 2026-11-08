import AppKit
import QuartzCore
import SwiftUI

/// A glass pill confirms a copy without taking focus. It appears below the menu bar on the screen
/// that contains the mouse pointer. It shows the check and the item's name, then disappears on its
/// own.
///
/// The pill uses an `NSGlassEffectView` instead of a SwiftUI glass effect because SwiftUI draws its
/// glass above hosted AppKit views. The check is a hosted AppKit view because Lottie renders
/// through AppKit. The pill's content view always sits inside the glass.
@MainActor
final class CopyHUDController {
    private var panel: NSPanel?
    private var pill: NSGlassEffectView?
    private let model = CopyHUDModel()
    private var dismissal: Task<Void, Never>?

    private var pillSize: NSSize { NSSize(width: Constants.HUD.width, height: Constants.HUD.height) }
    /// The height accommodates the pill plus the distance it travels from above the screen edge.
    private var windowSize: NSSize { NSSize(width: pillSize.width, height: pillSize.height * 2 + Constants.HUD.topGap) }
    private var shownOrigin: NSPoint { NSPoint(x: 0, y: windowSize.height - Constants.HUD.topGap - pillSize.height) }
    private var hiddenOrigin: NSPoint { NSPoint(x: 0, y: windowSize.height) }

    func show(for item: ClipItem) {
        guard UserDefaults.standard.object(forKey: Constants.showCopyConfirmationKey) as? Bool ?? true else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(frameOnMouseScreen(), display: false)
        model.title = MenuFormatting.title(for: item)
        model.run += 1
        model.visible = true
        panel.orderFrontRegardless()
        move(to: shownOrigin, alpha: 1, spring: .arrive)

        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: Constants.HUD.dwell)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        model.visible = false
        move(to: hiddenOrigin, alpha: 0, spring: .depart)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !model.visible else { return }
            panel?.orderOut(nil)
        }
    }

    /// The pill uses a spring animation on its layer. With Reduce Motion on, it fades in place.
    private func move(to origin: NSPoint, alpha: CGFloat, spring: Spring) {
        guard let pill, let layer = pill.layer else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let from = layer.presentation()?.position.y ?? layer.position.y
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = alpha
        fade.duration = reduceMotion ? 0.15 : spring.response * 0.8
        pill.setFrameOrigin(reduceMotion ? shownOrigin : origin)
        pill.alphaValue = alpha
        layer.removeAllAnimations()
        layer.add(fade, forKey: "opacity")
        guard !reduceMotion else { return }
        let slide = CASpringAnimation(keyPath: "position.y")
        slide.fromValue = from
        slide.toValue = layer.position.y
        slide.mass = 1
        slide.stiffness = spring.stiffness
        slide.damping = spring.damping
        slide.duration = slide.settlingDuration
        layer.add(slide, forKey: "position")
    }

    /// The HUD's springs use Core Animation parameters derived from the SwiftUI spring response and
    /// damping fraction.
    struct Spring {
        let response: CGFloat
        let stiffness: CGFloat
        let damping: CGFloat

        /// It has one small overshoot.
        static let arrive = Spring(response: 0.45, dampingFraction: 0.72)
        /// It leaves without bouncing because it is critically damped.
        static let depart = Spring(response: 0.35, dampingFraction: 1)

        init(response: CGFloat, dampingFraction: CGFloat) {
            self.response = response
            let omega = 2 * CGFloat.pi / response
            stiffness = omega * omega
            damping = 2 * dampingFraction * omega
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none

        let container = NSView(frame: NSRect(origin: .zero, size: windowSize))
        container.wantsLayer = true
        let host = NSHostingView(rootView: CopyHUDView(model: model))
        host.frame = NSRect(origin: .zero, size: pillSize)
        host.autoresizingMask = [.width, .height]
        let pill = NSGlassEffectView(frame: NSRect(origin: hiddenOrigin, size: pillSize))
        pill.wantsLayer = true
        pill.cornerRadius = pillSize.height / 2
        pill.style = .regular
        pill.contentView = host
        pill.alphaValue = 0
        container.addSubview(pill)
        self.pill = pill
        panel.contentView = container
        return panel
    }

    /// It is centered at the top of the screen that contains the mouse pointer, just under the menu
    /// bar.
    private func frameOnMouseScreen() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: visible.midX - windowSize.width / 2, y: visible.maxY - windowSize.height,
            width: windowSize.width, height: windowSize.height
        )
    }
}

@MainActor
final class CopyHUDModel: ObservableObject {
    @Published var title = ""
    @Published var visible = false
    /// It changes each time it is shown, so the check runs again even for the same item.
    @Published var run = 0
}

/// The pill contains the check, followed by two lines of text.
struct CopyHUDView: View {
    @ObservedObject var model: CopyHUDModel

    var body: some View {
        HStack(spacing: Space.sm) {
            DeckAnimation(name: Constants.Animations.copied, isActive: model.visible)
                .id(model.run)
                .frame(width: Constants.HUD.checkSide, height: Constants.HUD.checkSide)
            VStack(alignment: .leading, spacing: 1) {
                Text("Copied")
                    .deckFont(.label)
                    .foregroundStyle(Palette.textPrimary)
                Text(model.title)
                    .deckFont(.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.md)
        .frame(width: Constants.HUD.width, height: Constants.HUD.height)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Copied \(model.title)")
    }
}

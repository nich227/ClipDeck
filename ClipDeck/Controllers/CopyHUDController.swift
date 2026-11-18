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
    private let defaults: UserDefaults
    private let announce: @MainActor (String) -> Void

    init(defaults: UserDefaults = .standard, announce: @escaping @MainActor (String) -> Void = CopyHUDController.announce) {
        self.defaults = defaults
        self.announce = announce
    }

    private var pillSize: NSSize { NSSize(width: Constants.HUD.width, height: Constants.HUD.height) }
    /// The height accommodates the pill plus the distance it travels from above the screen edge.
    private var windowSize: NSSize { NSSize(width: pillSize.width, height: pillSize.height * 2 + Constants.HUD.topGap) }
    private var shownOrigin: NSPoint { NSPoint(x: 0, y: windowSize.height - Constants.HUD.topGap - pillSize.height) }
    private var hiddenOrigin: NSPoint { NSPoint(x: 0, y: windowSize.height) }

    func show(for item: ClipItem) {
        let title = MenuFormatting.title(for: item)
        // The setting turns off the pill. VoiceOver still says what was copied.
        announce("Copied \(title)")
        guard defaults.object(forKey: Constants.showCopyConfirmationKey) as? Bool ?? true else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(frameOnMouseScreen(), display: false)
        model.title = title
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

    /// The pill takes no focus, so VoiceOver announces the confirmation.
    static func announce(_ message: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    private func hide() {
        model.visible = false
        move(to: hiddenOrigin, alpha: 0, spring: .depart)
        Task { [weak self] in
            try? await Task.sleep(for: Constants.HUD.orderOutDelay)
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

    /// It is centered just under the menu bar on the screen that contains the mouse pointer.
    private func frameOnMouseScreen() -> NSRect {
        let visible = NSScreen.visibleFrameUnderMouse
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
            VStack(alignment: .leading, spacing: Space.xxxs) {
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

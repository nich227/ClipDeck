import AppKit
import Lottie
import os
import SwiftUI

/// Drawn animations use one entry point: a bundled Lottie file in a single tint. A one-shot draws
/// on once and holds its still frame. A loop repeats. Nothing plays while `isActive` is false, and
/// a loop then holds no layers at all. With Reduce Motion on, the still frame shows without moving.
/// The view takes whatever frame the caller gives it and fits the drawing inside.
struct DeckAnimation: View {
    private let name: String
    private let loops: Bool
    private let isActive: Bool
    private let tint: Color
    private let stillOnly: Bool
    private let label: String?
    private let onFinished: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - name: a file from `Constants.Animations`.
    ///   - loops: repeat the whole file, or play once up to the still frame.
    ///   - isActive: whether the surface under the animation is on screen. Each change from false
    ///     to true plays a one-shot again.
    ///   - label: the VoiceOver label. Without one the animation is decorative and hidden.
    ///   - onFinished: called on the main thread when a one-shot reaches its still frame: at the
    ///     end of the drawing, when it is cut short by going inactive, or right away if Reduce
    ///     Motion is on. Never called for a loop.
    init(
        name: String,
        loops: Bool = false,
        isActive: Bool = true,
        tint: Color = Palette.accent,
        label: String? = nil,
        onFinished: (() -> Void)? = nil
    ) {
        self.init(name: name, loops: loops, isActive: isActive, tint: tint, stillOnly: false, label: label, onFinished: onFinished)
    }

    /// Only the still frame appears for a state that was already true when its surface appeared.
    static func still(name: String, tint: Color = Palette.accent, label: String? = nil) -> DeckAnimation {
        DeckAnimation(name: name, loops: false, isActive: true, tint: tint, stillOnly: true, label: label, onFinished: nil)
    }

    private init(
        name: String, loops: Bool, isActive: Bool, tint: Color, stillOnly: Bool, label: String?, onFinished: (() -> Void)?
    ) {
        self.name = name
        self.loops = loops
        self.isActive = isActive
        self.tint = tint
        self.stillOnly = stillOnly
        self.label = label
        self.onFinished = onFinished
    }

    var body: some View {
        let player = DeckAnimationPlayer(
            name: name,
            playback: Self.playback(loops: loops, isActive: isActive, reduceMotion: reduceMotion, stillOnly: stillOnly),
            tint: tint,
            onFinished: loops || stillOnly ? nil : onFinished
        )
        .allowsHitTesting(false)
        if let label {
            player
                .accessibilityElement()
                .accessibilityLabel(label)
                .accessibilityAddTraits(.isImage)
        } else {
            player.accessibilityHidden(true)
        }
    }

    static func playback(loops: Bool, isActive: Bool, reduceMotion: Bool, stillOnly: Bool) -> DeckAnimationSurface.Playback {
        guard isActive else { return .idle }
        if stillOnly || reduceMotion { return .still }
        return loops ? .loop : .once
    }

    /// Decodes every bundled file off the main thread, including the file for the first animation
    /// shown. It is safe to call once at launch and leaves nothing running.
    static func preload() {
        Task { await DeckAnimationLibrary.preload() }
    }
}

private struct DeckAnimationPlayer: NSViewRepresentable {
    let name: String
    let playback: DeckAnimationSurface.Playback
    let tint: Color
    let onFinished: (() -> Void)?

    func makeNSView(context: Context) -> DeckAnimationSurface {
        DeckAnimationSurface(name: name)
    }

    func updateNSView(_ surface: DeckAnimationSurface, context: Context) {
        surface.setAnimation(named: name)
        surface.onFinished = onFinished
        surface.setTint(tint)
        surface.setPlayback(playback)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView surface: DeckAnimationSurface, context: Context) -> CGSize? {
        surface.fittingSize(width: proposal.width, height: proposal.height)
    }

    static func dismantleNSView(_ surface: DeckAnimationSurface, coordinator: ()) {
        surface.onFinished = nil
        surface.setPlayback(.idle)
        surface.releasePlayer()
    }
}

/// The AppKit view is under `DeckAnimation`. It owns one `LottieAnimationLayer`. The view builds
/// the layer on first use and releases it when a loop goes idle or the view leaves its window.
/// Thus, an animation that is not showing holds no layers or Core Animation animations.
final class DeckAnimationSurface: NSView {
    enum Playback: Equatable {
        /// The surface is off screen. A loop is released. A one-shot keeps its still frame.
        case idle
        /// The still frame shows no movement.
        case still
        /// Play from the first frame to the still frame. Then hold on the still frame.
        case once
        /// The whole file repeats.
        case loop
    }

    private(set) var playback = Playback.idle
    var onFinished: (() -> Void)?

    private(set) var name: String
    private var animation: LottieAnimation?
    private var stillFrame: AnimationFrameTime = 0
    private(set) var player: LottieAnimationLayer?
    private var tint = Palette.accent
    private var appliedTint: LottieColor?
    /// Whether a one-shot has started and its `onFinished` has not been called yet.
    private var owesFinish = false
    /// This records whether the current one-shot reached its still frame, so a rebuilt player shows
    /// the still.
    private var finishedOnce = false

    private static let strokeColor = AnimationKeypath(keypath: "**.Stroke 1.Color")

    init(name: String) {
        self.name = name
        super.init(frame: .zero)
        wantsLayer = true
        load()
        NotificationCenter.default.addObserver(
            self, selector: #selector(systemColorsDidChange), name: NSColor.systemColorsDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// Lottie's coordinate space has its origin at the top left.
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    /// Returns the file's canvas size, or zero if the file did not load.
    var canvasSize: CGSize { animation?.size ?? .zero }

    /// Use the proposed size when specified, and use the canvas size for any unspecified dimension.
    func fittingSize(width: CGFloat?, height: CGFloat?) -> CGSize {
        func resolve(_ proposed: CGFloat?, _ natural: CGFloat) -> CGFloat {
            guard let proposed, proposed.isFinite else { return natural }
            return max(proposed, 0)
        }
        return CGSize(width: resolve(width, canvasSize.width), height: resolve(height, canvasSize.height))
    }

    func setAnimation(named name: String) {
        guard name != self.name else { return }
        self.name = name
        let current = playback
        releasePlayer()
        load()
        finishedOnce = false
        playback = .idle
        setPlayback(current)
    }

    func setTint(_ tint: Color) {
        guard tint != self.tint else { return }
        self.tint = tint
        refreshTint()
    }

    func setPlayback(_ target: Playback) {
        guard target != playback else { return }
        let previous = playback
        playback = target
        switch target {
        case .idle:
            if previous == .loop {
                releasePlayer()
            } else {
                settle()
            }
        case .still:
            showStill()
            if previous == .idle { owesFinish = true }
            finish()
        case .once:
            finishedOnce = false
            owesFinish = true
            guard let animation, let player = makePlayer() else { return }
            player.play(fromFrame: animation.startFrame, toFrame: stillFrame, loopMode: .playOnce) { [weak self] completed in
                guard let self, completed, self.playback == .once else { return }
                self.finishedOnce = true
                self.finish()
            }
        case .loop:
            guard let animation, let player = makePlayer() else { return }
            player.play(fromFrame: animation.startFrame, toFrame: animation.endFrame, loopMode: .loop)
        }
    }

    func releasePlayer() {
        player?.removeFromSuperlayer()
        player = nil
        appliedTint = nil
    }

    override func layout() {
        super.layout()
        layoutPlayer()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutPlayer()
    }

    /// Core Animation drops a layer's animations when it leaves its window. Thus, the player is
    /// released with the window and rebuilt in the next one.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            if playback == .once, player != nil { finishedOnce = true }
            releasePlayer()
            return
        }
        player?.screenScale = backingScale
        guard player == nil else { return }
        switch playback {
        case .idle:
            break
        case .still:
            showStill()
        case .once:
            if finishedOnce {
                showStill()
            } else {
                playback = .idle
                setPlayback(.once)
            }
        case .loop:
            playback = .idle
            setPlayback(.loop)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        player?.screenScale = backingScale
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTint()
    }

    @objc private func systemColorsDidChange() {
        refreshTint()
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func load() {
        animation = DeckAnimationLibrary.animation(named: name)
        stillFrame = animation.map(DeckAnimationLibrary.stillFrame) ?? 0
    }

    private func makePlayer() -> LottieAnimationLayer? {
        if let player { return player }
        guard let animation else { return nil }
        let player = LottieAnimationLayer(
            animation: animation, configuration: DeckAnimationLibrary.configuration, logger: DeckAnimationLibrary.logger
        )
        player.screenScale = backingScale
        layer?.addSublayer(player)
        self.player = player
        refreshTint()
        layoutPlayer()
        return player
    }

    private func showStill() {
        finishedOnce = true
        makePlayer()?.currentFrame = stillFrame
    }

    /// A one-shot that goes idle partway through jumps to its still frame.
    private func settle() {
        guard let player, player.isAnimationPlaying else { return }
        finishedOnce = true
        player.currentFrame = stillFrame
        finish()
    }

    private func finish() {
        guard owesFinish else { return }
        owesFinish = false
        guard let onFinished else { return }
        DispatchQueue.main.async(execute: onFinished)
    }

    private func layoutPlayer() {
        guard let player, let content = player.animationLayer, canvasSize.width > 0, canvasSize.height > 0 else { return }
        let scale = min(bounds.width / canvasSize.width, bounds.height / canvasSize.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        player.frame = bounds
        content.position = CGPoint(x: bounds.midX, y: bounds.midY)
        content.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
    }

    /// The code resolves the tint against this view's appearance. It hands the tint to Lottie only
    /// when the resolved color has changed because a new value provider rebuilds every Core
    /// Animation animation.
    private func refreshTint() {
        guard let player else { return }
        let color = resolvedTint()
        guard color != appliedTint else { return }
        appliedTint = color
        player.setValueProvider(ColorValueProvider(color), keypath: Self.strokeColor)
    }

    private func resolvedTint() -> LottieColor {
        var color = LottieColor(r: 1, g: 1, b: 1, a: 1)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let rgb = NSColor(tint).usingColorSpace(.sRGB) ?? NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return }
            color = LottieColor(
                r: Double(rgb.redComponent), g: Double(rgb.greenComponent), b: Double(rgb.blueComponent),
                a: Double(rgb.alphaComponent)
            )
        }
        return color
    }
}

/// The decoded animations use one instance per file for the life of the process, and every player
/// shares the Lottie configuration.
@MainActor
enum DeckAnimationLibrary {
    private static var animations: [String: LottieAnimation] = [:]
    private static let log = Logger(subsystem: Constants.logSubsystem, category: "Animation")

    /// ClipDeck uses only the Core Animation engine, which renders in the render server with no
    /// work per frame in this process. If the engine cannot draw an animation, it logs it instead
    /// of moving it to the main thread engine. `DeckAnimation` handles Reduce Motion, so Lottie's
    /// own handling is off.
    static let configuration: LottieConfiguration = {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        // Lottie reads the color space for stroke colors from the shared configuration only.
        LottieConfiguration.shared.colorSpace = sRGB
        return LottieConfiguration(
            renderingEngine: .coreAnimation, decodingStrategy: .dictionaryBased, colorSpace: sRGB,
            reducedMotionOption: .standardMotion
        )
    }()

    static let logger = LottieLogger(
        assert: { condition, message, _, _ in
            guard !condition() else { return }
            let text = message()
            log.fault("Lottie: \(text, privacy: .public)")
        },
        assertionFailure: { message, _, _ in
            let text = message()
            log.fault("Lottie: \(text, privacy: .public)")
        },
        warn: { message, _, _ in
            let text = message()
            log.error("Lottie: \(text, privacy: .public)")
        },
        info: { _ in }
    )

    static func animation(named name: String) -> LottieAnimation? {
        if let animation = animations[name] { return animation }
        guard let animation = decode(name) else {
            log.fault("The animation \(name, privacy: .public) is missing or malformed")
            return nil
        }
        animations[name] = animation
        return animation
    }

    static func isLoaded(_ name: String) -> Bool {
        animations[name] != nil
    }

    /// This is the frame of the "reduced motion" marker. If the file has no marker, this is its
    /// last frame.
    static func stillFrame(of animation: LottieAnimation) -> AnimationFrameTime {
        animation.frameTime(forMarker: Constants.Animations.stillMarker) ?? animation.endFrame
    }

    static func preload() async {
        let names = Constants.Animations.all.filter { animations[$0] == nil }
        let decoded = await Task.detached(priority: .utility) {
            names.compactMap { name in decode(name).map { (name, $0) } }
        }.value
        for (name, animation) in decoded where animations[name] == nil {
            animations[name] = animation
        }
    }

    nonisolated private static func decode(_ name: String) -> LottieAnimation? {
        LottieAnimation.named(name, bundle: .main, animationCache: nil)
    }
}

import AppKit
import Lottie
import Metal
import QuartzCore
import SwiftUI
import XCTest
@testable import ClipDeck

/// scripts/make-animations.py generates the animations. These tests load them from the app bundle,
/// render frames, and drive `DeckAnimationSurface`. They catch malformed files, paths that draw
/// nothing, and files the Core Animation engine cannot play. They also catch surfaces that keep
/// layers or animations they should have released.
@MainActor
final class AnimationTests: XCTestCase {
    private let bundle = Bundle(for: ClipStore.self)

    private func animation(_ name: String) throws -> LottieAnimation {
        try XCTUnwrap(DeckAnimationLibrary.animation(named: name), "\(name).json did not load")
    }

    private func stillProgress(_ animation: LottieAnimation) throws -> CGFloat {
        try XCTUnwrap(animation.progressTime(forMarker: Constants.Animations.stillMarker), "the still marker is missing")
    }

    // MARK: Rendering helpers

    /// Returns the alpha of each pixel in one frame that the main thread engine draws. The rows run
    /// from the top.
    private func alpha(_ animation: LottieAnimation, progress: CGFloat) throws -> [[UInt8]] {
        let view = LottieAnimationView(animation: animation, configuration: LottieConfiguration(renderingEngine: .mainThread))
        view.frame = NSRect(x: 0, y: 0, width: animation.size.width, height: animation.size.height)
        view.currentProgress = progress
        view.layoutSubtreeIfNeeded()
        view.layer?.layoutIfNeeded()

        let width = Int(animation.size.width), height = Int(animation.size.height)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // The view is flipped, so its layer draws with the origin at the top left.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        view.layer?.render(in: context)
        let data = try XCTUnwrap(context.data)
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        return (0..<height).map { y in (0..<width).map { x in bytes[y * context.bytesPerRow + x * 4 + 3] } }
    }

    private func painted(_ rows: [[UInt8]]) -> Int {
        rows.reduce(0) { $0 + $1.filter { $0 > 0 }.count }
    }

    private func painted(_ rows: [[UInt8]], in rect: CGRect) -> Int {
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) where rows[y][x] > 0 {
                count += 1
            }
        }
        return count
    }

    private func paintedPixels(_ animation: LottieAnimation, progress: CGFloat) throws -> Int {
        painted(try alpha(animation, progress: progress))
    }

    /// The smallest rectangle around every pixel that is more than half covered.
    private func inkBounds(_ rows: [[UInt8]]) -> CGRect {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for (y, row) in rows.enumerated() {
            for (x, value) in row.enumerated() where value > 127 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func allLayers(_ layer: CALayer) -> [CALayer] {
        [layer] + (layer.sublayers ?? []).flatMap(allLayers)
    }

    /// Runs the display pass for Core Animation's next commit. During this pass, the Core Animation
    /// engine builds its animations and reports a file it cannot play.
    private func display(_ layer: CALayer?) {
        guard let layer else { return }
        for layer in allLayers(layer) { layer.displayIfNeeded() }
    }

    private func animationCount(_ layer: CALayer?) -> Int {
        guard let layer else { return 0 }
        return allLayers(layer).reduce(0) { $0 + ($1.animationKeys()?.count ?? 0) }
    }

    /// This returns the surface pixels as the render server draws them. `CARenderer` does the
    /// drawing here. The result is rows of BGRA bytes from the top.
    private func renderedPixels(of surface: DeckAnimationSurface, side: Int) throws -> [[UInt8]] {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device to render with") }
        let layer = try XCTUnwrap(surface.layer)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        // The renderer and the read back use one queue, so the read back waits for the frame.
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue: queue])
        renderer.layer = layer
        renderer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        CATransaction.flush()
        display(layer)
        CATransaction.flush()
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        renderer.layer = nil

        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(commands.makeBlitCommandEncoder())
        blit.synchronize(resource: texture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        texture.getBytes(&bytes, bytesPerRow: side * 4, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        // The renderer's origin is at the bottom left, so its first row is the bottom one.
        return (0..<side).map { row in Array(bytes[((side - 1 - row) * side * 4)..<((side - row) * side * 4)]) }
    }

    private func surface(_ name: String, side: CGFloat = 72) -> DeckAnimationSurface {
        let surface = DeckAnimationSurface(name: name)
        surface.frame = NSRect(x: 0, y: 0, width: side, height: side)
        surface.layoutSubtreeIfNeeded()
        return surface
    }

    /// The window is never ordered in. A layer needs a window for Core Animation to run its
    /// animations and call their delegates.
    private func offscreenWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 72, height: 72), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.close() }
        return window
    }

    // MARK: The files

    func testEveryBundledAnimationHasAConstant() throws {
        let urls = try XCTUnwrap(bundle.urls(forResourcesWithExtension: "json", subdirectory: nil))
        let files = Set(urls.map { $0.deletingPathExtension().lastPathComponent })
        XCTAssertEqual(files, Set(Constants.Animations.all))
        XCTAssertEqual(Constants.Animations.granted, Constants.Animations.copied, "the granted mark reuses the done mark")
    }

    func testEveryAnimationLoadsWithTheExpectedShape() throws {
        let expected: [(name: String, side: CGFloat, frames: CGFloat, still: CGFloat)] = [
            (Constants.Animations.paperclip, 120, 175, 70),
            (Constants.Animations.copied, 60, 60, 46),
            (Constants.Animations.noResults, 120, 40, 40),
        ]
        XCTAssertEqual(expected.map(\.name), Constants.Animations.all)
        for file in expected {
            let animation = try animation(file.name)
            XCTAssertEqual(animation.size, CGSize(width: file.side, height: file.side), file.name)
            XCTAssertEqual(animation.framerate, 60, file.name)
            XCTAssertEqual(animation.startFrame, 0, file.name)
            XCTAssertEqual(animation.endFrame, file.frames, file.name)
            XCTAssertEqual(animation.duration, Double(file.frames) / 60, accuracy: 0.001, file.name)
            XCTAssertEqual(animation.markerNames, [Constants.Animations.stillMarker], file.name)
            XCTAssertEqual(DeckAnimationLibrary.stillFrame(of: animation), file.still, file.name)
        }
    }

    func testEveryStillFrameIsACompleteDrawingInsideItsCanvas() throws {
        for name in Constants.Animations.all {
            let animation = try animation(name)
            let rows = try alpha(animation, progress: stillProgress(animation))
            let ink = inkBounds(rows)
            XCTAssertFalse(ink.isNull, "\(name) shows nothing when nothing may move")
            let canvas = CGRect(origin: .zero, size: animation.size)
            XCTAssertTrue(canvas.insetBy(dx: 2, dy: 2).contains(ink), "\(name) touches the edge of its canvas: \(ink)")
            XCTAssertEqual(ink.midX, canvas.midX, accuracy: animation.size.width * 0.05, "\(name) is off center")
            XCTAssertEqual(ink.midY, canvas.midY, accuracy: animation.size.height * 0.05, "\(name) is off center")
            let most = try (0...10).map { try paintedPixels(animation, progress: CGFloat($0) / 10) }.max() ?? 0
            XCTAssertGreaterThanOrEqual(painted(rows), most * 95 / 100, "\(name) has a fuller frame than its still frame")
        }
    }

    func testThePaperclipDrawsOnThenUnwinds() throws {
        let clip = try animation(Constants.Animations.paperclip)
        let start = try paintedPixels(clip, progress: 0)
        let half = try paintedPixels(clip, progress: 0.2)
        let drawn = try paintedPixels(clip, progress: 0.5)
        let end = try paintedPixels(clip, progress: 1)
        XCTAssertEqual(start, 0, "nothing is drawn before the trim opens")
        XCTAssertGreaterThan(half, 0)
        XCTAssertGreaterThan(drawn, half, "the wire keeps growing until the hold")
        XCTAssertEqual(end, 0, "the wire has unwound by the end of the loop")
        XCTAssertEqual(try paintedPixels(clip, progress: stillProgress(clip)), drawn, "the still frame is the whole wire")
    }

    func testTheCheckAppearsAfterTheRing() throws {
        let copied = try animation(Constants.Animations.copied)
        let ringOnly = try paintedPixels(copied, progress: 0.2)
        let complete = try paintedPixels(copied, progress: 1)
        XCTAssertEqual(try paintedPixels(copied, progress: 0), 0)
        XCTAssertGreaterThan(ringOnly, 0, "the ring is drawing by a fifth of the way in")
        XCTAssertGreaterThan(complete, ringOnly, "the check adds to the ring")
        XCTAssertEqual(try paintedPixels(copied, progress: stillProgress(copied)), complete, "a one-shot stops on the finished mark")
    }

    func testTheGlassDrawsItsLensThenItsHandle() throws {
        let glass = try animation(Constants.Animations.noResults)
        let handle = CGRect(x: 76, y: 76, width: 44, height: 44)
        let lens = CGRect(x: 20, y: 20, width: 56, height: 56)

        XCTAssertEqual(try paintedPixels(glass, progress: 0), 0, "nothing is drawn before the trim opens")
        let early = try alpha(glass, progress: 0.25)
        XCTAssertGreaterThan(painted(early, in: lens), 0, "the lens starts first")
        XCTAssertEqual(painted(early, in: handle), 0, "the handle waits for the lens")

        let done = try alpha(glass, progress: 1)
        XCTAssertGreaterThan(painted(done, in: lens), painted(early, in: lens))
        XCTAssertGreaterThan(painted(done, in: handle), 0, "the handle runs out to the lower right")
        XCTAssertEqual(done[52][52], 0, "the lens is open in the middle")
        XCTAssertEqual(try stillProgress(glass), 1, "the last frame is the still frame")
    }

    // MARK: The engine

    func testEveryAnimationPlaysOnTheCoreAnimationEngine() throws {
        for name in Constants.Animations.all {
            var complaints: [String] = []
            let logger = LottieLogger(
                assert: { condition, message, _, _ in if !condition() { complaints.append(message()) } },
                assertionFailure: { message, _, _ in complaints.append(message()) },
                warn: { message, _, _ in complaints.append(message()) },
                info: { _ in }
            )
            // When the automatic engine cannot play a file, Lottie moves the file to the main
            // thread engine.
            let player = LottieAnimationLayer(
                animation: try animation(name), configuration: LottieConfiguration(renderingEngine: .automatic), logger: logger
            )
            player.setValueProvider(
                ColorValueProvider(LottieColor(r: 1, g: 0, b: 0, a: 1)), keypath: AnimationKeypath(keypath: "**.Stroke 1.Color")
            )
            player.play(fromProgress: 0, toProgress: 1, loopMode: .loop)
            display(player)
            XCTAssertEqual(player.currentRenderingEngine, .coreAnimation, "\(name) fell back while playing")
            XCTAssertGreaterThan(animationCount(player), 0, "\(name) set up no animations")

            player.currentFrame = DeckAnimationLibrary.stillFrame(of: try animation(name))
            display(player)
            XCTAssertEqual(player.currentRenderingEngine, .coreAnimation, "\(name) fell back while paused")
            XCTAssertEqual(complaints, [], name)
        }
        XCTAssertEqual(DeckAnimationLibrary.configuration.renderingEngine, .coreAnimation, "the app never uses the main thread engine")
    }

    func testTheLibraryDecodesEachFileOnce() async throws {
        await DeckAnimationLibrary.preload()
        for name in Constants.Animations.all {
            XCTAssertTrue(DeckAnimationLibrary.isLoaded(name), name)
            XCTAssertTrue(try animation(name) === animation(name), "\(name) was decoded twice")
        }
        XCTAssertNil(DeckAnimationLibrary.animation(named: "no-such-animation"))
    }

    // MARK: DeckAnimation

    func testPlaybackFollowsActivityAndReduceMotion() {
        func playback(loops: Bool = false, active: Bool = true, reduce: Bool = false, still: Bool = false) -> DeckAnimationSurface.Playback {
            DeckAnimation.playback(loops: loops, isActive: active, reduceMotion: reduce, stillOnly: still)
        }
        XCTAssertEqual(playback(), .once)
        XCTAssertEqual(playback(loops: true), .loop)
        XCTAssertEqual(playback(reduce: true), .still, "Reduce Motion shows the still frame")
        XCTAssertEqual(playback(loops: true, reduce: true), .still)
        XCTAssertEqual(playback(still: true), .still)
        XCTAssertEqual(playback(active: false), .idle, "nothing plays off screen")
        XCTAssertEqual(playback(loops: true, active: false), .idle)
        XCTAssertEqual(playback(loops: true, active: false, reduce: true), .idle)
        XCTAssertEqual(playback(active: false, still: true), .idle)
    }

    func testAnIdleSurfaceBuildsNothing() {
        let surface = surface(Constants.Animations.paperclip)
        XCTAssertEqual(surface.playback, .idle)
        XCTAssertNil(surface.player)
        XCTAssertEqual(surface.layer?.sublayers?.count ?? 0, 0)
        XCTAssertFalse(surface.isAccessibilityElement(), "the drawing is decorative")
        XCTAssertNil(surface.hitTest(NSPoint(x: 10, y: 10)), "clicks pass through")
    }

    func testALoopIsReleasedWhenItsSurfaceGoesIdle() throws {
        let surface = surface(Constants.Animations.paperclip)
        surface.setPlayback(.loop)
        display(surface.layer)
        let player = try XCTUnwrap(surface.player)
        XCTAssertTrue(player.isAnimationPlaying)
        XCTAssertEqual(player.loopMode, .loop)
        XCTAssertEqual(player.currentRenderingEngine, .coreAnimation)
        XCTAssertGreaterThan(animationCount(surface.layer), 0)

        surface.setPlayback(.idle)
        XCTAssertNil(surface.player, "a hidden loop keeps no layers")
        XCTAssertEqual(surface.layer?.sublayers?.count ?? 0, 0)
        XCTAssertEqual(animationCount(surface.layer), 0, "a hidden loop keeps no animations")

        surface.setPlayback(.loop)
        display(surface.layer)
        XCTAssertEqual(surface.player?.isAnimationPlaying, true, "it plays again when the surface comes back")
    }

    func testAOneShotStopsOnItsStillFrameAndKeepsItWhenIdle() throws {
        let surface = surface(Constants.Animations.copied, side: 28)
        let cutShort = expectation(description: "a one-shot cut short still reports its end")
        surface.onFinished = { cutShort.fulfill() }
        surface.setPlayback(.once)
        display(surface.layer)
        let player = try XCTUnwrap(surface.player)
        XCTAssertTrue(player.isAnimationPlaying)
        XCTAssertEqual(player.loopMode, .playOnce)

        surface.setPlayback(.idle)
        display(surface.layer)
        XCTAssertTrue(surface.player === player, "the finished mark stays while its surface fades out")
        XCTAssertFalse(player.isAnimationPlaying)
        XCTAssertEqual(player.currentFrame, 46, "an interrupted one-shot jumps to its still frame")
        wait(for: [cutShort], timeout: 1)
        surface.onFinished = nil

        surface.setPlayback(.once)
        display(surface.layer)
        XCTAssertTrue(player.isAnimationPlaying, "each activation plays it again")
    }

    func testTheStillFrameDoesNotMove() throws {
        for name in Constants.Animations.all {
            let surface = surface(name)
            surface.setPlayback(.still)
            display(surface.layer)
            let player = try XCTUnwrap(surface.player)
            XCTAssertFalse(player.isAnimationPlaying, name)
            XCTAssertEqual(player.currentFrame, DeckAnimationLibrary.stillFrame(of: try animation(name)), name)
            XCTAssertEqual(player.currentRenderingEngine, .coreAnimation, name)
        }
    }

    func testTheSurfaceFitsTheFrameItIsGiven() throws {
        let surface = surface(Constants.Animations.paperclip, side: 72)
        XCTAssertEqual(surface.canvasSize, CGSize(width: 120, height: 120))
        XCTAssertEqual(surface.fittingSize(width: 72, height: 72), CGSize(width: 72, height: 72))
        XCTAssertEqual(surface.fittingSize(width: nil, height: nil), CGSize(width: 120, height: 120), "the canvas size when left open")
        XCTAssertEqual(surface.fittingSize(width: .infinity, height: 40), CGSize(width: 120, height: 40))

        surface.setPlayback(.still)
        let content = try XCTUnwrap(surface.player?.animationLayer)
        XCTAssertEqual(content.position, CGPoint(x: 36, y: 36))
        XCTAssertEqual(content.affineTransform().a, 0.6, accuracy: 0.0001)
        XCTAssertEqual(content.affineTransform().d, 0.6, accuracy: 0.0001)

        surface.frame = NSRect(x: 0, y: 0, width: 240, height: 120)
        surface.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.position, CGPoint(x: 120, y: 60), "centered in a frame of another shape")
        XCTAssertEqual(content.affineTransform().a, 1, accuracy: 0.0001, "scaled to fit, never stretched")

        let hosted = NSHostingView(rootView: DeckAnimation(name: Constants.Animations.copied).frame(width: 28, height: 28))
        XCTAssertEqual(hosted.fittingSize, CGSize(width: 28, height: 28), "a call site only sets a frame")
    }

    func testANewNameReplacesTheDrawingAndKeepsThePlayback() throws {
        let surface = surface(Constants.Animations.paperclip)
        surface.setPlayback(.still)
        let first = try XCTUnwrap(surface.player)
        surface.setAnimation(named: Constants.Animations.paperclip)
        XCTAssertTrue(surface.player === first, "the same name changes nothing")

        surface.setAnimation(named: Constants.Animations.copied)
        let second = try XCTUnwrap(surface.player)
        XCTAssertFalse(second === first)
        XCTAssertEqual(surface.canvasSize, CGSize(width: 60, height: 60))
        XCTAssertEqual(surface.playback, .still)
        XCTAssertEqual(second.currentFrame, 46)
        XCTAssertEqual(surface.layer?.sublayers?.count, 1, "the old drawing is gone")
    }

    func testTheDefaultTintIsTheSystemAccent() throws {
        let surface = surface(Constants.Animations.copied)
        surface.setPlayback(.still)
        let provider = try XCTUnwrap(surface.player?.valueProviders.values.first as? ColorValueProvider)
        var accent: NSColor?
        surface.effectiveAppearance.performAsCurrentDrawingAppearance {
            accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        }
        let expected = try XCTUnwrap(accent)
        XCTAssertEqual(provider.color.r, Double(expected.redComponent), accuracy: 0.01)
        XCTAssertEqual(provider.color.g, Double(expected.greenComponent), accuracy: 0.01)
        XCTAssertEqual(provider.color.b, Double(expected.blueComponent), accuracy: 0.01)
        XCTAssertEqual(provider.color.a, 1, accuracy: 0.01)
    }

    func testTheTintReachesLottieOnlyWhenItChanges() throws {
        let surface = surface(Constants.Animations.copied)
        surface.setTint(Color(.sRGB, red: 1, green: 0, blue: 0))
        XCTAssertNil(surface.player, "a tint alone builds nothing")
        surface.setPlayback(.still)
        let player = try XCTUnwrap(surface.player)

        func provider() throws -> ColorValueProvider {
            XCTAssertEqual(player.valueProviders.count, 1)
            return try XCTUnwrap(player.valueProviders.values.first as? ColorValueProvider)
        }
        let red = try provider()
        XCTAssertEqual(red.color.r, 1, accuracy: 0.01)
        XCTAssertEqual(red.color.g, 0, accuracy: 0.01)
        XCTAssertEqual(red.color.b, 0, accuracy: 0.01)

        surface.setTint(Color(.sRGB, red: 1, green: 0, blue: 0))
        surface.viewDidChangeEffectiveAppearance()
        XCTAssertTrue(try provider() === red, "the same color does not rebuild the animations")

        surface.setTint(Color(.sRGB, red: 0, green: 0, blue: 1))
        let blue = try provider()
        XCTAssertFalse(blue === red)
        XCTAssertEqual(blue.color.b, 1, accuracy: 0.01)
        XCTAssertEqual(blue.color.r, 0, accuracy: 0.01)
    }

    func testTheRenderServerDrawsTheStillFrameInTheTint() throws {
        let side = 120
        for name in Constants.Animations.all {
            let surface = surface(name, side: CGFloat(side))
            surface.setTint(Color(.sRGB, red: 0, green: 0, blue: 1))
            XCTAssertEqual(try renderedPixels(of: surface, side: side).joined().filter { $0 > 0 }.count, 0, "an idle surface draws nothing")

            surface.setPlayback(.still)
            let rows = try renderedPixels(of: surface, side: side)
            let alpha = rows.map { row in stride(from: 3, to: row.count, by: 4).map { row[$0] } }
            let ink = inkBounds(alpha)
            XCTAssertFalse(ink.isNull, "\(name) draws nothing on the Core Animation engine")
            XCTAssertEqual(ink.midX, CGFloat(side) / 2, accuracy: CGFloat(side) * 0.05, name)
            XCTAssertEqual(ink.midY, CGFloat(side) / 2, accuracy: CGFloat(side) * 0.05, name)

            var solid = 0, blue = 0
            for row in rows {
                for pixel in stride(from: 0, to: row.count, by: 4) where row[pixel + 3] == 255 {
                    solid += 1
                    if row[pixel] > 200, row[pixel + 1] < 60, row[pixel + 2] < 60 { blue += 1 }
                }
            }
            XCTAssertGreaterThan(solid, 0, name)
            XCTAssertEqual(blue, solid, "\(name) is not drawn in the tint")

            if name == Constants.Animations.noResults {
                XCTAssertGreaterThan(painted(alpha, in: CGRect(x: 84, y: 84, width: 36, height: 36)), 0, "the handle is at the lower right")
                XCTAssertEqual(painted(alpha, in: CGRect(x: 84, y: 0, width: 36, height: 36)), 0, "the glass is drawn upside down")
            }
        }
    }

    func testAOneShotReportsItsEndAndSurvivesLeavingTheWindow() throws {
        let window = offscreenWindow()
        let surface = surface(Constants.Animations.noResults)
        window.contentView?.addSubview(surface)
        let finished = expectation(description: "the one-shot reached its still frame")
        surface.onFinished = { finished.fulfill() }
        surface.setPlayback(.once)
        window.displayIfNeeded()
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(surface.player?.isAnimationPlaying, false)

        surface.removeFromSuperview()
        XCTAssertNil(surface.player, "a surface outside a window keeps no layers")
        XCTAssertEqual(surface.playback, .once)

        surface.onFinished = { XCTFail("a finished one-shot does not report again") }
        window.contentView?.addSubview(surface)
        let player = try XCTUnwrap(surface.player)
        XCTAssertFalse(player.isAnimationPlaying, "a finished one-shot comes back as its still frame")
        XCTAssertEqual(player.currentFrame, 40)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    func testALoopComesBackWhenItsSurfaceReturnsToAWindow() throws {
        let window = offscreenWindow()
        let surface = surface(Constants.Animations.paperclip)
        window.contentView?.addSubview(surface)
        surface.setPlayback(.loop)
        window.displayIfNeeded()
        XCTAssertEqual(surface.player?.isAnimationPlaying, true)

        surface.removeFromSuperview()
        XCTAssertNil(surface.player)
        window.contentView?.addSubview(surface)
        window.displayIfNeeded()
        XCTAssertEqual(surface.player?.isAnimationPlaying, true)
        XCTAssertEqual(surface.playback, .loop)
    }

    func testTheStillFrameReportsTheEndOfAOneShotAtOnce() {
        let surface = surface(Constants.Animations.copied)
        let finished = expectation(description: "Reduce Motion ends a one-shot right away")
        surface.onFinished = { finished.fulfill() }
        surface.setPlayback(.still)
        wait(for: [finished], timeout: 1)

        surface.onFinished = { XCTFail("the still frame reports once") }
        surface.setPlayback(.idle)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}

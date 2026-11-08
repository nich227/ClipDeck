import AppKit
import Lottie
import XCTest
@testable import ClipDeck

/// scripts/make-animations.py generates the animations. The tests load them from the app bundle and
/// render frames. They catch malformed files and paths that draw nothing.
final class AnimationTests: XCTestCase {
    private func animation(_ name: String) throws -> LottieAnimation {
        try XCTUnwrap(LottieAnimation.named(name, bundle: Bundle(for: ClipStore.self)), "\(name).json did not load")
    }

    /// Renders one frame with the main thread engine and counts the pixels that the engine touched.
    private func paintedPixels(_ animation: LottieAnimation, progress: CGFloat) throws -> Int {
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
        view.layer?.render(in: context)
        let data = try XCTUnwrap(context.data)
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        var painted = 0
        for y in 0..<height {
            for x in 0..<width where bytes[y * context.bytesPerRow + x * 4 + 3] > 0 {
                painted += 1
            }
        }
        return painted
    }

    func testBothAnimationsLoadWithTheExpectedShape() throws {
        let clip = try animation(Constants.Animations.paperclip)
        XCTAssertEqual(clip.size, CGSize(width: 120, height: 120))
        XCTAssertGreaterThan(clip.duration, 2)
        let copied = try animation(Constants.Animations.copied)
        XCTAssertEqual(copied.size, CGSize(width: 60, height: 60))
        XCTAssertEqual(copied.duration, 1, accuracy: 0.01)
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
    }

    func testTheCheckAppearsAfterTheRing() throws {
        let copied = try animation(Constants.Animations.copied)
        let ringOnly = try paintedPixels(copied, progress: 0.2)
        let complete = try paintedPixels(copied, progress: 1)
        XCTAssertGreaterThan(ringOnly, 0, "the ring is drawing by a fifth of the way in")
        XCTAssertGreaterThan(complete, ringOnly, "the check adds to the ring")
    }
}

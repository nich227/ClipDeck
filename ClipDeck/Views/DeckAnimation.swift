import Lottie
import SwiftUI

/// The bundled Lottie animation has one tint color. It plays only while `isActive`, so it does not
/// run in a hidden panel. With Reduce Motion on, it shows its final frame.
struct DeckAnimation: View {
    let name: String
    var loops = false
    var isActive = true
    var tint: Color = Palette.accent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LottieView(animation: .named(name))
            .playbackMode(playbackMode)
            .valueProvider(ColorValueProvider(lottieTint), for: AnimationKeypath(keypath: "**.Stroke 1.Color"))
            .configure { $0.contentMode = .scaleAspectFit }
            .resizable()
            .accessibilityHidden(true)
    }

    private var playbackMode: LottiePlaybackMode {
        guard isActive, !reduceMotion else { return .paused(at: .progress(1)) }
        return .playing(.fromProgress(0, toProgress: 1, loopMode: loops ? .loop : .playOnce))
    }

    private var lottieTint: LottieColor {
        let color = NSColor(tint).usingColorSpace(.sRGB) ?? .controlAccentColor
        return LottieColor(
            r: Double(color.redComponent), g: Double(color.greenComponent), b: Double(color.blueComponent),
            a: Double(color.alphaComponent)
        )
    }
}

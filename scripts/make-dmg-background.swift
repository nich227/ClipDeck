// It draws the disk image background: the app's name in the wordmark typeface, the instruction,
// and the footer. It leaves the space for the two icons blank. The image is transparent, and
// Finder paints a white surface behind it in both appearances, so the window is always white.
//
//   swift scripts/make-dmg-background.swift <version> <minimum macOS> <output directory>
//
// It writes background.png and background@2x.png. make-dmg.sh combines them into one TIFF.

import AppKit
import CoreText

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    FileHandle.standardError.write("usage: make-dmg-background.swift <version> <minimum macOS> <output directory>\n".data(using: .utf8)!)
    exit(1)
}
let version = arguments[1]
let minimumSystem = arguments[2]
let outputDirectory = arguments[3]

// make-dmg.sh opens the window. Finder anchors the image at the top left and never scales it. Thus,
// the script draws a canvas larger than the window and places the layout in the visible part.
let windowWidth: CGFloat = 600
let windowHeight: CGFloat = 400
let width: CGFloat = 1000
let height: CGFloat = 760

// Ink for a white window: near black for the name, grays for the rest.
let ink = NSColor(srgbRed: 0x1d / 255, green: 0x1d / 255, blue: 0x1f / 255, alpha: 1)
let inkSoft = NSColor(srgbRed: 0x6e / 255, green: 0x6e / 255, blue: 0x73 / 255, alpha: 1)
let inkFaint = NSColor(srgbRed: 0x8a / 255, green: 0x8a / 255, blue: 0x8e / 255, alpha: 1)

/// The app registers the bundled wordmark face for this process. If the file is missing, the app
/// uses the system serif and still draws the image.
func wordmarkFont(size: CGFloat) -> NSFont {
    let script = URL(fileURLWithPath: arguments[0]).deletingLastPathComponent()
    let candidates = [
        script.appendingPathComponent("../ClipDeck/Resources/Fonts/InstrumentSerif-Regular.ttf").standardizedFileURL,
        URL(fileURLWithPath: "ClipDeck/Resources/Fonts/InstrumentSerif-Regular.ttf"),
    ]
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        if let font = NSFont(name: "InstrumentSerif-Regular", size: size) { return font }
    }
    FileHandle.standardError.write("Instrument Serif not found; using the system serif\n".data(using: .utf8)!)
    let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) ?? NSFont.systemFont(ofSize: size).fontDescriptor
    return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size)
}

func text(
    _ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, tracking: CGFloat = 0, font: NSFont? = nil
) -> NSAttributedString {
    NSAttributedString(string: string, attributes: [
        .font: font ?? NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .kern: tracking,
    ])
}

func draw(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext

    cg.clear(CGRect(x: 0, y: 0, width: width, height: height))

    // The positions belong to the window and are measured from the shared top left corner.
    func down(_ n: CGFloat) -> CGFloat { height - n }

    // The header shows the name in the wordmark face. A small label appears under it.
    let wordmark = text("ClipDeck", size: 36, color: ink, font: wordmarkFont(size: 36))
    wordmark.draw(at: CGPoint(x: 40, y: down(44 + wordmark.size().height)))
    text("CLIPBOARD HISTORY", size: 9, weight: .medium, color: inkFaint, tracking: 1.6)
        .draw(at: CGPoint(x: 41, y: down(98)))

    let instruction = text("To install, drag ClipDeck to the Applications folder.", size: 12, color: inkSoft, tracking: 0.35)
    instruction.draw(at: CGPoint(x: (windowWidth - instruction.size().width) / 2, y: down(290)))

    let footer = text("Version \(version)", size: 10, color: inkFaint, tracking: 0.5)
    footer.draw(at: CGPoint(x: 40, y: down(windowHeight - 44)))
    let requirement = text("Requires macOS \(minimumSystem) or later.", size: 10, color: inkFaint, tracking: 0.5)
    requirement.draw(at: CGPoint(x: windowWidth - 40 - requirement.size().width, y: down(windowHeight - 44)))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to path: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("could not encode \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("  wrote \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
    } catch {
        FileHandle.standardError.write("could not write \(path)\n".data(using: .utf8)!)
        exit(1)
    }
}

write(draw(scale: 1), to: "\(outputDirectory)/background.png")
write(draw(scale: 2), to: "\(outputDirectory)/background@2x.png")

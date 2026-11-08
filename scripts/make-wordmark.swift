// Renders the app's Instrument Serif wordmark as two transparent 2x PNGs for the README header:
// assets/wordmark-light.png in near-black ink and assets/wordmark-dark.png in near-white.
//
//   swift scripts/make-wordmark.swift

import AppKit
import CoreText

let repo = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("..").standardizedFileURL
let fontURL = repo.appendingPathComponent("ClipDeck/Resources/Fonts/InstrumentSerif-Regular.ttf")
guard CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil) || NSFont(name: "InstrumentSerif-Regular", size: 12) != nil,
      let font = NSFont(name: "InstrumentSerif-Regular", size: 64) else {
    FileHandle.standardError.write("could not load \(fontURL.path)\n".data(using: .utf8)!)
    exit(1)
}

func render(ink: NSColor, to path: URL) throws {
    let scale: CGFloat = 2
    let text = NSAttributedString(string: "ClipDeck", attributes: [.font: font, .foregroundColor: ink])
    let size = text.size()
    let padding: CGFloat = 8
    let canvas = NSSize(width: ceil(size.width) + padding * 2, height: ceil(size.height) + padding * 2)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = canvas
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    text.draw(at: NSPoint(x: padding, y: padding))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: path)
    print("  wrote \(path.lastPathComponent) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
}

let assets = repo.appendingPathComponent("assets")
try render(ink: NSColor(srgbRed: 0x0b / 255, green: 0x0b / 255, blue: 0x0c / 255, alpha: 1), to: assets.appendingPathComponent("wordmark-light.png"))
try render(ink: NSColor(srgbRed: 0xf2 / 255, green: 0xf2 / 255, blue: 0xf4 / 255, alpha: 1), to: assets.appendingPathComponent("wordmark-dark.png"))

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ClipDeck

/// The shared builders support pasteboard snapshots and captures.
enum Fixtures {
    static func snapshot(_ items: [[String: Data]]) -> PasteboardSnapshot {
        PasteboardSnapshot(items: items.map { payload in
            PasteboardSnapshot.Item(types: payload.keys.sorted()) { payload[$0] }
        })
    }

    static func classifier(maxTextBytes: Int = Constants.Capture.maxTextBytes) -> PasteboardClassifier {
        PasteboardClassifier(
            maxTextBytes: maxTextBytes,
            makeBookmark: { Data("bookmark:\($0.path)".utf8) },
            fileSize: { _ in 10 }
        )
    }

    static func textCapture(_ text: String, rtf: Data? = nil) -> Capture {
        var payload: [String: Data] = [PasteboardTypes.plainText: Data(text.utf8)]
        if let rtf { payload[PasteboardTypes.rtf] = rtf }
        guard case .capture(let capture) = classifier().classify(snapshot([payload])) else {
            preconditionFailure("text did not classify")
        }
        return capture
    }

    static func fileCapture(_ paths: [String]) -> Capture {
        let items = paths.map { [PasteboardTypes.fileURL: URL(fileURLWithPath: $0).dataRepresentation] }
        guard case .capture(let capture) = classifier().classify(snapshot(items)) else {
            preconditionFailure("files did not classify")
        }
        return capture
    }

    static func imageCapture(width: Int = 4, height: Int = 3) -> Capture {
        guard case .capture(let capture) = classifier().classify(snapshot([[PasteboardTypes.png: png(width: width, height: height)]])) else {
            preconditionFailure("image did not classify")
        }
        return capture
    }

    static func cgImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0, green: 0.83, blue: 0.67, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func png(width: Int, height: Int) -> Data {
        ImageProcessing.pngData(from: cgImage(width: width, height: height))!
    }

    static func tiff(width: Int, height: Int) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage(width: width, height: height), nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipDeckTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

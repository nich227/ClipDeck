import CryptoKit
import Foundation

enum ContentHash {
    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// The value is the lowercase hex SHA-256 hash of a kind tag and the canonical bytes. The tag
    /// keeps a text item and a file item with the same bytes from colliding.
    static func sha256(tag: String, _ data: Data) -> String {
        var hasher = SHA256()
        var tag = tag
        tag.withUTF8 { hasher.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        withUnsafeBytes(of: UInt8(0)) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
        let digest = hasher.finalize()
        return String(unsafeUninitializedCapacity: SHA256.byteCount * 2) { buffer in
            var index = 0
            for byte in digest {
                buffer[index] = hexDigits[Int(byte >> 4)]
                buffer[index + 1] = hexDigits[Int(byte & 0x0F)]
                index += 2
            }
            return index
        }
    }
}

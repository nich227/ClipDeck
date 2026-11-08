import CryptoKit
import Foundation

enum ContentHash {
    /// The value is the lowercase hex SHA-256 hash of a kind tag and the canonical bytes. The tag
    /// keeps a text item and a file item with the same bytes from colliding.
    static func sha256(tag: String, _ data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(tag.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

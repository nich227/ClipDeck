import Foundation

extension Error {
    var advice: String? {
        guard let advice = (self as? LocalizedError)?.recoverySuggestion?
            .trimmingCharacters(in: .whitespacesAndNewlines), !advice.isEmpty else { return nil }
        return advice
    }

    /// The error description is a sentence. If the error gives advice, the advice follows the
    /// description.
    var explanation: String {
        var text = localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = text.last, !".!?".contains(last) { text += "." }
        return advice.map { text + " " + $0 } ?? text
    }
}

import SwiftUI

/// Select a time range and the types of clipboard items to clear. Review how many items match.
/// Confirm the action.
struct ClearHistoryView: View {
    let store: ClipStore
    let onClose: () -> Void

    @State private var range: ClearRange = .lastHour
    @State private var includeText = true
    @State private var includeImages = true
    @State private var includeFiles = true
    @State private var matching: Int?
    @State private var isClearing = false
    @State private var errorMessage: String?

    /// It fits the longest range in the popup and the count line on two lines.
    private static let width: CGFloat = 380

    private var kinds: Set<ClipKind> {
        var kinds: Set<ClipKind> = []
        if includeText { kinds.insert(.text) }
        if includeImages { kinds.insert(.image) }
        if includeFiles { kinds.insert(.file) }
        return kinds
    }

    private var selectionKey: String {
        "\(range.rawValue)|\(kinds.map(\.rawValue).sorted())"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Clear History")
                .deckFont(.title)
                .accessibilityAddTraits(.isHeader)

            Picker("Clear:", selection: $range) {
                ForEach(ClearRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: Space.xs) {
                Toggle(ClipKind.text.label, isOn: $includeText)
                Toggle(ClipKind.image.label, isOn: $includeImages)
                Toggle(ClipKind.file.label, isOn: $includeFiles)
            }
            .toggleStyle(.checkbox)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Kinds of items to clear")

            // The text reserves two lines, so the window keeps its height as the count arrives.
            Text(previewText)
                .deckFont(.label)
                .foregroundStyle(errorMessage == nil ? Palette.textSecondary : Palette.danger)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Clear History", role: .destructive, action: clear)
                    .keyboardShortcut(.defaultAction)
                    .disabled((matching ?? 0) == 0 || isClearing)
            }
        }
        .padding([.horizontal, .bottom], Space.xl)
        .padding(.top, Space.xs)
        .frame(width: Self.width)
        .task(id: selectionKey) { await refreshCount() }
    }

    private var previewText: String {
        if let errorMessage { return errorMessage }
        if kinds.isEmpty { return "Select at least one kind of item." }
        guard let matching else { return "Counting\u{2026}" }
        switch matching {
        case 0: return "No items to clear."
        case 1: return "This will remove 1 item from your history. You can't undo this action."
        default: return "This will remove \(matching.formatted()) items from your history. You can't undo this action."
        }
    }

    private func refreshCount() async {
        matching = nil
        errorMessage = nil
        do {
            matching = try await store.count(matching: ClearRequest(range: range, kinds: kinds))
        } catch {
            errorMessage = "ClipDeck couldn't count the items. \(error.explanation)"
        }
    }

    private func clear() {
        isClearing = true
        let request = ClearRequest(range: range, kinds: kinds)
        Task {
            defer { isClearing = false }
            do {
                try await store.clear(request)
                ThumbnailCache.shared.removeAll()
                NotificationCenter.default.post(name: .clipHistoryDidChange, object: nil)
                onClose()
            } catch {
                errorMessage = "ClipDeck couldn't clear your history. \(error.explanation)"
            }
        }
    }
}

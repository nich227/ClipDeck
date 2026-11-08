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

            Text(previewText)
                .deckFont(.label)
                .foregroundStyle(errorMessage == nil ? Palette.textSecondary : Palette.danger)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Clear History", role: .destructive, action: clear)
                    .keyboardShortcut(.defaultAction)
                    .disabled((matching ?? 0) == 0 || isClearing)
            }
        }
        .padding(Space.xl)
        .frame(width: 380)
        .task(id: selectionKey) { await refreshCount() }
    }

    private var previewText: String {
        if let errorMessage { return errorMessage }
        if kinds.isEmpty { return "Select at least one kind of item." }
        guard let matching else { return "Counting\u{2026}" }
        switch matching {
        case 0: return "No items to clear."
        case 1: return "1 item will be removed from your history. You can't undo this action."
        default: return "\(matching.formatted()) items will be removed from your history. You can't undo this action."
        }
    }

    private func refreshCount() async {
        matching = nil
        errorMessage = nil
        do {
            matching = try await store.count(matching: ClearRequest(range: range, kinds: kinds))
        } catch {
            errorMessage = error.localizedDescription
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
                errorMessage = error.localizedDescription
            }
        }
    }
}

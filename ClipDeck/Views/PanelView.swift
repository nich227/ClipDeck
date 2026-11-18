import SwiftUI

struct PanelView: View {
    @ObservedObject var viewModel: HistoryViewModel
    let onCopy: () -> Void

    @FocusState private var searchFocused: Bool
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Hairline(axis: .horizontal)
            HStack(spacing: 0) {
                listArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Hairline(axis: .vertical)
                PreviewPane(
                    item: viewModel.selectedItem,
                    store: viewModel.store,
                    isActive: viewModel.isVisible,
                    refreshToken: viewModel.refreshToken
                )
                .equatable()
                .frame(width: Constants.Panel.previewWidth)
            }
            Hairline(axis: .horizontal)
            PanelFooter(hasQuery: !viewModel.query.isEmpty)
                .equatable()
        }
        .frame(width: Constants.Panel.width, height: Constants.Panel.height)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : -Space.xs)
        .onChange(of: viewModel.isVisible) { _, visible in
            visible ? reveal() : (appeared = false)
        }
        .onAppear(perform: reveal)
        .onChange(of: viewModel.loadFailed) { _, failed in
            if failed { announceLoadFailure() }
        }
    }

    private func reveal() {
        withAnimation(Anim.allowed(Anim.standard, reduceMotion: reduceMotion)) { appeared = true }
        // The field can receive focus only on the next run loop turn after the panel becomes key.
        DispatchQueue.main.async { searchFocused = true }
    }

    private var searchBar: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Glyph.inline, weight: .regular))
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)
            TextField("Search", text: $viewModel.query)
                .textFieldStyle(.plain)
                .deckFont(.search)
                .foregroundStyle(Palette.textPrimary)
                .focused($searchFocused)
                .accessibilityLabel("Search clipboard history")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    @ViewBuilder
    private var listArea: some View {
        if !viewModel.items.isEmpty {
            HistoryList(
                items: viewModel.items,
                selectedID: viewModel.selectedID,
                selectedIndex: viewModel.selectedIndex,
                refreshToken: viewModel.refreshToken,
                isActive: viewModel.isVisible,
                query: viewModel.query,
                location: viewModel.store.location,
                onSelect: { viewModel.select($0) },
                onCopy: { item in
                    viewModel.select(item)
                    onCopy()
                },
                onRowAppear: { viewModel.loadMoreIfNeeded(after: $0) }
            )
            .equatable()
        } else if viewModel.loadFailed {
            LoadFailedView()
        } else if viewModel.hasLoaded {
            // Any typed text counts as a search here. The search has not run yet for a query one
            // character long. The empty-history state must not flash while the full list loads.
            let query = viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
            EmptyStateView(query: query.isEmpty ? nil : query, isActive: viewModel.isVisible)
        } else {
            // The first page has not loaded yet. An empty state here would flash before it loads.
            Color.clear
        }
    }

    /// Focus stays in the search field, so VoiceOver announces a failed load.
    private func announceLoadFailure() {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        AccessibilityNotification.Announcement("\(LoadFailedView.title). \(LoadFailedView.message)").post()
    }
}

struct Hairline: View {
    let axis: Axis

    var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            .accessibilityHidden(true)
    }
}

/// The key hints appear first. One line then says what copying does. That line gives way first when
/// the panel's text is longer than the English text.
private struct PanelFooter: View, Equatable {
    let hasQuery: Bool

    var body: some View {
        HStack(spacing: Space.md) {
            KeyHint(key: .symbol("return"), label: "Copy", spoken: "Return, copy")
            KeyHint(key: .symbol("arrow.up.arrow.down"), label: "Move", spoken: "Up Arrow or Down Arrow, move")
            KeyHint(key: .text("esc"), label: hasQuery ? "Clear" : "Close", spoken: hasQuery ? "Escape, clear the search" : "Escape, close")
            Spacer(minLength: Space.md)
            Text("Press Return to copy an item, then paste it in any app.")
                .deckFont(.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.xs)
    }
}

private struct KeyHint: View {
    enum Key {
        case symbol(String)
        case text(String)
    }

    let key: Key
    let label: String
    let spoken: String

    var body: some View {
        HStack(spacing: Space.xxs) {
            keyCap
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, Space.xxs)
                .frame(minWidth: Space.lg, minHeight: Space.lg)
                .background(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous).fill(Palette.surface1))
            Text(label)
                .deckFont(.caption)
                .foregroundStyle(Palette.textSecondary)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    @ViewBuilder
    private var keyCap: some View {
        switch key {
        case .symbol(let name):
            Image(systemName: name)
                .deckFont(.caption)
        case .text(let text):
            Text(text)
                .deckFont(.mono)
        }
    }
}

struct EmptyStateView: View {
    /// The value is the search that found nothing, or nil when the history itself is empty.
    let query: String?
    /// The animation runs only while the panel is on screen.
    let isActive: Bool

    private var isSearching: Bool { query != nil }

    var body: some View {
        VStack(spacing: Space.sm) {
            glyph
            Text(query.map { "No Results for \u{201C}\($0)\u{201D}" } ?? "No Items")
                .deckFont(.label)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
            Text(isSearching ? "Check the spelling or try a new search." : "Items you copy will appear here.")
                .deckFont(.caption)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// Each drawing keeps its place while the words beside it change. The glass draws once when a
    /// search first finds nothing and holds through the keystrokes that follow.
    @ViewBuilder
    private var glyph: some View {
        if isSearching {
            DeckAnimation(name: Constants.Animations.noResults, isActive: isActive)
                .frame(width: Glyph.illustration, height: Glyph.illustration)
        } else {
            DeckAnimation(name: Constants.Animations.paperclip, loops: true, isActive: isActive)
                .frame(width: Glyph.illustration, height: Glyph.illustration)
        }
    }
}

/// This stands in for the list when the history could not be read.
struct LoadFailedView: View {
    static let title = "Can't Load History"
    static let message = "Close the panel. Open it again. If the problem continues, quit ClipDeck and reopen it."

    var body: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: Glyph.state, weight: .regular))
                .foregroundStyle(Palette.caution)
                .frame(height: Glyph.illustration)
                .accessibilityHidden(true)
            Text(Self.title)
                .deckFont(.label)
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)
            Text(Self.message)
                .deckFont(.caption)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.title). \(Self.message)")
    }
}

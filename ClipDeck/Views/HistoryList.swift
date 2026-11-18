import SwiftUI

/// Every history row has the same height, so the scroll offset determines which rows are on screen.
/// No row is measured.
enum ListMetrics {
    static let rowHeight = Constants.Panel.rowHeight
    static let spacing = Space.xxs
    static let inset = Space.xs
    static let pitch = rowHeight + spacing

    static func contentHeight(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return 2 * inset + CGFloat(count) * pitch - spacing
    }

    static func top(of index: Int) -> CGFloat {
        inset + CGFloat(index) * pitch
    }

    /// This includes the rows that intersect the viewport, plus `overscan` rows on each side.
    static func window(
        offset: CGFloat, viewport: CGFloat, count: Int, overscan: Int = Constants.Panel.rowOverscan
    ) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let first = Int(((offset - inset) / pitch).rounded(.down))
        let last = Int(((offset + viewport - inset) / pitch).rounded(.down))
        let lower = min(max(first - overscan, 0), count - 1)
        let upper = min(max(last + overscan, lower), count - 1)
        return lower..<(upper + 1)
    }

    /// Returns the scroll offset that shows the whole row with the least movement, or nil when the
    /// row is already in view.
    static func offset(revealing index: Int, from offset: CGFloat, viewport: CGFloat, count: Int) -> CGFloat? {
        guard index >= 0, index < count, viewport > 0 else { return nil }
        let top = top(of: index)
        let bottom = top + rowHeight
        let limit = max(contentHeight(count: count) - viewport, 0)
        if top - inset < offset { return min(max(top - inset, 0), limit) }
        if bottom + inset > offset + viewport { return min(max(bottom + inset - viewport, 0), limit) }
        return nil
    }
}

/// The history list builds only the rows near the viewport. Thus, each selection move or scroll
/// step costs the same for ten items as for ten thousand.
struct HistoryList: View, Equatable {
    let items: [ClipItem]
    let selectedID: Int64?
    let selectedIndex: Int?
    let refreshToken: Int
    let isActive: Bool
    /// The list returns to the top when this changes.
    let query: String
    let location: StoreLocation
    let onSelect: (ClipItem) -> Void
    let onCopy: (ClipItem) -> Void
    let onRowAppear: (ClipItem) -> Void

    /// The list most recently built this range of rows. A scroll step rebuilds the list only when
    /// it changes the range.
    @State private var visible: Range<Int>?
    @State private var position = ScrollPosition(edge: .top)
    @State private var scrollBox = ScrollBox()
    /// A row that scrolls under a pointer at rest gets no hover fill. The selection moved, so the
    /// keyboard is leading, and the fill returns when the pointer moves.
    @State private var hoverSuppressed = false

    /// The closures and location never change for a panel, so they are not part of the comparison.
    nonisolated static func == (lhs: HistoryList, rhs: HistoryList) -> Bool {
        lhs.selectedID == rhs.selectedID && lhs.selectedIndex == rhs.selectedIndex
            && lhs.refreshToken == rhs.refreshToken && lhs.isActive == rhs.isActive && lhs.query == rhs.query
            && lhs.items == rhs.items
    }

    var body: some View {
        let window = currentWindow
        GeometryReader { proxy in
            list(window)
                .onChange(of: proxy.size.height, initial: true) { _, height in
                    scrollBox.snapshot.viewport = height
                    updateWindow()
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("History")
    }

    private func list(_ window: Range<Int>) -> some View {
        ScrollView {
            VStack(spacing: ListMetrics.spacing) {
                ForEach(items[window]) { item in
                    ClipRow(
                        item: item, isSelected: item.id == selectedID, showsHover: !hoverSuppressed,
                        refreshToken: refreshToken, location: location
                    )
                        .equatable()
                        .onTapGesture(count: 2) { onCopy(item) }
                        .simultaneousGesture(TapGesture().onEnded { onSelect(item) })
                        .onAppear { onRowAppear(item) }
                        .accessibilityAction { onCopy(item) }
                }
            }
            .padding(.top, ListMetrics.top(of: window.lowerBound))
            .padding(.horizontal, ListMetrics.inset)
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(height: ListMetrics.contentHeight(count: items.count), alignment: .top)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, offset in
            scrollBox.snapshot.offset = offset
            updateWindow()
        }
        .onContinuousHover { phase in
            if case .active = phase, hoverSuppressed { hoverSuppressed = false }
        }
        .onChange(of: selectedID) { _, _ in
            if !hoverSuppressed { hoverSuppressed = true }
            revealSelection()
            announceSelection()
        }
        .onChange(of: isActive) { _, active in
            if active { scroll(to: 0) }
        }
        .onChange(of: query) { _, _ in scroll(to: 0) }
    }

    /// The window always follows the latest offset and current count, so it stays correct when
    /// items change while the list is scrolled far down.
    private var currentWindow: Range<Int> {
        _ = visible
        return ListMetrics.window(
            offset: scrollBox.snapshot.offset, viewport: scrollBox.snapshot.viewport, count: items.count
        )
    }

    private func revealSelection() {
        guard let selectedIndex,
              let target = ListMetrics.offset(
                  revealing: selectedIndex, from: scrollBox.snapshot.offset, viewport: scrollBox.snapshot.viewport,
                  count: items.count
              ) else { return }
        scroll(to: target)
    }

    private func scroll(to offset: CGFloat) {
        position.scrollTo(y: offset)
        // Two key presses can arrive before the scroll view reports the new offset.
        scrollBox.snapshot.offset = offset
        updateWindow()
    }

    private func updateWindow() {
        let next = ListMetrics.window(
            offset: scrollBox.snapshot.offset, viewport: scrollBox.snapshot.viewport, count: items.count
        )
        if next != visible { visible = next }
    }

    /// Focus stays in the search field while the arrow keys move the selection, so VoiceOver hears
    /// each newly selected row as an announcement.
    private func announceSelection() {
        guard NSWorkspace.shared.isVoiceOverEnabled, let selectedIndex, items.indices.contains(selectedIndex) else { return }
        AccessibilityNotification.Announcement(ItemFormatting.spokenDescription(for: items[selectedIndex])).post()
    }
}

struct ScrollSnapshot: Equatable {
    var offset: CGFloat = 0
    var viewport: CGFloat = Constants.Panel.height
}

/// The latest scroll offset stays outside view state so a scroll step does not rebuild the list.
private final class ScrollBox {
    var snapshot = ScrollSnapshot()
}

struct ClipRow: View, Equatable {
    let item: ClipItem
    let isSelected: Bool
    var showsHover = true
    let refreshToken: Int
    let location: StoreLocation

    @State private var isHovered = false

    nonisolated static func == (lhs: ClipRow, rhs: ClipRow) -> Bool {
        lhs.isSelected == rhs.isSelected && lhs.showsHover == rhs.showsHover && lhs.refreshToken == rhs.refreshToken
            && lhs.item == rhs.item
    }

    var body: some View {
        let subtitle = ItemFormatting.subtitle(for: item)
        HStack(spacing: Space.sm) {
            ThumbnailView(item: item, location: location, side: Constants.Panel.rowThumbnailSide, refreshToken: refreshToken)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(item.title)
                    .deckFont(.body)
                    .foregroundStyle(item.isMissing ? Palette.textSecondary : Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: Space.xxs) {
                    if item.isMissing {
                        Text("Not Found")
                            .foregroundStyle(Palette.caution)
                            .fixedSize()
                    }
                    Text(subtitle.detail)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\u{00B7} \(subtitle.time)")
                        .fixedSize()
                }
                .deckFont(.caption)
                .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.sm)
        .frame(height: ListMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(isSelected ? Palette.surface2 : (isHovered && showsHover ? Palette.surface1 : Palette.clear))
        )
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(Palette.accent)
                    .frame(width: Constants.Panel.selectionBar.width, height: Constants.Panel.selectionBar.height)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ItemFormatting.spokenDescription(for: item, subtitle: subtitle))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Copies this item.")
    }
}

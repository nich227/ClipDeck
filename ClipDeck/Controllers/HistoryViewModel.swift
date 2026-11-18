import Foundation

/// The model holds the list that the panel shows. The list is the history or the results of a
/// debounced full-text search. Either list loads one page at a time.
///
/// The store lists the history and a search in one order, newest copy first. It gives every copy
/// a later date than every earlier copy, so a row that is new or was copied again always comes
/// before every row that was not. The model relies on that order and never sorts rows by date.
///
/// Every reload uses one runner, so at most one first-page read is in flight and at most one more
/// waits behind it. This stays true however many history changes or keystrokes arrive. A history
/// change merges the fresh first page into the loaded rows and publishes only what differs.
@MainActor
final class HistoryViewModel: ObservableObject {
    /// This returns one page of rows for the search text, or one page of the full history when the
    /// text is empty. The rows follow the cursor in newest-first order.
    typealias Fetch = @MainActor (_ text: String, _ cursor: PageCursor?, _ limit: Int) async throws -> [ClipItem]

    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var selectedID: Int64?
    @Published private(set) var isVisible = false
    /// It changes when the panel opens and when a thumbnail is saved while the panel is open, so
    /// rows retry thumbnails that were not ready. A reload alone does not change it.
    @Published private(set) var refreshToken = 0
    /// This tracks whether a load has finished since launch. Until then, an empty list is still
    /// loading and does not mean the history is empty.
    @Published private(set) var hasLoaded = false
    /// The latest load failed. If the first page fails to load, no rows remain because the
    /// displayed rows belonged to another search or another session. If a merge fails, it keeps the
    /// rows that it could not refresh. The next successful load clears the failure.
    @Published private(set) var loadFailed = false
    @Published var query = "" {
        didSet {
            if query != oldValue { scheduleSearch() }
        }
    }

    let store: ClipStore
    private let fetch: Fetch
    /// Selection and paging use each loaded item's position, so they never scan the list. A
    /// position is the stored slot plus `slotBase`. New rows at the top move every row below them
    /// by the same amount, so only `slotBase` and the rows of the first page are written.
    private var slotByID: [Int64: Int] = [:]
    private var slotBase = 0
    /// The model reads this copy of `selectedID`. A published property costs far more to read than
    /// a stored one. Every key press reads the selection.
    private var selection: Int64?
    private var hasMore = true
    private var isLoadingMore = false
    /// The two values are the latest request's search text and the search text associated with the
    /// loaded rows.
    private var requestedText = ""
    private var loadedText = ""
    private var pendingReload: Reload?
    private var reloadRunner: Task<Void, Never>?
    /// It runs while keystrokes are close together and is nil after a pause in typing.
    private var searchTask: Task<Void, Never>?
    private var thumbnailObserver: ObserverToken?

    private enum Reload {
        /// Keep the loaded rows and the selection. Merge the changes.
        case merge
        /// Restart at the first page. Select the first row.
        case reset
    }

    init(store: ClipStore, fetch: Fetch? = nil) {
        self.store = store
        self.fetch = fetch ?? { text, cursor, limit in
            if text.isEmpty { return try await store.page(after: cursor, limit: limit) }
            return try await store.search(text, after: cursor, limit: limit)
        }
        thumbnailObserver = ObserverToken(NotificationCenter.default.addObserver(
            forName: .clipThumbnailDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.thumbnailDidChange() }
        })
    }

    var selectedItem: ClipItem? {
        guard let selection, let index = index(of: selection) else { return nil }
        return items[index]
    }

    /// The list uses the selected row's position in `items`, so it can scroll to the row without a
    /// scan.
    var selectedIndex: Int? {
        selection.flatMap { index(of: $0) }
    }

    private func index(of id: Int64) -> Int? {
        guard let slot = slotByID[id] else { return nil }
        return slot + slotBase
    }

    var isSearching: Bool { !searchText.isEmpty }

    /// This is the text to search for. A single character would match most of the history, so
    /// search starts when the second character is entered. The full list remains visible until
    /// then.
    private var searchText: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= Constants.List.minimumSearchLength ? trimmed : ""
    }

    // MARK: - Panel lifecycle

    func panelWillShow() {
        isVisible = true
        query = ""
        cancelSearch()
        refreshToken += 1
        requestedText = ""
        requestReload(.reset)
    }

    func panelDidHide() {
        isVisible = false
        cancelSearch()
        pendingReload = nil
    }

    func historyDidChange() {
        guard isVisible else { return }
        requestReload(.merge)
    }

    func thumbnailDidChange() {
        guard isVisible else { return }
        refreshToken += 1
    }

    // MARK: - Selection

    func select(_ item: ClipItem) {
        setSelection(item.id)
    }

    func moveSelection(by delta: Int) {
        let rows = items
        guard !rows.isEmpty else { return }
        var current = -1
        if let selection, let index = index(of: selection) { current = index }
        let next = min(max(current + delta, 0), rows.count - 1)
        setSelection(rows[next].id)
        if next >= rows.count - Constants.List.loadMoreThreshold { loadMore() }
    }

    /// Publishing an unchanged selection would still redraw the panel.
    private func setSelection(_ id: Int64?) {
        guard selection != id else { return }
        selection = id
        selectedID = id
    }

    // MARK: - Loading

    func loadMoreIfNeeded(after item: ClipItem) {
        guard hasMore, !isLoadingMore,
              let index = index(of: item.id),
              index >= items.count - Constants.List.loadMoreThreshold else { return }
        loadMore()
    }

    /// A keystroke after a pause starts a search at once. Subsequent keystrokes within the debounce
    /// period trigger one search after the last keystroke.
    private func scheduleSearch() {
        if searchTask == nil { applySearch() }
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Constants.List.searchDebounce)
            guard !Task.isCancelled, let self else { return }
            self.searchTask = nil
            self.applySearch()
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
    }

    /// A keystroke reloads nothing when the search text stays the same, such as for a first
    /// character or a trailing space.
    private func applySearch() {
        let text = searchText
        guard isVisible, text != requestedText else { return }
        requestedText = text
        requestReload(.reset)
    }

    private func requestReload(_ reload: Reload) {
        if reload == .reset || pendingReload == nil { pendingReload = reload }
        guard reloadRunner == nil else { return }
        reloadRunner = Task { [weak self] in await self?.runReloads() }
    }

    private func runReloads() async {
        defer { reloadRunner = nil }
        while isVisible, let reload = pendingReload {
            pendingReload = nil
            let text = requestedText
            let merges = reload == .merge && text == loadedText
            // The store removes its oldest rows to stay under the storage limit, so it would remove
            // the oldest loaded row first. Reading that row with the first page shows whether the
            // rows retained from the previous load are still there.
            let oldest = merges ? items.last : nil
            let beforeOldest = oldest == nil ? nil : items.dropLast().last.map(PageCursor.init(after:))
            do {
                let page: [ClipItem]
                var found: ClipItem?
                if let beforeOldest {
                    async let stored = fetch(text, beforeOldest, 1)
                    page = try await fetch(text, nil, Constants.List.pageSize)
                    found = try await stored.first
                } else {
                    page = try await fetch(text, nil, Constants.List.pageSize)
                }
                // A newer reset replaces this result, and the result is not needed while the panel
                // is hidden.
                guard isVisible, pendingReload != .reset else { continue }
                if merges {
                    merge(page, for: text, oldest: oldest, isStored: found?.id == oldest?.id)
                } else {
                    replace(with: page, for: text, keepSelection: false)
                }
                finishLoad(failed: false)
            } catch {
                Log.panel.error("Could not load history: \(error.localizedDescription)")
                // A newer reset reports its own result, and a hidden panel shows nothing.
                guard isVisible, pendingReload != .reset else { continue }
                if !merges {
                    loadedText = text
                    hasMore = false
                    if !items.isEmpty { setItems([]) }
                    setSelection(nil)
                }
                finishLoad(failed: true)
            }
        }
    }

    /// Publishing an unchanged value would still redraw the panel.
    private func finishLoad(failed: Bool) {
        if loadFailed != failed { loadFailed = failed }
        if !hasLoaded { hasLoaded = true }
    }

    private func replace(with page: [ClipItem], for text: String, keepSelection: Bool) {
        loadedText = text
        hasMore = page.count == Constants.List.pageSize
        if page != items { setItems(page) }
        setSelection(keepSelection ? loadedSelection ?? page.first?.id : page.first?.id)
    }

    /// Returns the selection when its row is still loaded. Otherwise, it returns nil.
    private var loadedSelection: Int64? {
        guard let selection, slotByID[selection] != nil else { return nil }
        return selection
    }

    private func setItems(_ rows: [ClipItem]) {
        items = rows
        slotBase = 0
        slotByID = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Folds a fresh first page into the loaded rows. The page is exact for every row at least as
    /// new as its last row. Rows loaded beyond it stay, except for any rows the page now contains
    /// because they were copied again. A page that is not full contains the whole history. `oldest`
    /// is the last row that was loaded when the page was requested, and `isStored` tells whether
    /// the store still has it.
    private func merge(_ page: [ClipItem], for text: String, oldest: ClipItem?, isStored: Bool) {
        guard page.count == Constants.List.pageSize, let boundary = page.last else {
            replace(with: page, for: text, keepSelection: true)
            return
        }
        let rows = items
        let olderStart = firstIndex(in: rows, after: boundary)
        let movedIDs = Set(page.lazy.map(\.id).filter { (self.index(of: $0) ?? -1) >= olderStart })
        guard rows.count - olderStart > movedIDs.count, let oldest else {
            replace(with: page, for: text, keepSelection: true)
            return
        }
        if movedIDs.contains(oldest.id) {
            // The oldest row is already on the page, so reading it back showed nothing about the
            // remaining rows. The next pass reads back the current oldest row.
            if pendingReload == nil { pendingReload = .merge }
        } else if !isStored {
            replace(with: page, for: text, keepSelection: true)
            return
        }
        if rows.prefix(page.count).elementsEqual(page) { return }

        if movedIDs.isEmpty {
            for item in rows[..<olderStart] { slotByID[item.id] = nil }
            slotBase += page.count - olderStart
            for (position, item) in page.enumerated() { slotByID[item.id] = position - slotBase }
            items.replaceSubrange(..<olderStart, with: page)
        } else {
            setItems(page + rows[olderStart...].filter { !movedIDs.contains($0.id) })
        }
        setSelection(loadedSelection ?? page.first?.id)
    }

    /// Returns the position of the first loaded row that the store lists after `boundary`. The
    /// boundary is the last row of a fresh first page.
    ///
    /// A loaded boundary with the same date has not been copied since, so it marks its own
    /// position. Otherwise, the boundary is new or was copied again. The store lists such a row
    /// before every row that was not copied again. Thus, every loaded row outside the page comes
    /// after the boundary.
    private func firstIndex(in rows: [ClipItem], after boundary: ClipItem) -> Int {
        if let index = index(of: boundary.id), rows[index].lastUsed == boundary.lastUsed { return index + 1 }
        return 0
    }

    /// The next page continues from the last loaded row. It is dropped when that row is no longer
    /// last or the search text changes before the page arrives.
    private func loadMore() {
        guard hasMore, !isLoadingMore, let last = items.last else { return }
        isLoadingMore = true
        let text = loadedText
        Task {
            defer { isLoadingMore = false }
            guard let page = try? await fetch(text, PageCursor(after: last), Constants.List.pageSize),
                  text == loadedText, items.last?.id == last.id else { return }
            let fresh = page.filter { slotByID[$0.id] == nil }
            let count = items.count
            for (offset, item) in fresh.enumerated() {
                slotByID[item.id] = count + offset - slotBase
            }
            items.append(contentsOf: fresh)
            hasMore = page.count == Constants.List.pageSize
        }
    }
}

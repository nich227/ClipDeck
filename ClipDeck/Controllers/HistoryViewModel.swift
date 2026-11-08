import Foundation

/// The panel shows either one page of history at a time or the results of a debounced full-text
/// search.
@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var selectedID: Int64?
    @Published private(set) var isVisible = false
    /// It changes on every reload, so rows retry thumbnails that were still being generated.
    @Published private(set) var refreshToken = 0
    @Published var query = "" {
        didSet {
            if query != oldValue { scheduleSearch() }
        }
    }

    let store: ClipStore
    /// Selection and paging use each loaded item's position, so they never scan the list.
    private var indexByID: [Int64: Int] = [:]
    private var hasMore = true
    private var isLoadingMore = false
    private var generation = 0
    private var searchTask: Task<Void, Never>?

    init(store: ClipStore) {
        self.store = store
    }

    var selectedItem: ClipItem? {
        guard let selectedID, let index = indexByID[selectedID] else { return nil }
        return items[index]
    }

    var isSearching: Bool { !searchText.isEmpty }

    /// Enter the text to search for. A single character would match most of the history, so the
    /// search starts at the second character. The full list appears before then.
    private var searchText: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= Constants.List.minimumSearchLength ? trimmed : ""
    }

    // MARK: - Panel lifecycle

    func panelWillShow() {
        isVisible = true
        query = ""
        searchTask?.cancel()
        Task { await reload(keepSelection: false) }
    }

    func panelDidHide() {
        isVisible = false
        searchTask?.cancel()
    }

    func historyDidChange() {
        guard isVisible else { return }
        Task { await reload(keepSelection: true) }
    }

    // MARK: - Selection

    func select(_ item: ClipItem) {
        selectedID = item.id
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = selectedID.flatMap { indexByID[$0] } ?? -1
        let next = min(max(current + delta, 0), items.count - 1)
        selectedID = items[next].id
        if next >= items.count - Constants.List.loadMoreThreshold { loadMore() }
    }

    // MARK: - Loading

    func loadMoreIfNeeded(after item: ClipItem) {
        guard hasMore, !isLoadingMore,
              let index = indexByID[item.id],
              index >= items.count - Constants.List.loadMoreThreshold else { return }
        loadMore()
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Constants.List.searchDebounce)
            guard !Task.isCancelled else { return }
            await self?.reload(keepSelection: false)
        }
    }

    private func reload(keepSelection: Bool) async {
        generation += 1
        let token = generation
        let text = searchText
        do {
            let page = try await fetch(text: text, after: nil)
            guard token == generation else { return }
            let previous = selectedID
            items = page
            indexByID = Dictionary(page.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            hasMore = page.count == Constants.List.pageSize
            refreshToken += 1
            if keepSelection, let previous, indexByID[previous] != nil {
                selectedID = previous
            } else {
                selectedID = page.first?.id
            }
        } catch {
            Log.panel.error("Could not load history: \(error.localizedDescription)")
        }
    }

    private func loadMore() {
        guard hasMore, !isLoadingMore, let last = items.last else { return }
        isLoadingMore = true
        let token = generation
        let text = searchText
        Task {
            defer { isLoadingMore = false }
            guard let page = try? await fetch(text: text, after: PageCursor(after: last)),
                  token == generation else { return }
            let fresh = page.filter { indexByID[$0.id] == nil }
            for (offset, item) in fresh.enumerated() {
                indexByID[item.id] = items.count + offset
            }
            items.append(contentsOf: fresh)
            hasMore = page.count == Constants.List.pageSize
        }
    }

    /// Both modes use cursor pagination, so a deep page costs about the same as the first.
    private func fetch(text: String, after cursor: PageCursor?) async throws -> [ClipItem] {
        if text.isEmpty { return try await store.page(after: cursor) }
        return try await store.search(text, after: cursor)
    }
}

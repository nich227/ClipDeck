import Foundation
@testable import ClipDeck

/// It forwards reads to the store, counts them, and can hold a kind of read until it is released.
final class FetchRecorder: @unchecked Sendable {
    private struct Failure: Error {}

    private let store: ClipStore
    private let lock = NSLock()
    private var firstPages = 0
    private var nextPages = 0
    private var searchTexts: [String] = []
    private var failing = false
    private var failingEvery = false
    private var heldFirstPages = false
    private var heldNextPages = false
    private var heldSearches = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(store: ClipStore) {
        self.store = store
    }

    var fetch: HistoryViewModel.Fetch {
        { [self] text, cursor, limit in
            let (held, fails) = record(text: text, cursor: cursor, limit: limit)
            if held { await withCheckedContinuation { park($0) } }
            if fails { throw Failure() }
            if text.isEmpty { return try await store.page(after: cursor, limit: limit) }
            return try await store.search(text, after: cursor, limit: limit)
        }
    }

    private func record(text: String, cursor: PageCursor?, limit: Int) -> (held: Bool, fails: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let fails = failing || failingEvery
        failing = false
        if cursor != nil {
            if limit > 1 { nextPages += 1 }
            return (limit > 1 && heldNextPages, fails)
        }
        firstPages += 1
        if !text.isEmpty { searchTexts.append(text) }
        return (text.isEmpty ? heldFirstPages : heldSearches, fails)
    }

    private func park(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        let stillHeld = heldFirstPages || heldNextPages || heldSearches
        if stillHeld { waiters.append(continuation) }
        lock.unlock()
        if !stillHeld { continuation.resume() }
    }

    private func update(_ change: (FetchRecorder) -> Void) {
        lock.lock()
        change(self)
        let resumed = heldFirstPages || heldNextPages || heldSearches ? [] : waiters
        if !(heldFirstPages || heldNextPages || heldSearches) { waiters = [] }
        lock.unlock()
        resumed.forEach { $0.resume() }
    }

    var firstPageReads: Int { lock.lock(); defer { lock.unlock() }; return firstPages }
    var nextPageReads: Int { lock.lock(); defer { lock.unlock() }; return nextPages }
    var searches: [String] { lock.lock(); defer { lock.unlock() }; return searchTexts }

    func reset() { update { $0.firstPages = 0; $0.nextPages = 0; $0.searchTexts = [] } }
    func failNext() { update { $0.failing = true } }
    func failEveryRead(_ fails: Bool) { update { $0.failingEvery = fails } }
    func holdFirstPages() { update { $0.heldFirstPages = true } }
    func releaseFirstPages() { update { $0.heldFirstPages = false } }
    func holdNextPages() { update { $0.heldNextPages = true } }
    func releaseNextPages() { update { $0.heldNextPages = false } }
    func holdSearches() { update { $0.heldSearches = true } }
    func releaseSearches() { update { $0.heldSearches = false } }
}

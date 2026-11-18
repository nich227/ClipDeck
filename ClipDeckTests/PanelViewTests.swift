import AppKit
import SwiftUI
import XCTest
@testable import ClipDeck

/// The panel's list area is hosted the way `PanelController` hosts it, in a window that is never
/// ordered in. A closed panel is in the same state. Its views update, but nothing shows.
@MainActor
final class PanelViewTests: XCTestCase {
    private var directory: URL!
    private var store: ClipStore!
    private var recorder: FetchRecorder!
    private var viewModel: HistoryViewModel!
    private var host: NSHostingView<AnyView>!

    override func setUp() async throws {
        directory = Fixtures.temporaryDirectory()
        store = try ClipStore(location: StoreLocation(root: directory))
        recorder = FetchRecorder(store: store)
        viewModel = HistoryViewModel(store: store, fetch: recorder.fetch)
        hostPanel(reduceMotion: false)
    }

    /// The tests choose Reduce Motion themselves. The machine that runs them may have the system
    /// setting turned on, and every animation would then show its still frame.
    private func hostPanel(reduceMotion: Bool) {
        let panel = PanelView(viewModel: viewModel, onCopy: {}).environment(\.deckReduceMotion, reduceMotion)
        host = NSHostingView(rootView: AnyView(panel))
        host.frame = NSRect(x: 0, y: 0, width: Constants.Panel.width, height: Constants.Panel.height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        addTeardownBlock { @MainActor in window.close() }
    }

    override func tearDown() async throws {
        host = nil
        viewModel = nil
        recorder = nil
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "condition not met in time", file: file, line: line)
    }

    /// Long enough for a pending view update to arrive.
    private func pause() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }

    private var surfaces: [DeckAnimationSurface] {
        func find(in view: NSView) -> [DeckAnimationSurface] {
            (view as? DeckAnimationSurface).map { [$0] } ?? view.subviews.flatMap(find)
        }
        return find(in: host)
    }

    private func surface(_ name: String) -> DeckAnimationSurface? {
        surfaces.first { $0.name == name }
    }

    private func insert(_ text: String) async throws {
        _ = try await store.insert(Fixtures.textCapture(text))
        viewModel.historyDidChange()
    }

    func testNoEmptyStateShowsWhileTheFirstPageIsOnItsWay() async throws {
        recorder.holdFirstPages()
        viewModel.panelWillShow()
        await waitUntil { self.recorder.firstPageReads == 1 }
        try await pause()
        XCTAssertEqual(surfaces.map(\.name), [], "an empty state flashed before the history loaded")

        recorder.releaseFirstPages()
        await waitUntil { self.surface(Constants.Animations.paperclip)?.playback == .loop }
    }

    func testThePaperclipLoopIsReleasedWhenThePanelHides() async throws {
        viewModel.panelWillShow()
        await waitUntil { self.surface(Constants.Animations.paperclip)?.player != nil }
        let paperclip = try XCTUnwrap(surface(Constants.Animations.paperclip))
        XCTAssertEqual(paperclip.playback, .loop)

        viewModel.panelDidHide()
        await waitUntil { paperclip.playback == .idle }
        XCTAssertNil(paperclip.player, "a closed panel keeps no animation layers")
        XCTAssertEqual(paperclip.layer?.sublayers?.count ?? 0, 0)

        viewModel.panelWillShow()
        await waitUntil { paperclip.playback == .loop && paperclip.player != nil }
    }

    func testReduceMotionShowsTheStillFrameWithoutPlaying() async throws {
        hostPanel(reduceMotion: true)
        viewModel.panelWillShow()
        await waitUntil { self.surface(Constants.Animations.paperclip)?.player != nil }
        let paperclip = try XCTUnwrap(surface(Constants.Animations.paperclip))
        XCTAssertEqual(paperclip.playback, .still)
        XCTAssertEqual(paperclip.player?.isAnimationPlaying, false)

        viewModel.query = "zz"
        await waitUntil { self.surface(Constants.Animations.noResults)?.player != nil }
        let glass = try XCTUnwrap(surface(Constants.Animations.noResults))
        XCTAssertEqual(glass.playback, .still)
        XCTAssertEqual(glass.player?.isAnimationPlaying, false)
    }

    func testTheNoResultsGlassDrawsOnceWhileASearchKeepsFindingNothing() async throws {
        try await insert("alpha")
        viewModel.panelWillShow()
        await waitUntil { self.viewModel.items.count == 1 }
        XCTAssertEqual(surfaces.map(\.name), [], "a list with rows draws no animation")

        viewModel.query = "zz"
        await waitUntil { self.surface(Constants.Animations.noResults)?.player != nil }
        let glass = try XCTUnwrap(surface(Constants.Animations.noResults))
        let player = try XCTUnwrap(glass.player)
        XCTAssertEqual(glass.playback, .once)
        host.window?.displayIfNeeded()
        await waitUntil { !player.isAnimationPlaying }

        for text in ["zzz", "zzzz", "zzzz y"] {
            viewModel.query = text
            try await Task.sleep(for: Constants.List.searchDebounce * 2)
            await waitUntil { self.recorder.searches.last == text }
            try await pause()
            XCTAssertTrue(surface(Constants.Animations.noResults) === glass, "the glass was rebuilt for \(text)")
            XCTAssertTrue(glass.player === player)
            XCTAssertFalse(player.isAnimationPlaying, "the glass drew again for \(text)")
        }

        viewModel.panelDidHide()
        await waitUntil { glass.playback == .idle }
        XCTAssertTrue(glass.player === player, "a one-shot keeps its still frame while the panel is closed")
        XCTAssertFalse(player.isAnimationPlaying)
    }

    func testEachListStateLeavesNoAnimationFromTheOneBefore() async throws {
        viewModel.panelWillShow()
        await waitUntil { self.surface(Constants.Animations.paperclip)?.player != nil }
        let paperclip = try XCTUnwrap(surface(Constants.Animations.paperclip))

        // The empty history changes to a search that finds nothing.
        viewModel.query = "zz"
        await waitUntil { self.surface(Constants.Animations.noResults) != nil }
        XCTAssertNil(paperclip.player, "the loop outlived the empty history")
        XCTAssertEqual(surfaces.count, 1)
        let glass = try XCTUnwrap(surface(Constants.Animations.noResults))

        // This returns to the empty history.
        viewModel.query = ""
        await waitUntil { self.surface(Constants.Animations.paperclip)?.playback == .loop }
        XCTAssertNil(glass.player)
        XCTAssertEqual(surfaces.count, 1)
        let second = try XCTUnwrap(surface(Constants.Animations.paperclip))

        // Go to the results.
        try await insert("alpha")
        await waitUntil { self.viewModel.items.count == 1 }
        await waitUntil { self.surfaces.isEmpty }
        XCTAssertNil(second.player, "the loop outlived the empty history")

        // This leads to a failed load.
        recorder.failEveryRead(true)
        viewModel.query = "al"
        await waitUntil { self.viewModel.loadFailed }
        try await pause()
        XCTAssertEqual(surfaces.map(\.name), [], "the error state draws no animation")
    }
}

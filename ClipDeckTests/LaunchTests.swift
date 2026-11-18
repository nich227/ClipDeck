import os
import SQLite3
import XCTest
@testable import ClipDeck

final class LaunchTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = Fixtures.temporaryDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testTheStoreOpensOffTheMainThread() async throws {
        let directory = self.directory!
        let openedOnMain = OSAllocatedUnfairLock(initialState: true)
        let store = try await AppDelegate.openStore {
            openedOnMain.withLock { $0 = Thread.isMainThread }
            return StoreLocation(root: directory)
        }
        XCTAssertFalse(openedOnMain.withLock { $0 }, "a migration at launch must not hold the main thread")
        let count = try await store.count()
        XCTAssertEqual(count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.location.database.path))
    }

    func testADebugBuildCanKeepItsHistoryElsewhere() throws {
        let elsewhere = try AppDelegate.storeLocation(environment: [AppDelegate.storeRootVariable: directory.path])
        XCTAssertEqual(elsewhere.root.path, directory.path)
        XCTAssertEqual(elsewhere.database.path, directory.appendingPathComponent(Constants.databaseFileName).path)

        // Building the default location only names it. Nothing here opens it.
        let standard = try AppDelegate.storeLocation(environment: [:])
        XCTAssertEqual(standard.root.lastPathComponent, Constants.supportDirectoryName)
        XCTAssertEqual(try AppDelegate.storeLocation(environment: [AppDelegate.storeRootVariable: ""]).root, standard.root)
    }

    func testADebugBuildCanWatchAPasteboardOfItsOwn() {
        let name = "ClipDeckTests-\(UUID().uuidString)"
        XCTAssertEqual(AppDelegate.pasteboardName(environment: [AppDelegate.pasteboardVariable: name])?.rawValue, name)
        XCTAssertNil(AppDelegate.pasteboardName(environment: [:]))
        XCTAssertNil(AppDelegate.pasteboardName(environment: [AppDelegate.pasteboardVariable: ""]))
    }

    @MainActor
    func testAStoreThatCannotOpenReportsWhy() async throws {
        let location = StoreLocation(root: directory)
        do {
            let db = try Database(path: location.database.path)
            try db.setUserVersion(ClipStore.schemaVersion + 1)
        }
        do {
            _ = try await AppDelegate.openStore { location }
            XCTFail("a newer history opened")
        } catch {
            XCTAssertEqual(error as? StoreError, .newerSchema(ClipStore.schemaVersion + 1), "the alert names this case")
            XCTAssertEqual(
                AppDelegate.storeErrorExplanation(for: error), error.explanation,
                "the error's own words say to update, and the alert adds nothing to them"
            )
        }
    }

    // MARK: - The alert for a store that cannot open

    private func sqlite(_ code: Int32, _ message: String = "what SQLite said") -> SQLiteError {
        SQLiteError(code: code, message: message)
    }

    private let retry = " Quit ClipDeck. Open it again."
    private let afterAdvice = " Then open ClipDeck again."

    func testAHistoryFromANewerVersionIsExplainedOnce() {
        let error = StoreError.newerSchema(ClipStore.schemaVersion + 1)
        let text = AppDelegate.storeErrorExplanation(for: error)
        XCTAssertEqual(text, "This history was saved by a newer version of ClipDeck. Update ClipDeck to open it.")
        XCTAssertEqual(text, error.explanation, "the store's words are the only wording")
        XCTAssertEqual(AppDelegate.reopening(after: error), .cannotHelp)
        XCTAssertFalse(text.contains("Quit ClipDeck"), "opening the same version again cannot help")
    }

    func testAnErrorWithAdviceEndsWithOpeningAgainAfterIt() throws {
        let withAdvice = [
            SQLITE_FULL, SQLITE_CANTOPEN, SQLITE_PERM, SQLITE_READONLY, SQLITE_AUTH,
            SQLITE_CANTOPEN | (2 << 8), SQLITE_READONLY | (6 << 8),
            SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_CORRUPT | (1 << 8),
        ]
        for code in withAdvice {
            let error = sqlite(code)
            let advice = try XCTUnwrap(error.advice, "code \(code)")
            let text = AppDelegate.storeErrorExplanation(for: error)
            XCTAssertEqual(text, error.localizedDescription + " " + advice + afterAdvice, "code \(code)")
            XCTAssertFalse(text.hasSuffix(retry), "code \(code): opening again alone does not help")
        }
    }

    func testADamagedHistorySaysHowToStartOver() {
        XCTAssertEqual(
            AppDelegate.storeErrorExplanation(for: sqlite(SQLITE_CORRUPT, "database disk image is malformed")),
            "The history database is damaged (SQLite error 11: database disk image is malformed). Quit ClipDeck. "
                + "Move the ClipDeck folder from ~/Library/Application Support to another folder to start with an "
                + "empty history. Then open ClipDeck again."
        )
    }

    func testAnErrorWithoutAdviceSaysToOpenAgain() {
        for code in [SQLITE_BUSY, SQLITE_LOCKED, SQLITE_NOMEM, SQLITE_IOERR, SQLITE_IOERR | (10 << 8), SQLITE_ERROR] {
            let error = sqlite(code)
            XCTAssertNil(error.advice, "code \(code)")
            XCTAssertEqual(AppDelegate.storeErrorExplanation(for: error), error.localizedDescription + retry, "code \(code)")
        }
    }

    func testTheAlertFollowsAdviceExactlyWhereTheErrorGivesIt() {
        for code in Int32(1)...28 {
            let error = sqlite(code, "MARKER")
            let description = error.localizedDescription
            let tail = description.components(separatedBy: "MARKER").last ?? ""
            XCTAssertFalse(tail.contains { $0.isLetter }, "code \(code): the advice is not part of the description")
            XCTAssertEqual(description.last, ".", "code \(code): the alert adds a sentence after this one")
            XCTAssertEqual(
                AppDelegate.reopening(after: error) == .helpsAfterAdvice, error.advice != nil,
                "code \(code): \(description)"
            )
            XCTAssertEqual(error.advice?.last, error.advice == nil ? nil : ".", "code \(code)")
        }
    }

    func testAnyOtherErrorIsASentenceThenOpeningAgain() {
        struct Plain: LocalizedError {
            var errorDescription: String? { "  The folder is missing \n" }
        }
        XCTAssertEqual(AppDelegate.storeErrorExplanation(for: Plain()), "The folder is missing." + retry)

        let posix = POSIXError(.EIO)
        let text = AppDelegate.storeErrorExplanation(for: posix)
        XCTAssertTrue(text.hasSuffix(retry))
        XCTAssertFalse(text.contains(".."))
        XCTAssertFalse(text.contains(". ."))

        for code in [CocoaError.fileWriteNoPermission, .fileReadNoPermission, .fileWriteOutOfSpace, .fileWriteVolumeReadOnly] {
            let error = CocoaError(code)
            let text = AppDelegate.storeErrorExplanation(for: error)
            XCTAssertFalse(text.contains("Quit ClipDeck"), "\(code): opening again does not free space or change a permission")
            XCTAssertEqual(text.trimmingCharacters(in: CharacterSet(charactersIn: ".")), error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        }
        XCTAssertTrue(AppDelegate.storeErrorExplanation(for: CocoaError(.fileReadUnknown)).hasSuffix(retry))
    }

    func testNoExplanationRepeatsASentence() {
        let errors: [Error] = [
            StoreError.newerSchema(9), sqlite(SQLITE_FULL), sqlite(SQLITE_CANTOPEN), sqlite(SQLITE_BUSY), sqlite(SQLITE_CORRUPT),
            sqlite(SQLITE_ERROR), CocoaError(.fileWriteNoPermission), POSIXError(.ENOSPC),
        ]
        for error in errors {
            let text = AppDelegate.storeErrorExplanation(for: error)
            let sentences = text.components(separatedBy: ". ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
            XCTAssertEqual(Set(sentences).count, sentences.count, text)
            XCTAssertFalse(text.contains("please") || text.contains("Please"), text)
            XCTAssertTrue(text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?"), text)
        }
    }
}

# AGENTS.md

ClipDeck: macOS menu bar clipboard history. A global shortcut opens a Liquid Glass panel with search over unlimited history in SQLite. AppKit lifecycle hosting SwiftUI views. Repository: https://github.com/nich227/ClipDeck

## Invariants

1. The SQLite connection is only touched on the store's serial queue. Every public `ClipStore` call goes through `perform`. The one exception is `markCleanShutdown`, which blocks on the queue because the app is quitting.
2. The list never loads the whole table. Browsing pages by `(last_used, id)` cursor. Search uses FTS5 `MATCH` with prefix terms, never `LIKE`, and never sorts: the index is keyed by `items.seq`, a number that every copy raises, so the index lists matches newest copy first and a page reads only the rows it returns. A whole word, or a prefix of 2 or 3 characters (`prefix = '2 3'`), costs O(page). A longer prefix first merges the postings of the terms that start with it. Every copy stores a `last_used` later than every other row's (`ClipStore.copyTime` raises a time that the clock would put earlier), so the list order `(last_used, id)` and the index order `seq` are one order, whatever the clock does. A search cursor resolves to a `seq` bound with one row lookup. A list row reads `preview` (the first `rowPreviewCharacters` of a longer text) and never `search_text`. Query plan tests in `ClipStoreTests` guard this.
3. File items store a path and bookmark only. File bytes are never copied.
4. Blob and thumbnail files are named by item hash. Anything that deletes rows removes exactly those rows' files by hash, O(rows removed), and unlinks only what the row can have: a blob when `blob_type` is set, and a thumbnail when `thumb_size > 0` or the row is an image or a file, because a crash or a build that stops at schema 4 can leave a thumbnail on disk with no size in its row. `saveThumbnail` records the size and moves the file into place in one transaction; a save that fails leaves the row and any thumbnail it already had as they were. Blob and thumbnail bytes are written to `staging/` on the store's file queue and renamed into place on the store queue, so `blobs/` and `thumbs/` hold only complete files and a large write never blocks a read. An insert that fails removes the blob it put in place. Nothing lists `blobs/` or `thumbs/` except `collectGarbage`, and it runs only after an unclean shutdown. `init` empties `staging/`.
5. Schema changes add a new case to `ClipStore.migrate(_:from:)` and bump `schemaVersion`. Never edit an existing step.
6. While the panel is closed, the only timer is the 300 ms pasteboard poll. Every Lottie animation takes `isActive`. When its surface is off screen, a loop releases its layers and a one-shot keeps its still frame. The panel's list area shows one of five states (`PanelView.listArea`): rows, the load-failed state, the empty history (the paperclip loop), no results (the glass, once per search that finds nothing, not once per keystroke), or nothing while the first page is on its way (`hasLoaded` is false). Leaving a state dismantles its animation. `PanelViewTests` hosts the panel and guards this.
7. Return copies; ClipDeck never synthesizes a paste. No Accessibility permission is requested.
8. The main thread never waits on the capture or store queues, except `markCleanShutdown` at quit. The store opens off the main thread (`AppDelegate.openStore`), because opening can migrate the whole history, and the rest of the app starts in `start(with:)` when it is ready. Payload rows load on the store queue; blob bytes and rebuilt TIFF load on the store's file queue. `writeOwn` records the change count the writer's own `clearContents()` returned, under a lock. The main thread also reads no file for a row: `PasteboardWriter.prepare` resolves bookmarks and checks files off the main thread before `write`, and `ThumbnailCache` reads and decodes a thumbnail off the main thread into a plain bitmap, so a draw never decodes.
9. Set panel and HUD text with `deckFont(_:)`. Native controls in Settings and the Clear window are the exception.
10. A repeat copy moves the row to the top and replaces its stored formats, bookmarks, and flags in one transaction. Formats and bookmarks that already equal the new copy's, byte for byte, are left in place. A repeat copy of the newest row keeps its `seq`; any other takes the next `seq`, which moves its search index entry and tokenizes its text once. Text first copied without plain text is written back without it (`offers_plain_text`).
11. `stats.total_bytes` is maintained by the three `items_stats_*` triggers and read with one row lookup. Never compute usage with a directory walk or `sum()` on a hot path. It covers `(kind != file ? byte_size : 0) + thumb_size`; `ClipStore.storedBytesSQL` is the one copy of that expression outside the frozen migration.
12. Eviction is O(k log n) for k rows removed: `oldestSQL` walks `items_recent` backward, `EvictionPlan.select` picks until the excess is freed, one `evictSQL` statement removes the batch, then each row's files by hash. `Constants.Storage.evictionBatch` rows per transaction. Runs inside `insert` and `saveThumbnail` (loop until under budget) and in `setStorageBudget` (one batch per queue hop). The newest row is never evicted.
13. `collectGarbage` is the only O(files) operation. It lists directories off the store queue, checks `Constants.Storage.sweepBatch` names per transaction, records thumbnail sizes never recorded, and recounts. `AppDelegate.openSession` runs it only when `beginSession()` reports the previous session skipped `markCleanShutdown`.
14. The menu bar menu is built in `menuNeedsUpdate`, so nothing is built while it is closed. `recent` refreshes on `clipHistoryDidChange` with one ten-row indexed read. One read is in flight at a time, and every change that arrives during it shares one more read. Row icons are kept between openings, the thumbnail icons only for the rows in the menu. Placeholder icons never touch the disk (`UTType` from the extension, not `icon(forFile:)`). The ten rows carry key equivalents Command-1 to Command-9 and Command-0 (`Constants.Menu.rowKeys`), which the menu renders in gray on the right and honors while open. Open ClipDeck shows the global shortcut as a key equivalent through `applyShortcut`, for display only; Carbon owns the real registration.
15. Glass is AppKit `NSGlassEffectView` wherever a hosted AppKit view (Lottie, `AVPlayerView`) sits on it. SwiftUI `.glassEffect` draws above hosted views and hides them. The panel and the HUD both use `NSGlassEffectView` with the SwiftUI content as `contentView`.
16. Colors come from `Palette` and follow the system: `Color.accentColor`, `.primary`, `.secondary`, `tertiaryLabelColor`, and label-opacity fills. No fixed hue, no forced color scheme.
17. The copy path is `ClipCopier` only. The panel and the menu must not write to the pasteboard themselves. `onCopied` shows the HUD, and `CopyHUDController.show` announces the copy to VoiceOver even when the pill is turned off. Every copy that fails, whether the item cannot be read back or cannot be written, calls `onFailed` (the alert sound and a VoiceOver announcement) and posts `clipHistoryDidChange`, so the lists drop a row that is gone. The panel stays open after a failed copy and closes after a copy that worked.
18. Every drawn animation is a Lottie file played through `DeckAnimation`, on Lottie's Core Animation engine only. `scripts/make-animations.py` generates the files. Edit the script, rerun it, commit both, and list the name in `Constants.Animations.all`. Each file marks its still frame with a `reduced motion` marker. `AnimationTests` renders each file and plays it on the Core Animation engine; the test workflow fails if the JSON drifts from the script. A window or layer that moves or fades into place is not a drawn animation and stays Core Animation or SwiftUI.
19. No force unwraps or `try!` in `ClipDeck/`. Tests may use them.
20. The panel list builds only the rows near the viewport. `ListMetrics.window` picks them from the scroll offset, so every row is exactly `Constants.Panel.rowHeight` tall. `HistoryList`, `ClipRow`, and `PreviewPane` are `Equatable` and compare only their data, so a selection move rebuilds two rows and typing in the search field rebuilds none. Keep closures and the store out of `==`. A selection change turns off the hover fill (`showsHover`) until the pointer moves, so a row that scrolls under a pointer at rest is not highlighted.
21. While the panel is open, every reload goes through one runner in `HistoryViewModel`: at most one first-page read is in flight and one more waits, for any number of history changes or keystrokes. A keystroke after a pause searches at once; keystrokes within `Constants.List.searchDebounce` of each other share one search after the last. A history change merges the fresh first page into the loaded rows, keeps the rows loaded beyond it and the selection, and publishes nothing when no row differs. The merge reads the oldest loaded row back in the same pass, and falls back to the first page when the store evicted it. The history and a search are one order, newest copy first (invariant 2), so a row that is new or was copied again is listed before every row that was not. The merge finds the page's last row among the loaded rows by id (`firstIndex(in:after:)`): a loaded row with the same `lastUsed` marks its own place, and any other last row puts every loaded row the page does not hold after the page. The model never sorts or searches rows by date. A reload does not change `refreshToken`. Only opening the panel and `clipThumbnailDidChange` do, so rows restart their thumbnail tasks only when a thumbnail can have appeared. `refreshToken` says nothing about whether rows loaded: `hasLoaded` does, and `loadFailed` is true while the latest load failed. A failed first page (opening the panel, a search) leaves no rows and no selection; a failed merge keeps the rows it could not refresh.
22. Per-file work for a file selection runs with `DispatchQueue.concurrentPerform`: paths, bookmarks, and sizes in `PasteboardClassifier`, and bookmark resolution in `PasteboardWriter.prepare`. `PasteboardClassifier.makeBookmark` and `fileSize` must be safe to call from several threads. Classifying text costs one pass to decode and one to hash. The title and the empty check stop at the first line, and the hash reads the string's own bytes.
23. Rows leave `items` through `ClipStore.deleteSQL(where:)`, one statement per batch, in `seq` order. Clearing everything empties the index first with `'delete-all'`. FTS5 writes its pending changes to disk whenever a removal arrives out of rowid order or a statement ends, so a per-row or unordered delete costs one flush per row.
24. `search_text` is the last column of `items`, and `seq`, `preview`, and every small column come before it, so reading them never walks a long text's overflow pages. `ALTER TABLE ADD COLUMN` appends after it: a migration that adds a column to `items` rebuilds the table the way the step from version 4 does, and removes by hand the rows that refer to no item, with `foreign_keys` off for that step only.
25. `Database.run`, `query`, and `first` compile each SQL string once per connection and bind text and blobs without copying them. A statement from them is reset before the call returns; never keep one, and never write SQL that differs per call. Use `Database.prepare` for a statement you step yourself. The store uses no `RETURNING`, which builds a temporary table on every run.

## Facts

| | |
|---|---|
| Bundle ID | `com.kevster.clipdeck` (Debug: `com.kevster.clipdeck.debug`) |
| Log subsystem | `com.kevster.clipdeck` |
| Minimum macOS | 26.0 (`MACOSX_DEPLOYMENT_TARGET` in `project.yml`; `Info.plist` reads it) |
| Toolchain | Xcode 26+, Swift 5.9 language mode, XcodeGen |
| Packages (SPM, in `project.yml`) | `Lottie` 4.6.1+, `Sparkle` 2.8+ |
| System frameworks | SQLite (FTS5 with a contentless-delete table, which needs 3.43 or later; `json_each`), CryptoKit, QuickLookThumbnailing, AVKit, Carbon, ServiceManagement |
| Default shortcut | Shift Command C, Carbon `RegisterEventHotKey` |
| Storage | `~/Library/Application Support/ClipDeck/` with `clipdeck.sqlite`, `blobs/<hash>`, `thumbs/<hash>.png`, `staging/` (files being written). A Debug build keeps its store at `CLIPDECK_STORE_ROOT` and watches and writes the pasteboard named by `CLIPDECK_PASTEBOARD` when those variables are set (`AppDelegate.storeLocation`, `AppDelegate.pasteboardName`); Release ignores both |
| Schema version | 5. A build made before the first release stops at 4 and refuses a newer database, so a store that 5 has opened cannot go back to it |
| Connection | WAL, `synchronous = NORMAL`, `wal_autocheckpoint = Constants.Storage.checkpointPages`, `journal_size_limit = Constants.Storage.logSizeLimit` (the system SQLite defaults to 32 KB, which truncates the log at every checkpoint). Three checkpoints run outside the automatic ones: `init` truncates the log after a migration (`wal_checkpoint(TRUNCATE)` when the version on disk was below `schemaVersion`), because a step that rebuilds the history leaves a log as large as the history; `beginSession` runs `wal_checkpoint(PASSIVE)`, so a session that loses power still reads as unclean; `markCleanShutdown` runs `wal_checkpoint(TRUNCATE)`, so the history survives a loss of power after the app quits |
| User-facing copy | Apple Style Guide and macOS HIG: title-style capitalization for menu items, buttons, toggles, and section headers; sentence style for descriptions and messages; key names Return, Escape, Up Arrow; shortcuts in prose as Shift-Command-C; `>` between menu and settings levels; "click" and "choose" on Mac; contractions are fine; never "please". The Clear History sheet follows Safari's: a "Clear:" popup of lowercase ranges and a Clear History button |
| UserDefaults keys | `hotkey`, `showMenuBarIcon`, `showCopyConfirmation`, `storageLimitEnabled`, `storageLimitGigabytes`, `settingsLastPane`, `welcomeShown`, `fileAccessPrompted.<case>` |
| Versions | `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`; the release workflow overrides both from the tag (`X.Y.Z` to `X*10000+Y*100+Z`) |
| Updates | Sparkle `SPUStandardUpdaterController`; `SUFeedURL` = `https://raw.githubusercontent.com/nich227/ClipDeck/gh-pages/updates.xml.rss`; `SUPublicEDKey`, `SUEnableAutomaticChecks` true (no permission prompt; the About pane toggles it), and `SUAutomaticallyUpdate` false (installs only with consent) in `Info.plist`; private seed is the `SPARKLE_ED_PRIVATE_KEY` secret, base64 of the raw 32 byte ed25519 seed. The same seed is in the owner's login keychain under the Sparkle account `ClipDeck` (`generate_keys --account ClipDeck`, `-p` prints the public key, `-x <file>` exports the seed), never under the default account, which belongs to other apps. `scripts/check-sparkle-key.js` fails when the secret is not the private half of `SUPublicEDKey` |
| Menu bar icon | `MenuBarIcon` asset, Ant Design `PaperClipOutlined`, template vector, 18 pt |
| Wordmark | Instrument Serif Regular (OFL), bundled at `ClipDeck/Resources/Fonts/` as a folder reference and registered through `ATSApplicationFontsPath`. `DeckType.wordmark` is its only use in the app. `scripts/make-wordmark.swift` renders `assets/wordmark-*.png` for the README; `make-dmg-background.swift` registers the same file for the dmg |
| App icon | `ClipDeck/Resources/AppIcon.icon`, an Icon Composer document compiled by actool (`ASSETCATALOG_COMPILER_APPICON_NAME`). Light: white background, black glass paperclip. Dark: near-black background, white glass paperclip. `assets/icon-*.png` are renders of it for the README |
| Signing (local) | ad hoc (`CODE_SIGN_IDENTITY = -`). Hardened runtime Release only, because the tests load into the Debug app |
| Lifecycle | `main.swift` installs `AppDelegate`; no SwiftUI `App` scene. The app is an accessory (no Dock icon) until Settings or Clear History opens; `DockPresence` switches it to a regular app while any such window is open and back when the last one closes. `AppDelegate.makeMainMenu` supplies the ClipDeck, File, Edit, and Window menus that make Command-W, Command-Q, and the text commands work in those windows. At launch the main menu and the animation preload come first, the store opens off the main thread, then `start(with:)` builds everything that needs it. A store that cannot open shows an alert whose one button quits. Its text is `Error.explanation`: the error's description, then its `recoverySuggestion` when it gives one (`StoreError` and `SQLiteError` are the one source of that wording; `ErrorText.swift` joins the two). `AppDelegate.reopening(after:)` decides what follows: nothing when opening again cannot help (a newer history, and the system's errors for no permission, no space, or a read-only volume), "Then open ClipDeck again." after an error that gives advice (a full disk, a folder that cannot be opened, a damaged database, whose advice says how to start with an empty history), and "Quit ClipDeck. Open it again." otherwise. The Clear History window shows `Error.explanation` after its own sentence. Reopening the app before the store is ready opens Settings once it is |
| Disk image window | The branded background from `make-dmg-background.swift` by default. Finder paints white behind any background picture in both appearances (measured 2026-11-07), so the window is white in Dark Mode too, which is the intent. The picture is transparent with dark ink. `--plain` drops the picture, and Finder's own surface and labels then follow the appearance |
| File access | `FileAccess` lists Desktop, Documents, Downloads, Removable Volumes, and Full Disk Access. `WelcomeWindowController.showIfFirstLaunch()` shows the Welcome window once (`welcomeShown`); each Grant lists the folder, which triggers the system prompt, and records `fileAccessPrompted.<case>`. Full Disk Access opens System Settings. `FileAccessAuthorization.state` never probes a folder that was not requested, so reading state cannot prompt. Settings > General > Privacy > Review reopens the window, titled File Access with a Done button. A granted mark draws on only for a grant made while the window is open (`FileAccessModel.justGranted`): the first refresh after `windowWillOpen` only records the states, so a grant made while the window was closed shows still |

## Commands

```bash
xcodegen generate
xcodebuild -project ClipDeck.xcodeproj -scheme ClipDeck -configuration Debug -derivedDataPath build/DerivedData build
xcodebuild -project ClipDeck.xcodeproj -scheme ClipDeck -configuration Debug -derivedDataPath build/DerivedData test
scripts/smoke-test.sh                 # launches the Debug binary with a store and a home folder in a temporary directory and a named pasteboard of its own (`CLIPDECK_PASTEBOARD`), writes a marker to that pasteboard, checks the row, stops the app by PID; it never reads or replaces the general pasteboard
scripts/smoke-test.sh --real-store    # the same against the real store and the general pasteboard; this build migrates the store; refuses while another ClipDeck is running; removes the marker row
TEST_RUNNER_CLIPDECK_BENCH=1 xcodebuild -project ClipDeck.xcodeproj -scheme ClipDeck -configuration Debug -derivedDataPath build/DerivedDataOpt SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule test -only-testing:ClipDeckTests/PipelineBenchmarks 2>&1 | grep BENCH    # optimized timings, private pasteboards and temporary stores only
TEST_RUNNER_CLIPDECK_BENCH=1 xcodebuild -project ClipDeck.xcodeproj -scheme ClipDeck -configuration Debug -derivedDataPath build/DerivedDataOpt SWIFT_OPTIMIZATION_LEVEL=-O test -only-testing:ClipDeckTests/ClipStoreBenchmarks 2>&1 | grep BENCH    # optimized store timings over a seeded temporary store
python3 scripts/make-animations.py    # regenerates ClipDeck/Resources/Animations/*.json
TEST_RUNNER_CLIPDECK_MODEL_SEEDS=1,2,3 TEST_RUNNER_CLIPDECK_MODEL_STEPS=3000 xcodebuild -project ClipDeck.xcodeproj -scheme ClipDeck -configuration Debug -derivedDataPath build/DerivedData test -only-testing:ClipDeckTests/ClipStoreModelTests    # more seeds of the random store model, comma separated; steps default to 3,000; without the seeds one fixed seed runs and the second test is skipped
scripts/make-dmg.sh <ClipDeck.app> <version> [out.dmg] [--plain]     # branded white window by default
scripts/package.sh <version> [--notarize xcode|<profile>|none]   # Developer ID build, notarized through Xcode by default, zip and dmg in build/release/
```

The `.xcodeproj` is generated and gitignored. Edit `project.yml`.

## Files

```
ClipDeck/
├── main.swift                        AppKit entry point
├── AppDelegate.swift                 Store location and open (off the main thread), the launch alert, Sparkle updater, monitor, ingest, copier, panel, menu bar, HUD, storage limit, session recovery
├── Info.plist                        LSUIElement, versions from build settings, SUFeedURL, SUPublicEDKey
├── ClipDeck.entitlements             No sandbox
├── Controllers/
│   ├── ClipStore.swift               SQLite on one serial queue: schema, migrations, insert, copy time, paging, FTS, clear, byte counter, eviction, session flag, checkpoints, sweep; file queue and staging for blob and thumbnail bytes; `StoreError`
│   ├── PasteboardMonitor.swift       300 ms utility timer on changeCount, pauses on lock and sleep, skips own writes
│   ├── PasteboardWriter.swift        prepare (resolve files, off main) and write (hand a stored item back with its original types)
│   ├── ClipCopier.swift              Payload, prepare, write back, onCopied or onFailed, touch, notify: the one copy path
│   ├── CopyHUDController.swift       NSGlassEffectView pill under the menu bar, CASpringAnimation in and out, Lottie check, VoiceOver announcements
│   ├── MenuBarController.swift       NSStatusItem and NSMenu: ten recent rows with lazy thumbnails, coalesced refresh, Check for Updates, commands
│   ├── ThumbnailGenerator.swift      QuickLook and ImageIO thumbnails off main, one job per hash; ThumbnailCache (off-main decode, shared loads, cost limit); clipThumbnailDidChange
│   ├── HotkeyManager.swift           Carbon RegisterEventHotKey, availability probe, fallback, teardown
│   ├── HistoryViewModel.swift        Panel state: pages, search, selection, one reload runner, first-page merge, hasLoaded and loadFailed
│   ├── PanelController.swift         DeckPanel (non-activating NSPanel) with NSGlassEffectView content, key and click monitors
│   ├── DockPresence.swift            Regular app while a window is open, accessory otherwise
│   ├── WelcomeWindowController.swift First-launch file access window, FileAccessModel, WelcomeView
│   ├── ClearHistoryWindowController.swift
│   └── SettingsWindowController.swift  Toolbar tabs; passes store and updater to the panes
├── Models/
│   ├── ClipItem.swift                ClipKind, ClipItem, PageCursor, ClipPayload
│   ├── Capture.swift                 Capture, PasteboardSnapshot, PasteboardTypes
│   ├── PasteboardClassifier.swift    Pasteboard to Capture or SkipReason; per-file work in parallel
│   ├── HotkeyConfig.swift            Key code, Carbon modifiers, validation, persistence
│   ├── ClearPolicy.swift             ClearRange, ClearRequest
│   ├── StorageBudget.swift           Limit from UserDefaults; EvictionPlan
│   ├── MenuFormatting.swift          Menu row and HUD titles
│   ├── FileAccess.swift              Protected locations, their probes and settings panes, FileAccessAuthorization
│   └── PollingGate.swift             Pause reasons for capture
├── Views/
│   ├── PanelView.swift               Search field, the list area's states, footer key hints, EmptyStateView (Lottie), LoadFailedView
│   ├── HistoryList.swift             ListMetrics, the windowed list, hover suppression, ClipRow
│   ├── ThumbnailView.swift           ThumbnailReader, row thumbnail, file type icons
│   ├── ItemFormatting.swift          Row subtitle, preview metadata, VoiceOver description
│   ├── PreviewPane.swift             Selected item preview, inline muted video
│   ├── DeckAnimation.swift           The one entry point for drawn animations: one-shot or loop, tint, isActive, still frame, preload
│   ├── ClearHistoryView.swift
│   └── Settings/                     General (shortcut, login, menu bar, confirmation), History (limit, usage), About (updates)
├── Utilities/
│   ├── Constants.swift               Timing, sizes, keys, Palette, Space, Radius, Glyph, Anim, DeckType
│   ├── LocalVolumes.swift            Mount table snapshot; remote paths are never stat'ed
│   ├── SQLite.swift                  Thin libsqlite3 wrapper: statement cache, borrowed bindings, column prefix read; `SQLiteError`, its description, and its advice
│   ├── ContentHash.swift             SHA-256 with a kind tag
│   ├── ErrorText.swift               `Error.advice` and `Error.explanation`: a description as a sentence, then the error's own advice
│   ├── ImageProcessing.swift         ImageIO: sizes, PNG, thumbnails
│   └── Log.swift                     Loggers and notification names
└── Resources/
    ├── Assets.xcassets               MenuBarIcon (SVG), ClipDeckCaution, ClipDeckDanger
    ├── AppIcon.icon/                 icon.json plus Assets/paperclip.svg; one file reference in project.yml
    ├── Fonts/                        InstrumentSerif-Regular.ttf, a folder reference named by ATSApplicationFontsPath
    └── Animations/                   paperclip.json, copied.json, noresults.json (generated)
ClipDeckTests/                        XCTest, temporary directories and private pasteboards only, never the real store. Fixtures.swift builds captures; StoreFixtures.swift models and inspects the store; FetchRecorder.swift counts, holds, and fails the view model's reads
scripts/                              build.sh, test.sh, smoke-test.sh, package.sh, make-animations.py, make-wordmark.swift, make-dmg.sh, make-dmg-background.swift, sign-nested.sh, import-certificate.sh, check-sparkle-key.js, sign-release.js, update-appcast.js
.github/workflows/                    test.yml (push and PR), release.yml (tags v*), check-secrets.yml (run by hand)
docs/release-notes/<version>.md       Shown in the GitHub Release and the Sparkle update window
licenses/                             ant-design-icons, instrument-serif, lottie-ios, sparkle
assets/                               icon-*.png (renders of the app icon) and wordmark-*.png (the name in Instrument Serif) for the README
DESIGN.md                             Tokens and motion
```

## Tests

| File | Covers |
|---|---|
| `ClipStoreTests.swift` | Insert, dedup bump, touch, paging, FTS (prefix lengths, order after a repeat copy, cursor rows that moved or left, clock steps), copy order (copies at the same instant, a copy after the clock stepped back listed first and kept by eviction, the search order equal to the list order), payloads, row and text previews, format refresh, missing files and images, remote volumes, clear, file cleanup, staging and failed inserts, byte counter, eviction (oldest by last use, newest kept, batches, at insert and when lowered), session flag, sweep and recount, migrations from empty and from v1 to v4, newer schema refused, connection settings, query plans |
| `ClipStoreMigrationTests.swift` | The step from version 4 to 5 against a database built as a schema 4 build left it: every row, format, and file reference survives unchanged, the schema equals a fresh version 5 schema, `seq` follows the list order, and the migrated store is sound, a migrated history takes every kind of write, a step that fails leaves version 4 intact, rows that refer to no item are dropped, an empty history migrates, every older version reaches 5 |
| `ClipStoreModelTests.swift` | A seeded random sequence of copies, repeat copies, panel copies, thumbnail saves, limits, and clears, run against a store and a plain model of it. The list, searches, byte counter, and files on disk are compared at intervals and at the end, with the database's own checks. One fixed seed runs with the suite; `CLIPDECK_MODEL_SEEDS` and `CLIPDECK_MODEL_STEPS` run more (Commands) |
| `StoreFixtures.swift` | Not a test: `SeededGenerator`, `SearchModel` (the index's answers computed without SQLite), `StoreInspector` (reads a store through a second connection; `assertSound` checks what a version 5 database must keep true), `VersionFourFixture` (builds older databases) |
| `DatabaseTests.swift` | Statement cache, bound text and blobs (empty, NUL, large), a failed statement runs again, nested use of one SQL string, `first` runs a write to completion, rollback, column prefix read |
| `ContentHashTests.swift` | Known digests, so the hash of stored rows never changes; tag separation; sliced data |
| `ClipStoreBenchmarks.swift` | Skipped unless `CLIPDECK_BENCH` is set. Seeds `CLIPDECK_BENCH_ROWS` rows (default 100,000) and reports throughput and latency in wall and CPU time |
| `StorageBudgetTests.swift` | Limit off until enabled, default, decimal bytes, clamping, `EvictionPlan.select` |
| `MenuFormattingTests.swift` | Row titles and tooltips |
| `FileAccessTests.swift` | Every access has a probe and a settings pane, only Full Disk Access opens System Settings, the probe paths, and that an unrequested folder reads as undetermined without prompting |
| `FileAccessModelTests.swift` | Which grants count as just granted, so their marks draw on: not the first state, not a state that stays granted, not several at once, not a grant made while the window was closed |
| `AnimationTests.swift` | Every file loads with its size, length, frame rate, and still marker, and has a constant; the paperclip draws on and unwinds; the check appears after the ring; the glass draws its lens, then its handle; each still frame is a whole, centered drawing; every file plays on the Core Animation engine; `DeckAnimationSurface` builds nothing while idle, releases a hidden loop, holds a one-shot on its still frame, reports its end, fits its frame, applies the tint only when it changes, and rebuilds after leaving a window |
| `PasteboardClassifierTests.swift` | Text, rich text, HTML only, files, images and companions, TIFF flag, concealed and transient, 50 MB cap, titles against a reference on edge cases and generated text, the text hash pinned to its UTF-8 bytes, order and sizes of a large file selection |
| `PasteboardWriterTests.swift` | Round trips; the change count each write returns; prepared file writes, order, and a missing file |
| `PasteboardMonitorTests.swift` | Own writes skipped, outside writes captured, pause and resume |
| `HistoryViewModelTests.swift` | Paging, selection bounds, load more, search at once after a pause and once for a burst of keystrokes, merge of a history change (kept rows and selection, a copied row, evicted rows, nothing published when nothing changed), positions after merges, search against the real store (paging in store order, a repeat copy, a touch, every loaded row kept after the clock was set back), a copy dated in the past listed first in the history, a seeded walk of copies, repeat copies, and touches dated out of order that keeps both lists in copy order, the merge around the page's last row (a row cleared above it, a whole page of new rows, a whole page of repeat copies, in the history and in a search), one reload in flight for a burst and for typing, a reload dropped when the panel hides, `hasLoaded`, a failed first page, a failed search, a failed merge, one publish for a failure that repeats, the thumbnail token |
| `PanelViewTests.swift` | The hosted panel, with `deckReduceMotion` set so the machine's Reduce Motion setting never decides a result: no empty state before the first page, the paperclip loop released when the panel hides and back when it shows, the glass drawn once while a search keeps finding nothing, no animation left behind when the list area changes state, none in the load-failed state, still frames that do not play with Reduce Motion on |
| `ThumbnailTests.swift` | One thumbnail job per hash, skipped and failed generation, a thumbnail whose item is gone (not saved, no file left in `thumbs/` or `staging/`), cache loads shared, sizes cached apart and emptied together, a missing thumbnail retried, the ingest notifications, one image capture reaching an open panel with at most two reads for the panel and two for the menu, the stored bytes at the history change that follows a thumbnail |
| `ClipCopierTests.swift` | Copy writes and moves the item to the top, the confirmation comes before the history change, files and images, the failures (an item that left the store, an image that lost its file, an item that cannot be written), the history change after a failure |
| `CopyHUDControllerTests.swift` | A copy is announced when the confirmation is turned off |
| `LaunchTests.swift` | The store opens off the main thread, a store that cannot open reports why, a Debug build's store location and pasteboard, the launch alert's text for a newer history, a SQLite error with and without advice, a damaged history (how to start over), and any other error, advice kept out of the description and followed by the alert exactly where an error gives it, no repeated sentence |
| `MenuBarControllerTests.swift` | The ten rows and their keys, icons reused between openings, no icon kept for a cleared image, one refresh for a burst, a failed refresh |
| `MenuShortcutTests.swift` | The row keys, the global shortcut as a menu key equivalent, keys the menu cannot show |
| `PipelineBenchmarks.swift` | Timings for capture, thumbnails, the list, copy, and the menu. Skipped unless `CLIPDECK_BENCH=1` |
| `ListMetricsTests.swift` | The rows built for a scroll offset stay O(visible) at any item count; the least scroll that reveals a row |
| `ItemFormattingTests.swift` | Relative time, row subtitle, preview metadata, VoiceOver description (built with the row's subtitle), Increase Contrast fills |
| `PanelPlacementTests.swift` | The panel's frame on large, second, short, and too-small screens |
| `HotkeyConfigTests.swift` | Default, reserved combos, modifier rules, encode and decode |
| `ClearPolicyTests.swift` | Range cutoffs, `PollingGate` |

## When you change X, also change Y

| Change | Also update |
|---|---|
| A pasteboard kind or type rule | `PasteboardClassifier`, `PasteboardWriter`, `PasteboardClassifierTests` |
| The schema | A new migration step, `schemaVersion`, `testMigrationFromEmptyDatabase`, a migration test from the previous version |
| A store query on a hot path | Expose its SQL as a `ClipStore` constant and add a query plan test |
| A statement that removes rows from `items` | Build it with `deleteSQL(where:)`, `testRemovalsWalkTheSequenceIndex` |
| `Constants.List.rowPreviewCharacters` | A migration step that rewrites `items.preview`; the step from version 4 wrote 300 |
| The store's speed | Run the benchmark before and after (Commands) |
| What counts toward the storage limit | `storedBytesSQL`, a new migration step for the triggers, `testStoredBytesFollowInsertsBumpsClearsAndThumbnails`, README |
| A design token | `DESIGN.md` and `Constants.swift` together |
| An animation | `scripts/make-animations.py`, rerun it, `Constants.Animations` (the name and `all`), `AnimationTests`, the drawn animations table in `DESIGN.md` |
| A UserDefaults key | `Constants`, the model that reads it, the Settings pane that writes it, the Facts table above |
| A Settings pane | `SettingsSection` (title and symbol) and `SettingsPane` in `SettingsWindowController.swift`. A pane is as tall as its content (`settingsPane()`), so it has no height to set |
| Reserved shortcuts | `HotkeyConfig.reserved`, `HotkeyConfigTests` |
| The minimum macOS | `project.yml` (both places), README Requirements, `release.yml` install note; `Info.plist` and the appcast read it from the build |
| The feed URL or Sparkle key | `Info.plist`, the `SPARKLE_ED_PRIVATE_KEY` secret, the keychain item under the Sparkle account `ClipDeck`, README Releasing. A new key means every installed copy needs one manual reinstall, so change it only before a public release. Run `check-secrets.yml` afterward |
| How the certificate is imported on a runner | `scripts/import-certificate.sh` only; `release.yml` and `check-secrets.yml` both call it, so the check tests what the release runs |
| A copy path | `ClipCopier` only |
| The order of a list the store returns | `HistoryViewModel.firstIndex(in:after:)` relies on one order for both lists, newest copy first; the search and whole-page tests in `HistoryViewModelTests` |
| A write of `last_used` or `seq` | It goes through `ClipStore.copyTime`, so both lists stay one order; the copy-order tests in `ClipStoreTests` (`testCopiesAtTheSameInstantListInCopyOrder`, `testACopyMadeAfterTheClockSteppedBackIsListedFirst`, `testSearchOrderMatchesTheListOrder`) |
| A `StoreError` case, or the `recoverySuggestion` of a `StoreError` or `SQLiteError` | The advice is user-facing copy and follows the description wherever `Error.explanation` is shown (the launch alert, the Clear History window). `AppDelegate.reopening(after:)` adds "Then open ClipDeck again." after any advice except a newer history's; `LaunchTests`, `testStoreErrorsDescribeThemselves` |
| A state of the panel's list area | `PanelView.listArea`, `PanelViewTests`, invariant 6 |
| A test that hosts a view with a `DeckAnimation` | Set `\.deckReduceMotion` on the hosted view. The workflow runner has Reduce Motion turned on, so a test that follows the system setting sees only still frames there |
| Where the app keeps or opens its store, or which pasteboard it watches | `AppDelegate.storeLocation`, `openStore`, and `pasteboardName`, `LaunchTests`, `scripts/smoke-test.sh` |
| `schemaVersion`'s declaration | `scripts/smoke-test.sh` reads the number from `ClipStore.swift` |
| Capture, thumbnail, list, copy, or menu code on a hot path | Run `PipelineBenchmarks` before and after, on the same machine load |
| The app icon | `AppIcon.icon/icon.json` (both appearances), then re-render `assets/icon-light.png` and `assets/icon-dark.png` from the built app |
| The wordmark face | `Resources/Fonts/`, `Constants.Brand.fontName`, `make-dmg-background.swift`, `make-wordmark.swift`, then rerun it for `assets/wordmark-*.png`; the license text in `licenses/` |

## Release

Push a tag `vX.Y.Z` on `main`. `release.yml` first checks that `SPARKLE_ED_PRIVATE_KEY` matches `SUPublicEDKey` (`scripts/check-sparkle-key.js`) and stops if it does not, imports the certificate into a keychain made for the run (`scripts/import-certificate.sh`), builds Release with the version from the tag, signs with the Developer ID from the secrets (team `8ZUR795GTN`, written in the workflow as in Gailan; a team id is public), re-signs Sparkle's nested code (`scripts/sign-nested.sh`), notarizes and staples, zips, builds the dmg (`scripts/make-dmg.sh`), signs and notarizes the dmg, signs the zip with the Sparkle seed (`scripts/sign-release.js`), creates the GitHub Release with `docs/release-notes/X.Y.Z.md`, and appends the item to `updates.xml.rss` on `gh-pages` (`scripts/update-appcast.js`). Secrets: `MACOS_CERTIFICATE_P12` (base64 of the `.p12`), `MACOS_CERTIFICATE_PASSWORD`, `APPLE_API_KEY_P8` (base64 of the `.p8`, not its text), `APPLE_API_KEY_ID`, `APPLE_API_ISSUER`, `SPARKLE_ED_PRIVATE_KEY`. Set them with `gh secret set <NAME> --repo nich227/ClipDeck < file` so a key never passes through the clipboard, where ClipDeck itself would record it. `check-secrets.yml` (Actions > check secrets > Run workflow) tests all six without releasing: the Sparkle key check, the certificate import plus a signed scratch file, and `notarytool history` with the API key; every check runs even when an earlier one fails. Run it after changing any secret and before the first tag. Write the release note before tagging.

Locally, `scripts/package.sh <version> [--notarize xcode|<profile>|none]` runs the same steps with the Developer ID in the keychain and writes `build/release/`. The default, `xcode`, notarizes through the account signed into Xcode: `xcodebuild archive`, `scripts/sign-nested.sh` on the archived app (Xcode leaves Sparkle's four helpers unsigned, and Apple refuses an unsigned executable), `xcodebuild -exportArchive` with `destination: upload`, then `xcodebuild -exportNotarizedApp` polled every 20 s. That route notarizes archives only, so the dmg is signed but not notarized; a quarantined copy mounts and the stapled app inside is accepted (measured 2026-11-07). A `notarytool` profile notarizes the dmg too. Never commit a certificate, a `.p8`, or the Sparkle seed; `.gitignore` lists those file types and `git ls-files` must never show one.

## Verify before finishing

```bash
xcodegen generate
xcodebuild -project ClipDeck.xcodeproj -scheme ClipDeck -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | grep -E 'error:|warning:|BUILD' | grep -v appintentsmetadataprocessor
xcodebuild -project ClipDeck.xcodeproj -scheme ClipDeck -configuration Debug -derivedDataPath build/DerivedData test 2>&1 | grep -E 'error:|Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)' | tail -3
python3 scripts/make-animations.py && git diff --exit-code -- ClipDeck/Resources/Animations
scripts/smoke-test.sh                                         # isolated store; never pass --real-store here
grep -rnE 'as!|try!|\)!' ClipDeck --include='*.swift'          # must print nothing
```

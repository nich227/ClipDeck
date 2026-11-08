import SwiftUI

struct HistorySettingsPane: View {
    let store: ClipStore?

    @AppStorage(Constants.Storage.limitEnabledKey) private var limitEnabled = false
    @AppStorage(Constants.Storage.limitGigabytesKey) private var limitGigabytes = Constants.Storage.defaultLimitGigabytes

    @State private var itemCount: Int?
    @State private var usedBytes: Int64?
    @State private var pendingApply: Task<Void, Never>?

    private var budget: StorageBudget? {
        limitEnabled ? StorageBudget(gigabytes: limitGigabytes) : nil
    }

    var body: some View {
        Form {
            Section("History") {
                LabeledContent("Items") {
                    Text(itemCount.map { $0.formatted() } ?? "\u{2026}")
                        .monospacedDigit()
                }
                LabeledContent("Storage Used") {
                    Text(usageText)
                        .monospacedDigit()
                }
                LabeledContent {
                    Button("Clear History\u{2026}") { ClearHistoryWindowController.shared.show() }
                } label: {
                    SettingLabel("Clear History", detail: "Remove items from a period of time, by kind.")
                }
            }

            Section("Storage") {
                Toggle(isOn: $limitEnabled) {
                    SettingLabel(
                        "Limit Storage",
                        detail: "When your history reaches this size, the oldest items are removed automatically."
                    )
                }
                if limitEnabled {
                    LabeledContent {
                        HStack(spacing: Space.xs) {
                            TextField(
                                "Gigabytes",
                                value: $limitGigabytes,
                                format: .number.precision(.fractionLength(0...1))
                            )
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                            Text("GB")
                            Stepper(
                                "Gigabytes",
                                value: $limitGigabytes,
                                in: Constants.Storage.minimumLimitGigabytes...Constants.Storage.maximumLimitGigabytes,
                                step: 1
                            )
                            .labelsHidden()
                        }
                    } label: {
                        SettingLabel("Maximum Size")
                    }
                    if let usedBytes, let budget {
                        ProgressView(value: Double(min(usedBytes, budget.bytes)), total: Double(budget.bytes))
                            .tint(Palette.accent)
                    }
                }
            }

            Section("Files") {
                LabeledContent {
                    Button("Show in Finder") {
                        if let root = store?.location.root {
                            NSWorkspace.shared.activateFileViewerSelecting([root])
                        }
                    }
                } label: {
                    SettingLabel(
                        "History Location",
                        detail: (store?.location.root.path as NSString?)?.abbreviatingWithTildeInPath
                    )
                }
                SettingLabel(
                    "Copied Files",
                    detail: "ClipDeck keeps a link to each file you copy instead of a copy of the file, so files don't count toward the storage limit."
                )
            }
        }
        .settingsPane(.history)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .clipHistoryDidChange)) { _ in
            Task { await refresh() }
        }
        .onChange(of: limitEnabled) { _, _ in scheduleApply() }
        .onChange(of: limitGigabytes) { _, _ in scheduleApply() }
        .onDisappear { pendingApply?.cancel() }
    }

    private var usageText: String {
        guard let usedBytes else { return "\u{2026}" }
        guard let budget else { return ItemFormatting.size(usedBytes) }
        return "\(ItemFormatting.size(usedBytes)) of \(ItemFormatting.size(budget.bytes))"
    }

    private func refresh() async {
        guard let store else { return }
        itemCount = try? await store.count()
        usedBytes = try? await store.storageUsage()
    }

    /// The limit takes effect only after a sequence of stepper clicks or typed digits settles.
    /// Thus, it never reduces the history to a number that the user only passed through.
    private func scheduleApply() {
        pendingApply?.cancel()
        pendingApply = Task {
            try? await Task.sleep(for: Constants.Storage.limitApplyDebounce)
            guard !Task.isCancelled else { return }
            await apply()
        }
    }

    private func apply() async {
        let clamped = StorageBudget.clamp(limitGigabytes)
        if clamped != limitGigabytes {
            limitGigabytes = clamped
        }
        guard let store else { return }
        let removed = try? await store.setStorageBudget(budget?.bytes)
        if let removed, removed > 0 {
            NotificationCenter.default.post(name: .clipHistoryDidChange, object: nil)
        }
        await refresh()
    }
}

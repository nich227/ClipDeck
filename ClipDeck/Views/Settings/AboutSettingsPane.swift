import Sparkle
import SwiftUI

struct AboutSettingsPane: View {
    let updater: SPUStandardUpdaterController?

    @State private var automaticChecks = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: Space.md) {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .frame(width: 44, height: 44)
                .foregroundStyle(Palette.accent)
            VStack(spacing: Space.xxs) {
                Text(Constants.appName)
                    .deckFont(.wordmark)
                Text(version)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Clipboard history for your Mac.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)

            if let updater {
                VStack(spacing: Space.xs) {
                    Button("Check for Updates\u{2026}") { updater.checkForUpdates(nil) }
                    Toggle("Automatically check for updates", isOn: $automaticChecks)
                        .toggleStyle(.checkbox)
                        .onChange(of: automaticChecks) { _, on in
                            updater.updater.automaticallyChecksForUpdates = on
                        }
                }
                .onAppear { automaticChecks = updater.updater.automaticallyChecksForUpdates }
            }

            VStack(spacing: Space.xxs) {
                if let repository = URL(string: Constants.repository) {
                    Link("Source Code and Release Notes", destination: repository)
                        .font(.caption)
                }
                Text("MIT License. Copyright 2026 Kevin Chen.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Space.xxl)
        .frame(width: SettingsSection.width, height: SettingsSection.about.height)
    }
}

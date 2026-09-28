import AppKit
import ServiceManagement
import SwiftUI

/// First-run introduction, shown once per `Pref.onboardingVersion` and replayable
/// from Settings → General. A real window rather than a sheet so it still works
/// when the main window is closed and Gauge is running from the menu bar.
struct WelcomeView: View {
    static let windowID = "welcome"

    @Environment(\.dismiss) private var dismiss
    @AppStorage(Pref.onboardingVersion) private var onboardedVersion = 0
    @State private var step: Step = .intro

    enum Step: Int, CaseIterable, Identifiable {
        case intro, privacy, setup, shortcuts
        var id: Int { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 36)
                .padding(.top, 34)
                .padding(.bottom, 20)

            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 560, height: 520)
        .background(.background)
        // Any way out counts as done, including closing the window.
        .onDisappear { onboardedVersion = Pref.currentOnboardingVersion }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .intro: IntroStep()
        case .privacy: PrivacyStep()
        case .setup: SetupStep()
        case .shortcuts: ShortcutsStep()
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { advance(by: -1) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(step == .intro ? 0 : 1)
                .disabled(step == .intro)

            Spacer()

            HStack(spacing: 6) {
                ForEach(Step.allCases) { dot in
                    Circle()
                        .fill(dot == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }

            Spacer()

            Button(step == .shortcuts ? "Start Monitoring" : "Continue") {
                if step == .shortcuts { dismiss() } else { advance(by: 1) }
            }
            .keyboardShortcut(.defaultAction)
        }
        .animation(.easeInOut(duration: 0.15), value: step)
    }

    private func advance(by delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { step = next }
    }
}

// MARK: Steps

private struct IntroStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepHeading(
                icon: .appIcon,
                title: "See what your Mac is actually doing.",
                subtitle: "Gauge reads the same system counters Activity Monitor does, then explains them."
            )
            VStack(alignment: .leading, spacing: 14) {
                WelcomeBullet(
                    symbol: "chart.line.uptrend.xyaxis",
                    title: "Six resources, one window",
                    detail: "CPU, memory, disk, network, GPU and battery, each with a live chart."
                )
                WelcomeBullet(
                    symbol: "square.grid.2x2",
                    title: "Apps, not process soup",
                    detail: "Dozens of browser helpers roll up into one row, so the culprit is obvious."
                )
                WelcomeBullet(
                    symbol: "clock.arrow.circlepath",
                    title: "30 days of history",
                    detail: "A snapshot every minute while Gauge runs, so you can spot the pattern."
                )
            }
        }
    }
}

private struct PrivacyStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepHeading(
                icon: .symbol("lock.shield"),
                title: "Everything stays on this Mac.",
                subtitle: "Gauge has no network code at all. There is nothing to opt out of."
            )
            VStack(alignment: .leading, spacing: 14) {
                WelcomeBullet(symbol: "person.crop.circle.badge.xmark", title: "No account", detail: "Open it and it works. There is no sign-in.")
                WelcomeBullet(symbol: "antenna.radiowaves.left.and.right.slash", title: "No telemetry", detail: "No analytics, no crash uploads, no phoning home.")
                WelcomeBullet(symbol: "power", title: "No background daemon", detail: "Quit Gauge and it stops sampling, completely.")
            }
            Panel(padding: 12) {
                Text("Recorded to").font(.caption).foregroundStyle(.secondary)
                Text(Self.dataPath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text("Clear it any time in Settings → Data.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private static var dataPath: String {
        let path = HistoryStore.defaultURL.deletingLastPathComponent().path(percentEncoded: false)
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        return path.hasPrefix(home) ? "~/" + path.dropFirst(home.count) : path
    }
}

private struct SetupStep: View {
    @AppStorage(Pref.menuBarMetric) private var menuMetric: Metric = .cpu
    @AppStorage(Pref.menuBarStyle) private var menuStyle: MenuBarStyle = .iconAndValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepHeading(
                icon: .symbol("slider.horizontal.3"),
                title: "Set it up the way you like.",
                subtitle: "All of this is in Settings later, so nothing here is final."
            )
            Form {
                Section {
                    Toggle("Open Gauge at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                    if let loginError {
                        Text(loginError).font(.caption).foregroundStyle(.red)
                    }
                } footer: {
                    Text("History is only recorded while Gauge is running.")
                }

                Section("Menu bar") {
                    Picker("Show", selection: $menuMetric) {
                        ForEach(Metric.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Style", selection: $menuStyle) {
                        ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, -20)

            Text("Gauge keeps sampling from the menu bar after you close the window.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            // Fails when running unbundled (`swift run`); needs the built Gauge.app.
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct ShortcutsStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepHeading(
                icon: .symbol("keyboard"),
                title: "Three things worth knowing.",
                subtitle: "That's the whole tour — the rest of the app explains itself."
            )
            VStack(spacing: 0) {
                ShortcutRow(keys: "⌘S", title: "Save a moment", detail: "Captures what every app is doing, with a note.")
                Divider()
                ShortcutRow(keys: "⇧⌘P", title: "Pause sampling", detail: "Freezes the charts so you can read them.")
                Divider()
                ShortcutRow(keys: "⌘,", title: "Settings", detail: "Sampling rate, alert thresholds and your data.")
            }
            .background(.background.secondary, in: .rect(cornerRadius: 12))

            Panel(padding: 12) {
                Label("Free and open source, under the MIT licence.", systemImage: "heart")
                    .font(.callout.weight(.medium))
                Text("Gauge is built in the open. Issues and pull requests are welcome.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("github.com/lightwaslost/gauge", destination: Links.repository)
                    .font(.caption)
            }
        }
    }
}

// MARK: Pieces

private struct StepHeading: View {
    enum Icon {
        case appIcon
        case symbol(String)
    }

    let icon: Icon
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch icon {
            case .appIcon:
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(width: 56, height: 56, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary)
            }
        }
    }
}

private struct WelcomeBullet: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.tint)
                .frame(width: 22, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ShortcutRow: View {
    let keys: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.callout.weight(.medium).monospaced())
                .frame(width: 46)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

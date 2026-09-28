import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AlertSettings().tabItem { Label("Alerts", systemImage: "bell") }
            DataSettings().tabItem { Label("Data", systemImage: "externaldrive") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480)
    }
}

private struct GeneralSettings: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Pref.visibleInterval) private var visibleInterval = 2.0
    @AppStorage(Pref.hiddenInterval) private var hiddenInterval = 10.0
    @AppStorage(Pref.menuBarMetric) private var menuMetric: Metric = .cpu
    @AppStorage(Pref.menuBarStyle) private var menuStyle: MenuBarStyle = .iconAndValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
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

            Section("Sampling") {
                Picker("While the window is open", selection: $visibleInterval) {
                    ForEach([1.0, 2, 3, 5], id: \.self) { Text("Every \(Int($0)) s").tag($0) }
                }
                Picker("While it's closed", selection: $hiddenInterval) {
                    ForEach([5.0, 10, 30, 60], id: \.self) { Text("Every \(Int($0)) s").tag($0) }
                }
            }

            Section("Menu bar") {
                Picker("Show", selection: $menuMetric) {
                    ForEach(Metric.allCases) { Text($0.title).tag($0) }
                }
                Picker("Style", selection: $menuStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                }
            }

            Section {
                Button("Show Welcome Window…") { openWindow(id: WelcomeView.windowID) }
            } footer: {
                Text("The short introduction Gauge shows the first time you open it.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
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

private struct AlertSettings: View {
    @AppStorage(Pref.alertsEnabled) private var enabled = true
    @AppStorage(Pref.alertCPUThreshold) private var threshold = 80.0
    @AppStorage(Pref.alertSustainSeconds) private var sustain = 120.0
    @AppStorage(Pref.alertMemoryGrowthGB) private var growth = 1.0
    @AppStorage(Pref.alertNotifications) private var notifications = false
    @State private var permissionDenied = false

    var body: some View {
        Form {
            Section {
                Toggle("Watch for busy and growing apps", isOn: $enabled)
            }
            Section("Busy apps") {
                Picker("CPU above", selection: $threshold) {
                    ForEach([50.0, 80, 100, 150, 200], id: \.self) { Text("\(Int($0))% of a core").tag($0) }
                }
                Picker("For at least", selection: $sustain) {
                    ForEach([30.0, 60, 120, 300, 600], id: \.self) { Text(Format.duration($0)).tag($0) }
                }
            }
            .disabled(!enabled)
            Section {
                Picker("Memory grows by", selection: $growth) {
                    ForEach([0.5, 1, 2, 4], id: \.self) { Text(Format.bytes(UInt64($0 * 1_073_741_824))).tag($0) }
                }
            } header: {
                Text("Growing apps")
            } footer: {
                Text("Measured over the last hour. The same app won't alert twice within 10 minutes.")
            }
            .disabled(!enabled)
            Section {
                Toggle("Also send macOS notifications", isOn: $notifications)
                    .disabled(!enabled || !Monitor.canNotify)
                    .onChange(of: notifications) { _, on in
                        guard on else { return }
                        Task {
                            permissionDenied = !(await Monitor.requestNotificationPermission())
                            if permissionDenied { notifications = false }
                        }
                    }
                if permissionDenied {
                    Text("Notifications are turned off for Gauge in System Settings.").font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DataSettings: View {
    @Environment(Monitor.self) private var monitor
    @State private var confirmClear = false
    @State private var includeMoments = false

    var body: some View {
        Form {
            Section("History") {
                LabeledContent("Kept for", value: "30 days, one snapshot a minute")
                LabeledContent("Earliest record") {
                    Text(monitor.store.oldestSnapshot?.formatted(date: .abbreviated, time: .shortened) ?? "None yet")
                }
                LabeledContent("Saved moments", value: "\(monitor.moments.count)")
            }
            Section {
                Button("Show Data Folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.defaultURL])
                }
                Toggle("Also delete saved moments", isOn: $includeMoments)
                Button("Clear History…", role: .destructive) { confirmClear = true }
            } footer: {
                Text("Nothing Gauge records is uploaded. There are no accounts and no analytics.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Clear recorded history?", isPresented: $confirmClear) {
            Button(includeMoments ? "Clear History and Moments" : "Clear History", role: .destructive) {
                monitor.clearHistory(includingMoments: includeMoments)
            }
        } message: {
            Text("This can't be undone.")
        }
    }
}

private struct AboutSettings: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gauge").font(.title3.weight(.semibold))
                        Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
                        Text("Free and open source, under the MIT licence.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                Link("Source code on GitHub", destination: Links.repository)
                Link("Report an issue", destination: Links.issues)
                Link("Read the licence", destination: Links.licence)
            } footer: {
                Text("Gauge makes no network requests of its own. These links open in your browser.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

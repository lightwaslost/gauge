import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview
    case cpu, memory, disk, network, storage, graphics, battery
    case apps, projects, history, alerts, moments

    var id: String { rawValue }

    static let resources: [SidebarItem] = [.cpu, .memory, .disk, .network, .storage, .graphics, .battery]
    static let workspace: [SidebarItem] = [.apps, .projects, .history, .alerts, .moments]

    var title: String {
        switch self {
        case .overview: "Overview"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .storage: "Storage"
        case .graphics: "Graphics"
        case .battery: "Battery"
        case .apps: "Apps"
        case .projects: "Projects"
        case .history: "History"
        case .alerts: "Alerts"
        case .moments: "Moments"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        case .storage: "chart.pie"
        case .graphics: "square.stack.3d.up"
        case .battery: "battery.75percent"
        case .apps: "square.grid.2x2"
        case .projects: "hammer"
        case .history: "clock.arrow.circlepath"
        case .alerts: "bell"
        case .moments: "bookmark"
        }
    }

    init(metric: Metric) {
        switch metric {
        case .cpu: self = .cpu
        case .memory: self = .memory
        case .network: self = .network
        case .disk: self = .disk
        case .gpu: self = .graphics
        case .battery: self = .battery
        }
    }
}

struct ContentView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow
    @AppStorage("section") private var storedSection: SidebarItem = .overview
    @AppStorage(Pref.onboardingVersion) private var onboardedVersion = 0
    @State private var selection: SidebarItem?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label(SidebarItem.overview.title, systemImage: SidebarItem.overview.symbol).tag(SidebarItem.overview)
                Section("Resources") {
                    ForEach(SidebarItem.resources) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section("Workspace") {
                    ForEach(SidebarItem.workspace) { item in
                        Label(item.title, systemImage: item.symbol)
                            .badge(item == .alerts ? monitor.alerts.count : 0)
                            .tag(item)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            detail(for: selection ?? .overview)
        }
        .toolbar {
            ToolbarItem(placement: .principal) { LiveIndicator() }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    monitor.togglePause()
                } label: {
                    Label(monitor.isPaused ? "Resume" : "Pause", systemImage: monitor.isPaused ? "play.fill" : "pause.fill")
                }
                .help(monitor.isPaused ? "Resume sampling" : "Pause sampling")
                .keyboardShortcut("p", modifiers: [.command, .shift])

                ExportMenu()
                SaveMomentButton(onSaved: { selection = .moments })
            }
        }
        .onAppear {
            selection = storedSection
            monitor.isWindowVisible = true
            // First launch: introduce the app before it drops you into the data.
            if onboardedVersion < Pref.currentOnboardingVersion, !DemoDriver.isEnabled {
                openWindow(id: WelcomeView.windowID)
            }
        }
        .onDisappear { monitor.isWindowVisible = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in
            monitor.isWindowVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)) { _ in
            monitor.isWindowVisible = true
        }
        .onChange(of: selection) { _, item in if let item { storedSection = item } }
        .onReceive(NotificationCenter.default.publisher(for: DemoDriver.navigate)) { note in
            if let raw = note.object as? String, let item = SidebarItem(rawValue: raw) {
                withAnimation(.easeInOut(duration: 0.25)) { selection = item }
            }
        }
        .task { DemoDriver.start(monitor: monitor) }
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .overview: OverviewView(open: { selection = $0 })
        case .cpu: CPUPage()
        case .memory: MemoryPage()
        case .disk: DiskPage()
        case .network: NetworkPage()
        case .storage: StorageView()
        case .graphics: GraphicsPage()
        case .battery: BatteryPage()
        case .apps: AppsView()
        case .projects: ProjectsView()
        case .history: HistoryView()
        case .alerts: AlertsView()
        case .moments: MomentsView()
        }
    }
}

private struct SidebarFooter: View {
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(Host.current().localizedName ?? "This Mac").font(.caption.weight(.medium)).lineLimit(1)
                Text("\(ProcessInfo.processInfo.activeProcessorCount) cores · \(Format.bytes(ProcessInfo.processInfo.physicalMemory))")
                    .font(.caption).foregroundStyle(.secondary)
                Label("Stays on this Mac", systemImage: "lock")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings")
        }
        .padding(12)
    }
}

private struct LiveIndicator: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        // No background of its own: the toolbar already draws a container behind
        // the item, and a capsule inside it reads as a double border.
        HStack(spacing: 6) {
            Circle()
                .fill(monitor.isPaused ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
            Text(monitor.isPaused ? "Paused" : "Live · every \(Int(monitor.interval))s")
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
        .padding(.horizontal, 2)
    }
}

struct SaveMomentButton: View {
    @Environment(Monitor.self) private var monitor
    var onSaved: () -> Void = {}
    @State private var confirmed = false

    var body: some View {
        Button {
            guard monitor.saveMoment() != nil else { return }
            confirmed = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                confirmed = false
            }
        } label: {
            Label(confirmed ? "Saved" : "Save Moment", systemImage: confirmed ? "checkmark" : "bookmark")
                .contentTransition(.symbolEffect(.replace))
        }
        .help("Capture what every app is doing right now (⌘S)")
        .keyboardShortcut("s", modifiers: .command)
        .contextMenu {
            Button("Show Moments", action: onSaved)
        }
    }
}

private struct ExportMenu: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        Menu {
            Button("Export Snapshot…") { exportSnapshot() }
            Button("Export History as CSV…") { exportHistory() }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .help("Export a snapshot or your recorded history")
    }

    private func exportSnapshot() {
        save(name: "Gauge Snapshot \(Self.stamp()).md", type: .plainText, contents: Report.snapshot(monitor))
    }

    private func exportHistory() {
        save(name: "Gauge History \(Self.stamp()).csv", type: .commaSeparatedText, contents: monitor.store.exportCSV())
    }

    private func save(name: String, type: UTType, contents: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func stamp() -> String {
        Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }
}

/// Plain-text report of the current state, for pasting into a bug report or chat.
enum Report {
    @MainActor
    static func snapshot(_ monitor: Monitor) -> String {
        let s = monitor.latest
        let d = monitor.details
        var lines = [
            "# Gauge snapshot — \(Date().formatted(date: .abbreviated, time: .standard))",
            "",
            "- Mac: \(d.gpuName ?? "Mac") · \(ProcessInfo.processInfo.activeProcessorCount) cores · \(Format.bytes(ProcessInfo.processInfo.physicalMemory))",
            "- macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "- CPU: \(Format.percent(s?.cpu ?? 0)) (user \(Format.percent(d.cpuUser)), system \(Format.percent(d.cpuSystem))), load \(String(format: "%.2f", d.loadAverage))",
            "- Memory: \(Format.bytes(s?.memoryUsed ?? 0)) used, pressure \(d.pressure.label), swap \(Format.bytes(d.swapUsed))",
            "- Disk: read \(Format.rate(s?.diskRead ?? 0)), write \(Format.rate(s?.diskWrite ?? 0))",
            "- Network: down \(Format.rate(s?.netIn ?? 0)), up \(Format.rate(s?.netOut ?? 0))",
            "- GPU: \(s?.gpu.map(Format.percent) ?? "n/a") · thermal \(d.thermalLabel)",
        ]
        if let battery = s?.battery {
            lines.append("- Battery: \(Format.percent(battery.level)), \(battery.isCharging ? "charging" : battery.onAC ? "on adapter" : "discharging")")
        }
        lines += ["", "| App | Processes | CPU | Memory |", "|---|---:|---:|---:|"]
        for app in monitor.apps.prefix(20) {
            lines.append("| \(app.name) | \(app.processes.count) | \(Format.cpu(app.cpu)) | \(Format.bytes(app.memory)) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

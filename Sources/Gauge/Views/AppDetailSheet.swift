import AppKit
import SwiftUI

/// Live view of one app's processes, with quit actions.
struct AppDetailSheet: View {
    @Environment(Monitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss
    let appID: String

    @State private var confirm: PendingAction?

    private enum PendingAction: Identifiable {
        case quitApp(force: Bool)
        case stopProcess(ProcessUsage)

        var id: String {
            switch self {
            case .quitApp(let force): "quit-\(force)"
            case .stopProcess(let process): "pid-\(process.pid)"
            }
        }
    }

    var body: some View {
        let app = monitor.apps.first { $0.id == appID }
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AppIconView(bundlePath: app?.bundlePath, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app?.name ?? "No longer running").font(.title2.weight(.semibold))
                    Text(app.map { "\($0.processes.count) \($0.processes.count == 1 ? "process" : "processes") · updating live" } ?? "This app quit.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }

            if let app {
                HStack(spacing: 12) {
                    StatTile(label: "CPU", value: Format.cpu(app.cpu))
                    StatTile(label: "Memory", value: Format.bytes(app.memory))
                    StatTile(label: "Disk", value: Format.rate(app.diskRead + app.diskWrite))
                }

                Text("Processes").font(.headline)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(app.processes.enumerated()), id: \.element.id) { index, process in
                            if index > 0 { Divider() }
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(process.name).lineLimit(1)
                                    Text("PID \(String(process.pid))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                                Spacer()
                                Text(Format.cpu(process.cpu)).monospacedDigit().frame(width: 64, alignment: .trailing)
                                Text(Format.bytes(process.memory)).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 84, alignment: .trailing)
                                Button("Stop", systemImage: "xmark.circle") { confirm = .stopProcess(process) }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                                    .help("Stop this process")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                        }
                    }
                    .background(.background.secondary, in: .rect(cornerRadius: 10))
                }
                .frame(maxHeight: 280)

                Text(app.bundlePath != nil
                     ? "Helpers are grouped here because they live inside this app's bundle or were started by it."
                     : "These processes don't belong to an app bundle; they're grouped by name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    if let bundle = app.bundlePath {
                        Button("Show in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bundle)])
                        }
                    }
                    Spacer()
                    Button("Force Quit…") { confirm = .quitApp(force: true) }
                    Button("Quit…") { confirm = .quitApp(force: false) }
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .confirmationDialog(title, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { action in
            switch action {
            case .quitApp(let force):
                Button(force ? "Force Quit" : "Quit", role: .destructive) {
                    if let app { quit(app, force: force) }
                }
            case .stopProcess(let process):
                Button("Stop \(process.name)", role: .destructive) { kill(process.pid, SIGTERM) }
            }
        } message: { action in
            switch action {
            case .quitApp(true): Text("The app closes immediately. Unsaved changes will be lost.")
            case .quitApp(false): Text("The app is asked to quit normally and may prompt you to save.")
            case .stopProcess: Text("Sends a normal quit signal. The parent app may restart it.")
            }
        }
    }

    private var title: String {
        switch confirm {
        case .quitApp(true): "Force quit this app?"
        case .quitApp(false): "Quit this app?"
        case .stopProcess(let process): "Stop \(process.name)?"
        case nil: ""
        }
    }

    private func quit(_ app: AppUsage, force: Bool) {
        if let bundle = app.bundlePath {
            let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == bundle }
            if !running.isEmpty {
                for app in running {
                    if force { app.forceTerminate() } else { app.terminate() }
                }
                return dismiss()
            }
        }
        // Not a registered app (or a background-only bundle): signal its processes directly.
        for process in app.processes { kill(process.pid, force ? SIGKILL : SIGTERM) }
        dismiss()
    }
}

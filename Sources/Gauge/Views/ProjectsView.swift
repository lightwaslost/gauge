import AppKit
import SwiftUI

struct ProjectsView: View {
    @Environment(Monitor.self) private var monitor
    @State private var projects: [Project] = []
    @State private var loaded = false
    @State private var pendingStop: DevProcess?
    @AppStorage(Pref.projectsIncludeIdle) private var includeIdle = true

    private let scanner = ProjectScanner()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Dev servers, databases and scripts, grouped by the folder they run in. Refreshes every 3 seconds.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Include runtimes without ports", isOn: $includeIdle).toggleStyle(.checkbox)
                }
                ForEach(visibleProjects) { project in
                    ProjectCard(project: project, usage: usage, onStop: { pendingStop = $0 })
                }
            }
            .padding(20)
        }
        .overlay {
            if loaded && projects.isEmpty {
                ContentUnavailableView(
                    "No dev processes running",
                    systemImage: "hammer",
                    description: Text("Start a dev server, database or script and it shows up here, grouped by project folder.")
                )
            } else if !loaded {
                ProgressView()
            }
        }
        .navigationTitle("Projects")
        .navigationSubtitle(subtitle)
        .task { await refreshLoop() }
        .confirmationDialog(
            "Stop \(pendingStop?.name ?? "process")?",
            isPresented: Binding(get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } }),
            presenting: pendingStop
        ) { process in
            Button("Stop PID \(String(process.pid))", role: .destructive) {
                kill(process.pid, SIGTERM)
                pendingStop = nil
            }
        } message: { process in
            Text("Sends a normal quit signal (SIGTERM). Unsaved work in that process may be lost.")
        }
    }

    private var visibleProjects: [Project] {
        guard !includeIdle else { return projects }
        return projects.compactMap { project in
            var project = project
            project.processes = project.processes.filter { !$0.ports.isEmpty }
            return project.processes.isEmpty ? nil : project
        }
    }

    private var subtitle: String {
        let ports = projects.reduce(0) { $0 + $1.ports.count }
        return "\(projects.filter { $0.root != nil }.count) projects · \(ports) listening ports"
    }

    private var usage: [Int32: ProcessUsage] {
        var result: [Int32: ProcessUsage] = [:]
        for app in monitor.apps {
            for process in app.processes { result[process.pid] = process }
        }
        return result
    }

    private func refreshLoop() async {
        let scanner = scanner
        while !Task.isCancelled {
            let result = await Task.detached(priority: .utility) { scanner.scan() }.value
            projects = result
            loaded = true
            try? await Task.sleep(for: .seconds(3))
        }
    }
}

private struct ProjectCard: View {
    let project: Project
    let usage: [Int32: ProcessUsage]
    let onStop: (DevProcess) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: project.root == nil ? "server.rack" : "folder.fill")
                    .foregroundStyle(project.root == nil ? Color.secondary : Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name).font(.headline)
                    if let root = project.root {
                        Text((root as NSString).abbreviatingWithTildeInPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                if let root = project.root {
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                }
            }
            .padding(12)

            Divider()

            ForEach(Array(project.processes.enumerated()), id: \.element.id) { index, process in
                if index > 0 { Divider().padding(.leading, 12) }
                ProcessLine(process: process, usage: usage[process.pid], onStop: { onStop(process) })
            }
        }
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}

private struct ProcessLine: View {
    let process: DevProcess
    let usage: ProcessUsage?
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(process.runtime)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: .capsule)
                .frame(width: 96, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(process.name)
                    Text(String(process.pid)).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                }
                if !process.command.isEmpty {
                    Text(process.command)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 4) {
                ForEach(process.ports.prefix(4), id: \.self) { port in
                    Button(":\(String(port))") {
                        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption.monospacedDigit())
                    .help("Open http://localhost:\(String(port))")
                }
            }

            Text(usage.map { Format.cpu($0.cpu) } ?? "—")
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
            Text(usage.map { Format.bytes($0.memory) } ?? "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            Button("Stop", systemImage: "stop.circle", action: onStop)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Stop this process")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

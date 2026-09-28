import SwiftUI

/// A row in the apps table: an app, or one of its processes.
struct UsageRow: Identifiable {
    let id: String
    let name: String
    let bundlePath: String?
    let pid: Int32?
    let cpu: Double
    let memory: UInt64
    let disk: Double
    let processCount: Int
    var children: [UsageRow]?

    init(app: AppUsage) {
        id = app.id
        name = app.name
        bundlePath = app.bundlePath
        pid = nil
        cpu = app.cpu
        memory = app.memory
        disk = app.diskRead + app.diskWrite
        processCount = app.processes.count
        // A lone process whose name matches its app needs no disclosure triangle.
        let processes = app.processes
        children = processes.count == 1 && processes[0].name == app.name
            ? nil
            : processes.map(UsageRow.init(process:))
    }

    init(process: ProcessUsage) {
        id = "pid-\(process.pid)"
        name = process.name
        bundlePath = nil
        pid = process.pid
        cpu = process.cpu
        memory = process.memory
        disk = process.diskRead + process.diskWrite
        processCount = 1
        children = nil
    }
}

struct AppsView: View {
    @Environment(Monitor.self) private var monitor
    @State private var sortOrder = [KeyPathComparator(\UsageRow.cpu, order: .reverse)]
    @State private var search = ""
    @State private var selection: UsageRow.ID?

    var body: some View {
        Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 8) {
                    if row.pid == nil {
                        AppIconView(bundlePath: row.bundlePath)
                    }
                    Text(row.name).lineLimit(1)
                    if let pid = row.pid {
                        Text(String(pid)).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
            }
            .width(min: 220, ideal: 300)

            TableColumn("CPU", value: \.cpu) { row in
                Text(Format.cpu(row.cpu)).monospacedDigit()
            }
            .width(min: 60, ideal: 70)
            .alignment(.trailing)

            TableColumn("Memory", value: \.memory) { row in
                Text(Format.bytes(row.memory)).monospacedDigit()
            }
            .width(min: 80, ideal: 90)
            .alignment(.trailing)

            TableColumn("Disk", value: \.disk) { row in
                Text(row.disk > 0 ? Format.rate(row.disk) : "—").monospacedDigit()
            }
            .width(min: 80, ideal: 90)
            .alignment(.trailing)

            TableColumn("Processes", value: \.processCount) { row in
                Text(row.pid == nil ? "\(row.processCount)" : "").monospacedDigit()
            }
            .width(min: 60, ideal: 70)
            .alignment(.trailing)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter apps")
        .navigationTitle("Apps")
        .navigationSubtitle("\(monitor.apps.count) apps · \(monitor.apps.reduce(0) { $0 + $1.processes.count }) processes")
        .safeAreaInset(edge: .bottom) {
            Text("Processes owned by other users (for example, system daemons) aren’t shown.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
        }
    }

    private var rows: [UsageRow] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return monitor.apps
            .filter { app in
                query.isEmpty
                    || app.name.localizedCaseInsensitiveContains(query)
                    || app.processes.contains { $0.name.localizedCaseInsensitiveContains(query) }
            }
            .map(UsageRow.init(app:))
            .map { row in
                var row = row
                row.children = row.children?.sorted(using: sortOrder)
                return row
            }
            .sorted(using: sortOrder)
    }
}

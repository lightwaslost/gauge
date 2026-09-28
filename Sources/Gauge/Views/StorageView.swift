import AppKit
import Charts
import SwiftUI

struct StorageView: View {
    @Environment(Monitor.self) private var monitor
    @State private var report: StorageReport? = StorageScanner.loadCached()
    @State private var scanning = false
    @State private var progress: (done: Int, total: Int, current: String) = (0, 0, "")
    @State private var scanTask: Task<Void, Never>?
    @State private var search = ""
    @State private var trail: [String] = []   // drill-down stack of folders

    var body: some View {
        PageScroll {
            PageHeader(title: "Storage", subtitle: "Which folders are taking up your disk.")
            volumeHeader
            if scanning {
                Panel {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                        Text("Measuring folders… \(progress.done) of \(progress.total)")
                    } currentValueLabel: {
                        Text(progress.current).lineLimit(1)
                    }
                    Button("Cancel") { scanTask?.cancel() }
                }
            }
            if let report {
                if trail.isEmpty { categories(report) }
                folders(report)
            } else if !scanning {
                Panel {
                    ContentUnavailableView {
                        Label("Not measured yet", systemImage: "externaldrive")
                    } description: {
                        Text("A full scan reads every file under your home folder and Applications. It runs in the background and can take a few minutes.")
                    } actions: {
                        Button("Scan Now") { scanHome() }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .navigationTitle("Storage")
        .onDisappear { scanTask?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: DemoDriver.scanStorage)) { _ in scanHome() }
    }

    // MARK: Sections

    private var volumeHeader: some View {
        let root = monitor.details.volumes.first { $0.path == "/" } ?? monitor.details.volumes.first
        return Panel {
            HStack(alignment: .center) {
                Image(systemName: "internaldrive.fill").font(.title).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(root?.name ?? "Startup disk").font(.headline)
                    if let root {
                        Text("\(Format.bytes(UInt64(root.used))) used · \(Format.bytes(UInt64(root.available))) free of \(Format.bytes(UInt64(root.total)))")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    if let report {
                        Text("Measured \(report.date.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Measure Folder…") { chooseFolder() }
                        Button(report == nil ? "Scan" : "Rescan") { rescan() }
                            .buttonStyle(.borderedProminent)
                    }
                    .disabled(scanning)
                }
            }
            if let root {
                ProgressView(value: Double(root.used), total: Double(max(root.total, 1)))
            }
        }
    }

    private func categories(_ report: StorageReport) -> some View {
        let slices = StorageCategory.allCases
            .map { ($0, report.bytes(in: $0)) }
            .filter { $0.1 > 0 }
        return Panel {
            HStack(alignment: .center, spacing: 28) {
                Chart(slices, id: \.0) { slice in
                    SectorMark(angle: .value("Size", slice.1), innerRadius: .ratio(0.64), angularInset: 1.2)
                        .foregroundStyle(slice.0.color)
                        .cornerRadius(3)
                }
                .chartBackground { _ in
                    VStack(spacing: 0) {
                        Text(Format.bytes(UInt64(report.total))).font(.title3.weight(.semibold)).monospacedDigit()
                        Text("measured").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 180, height: 180)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                    ForEach(slices, id: \.0) { category, bytes in
                        HStack(spacing: 8) {
                            Image(systemName: category.symbol).foregroundStyle(category.color).frame(width: 18)
                            Text(category.title).lineLimit(1)
                            Spacer()
                            Text(Format.bytes(UInt64(bytes))).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("Categories come from folder locations, not Apple's own labels. Clones, hard links and snapshots can make totals differ from Finder.")
                .font(.caption).foregroundStyle(.tertiary)
            if report.unreadable > 0 {
                HStack {
                    Label("\(report.unreadable) items couldn't be read.", systemImage: "lock")
                    Button("Grant Full Disk Access…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    .buttonStyle(.link)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func folders(_ report: StorageReport) -> some View {
        let query = search.trimmingCharacters(in: .whitespaces)
        let rows = report.folders.filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) }
        let largest = Double(report.folders.first?.bytes ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                if !trail.isEmpty {
                    Button("Back", systemImage: "chevron.left") { goBack() }
                        .labelStyle(.iconOnly)
                        .disabled(scanning)
                }
                Text(trail.isEmpty ? "Largest folders" : (report.scope as NSString).abbreviatingWithTildeInPath)
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.prefix(80).enumerated()), id: \.element.id) { index, folder in
                    if index > 0 { Divider().padding(.leading, 12) }
                    FolderRow(folder: folder, fraction: Double(folder.bytes) / max(largest, 1)) {
                        drill(into: folder.path)
                    }
                    .disabled(scanning)
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 12))
        }
    }

    // MARK: Actions

    private func rescan() {
        if let scope = trail.last { measure(children: scope) } else { scanHome() }
    }

    private func scanHome() {
        trail = []
        run(StorageScanner.defaultFolders(), scope: StorageScanner.home, cache: true)
    }

    private func drill(into path: String) {
        trail.append(path)
        measure(children: path)
    }

    private func goBack() {
        trail.removeLast()
        if let scope = trail.last { measure(children: scope) } else { report = StorageScanner.loadCached() }
    }

    private func measure(children path: String) {
        run(StorageScanner.children(of: path), scope: path, cache: false)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Measure"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        trail = [url.path]
        measure(children: url.path)
    }

    private func run(_ folders: [String], scope: String, cache: Bool) {
        scanTask?.cancel()
        scanning = true
        progress = (0, folders.count, "")
        scanTask = Task {
            let result = await Task.detached(priority: .utility) {
                await StorageScanner.scan(folders, scope: scope) { done, total, current in
                    Task { @MainActor in progress = (done, total, current) }
                }
            }.value
            if !Task.isCancelled {
                report = result
                if cache { StorageScanner.save(result) }
            }
            scanning = false
        }
    }
}

private struct FolderRow: View {
    let folder: FolderSize
    let fraction: Double
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: folder.category.symbol)
                .foregroundStyle(folder.category.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(folder.name).lineLimit(1)
                    Text((folder.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if folder.unreadable > 0 {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.orange)
                            .help("\(folder.unreadable) items couldn't be read")
                    }
                    Text(Format.bytes(UInt64(folder.bytes))).monospacedDigit()
                }
                GeometryReader { proxy in
                    Capsule().fill(folder.category.color.opacity(0.7))
                        .frame(width: max(2, proxy.size.width * fraction))
                }
                .frame(height: 4)
            }
            Button("Open", systemImage: "chevron.right", action: open)
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help("Break this folder down")
            Button("Show in Finder", systemImage: "magnifyingglass") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)])
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

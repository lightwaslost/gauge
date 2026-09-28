import Charts
import SwiftUI

// MARK: Layout primitives

struct PageHeader: View {
    @Environment(Monitor.self) private var monitor
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.largeTitle.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill()
        }
    }
}

/// Overall health: the worse of memory pressure and thermal state.
struct StatusPill: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let (label, color) = status
        Label(label, systemImage: "circle.fill")
            .labelStyle(PillLabelStyle(color: color))
            .help("Memory pressure: \(monitor.details.pressure.label) · Thermal: \(monitor.details.thermalLabel)")
    }

    private var status: (String, Color) {
        let details = monitor.details
        if details.pressure == .critical || details.thermal == .critical || details.thermal == .serious {
            return ("Under strain", .red)
        }
        if details.pressure == .warning || details.thermal == .fair {
            return ("Busy", .orange)
        }
        return ("Healthy", .green)
    }
}

struct PillLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 6)).foregroundStyle(color)
            configuration.title.font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: .capsule)
    }
}

struct Panel<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}

struct StatTile: View {
    let label: String
    let value: String
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}

struct TileRow<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 12) { content }
    }
}

struct PageScroll<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 1200, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: Live chart

enum LiveWindow: Int, CaseIterable, Identifiable {
    case one = 60, five = 300, ten = 600
    var id: Int { rawValue }
    var label: String { "\(rawValue / 60)m" }
}

/// Live chart over the in-memory buffer, with a window picker and hover readout.
struct LiveChartCard: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage("liveWindow") private var window: LiveWindow = .five
    @State private var hovered: Date?

    let metric: Metric
    var title: String? = nil

    var body: some View {
        let samples = visibleSamples
        let primary = samples.compactMap { metric.values($0).first?.value }
        let selected = hovered.flatMap { date in
            samples.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        }
        let shown = selected ?? samples.last

        Panel {
            HStack {
                Text(title ?? "\(metric.title) activity").font(.headline)
                Spacer()
                Picker("Window", selection: $window) {
                    ForEach(LiveWindow.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selected == nil ? "Now" : selected!.date.formatted(date: .omitted, time: .standard))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(shown.flatMap { metric.values($0).first.map { metric.format($0.value) } } ?? "—")
                            .font(.system(size: 30, weight: .semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    if let shown, metric.values(shown).count > 1, let second = metric.values(shown).last {
                        statLine(second.series, metric.format(second.value))
                    }
                    if !primary.isEmpty {
                        statLine("Average", metric.format(primary.reduce(0, +) / Double(primary.count)))
                        statLine("Peak", metric.format(primary.max() ?? 0))
                    }
                }
                .frame(width: 150, alignment: .leading)

                chart(samples, selected: selected)
                    .frame(height: 170)
            }

            HStack {
                ForEach(metric.values(samples.last ?? placeholder).map(\.series), id: \.self) { series in
                    Label(series, systemImage: "line.diagonal")
                        .font(.caption)
                        .foregroundStyle(metric.color(for: series))
                }
                Spacer()
                Text("Last \(window.label) · hover to inspect").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var visibleSamples: [SystemSample] {
        let cutoff = Date().addingTimeInterval(-Double(window.rawValue))
        return monitor.samples.filter { $0.date >= cutoff }
    }

    private var placeholder: SystemSample {
        SystemSample(date: .now, cpu: 0, memoryUsed: 0, memoryTotal: 1, netIn: 0, netOut: 0, diskRead: 0, diskWrite: 0, gpu: 0, battery: nil)
    }

    private func statLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }

    private func chart(_ samples: [SystemSample], selected: SystemSample?) -> some View {
        Chart {
            ForEach(metric.points(samples)) { point in
                AreaMark(x: .value("Time", point.date), y: .value(metric.title, point.value), stacking: .unstacked)
                    .foregroundStyle(by: .value("Series", point.series))
                    .opacity(0.14)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.date), y: .value(metric.title, point.value))
                    .foregroundStyle(by: .value("Series", point.series))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: metric.isSecondary(point.series) ? [4, 3] : []))
            }
            if let selected {
                RuleMark(x: .value("Selected", selected.date)).foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .chartForegroundStyleScale { (series: String) in metric.color(for: series) }
        .chartLegend(.hidden)
        .chartXScale(domain: Date().addingTimeInterval(-Double(window.rawValue))...Date())
        .modifier(OptionalYDomain(domain: metric.domain))
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine()
                AxisValueLabel { if let number = value.as(Double.self) { Text(metric.format(number)) } }
            }
        }
        .chartXSelection(value: $hovered)
    }
}

extension Metric {
    func isSecondary(_ series: String) -> Bool { series == "Upload" || series == "Write" }

    func color(for series: String) -> Color {
        switch series {
        case "Upload": .green
        case "Write": .mint
        default: color
        }
    }
}

// MARK: Memory breakdown

struct MemoryBreakdown: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let details = monitor.details
        let total = Double(monitor.latest?.memoryTotal ?? ProcessInfo.processInfo.physicalMemory)
        let parts: [(String, UInt64, Color)] = [
            ("App memory", details.memoryActive, .blue),
            ("Wired", details.memoryWired, .orange),
            ("Compressed", details.memoryCompressed, .purple),
            ("Cached files", details.memoryCached, .gray),
        ]
        Panel {
            HStack {
                Text("Memory").font(.headline)
                Spacer()
                Text(details.pressure.label).font(.caption).foregroundStyle(details.pressure == .normal ? Color.secondary : Color.orange)
            }
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { part in
                        Rectangle()
                            .fill(part.2.gradient)
                            .frame(width: max(0, proxy.size.width * Double(part.1) / max(total, 1) - 2))
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(.rect(cornerRadius: 4))
                .background(.quaternary, in: .rect(cornerRadius: 4))
            }
            .frame(height: 10)
            ForEach(parts, id: \.0) { part in
                HStack {
                    Circle().fill(part.2).frame(width: 7, height: 7)
                    Text(part.0)
                    Spacer()
                    Text(Format.bytes(part.1)).monospacedDigit()
                }
                .font(.callout)
            }
            Divider()
            HStack {
                Text("Swap used").foregroundStyle(.secondary)
                Spacer()
                Text(Format.bytes(details.swapUsed)).monospacedDigit()
            }
            .font(.callout)
        }
    }
}

// MARK: App activity list

enum AppColumn: String, CaseIterable, Identifiable {
    case processes, cpu, memory, read, write

    var id: String { rawValue }

    var title: String {
        switch self {
        case .processes: "Processes"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .read: "Read"
        case .write: "Write"
        }
    }

    func value(_ app: AppUsage) -> Double {
        switch self {
        case .processes: Double(app.processes.count)
        case .cpu: app.cpu
        case .memory: Double(app.memory)
        case .read: app.diskRead
        case .write: app.diskWrite
        }
    }

    func text(_ app: AppUsage) -> String {
        switch self {
        case .processes: "\(app.processes.count)"
        case .cpu: Format.cpu(app.cpu)
        case .memory: Format.bytes(app.memory)
        case .read: Format.rate(app.diskRead)
        case .write: Format.rate(app.diskWrite)
        }
    }
}

/// Flat, sortable list of apps. Click a row for its processes and actions.
struct AppActivityList: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage(Pref.showBackground) private var showBackground = false
    @State private var search = ""
    @State private var sort: AppColumn
    @State private var selectedApp: AppSelection?

    let title: String
    let columns: [AppColumn]
    var limit: Int? = nil

    init(title: String = "Apps", columns: [AppColumn] = [.processes, .cpu, .memory], sortedBy sort: AppColumn = .cpu, limit: Int? = nil) {
        self.title = title
        self.columns = columns
        self.limit = limit
        _sort = State(initialValue: sort)
    }

    var body: some View {
        let apps = filtered
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(title).font(.headline)
                Text("\(apps.count)")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(.quaternary, in: .capsule)
                Spacer()
                TextField("Filter", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                Toggle("Include background", isOn: $showBackground)
                    .toggleStyle(.checkbox)
                    .help("Also show command-line tools and services that aren't part of an app")
            }

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(columns) { column in
                        Button {
                            sort = column
                        } label: {
                            HStack(spacing: 2) {
                                Text(column.title)
                                if sort == column { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(width: column == .processes ? 76 : 90, alignment: .trailing)
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                ForEach(Array((limit.map { Array(apps.prefix($0)) } ?? apps).enumerated()), id: \.element.id) { index, app in
                    Divider().padding(.leading, 12)
                    Button {
                        selectedApp = AppSelection(id: app.id)
                    } label: {
                        HStack(spacing: 0) {
                            HStack(spacing: 9) {
                                AppIconView(bundlePath: app.bundlePath, size: 20)
                                Text(app.name).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(columns) { column in
                                Text(column.text(app))
                                    .monospacedDigit()
                                    .foregroundStyle(column == sort ? .primary : .secondary)
                                    .frame(width: column == .processes ? 76 : 90, alignment: .trailing)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(.rect)
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 12))

            Text("CPU is a share of one core, so busy apps can pass 100%. Memory is each app's physical footprint.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .sheet(item: $selectedApp) { selection in
            AppDetailSheet(appID: selection.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: DemoDriver.openApp)) { _ in
            if let first = filtered.first { selectedApp = AppSelection(id: first.id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: DemoDriver.closeSheet)) { _ in
            selectedApp = nil
        }
    }

    private var filtered: [AppUsage] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return monitor.apps
            .filter { showBackground || $0.bundlePath != nil }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { sort.value($0) == sort.value($1) ? $0.name < $1.name : sort.value($0) > sort.value($1) }
    }
}

struct AppSelection: Identifiable, Hashable {
    let id: String
}

struct RowButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : hovering ? Color.primary.opacity(0.04) : .clear)
            .onHover { hovering = $0 }
    }
}

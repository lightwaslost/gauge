import Charts
import SwiftUI

enum HistoryRange: String, CaseIterable, Identifiable {
    case hour = "1H", twelveHours = "12H", day = "24H", week = "7D", month = "30D"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .hour: 3600
        case .twelveHours: 12 * 3600
        case .day: 24 * 3600
        case .week: 7 * 24 * 3600
        case .month: HistoryStore.retention
        }
    }
}

/// One line per chart; network and disk directions are separate choices here.
enum HistoryMetric: String, CaseIterable, Identifiable {
    case cpu, memory, gpu, download, upload, diskRead, diskWrite, battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .download: "Download"
        case .upload: "Upload"
        case .diskRead: "Disk read"
        case .diskWrite: "Disk write"
        case .battery: "Battery"
        }
    }

    var base: Metric {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .gpu: .gpu
        case .download, .upload: .network
        case .diskRead, .diskWrite: .disk
        case .battery: .battery
        }
    }

    func value(_ sample: SystemSample) -> Double? {
        switch self {
        case .cpu: sample.cpu
        case .memory: sample.memoryFraction
        case .gpu: sample.gpu
        case .download: sample.netIn
        case .upload: sample.netOut
        case .diskRead: sample.diskRead
        case .diskWrite: sample.diskWrite
        case .battery: sample.battery?.level
        }
    }
}

struct HistoryView: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage("history.range") private var range: HistoryRange = .twelveHours
    @AppStorage("history.metric") private var metric: HistoryMetric = .cpu
    @State private var series: [SystemSample] = []
    @State private var topApps: [AppHistory] = []
    @State private var hovered: Date?
    @State private var appsAtTime: (date: Date, apps: [AppSnapshot])?

    var body: some View {
        PageScroll {
            PageHeader(title: "History", subtitle: "Up to 30 days, one snapshot a minute, kept on this Mac.")
            HStack {
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                Spacer()
                Picker("Metric", selection: $metric) {
                    ForEach(HistoryMetric.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 180)
            }

            chartCard

            HStack(alignment: .top, spacing: 12) {
                Panel {
                    HStack {
                        Text("Apps at \(appsAtTime.map { $0.date.formatted(date: .abbreviated, time: .shortened) } ?? "the selected time")")
                            .font(.headline)
                        Spacer()
                        Text("Hover the chart to move").font(.caption).foregroundStyle(.tertiary)
                    }
                    if let apps = appsAtTime?.apps, !apps.isEmpty {
                        ForEach(apps.prefix(10)) { app in
                            HStack(spacing: 8) {
                                AppIconView(bundlePath: app.bundlePath, size: 18)
                                Text(app.name).lineLimit(1)
                                Spacer()
                                Text(Format.cpu(app.cpu)).monospacedDigit().frame(width: 60, alignment: .trailing)
                                Text(Format.bytes(app.memory)).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 80, alignment: .trailing)
                            }
                            .font(.callout)
                        }
                    } else {
                        Text("No snapshot recorded near that time.").foregroundStyle(.secondary)
                    }
                }

                Panel {
                    Text("Heaviest in this range").font(.headline)
                    if topApps.isEmpty {
                        Text("Nothing recorded yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(topApps.prefix(10)) { app in
                            HStack(spacing: 8) {
                                AppIconView(bundlePath: app.bundlePath, size: 18)
                                Text(app.name).lineLimit(1)
                                Spacer()
                                Text(Format.duration(app.cpuSeconds)).monospacedDigit().frame(width: 70, alignment: .trailing)
                                    .help("Total CPU time")
                                Text(Format.bytes(app.peakMemory)).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 80, alignment: .trailing)
                                    .help("Peak memory")
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
        .navigationTitle("History")
        .task(id: "\(range.rawValue)-\(monitor.historyRevision)") { reload() }
        .task(id: hovered.map { Int($0.timeIntervalSince1970 / 60) }) {
            appsAtTime = monitor.store.apps(near: hovered ?? series.last?.date ?? Date(), tolerance: max(180, range.seconds / 300))
        }
    }

    private var chartCard: some View {
        let points = series.compactMap { sample in metric.value(sample).map { (sample.date, $0) } }
        let selected = hovered.flatMap { date in points.min { abs($0.0.timeIntervalSince(date)) < abs($1.0.timeIntervalSince(date)) } }
        let base = metric.base
        let color = base.color(for: metric == .upload ? "Upload" : metric == .diskWrite ? "Write" : base.title)
        return Panel {
            HStack(alignment: .firstTextBaseline) {
                Label(metric.title, systemImage: base.symbol).font(.headline)
                Spacer()
                if let selected {
                    Text(selected.0.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    Text(base.format(selected.1)).monospacedDigit().fontWeight(.semibold)
                } else {
                    Text("\(points.count) points").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .font(.callout)

            if points.isEmpty {
                ContentUnavailableView(
                    "No history yet",
                    systemImage: "clock",
                    description: Text("Gauge records a snapshot every minute while it's running. Check back soon.")
                )
                .frame(height: 260)
            } else {
                Chart {
                    ForEach(points, id: \.0) { point in
                        AreaMark(x: .value("Time", point.0), y: .value(metric.title, point.1))
                            .foregroundStyle(color.opacity(0.14))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", point.0), y: .value(metric.title, point.1))
                            .foregroundStyle(color)
                            .interpolationMethod(.monotone)
                    }
                    ForEach(monitor.moments.filter { $0.date >= rangeStart }) { moment in
                        RuleMark(x: .value("Moment", moment.date))
                            .foregroundStyle(.yellow.opacity(0.8))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .top) {
                                Image(systemName: "bookmark.fill").font(.caption2).foregroundStyle(.yellow)
                            }
                    }
                    if let selected {
                        RuleMark(x: .value("Selected", selected.0)).foregroundStyle(.secondary.opacity(0.5))
                        PointMark(x: .value("Selected", selected.0), y: .value(metric.title, selected.1))
                            .foregroundStyle(color)
                    }
                }
                .chartXScale(domain: rangeStart...Date())
                .modifier(OptionalYDomain(domain: base.domain))
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine()
                        AxisValueLabel { if let number = value.as(Double.self) { Text(base.format(number)) } }
                    }
                }
                .chartXSelection(value: $hovered)
                .frame(height: 260)
            }
        }
    }

    private var rangeStart: Date { Date().addingTimeInterval(-range.seconds) }

    private func reload() {
        let end = Date()
        let start = end.addingTimeInterval(-range.seconds)
        series = monitor.store.series(from: start, to: end, maxPoints: 480)
        topApps = monitor.store.topApps(from: start, to: end)
        if hovered == nil { appsAtTime = monitor.store.apps(near: series.last?.date ?? end) }
    }
}

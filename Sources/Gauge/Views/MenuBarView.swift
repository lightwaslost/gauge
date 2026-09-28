import SwiftUI

struct MenuBarLabel: View {
    let monitor: Monitor
    @AppStorage(Pref.menuBarMetric) private var metric: Metric = .cpu
    @AppStorage(Pref.menuBarStyle) private var style: MenuBarStyle = .iconAndValue

    var body: some View {
        HStack(spacing: 3) {
            if style != .valueOnly {
                Image(systemName: metric == .cpu ? "gauge.with.dots.needle.33percent" : metric.symbol)
            }
            if style != .iconOnly {
                Text(value).monospacedDigit()
            }
        }
    }

    private var value: String {
        guard let sample = monitor.latest else { return "—" }
        switch metric {
        case .network: return "↓" + Format.rate(sample.netIn)
        case .disk: return Format.rate(sample.diskRead + sample.diskWrite)
        case .memory: return Format.percent(sample.memoryFraction)
        default: return metric.headline(sample)
        }
    }
}

struct MenuBarView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                stat(.cpu)
                stat(.memory)
                stat(.gpu)
            }

            Sparkline(metric: .cpu, samples: monitor.samples).frame(height: 44)

            Divider()

            VStack(spacing: 0) {
                ForEach(monitor.apps.prefix(4)) { app in
                    HStack(spacing: 8) {
                        AppIconView(bundlePath: app.bundlePath, size: 16)
                        Text(app.name).lineLimit(1)
                        Spacer()
                        Text(Format.cpu(app.cpu)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()

            HStack {
                Button(saved ? "Saved" : "Save Moment") {
                    if monitor.saveMoment() != nil {
                        saved = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            saved = false
                        }
                    }
                }
                Spacer()
                Button("Open Gauge") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .keyboardShortcut(.defaultAction)
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit Gauge")
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func stat(_ metric: Metric) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metric.title).font(.caption).foregroundStyle(.secondary)
            Text(metric.headline(monitor.latest))
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

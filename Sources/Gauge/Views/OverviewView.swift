import SwiftUI

struct OverviewView: View {
    @Environment(Monitor.self) private var monitor
    var open: (SidebarItem) -> Void = { _ in }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        PageScroll {
            PageHeader(title: "Overview", subtitle: "Everything your Mac is doing, at a glance.")

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Metric.allCases) { metric in
                    Button { open(SidebarItem(metric: metric)) } label: {
                        MetricCard(metric: metric, samples: recentSamples)
                    }
                    .buttonStyle(CardButtonStyle())
                    .help("Open \(metric.title)")
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    LiveChartCard(metric: .cpu, title: "CPU activity")
                    MemoryBreakdown().frame(width: 300)
                }
                VStack(spacing: 12) {
                    LiveChartCard(metric: .cpu, title: "CPU activity")
                    MemoryBreakdown()
                }
            }

            AppActivityList(title: "Apps & activity", sortedBy: .cpu)
        }
        .navigationTitle("Overview")
    }

    /// Cards show the last five minutes regardless of the chart window setting.
    private var recentSamples: [SystemSample] {
        let cutoff = Date().addingTimeInterval(-300)
        return monitor.samples.filter { $0.date >= cutoff }
    }
}

struct CardButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(hovering ? 0.5 : 0), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

struct MetricCard: View {
    let metric: Metric
    let samples: [SystemSample]

    var body: some View {
        let latest = samples.last
        VStack(alignment: .leading, spacing: 8) {
            Label(metric.title, systemImage: metric.symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(metric.headline(latest))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer()
                Text(metric.detail(latest))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Sparkline(metric: metric, samples: samples)
                .frame(height: 50)
        }
        .padding(14)
        .foregroundStyle(.primary)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .contentShape(.rect(cornerRadius: 12))
    }
}

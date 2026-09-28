import Charts
import SwiftUI

struct ChartPoint: Identifiable {
    let date: Date
    let series: String
    let value: Double
    var id: String { "\(series)-\(date.timeIntervalSince1970)" }
}

extension Metric {
    func points(_ samples: [SystemSample]) -> [ChartPoint] {
        samples.flatMap { sample in
            values(sample).map { ChartPoint(date: sample.date, series: $0.series, value: $0.value) }
        }
    }

    /// Primary series uses the metric color, the secondary a lighter tint of it.
    var seriesStyles: KeyValuePairs<String, Color> {
        switch self {
        case .network: ["Download": color, "Upload": color.opacity(0.45)]
        case .disk: ["Read": color, "Write": color.opacity(0.45)]
        default: [title: color, "Used": color, "Charge": color]
        }
    }
}

/// Compact area chart used on overview cards.
struct Sparkline: View {
    let metric: Metric
    let samples: [SystemSample]

    var body: some View {
        let points = metric.points(samples)
        Chart(points) { point in
            AreaMark(
                x: .value("Time", point.date),
                y: .value(metric.title, point.value),
                stacking: .unstacked
            )
            .foregroundStyle(by: .value("Series", point.series))
            .opacity(0.18)
            .interpolationMethod(.monotone)

            LineMark(x: .value("Time", point.date), y: .value(metric.title, point.value))
                .foregroundStyle(by: .value("Series", point.series))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartForegroundStyleScale(domain: seriesDomain(points), range: seriesRange(points))
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .modifier(OptionalYDomain(domain: metric.domain))
        .animation(.easeOut(duration: 0.25), value: samples.last?.date)
    }

    private func seriesDomain(_ points: [ChartPoint]) -> [String] {
        Array(Set(points.map(\.series))).sorted { order($0) < order($1) }
    }

    private func seriesRange(_ points: [ChartPoint]) -> [Color] {
        seriesDomain(points).map(color(for:))
    }

    private func order(_ series: String) -> Int {
        ["Download", "Read"].contains(series) ? 0 : 1
    }

    private func color(for series: String) -> Color {
        metric.seriesStyles.first { $0.key == series }?.value ?? metric.color
    }
}

struct OptionalYDomain: ViewModifier {
    let domain: ClosedRange<Double>?

    func body(content: Content) -> some View {
        if let domain {
            content.chartYScale(domain: domain)
        } else {
            content
        }
    }
}

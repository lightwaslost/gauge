import AppKit
import SwiftUI

enum Format {
    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// CPU as percent of one core, e.g. "143.2%".
    static func cpu(_ percent: Double) -> String {
        percent < 10
            ? String(format: "%.1f%%", percent)
            : String(format: "%.0f%%", percent)
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond.rounded()), countStyle: .file) + "/s"
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? ""
    }
}

/// A chartable resource. Some metrics carry two series (in/out, read/write).
enum Metric: String, CaseIterable, Identifiable {
    case cpu, memory, network, disk, gpu, battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .network: "Network"
        case .disk: "Disk"
        case .gpu: "GPU"
        case .battery: "Battery"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .network: "network"
        case .disk: "internaldrive"
        case .gpu: "square.stack.3d.up"
        case .battery: "battery.75percent"
        }
    }

    var color: Color {
        switch self {
        case .cpu: .blue
        case .memory: .purple
        case .network: .teal
        case .disk: .orange
        case .gpu: .pink
        case .battery: .green
        }
    }

    /// Fixed y-domain for fractional metrics; nil lets the chart scale.
    var domain: ClosedRange<Double>? {
        switch self {
        case .cpu, .memory, .gpu, .battery: 0...1
        case .network, .disk: nil
        }
    }

    var isRate: Bool { self == .network || self == .disk }

    func values(_ sample: SystemSample) -> [(series: String, value: Double)] {
        switch self {
        case .cpu: [("CPU", sample.cpu)]
        case .memory: [("Used", sample.memoryFraction)]
        case .network: [("Download", sample.netIn), ("Upload", sample.netOut)]
        case .disk: [("Read", sample.diskRead), ("Write", sample.diskWrite)]
        case .gpu: sample.gpu.map { [("GPU", $0)] } ?? []
        case .battery: sample.battery.map { [("Charge", $0.level)] } ?? []
        }
    }

    func format(_ value: Double) -> String {
        isRate ? Format.rate(value) : Format.percent(value)
    }

    func headline(_ sample: SystemSample?) -> String {
        guard let sample else { return "—" }
        switch self {
        case .cpu: return Format.percent(sample.cpu)
        case .memory: return Format.bytes(sample.memoryUsed)
        case .network: return "↓ " + Format.rate(sample.netIn)
        case .disk: return "R " + Format.rate(sample.diskRead)
        case .gpu: return sample.gpu.map(Format.percent) ?? "Unavailable"
        case .battery: return sample.battery.map { Format.percent($0.level) } ?? "No battery"
        }
    }

    func detail(_ sample: SystemSample?) -> String {
        guard let sample else { return " " }
        switch self {
        case .cpu: return "\(ProcessInfo.processInfo.activeProcessorCount) cores"
        case .memory: return "of \(Format.bytes(sample.memoryTotal)) · \(Format.percent(sample.memoryFraction))"
        case .network: return "↑ " + Format.rate(sample.netOut)
        case .disk: return "W " + Format.rate(sample.diskWrite)
        case .gpu: return sample.gpu == nil ? "Not reported by this Mac" : "Device utilization"
        case .battery:
            guard let battery = sample.battery else { return "Desktop Mac" }
            return battery.isCharging ? "Charging" : battery.onAC ? "On power adapter" : "On battery"
        }
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    private static let executable = NSWorkspace.shared.icon(for: .unixExecutable)

    static func icon(for bundlePath: String?) -> NSImage {
        guard let bundlePath else { return executable }
        if let cached = cache[bundlePath] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: bundlePath)
        cache[bundlePath] = icon
        return icon
    }
}

struct AppIconView: View {
    let bundlePath: String?
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: AppIcons.icon(for: bundlePath))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

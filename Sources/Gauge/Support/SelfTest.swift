import Foundation

/// `Gauge --self-test`: runs every sampler headlessly and prints what it read.
/// Handy for checking a new Mac or macOS version without opening the UI.
enum SelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--self-test") else { return }

        let system = SystemSampler()
        let processes = ProcessSampler()
        _ = system.sample()
        _ = processes.sample()
        Thread.sleep(forTimeInterval: 2)
        let (sample, details) = system.sample()
        let apps = processes.sample()

        func line(_ label: String, _ value: String) { print(label.padding(toLength: 18, withPad: " ", startingAt: 0) + value) }
        line("CPU", "\(Format.percent(sample.cpu)) (user \(Format.percent(details.cpuUser)), system \(Format.percent(details.cpuSystem))), load \(String(format: "%.2f", details.loadAverage))")
        line("Memory", "\(Format.bytes(sample.memoryUsed)) of \(Format.bytes(sample.memoryTotal)), pressure \(details.pressure.label)")
        line("  breakdown", "app \(Format.bytes(details.memoryActive)), wired \(Format.bytes(details.memoryWired)), compressed \(Format.bytes(details.memoryCompressed)), swap \(Format.bytes(details.swapUsed))")
        line("Network", "↓ \(Format.rate(sample.netIn)) ↑ \(Format.rate(sample.netOut)), \(details.interfaces.count) interfaces (\(details.interfaces.filter(\.isPhysical).count) physical)")
        line("Disk", "R \(Format.rate(sample.diskRead)) W \(Format.rate(sample.diskWrite))")
        for volume in details.volumes {
            line("  volume", "\(volume.name) \(volume.path): \(Format.bytes(UInt64(volume.available))) free of \(Format.bytes(UInt64(volume.total)))")
        }
        line("GPU", "\(sample.gpu.map(Format.percent) ?? "unavailable"), \(details.gpuName ?? "unknown"), memory \(details.gpuMemory.map(Format.bytes) ?? "n/a")")
        line("Thermal", details.thermalLabel)
        if let battery = sample.battery {
            let extra = details.battery
            line("Battery", "\(Format.percent(battery.level)), charging \(battery.isCharging), AC \(battery.onAC)")
            line("  details", "health \(extra?.health.map(Format.percent) ?? "?"), cycles \(extra?.cycleCount.map(String.init) ?? "?"), \(extra?.temperature.map { String(format: "%.1f°C", $0) } ?? "?"), \(extra?.watts.map { String(format: "%.1f W", $0) } ?? "?"), \(extra?.minutesRemaining.map { "\($0) min" } ?? "estimating")")
        } else {
            line("Battery", "none")
        }
        line("Apps", "\(apps.count) groups, \(apps.reduce(0) { $0 + $1.processes.count }) processes")
        for app in apps.prefix(5) {
            line("  " + app.name, "\(Format.cpu(app.cpu)) · \(Format.bytes(app.memory)) · \(app.processes.count) proc")
        }
        let projects = ProjectScanner().scan()
        line("Projects", "\(projects.count) groups, \(projects.reduce(0) { $0 + $1.ports.count }) listening ports")
        let sample1 = StorageScanner.measure(StorageScanner.home + "/Downloads")
        line("Storage probe", sample1.map { "~/Downloads = \(Format.bytes(UInt64($0.bytes))) [\($0.category.title)]" } ?? "unreadable")
        exit(0)
    }
}

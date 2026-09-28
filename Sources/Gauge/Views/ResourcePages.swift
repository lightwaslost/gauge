import SwiftUI

struct CPUPage: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let details = monitor.details
        PageScroll {
            PageHeader(title: "CPU", subtitle: "Processor load across \(ProcessInfo.processInfo.activeProcessorCount) cores, helpers included.")
            LiveChartCard(metric: .cpu)
            TileRow {
                StatTile(label: "Total", value: Format.percent(monitor.latest?.cpu ?? 0))
                StatTile(label: "User", value: Format.percent(details.cpuUser), caption: "Apps and tools")
                StatTile(label: "System", value: Format.percent(details.cpuSystem), caption: "macOS kernel")
                StatTile(label: "Load (1 min)", value: String(format: "%.2f", details.loadAverage), caption: "Runnable threads")
            }
            AppActivityList(title: "Apps by CPU", sortedBy: .cpu)
        }
        .navigationTitle("CPU")
    }
}

struct MemoryPage: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let details = monitor.details
        PageScroll {
            PageHeader(title: "Memory", subtitle: "How much RAM is in use, how tight it is, and who's using it.")
            LiveChartCard(metric: .memory)
            TileRow {
                StatTile(label: "In use", value: Format.bytes(monitor.latest?.memoryUsed ?? 0),
                         caption: "of \(Format.bytes(ProcessInfo.processInfo.physicalMemory))")
                StatTile(label: "Pressure", value: details.pressure.label)
                StatTile(label: "Swap used", value: Format.bytes(details.swapUsed))
            }
            MemoryBreakdown()
            AppActivityList(title: "Apps by memory", sortedBy: .memory)
        }
        .navigationTitle("Memory")
    }
}

struct DiskPage: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let latest = monitor.latest
        PageScroll {
            PageHeader(title: "Disk", subtitle: "Reads and writes right now, and how full each volume is.")
            LiveChartCard(metric: .disk)
            TileRow {
                StatTile(label: "Reading", value: Format.rate(latest?.diskRead ?? 0))
                StatTile(label: "Writing", value: Format.rate(latest?.diskWrite ?? 0))
                StatTile(label: "Volumes", value: "\(monitor.details.volumes.count)")
            }
            Panel {
                Text("Volumes").font(.headline)
                ForEach(monitor.details.volumes) { volume in
                    VolumeRow(volume: volume)
                }
                Text("APFS volumes in one container share free space, so their totals overlap.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            AppActivityList(title: "Apps by disk activity", columns: [.processes, .read, .write], sortedBy: .read)
        }
        .navigationTitle("Disk")
    }
}

struct VolumeRow: View {
    let volume: VolumeInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive")
                    .foregroundStyle(.secondary)
                Text(volume.name)
                Text(volume.path).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Text("\(Format.bytes(UInt64(volume.available))) free of \(Format.bytes(UInt64(volume.total)))")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: Double(volume.used), total: Double(max(volume.total, 1)))
                .tint(Double(volume.available) / Double(max(volume.total, 1)) < 0.1 ? .red : .accentColor)
        }
    }
}

struct NetworkPage: View {
    @Environment(Monitor.self) private var monitor
    @State private var showIdle = false

    var body: some View {
        let latest = monitor.latest
        let interfaces = monitor.details.interfaces.filter { showIdle || $0.totalIn + $0.totalOut > 0 }
        PageScroll {
            PageHeader(title: "Network", subtitle: "Traffic in and out across your network interfaces.")
            LiveChartCard(metric: .network)
            TileRow {
                StatTile(label: "Download", value: Format.rate(latest?.netIn ?? 0))
                StatTile(label: "Upload", value: Format.rate(latest?.netOut ?? 0))
                StatTile(label: "Interfaces", value: "\(monitor.details.interfaces.count)",
                         caption: "\(monitor.details.interfaces.filter(\.isPhysical).count) physical")
            }
            Panel {
                HStack {
                    Text("Interfaces").font(.headline)
                    Spacer()
                    Toggle("Show unused", isOn: $showIdle).toggleStyle(.checkbox)
                }
                HStack {
                    Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Download").frame(width: 100, alignment: .trailing)
                    Text("Upload").frame(width: 100, alignment: .trailing)
                    Text("Since boot").frame(width: 110, alignment: .trailing)
                }
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                ForEach(interfaces) { interface in
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(interface.name).font(.body.monospaced())
                            Text(interface.isPhysical ? "Physical (Wi-Fi / Ethernet)" : Self.describe(interface.name))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Format.rate(interface.bytesIn)).frame(width: 100, alignment: .trailing)
                        Text(Format.rate(interface.bytesOut)).frame(width: 100, alignment: .trailing)
                        Text(Format.bytes(interface.totalIn + interface.totalOut)).foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .trailing)
                    }
                    .monospacedDigit()
                }
                Text("Totals above count physical interfaces only, since VPN tunnels re-carry the same traffic.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .navigationTitle("Network")
    }

    static func describe(_ name: String) -> String {
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") { return "VPN / tunnel" }
        if name.hasPrefix("awdl") || name.hasPrefix("llw") { return "AirDrop / peer-to-peer" }
        if name.hasPrefix("bridge") { return "Bridge" }
        if name.hasPrefix("anpi") { return "Apple network interface" }
        if name.hasPrefix("ap") { return "Personal hotspot" }
        return "Virtual"
    }
}

struct GraphicsPage: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let details = monitor.details
        PageScroll {
            PageHeader(title: "Graphics", subtitle: "GPU load as reported by the graphics driver.")
            if monitor.latest?.gpu == nil {
                Panel {
                    Label("This Mac doesn't report GPU utilization.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            } else {
                LiveChartCard(metric: .gpu)
            }
            TileRow {
                StatTile(label: "GPU load", value: monitor.latest?.gpu.map(Format.percent) ?? "—")
                StatTile(label: "GPU memory", value: details.gpuMemory.map(Format.bytes) ?? "—", caption: "Driver-reported")
                StatTile(label: "Thermal state", value: details.thermalLabel)
            }
            Panel {
                Label(details.gpuName ?? "Graphics processor", systemImage: "cpu").font(.headline)
                Text("On Apple silicon the GPU shares system memory, so GPU memory is part of Memory, not extra. macOS doesn't expose GPU use per app.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Graphics")
    }
}

struct BatteryPage: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let state = monitor.latest?.battery
        let details = monitor.details.battery
        PageScroll {
            PageHeader(title: "Battery", subtitle: "Charge, power source and long-term battery health.")
            if state == nil {
                Panel {
                    Label("This Mac has no internal battery.", systemImage: "powerplug").foregroundStyle(.secondary)
                }
            } else {
                LiveChartCard(metric: .battery)
                TileRow {
                    StatTile(label: "Charge", value: Format.percent(state?.level ?? 0))
                    StatTile(label: "Power source", value: state?.onAC == true ? "Adapter" : "Battery",
                             caption: state?.isCharging == true ? "Charging" : state?.onAC == true ? "Not charging" : "Discharging")
                    StatTile(label: state?.isCharging == true ? "Until full" : "Time left",
                             value: details?.minutesRemaining.map { Format.duration(Double($0 * 60)) } ?? "Estimating…")
                }
                TileRow {
                    StatTile(label: "Health", value: details?.health.map(Format.percent) ?? "—", caption: details?.condition)
                    StatTile(label: "Cycle count", value: details?.cycleCount.map(String.init) ?? "—")
                    StatTile(label: "Temperature", value: details?.temperature.map { String(format: "%.1f °C", $0) } ?? "—")
                    StatTile(label: "Power", value: details?.watts.map { String(format: "%.1f W", abs($0)) } ?? "—",
                             caption: (details?.watts ?? 0) < 0 ? "Into battery" : "From battery")
                }
            }
        }
        .navigationTitle("Battery")
    }
}

import Darwin
import Foundation
import IOKit
import IOKit.ps

struct BatteryState: Codable, Hashable {
    var level: Double      // 0...1
    var isCharging: Bool
    var onAC: Bool
}

/// One reading of whole-machine activity. Rates are bytes per second.
/// Kept small because it's buffered live and written to history.
struct SystemSample: Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let cpu: Double          // 0...1
    let memoryUsed: UInt64
    let memoryTotal: UInt64
    let netIn: Double
    let netOut: Double
    let diskRead: Double
    let diskWrite: Double
    let gpu: Double?         // 0...1, nil when the hardware doesn't report it
    let battery: BatteryState?

    var memoryFraction: Double {
        memoryTotal == 0 ? 0 : Double(memoryUsed) / Double(memoryTotal)
    }
}

enum MemoryPressure: Int, Comparable {
    case normal = 1, warning = 2, critical = 4

    var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct InterfaceTraffic: Identifiable, Hashable {
    let name: String
    let isPhysical: Bool
    let bytesIn: Double      // per second
    let bytesOut: Double
    let totalIn: UInt64      // since boot
    let totalOut: UInt64
    var id: String { name }
}

struct VolumeInfo: Identifiable, Hashable {
    let name: String
    let path: String
    let total: Int64
    let available: Int64
    let isInternal: Bool
    var id: String { path }
    var used: Int64 { max(0, total - available) }
}

struct BatteryDetails: Hashable {
    var cycleCount: Int?
    var health: Double?            // max capacity vs design, 0...1
    var temperature: Double?       // °C
    var watts: Double?             // positive = drawing from battery, negative = charging
    var minutesRemaining: Int?     // to empty, or to full while charging
    var condition: String?
}

/// Readings that are shown live but not written to history.
struct SystemDetails: Hashable {
    var cpuUser: Double = 0        // 0...1
    var cpuSystem: Double = 0
    var loadAverage: Double = 0    // 1-minute
    var memoryActive: UInt64 = 0
    var memoryWired: UInt64 = 0
    var memoryCompressed: UInt64 = 0
    var memoryCached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: MemoryPressure = .normal
    var interfaces: [InterfaceTraffic] = []
    var volumes: [VolumeInfo] = []
    var gpuName: String?
    var gpuMemory: UInt64?
    var thermal: ProcessInfo.ThermalState = .nominal
    var battery: BatteryDetails?

    var thermalLabel: String {
        switch thermal {
        case .nominal: "Normal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}

/// Reads machine-wide counters. Confined to the monitor's serial sampling queue.
final class SystemSampler: @unchecked Sendable {
    private let host = mach_host_self()
    private let memoryTotal = ProcessInfo.processInfo.physicalMemory
    private let pageSize = UInt64(vm_kernel_page_size)
    private var lastTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var lastInterfaces: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
    private var lastNetTime: TimeInterval?
    private var lastDisk: (read: UInt64, write: UInt64, time: TimeInterval)?
    private var cachedVolumes: [VolumeInfo] = []
    private var cachedGPUName: String?
    private var ticks = 0

    func sample() -> (SystemSample, SystemDetails) {
        let now = ProcessInfo.processInfo.systemUptime
        var details = SystemDetails()
        ticks += 1

        let cpu = cpuUsage(&details)
        let memoryUsed = memory(&details)
        let (netIn, netOut) = network(now, &details)

        let disk = diskBytes()
        var diskRead = 0.0, diskWrite = 0.0
        if let last = lastDisk, now > last.time {
            diskRead = rate(disk.0, last.read, now - last.time)
            diskWrite = rate(disk.1, last.write, now - last.time)
        }
        lastDisk = (disk.0, disk.1, now)

        let gpu = gpuStatistics(&details)
        let battery = batteryState()
        if battery != nil { details.battery = batteryDetails() }

        var load = [0.0, 0.0, 0.0]
        if getloadavg(&load, 3) > 0 { details.loadAverage = load[0] }
        details.thermal = ProcessInfo.processInfo.thermalState

        // Volumes barely change; refresh every ~30 seconds.
        if cachedVolumes.isEmpty || ticks % 15 == 0 { cachedVolumes = Self.volumes() }
        details.volumes = cachedVolumes

        let sample = SystemSample(
            date: Date(),
            cpu: cpu,
            memoryUsed: memoryUsed,
            memoryTotal: memoryTotal,
            netIn: netIn,
            netOut: netOut,
            diskRead: diskRead,
            diskWrite: diskWrite,
            gpu: gpu,
            battery: battery
        )
        return (sample, details)
    }

    private func rate(_ current: UInt64, _ previous: UInt64, _ seconds: TimeInterval) -> Double {
        current >= previous ? Double(current - previous) / seconds : 0
    }

    // MARK: CPU

    private func cpuUsage(_ details: inout SystemDetails) -> Double {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let current = (
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
        defer { lastTicks = current }
        guard let last = lastTicks else { return 0 }

        let user = Double(current.user &- last.user) + Double(current.nice &- last.nice)
        let system = Double(current.system &- last.system)
        let idle = Double(current.idle &- last.idle)
        let total = user + system + idle
        guard total > 0 else { return 0 }
        details.cpuUser = user / total
        details.cpuSystem = system / total
        return (user + system) / total
    }

    // MARK: Memory

    /// "Used" matches Activity Monitor: app memory + wired + compressed.
    private func memory(_ details: inout SystemDetails) -> UInt64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let appPages = internalPages > purgeable ? internalPages - purgeable : 0
        details.memoryActive = appPages * pageSize
        details.memoryWired = UInt64(stats.wire_count) * pageSize
        details.memoryCompressed = UInt64(stats.compressor_page_count) * pageSize
        details.memoryCached = (UInt64(stats.external_page_count) + purgeable) * pageSize

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            details.swapUsed = swap.xsu_used
        }

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            details.pressure = MemoryPressure(rawValue: Int(level)) ?? .normal
        }

        return details.memoryActive + details.memoryWired + details.memoryCompressed
    }

    // MARK: Network

    /// Per-interface 64-bit counters from the routing table. Loopback is skipped.
    private func network(_ now: TimeInterval, _ details: inout SystemDetails) -> (Double, Double) {
        let netRtIfList2: Int32 = 6
        let rtmIfInfo2: UInt8 = 0x12

        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, netRtIfList2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return (0, 0) }

        var counters: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if header.ifm_type == rtmIfInfo2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if message.ifm_flags & IFF_LOOPBACK == 0 {
                        var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                        if if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil {
                            let name = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                            counters[name] = (message.ifm_data.ifi_ibytes, message.ifm_data.ifi_obytes)
                        }
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }

        let elapsed = lastNetTime.map { now - $0 } ?? 0
        var interfaces: [InterfaceTraffic] = []
        var totalIn = 0.0, totalOut = 0.0
        for (name, value) in counters {
            var bytesIn = 0.0, bytesOut = 0.0
            if elapsed > 0, let previous = lastInterfaces[name] {
                bytesIn = rate(value.bytesIn, previous.bytesIn, elapsed)
                bytesOut = rate(value.bytesOut, previous.bytesOut, elapsed)
            }
            let physical = Self.isPhysicalInterface(name)
            // Tunnels (VPN) re-carry traffic already counted on the physical link.
            if physical { totalIn += bytesIn; totalOut += bytesOut }
            interfaces.append(InterfaceTraffic(
                name: name, isPhysical: physical, bytesIn: bytesIn, bytesOut: bytesOut,
                totalIn: value.bytesIn, totalOut: value.bytesOut
            ))
        }
        lastInterfaces = counters
        lastNetTime = now

        details.interfaces = interfaces.sorted {
            let lhs = $0.bytesIn + $0.bytesOut, rhs = $1.bytesIn + $1.bytesOut
            if lhs != rhs { return lhs > rhs }
            if $0.isPhysical != $1.isPhysical { return $0.isPhysical }
            return $0.totalIn + $0.totalOut > $1.totalIn + $1.totalOut
        }
        return (totalIn, totalOut)
    }

    private static func isPhysicalInterface(_ name: String) -> Bool {
        // Wi-Fi and Ethernet are en*; bridges, tunnels, AWDL and anpi are virtual.
        name.hasPrefix("en")
    }

    // MARK: Disk

    private func diskBytes() -> (UInt64, UInt64) {
        var read: UInt64 = 0, write: UInt64 = 0
        forEachService(matching: "IOBlockStorageDriver") { service in
            guard let stats = property(service, "Statistics") as? [String: Any] else { return }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, write)
    }

    static func volumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsBrowsableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false,
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            let available = values.volumeAvailableCapacityForImportantUsage
                ?? Int64(values.volumeAvailableCapacity ?? 0)
            return VolumeInfo(
                name: values.volumeName ?? url.lastPathComponent,
                path: url.path,
                total: Int64(total),
                available: available,
                isInternal: values.volumeIsInternal ?? false
            )
        }
        .sorted { ($0.path == "/" ? 0 : 1, $0.name) < ($1.path == "/" ? 0 : 1, $1.name) }
    }

    // MARK: GPU

    private func gpuStatistics(_ details: inout SystemDetails) -> Double? {
        var best: Double?
        var memory: UInt64?
        forEachService(matching: "IOAccelerator") { service in
            if cachedGPUName == nil, let model = property(service, "model") {
                if let text = model as? String {
                    cachedGPUName = text
                } else if let data = model as? Data {
                    cachedGPUName = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
                }
            }
            guard let stats = property(service, "PerformanceStatistics") as? [String: Any] else { return }
            if let value = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                best = max(best ?? 0, value / 100)
            }
            if let used = (stats["In use system memory"] as? NSNumber)?.uint64Value {
                memory = (memory ?? 0) + used
            }
        }
        if cachedGPUName == nil { cachedGPUName = Self.chipName() }
        details.gpuName = cachedGPUName
        details.gpuMemory = memory
        return best
    }

    private static func chipName() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: Battery

    private func batteryState() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return BatteryState(
                level: Double(current) / Double(maximum),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                onAC: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            )
        }
        return nil
    }

    private func batteryDetails() -> BatteryDetails? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        func int(_ key: String) -> Int? { (property(service, key) as? NSNumber)?.intValue }

        var details = BatteryDetails()
        details.cycleCount = int("CycleCount")
        if let design = int("DesignCapacity"), design > 0,
           let maximum = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") {
            details.health = min(1, Double(maximum) / Double(design))
        }
        if let temperature = int("Temperature") { details.temperature = Double(temperature) / 100 }
        if let voltage = int("Voltage"), let amperage = int("InstantAmperage") ?? int("Amperage") {
            // Amperage is negative while discharging.
            details.watts = -Double(voltage) * Double(amperage) / 1_000_000
        }
        let isCharging = (property(service, "IsCharging") as? Bool) ?? false
        let minutes = isCharging ? int("AvgTimeToFull") : int("AvgTimeToEmpty")
        if let minutes, minutes > 0, minutes < 65535 { details.minutesRemaining = minutes }
        if let health = details.health {
            details.condition = health >= 0.8 ? "Normal" : "Service recommended"
        }
        return details
    }

    // MARK: IOKit helpers

    private func forEachService(matching className: String, _ body: (io_object_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    private func property(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

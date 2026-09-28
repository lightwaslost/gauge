import Darwin
import Foundation

struct ProcessUsage: Identifiable, Hashable {
    let pid: Int32
    let name: String
    let cpu: Double          // percent of one core, like Activity Monitor
    let memory: UInt64       // physical footprint
    let diskRead: Double     // bytes per second
    let diskWrite: Double
    var id: Int32 { pid }
}

/// Processes grouped under the app bundle that owns them.
struct AppUsage: Identifiable, Hashable {
    let id: String           // bundle path, or "proc:<name>" for bare executables
    let name: String
    let bundlePath: String?
    var cpu: Double
    var memory: UInt64
    var diskRead: Double
    var diskWrite: Double
    var processes: [ProcessUsage]
}

/// Reads per-process usage via libproc and groups it by app.
/// Only processes readable by the current user are included.
final class ProcessSampler: @unchecked Sendable {
    private struct Identity {
        let startTime: UInt64
        let ppid: Int32
        let name: String
        let bundlePath: String?
    }

    private struct Counters {
        let cpuTicks: UInt64
        let bytesRead: UInt64
        let bytesWritten: UInt64
    }

    private var identities: [Int32: Identity] = [:]
    private var previous: [Int32: Counters] = [:]
    private var lastSampleTime: UInt64 = 0
    private var displayNames: [String: String] = [:]
    private let ticksToNanos: Double

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksToNanos = Double(timebase.numer) / Double(timebase.denom)
    }

    func sample() -> [AppUsage] {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = lastSampleTime == 0 ? 0 : Double(now - lastSampleTime)
        lastSampleTime = now

        var usages: [Int32: ProcessUsage] = [:]
        var current: [Int32: Counters] = [:]
        var liveIdentities: [Int32: Identity] = [:]

        for pid in listPids() {
            guard let info = rusage(pid) else { continue }
            let identity: Identity
            if let cached = identities[pid], cached.startTime == info.ri_proc_start_abstime {
                identity = cached
            } else if let fresh = makeIdentity(pid, startTime: info.ri_proc_start_abstime) {
                identity = fresh
            } else {
                continue
            }
            liveIdentities[pid] = identity

            let counters = Counters(
                cpuTicks: info.ri_user_time + info.ri_system_time,
                bytesRead: info.ri_diskio_bytesread,
                bytesWritten: info.ri_diskio_byteswritten
            )
            current[pid] = counters

            var cpu = 0.0, read = 0.0, write = 0.0
            if elapsed > 0, let last = previous[pid], identities[pid]?.startTime == identity.startTime {
                let seconds = elapsed / 1_000_000_000
                cpu = Double(counters.cpuTicks &- last.cpuTicks) * ticksToNanos / elapsed * 100
                read = Double(counters.bytesRead &- last.bytesRead) / seconds
                write = Double(counters.bytesWritten &- last.bytesWritten) / seconds
                if cpu < 0 || cpu.isNaN { cpu = 0 }
            }

            usages[pid] = ProcessUsage(
                pid: pid,
                name: identity.name,
                cpu: cpu,
                memory: info.ri_phys_footprint,
                diskRead: read,
                diskWrite: write
            )
        }

        identities = liveIdentities
        previous = current
        return group(usages)
    }

    // MARK: Grouping

    private func group(_ usages: [Int32: ProcessUsage]) -> [AppUsage] {
        var apps: [String: AppUsage] = [:]
        for (pid, usage) in usages {
            let (key, bundle) = owner(of: pid)
            if apps[key] == nil {
                apps[key] = AppUsage(
                    id: key,
                    name: bundle.map(displayName(forBundle:)) ?? usage.name,
                    bundlePath: bundle,
                    cpu: 0, memory: 0, diskRead: 0, diskWrite: 0,
                    processes: []
                )
            }
            apps[key]!.cpu += usage.cpu
            apps[key]!.memory += usage.memory
            apps[key]!.diskRead += usage.diskRead
            apps[key]!.diskWrite += usage.diskWrite
            apps[key]!.processes.append(usage)
        }
        return apps.values
            .map { app in
                var app = app
                app.processes.sort { $0.cpu > $1.cpu }
                return app
            }
            .sorted { $0.cpu == $1.cpu ? $0.memory > $1.memory : $0.cpu > $1.cpu }
    }

    /// Walks up the parent chain until it finds a process that lives inside an app bundle,
    /// so helpers, XPC services and child tools land under the app that started them.
    private func owner(of pid: Int32) -> (key: String, bundle: String?) {
        var cursor = pid
        for _ in 0..<12 {
            guard let identity = identities[cursor] else { break }
            if let bundle = identity.bundlePath { return (bundle, bundle) }
            guard identity.ppid > 1 else { break }
            cursor = identity.ppid
        }
        return ("proc:" + (identities[pid]?.name ?? "\(pid)"), nil)
    }

    private func displayName(forBundle path: String) -> String {
        if let cached = displayNames[path] { return cached }
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        displayNames[path] = name
        return name
    }

    // MARK: libproc

    private func listPids() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<Int32>.size))
        }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    private func rusage(_ pid: Int32) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info : nil
    }

    private func makeIdentity(_ pid: Int32, startTime: UInt64) -> Identity? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let ppid: Int32 = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size ? Int32(bsd.pbi_ppid) : 0

        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0
            ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : nil

        var name = path.map(Self.readableName) ?? ""
        if name.isEmpty {
            var nameBuffer = [CChar](repeating: 0, count: 256)
            let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            guard nameLength > 0 else { return nil }
            name = String(decoding: nameBuffer.prefix(Int(nameLength)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }

        return Identity(startTime: startTime, ppid: ppid, name: name, bundlePath: path.flatMap(Self.outermostBundle))
    }

    /// Tools installed as ".../claude/versions/2.1.3" are named after their version;
    /// use the nearest meaningful folder instead.
    static func readableName(fromPath path: String) -> String {
        let generic: Set<String> = ["versions", "version", "bin", "current", "latest", "libexec"]
        let components = path.split(separator: "/").map(String.init)
        guard let last = components.last else { return "" }
        guard last.allSatisfy({ $0.isNumber || $0 == "." }) else { return last }
        return components.dropLast().reversed().first {
            !generic.contains($0.lowercased()) && !$0.allSatisfy { $0.isNumber || $0 == "." }
        } ?? last
    }

    /// "/Applications/Foo.app/Contents/Frameworks/Helper.app/..." -> "/Applications/Foo.app"
    static func outermostBundle(in path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }
}

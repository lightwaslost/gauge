import Darwin
import Foundation

/// A development process: a known runtime, or anything listening on a TCP port.
struct DevProcess: Identifiable, Hashable {
    let pid: Int32
    let name: String
    let runtime: String
    let command: String      // arguments after the executable, trimmed
    let ports: [UInt16]
    let bundlePath: String?
    var id: Int32 { pid }
}

/// Dev processes that share a working folder.
struct Project: Identifiable, Hashable {
    let id: String           // root folder path, or a fixed key for the catch-all groups
    let name: String
    let root: String?
    var processes: [DevProcess]

    var ports: [UInt16] { processes.flatMap(\.ports).sorted() }
}

/// Finds dev runtimes and listening sockets, grouped by project folder.
/// Scans every readable process, so run it off the main thread and only while visible.
final class ProjectScanner: @unchecked Sendable {
    static let otherServicesID = "~services"
    static let appsListeningID = "~apps"

    private static let runtimes: [(prefix: String, label: String)] = [
        ("node", "Node.js"), ("bun", "Bun"), ("deno", "Deno"),
        ("python", "Python"), ("uvicorn", "Python"), ("gunicorn", "Python"),
        ("ruby", "Ruby"), ("puma", "Ruby"), ("java", "Java"), ("php", "PHP"),
        ("beam.smp", "Elixir"), ("dotnet", ".NET"),
        ("cargo", "Rust"), ("rust-analyzer", "Rust"), ("go", "Go"), ("gopls", "Go"),
        ("postgres", "PostgreSQL"), ("mysqld", "MySQL"), ("mongod", "MongoDB"),
        ("redis-server", "Redis"), ("nginx", "nginx"), ("caddy", "Caddy"),
        ("com.docker", "Docker"), ("vite", "Vite"), ("esbuild", "esbuild"),
    ]

    private static let projectMarkers = [
        ".git", "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "requirements.txt",
        "Gemfile", "pom.xml", "build.gradle", "mix.exs", "composer.json", "deno.json", "Package.swift",
    ]

    private var rootCache: [String: String?] = [:]
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    func scan() -> [Project] {
        var groups: [String: Project] = [:]

        for pid in Self.listPids() where pid != getpid() {
            guard let path = Self.path(pid) else { continue }
            let executable = ProcessSampler.readableName(fromPath: path)
            let bundle = ProcessSampler.outermostBundle(in: path)
            let ports = Self.listeningPorts(pid)
            let runtime = Self.runtime(for: executable)

            // Inside an app bundle only matters if it's serving something.
            if bundle != nil && ports.isEmpty { continue }
            if runtime == nil && ports.isEmpty { continue }

            let process = DevProcess(
                pid: pid,
                name: executable,
                runtime: runtime ?? "Listener",
                command: Self.arguments(pid),
                ports: ports,
                bundlePath: bundle
            )

            let key: String, name: String, root: String?
            if bundle != nil {
                (key, name, root) = (Self.appsListeningID, "Apps with open ports", nil)
            } else if let cwd = Self.workingDirectory(pid), let projectRoot = projectRoot(for: cwd) {
                (key, name, root) = (projectRoot, (projectRoot as NSString).lastPathComponent, projectRoot)
            } else {
                (key, name, root) = (Self.otherServicesID, "Other services", nil)
            }
            groups[key, default: Project(id: key, name: name, root: root, processes: [])].processes.append(process)
        }

        return groups.values
            .map { project in
                var project = project
                project.processes.sort { ($0.ports.first ?? .max, $0.pid) < ($1.ports.first ?? .max, $1.pid) }
                return project
            }
            .sorted { lhs, rhs in
                // Real projects first, catch-all groups last.
                let lhsCatchAll = lhs.root == nil, rhsCatchAll = rhs.root == nil
                if lhsCatchAll != rhsCatchAll { return rhsCatchAll }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    // MARK: Project roots

    /// Nearest ancestor (within the home folder) holding a project marker.
    private func projectRoot(for directory: String) -> String? {
        if let cached = rootCache[directory] { return cached }
        var result: String?
        var cursor = directory
        while cursor.hasPrefix(home + "/") {
            if Self.projectMarkers.contains(where: { FileManager.default.fileExists(atPath: cursor + "/" + $0) }) {
                result = cursor
                break
            }
            cursor = (cursor as NSString).deletingLastPathComponent
        }
        // A process running straight from ~ (or outside it) isn't a project.
        rootCache[directory] = result
        return result
    }

    private static func runtime(for executable: String) -> String? {
        let name = executable.lowercased()
        return runtimes.first { name == $0.prefix || name.hasPrefix($0.prefix + ".") || name.hasPrefix($0.prefix + "-") || (name.hasPrefix($0.prefix) && name.dropFirst($0.prefix.count).allSatisfy { $0.isNumber || $0 == "." }) }?.label
    }

    // MARK: libproc

    private static func listPids() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<Int32>.size))
        }
        return count > 0 ? pids.prefix(Int(count)).filter { $0 > 0 } : []
    }

    private static func path(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty || path == "/" ? nil : path
    }

    /// Local TCP ports this process is listening on.
    static func listeningPorts(_ pid: Int32) -> [UInt16] {
        let fdTypeSocket: UInt32 = 2      // PROX_FDTYPE_SOCKET
        let sockInfoTCP: Int32 = 2        // SOCKINFO_TCP
        let tcpStateListen: Int32 = 1     // TSI_S_LISTEN

        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let capacity = Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 16
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let filled = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard filled > 0 else { return [] }

        var ports = Set<UInt16>()
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == fdTypeSocket {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                  socket.psi.soi_kind == sockInfoTCP,
                  socket.psi.soi_proto.pri_tcp.tcpsi_state == tcpStateListen else { continue }
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }

    private static let secretWords = ["key", "token", "secret", "password", "passwd", "auth", "credential", "bearer"]

    /// Command lines often carry credentials (`--api-key sk-…`, `TOKEN=…`, `postgres://user:pass@…`).
    /// Hide them before anything reaches the screen.
    static func redactSecrets(_ arguments: [String]) -> [String] {
        let hidden = "••••••"
        var result: [String] = []
        var redactNext = false
        for argument in arguments {
            if redactNext {
                result.append(hidden)
                redactNext = false
                continue
            }
            let lower = argument.lowercased()
            if let equals = argument.firstIndex(of: "="),
               secretWords.contains(where: { lower[..<equals].contains($0) }) {
                result.append(String(argument[...equals]) + hidden)
            } else if argument.hasPrefix("-"), secretWords.contains(where: { lower.contains($0) }) {
                result.append(argument)
                redactNext = true
            } else if let credentials = argument.range(of: #"://[^/\s:@]+:[^/\s@]+@"#, options: .regularExpression) {
                result.append(argument.replacingCharacters(in: credentials, with: "://" + hidden + "@"))
            } else if looksLikeToken(argument) {
                result.append(hidden)
            } else {
                result.append(argument)
            }
        }
        return result
    }

    /// Long opaque strings with a known key prefix or high character variety.
    private static func looksLikeToken(_ value: String) -> Bool {
        let prefixes = ["sk-", "sk_", "pk_", "ghp_", "gho_", "github_pat_", "xoxb-", "xoxp-", "ctx7sk", "AKIA", "eyJ"]
        if value.count >= 16, prefixes.contains(where: value.hasPrefix) { return true }
        guard value.count >= 32, !value.contains("/"), !value.contains(".") else { return false }
        let hasDigit = value.contains(where: \.isNumber)
        let hasLetter = value.contains(where: \.isLetter)
        return hasDigit && hasLetter && !value.contains(" ")
    }

    /// Arguments after argv[0], via KERN_PROCARGS2. Empty for processes we can't read.
    private static func arguments(_ pid: Int32) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return "" }

        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path and the NUL padding after it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        var start = index
        while index < size, arguments.count < Int(argc) {
            if buffer[index] == 0 {
                arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        let joined = redactSecrets(Array(arguments.dropFirst()))
            .map { $0.hasPrefix("/") ? ($0 as NSString).lastPathComponent : $0 }
            .joined(separator: " ")
        return joined.count > 120 ? String(joined.prefix(117)) + "…" : joined
    }
}

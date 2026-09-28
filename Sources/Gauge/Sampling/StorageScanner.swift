import Foundation
import SwiftUI

enum StorageCategory: String, CaseIterable, Codable, Identifiable {
    case documents, downloads, applications, media, developer, appData, caches, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .documents: "Documents & Desktop"
        case .downloads: "Downloads"
        case .applications: "Applications"
        case .media: "Photos, Music & Movies"
        case .developer: "Developer"
        case .appData: "App data"
        case .caches: "Caches"
        case .other: "Everything else"
        }
    }

    var symbol: String {
        switch self {
        case .documents: "doc.text"
        case .downloads: "arrow.down.circle"
        case .applications: "square.grid.2x2"
        case .media: "photo.on.rectangle"
        case .developer: "hammer"
        case .appData: "shippingbox"
        case .caches: "archivebox"
        case .other: "folder"
        }
    }

    var color: Color {
        switch self {
        case .documents: .blue
        case .downloads: .cyan
        case .applications: .indigo
        case .media: .pink
        case .developer: .purple
        case .appData: .teal
        case .caches: .orange
        case .other: .gray
        }
    }
}

struct FolderSize: Identifiable, Hashable, Codable {
    let path: String
    let bytes: Int64
    let category: StorageCategory
    let unreadable: Int
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

struct StorageReport: Codable, Hashable {
    let scope: String            // folder that was broken down
    let date: Date
    let folders: [FolderSize]    // largest first

    var total: Int64 { folders.reduce(0) { $0 + $1.bytes } }
    var unreadable: Int { folders.reduce(0) { $0 + $1.unreadable } }

    func bytes(in category: StorageCategory) -> Int64 {
        folders.filter { $0.category == category }.reduce(0) { $0 + $1.bytes }
    }
}

/// Measures folder sizes on disk (allocated size, so sparse and cloned files count as stored).
enum StorageScanner {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// The folders that make up "your" space: home, its Library, and /Applications.
    static func defaultFolders() -> [String] {
        var folders = children(of: home).filter { $0 != home + "/Library" }
        folders += children(of: home + "/Library")
        folders.append("/Applications")
        return folders
    }

    static func children(of path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []
        )) ?? []
        return items.compactMap { item in
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else { return nil }
            return item.path
        }
    }

    static func scan(
        _ folders: [String],
        scope: String,
        progress: @escaping @Sendable (_ done: Int, _ total: Int, _ current: String) -> Void
    ) async -> StorageReport {
        var results: [FolderSize] = []
        await withTaskGroup(of: FolderSize?.self) { group in
            var iterator = folders.makeIterator()
            var done = 0
            // A few folders at a time keeps the disk busy without thrashing it.
            for _ in 0..<4 {
                if let next = iterator.next() { group.addTask { measure(next) } }
            }
            while let result = await group.next() {
                done += 1
                if let result { results.append(result); progress(done, folders.count, result.name) }
                if Task.isCancelled { group.cancelAll(); break }
                if let next = iterator.next() { group.addTask { measure(next) } }
            }
        }
        return StorageReport(
            scope: scope,
            date: Date(),
            folders: results.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        )
    }

    static func measure(_ path: String) -> FolderSize? {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }

        func size(of item: URL) -> Int64 {
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return 0 }
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }

        guard isDirectory.boolValue else {
            return FolderSize(path: path, bytes: size(of: url), category: category(for: path), unreadable: 0)
        }

        var unreadable = 0
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: []) { _, _ in
            unreadable += 1
            return true
        }
        var visited = 0
        while let item = enumerator?.nextObject() as? URL {
            total += size(of: item)
            visited += 1
            if visited % 5000 == 0, Task.isCancelled { break }
        }
        return FolderSize(path: path, bytes: total, category: category(for: path), unreadable: unreadable)
    }

    static func category(for path: String) -> StorageCategory {
        let relative = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
        let top = relative.split(separator: "/").first.map(String.init) ?? relative

        if path.hasPrefix("/Applications") || relative.hasPrefix("Applications") { return .applications }
        switch top {
        case "Downloads": return .downloads
        case "Documents", "Desktop": return .documents
        case "Pictures", "Movies", "Music": return .media
        case "Developer", "Projects", "projects", "code", "Code", "dev", "src", "go", "orca":
            return .developer
        default: break
        }
        if top.hasPrefix("."), [".npm", ".cargo", ".rustup", ".gradle", ".android", ".bun", ".cocoapods", ".m2",
                                ".pyenv", ".nvm", ".deno", ".pnpm-store", ".yarn", ".docker", ".conda", ".local"].contains(top) {
            return .developer
        }
        if top == ".cache" { return .caches }
        if top == "Library" {
            let second = relative.split(separator: "/").dropFirst().first.map(String.init) ?? ""
            switch second {
            case "Caches", "Logs": return .caches
            case "Developer": return .developer
            case "Mobile Documents": return .documents
            case "Application Support", "Containers", "Group Containers", "Mail", "Messages", "Safari": return .appData
            default: return .other
            }
        }
        return .other
    }

    // MARK: Cache

    static var cacheURL: URL {
        HistoryStore.defaultURL.deletingLastPathComponent().appendingPathComponent("storage.json")
    }

    static func loadCached() -> StorageReport? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StorageReport.self, from: data)
    }

    static func save(_ report: StorageReport) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(report).write(to: cacheURL, options: .atomic)
    }
}

import Foundation

/// An app's share of activity at a saved moment or across a history range.
struct AppSnapshot: Codable, Hashable, Identifiable {
    let appID: String
    let name: String
    let bundlePath: String?
    let cpu: Double          // percent of one core (average for the period)
    let memory: UInt64       // peak footprint for the period
    var id: String { appID }
}

struct Moment: Identifiable, Hashable {
    let id: Int64
    let date: Date
    var note: String
    let cpu: Double
    let memoryUsed: UInt64
    let memoryTotal: UInt64
    let apps: [AppSnapshot]
}

/// Aggregate of one app's recorded activity over a range.
struct AppHistory: Identifiable, Hashable {
    let appID: String
    let name: String
    let bundlePath: String?
    let cpuSeconds: Double   // total CPU time used across the range
    let peakMemory: UInt64
    let minutesActive: Int
    var id: String { appID }
}

/// Local-only history: one system snapshot per minute plus the top apps for that minute,
/// kept for `retention`, and user-saved moments kept until deleted.
@MainActor
final class HistoryStore {
    nonisolated static let retention: TimeInterval = 30 * 24 * 60 * 60

    private let database: Database?

    nonisolated static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Gauge", isDirectory: true).appendingPathComponent("history.sqlite")
    }

    init(url: URL = HistoryStore.defaultURL) {
        do {
            database = try Database(url: url)
        } catch {
            print("Gauge: history disabled, could not open database: \(error)")
            database = nil
        }
        migrate()
        prune()
    }

    private func migrate() {
        database?.execute("""
            CREATE TABLE IF NOT EXISTS system_snapshots (
                ts REAL PRIMARY KEY,
                cpu REAL NOT NULL,
                mem_used INTEGER NOT NULL,
                mem_total INTEGER NOT NULL,
                net_in REAL NOT NULL,
                net_out REAL NOT NULL,
                disk_read REAL NOT NULL,
                disk_write REAL NOT NULL,
                gpu REAL,
                battery REAL,
                charging INTEGER
            )
            """)
        database?.execute("""
            CREATE TABLE IF NOT EXISTS app_snapshots (
                ts REAL NOT NULL,
                app_id TEXT NOT NULL,
                name TEXT NOT NULL,
                bundle_path TEXT,
                cpu REAL NOT NULL,
                memory INTEGER NOT NULL
            )
            """)
        database?.execute("CREATE INDEX IF NOT EXISTS app_snapshots_ts ON app_snapshots(ts)")
        database?.execute("""
            CREATE TABLE IF NOT EXISTS moments (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                note TEXT NOT NULL DEFAULT '',
                cpu REAL NOT NULL,
                mem_used INTEGER NOT NULL,
                mem_total INTEGER NOT NULL,
                apps_json TEXT NOT NULL
            )
            """)
    }

    func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.retention).timeIntervalSince1970
        database?.execute("DELETE FROM system_snapshots WHERE ts < ?", [.double(cutoff)])
        database?.execute("DELETE FROM app_snapshots WHERE ts < ?", [.double(cutoff)])
    }

    // MARK: Snapshots

    func record(_ sample: SystemSample, apps: [AppSnapshot]) {
        guard let database else { return }
        let ts = sample.date.timeIntervalSince1970
        database.transaction {
            database.execute(
                "INSERT OR REPLACE INTO system_snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [
                    .double(ts), .double(sample.cpu),
                    .int(Int64(sample.memoryUsed)), .int(Int64(sample.memoryTotal)),
                    .double(sample.netIn), .double(sample.netOut),
                    .double(sample.diskRead), .double(sample.diskWrite),
                    .optional(sample.gpu), .optional(sample.battery?.level),
                    sample.battery.map { .int($0.isCharging ? 1 : 0) } ?? .null,
                ]
            )
            for app in apps {
                database.execute(
                    "INSERT INTO app_snapshots VALUES (?, ?, ?, ?, ?, ?)",
                    [
                        .double(ts), .text(app.appID), .text(app.name),
                        app.bundlePath.map(SQLValue.text) ?? .null,
                        .double(app.cpu), .int(Int64(app.memory)),
                    ]
                )
            }
        }
    }

    /// System history averaged into buckets so long ranges stay light to chart.
    func series(from start: Date, to end: Date, maxPoints: Int = 360) -> [SystemSample] {
        guard let database else { return [] }
        let span = end.timeIntervalSince(start)
        let bucket = max(60, (span / Double(maxPoints)).rounded(.up))
        return database.query(
            """
            SELECT CAST(ts / ?1 AS INTEGER) * ?1 AS bucket,
                   AVG(cpu), AVG(mem_used), MAX(mem_total), AVG(net_in), AVG(net_out),
                   AVG(disk_read), AVG(disk_write), AVG(gpu), AVG(battery), MAX(charging)
            FROM system_snapshots
            WHERE ts BETWEEN ?2 AND ?3
            GROUP BY bucket ORDER BY bucket
            """,
            [.double(bucket), .double(start.timeIntervalSince1970), .double(end.timeIntervalSince1970)]
        ) { row in
            SystemSample(
                date: Date(timeIntervalSince1970: row.double(0)),
                cpu: row.double(1),
                memoryUsed: UInt64(row.double(2)),
                memoryTotal: UInt64(row.int(3)),
                netIn: row.double(4),
                netOut: row.double(5),
                diskRead: row.double(6),
                diskWrite: row.double(7),
                gpu: row.optionalDouble(8),
                battery: row.optionalDouble(9).map {
                    BatteryState(level: $0, isCharging: row.int(10) == 1, onAC: row.int(10) == 1)
                }
            )
        }
    }

    /// Apps ranked by total CPU time across the range.
    func topApps(from start: Date, to end: Date, limit: Int = 15) -> [AppHistory] {
        guard let database else { return [] }
        return database.query(
            """
            SELECT app_id, MAX(name), MAX(bundle_path), SUM(cpu), MAX(memory), COUNT(*)
            FROM app_snapshots
            WHERE ts BETWEEN ? AND ?
            GROUP BY app_id
            ORDER BY SUM(cpu) DESC
            LIMIT ?
            """,
            [.double(start.timeIntervalSince1970), .double(end.timeIntervalSince1970), .int(Int64(limit))]
        ) { row in
            AppHistory(
                appID: row.text(0),
                name: row.text(1),
                bundlePath: row.isNull(2) ? nil : row.text(2),
                // Each row is a one-minute average in percent of a core.
                cpuSeconds: row.double(3) / 100 * 60,
                peakMemory: UInt64(row.int(4)),
                minutesActive: Int(row.int(5))
            )
        }
    }

    /// The recorded top apps for the snapshot closest to `date` (within `tolerance`).
    func apps(near date: Date, tolerance: TimeInterval = 180) -> (date: Date, apps: [AppSnapshot])? {
        guard let database else { return nil }
        let ts = date.timeIntervalSince1970
        // Closure passed as a plain argument: a trailing closure inside a `guard`
        // condition reads as the statement body, and the compiler warns about it.
        guard let nearest = database.query(
            "SELECT ts FROM system_snapshots WHERE ts BETWEEN ? AND ? ORDER BY ABS(ts - ?) LIMIT 1",
            [.double(ts - tolerance), .double(ts + tolerance), .double(ts)],
            { $0.double(0) }
        ).first else { return nil }
        let apps = database.query(
            "SELECT app_id, name, bundle_path, cpu, memory FROM app_snapshots WHERE ts = ? ORDER BY cpu DESC",
            [.double(nearest)]
        ) { row in
            AppSnapshot(
                appID: row.text(0), name: row.text(1), bundlePath: row.isNull(2) ? nil : row.text(2),
                cpu: row.double(3), memory: UInt64(row.int(4))
            )
        }
        return (Date(timeIntervalSince1970: nearest), apps)
    }

    /// Every recorded system snapshot as CSV.
    func exportCSV() -> String {
        guard let database else { return "" }
        let formatter = ISO8601DateFormatter()
        var lines = ["time,cpu_percent,memory_used_bytes,memory_total_bytes,net_in_bps,net_out_bps,disk_read_bps,disk_write_bps,gpu_percent,battery_percent,charging"]
        lines += database.query(
            "SELECT ts, cpu, mem_used, mem_total, net_in, net_out, disk_read, disk_write, gpu, battery, charging FROM system_snapshots ORDER BY ts"
        ) { row in
            [
                formatter.string(from: Date(timeIntervalSince1970: row.double(0))),
                String(format: "%.1f", row.double(1) * 100),
                String(row.int(2)), String(row.int(3)),
                String(format: "%.0f", row.double(4)), String(format: "%.0f", row.double(5)),
                String(format: "%.0f", row.double(6)), String(format: "%.0f", row.double(7)),
                row.isNull(8) ? "" : String(format: "%.1f", row.double(8) * 100),
                row.isNull(9) ? "" : String(format: "%.0f", row.double(9) * 100),
                row.isNull(10) ? "" : String(row.int(10)),
            ].joined(separator: ",")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    var oldestSnapshot: Date? {
        database?.query("SELECT MIN(ts) FROM system_snapshots") { row in
            row.isNull(0) ? nil : Date(timeIntervalSince1970: row.double(0))
        }.first ?? nil
    }

    // MARK: Moments

    @discardableResult
    func saveMoment(sample: SystemSample, apps: [AppSnapshot], note: String) -> Moment? {
        guard let database else { return nil }
        let json = (try? JSONEncoder().encode(apps)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let ok = database.execute(
            "INSERT INTO moments (ts, note, cpu, mem_used, mem_total, apps_json) VALUES (?, ?, ?, ?, ?, ?)",
            [
                .double(sample.date.timeIntervalSince1970), .text(note), .double(sample.cpu),
                .int(Int64(sample.memoryUsed)), .int(Int64(sample.memoryTotal)), .text(json),
            ]
        )
        guard ok else { return nil }
        return Moment(
            id: database.lastInsertID, date: sample.date, note: note, cpu: sample.cpu,
            memoryUsed: sample.memoryUsed, memoryTotal: sample.memoryTotal, apps: apps
        )
    }

    func moments() -> [Moment] {
        guard let database else { return [] }
        return database.query("SELECT id, ts, note, cpu, mem_used, mem_total, apps_json FROM moments ORDER BY ts DESC") { row in
            let apps = (try? JSONDecoder().decode([AppSnapshot].self, from: Data(row.text(6).utf8))) ?? []
            return Moment(
                id: row.int(0),
                date: Date(timeIntervalSince1970: row.double(1)),
                note: row.text(2),
                cpu: row.double(3),
                memoryUsed: UInt64(row.int(4)),
                memoryTotal: UInt64(row.int(5)),
                apps: apps
            )
        }
    }

    func updateNote(_ note: String, for id: Int64) {
        database?.execute("UPDATE moments SET note = ? WHERE id = ?", [.text(note), .int(id)])
    }

    /// Removes recorded snapshots. Saved moments are kept unless `includingMoments`.
    func clear(includingMoments: Bool) {
        database?.execute("DELETE FROM system_snapshots")
        database?.execute("DELETE FROM app_snapshots")
        if includingMoments { database?.execute("DELETE FROM moments") }
        database?.execute("VACUUM")
    }

    func deleteMoment(_ id: Int64) {
        database?.execute("DELETE FROM moments WHERE id = ?", [.int(id)])
    }
}

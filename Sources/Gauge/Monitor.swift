import Foundation
import Observation
import UserNotifications

struct ActivityAlert: Identifiable, Hashable {
    enum Kind: String { case sustainedCPU, memoryGrowth }

    let id = UUID()
    let date: Date
    let kind: Kind
    let appID: String
    let appName: String
    let bundlePath: String?
    let title: String
    let detail: String
}

/// Samples the machine on a timer, keeps a short live buffer for charts,
/// writes a one-minute average to local history, and raises activity alerts.
@Observable
@MainActor
final class Monitor {
    static let liveWindow: TimeInterval = 10 * 60
    static let snapshotInterval: TimeInterval = 60
    static let appsPerSnapshot = 12
    static let alertCooldown: TimeInterval = 10 * 60

    private(set) var samples: [SystemSample] = []
    private(set) var details = SystemDetails()
    private(set) var apps: [AppUsage] = []
    private(set) var moments: [Moment] = []
    private(set) var alerts: [ActivityAlert] = []
    private(set) var isPaused = false
    /// Bumped whenever history is written so history views can refresh.
    private(set) var historyRevision = 0

    /// Set by the main window; sampling slows down while nothing is on screen.
    var isWindowVisible = false {
        didSet { if oldValue != isWindowVisible { reschedule() } }
    }

    var latest: SystemSample? { samples.last }
    var interval: TimeInterval {
        let key = isWindowVisible ? Pref.visibleInterval : Pref.hiddenInterval
        return max(1, Pref.defaults.double(forKey: key))
    }

    let store: HistoryStore

    @ObservationIgnored private let queue = DispatchQueue(label: "gauge.sampler", qos: .utility)
    @ObservationIgnored private let systemSampler = SystemSampler()
    @ObservationIgnored private let processSampler = ProcessSampler()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var scheduledInterval: TimeInterval = 0
    @ObservationIgnored private var minuteStart = Date()
    @ObservationIgnored private var minuteSamples: [SystemSample] = []
    @ObservationIgnored private var minuteApps: [String: AppSnapshot] = [:]
    @ObservationIgnored private var minuteTicks = 0
    @ObservationIgnored private var cpuStreaks: [String: Date] = [:]
    @ObservationIgnored private var memoryTrail: [String: [(date: Date, bytes: UInt64)]] = [:]
    @ObservationIgnored private var lastAlerted: [String: Date] = [:]
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?

    init(store: HistoryStore? = nil) {
        self.store = store ?? HistoryStore()
        moments = self.store.moments()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescheduleIfIntervalChanged() }
        }
        start()
    }

    // MARK: Timer

    func start() {
        isPaused = false
        tick()
        reschedule()
    }

    func pause() {
        isPaused = true
        timer?.invalidate()
        timer = nil
    }

    func togglePause() { isPaused ? start() : pause() }

    private func reschedule() {
        guard !isPaused else { return }
        timer?.invalidate()
        scheduledInterval = interval
        let timer = Timer(timeInterval: scheduledInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = scheduledInterval * 0.15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func rescheduleIfIntervalChanged() {
        if !isPaused, interval != scheduledInterval { reschedule() }
    }

    private func tick() {
        let systemSampler = systemSampler
        let processSampler = processSampler
        queue.async {
            let (sample, details) = systemSampler.sample()
            let apps = processSampler.sample()
            Task { @MainActor [weak self] in self?.apply(sample, details, apps) }
        }
    }

    private func apply(_ sample: SystemSample, _ details: SystemDetails, _ apps: [AppUsage]) {
        samples.append(sample)
        let cutoff = sample.date.addingTimeInterval(-Self.liveWindow)
        if let firstKept = samples.firstIndex(where: { $0.date >= cutoff }), firstKept > 0 {
            samples.removeFirst(firstKept)
        }
        self.details = details
        self.apps = apps
        accumulate(sample, apps)
        checkSustainedCPU(apps, at: sample.date)
    }

    // MARK: Minute snapshots

    private func accumulate(_ sample: SystemSample, _ apps: [AppUsage]) {
        // A long gap means the Mac slept; don't smear the old minute across it.
        if let last = minuteSamples.last, sample.date.timeIntervalSince(last.date) > Self.snapshotInterval {
            resetMinute(at: sample.date)
        }

        minuteSamples.append(sample)
        minuteTicks += 1
        for app in apps where app.cpu > 0 || app.memory > 0 {
            let previous = minuteApps[app.id]
            minuteApps[app.id] = AppSnapshot(
                appID: app.id,
                name: app.name,
                bundlePath: app.bundlePath,
                cpu: (previous?.cpu ?? 0) + app.cpu,               // summed; averaged on flush
                memory: max(previous?.memory ?? 0, app.memory)
            )
        }

        if sample.date.timeIntervalSince(minuteStart) >= Self.snapshotInterval {
            flushMinute(at: sample.date)
        }
    }

    private func flushMinute(at date: Date) {
        // Need at least a couple of deltas for a meaningful average.
        guard minuteSamples.count >= 2 else { return resetMinute(at: date) }

        let averaged = Self.average(minuteSamples, at: date)
        let ticks = Double(minuteTicks)
        let averagedApps = minuteApps.values
            .map { AppSnapshot(appID: $0.appID, name: $0.name, bundlePath: $0.bundlePath, cpu: $0.cpu / ticks, memory: $0.memory) }
            .sorted { $0.cpu == $1.cpu ? $0.memory > $1.memory : $0.cpu > $1.cpu }

        store.record(averaged, apps: Array(averagedApps.prefix(Self.appsPerSnapshot)))
        store.prune(now: date)
        historyRevision += 1
        checkMemoryGrowth(averagedApps, at: date)
        resetMinute(at: date)
    }

    private func resetMinute(at date: Date) {
        minuteStart = date
        minuteSamples.removeAll(keepingCapacity: true)
        minuteApps.removeAll(keepingCapacity: true)
        minuteTicks = 0
    }

    static func average(_ samples: [SystemSample], at date: Date) -> SystemSample {
        let count = Double(samples.count)
        func mean(_ value: (SystemSample) -> Double) -> Double { samples.reduce(0) { $0 + value($1) } / count }
        let gpus = samples.compactMap(\.gpu)
        return SystemSample(
            date: date,
            cpu: mean(\.cpu),
            memoryUsed: UInt64(mean { Double($0.memoryUsed) }),
            memoryTotal: samples.last?.memoryTotal ?? 0,
            netIn: mean(\.netIn),
            netOut: mean(\.netOut),
            diskRead: mean(\.diskRead),
            diskWrite: mean(\.diskWrite),
            gpu: gpus.isEmpty ? nil : gpus.reduce(0, +) / Double(gpus.count),
            battery: samples.last?.battery
        )
    }

    // MARK: Alerts

    private var alertsEnabled: Bool { Pref.defaults.bool(forKey: Pref.alertsEnabled) }

    private func checkSustainedCPU(_ apps: [AppUsage], at date: Date) {
        guard alertsEnabled else { return cpuStreaks.removeAll() }
        let threshold = Pref.defaults.double(forKey: Pref.alertCPUThreshold)
        let sustain = Pref.defaults.double(forKey: Pref.alertSustainSeconds)

        var busy = Set<String>()
        for app in apps where app.cpu >= threshold {
            busy.insert(app.id)
            let start = cpuStreaks[app.id] ?? date
            cpuStreaks[app.id] = start
            if date.timeIntervalSince(start) >= sustain {
                raise(.sustainedCPU, for: app.id, name: app.name, bundle: app.bundlePath, at: date,
                      title: "\(app.name) has been busy for a while",
                      detail: "Over \(Int(threshold))% of a core for \(Format.duration(date.timeIntervalSince(start))), now at \(Format.cpu(app.cpu)).")
            }
        }
        cpuStreaks = cpuStreaks.filter { busy.contains($0.key) }
    }

    private func checkMemoryGrowth(_ apps: [AppSnapshot], at date: Date) {
        guard alertsEnabled else { return memoryTrail.removeAll() }
        let growth = UInt64(Pref.defaults.double(forKey: Pref.alertMemoryGrowthGB) * 1_073_741_824)
        let hourAgo = date.addingTimeInterval(-3600)

        var seen = Set<String>()
        for app in apps {
            seen.insert(app.appID)
            var trail = (memoryTrail[app.appID] ?? []).filter { $0.date >= hourAgo }
            trail.append((date, app.memory))
            memoryTrail[app.appID] = trail
            guard let lowest = trail.map(\.bytes).min(), app.memory > lowest, app.memory - lowest >= growth else { continue }
            raise(.memoryGrowth, for: app.appID, name: app.name, bundle: app.bundlePath, at: date,
                  title: "\(app.name) keeps using more memory",
                  detail: "Up \(Format.bytes(app.memory - lowest)) in the last hour, now \(Format.bytes(app.memory)).")
        }
        memoryTrail = memoryTrail.filter { seen.contains($0.key) }
    }

    private func raise(_ kind: ActivityAlert.Kind, for appID: String, name: String, bundle: String?, at date: Date, title: String, detail: String) {
        let key = kind.rawValue + "|" + appID
        if let last = lastAlerted[key], date.timeIntervalSince(last) < Self.alertCooldown { return }
        lastAlerted[key] = date
        alerts.insert(ActivityAlert(date: date, kind: kind, appID: appID, appName: name, bundlePath: bundle, title: title, detail: detail), at: 0)
        if alerts.count > 100 { alerts.removeLast(alerts.count - 100) }
        if Pref.defaults.bool(forKey: Pref.alertNotifications) { Self.notify(title: title, body: detail) }
    }

    func dismiss(_ alert: ActivityAlert) { alerts.removeAll { $0.id == alert.id } }
    func dismissAllAlerts() { alerts.removeAll() }

    /// Notifications need a real app bundle; `swift run` builds silently skip them.
    static var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestNotificationPermission() async -> Bool {
        guard canNotify else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    private static func notify(title: String, body: String) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Moments

    @discardableResult
    func saveMoment(note: String = "") -> Moment? {
        guard let sample = latest else { return nil }
        let snapshot = apps.prefix(Self.appsPerSnapshot).map {
            AppSnapshot(appID: $0.id, name: $0.name, bundlePath: $0.bundlePath, cpu: $0.cpu, memory: $0.memory)
        }
        let moment = store.saveMoment(sample: sample, apps: snapshot, note: note)
        moments = store.moments()
        return moment
    }

    func updateNote(_ note: String, for moment: Moment) {
        store.updateNote(note, for: moment.id)
        moments = store.moments()
    }

    func clearHistory(includingMoments: Bool) {
        store.clear(includingMoments: includingMoments)
        moments = store.moments()
        historyRevision += 1
    }

    func delete(_ moment: Moment) {
        store.deleteMoment(moment.id)
        moments = store.moments()
    }
}

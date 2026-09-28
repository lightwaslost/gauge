import Foundation

/// UserDefaults keys shared by `@AppStorage` in views and the monitor.
enum Pref {
    static let visibleInterval = "sampling.visibleInterval"     // seconds
    static let hiddenInterval = "sampling.hiddenInterval"
    static let alertsEnabled = "alerts.enabled"
    static let alertCPUThreshold = "alerts.cpuThreshold"        // percent of one core
    static let alertSustainSeconds = "alerts.sustainSeconds"
    static let alertMemoryGrowthGB = "alerts.memoryGrowthGB"    // within one hour
    static let alertNotifications = "alerts.notifications"
    static let menuBarMetric = "menuBar.metric"                 // Metric raw value
    static let menuBarStyle = "menuBar.style"                   // MenuBarStyle raw value
    static let showBackground = "apps.showBackground"
    static let projectsIncludeIdle = "projects.includeIdle"
    static let onboardingVersion = "onboarding.completedVersion"

    /// Bump to show the welcome window again after a release that changes it.
    static let currentOnboardingVersion = 1

    static func register() {
        UserDefaults.standard.register(defaults: [
            visibleInterval: 2.0,
            hiddenInterval: 10.0,
            alertsEnabled: true,
            alertCPUThreshold: 80.0,
            alertSustainSeconds: 120.0,
            alertMemoryGrowthGB: 1.0,
            alertNotifications: false,
            menuBarMetric: Metric.cpu.rawValue,
            menuBarStyle: MenuBarStyle.iconAndValue.rawValue,
            showBackground: false,
            projectsIncludeIdle: true,
            onboardingVersion: 0,
        ])
    }

    static var defaults: UserDefaults { .standard }
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case iconAndValue, valueOnly, iconOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .iconAndValue: "Icon and value"
        case .valueOnly: "Value only"
        case .iconOnly: "Icon only"
        }
    }
}

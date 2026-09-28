import SwiftUI

struct AlertsView: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage(Pref.alertsEnabled) private var enabled = true
    @AppStorage(Pref.alertCPUThreshold) private var threshold = 80.0
    @AppStorage(Pref.alertSustainSeconds) private var sustain = 120.0
    @State private var selectedApp: AppSelection?

    var body: some View {
        PageScroll {
            PageHeader(title: "Alerts", subtitle: "Apps that stayed busy or kept growing while Gauge was watching.")
            HStack {
                Text(enabled
                     ? "Watching for apps over \(Int(threshold))% CPU for \(Format.duration(sustain)), or growing \(Format.bytes(UInt64(Pref.defaults.double(forKey: Pref.alertMemoryGrowthGB) * 1_073_741_824))) in an hour."
                     : "Alerts are off.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if !monitor.alerts.isEmpty {
                    Button("Clear All") { monitor.dismissAllAlerts() }
                }
                SettingsLink { Label("Configure…", systemImage: "slider.horizontal.3") }
            }

            if monitor.alerts.isEmpty {
                Panel {
                    ContentUnavailableView(
                        "All quiet",
                        systemImage: "bell.slash",
                        description: Text("Alerts from this session appear here. They aren't kept after Gauge quits.")
                    )
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(monitor.alerts) { alert in
                        AlertRow(alert: alert, open: {
                            if monitor.apps.contains(where: { $0.id == alert.appID }) {
                                selectedApp = AppSelection(id: alert.appID)
                            }
                        }, dismiss: { monitor.dismiss(alert) })
                    }
                }
            }
        }
        .navigationTitle("Alerts")
        .sheet(item: $selectedApp) { AppDetailSheet(appID: $0.id) }
    }
}

private struct AlertRow: View {
    @Environment(Monitor.self) private var monitor
    let alert: ActivityAlert
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: alert.kind == .sustainedCPU ? "flame" : "arrow.up.right")
                .foregroundStyle(.orange)
                .frame(width: 20)
                .padding(.top, 2)
            AppIconView(bundlePath: alert.bundlePath, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.title).font(.headline)
                Text(alert.detail).foregroundStyle(.secondary)
                Text(alert.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            if monitor.apps.contains(where: { $0.id == alert.appID }) {
                Button("Inspect", action: open)
            }
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly).buttonStyle(.borderless)
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}

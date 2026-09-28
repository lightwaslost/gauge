import AppKit
import SwiftUI

@main
struct GaugeApp: App {
    @State private var monitor = Monitor()

    init() {
        // Needed when launched as a bare executable (`swift run`) rather than a bundle.
        SelfTest.runIfRequested()
        Pref.register()
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Gauge", id: "main") {
            ContentView()
                .environment(monitor)
                .frame(minWidth: 820, minHeight: 540)
        }
        .defaultSize(width: 1040, height: 700)

        Window("Welcome to Gauge", id: WelcomeView.windowID) {
            WelcomeView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView().environment(monitor)
        }

        // Keeps sampling (and recording history) after the window is closed.
        MenuBarExtra {
            MenuBarView().environment(monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

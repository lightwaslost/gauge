import AppKit
import SwiftUI

/// Lets a script drive the UI for recording demos. Only active when launched with `--demo`.
///
/// Commands arrive as distributed notifications named `app.gauge.demo`, with the command
/// as the notification object, e.g. `section:cpu`, `scroll:down`, `openApp`, `closeSheet`,
/// `saveMoment`, `resize:1440x900`, `scanStorage`.
enum DemoDriver {
    static let isEnabled = CommandLine.arguments.contains("--demo")
    static let navigate = Notification.Name("gauge.demo.navigate")
    static let openApp = Notification.Name("gauge.demo.openApp")
    static let closeSheet = Notification.Name("gauge.demo.closeSheet")
    static let scanStorage = Notification.Name("gauge.demo.scanStorage")

    @MainActor private static var observer: NSObjectProtocol?

    @MainActor
    static func start(monitor: Monitor) {
        guard isEnabled, observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.gauge.demo"), object: nil, queue: .main
        ) { note in
            guard let command = note.object as? String else { return }
            MainActor.assumeIsolated { handle(command, monitor: monitor) }
        }
    }

    @MainActor
    private static func handle(_ command: String, monitor: Monitor) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "section":
            NotificationCenter.default.post(name: navigate, object: argument)
            scrollToTop()
        case "scroll":
            scroll(argument)
        case "openApp":
            NotificationCenter.default.post(name: openApp, object: nil)
        case "closeSheet":
            NotificationCenter.default.post(name: closeSheet, object: nil)
        case "saveMoment":
            monitor.saveMoment(note: argument)
        case "scanStorage":
            NotificationCenter.default.post(name: scanStorage, object: nil)
        case "resize":
            let size = argument.split(separator: "x").compactMap { Double($0) }
            if size.count == 2, let window = mainWindow {
                // Pull the window onto whichever Space the user is looking at.
                window.collectionBehavior.insert(.moveToActiveSpace)
                let screen = (NSScreen.main ?? window.screen)?.visibleFrame ?? .zero
                let frame = NSRect(x: screen.midX - size[0] / 2, y: screen.midY - size[1] / 2, width: size[0], height: size[1])
                window.setFrame(frame, display: true)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
        default:
            break
        }
    }

    @MainActor private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true && $0.isVisible }
            ?? NSApp.windows.filter { $0.isVisible && $0.frame.width > 600 }.max { $0.frame.width < $1.frame.width }
    }

    /// The detail pane's scroll view: the largest one that isn't the sidebar.
    @MainActor private static var detailScrollView: NSScrollView? {
        guard let root = mainWindow?.contentView else { return nil }
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.frame.width > 400 { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    @MainActor
    private static func scrollToTop() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let scroll = detailScrollView, let document = scroll.documentView else { return }
            let top = document.isFlipped ? 0 : max(0, document.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: top))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// `down` scrolls one screen, `bottom`/`top` jump smoothly, a number scrolls that many points.
    @MainActor
    private static func scroll(_ argument: String) {
        guard let scroll = detailScrollView, let document = scroll.documentView else { return }
        let visible = scroll.contentView.bounds
        let maxY = max(0, document.frame.height - visible.height)
        let current = document.isFlipped ? visible.origin.y : maxY - visible.origin.y
        let target: CGFloat = switch argument {
        case "top": 0
        case "bottom": maxY
        case "down": min(maxY, current + visible.height * 0.8)
        case "up": max(0, current - visible.height * 0.8)
        default: min(maxY, max(0, current + CGFloat(Double(argument) ?? 0)))
        }
        let y = document.isFlipped ? target : maxY - target
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.9
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            scroll.contentView.animator().setBoundsOrigin(NSPoint(x: visible.origin.x, y: y))
        } completionHandler: {
            MainActor.assumeIsolated { scroll.reflectScrolledClipView(scroll.contentView) }
        }
    }
}

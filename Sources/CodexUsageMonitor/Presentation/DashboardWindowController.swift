import AppKit
import SwiftUI

@MainActor
protocol DashboardPresenting: AnyObject {
    func showDashboard()
}

@MainActor
final class DashboardWindowController: NSWindowController, DashboardPresenting {
    private let model: UsageViewModel
    let launchAtLogin: any LaunchAtLoginServicing

    init(
        model: UsageViewModel,
        launchAtLogin: any LaunchAtLoginServicing
    ) {
        self.model = model
        self.launchAtLogin = launchAtLogin
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func showDashboard() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Codex Usage Monitor"
            window.contentView = NSHostingView(rootView: UsagePopoverView(
                model: model,
                launchAtLogin: launchAtLogin
            ))
            window.center()
            window.isReleasedWhenClosed = false
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

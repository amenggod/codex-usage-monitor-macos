import AppKit
import SwiftUI

@MainActor
final class AppKitMenuBarController: NSObject, MenuBarControlling {
    private let model: UsageViewModel
    private let launchAtLogin: any LaunchAtLoginServicing
    private let dashboard: any DashboardPresenting
    private let visibilityStore: MenuBarVisibilityStore
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var refreshTimer: Timer?

    init(
        model: UsageViewModel,
        launchAtLogin: any LaunchAtLoginServicing,
        dashboard: any DashboardPresenting,
        visibilityStore: MenuBarVisibilityStore
    ) {
        self.model = model
        self.launchAtLogin = launchAtLogin
        self.dashboard = dashboard
        self.visibilityStore = visibilityStore
        super.init()
    }

    func start() {
        visibilityStore.setVisibilityChangeHandler { [weak self] _ in
            self?.synchronizeVisibility()
        }
        synchronizeVisibility()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: UsagePresentationPolicy.refreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTitle()
            }
        }
    }

    private func synchronizeVisibility() {
        if visibilityStore.isVisible {
            installStatusItemIfNeeded()
            refreshTitle()
        } else {
            removeStatusItem()
        }
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.toolTip = "Codex 用量"
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 520, height: 480)
        popover.contentViewController = NSHostingController(rootView: UsagePopoverView(
            model: model,
            launchAtLogin: launchAtLogin,
            dashboard: dashboard
        ))
        self.popover = popover
    }

    private func removeStatusItem() {
        popover?.performClose(nil)
        popover = nil
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func refreshTitle() {
        guard let button = statusItem?.button else { return }
        button.title = MenuBarFormatter.title(limits: model.snapshot.limits)
    }

    @objc
    private func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

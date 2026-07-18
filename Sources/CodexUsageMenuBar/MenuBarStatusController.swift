import AppKit
import CodexUsageMenuBarCore
import Observation
import SwiftUI

@MainActor
final class MenuBarStatusController: NSObject {
    private let model: MenuBarSnapshotModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    init(model: MenuBarSnapshotModel, router: MenuBarActionRouter) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: 26)
        super.init()

        popover.contentSize = NSSize(width: 420, height: 430)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(model: model, router: router)
        )

        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "chart.bar.fill",
                accessibilityDescription: "Codex 用量"
            )
            image?.size = NSSize(width: 18, height: 18)
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        updateStatusItem()
        observeDisplay()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func observeDisplay() {
        withObservationTracking {
            _ = model.presentationStatusText
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateStatusItem()
                self?.observeDisplay()
            }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let display = model.display
        button.toolTip = model.presentationStatusText
        button.setAccessibilityLabel(
            MenuBarHelperFormatting.accessibilityTitle(display)
        )
    }
}

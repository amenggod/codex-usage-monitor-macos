import AppKit
import SwiftUI

@MainActor
final class DesktopCardWindowController: NSWindowController, DesktopCardPresenting, NSWindowDelegate {
    private let model: UsageViewModel
    private let runtime: AppRuntime
    private let preferences: DesktopCardPreferences
    private let notificationCenter: NotificationCenter
    private let visibleFrameProvider: (CGPoint?, CGSize) -> CGRect
    private var isExpanded: Bool
    private var hostingView: NSHostingView<DesktopCardView>?
    private nonisolated(unsafe) var screenParametersObserver: NSObjectProtocol?

    init(
        model: UsageViewModel,
        runtime: AppRuntime,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        visibleFrameProvider: ((CGPoint?, CGSize) -> CGRect)? = nil
    ) {
        self.model = model
        self.runtime = runtime
        self.notificationCenter = notificationCenter
        self.visibleFrameProvider = visibleFrameProvider ?? Self.preferredVisibleFrame
        let preferences = DesktopCardPreferences(defaults: defaults)
        self.preferences = preferences
        isExpanded = preferences.isExpanded

        let size = isExpanded ? DesktopCardSize.expanded : DesktopCardSize.compact
        let visibleFrame = self.visibleFrameProvider(preferences.savedOrigin, size)
        let requestedOrigin = preferences.savedOrigin ?? Self.defaultOrigin(
            windowSize: size,
            visibleFrame: visibleFrame
        )
        let origin = DesktopCardPlacement.visibleOrigin(
            savedOrigin: requestedOrigin,
            windowSize: size,
            visibleFrame: visibleFrame
        )
        let panel = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.isReleasedWhenClosed = false

        super.init(window: panel)
        panel.delegate = self
        screenParametersObserver = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reclampToVisibleFrame()
            }
        }
        updateRootView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        reclampToVisibleFrame()
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded, let panel = window else { return }
        isExpanded = expanded
        preferences.setExpanded(expanded)

        let size = expanded ? DesktopCardSize.expanded : DesktopCardSize.compact
        let visibleFrame = visibleFrameProvider(panel.frame.origin, size)
        let requestedOrigin = CGPoint(x: panel.frame.minX, y: panel.frame.maxY - size.height)
        let origin = DesktopCardPlacement.visibleOrigin(
            savedOrigin: requestedOrigin,
            windowSize: size,
            visibleFrame: visibleFrame
        )
        panel.setFrame(CGRect(origin: origin, size: size), display: true, animate: true)
        preferences.saveOrigin(origin)
        updateRootView()
    }

    func windowDidMove(_ notification: Notification) {
        guard let origin = window?.frame.origin else { return }
        preferences.saveOrigin(origin)
    }

    private func updateRootView() {
        let rootView = DesktopCardView(
            model: model,
            runtime: runtime,
            isExpanded: isExpanded,
            onExpandedChange: { [weak self] expanded in
                self?.setExpanded(expanded)
            }
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView = hostingView
        self.hostingView = hostingView
    }

    private func reclampToVisibleFrame() {
        guard let panel = window else { return }
        let size = panel.frame.size
        let visibleFrame = visibleFrameProvider(panel.frame.origin, size)
        let origin = DesktopCardPlacement.visibleOrigin(
            savedOrigin: panel.frame.origin,
            windowSize: size,
            visibleFrame: visibleFrame
        )
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        preferences.saveOrigin(origin)
    }

    private static func preferredVisibleFrame(for origin: CGPoint?, windowSize: CGSize) -> CGRect {
        if let origin,
           let screen = NSScreen.screens.first(where: {
               $0.visibleFrame.intersects(CGRect(origin: origin, size: windowSize))
           }) {
            return screen.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? CGRect(origin: .zero, size: windowSize)
    }

    private static func defaultOrigin(windowSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: visibleFrame.maxX - windowSize.width - 24,
            y: visibleFrame.maxY - windowSize.height - 24
        )
    }

    deinit {
        if let screenParametersObserver {
            notificationCenter.removeObserver(screenParametersObserver)
        }
    }
}

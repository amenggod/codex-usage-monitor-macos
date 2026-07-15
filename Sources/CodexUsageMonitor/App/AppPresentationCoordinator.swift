import Foundation
import Observation

@MainActor
protocol DesktopCardPresentationControlling: AnyObject {
    func apply(mode: DisplayMode)
    func handleReopen()
}

extension DesktopCardPresentationController: DesktopCardPresentationControlling {}

@MainActor
@Observable
final class AppPresentationCoordinator {
    private let displayModeStore: DisplayModeStore
    private let desktopPresentationController: any DesktopCardPresentationControlling
    private let notificationCenter: NotificationCenter
    @ObservationIgnored
    private nonisolated(unsafe) var reopenObserver: NSObjectProtocol?
    private(set) var mode: DisplayMode
    var isMenuBarInserted: Bool

    init(
        displayModeStore: DisplayModeStore,
        desktopPresentationController: any DesktopCardPresentationControlling,
        notificationCenter: NotificationCenter = .default
    ) {
        self.displayModeStore = displayModeStore
        self.desktopPresentationController = desktopPresentationController
        self.notificationCenter = notificationCenter
        mode = displayModeStore.mode
        isMenuBarInserted = displayModeStore.showsMenuBar
        reopenObserver = notificationCenter.addObserver(
            forName: .codexUsageMonitorReopenRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleReopen()
            }
        }
    }

    func setMode(_ mode: DisplayMode) {
        displayModeStore.setMode(mode)
        desktopPresentationController.apply(mode: mode)
        self.mode = mode
        isMenuBarInserted = displayModeStore.showsMenuBar
    }

    func handleReopen() {
        desktopPresentationController.handleReopen()
    }

    deinit {
        if let reopenObserver {
            notificationCenter.removeObserver(reopenObserver)
        }
    }
}

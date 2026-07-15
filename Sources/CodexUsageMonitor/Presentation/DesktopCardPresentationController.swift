@MainActor
protocol DesktopCardPresenting: AnyObject {
    func show()
    func hide()
    func setExpanded(_ expanded: Bool)
}

@MainActor
final class DesktopCardPresentationController {
    private let surface: any DesktopCardPresenting
    private var currentMode: DisplayMode

    init(
        surface: any DesktopCardPresenting,
        displayModeStore: DisplayModeStore
    ) {
        self.surface = surface
        currentMode = displayModeStore.mode
    }

    func apply(mode: DisplayMode) {
        currentMode = mode
        if mode == .desktop || mode == .both {
            surface.show()
        } else {
            surface.hide()
        }
    }

    func handleReopen() {
        guard currentMode == .desktop || currentMode == .both else { return }
        surface.show()
    }
}

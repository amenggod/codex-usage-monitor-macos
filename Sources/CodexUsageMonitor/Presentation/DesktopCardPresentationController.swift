@MainActor
protocol DesktopCardPresenting: AnyObject {
    func show()
    func hide()
    func setExpanded(_ expanded: Bool)
}

@MainActor
final class DesktopCardPresentationController {
    private let surface: any DesktopCardPresenting
    private let displayModeStore: DisplayModeStore

    init(
        surface: any DesktopCardPresenting,
        displayModeStore: DisplayModeStore
    ) {
        self.surface = surface
        self.displayModeStore = displayModeStore
    }

    func apply(mode: DisplayMode) {
        displayModeStore.setMode(mode)
        if displayModeStore.showsDesktopCard {
            surface.show()
        } else {
            surface.hide()
        }
    }

    func handleReopen() {
        guard displayModeStore.showsDesktopCard else { return }
        surface.show()
    }
}

import AppKit

@MainActor
protocol SettingsMenuCommandPerforming {
    func performSettingsMenuCommand()
}

@MainActor
struct AppKitSettingsMenuCommandPerformer: SettingsMenuCommandPerforming {
    func performSettingsMenuCommand() {
        guard
            let submenu = NSApp.mainMenu?.items.first?.submenu,
            let itemIndex = submenu.items.firstIndex(where: {
                $0.keyEquivalent == "," && $0.isEnabled
            })
        else { return }

        submenu.performActionForItem(at: itemIndex)
    }
}

@MainActor
final class SettingsWindowPresenter: SettingsPresenting {
    private let settingsMenuCommand: any SettingsMenuCommandPerforming
    private let activateApplication: () -> Void

    init(
        settingsMenuCommand: any SettingsMenuCommandPerforming =
            AppKitSettingsMenuCommandPerformer(),
        activateApplication: @escaping () -> Void = {
            NSApp.activate(ignoringOtherApps: true)
        }
    ) {
        self.settingsMenuCommand = settingsMenuCommand
        self.activateApplication = activateApplication
    }

    func showSettings() {
        activateApplication()
        settingsMenuCommand.performSettingsMenuCommand()
    }
}

import Foundation
import Observation

@MainActor
@Observable
final class MenuBarVisibilityStore {
    private static let key = "menuBarVisible"
    private let defaults: UserDefaults
    private var visibilityChangeHandler: ((Bool) -> Void)?
    private(set) var isVisible: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.key) != nil {
            isVisible = defaults.bool(forKey: Self.key)
        } else {
            let oldMode = defaults.string(forKey: "displayMode")
            isVisible = oldMode == "menuBar" || oldMode == "both"
            defaults.set(isVisible, forKey: Self.key)
        }
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        defaults.set(visible, forKey: Self.key)
        visibilityChangeHandler?(visible)
    }

    func setVisibilityChangeHandler(_ handler: @escaping (Bool) -> Void) {
        visibilityChangeHandler = handler
    }
}

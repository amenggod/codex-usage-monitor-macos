import Foundation
import Observation

enum DisplayMode: String, CaseIterable, Identifiable, Sendable {
    case desktop
    case menuBar
    case both

    var id: String { rawValue }
}

@MainActor
@Observable
final class DisplayModeStore {
    private static let key = "displayMode"
    private let defaults: UserDefaults
    private(set) var mode: DisplayMode

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.key).flatMap(DisplayMode.init(rawValue:)) ?? .desktop
    }

    var showsDesktopCard: Bool {
        mode == .desktop || mode == .both
    }

    var showsMenuBar: Bool {
        mode == .menuBar || mode == .both
    }

    func setMode(_ mode: DisplayMode) {
        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.key)
    }
}

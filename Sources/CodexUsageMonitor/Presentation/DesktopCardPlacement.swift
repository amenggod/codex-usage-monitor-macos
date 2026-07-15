import CoreGraphics
import Foundation

enum DesktopCardSize {
    static let compact = CGSize(width: 340, height: 220)
    static let expanded = CGSize(width: 520, height: 480)
}

enum DesktopCardPlacement {
    static func visibleOrigin(
        savedOrigin: CGPoint,
        windowSize: CGSize,
        visibleFrame: CGRect
    ) -> CGPoint {
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - windowSize.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - windowSize.height)

        return CGPoint(
            x: min(max(savedOrigin.x, visibleFrame.minX), maximumX),
            y: min(max(savedOrigin.y, visibleFrame.minY), maximumY)
        )
    }
}

@MainActor
final class DesktopCardPreferences {
    private enum Key {
        static let originX = "desktopCard.origin.x"
        static let originY = "desktopCard.origin.y"
        static let expanded = "desktopCard.expanded"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var savedOrigin: CGPoint? {
        guard defaults.object(forKey: Key.originX) != nil,
              defaults.object(forKey: Key.originY) != nil else {
            return nil
        }
        return CGPoint(
            x: defaults.double(forKey: Key.originX),
            y: defaults.double(forKey: Key.originY)
        )
    }

    var isExpanded: Bool {
        defaults.bool(forKey: Key.expanded)
    }

    func saveOrigin(_ origin: CGPoint) {
        defaults.set(origin.x, forKey: Key.originX)
        defaults.set(origin.y, forKey: Key.originY)
    }

    func setExpanded(_ expanded: Bool) {
        defaults.set(expanded, forKey: Key.expanded)
    }
}

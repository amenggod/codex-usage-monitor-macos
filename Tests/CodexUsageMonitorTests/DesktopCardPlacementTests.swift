import CoreGraphics
import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite("DesktopCardPlacementTests")
struct DesktopCardPlacementTests {
    @Test func cardSizesMatchCompactAndExpandedDesign() {
        #expect(DesktopCardSize.compact == CGSize(width: 340, height: 220))
        #expect(DesktopCardSize.expanded == CGSize(width: 520, height: 480))
    }

    @Test func savedOriginIsClampedIntoVisibleFrame() {
        let origin = DesktopCardPlacement.visibleOrigin(
            savedOrigin: CGPoint(x: 2_000, y: -500),
            windowSize: DesktopCardSize.compact,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        #expect(origin.x == 1_100)
        #expect(origin.y == 0)
    }

    @Test func savedOriginRespectsAnOffsetVisibleFrame() {
        let origin = DesktopCardPlacement.visibleOrigin(
            savedOrigin: CGPoint(x: -900, y: 1_500),
            windowSize: DesktopCardSize.expanded,
            visibleFrame: CGRect(x: -400, y: 40, width: 1_600, height: 1_000)
        )

        #expect(origin.x == -400)
        #expect(origin.y == 560)
    }

    @MainActor
    @Test func injectedPreferencesPersistOriginAndExpandedState() throws {
        let suiteName = "DesktopCardPreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = DesktopCardPreferences(defaults: defaults)
        #expect(first.savedOrigin == nil)
        #expect(!first.isExpanded)

        first.saveOrigin(CGPoint(x: 123.5, y: -45.25))
        first.setExpanded(true)

        let reopened = DesktopCardPreferences(defaults: defaults)
        #expect(reopened.savedOrigin == CGPoint(x: 123.5, y: -45.25))
        #expect(reopened.isExpanded)
    }
}

import Foundation

enum TestResourceBundle {
    static func fixtureURL(
        forResource name: String,
        withExtension extensionName: String
    ) -> URL? {
#if SWIFT_PACKAGE
        Bundle.module.url(
            forResource: name,
            withExtension: extensionName,
            subdirectory: "Fixtures"
        )
#else
        let bundle = Bundle(for: BundleToken.self)
        return bundle.url(
            forResource: name,
            withExtension: extensionName,
            subdirectory: "Fixtures"
        ) ?? bundle.url(
            forResource: name,
            withExtension: extensionName
        )
#endif
    }

    private final class BundleToken: NSObject {}
}

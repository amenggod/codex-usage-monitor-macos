import Foundation

public enum LoginItemMainApplicationLocator {
    public static func mainApplicationURL(from helperBundleURL: URL) -> URL {
        var url = helperBundleURL
        for _ in 0..<4 {
            url.deleteLastPathComponent()
        }
        return url
    }
}

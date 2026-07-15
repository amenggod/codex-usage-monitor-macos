import Foundation

public enum LoginItemMainApplicationLocator {
    public static func mainApplicationURL(from helperBundleURL: URL) -> URL? {
        guard helperBundleURL.isFileURL else { return nil }
        var url = helperBundleURL.standardizedFileURL
        guard url.pathExtension == "app" else { return nil }

        url.deleteLastPathComponent()
        guard url.lastPathComponent == "LoginItems" else { return nil }

        url.deleteLastPathComponent()
        guard url.lastPathComponent == "Library" else { return nil }

        url.deleteLastPathComponent()
        guard url.lastPathComponent == "Contents" else { return nil }

        url.deleteLastPathComponent()
        guard url.pathExtension == "app" else { return nil }
        return url
    }
}

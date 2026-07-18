import AppKit
import Foundation

protocol CodexExecutableLocating: Sendable {
    func executableURL() throws -> URL
}

struct CodexExecutableLocator: CodexExecutableLocating, Sendable {
    enum LocatorError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "未找到可用的 Codex 实时限额服务"
        }
    }

    private let applicationURL: @Sendable () -> URL?
    private let fallbackURLs: [URL]
    private let environmentPath: String

    init(
        applicationURL: @escaping @Sendable () -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        },
        fallbackURLs: [URL] = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
        ],
        environmentPath: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) {
        self.applicationURL = applicationURL
        self.fallbackURLs = fallbackURLs
        self.environmentPath = environmentPath
    }

    func executableURL() throws -> URL {
        var candidates: [URL] = []
        if let appURL = applicationURL() {
            candidates.append(appURL.appending(path: "Contents/Resources/codex"))
        }
        candidates.append(contentsOf: fallbackURLs)
        candidates.append(contentsOf: environmentPath
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "codex") })

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate.standardizedFileURL
        }
        throw LocatorError.unavailable
    }
}

import Foundation

struct ProjectIdentity: Equatable, Sendable {
    let key: String
    let displayName: String
    let fullPath: String?
}

struct ProjectPathNormalizer: Sendable {
    func identity(for rawPath: String?) -> ProjectIdentity {
        guard let rawPath, !rawPath.isEmpty else {
            return ProjectIdentity(key: "unknown", displayName: "未知项目", fullPath: nil)
        }

        let expanded = NSString(string: rawPath).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        let displayName = URL(fileURLWithPath: resolved).lastPathComponent

        return ProjectIdentity(
            key: resolved,
            displayName: displayName.isEmpty ? resolved : displayName,
            fullPath: resolved
        )
    }
}

import AppKit
import CodexUsageShared
import Darwin

@main
struct LoginItemMain {
    static func main() {
        let mainURL = LoginItemMainApplicationLocator.mainApplicationURL(
            from: Bundle.main.bundleURL
        )
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.arguments = ["--background"]
        NSWorkspace.shared.openApplication(
            at: mainURL,
            configuration: configuration
        ) { _, error in
            exit(error == nil ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        RunLoop.main.run()
    }
}

protocol AppRuntimeStarting: Sendable {
    func start() async
}

extension UsageViewModel: AppRuntimeStarting {}

@MainActor
final class AppRuntime {
    private let starter: any AppRuntimeStarting
    private var hasLaunched = false

    init(starter: any AppRuntimeStarting) {
        self.starter = starter
    }

    func launch() async {
        guard !hasLaunched else { return }
        hasLaunched = true
        await starter.start()
    }
}

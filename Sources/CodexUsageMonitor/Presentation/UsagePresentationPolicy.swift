enum UsagePresentationPolicy {
    static func visibleWindows(limits: [LimitStatus]) -> [LimitWindow] {
        var windows: [LimitWindow] = []
        if limits.contains(where: { $0.window == .fiveHours }) {
            windows.append(.fiveHours)
        }
        windows.append(.week)
        return windows
    }
}

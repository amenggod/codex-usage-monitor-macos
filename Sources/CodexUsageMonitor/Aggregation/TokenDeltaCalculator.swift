enum TokenDeltaCalculator {
    static func delta(
        lastUsage: TokenUsage?,
        cumulativeUsage: TokenUsage?,
        previousCumulative: TokenUsage?
    ) -> TokenUsage {
        if let lastUsage {
            return lastUsage
        }

        guard let cumulativeUsage else {
            return .zero
        }

        guard let previousCumulative else {
            return cumulativeUsage
        }

        return cumulativeUsage - previousCumulative
    }
}

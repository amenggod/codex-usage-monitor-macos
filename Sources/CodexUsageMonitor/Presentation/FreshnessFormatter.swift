import Foundation

enum FreshnessFormatter {
    static func text(for freshness: DataFreshness) -> String {
        switch freshness {
        case .loading:
            "正在读取本地用量…"
        case let .fresh(date):
            "更新于 \(date.formatted(date: .omitted, time: .shortened))"
        case let .stale(date):
            "数据可能已过期 · \(date.formatted(date: .omitted, time: .shortened))"
        case let .partial(_, failedFiles):
            "部分数据等待恢复 · \(failedFiles) 个文件"
        case let .rebuilding(completed, total):
            "正在重建 · \(completed)/\(total)"
        case .noData:
            "尚无本地用量数据"
        case let .failed(message):
            "读取失败：\(message)"
        }
    }

    static func symbol(for freshness: DataFreshness) -> String {
        switch freshness {
        case .loading:
            "clock"
        case .fresh:
            "checkmark.circle"
        case .stale:
            "exclamationmark.arrow.triangle.2.circlepath"
        case .partial, .failed:
            "exclamationmark.triangle"
        case .rebuilding:
            "arrow.triangle.2.circlepath"
        case .noData:
            "tray"
        }
    }
}

enum LimitFreshnessFormatter {
    static func text(for freshness: LimitDataFreshness) -> String {
        switch freshness {
        case let .fresh(date):
            "实时限额更新于 \(date.formatted(date: .omitted, time: .shortened))"
        case let .stale(date):
            "上次实时同步 \(date.formatted(date: .omitted, time: .shortened))"
        case let .unavailable(_, message):
            "实时限额不可用：\(message)"
        }
    }

    static func symbol(for freshness: LimitDataFreshness) -> String {
        switch freshness {
        case .fresh: "bolt.horizontal.circle"
        case .stale: "clock.badge.exclamationmark"
        case .unavailable: "exclamationmark.triangle"
        }
    }
}

import Foundation
import UserNotifications

protocol NotificationSending: Sendable {
    func isEnabled() async -> Bool
    func requestAuthorization() async throws -> Bool
    func send(title: String, body: String, threshold: Int) async throws
}

protocol NotificationPreferenceStoring: Sendable {
    func isEnabled() async -> Bool
    func setEnabled(_ enabled: Bool) async
}

protocol UserNotificationCenterServing: Sendable {
    func requestAuthorization() async throws -> Bool
    func send(title: String, body: String) async throws
}

actor NotificationCoordinator: LimitNotifying {
    private let repository: UsageRepository
    private let sender: any NotificationSending
    private var inFlightReceiptKeys: Set<String> = []

    init(repository: UsageRepository, sender: any NotificationSending) {
        self.repository = repository
        self.sender = sender
    }

    func evaluate(_ limits: [LimitStatus]) async {
        guard await sender.isEnabled() else { return }

        for limit in limits {
            for threshold in [20, 10] where limit.remainingPercent < Double(threshold) {
                let receiptKey = [
                    limit.window.storageKey,
                    String(Int(limit.resetsAt.timeIntervalSince1970)),
                    String(threshold),
                ].joined(separator: "|")
                guard inFlightReceiptKeys.insert(receiptKey).inserted else { continue }
                defer { inFlightReceiptKeys.remove(receiptKey) }

                let wasSent: Bool
                do {
                    wasSent = try await repository.notificationWasSent(receiptKey)
                } catch {
                    continue
                }
                guard !wasSent else { continue }

                do {
                    try await sender.send(
                        title: "Codex 用量提醒",
                        body: "\(limit.window.displayName)剩余 \(Int(limit.remainingPercent.rounded()))%",
                        threshold: threshold
                    )
                    try await repository.markNotificationSent(receiptKey, sentAt: .now)
                } catch {
                    continue
                }
            }
        }
    }
}

final class UserNotificationSender: @unchecked Sendable, NotificationSending {
    private let center: any UserNotificationCenterServing
    private let preferences: any NotificationPreferenceStoring

    init(
        center: any UserNotificationCenterServing = SystemUserNotificationCenter(),
        preferences: any NotificationPreferenceStoring = UserDefaultsNotificationPreferences()
    ) {
        self.center = center
        self.preferences = preferences
    }

    func isEnabled() async -> Bool {
        await preferences.isEnabled()
    }

    func requestAuthorization() async throws -> Bool {
        let granted = try await center.requestAuthorization()
        await preferences.setEnabled(granted)
        return granted
    }

    func send(title: String, body: String, threshold: Int) async throws {
        try await center.send(title: title, body: body)
    }
}

private actor UserDefaultsNotificationPreferences: NotificationPreferenceStoring {
    private static let enabledKey = "notificationsEnabled"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isEnabled() async -> Bool {
        defaults.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ enabled: Bool) async {
        defaults.set(enabled, forKey: Self.enabledKey)
    }
}

private final class SystemUserNotificationCenter: @unchecked Sendable, UserNotificationCenterServing {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func send(title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }
}

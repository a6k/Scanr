import AppKit
import UserNotifications

/// Mitteilungen über das Mitteilungszentrum. Ein Klick zeigt die Dateien im Finder.
final class SystemNotifier: NSObject, ResultNotifier, UNUserNotificationCenterDelegate {
    nonisolated private static let filesKey = "files"

    func activate() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
    }

    func post(_ message: ResultMessage) {
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.userInfo = [Self.filesKey: message.files.map(\.path)]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let paths = response.notification.request.content.userInfo[Self.filesKey] as? [String] ?? []
        guard !paths.isEmpty else { return }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

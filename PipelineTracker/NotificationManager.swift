import Foundation
import UserNotifications
import AppKit

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // Show notifications even when app is frontmost (settings window open)
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
    }

    func requestPermission(completion: ((Bool) -> Void)? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { print("[Notifications] requestAuthorization error: \(error)") }
            print("[Notifications] permission granted: \(granted)")
            DispatchQueue.main.async { completion?(granted) }
        }
    }

    func checkAuthStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { completion(settings.authorizationStatus) }
        }
    }

    func sendTest() {
        let content = UNMutableNotificationContent()
        content.title = "✅ Notifications Working"
        content.body = "Pipeline Tracker can send you alerts."
        content.sound = .default
        // Use a time interval trigger so it fires even if the app is foreground
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let req = UNNotificationRequest(identifier: "notification-test-\(Date().timeIntervalSince1970)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req) { error in
            if let error { print("Test notification error: \(error)") }
        }
    }

    func notifyPipelineChange(pipeline: Pipeline, accountName: String) {
        guard pipeline.status == .success || pipeline.status == .failed
                || pipeline.status == .canceled || pipeline.status == .skipped else { return }

        let content = UNMutableNotificationContent()
        content.sound = .default

        switch pipeline.status {
        case .success: content.title = "✅ Pipeline Succeeded"
        case .failed:  content.title = "❌ Pipeline Failed"
        case .canceled: content.title = "⚠️ Pipeline Canceled"
        case .skipped:  content.title = "⏭ Pipeline Skipped"
        default: return
        }

        content.body = "[\(accountName)] \(pipeline.projectName) · \(pipeline.ref) · #\(pipeline.id)"
        post(id: "pipeline-\(pipeline.id)-\(pipeline.status.rawValue)", content: content)
    }

    func notifyNewPipeline(pipeline: Pipeline, accountName: String) {
        let content = UNMutableNotificationContent()
        content.title = "🚀 Pipeline Started"
        content.body = "[\(accountName)] \(pipeline.projectName) · \(pipeline.ref) · #\(pipeline.id)"
        content.sound = .default
        post(id: "new-pipeline-\(pipeline.id)", content: content)
    }

    func notifyTokenExpired(accountName: String) {
        let content = UNMutableNotificationContent()
        content.title = "🔑 Token Expired"
        content.body = "Account '\(accountName)' — token is invalid or expired. Update it in Settings."
        content.sound = .default
        // De-dupe: same id = only notifies once per account until resolved
        post(id: "token-expired-\(accountName)", content: content)
    }

    private func post(id: String, content: UNMutableNotificationContent) {
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

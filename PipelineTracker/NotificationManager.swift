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
        attach(symbol: "checkmark.circle.fill", color: .systemGreen, to: content)
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
        attach(symbol: pipeline.status.systemImage, color: NSColor(pipeline.status.color), to: content)
        post(id: "pipeline-\(pipeline.id)-\(pipeline.status.rawValue)", content: content)
    }

    func notifyNewPipeline(pipeline: Pipeline, accountName: String) {
        let content = UNMutableNotificationContent()
        content.title = "🚀 Pipeline Started"
        content.body = "[\(accountName)] \(pipeline.projectName) · \(pipeline.ref) · #\(pipeline.id)"
        content.sound = .default
        attach(symbol: "play.circle.fill", color: .systemBlue, to: content)
        post(id: "new-pipeline-\(pipeline.id)", content: content)
    }

    func notifyTokenExpired(accountName: String) {
        let content = UNMutableNotificationContent()
        content.title = "🔑 Token Expired"
        content.body = "Account '\(accountName)' — token is invalid or expired. Update it in Settings."
        content.sound = .default
        attach(symbol: "key.slash.fill", color: .systemRed, to: content)
        // De-dupe: same id = only notifies once per account until resolved
        post(id: "token-expired-\(accountName)", content: content)
    }

    func notifyAccountPaused(accountName: String) {
        let content = UNMutableNotificationContent()
        content.title = "⏸ Auto-Refresh Paused"
        content.body = "Account '\(accountName)' — token still invalid after retries. Monitoring is paused until you update the token in Settings or refresh manually."
        content.sound = .default
        attach(symbol: "pause.circle.fill", color: .systemOrange, to: content)
        post(id: "account-paused-\(accountName)", content: content)
    }

    private func post(id: String, content: UNMutableNotificationContent) {
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Notification image

    /// The notification banner thumbnail defaults to the app icon, which is empty
    /// (no AppIcon asset). Render a status glyph to a PNG and attach it so every
    /// notification shows a meaningful, color-coded image.
    private func attach(symbol: String, color: NSColor, to content: UNMutableNotificationContent) {
        guard let url = renderGlyphPNG(symbol: symbol, color: color),
              let attachment = try? UNNotificationAttachment(identifier: UUID().uuidString, url: url)
        else { return }
        content.attachments = [attachment]
    }

    private func renderGlyphPNG(symbol: String, color: NSColor) -> URL? {
        let side: CGFloat = 128
        let canvas = NSImage(size: NSSize(width: side, height: side))
        canvas.lockFocus()

        // Rounded tinted background.
        let bgRect = NSRect(x: 0, y: 0, width: side, height: side)
        NSBezierPath(roundedRect: bgRect, xRadius: 28, yRadius: 28).addClip()
        color.withAlphaComponent(0.16).setFill()
        bgRect.fill()

        // Tinted SF Symbol, centered.
        let cfg = NSImage.SymbolConfiguration(pointSize: 70, weight: .semibold)
        if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            let s = base.size
            let glyphRect = NSRect(x: (side - s.width) / 2, y: (side - s.height) / 2,
                                   width: s.width, height: s.height)
            base.draw(in: glyphRect)            // draw alpha mask
            color.set()
            glyphRect.fill(using: .sourceAtop)  // tint it
        }

        canvas.unlockFocus()

        guard let tiff = canvas.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notif-\(UUID().uuidString).png")
        do { try png.write(to: url); return url } catch { return nil }
    }
}

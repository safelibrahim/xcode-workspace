import AppKit
import UserNotifications

// MARK: - Scene notifications

/// Posts native macOS notification banners (the system's own out-of-the-box
/// component) for scene warnings — e.g. when two apps' minimum window sizes
/// conflict. Authorization is requested lazily on first use.
final class SceneToastPanel {

    private var authRequested = false

    /// Same call signature the custom toast had — `screen`/`duration` are
    /// unused now that the system owns presentation.
    func show(title: String, message: String, screen: NSScreen? = nil,
              duration: TimeInterval = 0) {
        let center = UNUserNotificationCenter.current()

        let post = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body  = message
            content.sound = nil   // visual warning only — no alert sound
            let request = UNNotificationRequest(
                identifier: "scene-warning",   // replaces any previous warning
                content: content,
                trigger: nil
            )
            center.add(request)
        }

        if authRequested {
            post()
        } else {
            authRequested = true
            center.requestAuthorization(options: [.alert]) { granted, _ in
                guard granted else { return }
                post()
            }
        }
    }

    func dismiss() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ["scene-warning"])
        center.removePendingNotificationRequests(withIdentifiers: ["scene-warning"])
    }
}

import SwiftUI
import Combine
import ApplicationServices
import UserNotifications

extension Notification.Name {
    static let menuBarExtraDidOpen = Notification.Name("menuBarExtraDidOpen")
}

/// Handles OS-level app lifecycle events that SwiftUI's Scene API doesn't expose.
class RewindpadAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                            UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidOpen(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuBarExtraOpened),
            name: .menuBarExtraDidOpen,
            object: nil
        )
        // Show scene-warning banners even while Rewindpad is the active app.
        UNUserNotificationCenter.current().delegate = self
        requestRequiredPermissions()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    @objc private func menuBarExtraOpened() {
        // Menu bar extra opened → hide the workspace window immediately
        for window in NSApp.windows where window.title == "Workspace" && window.isVisible {
            window.orderOut(nil)
        }
    }

    // MARK: - Permissions

    /// Requests Accessibility access (needed for AX window placement).
    /// If already granted this is a no-op. If not, macOS shows the one-time
    /// System Settings prompt — after that it never asks again.
    private func requestRequiredPermissions() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func windowDidOpen(_ note: Notification) {
        guard let w = note.object as? NSWindow, w.title == "Workspace" else { return }
        w.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func windowShouldMiniaturize(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        // Window hidden → restore overlays, but only if a scene app is frontmost
        // (never over an unrelated app the user has pulled up).
        RewindpadServer.shared.refreshSceneOverlayVisibility()
        return false
    }

    func windowDidBecomeMain(_ notification: Notification) {
        // Main window is front → hide overlays so they don't clutter the UI
        RewindpadServer.shared.overlayManager.hideAll()
        RewindpadServer.shared.dividerManager.hideAll()
        // Close the menu bar extra popover if it's open
        closeMenuBarExtra()
    }

    private func closeMenuBarExtra() {
        for window in NSApp.windows {
            guard window !== NSApp.mainWindow else { continue }
            if window.styleMask.contains(.nonactivatingPanel),
               window.title.isEmpty, window.isVisible,
               !(window is DividerPanel), !(window is SwitchOverlayPanel) {
                window.orderOut(nil)
            }
        }
    }

    func windowDidResignMain(_ notification: Notification) {
        // Main window stepped back → restore overlays only if a scene app is
        // taking the foreground (not when the user switched to an unrelated app).
        RewindpadServer.shared.refreshSceneOverlayVisibility()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Called just before the process exits (⌘Q, Dock Quit, or programmatic terminate).
    /// Sends a clean "disconnect" signal to the connected iPhone so it clears its
    /// Mac-ready heartbeat immediately rather than waiting for the 90 s expiry.
    func applicationWillTerminate(_ notification: Notification) {
        RewindpadServer.shared.broadcastGoodbye()
    }
}

@main
struct RewindpadMacApp: App {
    @NSApplicationDelegateAdaptor(RewindpadAppDelegate.self) private var appDelegate

    private let server = RewindpadServer.shared
    /// Kept alive for the app lifetime — syncs Carbon hotkeys whenever scenes change.
    @StateObject private var hotkeyBridge = HotkeyBridge()

    var body: some Scene {
        WindowGroup("Workspace") {
            ContentView()
                .onAppear { hotkeyBridge.attach(to: server) }
        }
        // Ensure ⌘Q always quits regardless of which window (or none) is key.
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Workspace") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }

        MenuBarExtra {
            SceneMenuBarView(server: server)
        } label: {
            Image("WorkspaceIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Thin bridge that keeps the hotkey manager in sync

@MainActor
final class HotkeyBridge: ObservableObject {
    private var cancellable: AnyCancellable?

    func attach(to server: RewindpadServer) {
        guard cancellable == nil else { return }
        cancellable = server.$appGroups
            .receive(on: RunLoop.main)
            .sink { groups in
                SceneHotkeyManager.shared.sync(with: groups)
            }
    }
}

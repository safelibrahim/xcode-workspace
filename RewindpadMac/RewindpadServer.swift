import Foundation
import AppKit
import Network
import Combine
import SwiftUI
import Darwin
import Carbon
import SQLite3

extension NSNotification.Name {
    static let rewindpadConnectionChanged = NSNotification.Name("rewindpadConnectionChanged")
}


private let rewindpadMaxInlineIconCharacters = 1_200_000

struct ClipboardItem: Identifiable, Codable {
    let id: Int
    let content: String
    let type: String
    let time: Date
    let preview: String

    var typeIcon: String {
        switch type {
        case "url":
            return "🔗"
        case "code":
            return "💻"
        default:
            return "📝"
        }
    }

    var typeColor: Color {
        switch type {
        case "url":
            return .green
        case "code":
            return .purple
        default:
            return .blue
        }
    }

    var timeAgo: String {
        let diff = Int(Date().timeIntervalSince(time))

        if diff < 60 {
            return "just now"
        }

        if diff < 3600 {
            return "\(diff / 60)m ago"
        }

        return "\(diff / 3600)h ago"
    }
}

struct RecentFile: Identifiable, Codable {
    let id: String
    let name: String
    let ext: String
    let app: String
    let path: String
    let time: Date
}

struct RunningApp: Identifiable, Codable {
    let id: String
    let name: String
    let active: Bool
    let order: Int
}

struct AppleShortcut: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let iconData: String?

    init(id: String, name: String, iconData: String? = nil) {
        self.id = id
        self.name = name
        self.iconData = iconData
    }
}

struct AvailableApp: Identifiable, Codable {
    let id: String          // always the app path (stable, unique)
    let name: String
    let path: String
    let icon: String
    let iconData: String?
    let bundleIdentifier: String?   // real CFBundleIdentifier, e.g. "com.apple.AppStore"

    init(id: String, name: String, path: String, icon: String,
         iconData: String? = nil, bundleIdentifier: String? = nil) {
        self.id   = id
        self.name = name
        self.path = path
        self.icon = icon
        self.iconData = iconData
        // Derive real bundle ID from the .app bundle if caller didn't supply one.
        self.bundleIdentifier = bundleIdentifier
            ?? Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier
    }
}


private func rewindpadSocketStringIsEmoji(_ value: String?) -> Bool {
    guard let value, !value.isEmpty, value.count <= 16 else {
        return false
    }

    return value.unicodeScalars.contains { scalar in
        scalar.properties.isEmojiPresentation || scalar.properties.isEmoji
    }
}

struct SavedShortcut: Identifiable, Codable {
    let id: String
    let title: String
    let type: String
    let target: String
    let icon: String
    let iconData: String?
    let createdAt: Date
    let pageIndex: Int?
    let slotIndex: Int?
    let pageRows: Int?

    init(id: String, title: String, type: String, target: String, icon: String, iconData: String? = nil, createdAt: Date, pageIndex: Int? = nil, slotIndex: Int? = nil, pageRows: Int? = nil) {
        self.id = id
        self.title = title
        self.type = type
        self.target = target
        self.icon = icon
        self.iconData = iconData
        self.createdAt = createdAt
        self.pageIndex = pageIndex
        self.slotIndex = slotIndex
        self.pageRows = pageRows
    }
}

enum RewindpadShortcutDiskStore {
    private static let legacyDefaultsKey = "rw_saved_shortcuts"
    private static let folderName = "RewindpadMac"
    private static let fileName = "saved_shortcuts.json"

    private static var folderURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(folderName, isDirectory: true)
    }

    private static var fileURL: URL? {
        folderURL?.appendingPathComponent(fileName, isDirectory: false)
    }

    // Prepares a shortcut for disk: resolves persistent icon references to actual base64
    // so icons survive app restarts. On load, restoreCustomIconsFromPersistentDisk()
    // converts the base64 back to persistent refs for in-memory use.
    static func diskSafe(_ shortcut: SavedShortcut) -> SavedShortcut {
        let iconData: String?
        if MacPersistentIconStore.isPersistentReference(shortcut.iconData) {
            let base64 = MacPersistentIconStore.base64ForTransport(shortcut.iconData)
            iconData = (base64?.count ?? 0) <= 200_000 ? base64 : nil
        } else if (shortcut.iconData?.count ?? 0) <= 200_000 {
            iconData = shortcut.iconData
        } else {
            iconData = nil
        }

        return SavedShortcut(
            id: shortcut.id,
            title: shortcut.title,
            type: shortcut.type,
            target: shortcut.target,
            icon: shortcut.icon,
            iconData: iconData,
            createdAt: shortcut.createdAt,
            pageIndex: shortcut.pageIndex,
            slotIndex: shortcut.slotIndex,
            pageRows: shortcut.pageRows
        )
    }

    // Legacy helper: strips all iconData (kept for any callers that need a lightweight copy)
    static func storageSafe(_ shortcut: SavedShortcut) -> SavedShortcut {
        SavedShortcut(
            id: shortcut.id,
            title: shortcut.title,
            type: shortcut.type,
            target: shortcut.target,
            icon: shortcut.icon,
            iconData: nil,
            createdAt: shortcut.createdAt,
            pageIndex: shortcut.pageIndex,
            slotIndex: shortcut.slotIndex,
            pageRows: shortcut.pageRows
        )
    }

    static func load() -> [SavedShortcut] {
        let decoder = JSONDecoder()

        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode([SavedShortcut].self, from: data) {
            return decoded
        }

        if let legacyData = UserDefaults.standard.data(forKey: legacyDefaultsKey),
           let decoded = try? decoder.decode([SavedShortcut].self, from: legacyData) {
            save(decoded)
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
            return decoded
        }

        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        return []
    }

    static func save(_ shortcuts: [SavedShortcut]) {
        let clean = shortcuts.map(diskSafe)

        guard let folderURL, let fileURL,
              let data = try? JSONEncoder().encode(clean) else {
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
            return
        }

        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        } catch {
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        }
    }
}

struct StatePayload: Codable {
    let clipboard: [ClipboardItem]
    let files: [RecentFile]
    let apps: [RunningApp]
    let availableApps: [AvailableApp]
    let shortcuts: [SavedShortcut]
    let availableShortcuts: [AppleShortcut]
    let barPageRows: [String: Int]
    var appGroups: [AppGroup] = []
}

// MARK: - App Groups

enum AppGroupLayout: String, Codable, CaseIterable, Identifiable {
    /// Two apps side by side (left | right), equal halves.
    case split1x1  = "split1x1"
    /// Two apps stacked (top | bottom), equal halves.
    case split1x1v = "split1x1v"
    /// One large app on the left (60%), two apps stacked on the right.
    case split1x2  = "split1x2"
    /// One large app on the right (60%), two apps stacked on the left.
    case split2x1  = "split2x1"
    /// One large app on top (60%), two apps side by side on the bottom.
    case split1x2h = "split1x2h"
    /// Four apps in a 2×2 grid, each taking one quadrant.
    case grid2x2   = "grid2x2"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .split1x1:  return "Side by Side"
        case .split1x1v: return "Top & Bottom"
        case .split1x2:  return "Focus Left"
        case .split2x1:  return "Focus Right"
        case .split1x2h: return "Focus Top"
        case .grid2x2:   return "2×2 Grid"
        }
    }

    var icon: String {
        switch self {
        case .split1x1:  return "rectangle.split.2x1"
        case .split1x1v: return "rectangle.split.1x2"
        case .split1x2:  return "rectangle.split.2x1.fill"
        case .split2x1:  return "rectangle.split.2x1.fill"
        case .split1x2h: return "rectangle.tophalf.inset.filled"
        case .grid2x2:   return "square.grid.2x2"
        }
    }

    /// How many apps this layout is designed for (minimum useful count).
    var appSlots: Int {
        switch self {
        case .split1x1, .split1x1v: return 2
        case .split1x2, .split2x1, .split1x2h: return 3
        case .grid2x2:              return 4
        }
    }
}

enum BrowserChoice: String, Codable, CaseIterable {
    case safari = "safari"
    case chrome = "chrome"

    var appName: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        }
    }
    var bundleID: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        }
    }
    var appPath: String {
        switch self {
        case .safari: return "/Applications/Safari.app"
        case .chrome:
            let candidates = [
                "/Applications/Google Chrome.app",
                (NSHomeDirectory() as NSString).appendingPathComponent("Applications/Google Chrome.app")
            ]
            return candidates.first { FileManager.default.fileExists(atPath: $0) }
                   ?? "/Applications/Google Chrome.app"
        }
    }
    var sfSymbol: String {
        switch self {
        case .safari: return "safari"
        case .chrome: return "globe"
        }
    }
}

enum ShortcutRunMode: String, Codable, CaseIterable {
    case slot       = "slot"
    case background = "background"
}

struct AppGroupEntry: Codable, Identifiable, Equatable {
    let id: String
    var appName: String
    let bundleID: String
    let path: String
    var url: String? = nil
    var browser: String? = nil
    var shortcutName: String? = nil
    /// Controls how a shortcut entry is executed. Ignored for non-shortcut entries.
    var shortcutRunMode: ShortcutRunMode = .slot

    /// True when this entry represents a browser tab rather than a standalone app.
    var isBrowserTab: Bool { url != nil && browser != nil }
    /// True when this entry represents a macOS Shortcut to run.
    var isShortcut: Bool { shortcutName != nil }
}

enum AppGroupStopBehavior: String, Codable, CaseIterable {
    case quit     = "quit"
    case minimize = "minimize"

    var label: String {
        switch self {
        case .quit:     return "Quit apps"
        case .minimize: return "Minimize apps"
        }
    }

    var description: String {
        switch self {
        case .quit:     return "Closes the apps when you stop the group"
        case .minimize: return "Minimizes the apps, keeps them running"
        }
    }
}

struct AppGroup: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var icon: String
    var apps: [AppGroupEntry]
    var layout: AppGroupLayout
    var primaryAppID: String?
    var stopBehavior: AppGroupStopBehavior
    let createdAt: Date
    /// 1-based index (1–9) for the global ⌘⌥N hotkey. nil = no shortcut assigned.
    var hotkeyIndex: Int? = nil
    /// Primary split ratio (0.0–1.0). Defaults depend on layout (0.5 for equal, 0.6 for focus).
    var splitRatio: Double? = nil
    /// Secondary split ratio used by focus and grid layouts for the perpendicular axis.
    var splitRatioSecondary: Double? = nil

    /// Returns the effective primary ratio for this layout, applying its default if not yet customised.
    var effectiveSplitRatio: Double {
        if let r = splitRatio { return r }
        switch layout {
        case .split1x1, .split1x1v: return 0.5
        case .split1x2, .split2x1, .split1x2h: return 0.6
        case .grid2x2: return 0.5
        }
    }

    /// Returns the effective secondary ratio for this layout (stack split within focus/grid).
    var effectiveSplitRatioSecondary: Double {
        splitRatioSecondary ?? 0.5
    }

    init(id: String, name: String, icon: String, apps: [AppGroupEntry],
         layout: AppGroupLayout, primaryAppID: String?,
         stopBehavior: AppGroupStopBehavior = .quit, createdAt: Date,
         hotkeyIndex: Int? = nil, splitRatio: Double? = nil, splitRatioSecondary: Double? = nil) {
        self.id = id; self.name = name; self.icon = icon; self.apps = apps
        self.layout = layout; self.primaryAppID = primaryAppID
        self.stopBehavior = stopBehavior; self.createdAt = createdAt
        self.hotkeyIndex = hotkeyIndex
        self.splitRatio = splitRatio
        self.splitRatioSecondary = splitRatioSecondary
    }

    /// Display string for the assigned hotkey, e.g. "⌘⌥1".
    var hotkeyLabel: String? {
        guard let idx = hotkeyIndex, (1...9).contains(idx) else { return nil }
        return "⌘⌥\(idx)"
    }
}

enum AppGroupStore {
    private static let folderName = "RewindpadMac"
    private static let fileName = "app_groups.json"

    private static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func load() -> [AppGroup] {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let groups = try? JSONDecoder().decode([AppGroup].self, from: data) else {
            return []
        }
        return groups
    }

    static func save(_ groups: [AppGroup]) {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(groups) else { return }
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }
}

struct SystemLoadPayload: Codable {
    let cpu: Double      // 0.0 – 1.0, 1-minute load average normalised by CPU count
    let memory: Double   // 0.0 – 1.0, fraction of RAM in use
}

struct ShortcutSyncPayload: Codable {
    let revision: Int
    let shortcuts: [SavedShortcut]
    let availableShortcuts: [AppleShortcut]
    let timestamp: TimeInterval
}

struct LaunchpadDeltaPayload: Codable {
    let revision: Int
    let action: String
    let shortcut: SavedShortcut?
    let removedID: String?
    let removedTarget: String?
    let removedType: String?
    let shortcuts: [SavedShortcut]
    let barPageRows: [String: Int]
    let timestamp: TimeInterval
}

struct ClientMessage: Codable {
    let type: String
    let payload: String?
}

struct ServerMessage: Codable {
    let type: String
    let data: Data
}

struct TrustedPairingRequest: Identifiable, Codable {
    let id: String
    let deviceName: String
}

struct TrustedPairingPayload: Codable, Sendable {
    let deviceID: String
    let deviceName: String
}

struct PinAuthPayload: Codable, Sendable {
    let pin: String
    let deviceID: String
    let deviceName: String?
}

struct TrustedAuthPayload: Codable, Sendable {
    let deviceID: String
    let token: String
    let deviceName: String?
}

struct IconRequestPayload: Codable, Sendable {
    let id: String
    let path: String
}

struct IconResponsePayload: Codable, Sendable {
    let id: String
    let iconData: String?
}

struct IconBatchRequestPayload: Codable, Sendable {
    let apps: [IconRequestPayload]
}

struct IconBatchPayload: Codable, Sendable {
    let icons: [IconResponsePayload]
}

// MARK: - Min-size haptic watcher (native tiling)

/// Watches one scene window's AX resize notifications and fires haptic feedback
/// as the user drags the native macOS tiling divider.
/// Two feedback patterns:
///  • Periodic soft tick every ~90 px of movement — confirms the drag is live.
///  • One strong levelChange tick when the window first hits its minimum size.
/// Also calls `onDrag` on every resize event so the divider hint overlay can
/// animate into its active state while the native divider is being dragged.
/// Observation only — the system divider keeps its fully native behaviour.
/// Minimal visual cue when a window pins at its minimum size during a
/// divider drag: a sleek border that snaps tight while a soft glow ring
/// radiates outward and fades — dramatic at the instant of impact, then gone.
final class MinSizePinFlash {
    static let shared = MinSizePinFlash()
    private var panel: NSPanel?

    /// Glow is drawn into padding around the real window frame, so the panel
    /// is grown by this amount on each side to give it room to bloom.
    private let inset: CGFloat = 24

    func flash(cgFrame: CGRect) {
        // CG global coordinates are flipped relative to the zero-origin
        // (menu-bar) screen — use THAT screen's height, not just screens.first,
        // so the rect lands on the window regardless of display arrangement.
        let primaryH = (NSScreen.screens.first { $0.frame.origin == .zero }
                        ?? NSScreen.main
                        ?? NSScreen.screens.first)?.frame.height ?? cgFrame.maxY
        let window = NSRect(x: cgFrame.minX,
                            y: primaryH - cgFrame.maxY,
                            width: cgFrame.width,
                            height: cgFrame.height)
        let cocoa = window.insetBy(dx: -inset, dy: -inset)   // room for the bloom

        panel?.orderOut(nil)
        let p = NSPanel(contentRect: cocoa,
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let host = NSHostingController(rootView: PinFlashView(inset: inset))
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
        host.view.frame = NSRect(origin: .zero, size: cocoa.size)
        p.contentViewController = host
        p.setFrame(cocoa, display: true)
        p.alphaValue = 1          // the SwiftUI view runs its own entrance
        p.orderFrontRegardless()
        panel = p

        // Brackets clamp + ripples bloom over ~0.45s; let the reticle dwell a
        // beat, then ease the whole panel out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self, weak p] in
            guard let p else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                p.animator().alphaValue = 0
            }, completionHandler: {
                p.orderOut(nil)
                if self?.panel == p { self?.panel = nil }
            })
        }
    }
}

/// Four corner brackets (a focus-lock reticle). Drawn at the bounding-box
/// corners with rounded joins so they read as a precise "locked" frame.
private struct CornerBrackets: Shape {
    var armRatio: CGFloat = 0.18
    var maxArm:   CGFloat = 30

    func path(in rect: CGRect) -> Path {
        let arm = min(min(rect.width, rect.height) * armRatio, maxArm)
        var p = Path()
        // Top-left
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))
        // Top-right
        p.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + arm))
        // Bottom-right
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
        // Bottom-left
        p.move(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - arm))
        return p
    }
}

/// The animated pin-flash: a focus-lock reticle whose corner brackets spring
/// inward to "clamp" the window, layered over staggered glow ripples that
/// radiate outward, and a refined hairline border for definition.
private struct PinFlashView: View {
    let inset: CGFloat
    @State private var clamped = false   // brackets clamp in + border defines
    @State private var ripple1 = false   // first glow ripple
    @State private var ripple2 = false   // second, staggered ripple

    private let accent = Color(red: 1.0, green: 0.56, blue: 0.0)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        ZStack {
            // Two staggered radiating ripples — blooms of energy at impact.
            shape
                .stroke(accent, lineWidth: 2.5)
                .blur(radius: ripple1 ? 14 : 3)
                .opacity(ripple1 ? 0 : 0.5)
                .scaleEffect(ripple1 ? 1.05 : 0.99)
            shape
                .stroke(accent.opacity(0.7), lineWidth: 1.5)
                .blur(radius: ripple2 ? 20 : 2)
                .opacity(ripple2 ? 0 : 0.35)
                .scaleEffect(ripple2 ? 1.10 : 1.0)

            // Refined hairline border — quietly defines the boundary.
            shape
                .strokeBorder(accent.opacity(clamped ? 0.45 : 0.0), lineWidth: 1.25)

            // Focus-lock corner brackets — spring inward to clamp the window.
            CornerBrackets()
                .stroke(
                    LinearGradient(colors: [accent, accent.opacity(0.55)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )
                .scaleEffect(clamped ? 1.0 : 1.07)
                .opacity(clamped ? 1.0 : 0.0)
                .shadow(color: accent.opacity(clamped ? 0.0 : 0.7), radius: 7)
        }
        .padding(inset)
        // A borderless panel's hosting view still reports a top safe-area inset
        // (the title-bar region), which would push the reticle DOWN and leave a
        // gap above the window. Ignore it so the boundary hugs the real frame.
        .ignoresSafeArea()
        .onAppear {
            // Brackets clamp with a quick overshoot landing on the haptic.
            withAnimation(.spring(response: 0.30, dampingFraction: 0.5)) {
                clamped = true
            }
            withAnimation(.easeOut(duration: 0.6)) {
                ripple1 = true
            }
            withAnimation(.easeOut(duration: 0.72).delay(0.09)) {
                ripple2 = true
            }
        }
    }
}

final class MinSizeWatcher {

    private let window:  AXUIElement
    private let minSize: CGSize
    private var observer: AXObserver?
    private var atLimit  = false

    private var lastCGFrame: CGRect?
    /// Accumulates drag distance between periodic haptic ticks.
    private var hapticAccumulator: CGFloat = 0
    private static let hapticInterval: CGFloat = 90

    /// Called on the main thread on every resize event (i.e. while dragging).
    var onDrag: (() -> Void)?

    private init(window: AXUIElement, minSize: CGSize) {
        self.window  = window
        self.minSize = minSize
    }

    static func attach(pid: pid_t, window: AXUIElement, minSize: CGSize) -> MinSizeWatcher? {
        // Attach even with no known minimum — the drag/grab haptics should
        // work on every window; the min-size pin tick simply won't fire.
        let watcher = MinSizeWatcher(window: window, minSize: minSize)

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<MinSizeWatcher>.fromOpaque(refcon).takeUnretainedValue().handleResize()
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return nil }

        let refcon = Unmanaged.passUnretained(watcher).toOpaque()
        guard AXObserverAddNotification(obs, window, "AXResized" as CFString, refcon) == .success
        else { return nil }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        watcher.observer = obs
        return watcher
    }

    func detach() {
        guard let obs = observer else { return }
        AXObserverRemoveNotification(obs, window, "AXResized" as CFString)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = nil
    }

    private func handleResize() {
        var sizeRef: CFTypeRef?
        var posRef:  CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              let sv = sizeRef, CFGetTypeID(sv) == AXValueGetTypeID(),
              let pv = posRef,  CFGetTypeID(pv) == AXValueGetTypeID() else { return }
        var size = CGSize.zero
        var pos  = CGPoint.zero
        AXValueGetValue(sv as! AXValue, .cgSize,  &size)
        AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
        let cgFrame = CGRect(origin: pos, size: size)
        let prev    = lastCGFrame
        lastCGFrame = cgFrame
        guard let prev, prev != cgFrame else { return }

        // Notify the divider hint overlay that dragging is in progress.
        onDrag?()

        // Periodic soft tick — one per ~90 px of drag movement.
        let moved = abs(cgFrame.width - prev.width) + abs(cgFrame.height - prev.height)
        hapticAccumulator += moved
        if hapticAccumulator >= Self.hapticInterval {
            hapticAccumulator = hapticAccumulator.truncatingRemainder(dividingBy: Self.hapticInterval)
            NSHapticFeedbackManager.defaultPerformer
                .perform(.generic, performanceTime: .now)
        }

        // Strong tick exactly once when the window first hits its minimum.
        let pinnedW = minSize.width  > 0 && size.width  <= minSize.width  + 1
        let pinnedH = minSize.height > 0 && size.height <= minSize.height + 1
        if pinnedW || pinnedH {
            if !atLimit {
                atLimit = true
                NSHapticFeedbackManager.defaultPerformer
                    .perform(.levelChange, performanceTime: .now)
                // Minimal visual cue: pulse an outline around the pinned window.
                MinSizePinFlash.shared.flash(cgFrame: cgFrame)
            }
        } else if atLimit, size.width > minSize.width + 6, size.height > minSize.height + 6 {
            atLimit = false
            hapticAccumulator = 0   // reset on direction change
        }
    }
}

// MARK: - Live divider resize pipeline

/// Off-main-thread window resizer used while a divider is being dragged or
/// trackpad-scrubbed. Every AX call is a synchronous IPC round trip into the
/// target app (5–50 ms each); doing them per tick on the main thread froze
/// both the windows and the divider visuals. This session:
///   • resolves each slot's AXUIElement window ONCE at gesture start,
///   • caches each window's minimum size (no per-tick min-size reads),
///   • applies frames on a background queue with latest-wins coalescing —
///     slow apps skip intermediate frames instead of lagging behind,
///   • keeps the main thread (pill, HUD, panel tracking) completely fluid.
final class LiveResizeSession {

    struct SlotWindow {
        let win: AXUIElement?       // nil = unresolvable; keeps slot indices aligned
        let minSize: CGSize
        var lastFrame: CGRect?
    }

    private var windows: [SlotWindow]
    private let queue = DispatchQueue(label: "rewindpad.live-resize", qos: .userInteractive)
    private let lock  = NSLock()
    private var latest: [CGRect]?
    private var draining = false

    init(windows: [SlotWindow]) {
        self.windows = windows
    }

    /// Called from the main thread on every divider tick — cheap: stores the
    /// frames and pokes the worker. Never blocks.
    func submit(_ frames: [CGRect]) {
        lock.lock()
        latest = frames
        let start = !draining
        if start { draining = true }
        lock.unlock()
        if start { queue.async { [weak self] in self?.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let frames = latest else { draining = false; lock.unlock(); return }
            latest = nil
            lock.unlock()
            apply(frames)
        }
    }

    private func apply(_ frames: [CGRect]) {
        for i in windows.indices {
            guard i < frames.count, let win = windows[i].win else { continue }
            var f = frames[i]
            // Respect the cached minimum — never ask the app to go below it.
            let m = windows[i].minSize
            if f.width  < m.width  { f.size.width  = m.width  }
            if f.height < m.height { f.size.height = m.height }
            guard windows[i].lastFrame != f else { continue }

            var p = f.origin
            var s = f.size
            if let pv = AXValueCreate(.cgPoint, &p) {
                AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv)
            }
            if let sv = AXValueCreate(.cgSize, &s) {
                AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
            }
            windows[i].lastFrame = f
        }
    }
}

final class RewindpadServer: ObservableObject {
    static let shared = RewindpadServer()

    @Published var clipboardHistory: [ClipboardItem] = []
    @Published var recentFiles: [RecentFile] = []
    @Published var runningApps: [RunningApp] = []
    @Published var availableApps: [AvailableApp] = []
    @Published var availableShortcuts: [AppleShortcut] = []
    @Published var suggestedLinks: [SuggestedLink] = []
    @Published var isFetchingHistory: Bool = false
    @Published var shortcuts: [SavedShortcut] = []
    @Published var barPageRows: [String: Int] = [:]
    @Published var appGroups: [AppGroup] = []
    /// Groups currently in the "active" (launched) state. Maps group ID → set of app paths
    /// that were *newly* opened by this launch (i.e. not already running before).
    @Published var activeAppGroups: [String: Set<String>] = [:]
    @Published var localSystemLoad: SystemLoadPayload = SystemLoadPayload(cpu: 0, memory: 0)
    @Published var needsAccessibilityPermission: Bool = !AXIsProcessTrusted()
    @Published var isConnected: Bool = false
    @Published var connectedDeviceName: String? = nil
    /// True once at least one iPhone has ever been trusted on this Mac.
    /// Used to decide whether to surface the pairing sheet on first launch.
    @Published var hasTrustedDevices: Bool = false

    /// Set by the menu bar's "Create Workspace" CTA — the Workspaces view
    /// consumes it on appear and opens the creator modal (covers the case
    /// where the view wasn't mounted when the CTA was clicked).
    @Published var pendingOpenWorkspaceCreator: Bool = false
    /// The name of the last successfully authenticated device.
    /// Persisted across restarts so we can show "Reconnecting to X…" instead of
    /// the PIN QR screen after a long background / Mac sleep.
    @Published var lastKnownDeviceName: String? = {
        UserDefaults.standard.string(forKey: "rw_last_known_device_name")
    }()
    @Published var pin: String = ""
    @Published var pendingTrustRequest: TrustedPairingRequest? = nil

    private var listener: NWListener?
    private var connectedConnection: NWConnection?
    private var authenticatedConnections: Set<ObjectIdentifier> = []
    private var pendingConnection: NWConnection?
    private var pendingTrustConnection: NWConnection?
    private var pendingTrustDeviceID: String?
    private var pendingTrustDeviceName: String?
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]
    private var officialIconDataCache: [String: String] = [:]
    private let officialIconDataCacheQueue = DispatchQueue(label: "com.rewindpad.officialIconDataCache")
    private var statePushWorkItem: DispatchWorkItem?
    private var editorRecoveryPushWorkItem: DispatchWorkItem?
    /// Grace period before flipping isConnected → false. Prevents the PIN screen
    /// from flashing during brief reconnects (e.g. iPhone backgrounded then foregrounded).
    private var disconnectGraceTimer: DispatchWorkItem?
    /// iOS gives a backgrounded app ~30 s of execution before fully suspending it
    /// (which drops the TCP socket). The iPhone reconnects the moment it is foregrounded.
    /// 120 s keeps the Mac in the "connected" UI through the entire suspension + reconnect,
    /// so the Mac screen and widget never flicker to a disconnected state.
    private let disconnectGraceSeconds: TimeInterval = 120
    private var lastSuccessfulSendAt: Date = Date()
    private var shortcutsRevision: Int = 0

    private var lastClipboard: String = ""
    private var clipTimer: Timer?
    /// Manages the floating Switch buttons shown on each App Group window slot.
    let overlayManager = AppGroupSwitchOverlayManager()
    /// Manages the live-draggable divider overlays shown between windows while a scene is active.
    let dividerManager = SceneDividerOverlayManager()
    /// Full-screen dark loading shield shown while a scene's apps open and settle.
    let loadingOverlay = SceneLoadingOverlayManager()

    /// Pending "show overlays" tasks keyed by group ID. Cancelled if Stop fires first.
    private var pendingOverlayTasks: [String: DispatchWorkItem] = [:]

    /// Maps group ID → launch token. A new UUID is minted each launch.
    /// activateAndPlace checks its copy of the token; if the stored token
    /// has changed (or is gone), the loop exits — this cancels placement
    /// when stopAppGroup is called mid-flight.
    private var placementTokens: [String: UUID] = [:]
    private var appsTimer: Timer?
    private var shortcutsTimer: Timer?
    private var systemLoadTimer: Timer?
    private var isAppleShortcutsRefreshRunning = false
    private var pendingAppleShortcutsRefresh = false
    private var lastAvailableShortcutsSignature = ""
    private var appDirectoryWatchSources: [DispatchSourceFileSystemObject] = []
    private var shortcutDirectoryWatchSources: [DispatchSourceFileSystemObject] = []
    private var appDirectoryRefreshWorkItem: DispatchWorkItem?
    private var shortcutDirectoryRefreshWorkItem: DispatchWorkItem?
    private var appsFollowUpWorkItems: [DispatchWorkItem] = []
    private var shortcutsBurstWorkItems: [DispatchWorkItem] = []

    private let port: NWEndpoint.Port = 9422
    private let bonjourType = "_rewindpad._tcp"
    private let shortcutsKey = "rw_saved_shortcuts"
    private let trustedDevicesKey = "rw_trusted_devices"
    private let trustedDeviceNamesKey = "rw_trusted_device_names"

    /// In-memory mirror of the Keychain trust store.
    /// Populated on first read so that a locked Keychain (screen saver / sleep)
    /// can never cause a spurious `invalid_trust` rejection for a paired device.
    private var cachedTrustedDevices: [String: String]?

    private static var deviceDisplayName: String {
        let candidates = [
            Host.current().localizedName,
            Host.current().name,
            ProcessInfo.processInfo.hostName
        ]

        for candidate in candidates {
            let cleaned = candidate?
                .replacingOccurrences(of: ".local", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let cleaned, !cleaned.isEmpty {
                return cleaned
            }
        }

        return "Mac"
    }

    private static var bonjourServiceName: String {
        deviceDisplayName
    }


    private static func localIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return nil
        }

        defer {
            freeifaddrs(interfaces)
        }

        var fallbackAddress: String?

        var pointer: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let currentPointer = pointer {
            let interface = currentPointer.pointee
            pointer = interface.ifa_next

            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else {
                continue
            }

            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let name = String(cString: interface.ifa_name)
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))

            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            guard result == 0 else {
                continue
            }

            let ipAddress = String(cString: hostname)

            if name == "en0" || name == "en1" {
                return ipAddress
            }

            if fallbackAddress == nil {
                fallbackAddress = ipAddress
            }
        }

        return fallbackAddress
    }

    private init() {
        // Persist the PIN across Mac restarts so that iPhones with a saved PIN
        // don't receive wrong_pin on the next reconnect and end up stuck on the
        // pairing screen. A new PIN is only generated if none has ever been saved.
        if let saved = UserDefaults.standard.string(forKey: "rw_server_pin"), !saved.isEmpty {
            pin = saved
        } else {
            pin = Self.generatePIN()
            UserDefaults.standard.set(pin, forKey: "rw_server_pin")
        }
        shortcuts = loadShortcuts()
        saveShortcuts()
        appGroups = AppGroupStore.load()
        availableApps = []
        availableShortcuts = []

        startServer()
        startPolling()
        overlayManager.server = self
        dividerManager.server = self
        startDirectoryWatchers()
        forceFullStateRefresh()
        installArrangeScript()

        // Seed the trusted-devices flag so the UI knows whether any iPhone has
        // ever been paired without exposing the raw Keychain dictionary.
        hasTrustedDevices = !loadTrustedDevices().isEmpty

        // Restart the network listener after Mac sleep/wake.
        // Active scenes (activeAppGroups) are deliberately preserved — apps
        // keep running; only the TCP socket infrastructure is recycled.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.restartAfterWake()
        }

        // Re-scan shortcuts whenever our app comes back to the foreground.
        // This catches edits the user made in Shortcuts.app while we were in the background.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            if app.bundleIdentifier == Bundle.main.bundleIdentifier {
                self.refreshAppleShortcutsIfChangedAsync()
            }
            // Scene overlays (slot buttons + dividers) float above normal windows.
            // Hide them whenever a non-scene app comes to the front so they never
            // sit on top of an unrelated app the user pulled up.
            self.updateSceneOverlayVisibility(frontmost: app)
        }

        // When a scene app quits (⌘Q, crash, Dock quit), collapse its slot and
        // let the remaining windows expand — same as pressing the − button.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self.handleSceneAppQuit(app)
        }
    }

    /// Removes the slot of an app that quit while its scene was active.
    /// No-op during scene stop/switch: stopAppGroup clears the session state
    /// before terminating apps, so the guard below filters those out.
    private func handleSceneAppQuit(_ app: NSRunningApplication) {
        guard !activeAppGroups.isEmpty else { return }
        let path = app.bundleURL?.path
        let bid  = app.bundleIdentifier

        for (groupID, entries) in activeSlotEntries {
            guard activeAppGroups[groupID] != nil else { continue }
            if let entry = entries.first(where: {
                (path != nil && $0.path == path)
                || (bid != nil && !$0.bundleID.isEmpty && $0.bundleID == bid)
            }) {
                removeSlotApp(groupID: groupID, entryID: entry.id)
            }
        }
    }

    /// Re-evaluates overlay visibility against the current frontmost app.
    /// Call after the workspace window hides or steps back.
    func refreshSceneOverlayVisibility() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        updateSceneOverlayVisibility(frontmost: front)
    }

    /// Shows the scene overlays when a scene app is frontmost, hides them when any
    /// other app takes the foreground — the overlays float above normal windows and
    /// must never sit on top of an unrelated app the user pulled up.
    /// Rewindpad itself is left to the workspace-window delegate, which hides
    /// overlays while the main window is visible.
    private func updateSceneOverlayVisibility(frontmost app: NSRunningApplication) {
        guard !activeAppGroups.isEmpty else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

        let path     = app.bundleURL?.path
        let bundleID = app.bundleIdentifier

        let inScene = activeSlotEntries.values.flatMap { $0 }.contains { entry in
            (path != nil && entry.path == path)
            || (bundleID != nil && !entry.bundleID.isEmpty && entry.bundleID == bundleID)
        } || (path != nil && activeAppGroups.values.contains { $0.contains(path!) })

        if inScene {
            overlayManager.showAll()
            dividerManager.showAll()
        } else {
            overlayManager.hideAll()
            dividerManager.hideAll()
        }
    }

    deinit {
        clipTimer?.invalidate()
        appsTimer?.invalidate()
        shortcutsTimer?.invalidate()
        systemLoadTimer?.invalidate()
        stopDirectoryWatchers()
        listener?.cancel()
        connectedConnection?.cancel()
        pendingConnection?.cancel()
    }

    /// Called by the AppDelegate on applicationWillTerminate.
    /// Sends a clean "disconnect" message to the connected iPhone so it can
    /// clear its Mac-ready heartbeat immediately (instead of waiting for the
    /// 90 s heartbeat expiry or the TCP keepalive timeout). After a short flush
    /// delay the listener and all connections are cancelled.
    func broadcastGoodbye() {
        cancelDisconnectGrace()

        if let connection = connectedConnection {
            // Send a lightweight "disconnect" message the iPhone side handles.
            let goodbye = ServerMessage(type: "disconnect", data: Data("{}".utf8))
            if let encoded = try? JSONEncoder().encode(goodbye) {
                var length = UInt32(encoded.count).bigEndian
                let packet = Data(bytes: &length, count: 4) + encoded
                // Fire-and-forget — we just need the packet in the kernel send buffer.
                connection.send(content: packet, completion: .idempotent)
            }
            // Give the TCP stack ~150 ms to flush the packet before the process exits.
            Thread.sleep(forTimeInterval: 0.15)
            connection.cancel()
        }

        pendingTrustConnection?.cancel()
        pendingTrustConnection = nil
        pendingConnection?.cancel()
        pendingConnection = nil
        connectedConnection = nil

        listener?.cancel()
        listener = nil
    }

    func forceFullStateRefresh() {
        refreshAppsAndFiles()
        refreshAvailableAppsAsync()
        refreshAppleShortcutsAsync()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.pushStateUpdate()
            self?.pushAvailableAppsUpdate()
        }
    }

    func refreshPIN() {
        pin = Self.generatePIN()
        UserDefaults.standard.set(pin, forKey: "rw_server_pin")

        connectedConnection?.cancel()
        connectedConnection = nil
        authenticatedConnections.removeAll()
        authenticatedConnections.removeAll()

        pendingConnection?.cancel()
        pendingConnection = nil

        DispatchQueue.main.async {
            self.isConnected = false
            self.connectedDeviceName = nil
            NotificationCenter.default.post(name: .rewindpadConnectionChanged, object: nil)
        }
    }

    func approvePendingTrustRequest() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let connection = self.pendingTrustConnection,
                  let deviceID = self.pendingTrustDeviceID,
                  let deviceName = self.pendingTrustDeviceName else {
                self?.pendingTrustRequest = nil
                return
            }

            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            var devices = self.loadTrustedDevices()
            devices[deviceID] = token
            self.saveTrustedDevices(devices)

            var deviceNames = self.loadTrustedDeviceNames()
            deviceNames[deviceID] = deviceName
            self.saveTrustedDeviceNames(deviceNames)

            self.connectedConnection = connection
            self.authenticatedConnections.insert(ObjectIdentifier(connection))
            self.pendingConnection = nil
            self.pendingTrustConnection = nil
            self.pendingTrustDeviceID = nil
            self.pendingTrustDeviceName = nil
            self.pendingTrustRequest = nil
            self.connectedDeviceName = deviceName
            self.isConnected = true

            self.sendResponse([
                "ok": true,
                "trusted": true,
                "token": token,
                "deviceName": deviceName
            ], to: connection)

            self.sendState(to: connection)
            self.sendAvailableApps(to: connection)

            NotificationCenter.default.post(name: .rewindpadConnectionChanged, object: nil)
        }
    }

    func rejectPendingTrustRequest() {
        guard let connection = pendingTrustConnection else {
            pendingTrustRequest = nil
            return
        }

        pendingTrustConnection = nil
        pendingTrustDeviceID = nil
        pendingTrustDeviceName = nil
        pendingTrustRequest = nil

        sendResponse(["ok": false, "error": "trust_rejected"], to: connection)
        connection.cancel()
    }

    private func publishTemporaryWaitingState() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.isConnected = false
            self.connectedDeviceName = nil
            NotificationCenter.default.post(name: .rewindpadConnectionChanged, object: nil)
        }
    }

    private func markConnectionActive(_ connection: NWConnection, deviceName: String? = nil) {
        authenticatedConnections.insert(ObjectIdentifier(connection))
        let previousConnection = connectedConnection
        connectedConnection = connection
        pendingConnection = nil

        if let previousConnection, previousConnection !== connection {
            previousConnection.cancel()
            authenticatedConnections.remove(ObjectIdentifier(previousConnection))
            receiveBuffers.removeValue(forKey: ObjectIdentifier(previousConnection))
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Cancel any pending grace-period timer — the device reconnected in time.
            self.cancelDisconnectGrace()

            let changed = self.isConnected == false || (deviceName != nil && self.connectedDeviceName != deviceName)
            self.isConnected = true

            if let deviceName, !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
                self.connectedDeviceName = name
                // Persist so we can show "Reconnecting to X…" after a long background.
                self.lastKnownDeviceName = name
                UserDefaults.standard.set(name, forKey: "rw_last_known_device_name")
            }

            if changed {
                NotificationCenter.default.post(name: .rewindpadConnectionChanged, object: nil)
            }
        }
    }

    private func markConnectionInactive(_ connection: NWConnection? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if let connection, connection !== self.connectedConnection {
                return
            }

            // Remove from auth set immediately so no further commands can sneak through.
            if let connection {
                self.authenticatedConnections.remove(ObjectIdentifier(connection))
            } else if let connectedConnection = self.connectedConnection {
                self.authenticatedConnections.remove(ObjectIdentifier(connectedConnection))
            }
            self.connectedConnection = nil

            // Don't flip isConnected → false immediately. Give the iPhone a grace window
            // to reconnect (background task keeps it alive ~30s). If a new authenticated
            // connection arrives before the timer fires, it cancels the grace timer and
            // the UI never flashes the PIN screen.
            self.scheduleDisconnectGrace()
        }
    }

    private func scheduleDisconnectGrace() {
        disconnectGraceTimer?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // If the device reconnected and re-authenticated before the timer fired,
            // connectedConnection will be non-nil — skip the flip.
            guard self.connectedConnection == nil else { return }
            self.isConnected = false
            self.connectedDeviceName = nil
            // lastKnownDeviceName is intentionally kept — it drives the
            // "Reconnecting to X…" screen instead of showing the PIN QR code.
            NotificationCenter.default.post(name: .rewindpadConnectionChanged, object: nil)
        }
        disconnectGraceTimer = task
        // isConnected stays true during the grace window so the UI doesn't flash the PIN screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + disconnectGraceSeconds, execute: task)
    }

    private func cancelDisconnectGrace() {
        disconnectGraceTimer?.cancel()
        disconnectGraceTimer = nil
    }

    private static func generatePIN() -> String {
        String(format: "%04d", Int.random(in: 1000...9999))
    }

    private func loadTrustedDevices() -> [String: String] {
        // Return the in-memory cache if available — survives Keychain lock (screen saver / sleep).
        if let cached = cachedTrustedDevices {
            return cached
        }
        // First call: read from Keychain (accessible while unlocked or after first unlock).
        let devices: [String: String]
        if let json = KeychainHelper.get(forKey: trustedDevicesKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            devices = decoded
        } else {
            devices = migrateTrustedDevicesFromUserDefaults()
        }
        // Only cache non-empty results. If Keychain was transiently inaccessible
        // (e.g., locked during early startup), the empty dict must not be frozen in
        // cache — the next reconnect attempt should retry the Keychain read.
        if !devices.isEmpty {
            cachedTrustedDevices = devices
        }
        return devices
    }

    private func saveTrustedDevices(_ devices: [String: String]) {
        cachedTrustedDevices = devices   // update in-memory mirror immediately
        guard let data = try? JSONEncoder().encode(devices),
              let json = String(data: data, encoding: .utf8) else {
            return
        }

        KeychainHelper.set(json, forKey: trustedDevicesKey)
        UserDefaults.standard.removeObject(forKey: trustedDevicesKey)

        // Keep the published flag in sync so the UI reacts without polling.
        let hasAny = !devices.isEmpty
        DispatchQueue.main.async { [weak self] in
            self?.hasTrustedDevices = hasAny
        }
    }

    private func migrateTrustedDevicesFromUserDefaults() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: trustedDevicesKey),
              let devices = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }

        saveTrustedDevices(devices)
        return devices
    }

    private func loadTrustedDeviceNames() -> [String: String] {
        guard let json = KeychainHelper.get(forKey: trustedDeviceNamesKey),
              let data = json.data(using: .utf8),
              let devices = try? JSONDecoder().decode([String: String].self, from: data) else {
            return migrateTrustedDeviceNamesFromUserDefaults()
        }

        return devices
    }

    private func saveTrustedDeviceNames(_ devices: [String: String]) {
        guard let data = try? JSONEncoder().encode(devices),
              let json = String(data: data, encoding: .utf8) else {
            return
        }

        KeychainHelper.set(json, forKey: trustedDeviceNamesKey)
        UserDefaults.standard.removeObject(forKey: trustedDeviceNamesKey)
    }

    private func migrateTrustedDeviceNamesFromUserDefaults() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: trustedDeviceNamesKey),
              let devices = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }

        saveTrustedDeviceNames(devices)
        return devices
    }

    private func stableTCPParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        return parameters
    }

    private func startServer() {
        do {
            let params = stableTCPParameters()
            let listener = try NWListener(using: params, on: port)

            let ipv4 = Self.localIPv4Address() ?? ""
            let txtRecord = NWTXTRecord(["ipv4": ipv4])

            listener.service = NWListener.Service(
                name: Self.bonjourServiceName,
                type: bonjourType,
                txtRecord: txtRecord
            )

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }

                switch state {
                case .ready:
                    print("Rewindpad server listening on port 9422 and advertising Bonjour \(self.bonjourType)")
                case .failed(let error):
                    print("Rewindpad server failed: \(error)")
                case .cancelled:
                    print("Rewindpad server cancelled")
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            self.listener = listener
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            print("Failed to start Rewindpad server: \(error)")
        }
    }

    /// Called when the Mac wakes from sleep.
    /// Recycles all network infrastructure while leaving active scenes untouched.
    private func restartAfterWake() {
        // Tear down existing sockets — they are invalid after sleep.
        listener?.cancel()
        listener = nil
        connectedConnection?.cancel()
        connectedConnection = nil
        pendingConnection?.cancel()
        pendingConnection = nil
        authenticatedConnections.removeAll()
        receiveBuffers.removeAll()
        cancelDisconnectGrace()

        // Flip connection state on the main thread (UI observes this).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isConnected = false
            self.connectedDeviceName = nil
            // lastKnownDeviceName is preserved — the iPhone will reconnect
            // automatically and the UI shows "Reconnecting to X" rather than
            // a fresh PIN QR code.
            NotificationCenter.default.post(name: .rewindpadConnectionChanged, object: nil)
        }

        // Give the OS a moment to re-initialise the network stack after wake,
        // then bring the Bonjour listener back up.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.startServer()
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        // Do not cancel the active iPhone connection just because a new socket opened.
        // Bonjour retries / reconnect probes can create short-lived extra sockets.
        // Replacing the active socket before the new one authenticates causes
        // "connection reset by peer" on the iPhone after 50-60 seconds.
        pendingConnection = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }

            switch state {
            case .cancelled, .failed:
                DispatchQueue.main.async {
                    if connection === self.pendingConnection {
                        self.pendingConnection = nil
                    }

                    if connection === self.pendingTrustConnection {
                        self.pendingTrustConnection = nil
                        self.pendingTrustDeviceID = nil
                        self.pendingTrustDeviceName = nil
                        self.pendingTrustRequest = nil
                    }
                }
                // Route through markConnectionInactive so the grace timer fires
                // instead of immediately setting isConnected = false.
                self.markConnectionInactive(connection)
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
        receiveMessage(from: connection)
    }

    private func receiveMessage(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                let key = ObjectIdentifier(connection)
                var buffer = self.receiveBuffers[key] ?? Data()
                buffer.append(data)
                self.receiveBuffers[key] = buffer
                self.processBuffer(for: connection)
            }

            if !isComplete && error == nil {
                self.receiveMessage(from: connection)
            } else {
                DispatchQueue.main.async {
                    if connection === self.pendingConnection {
                        self.pendingConnection = nil
                    }
                    self.receiveBuffers.removeValue(forKey: ObjectIdentifier(connection))
                }
                // Route through markConnectionInactive so the grace timer fires
                // instead of immediately setting isConnected = false.
                self.markConnectionInactive(connection)
            }
        }
    }

    private func processBuffer(for connection: NWConnection) {
        let key = ObjectIdentifier(connection)

        guard var buffer = receiveBuffers[key] else {
            return
        }

        while buffer.count >= 4 {
            let lengthData = buffer.prefix(4)
            let length = lengthData.reduce(UInt32(0)) { partial, byte in
                (partial << 8) | UInt32(byte)
            }

            let totalNeeded = 4 + Int(length)

            guard buffer.count >= totalNeeded else {
                break
            }

            let messageData = buffer.subdata(in: 4..<totalNeeded)
            buffer = buffer.subdata(in: totalNeeded..<buffer.count)

            if let message = try? JSONDecoder().decode(ClientMessage.self, from: messageData) {
                handleMessage(message, from: connection)
            }
        }

        receiveBuffers[key] = buffer
    }

    private func handleMessage(_ message: ClientMessage, from connection: NWConnection) {
        let isAuthMessage = message.type == "auth" || message.type == "trustedAuth" || message.type == "trustRequest"

        if !isAuthMessage && !authenticatedConnections.contains(ObjectIdentifier(connection)) {
            sendResponse(["ok": false, "error": "auth_required"], to: connection)
            return
        }

        switch message.type {
        case "trustedAuth":
            handleTrustedAuth(message, from: connection)

        case "trustRequest":
            handleTrustRequest(message, from: connection)

        case "auth":
            let auth = decodePinAuthPayload(from: message.payload)
            let submittedPIN = submittedAuthPIN(from: message.payload, decodedAuth: auth)
            let currentPIN = normalizedPIN(pin)

            guard submittedPIN == currentPIN else {
                sendResponse(["ok": false, "error": "wrong_pin"], to: connection)
                return
            }

            let cleanName = auth?.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
            var response: [String: Any] = ["ok": true, "macName": Self.deviceDisplayName]

            if let deviceID = auth?.deviceID.trimmingCharacters(in: .whitespacesAndNewlines), !deviceID.isEmpty {
                let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                var devices = loadTrustedDevices()
                devices[deviceID] = token
                saveTrustedDevices(devices)

                if let cleanName, !cleanName.isEmpty {
                    var names = loadTrustedDeviceNames()
                    names[deviceID] = cleanName
                    saveTrustedDeviceNames(names)
                    response["deviceName"] = cleanName
                }

                response["trusted"] = true
                response["token"] = token
            }

            let knownName: String? = auth.flatMap { loadTrustedDeviceNames()[$0.deviceID] }
            markConnectionActive(connection, deviceName: cleanName?.isEmpty == false ? cleanName : knownName)
            sendResponse(response, to: connection)
            sendState(to: connection)
            sendAvailableApps(to: connection)
            sendAvailableShortcuts(to: connection)
            sendSavedShortcuts(to: connection)

        case "paste":
            markConnectionActive(connection)

            if let content = message.payload {
                pasteToClipboard(content)
                sendResponse(["ok": true], to: connection)
            }

        case "open":
            markConnectionActive(connection)

            if let path = message.payload {
                openFile(path)
                sendResponse(["ok": true], to: connection)
            }

        case "switch":
            markConnectionActive(connection)

            if let appName = message.payload {
                switchToApp(appName)
                sendResponse(["ok": true], to: connection)
            }

        case "command":
            markConnectionActive(connection)

            if let command = message.payload {
                performCommand(command)
                sendResponse(["ok": true], to: connection)
            }

        case "addShortcut":
            markConnectionActive(connection)

            if let payload = message.payload {
                sendResponse(["ok": true], to: connection)
                addShortcutFromPayload(payload)
            }

        case "removeShortcut":
            markConnectionActive(connection)

            if let shortcutID = message.payload {
                sendResponse(["ok": true], to: connection)
                removeShortcut(shortcutID)
            }

        case "launchShortcut":
            markConnectionActive(connection)

            if let shortcutID = message.payload {
                launchShortcut(shortcutID)
                sendResponse(["ok": true], to: connection)
            }

        case "launchGroup":
            markConnectionActive(connection)

            if let groupID = message.payload {
                // launchAppGroup touches AppKit and @Published properties — must run on main thread.
                // handleMessage is invoked from the Network framework's background queue.
                DispatchQueue.main.async { [weak self] in self?.launchAppGroup(id: groupID) }
                sendResponse(["ok": true], to: connection)
            }

        case "stopAppGroup":
            markConnectionActive(connection)

            if let groupID = message.payload {
                // stopAppGroup calls NSPanel.orderOut, NSRunningApplication.terminate, etc.
                // All AppKit operations require the main thread.
                DispatchQueue.main.async { [weak self] in self?.stopAppGroup(id: groupID) }
                sendResponse(["ok": true], to: connection)
            }

        case "refreshApps":
            markConnectionActive(connection)
            sendResponse(["ok": true], to: connection)
            refreshAvailableAppsAsync()
            scheduleAvailableAppsFollowUpRefreshes()

        case "refreshShortcuts", "refreshShortcutSnapshot":
            markConnectionActive(connection)
            sendResponse(["ok": true], to: connection)
            sendFreshShortcutSyncSnapshot(to: connection)
            scheduleAppleShortcutsBurstRefreshes()

        case "requestLaunchpadSnapshot", "refreshLaunchpadSnapshot":
            markConnectionActive(connection)
            sendResponse(["ok": true], to: connection)
            sendLaunchpadDelta(action: "snapshot", to: connection)

        case "ping":
            markConnectionActive(connection)
            sendResponse(["ok": true, "type": "pong", "macName": Self.deviceDisplayName], to: connection)

        case "refreshState", "getstate":
            markConnectionActive(connection)
            sendState(to: connection)
            sendAvailableApps(to: connection)

        case "appIcon", "requestAppIcon":
            markConnectionActive(connection)

            if let payload = message.payload,
               let data = payload.data(using: .utf8),
               let request = try? JSONDecoder().decode(IconRequestPayload.self, from: data) {
                sendAppIcon(request: request, to: connection)
            }

        case "requestAllAppIcons":
            markConnectionActive(connection)

            if let payload = message.payload,
               let data = payload.data(using: .utf8),
               let request = try? JSONDecoder().decode(IconBatchRequestPayload.self, from: data) {
                sendAppIconsBatch(requests: request.apps, to: connection)
            } else {
                let requests = availableApps.map { IconRequestPayload(id: $0.path.isEmpty ? $0.id : $0.path, path: $0.path) }
                sendAppIconsBatch(requests: requests, to: connection)
            }

        case "requestShortcutsIcon":
            markConnectionActive(connection)
            sendShortcutsIcon(to: connection)

        default:
            break
        }
    }

    private func decodePinAuthPayload(from payload: String?) -> PinAuthPayload? {
        guard let payload,
              let data = payload.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(PinAuthPayload.self, from: data)
    }

    private func submittedAuthPIN(from payload: String?, decodedAuth: PinAuthPayload?) -> String {
        if let pin = decodedAuth?.pin {
            return normalizedPIN(pin)
        }

        let raw = payload?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let digits = raw.filter { $0.isNumber }

        if !raw.contains("{"),
           !raw.contains("}"),
           !raw.contains("\""),
           digits.count == 4 {
            return digits
        }

        return raw
    }

    private func normalizedPIN(_ value: String) -> String {
        let digits = value.filter { $0.isNumber }
        return digits.isEmpty ? value.trimmingCharacters(in: .whitespacesAndNewlines) : digits
    }

    private func handleTrustedAuth(_ message: ClientMessage, from connection: NWConnection) {
        guard let payloadString = message.payload,
              let payloadData = payloadString.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TrustedAuthPayload.self, from: payloadData) else {
            sendResponse(["ok": false, "error": "trust_required"], to: connection)
            return
        }

        let devices = loadTrustedDevices()

        if devices[payload.deviceID] == payload.token {
            let incomingName = payload.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
            var deviceNames = loadTrustedDeviceNames()

            if let incomingName, !incomingName.isEmpty {
                deviceNames[payload.deviceID] = incomingName
                saveTrustedDeviceNames(deviceNames)
            }

            let resolvedName = incomingName?.isEmpty == false ? incomingName
                            : deviceNames[payload.deviceID]?.isEmpty == false ? deviceNames[payload.deviceID]
                            : nil   // fallback: never show QR screen after a trusted reconnect
            markConnectionActive(connection, deviceName: resolvedName)

            sendResponse(["ok": true, "trusted": true, "macName": Self.deviceDisplayName], to: connection)
            sendState(to: connection)
            sendAvailableApps(to: connection)
        } else {
            sendResponse(["ok": false, "error": "invalid_trust"], to: connection)
        }
    }

    private func handleTrustRequest(_ message: ClientMessage, from connection: NWConnection) {
        guard let payloadString = message.payload,
              let payloadData = payloadString.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TrustedPairingPayload.self, from: payloadData) else {
            sendResponse(["ok": false, "error": "trust_required"], to: connection)
            return
        }

        pendingTrustConnection = connection
        pendingTrustDeviceID = payload.deviceID
        pendingTrustDeviceName = payload.deviceName

        DispatchQueue.main.async {
            self.pendingTrustRequest = TrustedPairingRequest(
                id: payload.deviceID,
                deviceName: payload.deviceName
            )
            self.connectedDeviceName = nil
            self.isConnected = false
            NotificationCenter.default.post(name: .rewindpadConnectionChanged, object: nil)
        }

        sendResponse(["ok": false, "pending_trust": true], to: connection)
    }

    private func safeInlineIconData(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanValue.isEmpty, cleanValue.count <= rewindpadMaxInlineIconCharacters else { return nil }
        return cleanValue
    }

    // Resolves persistent file references (launchpad-icon://...) to actual base64 before
    // sending to iPhone. The iPhone has no access to the Mac's Application Support folder.
    private func transportableIconData(_ value: String?) -> String? {
        let base64 = MacPersistentIconStore.base64ForTransport(value) ?? value
        return safeInlineIconData(base64)
    }

    private func displayShortcutForIPhone(_ shortcut: SavedShortcut) -> SavedShortcut {
        // Keep all realtime/state shortcut payloads lightweight.
        // Do NOT render or read app icons here. Icon generation is expensive and was the main
        // reason Mac editor changes could feel delayed on iPhone.
        // iPhone will request missing icons separately after the tile is already visible.
        let safeShortcut = RewindpadShortcutDiskStore.storageSafe(shortcut)

        return SavedShortcut(
            id: safeShortcut.id,
            title: safeShortcut.title,
            type: safeShortcut.type,
            target: safeShortcut.target,
            icon: safeShortcut.icon,
            iconData: rewindpadSocketStringIsEmoji(shortcut.icon) ? nil : transportableIconData(shortcut.iconData),
            createdAt: safeShortcut.createdAt,
            pageIndex: safeShortcut.pageIndex,
            slotIndex: safeShortcut.slotIndex,
            pageRows: safeShortcut.pageRows
        )
    }

    private func deltaShortcutForIPhone(_ shortcut: SavedShortcut) -> SavedShortcut {
        let safeShortcut = RewindpadShortcutDiskStore.storageSafe(shortcut)

        return SavedShortcut(
            id: safeShortcut.id,
            title: safeShortcut.title,
            type: safeShortcut.type,
            target: safeShortcut.target,
            icon: safeShortcut.icon,
            iconData: rewindpadSocketStringIsEmoji(shortcut.icon) ? nil : transportableIconData(shortcut.iconData),
            createdAt: safeShortcut.createdAt,
            pageIndex: safeShortcut.pageIndex,
            slotIndex: safeShortcut.slotIndex,
            pageRows: safeShortcut.pageRows
        )
    }

    private func displayShortcutsForIPhone() -> [SavedShortcut] {
        shortcuts.map { displayShortcutForIPhone($0) }
    }

    private func sendState(to connection: NWConnection) {
        let lightweightApps = availableApps.map { app in
            AvailableApp(id: app.id, name: app.name, path: app.path, icon: app.icon, iconData: nil)
        }
        let lightweightShortcuts = displayShortcutsForIPhone()
        let lightweightAppleShortcuts = availableShortcuts.map { shortcut in
            AppleShortcut(id: shortcut.id, name: shortcut.name, iconData: nil)
        }

        var payload = StatePayload(
            clipboard: Array(clipboardHistory.prefix(60)),
            files: Array(recentFiles.prefix(40)),
            apps: Array(runningApps.prefix(40)),
            availableApps: lightweightApps,
            shortcuts: lightweightShortcuts,
            availableShortcuts: lightweightAppleShortcuts,
            barPageRows: barPageRows
        )
        payload.appGroups = appGroups

        guard let data = try? JSONEncoder().encode(payload) else {
            return
        }

        sendServerMessage(ServerMessage(type: "state", data: data), to: connection)

        // Also push current active-group state so iPhone stays in sync after reconnect.
        let activeIDs = Array(activeAppGroups.keys)
        if let activeData = try? JSONEncoder().encode(activeIDs) {
            sendServerMessage(ServerMessage(type: "activeAppGroups", data: activeData), to: connection)
        }
    }

    private func sendAvailableApps(to connection: NWConnection) {
        let lightweightApps = availableApps.map { app in
            AvailableApp(id: app.id, name: app.name, path: app.path, icon: app.icon, iconData: nil)
        }

        guard let data = try? JSONEncoder().encode(lightweightApps) else {
            return
        }

        sendServerMessage(ServerMessage(type: "availableApps", data: data), to: connection)
    }

    private func sendAvailableShortcuts(to connection: NWConnection) {
        let lightweightShortcuts = availableShortcuts.map { shortcut in
            AppleShortcut(id: shortcut.id, name: shortcut.name, iconData: nil)
        }

        guard let data = try? JSONEncoder().encode(lightweightShortcuts) else {
            return
        }

        sendServerMessage(ServerMessage(type: "availableShortcuts", data: data), to: connection)
    }

    private func sendSavedShortcuts(to connection: NWConnection) {
        let lightweightShortcuts = displayShortcutsForIPhone()

        guard let data = try? JSONEncoder().encode(lightweightShortcuts) else {
            return
        }

        sendServerMessage(ServerMessage(type: "savedShortcuts", data: data), to: connection)
    }

    private func sendShortcutSync(to connection: NWConnection) {
        let payload = ShortcutSyncPayload(
            revision: shortcutsRevision,
            shortcuts: displayShortcutsForIPhone(),
            availableShortcuts: availableShortcuts.map { AppleShortcut(id: $0.id, name: $0.name, iconData: nil) },
            timestamp: Date().timeIntervalSince1970
        )

        guard let data = try? JSONEncoder().encode(payload) else {
            return
        }

        sendServerMessage(ServerMessage(type: "shortcutSync", data: data), to: connection)
    }

    private func sendLaunchpadDelta(
        action: String,
        shortcut: SavedShortcut? = nil,
        removedID: String? = nil,
        removedTarget: String? = nil,
        removedType: String? = nil,
        to connection: NWConnection
    ) {
        // Millisecond path:
        // upsert/remove sends only the changed shortcut/removal keys.
        // No app icons, no full shortcut array, no state payload.
        let displayShortcut = shortcut.map { deltaShortcutForIPhone($0) }
        let shouldIncludeSnapshot = action == "snapshot"

        let payload = LaunchpadDeltaPayload(
            revision: shortcutsRevision,
            action: action,
            shortcut: displayShortcut,
            removedID: removedID,
            removedTarget: removedTarget,
            removedType: removedType,
            shortcuts: shouldIncludeSnapshot ? displayShortcutsForIPhone() : [],
            barPageRows: barPageRows,
            timestamp: Date().timeIntervalSince1970
        )

        guard let data = try? JSONEncoder().encode(payload) else {
            return
        }

        sendServerMessage(ServerMessage(type: "launchpadDelta", data: data), to: connection)
    }

    private func sendFreshShortcutSyncSnapshot(to connection: NWConnection) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak connection] in
            guard let self, let connection else { return }

            let freshShortcuts = self.fetchAppleShortcuts()
            let freshSignature = freshShortcuts.map { $0.name }.joined(separator: "\u{1F}")

            DispatchQueue.main.async { [weak self, weak connection] in
                guard let self, let connection else { return }

                self.availableShortcuts = freshShortcuts
                self.lastAvailableShortcutsSignature = freshSignature
                self.pruneSavedShortcutsForCurrentAppleShortcuts(freshShortcuts)
                self.sendShortcutSync(to: connection)
            }
        }
    }

    private func pushShortcutSyncUpdate(forceRescan: Bool = true) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isConnected,
                  let connection = self.connectedConnection else {
                return
            }

            if forceRescan {
                self.sendFreshShortcutSyncSnapshot(to: connection)
            } else {
                self.sendShortcutSync(to: connection)
            }
        }
    }

    private func pruneSavedShortcutsForCurrentAppleShortcuts(_ appleShortcuts: [AppleShortcut]) {
        let appleNames = Set(appleShortcuts.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        guard !appleNames.isEmpty else { return }

        let oldCount = shortcuts.count
        shortcuts.removeAll { savedShortcut in
            guard savedShortcut.type == "shortcut" else { return false }

            let title = savedShortcut.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let target = savedShortcut.target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let id = savedShortcut.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            return !appleNames.contains(title) && !appleNames.contains(target) && !appleNames.contains(id)
        }

        if shortcuts.count != oldCount {
            shortcutsRevision += 1
            saveShortcuts()
        }
    }

    private func pushSavedShortcutsUpdate() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isConnected,
                  let connection = self.connectedConnection else {
                return
            }

            self.sendSavedShortcuts(to: connection)
            self.sendShortcutSync(to: connection)
        }
    }

    private func pushAvailableShortcutsUpdate() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isConnected,
                  let connection = self.connectedConnection else {
                return
            }

            self.sendAvailableShortcuts(to: connection)
            self.sendShortcutSync(to: connection)
        }
    }

    private func pushAvailableAppsUpdate() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let connection = self.connectedConnection else {
                return
            }

            self.sendAvailableApps(to: connection)
        }
    }

    private func sendAppIcon(request: IconRequestPayload, to connection: NWConnection) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let iconData = self?.officialIconData(forAppAt: request.path)
            let response = IconResponsePayload(id: request.id, iconData: iconData)

            guard let data = try? JSONEncoder().encode(response) else {
                return
            }

            self?.sendServerMessage(ServerMessage(type: "appIcon", data: data), to: connection)
        }
    }

    private func sendAppIconsBatch(requests: [IconRequestPayload], to connection: NWConnection) {
        let cleanedRequests = requests.filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard !cleanedRequests.isEmpty else {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            for chunkStart in stride(from: 0, to: min(cleanedRequests.count, 48), by: 8) {
                let chunkEnd = min(chunkStart + 8, cleanedRequests.count)
                let chunk = Array(cleanedRequests[chunkStart..<chunkEnd])

                let icons = chunk.map { request in
                    IconResponsePayload(
                        id: request.id,
                        iconData: self.officialIconData(forAppAt: request.path)
                    )
                }

                let payload = IconBatchPayload(icons: icons)

                guard let data = try? JSONEncoder().encode(payload) else {
                    continue
                }

                self.sendServerMessage(ServerMessage(type: "appIconsBatch", data: data), to: connection)
            }
        }
    }

    private func sendShortcutsIcon(to connection: NWConnection) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let response = IconResponsePayload(id: "shortcuts", iconData: self?.shortcutOfficialIconData())

            guard let data = try? JSONEncoder().encode(response) else {
                return
            }

            self?.sendServerMessage(ServerMessage(type: "shortcutsIcon", data: data), to: connection)
        }
    }

    private func sendResponse(_ dictionary: [String: Any], to connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary) else {
            return
        }

        sendServerMessage(ServerMessage(type: "response", data: data), to: connection)
    }

    private func sendServerMessage(_ message: ServerMessage, to connection: NWConnection) {
        guard let responseData = try? JSONEncoder().encode(message) else {
            return
        }

        var length = UInt32(responseData.count).bigEndian
        let lengthPrefix = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        let packet = lengthPrefix + responseData

        connection.send(content: packet, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection else { return }

            DispatchQueue.main.async {
                if let error {
                    print("Rewindpad send failed: \(error.localizedDescription)")

                    if connection === self.connectedConnection {
                        self.markConnectionInactive(connection)
                    }
                } else {
                    self.lastSuccessfulSendAt = Date()
                }
            }
        })
    }

    func pushStateUpdate() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let connection = self.connectedConnection else {
                return
            }

            self.sendState(to: connection)
        }
    }

    func pushStateUpdateDebouncedFromUI(delay: TimeInterval = 0.20) {
        pushStateUpdateDebounced(delay: delay)
        pushShortcutSyncUpdate(forceRescan: false)
    }

    func pushLaunchpadDeltaUpsert(_ shortcut: SavedShortcut) {
        pushEditorLaunchpadChange(action: "upsert", shortcut: shortcut)
    }

    func pushLaunchpadDeltaRemove(_ shortcut: SavedShortcut) {
        pushEditorLaunchpadChange(
            action: "remove",
            shortcut: nil,
            removedID: shortcut.id,
            removedTarget: shortcut.target,
            removedType: shortcut.type
        )
    }

    func pushLaunchpadDeltaSnapshot() {
        pushEditorLaunchpadChange(action: "snapshot")
    }

    private func pushEditorLaunchpadChange(
        action: String,
        shortcut: SavedShortcut? = nil,
        removedID: String? = nil,
        removedTarget: String? = nil,
        removedType: String? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.shortcutsRevision += 1

            guard self.isConnected, let connection = self.connectedConnection else {
                self.isConnected = false
                self.connectedDeviceName = nil
                NotificationCenter.default.post(name: .rewindpadConnectionChanged, object: nil)
                return
            }

            self.sendLaunchpadDelta(
                action: action,
                shortcut: shortcut,
                removedID: removedID,
                removedTarget: removedTarget,
                removedType: removedType,
                to: connection
            )

            // Do not send backup sync immediately. That was competing with the delta path.
            // The tiny delta should reach iPhone first; consistency sync follows later.
            self.scheduleEditorRecoveryPush()
        }
    }

    private func scheduleEditorRecoveryPush() {
        editorRecoveryPushWorkItem?.cancel()

        let task = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isConnected,
                  let connection = self.connectedConnection else {
                return
            }

            // Backup consistency only. Keep it away from the millisecond delta path.
            self.sendShortcutSync(to: connection)
        }

        editorRecoveryPushWorkItem = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.80, execute: task)
    }

    private func pushStateUpdateDebounced(delay: TimeInterval = 0.35) {
        statePushWorkItem?.cancel()

        let task = DispatchWorkItem { [weak self] in
            self?.pushStateUpdate()
        }

        statePushWorkItem = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func startDirectoryWatchers() {
        stopDirectoryWatchers()

        let appDirectories = [
            "/Applications",
            NSHomeDirectory() + "/Applications"
        ]

        let shortcutDirectories = [
            NSHomeDirectory() + "/Library/Shortcuts",
            NSHomeDirectory() + "/Library/Group Containers/group.com.apple.shortcuts",
            NSHomeDirectory() + "/Library/Containers/com.apple.shortcuts"
        ]

        appDirectoryWatchSources = appDirectories.compactMap { path in
            makeDirectoryWatcher(path: path) { [weak self] in
                self?.scheduleDirectoryDrivenAppsRefresh()
            }
        }

        shortcutDirectoryWatchSources = shortcutDirectories.compactMap { path in
            makeDirectoryWatcher(path: path) { [weak self] in
                self?.scheduleDirectoryDrivenShortcutRefresh()
            }
        }
    }

    private func stopDirectoryWatchers() {
        appDirectoryRefreshWorkItem?.cancel()
        shortcutDirectoryRefreshWorkItem?.cancel()
        appDirectoryRefreshWorkItem = nil
        shortcutDirectoryRefreshWorkItem = nil

        appsFollowUpWorkItems.forEach { $0.cancel() }
        shortcutsBurstWorkItems.forEach { $0.cancel() }
        appsFollowUpWorkItems = []
        shortcutsBurstWorkItems = []

        appDirectoryWatchSources.forEach { $0.cancel() }
        shortcutDirectoryWatchSources.forEach { $0.cancel() }
        appDirectoryWatchSources = []
        shortcutDirectoryWatchSources = []
    }

    private func makeDirectoryWatcher(path: String, onChange: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        let fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return nil
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete],
            queue: .main
        )

        source.setEventHandler(handler: onChange)
        source.setCancelHandler {
            close(fileDescriptor)
        }
        source.resume()
        return source
    }

    private func scheduleDirectoryDrivenAppsRefresh() {
        appDirectoryRefreshWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshAvailableAppsAsync()
            self.scheduleAvailableAppsFollowUpRefreshes()
        }

        appDirectoryRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func scheduleDirectoryDrivenShortcutRefresh() {
        shortcutDirectoryRefreshWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pushShortcutSyncUpdate(forceRescan: true)
            self.refreshAppleShortcutsAsync()
            self.scheduleAppleShortcutsBurstRefreshes()
        }

        shortcutDirectoryRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func scheduleAvailableAppsFollowUpRefreshes() {
        appsFollowUpWorkItems.forEach { $0.cancel() }
        appsFollowUpWorkItems = []

        let delays: [TimeInterval] = [0.35, 0.9, 1.8, 3.2]
        appsFollowUpWorkItems = delays.map { delay in
            let item = DispatchWorkItem { [weak self] in
                self?.refreshAvailableAppsAsync()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
    }

    private func scheduleAppleShortcutsBurstRefreshes() {
        shortcutsBurstWorkItems.forEach { $0.cancel() }
        shortcutsBurstWorkItems = []

        let delays: [TimeInterval] = [0.25, 0.6, 1.1, 1.8, 3.0, 5.0]
        shortcutsBurstWorkItems = delays.map { delay in
            let item = DispatchWorkItem { [weak self] in
                self?.refreshAppleShortcutsAsync()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
    }

    private func startPolling() {
        clipTimer?.invalidate()
        appsTimer?.invalidate()
        shortcutsTimer?.invalidate()
        systemLoadTimer?.invalidate()

        clipTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.pollClipboard()
        }

        appsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshAppsAndFiles()
        }

        shortcutsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, self.isConnected else { return }
            self.refreshAppleShortcutsIfChangedAsync()
        }

        systemLoadTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateLocalSystemLoad()
            if self.isConnected, let conn = self.connectedConnection {
                self.sendSystemLoad(to: conn)
            }
        }

        RunLoop.main.add(clipTimer!, forMode: .common)
        RunLoop.main.add(appsTimer!, forMode: .common)
        RunLoop.main.add(shortcutsTimer!, forMode: .common)
        RunLoop.main.add(systemLoadTimer!, forMode: .common)
        updateLocalSystemLoad()
    }

    private func pollClipboard() {
        let pasteboard = NSPasteboard.general

        guard let content = pasteboard.string(forType: .string),
              !content.isEmpty,
              content != lastClipboard else {
            return
        }

        lastClipboard = content

        let item = ClipboardItem(
            id: Int(Date().timeIntervalSince1970 * 1000),
            content: content,
            type: detectType(content),
            time: Date(),
            preview: String(content.prefix(80)).replacingOccurrences(of: "\n", with: " ")
        )

        DispatchQueue.main.async {
            self.clipboardHistory.insert(item, at: 0)

            if self.clipboardHistory.count > 20 {
                self.clipboardHistory.removeLast()
            }

            self.pushStateUpdate()
        }
    }

    private func detectType(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return "url"
        }

        let codeKeywords = [
            "const ",
            "let ",
            "var ",
            "func ",
            "import ",
            "class ",
            "struct ",
            "if ",
            "for ",
            "return "
        ]

        if codeKeywords.contains(where: { trimmed.contains($0) }) {
            return "code"
        }

        return "text"
    }

    private func pasteToClipboard(_ content: String) {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(content, forType: .string)
        }
    }

    private func refreshAppsAndFiles() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let runningApps = self?.fetchRunningApps() ?? []
            let recentFiles = self?.fetchRecentFiles() ?? []

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                self.runningApps = runningApps
                self.recentFiles = recentFiles
                self.pushStateUpdate()
            }
        }
    }

    private func refreshAvailableAppsAsync() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let apps = self?.fetchAvailableApps() ?? []

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                self.availableApps = apps
                self.pushAvailableAppsUpdate()
            }
        }
    }

    private func fetchRunningApps() -> [RunningApp] {
        let workspace = NSWorkspace.shared
        let frontmost = workspace.frontmostApplication?.localizedName ?? ""

        return workspace.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.localizedName != nil }
            .enumerated()
            .map { index, app in
                let name = app.localizedName ?? "Unknown"

                return RunningApp(
                    id: name,
                    name: name,
                    active: name == frontmost,
                    order: index
                )
            }
    }

    private func fetchAvailableApps() -> [AvailableApp] {
        // Fast, user-friendly app list:
        // 1. Include all third-party apps from /Applications and ~/Applications.
        // 2. Include only essential Apple apps users actually expect to launch.
        // This keeps the Add App modal fast and prevents scanning/icon-loading 100+ system apps.
        let folders = [
            "/Applications",
            "\(NSHomeDirectory())/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices/Applications"
        ]

        var results: [AvailableApp] = []
        var seenPaths = Set<String>()
        var seenBundleIDs = Set<String>()

        func appendApp(at url: URL) {
            guard url.pathExtension.lowercased() == "app" else {
                return
            }

            let path = url.path

            guard !seenPaths.contains(path) else {
                return
            }

            guard FileManager.default.fileExists(atPath: path) else {
                return
            }

            let name = localizedAppName(for: url)
            let bundleID = Bundle(url: url)?.bundleIdentifier ?? ""

            guard shouldShowInAvailableApps(name: name, path: path, bundleID: bundleID) else {
                return
            }

            if !bundleID.isEmpty {
                guard !seenBundleIDs.contains(bundleID) else {
                    return
                }

                seenBundleIDs.insert(bundleID)
            }

            seenPaths.insert(path)

            results.append(
                AvailableApp(
                    id: path,
                    name: displayNameForAvailableApp(name),
                    path: path,
                    icon: "",
                    iconData: nil,
                    bundleIdentifier: bundleID.isEmpty ? nil : bundleID
                )
            )
        }

        for folder in folders {
            let folderURL = URL(fileURLWithPath: folder, isDirectory: true)

            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isApplicationKey, .isDirectoryKey, .localizedNameKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for url in contents {
                appendApp(at: url)
            }
        }

        return results.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func shouldShowInAvailableApps(name: String, path: String, bundleID: String) -> Bool {
        let normalizedName = normalizedAvailableAppName(name)
        let normalizedBundleID = bundleID.lowercased()
        let isAppleApp = normalizedBundleID.hasPrefix("com.apple.") || path.hasPrefix("/System/")

        if !isAppleApp {
            return true
        }

        return Self.essentialAppleAppNames.contains(normalizedName) || Self.essentialAppleBundleIDs.contains(normalizedBundleID)
    }

    private static let essentialAppleAppNames: Set<String> = [
            "app store",
            "books",
            "calculator",
            "calendar",
            "contacts",
            "facetime",
            "find my",
            "freeform",
            "home",
            "mail",
            "maps",
            "messages",
            "music",
            "notes",
            "photos",
            "podcasts",
            "preview",
            "quicktime player",
            "reminders",
            "safari",
            "shortcuts",
            "system settings",
            "terminal",
            "textedit",
            "tv",
            "voice memos"
    ]

    private static let essentialAppleBundleIDs: Set<String> = [
            "com.apple.appstore",
            "com.apple.books",
            "com.apple.calculator",
            "com.apple.ical",
            "com.apple.addressbook",
            "com.apple.facetime",
            "com.apple.findmy",
            "com.apple.freeform",
            "com.apple.home",
            "com.apple.mail",
            "com.apple.maps",
            "com.apple.messages",
            "com.apple.music",
            "com.apple.notes",
            "com.apple.photos",
            "com.apple.podcasts",
            "com.apple.preview",
            "com.apple.quicktimeplayerx",
            "com.apple.reminders",
            "com.apple.safari",
            "com.apple.shortcuts",
            "com.apple.systempreferences",
            "com.apple.systemsettings",
            "com.apple.terminal",
            "com.apple.textedit",
            "com.apple.tv",
            "com.apple.voicememos"
    ]

    private func normalizedAvailableAppName(_ name: String) -> String {
        name
            .replacingOccurrences(of: ".app", with: "")
            .replacingOccurrences(of: "Apple Music", with: "Music", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func displayNameForAvailableApp(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: ".app", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.localizedCaseInsensitiveContains("Apple Music") {
            return "Music"
        }

        return cleaned
    }

    private func localizedAppName(for url: URL) -> String {
        if let resourceValues = try? url.resourceValues(forKeys: [.localizedNameKey]),
           let localizedName = resourceValues.localizedName,
           !localizedName.isEmpty {
            return localizedName.replacingOccurrences(of: ".app", with: "")
        }

        return url.deletingPathExtension().lastPathComponent
    }

    private func cachedOfficialIconData(forAppAt path: String) -> String? {
        officialIconDataCacheQueue.sync {
            officialIconDataCache[path]
        }
    }

    private func cacheOfficialIconData(_ data: String, forAppAt path: String) {
        officialIconDataCacheQueue.sync {
            officialIconDataCache[path] = data
        }
    }

    private func removeCachedOfficialIconData(forAppAt path: String) {
        officialIconDataCacheQueue.sync {
            officialIconDataCache.removeValue(forKey: path)
        }
    }

    private func officialIconData(forAppAt path: String) -> String? {
        guard !path.isEmpty else {
            return nil
        }

        if let cached = cachedOfficialIconData(forAppAt: path) {
            let cleanCached = sanitizedOfficialIconData(cached)
            if let cleanCached {
                return cleanCached
            }

            removeCachedOfficialIconData(forAppAt: path)
        }

        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        let cacheURL = officialIconCacheURL(forAppAt: path)

        if let cacheURL,
           let cached = try? String(contentsOf: cacheURL, encoding: .utf8) {
            if let cleanCached = sanitizedOfficialIconData(cached) {
                cacheOfficialIconData(cleanCached, forAppAt: path)
                return cleanCached
            }

            try? FileManager.default.removeItem(at: cacheURL)
        }

        let encoded: String? = autoreleasepool {
            let icon = NSWorkspace.shared.icon(forFile: path)
            let targetSize = NSSize(width: 64, height: 64)
            let rendered = NSImage(size: targetSize)

            rendered.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            icon.draw(
                in: NSRect(origin: .zero, size: targetSize),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
            rendered.unlockFocus()

            guard let tiffData = rendered.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                return nil
            }

            return pngData.base64EncodedString()
        }

        guard let cleanEncoded = sanitizedOfficialIconData(encoded) else {
            return nil
        }

        cacheOfficialIconData(cleanEncoded, forAppAt: path)

        if let cacheURL {
            try? cleanEncoded.write(to: cacheURL, atomically: true, encoding: .utf8)
        }

        return cleanEncoded
    }

    private func sanitizedOfficialIconData(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleanValue.utf8.count > 500,
              cleanValue.count <= rewindpadMaxInlineIconCharacters,
              Data(base64Encoded: cleanValue, options: .ignoreUnknownCharacters) != nil else {
            return nil
        }

        return cleanValue
    }

    private func officialIconCacheURL(forAppAt path: String) -> URL? {
        guard let directory = officialIconCacheDirectory() else {
            return nil
        }

        let bundleID = Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier ?? ""
        let modified = appModificationTimestamp(forAppAt: path)
        let rawKey = "\(bundleID.isEmpty ? path : bundleID)|\(Int(modified))|\(path)"
        let safeKey = rawKey
            .data(using: .utf8)?
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "") ?? UUID().uuidString

        return directory.appendingPathComponent(safeKey).appendingPathExtension("txt")
    }

    private func appModificationTimestamp(forAppAt path: String) -> TimeInterval {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modifiedDate = attributes[.modificationDate] as? Date else {
            return 0
        }

        return modifiedDate.timeIntervalSince1970
    }

    private func officialIconCacheDirectory() -> URL? {
        let manager = FileManager.default

        guard let appSupport = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let directory = appSupport
            .appendingPathComponent("Rewindpad", isDirectory: true)
            .appendingPathComponent("IconCache", isDirectory: true)

        if !manager.fileExists(atPath: directory.path) {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        return directory
    }

    private func iconForApp(_ name: String) -> String {
        let lower = name.lowercased()

        if lower.contains("safari") { return "🧭" }
        if lower.contains("chrome") { return "🌐" }
        if lower.contains("figma") { return "🎨" }
        if lower.contains("xcode") { return "🔨" }
        if lower.contains("slack") { return "💬" }
        if lower.contains("terminal") { return "⬛" }
        if lower.contains("notes") { return "📓" }
        if lower.contains("calendar") { return "📅" }
        if lower.contains("mail") { return "📧" }
        if lower.contains("shortcuts") { return "✨" }

        return "💠"
    }

    private func fetchRecentFiles() -> [RecentFile] {
        let appMap: [String: String] = [
            "fig": "Figma",
            "pdf": "Preview",
            "tsx": "VS Code",
            "ts": "VS Code",
            "js": "VS Code",
            "jsx": "VS Code",
            "py": "VS Code",
            "md": "VS Code",
            "xlsx": "Numbers",
            "xls": "Numbers",
            "csv": "Numbers",
            "docx": "Pages",
            "doc": "Pages",
            "txt": "TextEdit",
            "png": "Preview",
            "jpg": "Preview",
            "jpeg": "Preview",
            "svg": "Preview"
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = [
            "-onlyin",
            NSHomeDirectory(),
            "kMDItemLastUsedDate >= $time.today(-1)"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        return output.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .filter { !$0.hasSuffix(".app") && !$0.contains(".lproj") }
            .prefix(15)
            .map { path in
                let url = URL(fileURLWithPath: path)
                let ext = url.pathExtension.lowercased()

                return RecentFile(
                    id: path,
                    name: url.lastPathComponent,
                    ext: ext.isEmpty ? "file" : ext,
                    app: appMap[ext] ?? "Finder",
                    path: path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                    time: Date()
                )
            }
    }

    private func switchToApp(_ name: String) {
        DispatchQueue.main.async {
            NSWorkspace.shared.runningApplications
                .first { $0.localizedName == name }?
                .activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func openFile(_ path: String) {
        let expanded = path.replacingOccurrences(of: "~", with: NSHomeDirectory())

        DispatchQueue.main.async {
            NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
        }
    }

    private func addShortcutFromPayload(_ payload: String) {
        guard let decodedShortcut = decodeSavedShortcutPayload(payload) else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let instantShortcut = self.instantShortcutForDisplay(decodedShortcut)

            if let existingIndex = self.shortcuts.firstIndex(where: { $0.target == instantShortcut.target && $0.type == instantShortcut.type }) {
                self.shortcuts[existingIndex] = instantShortcut
            } else {
                self.shortcuts.insert(instantShortcut, at: 0)
            }

            self.shortcutsRevision += 1
            let revision = self.shortcutsRevision
            let snapshot = self.shortcuts
            self.saveShortcutsInBackground(snapshot, revision: revision)

            if let connection = self.connectedConnection {
                self.sendLaunchpadDelta(action: "upsert", shortcut: instantShortcut, to: connection)
            }

            self.scheduleEditorRecoveryPush()
            self.enrichShortcutIconInBackground(shortcutID: instantShortcut.id)
        }
    }

    private func instantShortcutForDisplay(_ shortcut: SavedShortcut) -> SavedShortcut {
        guard shortcut.type == "app" else {
            return shortcut
        }

        let matchingApp = availableApps.first {
            $0.path == shortcut.target ||
            $0.id == shortcut.target ||
            $0.name == shortcut.title ||
            $0.name.localizedCaseInsensitiveCompare(shortcut.title) == .orderedSame
        }

        let resolvedPath = matchingApp?.path ?? shortcut.target
        let resolvedIcon = matchingApp?.icon ?? shortcut.icon

        return SavedShortcut(
            id: shortcut.id,
            title: shortcut.title,
            type: shortcut.type,
            target: resolvedPath,
            icon: resolvedIcon,
            iconData: nil,
            createdAt: shortcut.createdAt
        )
    }

    private func enrichShortcutIconInBackground(shortcutID: String) {
        // Intentionally disabled for Mac performance.
        // Icons are resolved lazily from app paths in the Mac UI or requested on demand by iPhone.
    }


    private func decodeSavedShortcutPayload(_ payload: String) -> SavedShortcut? {
        guard let data = payload.data(using: .utf8) else {
            return nil
        }

        let decoder = JSONDecoder()

        if let shortcut = try? decoder.decode(SavedShortcut.self, from: data) {
            return shortcut
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let id = object["id"] as? String ?? UUID().uuidString
        let title = object["title"] as? String ?? object["name"] as? String ?? "App"
        let type = object["type"] as? String ?? "app"
        let target = object["target"] as? String ?? object["path"] as? String ?? ""
        let icon = object["icon"] as? String ?? "💠"

        let createdAt: Date
        if let seconds = object["createdAt"] as? TimeInterval {
            createdAt = Date(timeIntervalSince1970: seconds)
        } else {
            createdAt = Date()
        }

        guard !target.isEmpty else {
            return nil
        }

        return SavedShortcut(
            id: id,
            title: title,
            type: type,
            target: target,
            icon: icon,
            iconData: nil,
            createdAt: createdAt
        )
    }

    private func enrichShortcutIcon(_ shortcut: SavedShortcut) -> SavedShortcut {
        if shortcut.type == "app" {
            let matchingApp = availableApps.first {
                $0.path == shortcut.target ||
                $0.id == shortcut.target ||
                $0.name == shortcut.title ||
                $0.name.localizedCaseInsensitiveCompare(shortcut.title) == .orderedSame
            }

            return SavedShortcut(
                id: shortcut.id,
                title: shortcut.title,
                type: shortcut.type,
                target: matchingApp?.path ?? shortcut.target,
                icon: matchingApp?.icon ?? shortcut.icon,
                iconData: nil,
                createdAt: shortcut.createdAt
            )
        }

        return RewindpadShortcutDiskStore.storageSafe(shortcut)
    }

    private func removeShortcut(_ payload: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let keys = self.removalKeys(from: payload)
            let oldCount = self.shortcuts.count

            self.shortcuts.removeAll { shortcut in
                keys.contains(shortcut.id) ||
                keys.contains(shortcut.target) ||
                keys.contains(shortcut.title) ||
                keys.contains(shortcut.target.lowercased()) ||
                keys.contains(shortcut.title.lowercased())
            }

            guard self.shortcuts.count != oldCount else {
                self.pushStateUpdate()
                return
            }

            self.shortcutsRevision += 1
            let revision = self.shortcutsRevision
            let snapshot = self.shortcuts
            self.saveShortcutsInBackground(snapshot, revision: revision)

            if let connection = self.connectedConnection {
                self.sendLaunchpadDelta(
                    action: "remove",
                    removedID: payload,
                    removedTarget: payload,
                    removedType: nil,
                    to: connection
                )
            }

            self.scheduleEditorRecoveryPush()
        }
    }

    private func removalKeys(from payload: String) -> Set<String> {
        var keys = Set<String>()

        func add(_ value: String?) {
            guard let value else { return }
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            keys.insert(cleaned)
            keys.insert(cleaned.lowercased())
        }

        add(payload)

        if let data = payload.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            add(object["id"] as? String)
            add(object["target"] as? String)
            add(object["path"] as? String)
            add(object["title"] as? String)
            add(object["name"] as? String)
        }

        return keys
    }

    private func launchShortcut(_ id: String) {
        guard let shortcut = shortcuts.first(where: { $0.id == id }) else {
            return
        }

        switch shortcut.type {
        case "app":
            NSWorkspace.shared.open(URL(fileURLWithPath: shortcut.target))

        case "shortcut":
            runAppleShortcut(shortcut.target)

        case "url", "link":
            let rawURL: String

            if shortcut.target.hasPrefix("http://") || shortcut.target.hasPrefix("https://") {
                rawURL = shortcut.target
            } else {
                rawURL = "https://\(shortcut.target)"
            }

            guard URL(string: rawURL) != nil else {
                return
            }

            openOrReuseURLInBrowser(rawURL, browser: defaultBrowserChoice())

        default:
            break
        }
    }

    private struct LegacySavedShortcut: Codable {
        let id: String
        let title: String
        let type: String
        let target: String
        let icon: String
        let createdAt: Date
    }

    private func loadShortcuts() -> [SavedShortcut] {
        RewindpadShortcutDiskStore.load()
    }

    private func saveShortcuts() {
        RewindpadShortcutDiskStore.save(shortcuts)
    }

    // MARK: - App Group CRUD

    func addAppGroup(_ group: AppGroup) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appGroups.removeAll { $0.id == group.id }
            self.appGroups.insert(group, at: 0)
            AppGroupStore.save(self.appGroups)
            self.pushAppGroupsToPhone()
        }
    }

    func updateAppGroup(_ group: AppGroup) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let idx = self.appGroups.firstIndex(where: { $0.id == group.id }) {
                self.appGroups[idx] = group
            }
            AppGroupStore.save(self.appGroups)
            self.pushAppGroupsToPhone()
        }
    }

    func removeAppGroup(id: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appGroups.removeAll { $0.id == id }
            AppGroupStore.save(self.appGroups)
            self.pushAppGroupsToPhone()
        }
    }

    private func pushAppGroupsToPhone() {
        guard let connection = connectedConnection else { return }
        guard let data = try? JSONEncoder().encode(appGroups) else { return }
        sendServerMessage(ServerMessage(type: "appGroups", data: data), to: connection)
    }

    // ── Diagnostic ──────────────────────────────────────────────────────────────
    // Run this from the UI to get an instant report — no Console needed.
    func requestAutomationPermissionOld() {
        // Old sandbox-based approach — no longer used.
        showAlert(title: "Not needed", message: "Sandbox removed. osascript runs directly.")
    }

    /// Uses AEDeterminePermissionToAutomateTarget — kept for diagnostics.
    func requestAutomationPermissionLegacy() {
        let targets = ["com.apple.finder", "com.apple.systemevents"]
        var results: [(String, OSStatus)] = []

        for bundleID in targets {
            let status: OSStatus = bundleID.withCString { cStr -> OSStatus in
                var desc = AEDesc()
                let createErr: OSErr = AECreateDesc(typeApplicationBundleID, cStr,
                                                    Int(strlen(cStr)), &desc)
                guard createErr == noErr else { return OSStatus(createErr) }
                defer { AEDisposeDesc(&desc) }
                return AEDeterminePermissionToAutomateTarget(
                    &desc, typeWildCard, typeWildCard, true)
            }
            results.append((bundleID, status))
        }

        DispatchQueue.main.async {
            let lines = results.map { (id, status) -> String in
                switch status {
                case noErr:               return "✅ \(id): granted"
                case -1743:              return "❌ \(id): denied by user"
                case -600:               return "⚠️ \(id): not yet determined (re-try)"
                default:                 return "❓ \(id): status=\(status)"
                }
            }
            let allGranted = results.allSatisfy { $0.1 == noErr }

            let alert = NSAlert()
            alert.messageText = "Automation Permission"
            alert.informativeText = lines.joined(separator: "\n") + (allGranted
                ? "\n\n✅ All granted! App Catalyst windows can now be placed."
                : "\n\nIf a dialog appeared, click Allow. Then tap this button again to verify.")
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open Privacy Settings")
            let resp = alert.runModal()
            if resp == .alertSecondButtonReturn {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            }
        }
    }

    func runGroupDiagnostic() {
        var lines: [String] = []
        lines.append("=== Saved Groups ===")
        if appGroups.isEmpty {
            lines.append("No groups saved.")
        }
        for group in appGroups {
            lines.append("Group: \"\(group.name)\" layout=\(group.layout.rawValue)")
            for entry in group.apps {
                let bid = entry.bundleID
                let isPath = bid.hasPrefix("/") || bid.hasPrefix("~")
                lines.append("  App: \(entry.appName)")
                lines.append("    bundleID: \(bid) \(isPath ? "❌ STILL A PATH!" : "✅")")
                lines.append("    path: \(entry.path)")
                // Check if running
                let running = NSWorkspace.shared.runningApplications
                let found = running.first { $0.bundleIdentifier == bid }
                    ?? running.first { $0.localizedName == entry.appName }
                lines.append("    running: \(found != nil ? "✅ \(found!.localizedName ?? "?")" : "not running")")
            }
        }

        lines.append("\n=== AvailableApps bundleIDs ===")
        for app in availableApps.prefix(10) {
            lines.append("  \(app.name): bundleID=\(app.bundleIdentifier ?? "NIL ❌")")
        }

        showAlert(title: "Group Diagnostic", message: lines.joined(separator: "\n"))
    }

    func runAXDiagnostic() {
        var lines: [String] = []

        // 1. AX permission
        let trusted = AXIsProcessTrusted()
        lines.append("AX trusted: \(trusted ? "✅ YES" : "❌ NO")")

        // 2. Stage Manager (kills AX positioning in macOS Ventura+)
        let wmDefaults = UserDefaults(suiteName: "com.apple.WindowManager")
        let stageManager = wmDefaults?.bool(forKey: "GloballyEnabled") ?? false
        lines.append("Stage Manager: \(stageManager ? "⚠️ ON — blocks AX placement!" : "✅ OFF")")

        // 2b. Automation permission for System Events (needed for osascript/AppleScript)
        let autoTest = NSAppleScript(source: "tell application \"System Events\" to get name")
        var autoErr: NSDictionary?
        autoTest?.executeAndReturnError(&autoErr)
        let autoOK = autoErr == nil
        lines.append("Automation (System Events): \(autoOK ? "✅ OK" : "❌ DENIED — grant in System Settings → Privacy → Automation")")

        // 3. Frontmost app
        guard let front = NSWorkspace.shared.frontmostApplication else {
            lines.append("No frontmost app found")
            showAlert(title: "AX Diagnostic", message: lines.joined(separator: "\n"))
            return
        }
        lines.append("Frontmost app: \(front.localizedName ?? "?") (PID \(front.processIdentifier))")

        // 4. AX windows
        let axApp = AXUIElementCreateApplication(front.processIdentifier)
        var ref: CFTypeRef?
        let winErr = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref)
        guard winErr == .success, let wins = ref as? [AXUIElement], !wins.isEmpty else {
            lines.append("AX windows: ❌ none (err=\(winErr.rawValue))")
            showAlert(title: "AX Diagnostic", message: lines.joined(separator: "\n"))
            return
        }
        lines.append("AX windows: \(wins.count)")

        let win = wins[0]

        // 5. Read current position
        var posRef: CFTypeRef?
        var curPos = CGPoint.zero
        if AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
           let pv = posRef, CFGetTypeID(pv) == AXValueGetTypeID() {
            AXValueGetValue(pv as! AXValue, .cgPoint, &curPos)
        }
        lines.append("Current position: (\(Int(curPos.x)), \(Int(curPos.y)))")

        // 6. Try to move it 80px to the right and read back
        let testPos = CGPoint(x: curPos.x + 80, y: curPos.y)
        var tp = testPos
        if let pv = AXValueCreate(.cgPoint, &tp) {
            let setErr = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv)
            lines.append("SetPosition error code: \(setErr.rawValue) \(setErr == .success ? "✅" : "❌")")
        }

        // 7. Read back
        var afterRef: CFTypeRef?
        var afterPos = CGPoint.zero
        if AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &afterRef) == .success,
           let av = afterRef, CFGetTypeID(av) == AXValueGetTypeID() {
            AXValueGetValue(av as! AXValue, .cgPoint, &afterPos)
        }
        lines.append("Position after set: (\(Int(afterPos.x)), \(Int(afterPos.y)))")

        let moved = abs(afterPos.x - testPos.x) < 5
        lines.append(moved ? "✅ AX write WORKED — window moved" : "❌ AX write IGNORED — window did NOT move")

        if moved {
            // Restore original position
            var rp = curPos
            if let pv = AXValueCreate(.cgPoint, &rp) {
                AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv)
            }
        }

        showAlert(title: "AX Diagnostic", message: lines.joined(separator: "\n"))
    }

    private func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    // ── End Diagnostic ───────────────────────────────────────────────────────────

    /// Picks split ratios that honor every app's minimum size and distribute
    /// the remaining space in proportion to each side's needs. A divider the
    /// user dragged themselves is respected (only clamped into the feasible
    /// range); the weighting applies when the ratio is still the default.
    func optimizedRatios(for group: AppGroup, screen: NSScreen) -> (primary: Double, secondary: Double) {
        let entries = group.apps.filter { !($0.isShortcut && $0.shortcutRunMode == .background) }
        var r  = group.effectiveSplitRatio
        var r2 = group.effectiveSplitRatioSecondary
        guard entries.count >= 2 else { return (r, r2) }

        let b = splitRatioBounds(entries: entries, layout: group.layout, screen: screen)
        if b.min < b.max {
            let horizontal: Bool
            switch group.layout {
            case .split1x1, .split1x2, .split2x1, .grid2x2: horizontal = true
            case .split1x1v, .split1x2h:                    horizontal = false
            }
            let v = screen.visibleFrame
            let total = Double(horizontal ? v.width : v.height)

            func need(_ e: AppGroupEntry) -> Double {
                let s = minSlotSize(for: e)
                return Double(horizontal ? s.width : s.height)
            }
            let mainNeed = need(entries[0])
            let sideNeed = entries.dropFirst().map(need).max() ?? 0

            if group.splitRatio == nil, mainNeed > 0 || sideNeed > 0, total > 0 {
                // Untouched divider: give the side column what it needs (plus
                // a small margin) and hand the primary window everything else
                // — never letting the primary dip below its own minimum.
                var target = r
                if sideNeed > 0 { target = 1 - (sideNeed * 1.08) / total }
                if mainNeed > 0 { target = max(target, (mainNeed * 1.02) / total) }
                r = min(max(target, b.min), b.max)
            } else {
                // User-set (or unknown needs): just keep it feasible.
                r = min(max(r, b.min), b.max)
            }
        }
        let b2 = splitRatioBoundsSecondary(entries: entries, layout: group.layout, screen: screen)
        if b2.min < b2.max { r2 = min(max(r2, b2.min), b2.max) }
        return (r, r2)
    }

    func launchAppGroup(id: String) {
        guard var group = appGroups.first(where: { $0.id == id }) else { return }

        // Built for a bigger display? Warn before launching onto a smaller one
        // (e.g. monitor → MacBook Air) so the user isn't surprised by windows
        // that can't fit. They can still proceed.
        if let reason = screenFitProblem(for: group) {
            guard confirmLaunchDespiteScreenFit(name: group.name, reason: reason) else { return }
        }

        // Optimize window proportions for this screen before computing frames.
        let launchScreen = NSScreen.screens.first ?? NSScreen.main!
        let optimized = optimizedRatios(for: group, screen: launchScreen)
        if let idx = appGroups.firstIndex(where: { $0.id == id }) {
            appGroups[idx].splitRatio = optimized.primary
            appGroups[idx].splitRatioSecondary = optimized.secondary
            group = appGroups[idx]
        }

        needsAccessibilityPermission = !AXIsProcessTrusted()
        guard !needsAccessibilityPermission else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(opts as CFDictionary)
            return
        }

        // Only one App Group can be active at a time.
        // Stop every currently running group before launching the new one.
        // We snapshot the keys first because stopAppGroup mutates activeAppGroups.
        let runningGroupIDs = Array(activeAppGroups.keys).filter { $0 != id }
        let isSwitching = !runningGroupIDs.isEmpty
        for runningID in runningGroupIDs {
            stopAppGroup(id: runningID)
        }

        // Split into visible layout entries and background-only shortcuts.
        // Background shortcuts run silently on launch and must not consume a layout slot.
        let slotApps        = group.apps.filter { !($0.isShortcut && $0.shortcutRunMode == .background) }
        let backgroundShortcuts = group.apps.filter { $0.isShortcut && $0.shortcutRunMode == .background }

        let targetScreen   = NSScreen.screens.first ?? NSScreen.main!
        let primaryScreenH = targetScreen.frame.height
        let cgFrames = windowFramesCG(
            for: group.layout,
            appCount: slotApps.count,          // only slot entries count toward the layout
            targetScreen: targetScreen,
            primaryScreenH: primaryScreenH,
            splitRatio: group.effectiveSplitRatio,
            splitRatioSecondary: group.effectiveSplitRatioSecondary
        )

        let primaryIndex = slotApps.firstIndex(where: { $0.id == group.primaryAppID }) ?? 0
        let apps = slotApps

        // Own all apps in the group for stop purposes — this ensures repeated
        // run/stop cycles work correctly even when apps are already running/minimized.
        // Shortcut entries use a virtual path prefix and are excluded from direct ownership;
        // placeShortcutResult will add the actual opened-app path at runtime.
        let groupPaths = Set(apps.compactMap { entry -> String? in
            entry.isShortcut ? nil : entry.path
        })
        // Bundle IDs for the same set — used as a fallback in hideSurroundingApps
        // so path-mismatch edge cases (Chrome installed in ~/Applications, symlinks, etc.)
        // never cause a scene app to be accidentally hidden.
        let groupBundleIDs = Set(apps.compactMap { entry -> String? in
            guard !entry.isShortcut, !entry.bundleID.isEmpty,
                  !entry.bundleID.hasPrefix("/") else { return nil }
            return entry.bundleID
        })

        // Hide Rewindpad's main window immediately when launching a workspace.
        hideOwnNonPanelWindows()

        // Cover the launch shuffle (apps opening, windows snapping into place)
        // with a dark loading shield. It is dismissed explicitly by the settle
        // pass once every window has reached its final size; the duration here
        // is only a safety cap in case an app never produces a window.
        loadingOverlay.show(
            sceneName: group.name,
            icon: group.icon,
            screen: targetScreen,
            duration: (isSwitching ? 0.6 : 0.0) + 12.0
        )

        // Mark this group active immediately so the iPhone tile updates right away
        // (even though the Mac-side launch is slightly deferred when switching).
        activeAppGroups[id] = groupPaths
        activeSlotEntries[id] = slotApps

        // Kill any settle chain surviving from a previous launch of this same
        // group — its clean ticks would dismiss the fresh loading shield
        // immediately on relaunch.
        settleChainTokens[id] = UUID()
        settleCleanStreak[id] = 0

        // Start watching window sizes early so the loading shield can drop
        // the moment every window exists at its final size — fast launches
        // aren't held until the tiling handoff.
        DispatchQueue.main.asyncAfter(deadline: .now() + (isSwitching ? 0.6 : 0.0) + 2.0) { [weak self] in
            self?.startSettleChain(groupID: id)
        }
        broadcastActiveAppGroups()

        // Mint a new placement token for this launch. activateAndPlace loops
        // check their copy of the token on every iteration; if stopAppGroup
        // clears it the loops exit immediately.
        let token = UUID()
        placementTokens[id] = token

        // When switching from a running group, app.terminate() / minimizeAppWindows are
        // OS-level async operations — the stopped apps are still alive and potentially on
        // screen for a moment after stopAppGroup returns. Starting Group B immediately
        // means both sets of apps fight for the workspace during placement. Adding a
        // brief transition delay lets the stopped apps actually leave the screen first.
        let transitionDelay: TimeInterval = isSwitching ? 0.6 : 0.0

        // Step 1: open every app / URL / shortcut so they start loading in parallel.
        DispatchQueue.main.asyncAfter(deadline: .now() + transitionDelay) { [weak self] in
            guard let self, self.placementTokens[id] == token else { return }
            // Slot entries (apps, browser tabs, slot-mode shortcuts)
            for entry in apps {
                if entry.isBrowserTab, let urlString = entry.url,
                   let browserChoice = entry.browser.flatMap({ BrowserChoice(rawValue: $0) }) {
                    self.openOrReuseURLInBrowser(urlString, browser: browserChoice)
                } else if entry.isShortcut, let name = entry.shortcutName {
                    self.runAppleShortcut(name)
                } else {
                    // Launch without activating — the app loads quietly in the
                    // back and only surfaces when placed into its slot, so the
                    // launch shuffle doesn't flash windows to the front.
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = false
                    NSWorkspace.shared.openApplication(
                        at: URL(fileURLWithPath: entry.path),
                        configuration: config
                    )
                }
            }
            // Background shortcuts — run silently, no window placement.
            // We fire them first so they start running before slot apps appear,
            // then schedule a follow-up hideSurroundingApps to push away anything
            // the shortcut briefly activated (e.g. Shortcuts.app, Music, System Settings).
            // The single hide at +0.4s is not enough because the shortcuts CLI is
            // non-blocking — the shortcut's side-effect app may activate AFTER that
            // first hide, leaving it on screen over the new layout.
            for entry in backgroundShortcuts {
                if let name = entry.shortcutName {
                    self.runAppleShortcut(name)
                }
            }
            if !backgroundShortcuts.isEmpty {
                let capturedPaths     = groupPaths
                let capturedBundleIDs = groupBundleIDs
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    guard let self, self.placementTokens[id] == token else { return }
                    self.hideSurroundingApps(keepingPaths: capturedPaths,
                                             keepingBundleIDs: capturedBundleIDs)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                    guard let self, self.placementTokens[id] == token else { return }
                    self.hideSurroundingApps(keepingPaths: capturedPaths,
                                             keepingBundleIDs: capturedBundleIDs)
                }
            }
        }

        // Step 2: shortly after launch, clear the screen — hide Rewindpad and
        // any unrelated foreground apps so the workspace feels focused.
        DispatchQueue.main.asyncAfter(deadline: .now() + transitionDelay + 0.4) { [weak self] in
            guard let self, self.placementTokens[id] == token else { return }
            self.hideSurroundingApps(keepingPaths: groupPaths, keepingBundleIDs: groupBundleIDs)
        }

        let orderedIndices: [Int] = {
            var indices = Array(0..<apps.count)
            if let pi = indices.firstIndex(of: primaryIndex) {
                indices.remove(at: pi)
                indices.append(primaryIndex)
            }
            return indices
        }()

        var delay: TimeInterval = transitionDelay + 1.5
        for idx in orderedIndices {
            let entry = apps[idx]
            let frame = cgFrames[min(idx, cgFrames.count - 1)]
            // Shortcuts need extra time to run and bring an app to the foreground.
            let slotDelay: TimeInterval = entry.isShortcut ? delay + 2.5 : delay
            DispatchQueue.main.asyncAfter(deadline: .now() + slotDelay) { [weak self] in
                guard let self else { return }
                if entry.isShortcut {
                    self.placeShortcutResult(entry: entry, frame: frame,
                                             groupID: id, token: token,
                                             deadline: Date().addingTimeInterval(12))
                } else {
                    self.activateAndPlace(entry: entry, frame: frame,
                                          deadline: Date().addingTimeInterval(15),
                                          groupID: id, token: token)
                }
            }
            delay += 0.05
        }

        // Probe each slot app's true minimum window size while the loading
        // shield still covers the screen — the momentary 1×1 resize used by
        // the probe is invisible behind it, and the placement loops restore
        // Probe min sizes after apps have settled — results are cached permanently.
        DispatchQueue.main.asyncAfter(deadline: .now() + transitionDelay + 1.3) { [weak self] in
            guard let self, self.activeAppGroups[id] != nil else { return }
            let running = NSWorkspace.shared.runningApplications
            for entry in slotApps where !entry.isShortcut {
                guard let app = running.first(where: { $0.bundleIdentifier == entry.bundleID })
                    ?? running.first(where: { $0.bundleURL?.path == entry.path }) else { continue }
                self.probeMinSize(app: app, bundleID: entry.bundleID)
            }
        }

        // Show Switch overlays after apps have had time to be placed.
        // Cancel any previous pending task for this group (handles rapid re-launch).
        pendingOverlayTasks[id]?.cancel()
        let appsSnapshot = apps
        let groupSnapshot = group
        let overlayTask = DispatchWorkItem { [weak self] in
            guard let self, self.activeAppGroups[id] != nil else { return }
            let canAdd = appsSnapshot.count < self.slotCapacity(for: groupSnapshot.layout)
            self.overlayManager.showOverlays(for: id, entries: appsSnapshot, canAdd: canAdd)
            // Stop the activateAndPlace retry loops FIRST — they run for up to
            // 15 s re-asserting the manual frames and would fight the native
            // tiling, snapping windows back out of the tiled group.
            self.placementTokens.removeValue(forKey: id)
            // Windows may have refused their assigned sizes (minimum-size
            // clamping). Re-derive the ratios from what they actually accepted
            // and re-place, so everything tiles edge-to-edge with no gaps or
            // overlaps before native tiling takes over.
            self.startSettleChain(groupID: id)
            // Hand the windows to macOS's native tiling so the system's own
            // draggable divider appears between them.
            self.applyNativeTiling(groupID: id)
            // First-ever scene: tell the user the windows are resizable.
            if !UserDefaults.standard.bool(forKey: "rw_resize_hint_shown") {
                UserDefaults.standard.set(true, forKey: "rw_resize_hint_shown")
                self.sceneToast.show(
                    title:   "Windows are resizable",
                    message: "Hover between two windows and drag the divider.",
                    screen:  NSScreen.screens.first ?? NSScreen.main!
                )
            }
            self.pendingOverlayTasks.removeValue(forKey: id)
            // Showing the panels may cause macOS to resurface our main window briefly.
            // Order it back out immediately so it never appears over the group layout.
            self.hideOwnNonPanelWindows()
        }
        pendingOverlayTasks[id] = overlayTask
        DispatchQueue.main.asyncAfter(deadline: .now() + transitionDelay + 4.0, execute: overlayTask)
    }

    /// Called by the divider overlay when the user drags. Resizes all slot windows live
    /// and saves the new ratios back to the stored AppGroup.
    /// Called every drag frame — resizes windows live, NO disk I/O.
    func applyLiveSplitRatio(_ ratio: Double, secondary: Double?, toGroupID id: String) {
        guard let idx = appGroups.firstIndex(where: { $0.id == id }),
              activeAppGroups[id] != nil else { return }

        // Update in-memory model only — no save here to avoid main-thread disk stalls.
        appGroups[idx].splitRatio = ratio
        if let sec = secondary { appGroups[idx].splitRatioSecondary = sec }

        // During a gesture, hand frames to the off-main pipeline (cheap, never
        // blocks). Outside one (e.g. double-click reset), place synchronously.
        if let session = liveResizeSessions[id] {
            session.submit(sceneFramesCG(for: appGroups[idx]))
        } else {
            resizeWindowsForGroup(appGroups[idx])
        }
    }

    /// CG-coordinate frames for a group's current live slot entries — full
    /// visible frame when only one app remains.
    private func sceneFramesCG(for group: AppGroup) -> [CGRect] {
        let slotApps = liveSlotEntries(for: group)
        let targetScreen  = NSScreen.screens.first ?? NSScreen.main!
        let primaryScreenH = targetScreen.frame.height
        if slotApps.count == 1 {
            let v = targetScreen.visibleFrame
            return [CGRect(x: v.minX, y: primaryScreenH - v.maxY,
                           width: v.width, height: v.height)]
        }
        return windowFramesCG(
            for: group.layout,
            appCount: slotApps.count,
            targetScreen: targetScreen,
            primaryScreenH: primaryScreenH,
            splitRatio: group.effectiveSplitRatio,
            splitRatioSecondary: group.effectiveSplitRatioSecondary
        )
    }

    // MARK: - Native macOS window tiling

    /// Per-slot "Move & Resize" menu commands for a layout. Each slot gets a
    /// list of title variants (menu wording differs slightly across macOS
    /// versions); the first one that exists in the app's menu is pressed.
    private func nativeTileCommands(for layout: AppGroupLayout, count: Int) -> [[String]] {
        // macOS 15 Sequoia adds "Tile Window to X of Screen" at the top level of
        // the Window menu. These are the commands that create the native tiling
        // pair (and the draggable divider). The older "Move & Resize → Left Half"
        // items merely reposition the window without creating a tiling relationship.
        // Always try the Sequoia tile commands first; fall back for older macOS.
        let L  = ["Tile Window to Left of Screen",        "Left",         "Left Half"]
        let R  = ["Tile Window to Right of Screen",       "Right",        "Right Half"]
        let T  = ["Tile Window to Top of Screen",         "Top",          "Top Half"]
        let B  = ["Tile Window to Bottom of Screen",      "Bottom",       "Bottom Half"]
        let TL = ["Tile Window to Top Left Corner",       "Top Left",     "Top Left Quarter"]
        let TR = ["Tile Window to Top Right Corner",      "Top Right",    "Top Right Quarter"]
        let BL = ["Tile Window to Bottom Left Corner",    "Bottom Left",  "Bottom Left Quarter"]
        let BR = ["Tile Window to Bottom Right Corner",   "Bottom Right", "Bottom Right Quarter"]

        guard count > 1 else { return [["Fill", "Fill Screen"]] }

        switch layout {
        case .split1x1:  return [L, R]
        case .split1x1v: return [T, B]
        case .split1x2:  return count > 2 ? [L, TR, BR] : [L, R]
        case .split2x1:  return count > 2 ? [R, TL, BL] : [R, L]
        case .split1x2h: return count > 2 ? [T, BL, BR] : [T, B]
        case .grid2x2:   return Array([TL, TR, BL, BR].prefix(count))
        }
    }

    /// Presses one of `titles` inside the app's Window → Move & Resize submenu
    /// via Accessibility. Returns true when a matching item was pressed.
    @discardableResult
    private func pressMoveResizeMenuItem(app: NSRunningApplication, titles: [String]) -> Bool {
        let name  = app.localizedName ?? app.bundleIdentifier ?? "?"
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // AX returns CFArray which must be walked as NSArray — casting directly
        // to [AXUIElement] can silently fail on some bridge configurations.
        func children(_ el: AXUIElement) -> [AXUIElement] {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success,
                  let arr = ref as? NSArray else { return [] }
            return arr.compactMap { $0 as! AXUIElement }
        }
        func title(_ el: AXUIElement) -> String {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &ref) == .success
            else { return "" }
            return (ref as? String) ?? ""
        }
        func press(_ item: AXUIElement) -> Bool {
            AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        }

        // Strategy 1 — navigate Window → Move & Resize → <tile item>
        var mbRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &mbRef) == .success,
           let mb = mbRef {
            let menuBar = mb as! AXUIElement
            let topItems = children(menuBar)
            NSLog("[Rewindpad] %@ menu bar has %d top-level items", name, topItems.count)

            // Find the Window menu — try exact match first, then find by content
            // (the menu that contains "Minimize" or "Close").
            let windowItem = topItems.first { title($0) == "Window" }
                ?? topItems.first { item in
                    guard let menu = children(item).first else { return false }
                    return children(menu).contains { ["Minimize", "Close", "Zoom"].contains(title($0)) }
                }

            if let winItem = windowItem,
               let windowMenu = children(winItem).first {
                let windowItems = children(windowMenu)
                NSLog("[Rewindpad] %@ Window menu has %d items", name, windowItems.count)

                // Recursively search the Window menu and its submenus for a
                // matching tile item so we handle any submenu nesting depth.
                func findAndPress(in items: [AXUIElement], depth: Int) -> Bool {
                    guard depth < 3 else { return false }
                    for item in items {
                        let t = title(item)
                        if titles.contains(t) {
                            NSLog("[Rewindpad] %@ pressing '%@' (depth %d)", name, t, depth)
                            return press(item)
                        }
                        // Recurse into submenus (move-resize submenu lives 1 level deep)
                        if findAndPress(in: children(item), depth: depth + 1) { return true }
                    }
                    return false
                }

                if findAndPress(in: windowItems, depth: 0) { return true }
                NSLog("[Rewindpad] %@ tile items %@ not found in Window menu", name, titles)
            } else {
                NSLog("[Rewindpad] %@ Window menu not found; top items: %@",
                      name, topItems.map(title).joined(separator: ", "))
            }
        } else {
            NSLog("[Rewindpad] %@ menu bar not accessible", name)
        }

        // Strategy 2 — try undocumented window-level tile actions that some
        // Sequoia builds expose directly on the AXWindow element.
        if let win = getAXWindow(for: app) {
            for action in ["AXTileLeft", "AXTileWindowLeft", "AXMoveToLeftHalf",
                           "AXTileWindowToLeft", "AXSnapLeft"] {
                if AXUIElementPerformAction(win, action as CFString) == .success {
                    NSLog("[Rewindpad] %@ tiled via direct action '%@'", name, action)
                    return true
                }
            }
        }

        NSLog("[Rewindpad] %@ all tile strategies failed for %@", name, titles)
        return false
    }

    /// Per-group AX resize watchers that tick the trackpad when the native
    /// divider pins a window at its minimum size.
    private var minSizeWatchers: [String: [MinSizeWatcher]] = [:]

    /// Toast shown when two slot apps' minimum sizes can't coexist on screen.
    private let sceneToast = SceneToastPanel()

    /// Warns when two apps sharing an axis need more combined minimum space
    /// than the screen offers — their sizes will conflict no matter where the
    /// divider sits. Uses the same collapsed-bounds condition as the resize
    /// limits, so the toast and the red glow always agree.
    /// Returns the names of two apps whose minimum sizes cannot coexist in
    /// this entry line-up, or nil when every divider position can satisfy all
    /// minimums. Shared by the launch-time toast and the add-app guard.
    func conflictPair(entries: [AppGroupEntry], layout: AppGroupLayout,
                      screen: NSScreen) -> (String, String)? {
        guard entries.count >= 2 else { return nil }

        let b = splitRatioBounds(entries: entries, layout: layout, screen: screen)
        if b.min >= b.max {
            return (entries[0].appName, entries[1].appName)
        }
        if entries.count >= 3 {
            let b2 = splitRatioBoundsSecondary(entries: entries, layout: layout, screen: screen)
            if b2.min >= b2.max {
                return (entries[1].appName, entries[2].appName)
            }
        }
        return nil
    }

    /// Checks whether a stored workspace can physically fit the CURRENT screen.
    /// A workspace built on a large monitor may not fit a smaller built-in
    /// display (e.g. a MacBook Air). Returns a human reason when it won't fit,
    /// or nil when it's fine. Uses the best known minimum sizes — no launching.
    func screenFitProblem(for group: AppGroup) -> String? {
        let screen = NSScreen.screens.first ?? NSScreen.main!
        let entries = liveSlotEntries(for: group)
        guard entries.count >= 2 else { return nil }
        guard let (a, b) = conflictPair(entries: entries, layout: group.layout, screen: screen) else {
            return nil   // fits on this screen
        }

        let v = screen.visibleFrame
        let horizontal: Bool
        switch group.layout {
        case .split1x1, .split1x2, .split2x1, .grid2x2: horizontal = true
        case .split1x1v, .split1x2h:                    horizontal = false
        }
        let dimWord  = horizontal ? "wider" : "taller"
        let available = Int((horizontal ? v.width : v.height).rounded())

        // What the tighter pair actually needs along the split axis.
        func need(_ name: String) -> Int {
            guard let e = entries.first(where: { $0.appName == name }) else { return 0 }
            let s = minSlotSize(for: e)
            return Int((horizontal ? s.width : s.height).rounded())
        }
        let needA = need(a), needB = need(b)
        let combined = needA + needB

        var reason = "“\(a)” and “\(b)” need a \(dimWord) window than this display can give them. "
        if combined > 0 {
            reason += "Together they need about \(combined) pt, but \(screen.localizedName) only has \(available) pt of usable space. "
        }
        reason += "This Workspace was set up for a larger display."
        return reason
    }

    /// Blocking warning shown when a workspace won't fit the current screen.
    /// Returns true if the user chose to launch anyway.
    private func confirmLaunchDespiteScreenFit(name: String, reason: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(name)” may not fit this screen"
        alert.informativeText = reason
        alert.addButton(withTitle: "Launch Anyway")
        alert.addButton(withTitle: "Cancel")
        // Make Cancel respond to Escape; Launch Anyway stays the default (Return).
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func checkMinSizeConflicts(groupID: String) {
        guard let group = appGroups.first(where: { $0.id == groupID }),
              activeAppGroups[groupID] != nil else { return }
        let screen = NSScreen.screens.first ?? NSScreen.main!

        guard let (a, c) = conflictPair(entries: liveSlotEntries(for: group),
                                        layout: group.layout, screen: screen) else { return }
        sceneToast.show(
            title:   "Window sizes conflict",
            message: "\(a) and \(c) need more space than fits on this screen.",
            screen:  screen
        )
    }

    private func attachMinSizeWatchers(groupID: String) {
        detachMinSizeWatchers(groupID: groupID)
        guard let group = appGroups.first(where: { $0.id == groupID }),
              activeAppGroups[groupID] != nil else { return }

        let running = NSWorkspace.shared.runningApplications
        var watchers: [MinSizeWatcher] = []
        for entry in liveSlotEntries(for: group) {
            guard let app = running.first(where: { $0.bundleIdentifier == entry.bundleID })
                ?? running.first(where: { $0.bundleURL?.path == entry.path }),
                  let win = getAXWindow(for: app) else { continue }
            let minSize = minSlotSize(for: entry)
            if let w = MinSizeWatcher.attach(pid: app.processIdentifier,
                                             window: win, minSize: minSize) {
                // Subtle haptic when the user starts dragging the native
                // divider (debounced so a continuous drag taps only once).
                w.onDrag = { [weak self] in
                    self?.dividerDragHaptic(for: groupID)
                }
                watchers.append(w)
            }
        }
        minSizeWatchers[groupID] = watchers
    }

    private var lastDividerHaptic: [String: Date] = [:]

    /// One gentle alignment tap when a divider drag begins; re-arms after a
    /// second of no drag events so a continuous drag doesn't buzz.
    private func dividerDragHaptic(for groupID: String) {
        let now = Date()
        if let last = lastDividerHaptic[groupID], now.timeIntervalSince(last) < 1.0 {
            lastDividerHaptic[groupID] = now
            return
        }
        lastDividerHaptic[groupID] = now
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func detachMinSizeWatchers(groupID: String) {
        minSizeWatchers[groupID]?.forEach { $0.detach() }
        minSizeWatchers.removeValue(forKey: groupID)
    }

    /// Tiles a running scene's windows with macOS's native window tiling, so
    /// the system shows its own draggable divider between them. Presses are
    /// staggered to let each tiling animation land before the next begins.
    func applyNativeTiling(groupID: String) {
        guard let group = appGroups.first(where: { $0.id == groupID }),
              activeAppGroups[groupID] != nil else { return }

        let slots    = liveSlotEntries(for: group)
        let commands = nativeTileCommands(for: group.layout, count: slots.count)
        let running  = NSWorkspace.shared.runningApplications

        // macOS only enters the tiling relationship (and shows the native
        // draggable divider) when the tile command is pressed while that app
        // is the active frontmost application. We activate each app briefly
        // right before its press, then restore focus to the last app so the
        // workspace feels natural. Stagger is 0.6 s to give activation time
        // to settle before the AX press fires.
        let previousFront = NSWorkspace.shared.frontmostApplication
        var delay: TimeInterval = 0
        for (i, entry) in slots.enumerated() {
            guard i < commands.count else { break }
            guard let app = running.first(where: { $0.bundleIdentifier == entry.bundleID })
                ?? running.first(where: { $0.bundleURL?.path == entry.path }) else { continue }
            let titles = commands[i]
            let isLast = i == min(slots.count, commands.count) - 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.activeAppGroups[groupID] != nil else { return }
                // Bring this app to front so macOS registers the tile in its
                // tiling group, which is what creates the draggable divider.
                app.activate(options: .activateIgnoringOtherApps)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
                    guard let self, self.activeAppGroups[groupID] != nil else { return }
                    if self.pressMoveResizeMenuItem(app: app, titles: titles) {
                        NSHapticFeedbackManager.defaultPerformer
                            .perform(.alignment, performanceTime: .now)
                    }
                    // After the last tile, restore focus to whatever was front
                    // before (or fall back to the last-tiled app).
                    if isLast {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            (previousFront ?? app).activate(options: .activateIgnoringOtherApps)
                        }
                    }
                }
            }
            delay += 0.8
        }

        // Once the tiling animations have settled, start watching for
        // min-size pins (haptic feedback). The native macOS tiling divider is
        // the only divider shown — no overlay hint.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.6) { [weak self] in
            guard let self, self.appGroups.contains(where: { $0.id == groupID }),
                  self.activeAppGroups[groupID] != nil else { return }
            self.attachMinSizeWatchers(groupID: groupID)
            self.checkMinSizeConflicts(groupID: groupID)
        }
    }

    /// Called when a divider drag/scrub begins. Resolves every slot window's
    /// AXUIElement and minimum size ONCE and spins up the off-main resize
    /// pipeline; also disables AXEnhancedUserInterface (which makes AX window
    /// moves animated and slow) on the affected apps for the gesture's duration.
    func beginLiveSplitDrag(forGroupID id: String) {
        lastAppliedFrames.removeValue(forKey: id)
        guard let group = appGroups.first(where: { $0.id == id }) else { return }

        let slotApps = liveSlotEntries(for: group)
        let running  = NSWorkspace.shared.runningApplications
        var slots: [LiveResizeSession.SlotWindow] = []

        for entry in slotApps {
            let app = running.first { $0.bundleIdentifier == entry.bundleID }
                ?? running.first { $0.bundleURL?.path == entry.path }
            guard let app, let win = getAXWindow(for: app) else {
                slots.append(.init(win: nil, minSize: .zero, lastFrame: nil))
                continue
            }

            // Turn off assistive move-animation for buttery live resizes.
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var prev: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, &prev) == .success,
               (prev as? Bool) == true {
                AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
                enhancedUIRestorePIDs.append(app.processIdentifier)
            }

            slots.append(.init(win: win, minSize: axMinWindowSize(for: win), lastFrame: nil))
        }

        liveResizeSessions[id] = LiveResizeSession(windows: slots)
    }

    /// Tears down the live-resize pipeline: restores AXEnhancedUserInterface and
    /// runs one authoritative synchronous placement pass so the final state is exact.
    private func endLiveSplitDrag(forGroupID id: String) {
        liveResizeSessions.removeValue(forKey: id)

        for pid in enhancedUIRestorePIDs {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        enhancedUIRestorePIDs.removeAll()

        if let group = appGroups.first(where: { $0.id == id }) {
            lastAppliedFrames.removeValue(forKey: id)
            resizeWindowsForGroup(group)
        }
    }

    /// Called once when drag ends — persists the final ratios to disk.
    func saveSplitRatio(forGroupID id: String) {
        endLiveSplitDrag(forGroupID: id)
        guard appGroups.contains(where: { $0.id == id }) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            AppGroupStore.save(self.appGroups)
        }
    }

    /// Frames most recently applied per group during live divider drags — lets us
    /// skip AX calls for windows whose frame didn't change (e.g. the main window
    /// while only the secondary divider moves).
    private var lastAppliedFrames: [String: [CGRect]] = [:]

    /// Active off-main-thread resize pipelines, one per dragging group.
    private var liveResizeSessions: [String: LiveResizeSession] = [:]
    /// Apps whose AXEnhancedUserInterface we disabled for the drag (it makes
    /// AX window moves animated/slow); restored when the drag ends.
    private var enhancedUIRestorePIDs: [pid_t] = []

    /// Live slot entries per active session — reflects +/− edits made from the
    /// overlay buttons without mutating the saved scene definition.
    var activeSlotEntries: [String: [AppGroupEntry]] = [:]

    /// Max number of visible slots a layout can host.
    func slotCapacity(for layout: AppGroupLayout) -> Int {
        switch layout {
        case .split1x1, .split1x1v: return 2
        case .split1x2, .split2x1, .split1x2h: return 3
        case .grid2x2: return 4
        }
    }

    /// The slot entries currently shown for a group — session edits first,
    /// falling back to the stored definition when the group isn't running.
    func liveSlotEntries(for group: AppGroup) -> [AppGroupEntry] {
        activeSlotEntries[group.id]
            ?? group.apps.filter { !($0.isShortcut && $0.shortcutRunMode == .background) }
    }

    /// Removes one slot from a running scene and expands the remaining windows.
    func removeSlotApp(groupID: String, entryID: String) {
        guard let group = appGroups.first(where: { $0.id == groupID }),
              activeAppGroups[groupID] != nil else { return }
        var entries = liveSlotEntries(for: group)
        guard let idx = entries.firstIndex(where: { $0.id == entryID }) else { return }
        let removed = entries.remove(at: idx)
        activeSlotEntries[groupID] = entries

        // Hide the removed app and drop it from session ownership so stopping
        // the scene later doesn't quit an app the user explicitly took out.
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.path == removed.path
        }) { app.hide() }
        activeAppGroups[groupID]?.remove(removed.path)

        guard !entries.isEmpty else { stopAppGroup(id: groupID); return }
        relayoutActiveScene(groupID: groupID, group: group)
    }

    /// Adds an app into a running scene, shrinking existing windows to make room.
    /// Refused (with a toast explaining why) when the new app's minimum size
    /// cannot coexist with the current apps on this screen.
    func addSlotApp(groupID: String, newEntry: AppGroupEntry) {
        guard let group = appGroups.first(where: { $0.id == groupID }),
              activeAppGroups[groupID] != nil else { return }
        var entries = liveSlotEntries(for: group)
        guard entries.count < slotCapacity(for: group.layout) else { return }
        entries.append(newEntry)

        // The + menu only lists running apps — measure the candidate's true
        // minimum right now so the validation below uses the enforced value,
        // not a missing/lying AXMinSize.
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == newEntry.bundleID
        }) ?? NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.path == newEntry.path
        }) {
            probeMinSize(app: app, bundleID: newEntry.bundleID)
        }

        // Validate the hypothetical line-up BEFORE committing anything: if no
        // divider position can satisfy every app's minimum size, block the add.
        let screen = NSScreen.screens.first ?? NSScreen.main!
        if let (a, c) = conflictPair(entries: entries, layout: group.layout, screen: screen) {
            NSHapticFeedbackManager.defaultPerformer
                .perform(.levelChange, performanceTime: .now)
            sceneToast.show(
                title:   "Can’t add \(newEntry.appName)",
                message: "\(a) and \(c) need more space than fits on this screen.",
                screen:  screen
            )
            return
        }

        activeSlotEntries[groupID] = entries
        activeAppGroups[groupID]?.insert(newEntry.path)

        relayoutActiveScene(groupID: groupID, group: group)

        // Open the new app (it may not be running yet) and place it in its slot.
        // Re-fetch the group: relayoutActiveScene may have clamped the ratios to
        // honour the new app's minimum size, and the frame must match.
        let placed = appGroups.first(where: { $0.id == groupID }) ?? group
        let targetScreen = NSScreen.screens.first ?? NSScreen.main!
        let frames = windowFramesCG(
            for: placed.layout,
            appCount: entries.count,
            targetScreen: targetScreen,
            primaryScreenH: targetScreen.frame.height,
            splitRatio: placed.effectiveSplitRatio,
            splitRatioSecondary: placed.effectiveSplitRatioSecondary
        )
        guard entries.count - 1 < frames.count else { return }
        let frame = frames[entries.count - 1]
        NSWorkspace.shared.open(URL(fileURLWithPath: newEntry.path))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.placeAppInFrame(entry: newEntry, frame: frame, groupID: groupID)
        }
        // The relayout's tiling pass ran before the new app launched and
        // skipped it — re-tile once the window exists so it joins the group.
        // Cancel the placement retry loop first so it can't fight the tiling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.placementTokens.removeValue(forKey: groupID)
            self?.applyNativeTiling(groupID: groupID)
        }
    }

    /// Post-launch settle pass: apps clamp windows to their own minimum sizes,
    /// which can leave a gap on one side and an overlap on the other. Read the
    /// windows' ACTUAL accepted sizes, re-derive the split ratios from reality,
    /// and re-place everything so the layout tiles the screen exactly.
    private var settleChainTokens: [String: UUID] = [:]
    private var settleCleanStreak: [String: Int] = [:]

    /// Starts (or restarts) the settle chain for a scene. Rotating the token
    /// kills any previous chain so launches never stack duplicate monitors.
    func startSettleChain(groupID: String) {
        let token = UUID()
        settleChainTokens[groupID] = token
        settleSceneProportions(groupID: groupID, pass: 0, token: token)
    }

    private func settleSceneProportions(groupID: String, pass: Int = 0, token: UUID? = nil) {
        if let token, settleChainTokens[groupID] != token { return }
        guard let idx = appGroups.firstIndex(where: { $0.id == groupID }),
              activeAppGroups[groupID] != nil else { return }

        // Never fight the user's own drag — skip this tick entirely.
        guard NSEvent.pressedMouseButtons == 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.settleSceneProportions(groupID: groupID, pass: pass, token: token)
            }
            return
        }
        let group = appGroups[idx]
        let screen = NSScreen.screens.first ?? NSScreen.main!
        let v = screen.visibleFrame
        let entries = liveSlotEntries(for: group)
        guard entries.count >= 2, v.width > 0, v.height > 0 else { return }

        func actualSize(_ entry: AppGroupEntry) -> CGSize? {
            let running = NSWorkspace.shared.runningApplications
            let app = running.first { $0.bundleIdentifier == entry.bundleID }
                ?? running.first { $0.bundleURL?.path == entry.path }
            guard let app, let win = getAXWindow(for: app) else { return nil }
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &ref) == .success,
                  let val = ref, CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
            var size = CGSize.zero
            AXValueGetValue(val as! AXValue, .cgSize, &size)
            return size
        }

        let horizontal: Bool
        switch group.layout {
        case .split1x1, .split1x2, .split2x1, .grid2x2: horizontal = true
        case .split1x1v, .split1x2h:                    horizontal = false
        }
        let totalP = Double(horizontal ? v.width : v.height)
        func primaryAxis(_ s: CGSize) -> Double { Double(horizontal ? s.width : s.height) }

        let assigned = sceneFramesCG(for: group)
        var changed = false

        // ── Primary divider ─────────────────────────────────────────────
        // A window that refused its assigned size is sitting at its own
        // minimum and would overlap its neighbor (or leave a gap). Pick the
        // ratio that honors whichever window refused.
        // Windows that drifted from their slot (smaller, or moved) didn't hit
        // a minimum — they restored their own previous frame (Maps does this
        // at an unpredictable moment after launch). Push them back into their
        // slot; the divider must not follow them.
        var anyDrift = false
        var allWindowsPresent = true
        let running = NSWorkspace.shared.runningApplications
        for (i, entry) in entries.enumerated() where assigned.indices.contains(i) {
            let app = running.first { $0.bundleIdentifier == entry.bundleID }
                ?? running.first { $0.bundleURL?.path == entry.path }
            guard let app, let win = getAXWindow(for: app) else {
                allWindowsPresent = false
                continue
            }

            var posRef: CFTypeRef?, sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let pv = posRef, CFGetTypeID(pv) == AXValueGetTypeID(),
                  let sv = sizeRef, CFGetTypeID(sv) == AXValueGetTypeID() else { continue }
            var pos = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
            AXValueGetValue(sv as! AXValue, .cgSize, &size)

            let drifted = abs(pos.x - assigned[i].minX) > 2
                || abs(pos.y - assigned[i].minY) > 2
                || primaryAxis(size) < primaryAxis(assigned[i].size) - 2
            if drifted {
                anyDrift = true
                placeWindow(app: app, frame: assigned[i])
            }
        }

        // Ratio corrections only happen in the early passes; the long-running
        // guard below is purely a position/size enforcer.
        if pass < 3, let s0 = actualSize(entries[0]), assigned.indices.contains(0) {
            let want0 = primaryAxis(CGSize(width: assigned[0].width, height: assigned[0].height))
            let got0  = primaryAxis(s0)
            // Refusal = the window is LARGER than asked (sitting at its min).
            let primaryRefused = got0 > want0 + 2

            var sideRefused = false
            var got1: Double = 0
            if entries.count >= 2, let s1 = actualSize(entries[1]), assigned.indices.contains(1) {
                let want1 = primaryAxis(CGSize(width: assigned[1].width, height: assigned[1].height))
                got1 = primaryAxis(s1)
                sideRefused = got1 > want1 + 2
            }

            var target: Double? = nil
            if primaryRefused && sideRefused {
                // Both at their floors — only feasible if they fit together.
                if got0 + got1 <= totalP + 2 { target = got0 / totalP }
            } else if primaryRefused {
                target = got0 / totalP            // side absorbs the difference
            } else if sideRefused {
                target = 1 - (got1 / totalP)      // primary absorbs the difference
            }

            // Only correct when the seam is meaningfully off (> 8 pt) — small
            // rounding noise must never trigger another visible resize.
            if let target, target > 0.05, target < 0.95,
               abs(target - group.effectiveSplitRatio) * totalP > 8 {
                appGroups[idx].splitRatio = target
                changed = true
            }
        }

        // ── Secondary divider (stacked side column / bottom row) ────────
        // Same rule: only follow a window that came out LARGER than asked.
        if entries.count >= 3, let s1 = actualSize(entries[1]), assigned.indices.contains(1) {
            let got: Double
            let want: Double
            let span: Double
            switch group.layout {
            case .split1x2, .split2x1, .grid2x2:
                got = Double(s1.height); want = Double(assigned[1].height); span = Double(v.height)
            case .split1x2h:
                got = Double(s1.width);  want = Double(assigned[1].width);  span = Double(v.width)
            default:
                got = 0; want = 0; span = 1
            }
            let achieved = got / span
            if got > want + 2, achieved > 0.05, achieved < 0.95,
               abs(achieved - group.effectiveSplitRatioSecondary) * span > 8 {
                appGroups[idx].splitRatioSecondary = achieved
                changed = true
            }
        }

        if changed {
            // resizeWindowsForGroup compares against the last applied frames
            // and skips windows whose target didn't move — windows that are
            // already right keep their size untouched.
            resizeWindowsForGroup(appGroups[idx])
        }

        // Drop the launch loading shield only after TWO consecutive clean
        // checks — one clean read can be a transient state while apps are
        // still loading. (No-op when the shield is already gone.)
        if allWindowsPresent && !anyDrift && !changed {
            settleCleanStreak[groupID, default: 0] += 1
            if settleCleanStreak[groupID, default: 0] >= 2 {
                loadingOverlay.dismiss()
            }
        } else {
            settleCleanStreak[groupID] = 0
        }

        // Guard for the scene's whole lifetime: apps like Maps restore their
        // previous session's frame at an unpredictable moment after launch.
        // Each tick is read-only unless a window actually drifted, and the
        // chain ends itself when the scene stops (the activity guard above).
        let interval: TimeInterval = pass < 4 ? 1.5 : 3.0
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.settleSceneProportions(groupID: groupID, pass: pass + 1, token: token)
        }
    }

    /// Re-places all windows of a running scene to match the current live slot
    /// entries, then refreshes the overlay buttons and dividers.
    /// The split ratios are clamped into the apps' min-size bounds first, so a
    /// newly added app with a large minimum width gets the space it needs
    /// instead of a blind half-and-half split.
    private func relayoutActiveScene(groupID: String, group: AppGroup) {
        let screen = NSScreen.screens.first ?? NSScreen.main!
        var grp = group

        if let idx = appGroups.firstIndex(where: { $0.id == groupID }) {
            let b = splitRatioBounds(for: appGroups[idx], screen: screen)
            if b.min < b.max {
                let clamped = min(max(appGroups[idx].effectiveSplitRatio, b.min), b.max)
                appGroups[idx].splitRatio = clamped
            }
            let b2 = splitRatioBoundsSecondary(for: appGroups[idx], screen: screen)
            if b2.min < b2.max {
                let clamped2 = min(max(appGroups[idx].effectiveSplitRatioSecondary, b2.min), b2.max)
                appGroups[idx].splitRatioSecondary = clamped2
            }
            grp = appGroups[idx]
        }

        lastAppliedFrames.removeValue(forKey: groupID)
        resizeWindowsForGroup(grp)
        let entries = liveSlotEntries(for: grp)
        let canAdd  = entries.count < slotCapacity(for: grp.layout)
        overlayManager.removeOverlays(for: groupID)
        overlayManager.showOverlays(for: groupID, entries: entries, canAdd: canAdd)
        // Re-tile natively for the new slot count so the system divider reappears.
        applyNativeTiling(groupID: groupID)
    }

    private func resizeWindowsForGroup(_ group: AppGroup) {
        let slotApps = liveSlotEntries(for: group)
        let frames   = sceneFramesCG(for: group)

        let previous = lastAppliedFrames[group.id]
        lastAppliedFrames[group.id] = frames

        let running = NSWorkspace.shared.runningApplications
        for (i, entry) in slotApps.enumerated() {
            guard i < frames.count else { break }
            // Unchanged since the last drag tick — skip the AX round-trip.
            if let previous, i < previous.count, previous[i] == frames[i] { continue }
            // Match by bundle ID first, then path — same logic as runningApp(for:)
            let app = running.first(where: {
                guard let bid = $0.bundleIdentifier else { return false }
                return bid == entry.bundleID
            }) ?? running.first(where: { $0.bundleURL?.path == entry.path })
            guard let app else { continue }
            placeWindow(app: app, frame: frames[i])
        }
    }

    func stopAppGroup(id: String) {
        guard let ownedPaths = activeAppGroups[id] else { return }
        let group = appGroups.first(where: { $0.id == id })
        let behavior = group?.stopBehavior ?? .quit

        // Cancel the pending overlay-show task and any in-flight placement loops.
        pendingOverlayTasks[id]?.cancel()
        pendingOverlayTasks.removeValue(forKey: id)
        placementTokens.removeValue(forKey: id)
        overlayManager.removeOverlays(for: id)
        dividerManager.removeDividers(for: id)
        lastAppliedFrames.removeValue(forKey: id)
        liveResizeSessions.removeValue(forKey: id)
        activeSlotEntries.removeValue(forKey: id)
        detachMinSizeWatchers(groupID: id)
        sceneToast.dismiss()
        loadingOverlay.dismiss()

        let running = NSWorkspace.shared.runningApplications
        for path in ownedPaths {
            guard let app = running.first(where: { $0.bundleURL?.path == path }) else { continue }
            switch behavior {
            case .quit:
                app.terminate()
            case .minimize:
                minimizeAppWindows(app: app)
            }
        }

        activeAppGroups.removeValue(forKey: id)
        broadcastActiveAppGroups()
    }

    /// Miniaturizes all visible windows of an app via the Accessibility API,
    /// falling back to AppleScript for apps that block AX.
    private func minimizeAppWindows(app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            // AX blocked — use AppleScript fallback
            let pid = app.processIdentifier
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let src = """
                tell application "System Events"
                    set proc to first process whose unix id is \(pid)
                    repeat with w in windows of proc
                        set miniaturized of w to true
                    end repeat
                end tell
                """
                _ = self?.runAppleScriptSync(src)
            }
            return
        }
        for win in windows {
            AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, true as CFTypeRef)
        }
    }

    /// Hides Rewindpad and every foreground app whose path is not in `keepingPaths`.
    /// Called shortly after an App Group launches to give the group a clean workspace.
    private func hideSurroundingApps(keepingPaths: Set<String>, keepingBundleIDs: Set<String> = []) {
        let running = NSWorkspace.shared.runningApplications

        for app in running {
            // Only touch regular (visible) apps — skip agents, daemons, etc.
            guard app.activationPolicy == .regular else { continue }
            // Skip already-hidden apps.
            guard !app.isHidden else { continue }
            // Never hide the App Group's own apps — match by path OR bundle ID so
            // Chrome/Safari installed in non-standard locations are still recognised.
            if let path = app.bundleURL?.path, keepingPaths.contains(path) { continue }
            if let bid = app.bundleIdentifier, keepingBundleIDs.contains(bid) { continue }
            // Hide everything else (including Rewindpad if it happens to match).
            app.hide()
        }

        // Hide Rewindpad's own non-panel windows by ordering them out individually.
        // We intentionally avoid NSApp.hide(nil) here because hiding the whole app at
        // the OS level causes macOS to automatically *unhide* it the moment any NSPanel
        // owned by this process appears (e.g. the Switch overlay buttons at t=4s).
        // Ordering individual windows out does not set the app-hidden flag, so panels
        // can be shown later without pulling back the Rewindpad main window.
        for window in NSApp.windows where !(window is NSPanel) {
            if window.isVisible { window.orderOut(nil) }
        }
    }

    /// Orders out all non-panel windows of this app without touching the OS-level
    /// app-hidden flag. Call this after showing overlay panels to ensure the Rewindpad
    /// main window stays off-screen even if macOS briefly resurfaces it.
    private func hideOwnNonPanelWindows() {
        for window in NSApp.windows where !(window is NSPanel) {
            if window.isVisible { window.orderOut(nil) }
        }
    }

    /// Called by the overlay manager to move a replacement app into an existing layout slot.
    /// Place `entry` into `frame`. When called from a slot-switch the caller must pass
    /// `groupID` so the placement loop is tied to the group's placement token and will
    /// stop immediately if `stopAppGroup` is called (same guarantee as the initial launch).
    func placeAppInFrame(entry: AppGroupEntry, frame: CGRect, groupID: String = "") {
        let token = groupID.isEmpty ? UUID() : (placementTokens[groupID] ?? UUID())
        activateAndPlace(entry: entry, frame: frame, deadline: Date().addingTimeInterval(12),
                         groupID: groupID, token: token)
    }

    /// Best-effort window placement for a shortcut slot.
    /// Waits until a suitable foreground app appears (brought up by the shortcut),
    /// then places its window in `frame`. One-shot — no retry after deadline.
    private func placeShortcutResult(entry: AppGroupEntry, frame: CGRect,
                                      groupID: String, token: UUID, deadline: Date) {
        guard Date() < deadline else { return }
        if !groupID.isEmpty, placementTokens[groupID] != token { return }

        let selfBundleID = Bundle.main.bundleIdentifier ?? "com.ibrahimsafel.RewindpadMac"
        let ignoreIDs: Set<String> = [selfBundleID, "com.apple.shortcuts"]

        let running = NSWorkspace.shared.runningApplications
        let candidates = running.filter {
            $0.activationPolicy == .regular &&
            !ignoreIDs.contains($0.bundleIdentifier ?? "")
        }

        // Prefer whichever candidate is currently frontmost.
        let target: NSRunningApplication?
        if let front = NSWorkspace.shared.frontmostApplication,
           candidates.contains(where: { $0.processIdentifier == front.processIdentifier }) {
            target = front
        } else {
            target = candidates.first
        }

        guard let target, let targetPath = target.bundleURL?.path else {
            // Nothing usable yet — retry in 0.3s
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.placeShortcutResult(entry: entry, frame: frame,
                                          groupID: groupID, token: token, deadline: deadline)
            }
            return
        }

        // Claim this app into the group so stopAppGroup will manage it.
        activeAppGroups[groupID]?.insert(targetPath)

        let syntheticEntry = AppGroupEntry(
            id: entry.id,
            appName: target.localizedName ?? entry.appName,
            bundleID: target.bundleIdentifier ?? "",
            path: targetPath
        )
        activateAndPlace(entry: syntheticEntry, frame: frame,
                         deadline: Date().addingTimeInterval(12),
                         groupID: groupID, token: token)
    }

    /// Called by the overlay manager when the user switches one app for another in a slot.
    /// Updates the active group's owned-path set so that stopAppGroup controls the correct apps:
    /// the switched-in app is added, the swapped-out app is removed.
    func switchSlotApp(in groupID: String, oldPath: String, newPath: String) {
        guard activeAppGroups[groupID] != nil else { return }
        activeAppGroups[groupID]?.remove(oldPath)
        activeAppGroups[groupID]?.insert(newPath)
    }

    private func updateLocalSystemLoad() {
        let payload = SystemLoadPayload(cpu: currentCPULoad(), memory: currentMemoryUsage())
        DispatchQueue.main.async { self.localSystemLoad = payload }
    }

    private func sendSystemLoad(to connection: NWConnection) {
        let payload = SystemLoadPayload(cpu: currentCPULoad(), memory: currentMemoryUsage())
        DispatchQueue.main.async { self.localSystemLoad = payload }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        sendServerMessage(ServerMessage(type: "systemLoad", data: data), to: connection)
    }

    /// 1-minute load average normalised by logical CPU count, clamped to [0, 1].
    private func currentCPULoad() -> Double {
        var la = [Double](repeating: 0, count: 3)
        getloadavg(&la, 3)
        let n = max(ProcessInfo.processInfo.processorCount, 1)
        return min(la[0] / Double(n), 1.0)
    }

    /// Fraction of physical RAM actively used (active + wired + compressed pages).
    private func currentMemoryUsage() -> Double {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = Int64(vm_kernel_page_size)
        let used = (Int64(stats.active_count) + Int64(stats.wire_count)
                    + Int64(stats.compressor_page_count)) * page
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        return Double(used) / Double(total)
    }

    private func broadcastActiveAppGroups() {
        guard let connection = connectedConnection else { return }
        // Send the set of currently active group IDs to the iPhone.
        let activeIDs = Array(activeAppGroups.keys)
        guard let data = try? JSONEncoder().encode(activeIDs) else { return }
        sendServerMessage(ServerMessage(type: "activeAppGroups", data: data), to: connection)
    }

    /// Restores any minimized windows for an app so they become placeable again.
    private func unminimizeAppWindows(app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return }
        for win in windows {
            var minimizedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
               let val = minimizedRef as? Bool, val {
                AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, false as CFTypeRef)
            }
        }
    }

    private func activateAndPlace(entry: AppGroupEntry, frame: CGRect,
                                  deadline: Date, placed: Bool = false,
                                  groupID: String = "", token: UUID = UUID()) {
        guard Date() < deadline else { return }
        // If the token no longer matches, stopAppGroup was called — bail out.
        if !groupID.isEmpty, placementTokens[groupID] != token { return }

        guard let app = runningApp(for: entry) else {
            if !placed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.activateAndPlace(entry: entry, frame: frame, deadline: deadline,
                                          placed: false, groupID: groupID, token: token)
                }
            }
            return
        }

        // If the window is minimized, restore it first so it becomes visible/placeable.
        unminimizeAppWindows(app: app)

        guard hasOnScreenWindow(for: app) else {
            if !placed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.activateAndPlace(entry: entry, frame: frame, deadline: deadline,
                                          placed: false, groupID: groupID, token: token)
                }
            }
            return
        }

        if !placed {
            activateApp(app)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                // Re-check token before doing any work.
                if !groupID.isEmpty, self.placementTokens[groupID] != token { return }

                let axWin = self.getAXWindow(for: app)

                if let win = axWin {
                    self.placeWindow(app: app, frame: frame)
                    var posRef: CFTypeRef?
                    var actual = CGPoint(x: -1, y: -1)
                    if AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
                       let rv = posRef, CFGetTypeID(rv) == AXValueGetTypeID() {
                        AXValueGetValue(rv as! AXValue, .cgPoint, &actual)
                    }
                    let lockDeadline = Date().addingTimeInterval(8)
                    self.activateAndPlace(entry: entry, frame: frame, deadline: lockDeadline,
                                         placed: true, groupID: groupID, token: token)
                } else {
                    // Catalyst / AX-blocked app: AppleScript retries.
                    let pid = app.processIdentifier
                    let appName = entry.appName
                    for attempt in 1...3 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt) * 1.0) { [weak self] in
                            guard let self else { return }
                            if !groupID.isEmpty, self.placementTokens[groupID] != token { return }
                            self.placeWindowViaAppleScript(pid: pid, frame: frame,
                                                           label: "\(appName) osa#\(attempt)")
                        }
                    }
                }
            }
        } else {
            // Lock phase for AX-capable apps only.
            if self.getAXWindow(for: app) != nil {
                placeWindow(app: app, frame: frame)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.activateAndPlace(entry: entry, frame: frame, deadline: deadline,
                                          placed: true, groupID: groupID, token: token)
                }
            }
        }
    }

    // Poll at 50 ms until a window exists for this app, then re-lock its position
    // every 100 ms until `until` expires (~3 s of coverage).
    private func snapWindow(entry: AppGroupEntry, frame: CGRect, until deadline: Date, locking: Bool = false) {
        guard Date() < deadline else { return }

        if let app = runningApp(for: entry), hasOnScreenWindow(for: app) {
            placeWindow(app: app, frame: frame)
            if !locking {
                // Window just appeared — switch to re-lock mode every 50 ms for 10 s.
                // 10 s covers slow-loading apps (App Store, Books, etc.) that restore
                // their saved window position after their content finishes loading.
                let lockUntil = Date().addingTimeInterval(10.0)
                snapWindow(entry: entry, frame: frame, until: lockUntil, locking: true)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.snapWindow(entry: entry, frame: frame, until: deadline, locking: true)
                }
            }
        } else {
            // Not running or no window yet — poll fast.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.snapWindow(entry: entry, frame: frame, until: deadline, locking: false)
            }
        }
    }

    // True when the app has at least one normal on-screen window.
    // Uses CGWindowList — works for ALL apps including Catalyst/sandboxed ones
    // that don't expose kAXWindowsAttribute.
    private func hasOnScreenWindow(for app: NSRunningApplication) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        let pid = Int(app.processIdentifier)
        // Accept any visible window for this PID — no layer filter so Catalyst
        // apps like App Store (which use non-zero layers) are included.
        return list.contains {
            ($0[kCGWindowOwnerPID as String] as? Int) == pid &&
            ($0[kCGWindowAlpha as String] as? Double ?? 0) > 0
        }
    }

    // Return the best available AX window element for this app.
    // Tries kAXWindowsAttribute → kAXFocusedWindowAttribute → kAXMainWindowAttribute.
    private func getAXWindow(for app: NSRunningApplication) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // Standard window list (most apps)
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
           let wins = ref as? [AXUIElement], let w = wins.first { return w }

        // Catalyst / sandboxed apps often only expose the focused window
        var fRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &fRef) == .success,
           let w = fRef { return (w as! AXUIElement) }

        // Last resort: main window attribute
        var mRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &mRef) == .success,
           let w = mRef { return (w as! AXUIElement) }

        return nil
    }

    // Activate an app using the correct API for the current OS version.
    private func activateApp(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    // MARK: - Window Placement

    // Apply a CG-coordinate frame.
    // Method 1: Accessibility API — works for AppKit/SwiftUI/Electron/etc apps.
    // Method 2: osascript via System Events — works for Mac Catalyst apps (AX err -25204).
    private func placeWindow(app: NSRunningApplication, frame: CGRect) {
        // Method 1: AX (works for regular AppKit/SwiftUI/Electron apps)
        if let win = getAXWindow(for: app) {
            var minRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minRef) == .success,
               (minRef as? Bool) == true {
                AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, false as CFBoolean)
            }
            // Respect the window's minimum size — never shrink below it.
            let effective = frame.clamped(toMinSizeOf: win)
            var p = CGPoint(x: effective.minX, y: effective.minY)
            var s = CGSize(width: effective.width, height: effective.height)
            if let pv = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv) }
            if let sv = AXValueCreate(.cgSize,  &s) { AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString,    sv) }
            if let pv = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv) }
            return
        }

        // Method 2: NSAppleScript via System Events (for Mac Catalyst apps that block AX).
        placeWindowViaAppleScript(pid: app.processIdentifier, frame: frame)
    }

    // MARK: - Min-size helpers

    /// Reads the AX minimum window size. Returns .zero if unavailable.
    func axMinWindowSize(for win: AXUIElement) -> CGSize {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, "AXMinSize" as CFString, &ref) == .success,
              let v = ref, CFGetTypeID(v) == AXValueGetTypeID() else { return .zero }
        var sz = CGSize.zero
        AXValueGetValue(v as! AXValue, .cgSize, &sz)
        return sz
    }

    /// Returns the minimum window size for a running app (via AX), or .zero.
    func minWindowSize(for app: NSRunningApplication) -> CGSize {
        guard let win = getAXWindow(for: app) else { return .zero }
        return axMinWindowSize(for: win)
    }

    /// Computes the tightest split-ratio range [minRatio, maxRatio] that satisfies
    /// each slot app's minimum size for the given layout axis on `screen`.
    /// Returns (0.15, 0.85) as safe defaults when min sizes can't be determined.
    // MARK: - Empirical min-size probing

    /// Empirically measured minimum window sizes, keyed by bundle ID.
    /// Persisted across launches — over time this covers every app the user
    /// actually puts in scenes, with the TRUE enforced minimum.
    private var probedMinSizes: [String: CGSize] = {
        guard let raw = UserDefaults.standard.dictionary(forKey: "rw_probed_min_sizes")
                as? [String: [Double]] else { return [:] }
        return raw.compactMapValues {
            $0.count == 2 ? CGSize(width: $0[0], height: $0[1]) : nil
        }
    }()

    private func saveProbedMinSizes() {
        let raw = probedMinSizes.mapValues { [Double($0.width), Double($0.height)] }
        UserDefaults.standard.set(raw, forKey: "rw_probed_min_sizes")
    }

    /// Min sizes read non-destructively (AXMinSize) from apps while they were
    /// running. Lower trust than probed values, but persists so the data is
    /// available later even when the app isn't running.
    private var harvestedMinSizes: [String: CGSize] = {
        guard let raw = UserDefaults.standard.dictionary(forKey: "rw_harvested_min_sizes")
                as? [String: [Double]] else { return [:] }
        return raw.compactMapValues {
            $0.count == 2 ? CGSize(width: $0[0], height: $0[1]) : nil
        }
    }()

    private func saveHarvestedMinSizes() {
        let raw = harvestedMinSizes.mapValues { [Double($0.width), Double($0.height)] }
        UserDefaults.standard.set(raw, forKey: "rw_harvested_min_sizes")
    }

    /// Sweeps all running apps and records their AXMinSize without touching
    /// any window. Cheap and silent — call whenever fresh data helps (e.g.
    /// when the workspace editor opens). Coverage grows over time as the
    /// user runs different apps.
    func harvestMinSizesFromRunningApps() {
        var changed = false
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bid = app.bundleIdentifier, !bid.isEmpty,
                  probedMinSizes[bid] == nil else { continue }
            let s = minWindowSize(for: app)
            guard s.width > 40, s.height > 40 else { continue }
            if let existing = harvestedMinSizes[bid],
               existing.width >= s.width, existing.height >= s.height { continue }
            harvestedMinSizes[bid] = CGSize(width: max(s.width, harvestedMinSizes[bid]?.width ?? 0),
                                            height: max(s.height, harvestedMinSizes[bid]?.height ?? 0))
            changed = true
        }
        if changed { saveHarvestedMinSizes() }
    }

    /// Whether a running app could join the scene's layout without breaking
    /// any window's minimum size on the current screen. Non-destructive —
    /// uses known/AX min sizes, never probes.
    func canAddToScene(groupID: String, app: NSRunningApplication) -> Bool {
        guard let group = appGroups.first(where: { $0.id == groupID }),
              let path = app.bundleURL?.path else { return false }
        var entries = liveSlotEntries(for: group)
        guard entries.count < slotCapacity(for: group.layout) else { return false }
        entries.append(AppGroupEntry(
            id: UUID().uuidString,
            appName: app.localizedName ?? "",
            bundleID: app.bundleIdentifier ?? "",
            path: path
        ))
        let screen = NSScreen.screens.first ?? NSScreen.main!
        return conflictPair(entries: entries, layout: group.layout, screen: screen) == nil
    }

    /// Save-time verification: returns a measured minimum size for the entry,
    /// launching the app (without activating it) when it isn't running and no
    /// trustworthy data exists yet. Apps we started are quit again afterwards.
    func measureMinSizeForValidation(entry: AppGroupEntry) async -> CGSize? {
        guard !entry.isShortcut else { return nil }

        let running = NSWorkspace.shared.runningApplications
        if let app = running.first(where: { $0.bundleIdentifier == entry.bundleID })
            ?? running.first(where: { $0.bundleURL?.path == entry.path }) {
            return probeMinSize(app: app, bundleID: entry.bundleID)
        }

        // Already know it from a previous probe/harvest/registry? Done.
        if let known = knownMinSize(bundleID: entry.bundleID) { return known }

        // Unknown and not running — launch quietly, measure, quit.
        let url = URL(fileURLWithPath: (entry.path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        guard let app = try? await NSWorkspace.shared.openApplication(at: url, configuration: config) else {
            return nil
        }
        var measured: CGSize?
        for _ in 0..<16 {   // up to ~4 s for the first window to appear
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let size = probeMinSize(app: app, bundleID: entry.bundleID) {
                measured = size
                break
            }
        }
        app.terminate()
        return measured
    }

    /// Best known minimum size for a bundle ID from any source
    /// (probed → harvested → static registry), or nil if unknown.
    func knownMinSize(bundleID: String) -> CGSize? {
        if let p = probedMinSizes[bundleID] { return p }
        if let h = harvestedMinSizes[bundleID] { return h }
        if let r = AppMinSizeRegistry.sizes[bundleID] { return r }
        let lower = bundleID.lowercased()
        return AppMinSizeRegistry.sizes.first { $0.key.lowercased() == lower }?.value
    }

    /// Measures an app's true minimum window size: ask its window to become
    /// 1×1 via AX and read back what it actually became — AppKit clamps the
    /// request to the window's real contentMinSize, so this is accurate even
    /// for apps whose AXMinSize attribute is missing or wrong (Electron).
    /// The original frame is restored immediately; result is cached for good.
    @discardableResult
    func probeMinSize(app: NSRunningApplication, bundleID: String) -> CGSize? {
        guard !bundleID.isEmpty else { return nil }
        if let cached = probedMinSizes[bundleID] { return cached }
        guard let win = getAXWindow(for: app) else { return nil }

        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let sv = sizeRef, CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var original = CGSize.zero
        AXValueGetValue(sv as! AXValue, .cgSize, &original)
        guard original.width > 0 else { return nil }

        var tiny = CGSize(width: 1, height: 1)
        guard let tv = AXValueCreate(.cgSize, &tiny) else { return nil }
        AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, tv)

        var measured = CGSize.zero
        var probedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &probedRef) == .success,
           let pv = probedRef, CFGetTypeID(pv) == AXValueGetTypeID() {
            AXValueGetValue(pv as! AXValue, .cgSize, &measured)
        }

        // Restore the original size before anything else.
        var restore = original
        if let rv = AXValueCreate(.cgSize, &restore) {
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, rv)
        }

        // Sanity: a real minimum is meaningfully sized. (If the app refused
        // the resize, measured == original, which IS its floor right now —
        // still a safe upper bound for conflict checks.)
        guard measured.width > 40, measured.height > 40 else { return nil }

        probedMinSizes[bundleID] = measured
        saveProbedMinSizes()
        return measured
    }

    /// Minimum window size for a slot entry, in order of trust:
    /// empirically probed value (the enforced truth) → static registry for
    /// known apps → live AXMinSize. Combined per-dimension with MAX so a
    /// missing/lying source can never lower a known floor.
    func minSlotSize(for entry: AppGroupEntry) -> CGSize {
        let registry = AppMinSizeRegistry.minSize(for: entry) ?? .zero
        let harvested = harvestedMinSizes[entry.bundleID] ?? .zero

        let running = NSWorkspace.shared.runningApplications
        let app = running.first { $0.bundleIdentifier == entry.bundleID }
            ?? running.first { $0.bundleURL?.path == entry.path }
        let ax = app.map { minWindowSize(for: $0) } ?? .zero

        if let probed = probedMinSizes[entry.bundleID] {
            // Probed is authoritative; AX can only raise it (e.g. a different
            // window type with a larger floor).
            return CGSize(width:  max(probed.width,  ax.width),
                          height: max(probed.height, ax.height))
        }
        return CGSize(width:  max(ax.width,  max(registry.width,  harvested.width)),
                      height: max(ax.height, max(registry.height, harvested.height)))
    }

    func splitRatioBounds(for group: AppGroup, screen: NSScreen) -> (min: Double, max: Double) {
        splitRatioBounds(entries: liveSlotEntries(for: group), layout: group.layout, screen: screen)
    }

    /// Core primary-axis bounds for an explicit entry list — lets callers test
    /// hypothetical line-ups (e.g. "would adding Figma still fit?") before
    /// committing them to the live scene.
    func splitRatioBounds(entries slotApps: [AppGroupEntry], layout: AppGroupLayout,
                          screen: NSScreen) -> (min: Double, max: Double) {
        guard slotApps.count >= 2 else { return (0.10, 0.90) }

        let v = screen.visibleFrame
        func minW(_ e: AppGroupEntry) -> CGFloat { minSlotSize(for: e).width }
        func minH(_ e: AppGroupEntry) -> CGFloat { minSlotSize(for: e).height }

        switch layout {
        case .split1x1:
            // Left | Right — ratio = leftWidth / totalWidth
            let minLeft  = minW(slotApps[0])
            let minRight = minW(slotApps[1])
            let total    = v.width
            let lo = total > 0 ? max(0.10, Double(minLeft  / total)) : 0.10
            let hi = total > 0 ? min(0.90, Double(1 - minRight / total)) : 0.90
            return (max(lo, 0.10), min(hi, 0.90))

        case .split1x1v:
            // Top | Bottom — ratio = topHeight / totalHeight
            let minTop    = minH(slotApps[0])
            let minBottom = minH(slotApps[1])
            let total     = v.height
            let lo = total > 0 ? max(0.10, Double(minTop    / total)) : 0.10
            let hi = total > 0 ? min(0.90, Double(1 - minBottom / total)) : 0.90
            return (max(lo, 0.10), min(hi, 0.90))

        case .split1x2, .split2x1:
            // Vertical split (primary axis = horizontal)
            let mainMin = minW(slotApps[0])
            let sideMin = slotApps.dropFirst().map(minW).max() ?? 0
            let total   = v.width
            let lo = total > 0 ? max(0.10, Double(mainMin / total)) : 0.10
            let hi = total > 0 ? min(0.90, Double(1 - sideMin / total)) : 0.90
            return (max(lo, 0.10), min(hi, 0.90))

        case .split1x2h:
            let mainMin = minH(slotApps[0])
            let sideMin = slotApps.dropFirst().map(minH).max() ?? 0
            let total   = v.height
            let lo = total > 0 ? max(0.10, Double(mainMin / total)) : 0.10
            let hi = total > 0 ? min(0.90, Double(1 - sideMin / total)) : 0.90
            return (max(lo, 0.10), min(hi, 0.90))

        case .grid2x2:
            return (0.15, 0.85)
        }
    }

    /// Min-size limits for the SECONDARY split ratio (the stack divider inside a
    /// focus layout's side column / split1x2h's bottom row / grid2x2's row split).
    func splitRatioBoundsSecondary(for group: AppGroup, screen: NSScreen) -> (min: Double, max: Double) {
        splitRatioBoundsSecondary(entries: liveSlotEntries(for: group),
                                  layout: group.layout, screen: screen)
    }

    /// Core secondary-axis bounds for an explicit entry list (see primary variant).
    func splitRatioBoundsSecondary(entries slotApps: [AppGroupEntry], layout: AppGroupLayout,
                                   screen: NSScreen) -> (min: Double, max: Double) {
        guard slotApps.count >= 3 else { return (0.10, 0.90) }

        let v = screen.visibleFrame
        func minH(_ entry: AppGroupEntry) -> CGFloat { minSlotSize(for: entry).height }
        func minW(_ entry: AppGroupEntry) -> CGFloat { minSlotSize(for: entry).width  }

        switch layout {
        case .split1x2, .split2x1:
            // ratio2 = top stacked window's height fraction of the full height.
            let minTop    = minH(slotApps[1])
            let minBottom = minH(slotApps[2])
            let total     = v.height
            let lo = total > 0 ? max(0.10, Double(minTop / total)) : 0.10
            let hi = total > 0 ? min(0.90, Double(1 - minBottom / total)) : 0.90
            return (max(lo, 0.10), min(hi, 0.90))

        case .split1x2h:
            // ratio2 = bottom-row left window's width fraction of the full width.
            let minLeft  = minW(slotApps[1])
            let minRight = minW(slotApps[2])
            let total    = v.width
            let lo = total > 0 ? max(0.10, Double(minLeft / total)) : 0.10
            let hi = total > 0 ? min(0.90, Double(1 - minRight / total)) : 0.90
            return (max(lo, 0.10), min(hi, 0.90))

        case .grid2x2:
            // ratio2 = top row height fraction; compare both columns' minimums.
            let topMin    = slotApps.prefix(2).map(minH).max() ?? 0
            let bottomMin = slotApps.dropFirst(2).prefix(2).map(minH).max() ?? 0
            let total = v.height
            let lo = total > 0 ? max(0.10, Double(topMin / total)) : 0.10
            let hi = total > 0 ? min(0.90, Double(1 - bottomMin / total)) : 0.90
            return (max(lo, 0.10), min(hi, 0.90))

        case .split1x1, .split1x1v:
            return (0.10, 0.90)   // these layouts have no secondary divider
        }
    }

    // installArrangeScript is a no-op — sandbox removed, no script file needed
    func installArrangeScript() {}

    /// Returns the system-default browser as a BrowserChoice.
    /// Falls back to Safari if the default isn't recognised.
    private func defaultBrowserChoice() -> BrowserChoice {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            toOpen: URL(string: "https://example.com")!
        ) else { return .safari }
        let path = appURL.path
        if path.localizedCaseInsensitiveContains("Google Chrome") { return .chrome }
        return .safari
    }

    /// Opens `urlString` as a new tab in the active browser window.
    /// If the browser has no open windows, opens a new window instead.
    private func openOrReuseURLInBrowser(_ urlString: String, browser: BrowserChoice) {
        guard let url = URL(string: urlString) else { return }
        let appURL = URL(fileURLWithPath: browser.appPath)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        // Opens the URL with the chosen browser — creates a new tab if the browser is
        // already running, or launches it fresh. No TCC permission required.
        NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                configuration: config, completionHandler: nil)
    }

    // MARK: - osascript subprocess (no permission dialog needed)
    // /usr/bin/osascript is pre-authorized to control System Events.
    // Runs as a subprocess so it works without any TCC prompt.

    private func runAppleScript(_ source: String) {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", source]
        task.standardOutput = FileHandle.nullDevice
        task.standardError  = FileHandle.nullDevice
        try? task.run()
    }

    @discardableResult
    private func runAppleScriptSync(_ source: String) -> String {
        let out = Pipe(), err = Pipe()
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", source]
        task.standardOutput = out
        task.standardError  = err
        do {
            try task.run()
            task.waitUntilExit()
            let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return e.isEmpty ? (o.isEmpty ? "ok" : o) : "err:\(e)"
        } catch { return "launch-failed:\(error)" }
    }

    private func placeWindowViaAppleScript(pid: pid_t, frame: CGRect, label: String = "") {
        let x = Int(frame.minX), y = Int(frame.minY)
        let w = Int(frame.width), h = Int(frame.height)
        let src = """
        tell application "System Events"
            set proc to first process whose unix id is \(pid)
            if (count of windows of proc) > 0 then
                set position of window 1 of proc to {\(x), \(y)}
                set size of window 1 of proc to {\(w), \(h)}
                set position of window 1 of proc to {\(x), \(y)}
            end if
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            _ = self.runAppleScriptSync(src)
        }
    }

    func requestAutomationPermission() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runAppleScriptSync(
                "tell application \"System Events\" to return name of first process"
            )
            DispatchQueue.main.async {
                if result.hasPrefix("err:") {
                    self.showAlert(title: "Automation ❌", message: result)
                } else {
                    self.showAlert(title: "Automation ✅",
                                   message: "osascript works! Reply: \(result)\nWindow arrangement is ready.")
                }
            }
        }
    }

    // Convenience overload: look up the running app then place its window.
    private func placeWindow(entry: AppGroupEntry, frame: CGRect) {
        guard let app = runningApp(for: entry) else { return }
        placeWindow(app: app, frame: frame)
    }

    // Find the NSRunningApplication that corresponds to a group entry.
    private func runningApp(for entry: AppGroupEntry) -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications

        // 1. Stored bundle ID (the most reliable lookup — e.g. "com.apple.AppStore").
        //    Guard against the legacy case where bundleID was accidentally stored as a path.
        let stored = entry.bundleID
        if !stored.isEmpty, !stored.hasPrefix("/"), !stored.hasPrefix("~") {
            if let app = running.first(where: { $0.bundleIdentifier == stored }) { return app }
        }

        // 2. Derive bundle ID fresh from the .app bundle on disk.
        if let bid = Bundle(url: URL(fileURLWithPath: entry.path))?.bundleIdentifier {
            if let app = running.first(where: { $0.bundleIdentifier == bid }) { return app }
        }

        // 3. Path comparison — standardise both sides to resolve symlinks
        //    (system apps on Ventura+ may be cryptex-mounted at a different real path).
        let normalised = URL(fileURLWithPath: entry.path).standardized.path
        if let app = running.first(where: {
            guard let url = $0.bundleURL else { return false }
            return URL(fileURLWithPath: url.path).standardized.path == normalised
        }) { return app }

        // 4. Display-name fallback (last resort — catches localised app names).
        let appName = URL(fileURLWithPath: entry.path).deletingPathExtension().lastPathComponent
        return running.first { $0.localizedName == appName }
    }

    // Compute target window frames in CoreGraphics screen coordinates.
    //
    // NSScreen.visibleFrame is in Cocoa coords: origin bottom-left of screen, Y increases upward.
    // AX API expects CG coords: origin top-left of the PRIMARY screen, Y increases downward.
    // Conversion: cgY = primaryScreenHeight - cocoaRect.maxY
    private func windowFramesCG(
        for layout: AppGroupLayout,
        appCount: Int,
        targetScreen: NSScreen?,
        primaryScreenH: CGFloat,
        splitRatio: Double = 0.5,
        splitRatioSecondary: Double = 0.5
    ) -> [CGRect] {
        let screen = targetScreen ?? NSScreen.screens.first!
        let v = screen.visibleFrame // Cocoa coordinates

        // Convert a Cocoa rect to a CG rect.
        func toCG(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX, y: primaryScreenH - r.maxY, width: r.width, height: r.height)
        }

        let x = v.minX, y = v.minY, w = v.width, h = v.height
        let ratio  = CGFloat(max(0.15, min(0.85, splitRatio)))
        let ratio2 = CGFloat(max(0.15, min(0.85, splitRatioSecondary)))
        let cocoaFrames: [CGRect]

        switch layout {
        case .split1x1:
            // Left | Right split by ratio
            let splitX = (w * ratio).rounded()
            var f = [
                CGRect(x: x,           y: y, width: splitX,     height: h),
                CGRect(x: x + splitX,  y: y, width: w - splitX, height: h),
            ]
            for _ in 2..<max(appCount, 2) { f.append(f[1]) }
            cocoaFrames = f

        case .split1x1v:
            // Top | Bottom split by ratio (Cocoa: higher y = visually higher)
            let splitH = (h * ratio).rounded()
            var f = [
                CGRect(x: x, y: y + (h - splitH), width: w, height: splitH),  // top
                CGRect(x: x, y: y,                 width: w, height: h - splitH), // bottom
            ]
            for _ in 2..<max(appCount, 2) { f.append(f[1]) }
            cocoaFrames = f

        case .split1x2:
            // Large left (ratio%) | stacked right; stack split by ratio2
            guard appCount > 1 else { cocoaFrames = [v]; break }
            let mainW = (w * ratio).rounded()
            let sideW = w - mainW
            let sideCount = max(appCount - 1, 1)
            var f = [CGRect(x: x, y: y, width: mainW, height: h)]
            if sideCount == 1 {
                f.append(CGRect(x: x + mainW, y: y, width: sideW, height: h))
            } else {
                // two stacked: top gets ratio2 of height
                let topH = (h * ratio2).rounded()
                f.append(CGRect(x: x + mainW, y: y + h - topH, width: sideW, height: topH))
                f.append(CGRect(x: x + mainW, y: y,             width: sideW, height: h - topH))
                for _ in 3..<appCount {
                    f.append(CGRect(x: x + mainW, y: y, width: sideW, height: (h - topH)))
                }
            }
            cocoaFrames = f

        case .split2x1:
            // Stacked left | Large right (ratio%); stack split by ratio2
            guard appCount > 1 else { cocoaFrames = [v]; break }
            let mainW = (w * ratio).rounded()
            let sideW = w - mainW
            let sideCount = max(appCount - 1, 1)
            var f = [CGRect(x: x + sideW, y: y, width: mainW, height: h)]
            if sideCount == 1 {
                f.append(CGRect(x: x, y: y, width: sideW, height: h))
            } else {
                let topH = (h * ratio2).rounded()
                f.append(CGRect(x: x, y: y + h - topH, width: sideW, height: topH))
                f.append(CGRect(x: x, y: y,             width: sideW, height: h - topH))
                for _ in 3..<appCount {
                    f.append(CGRect(x: x, y: y, width: sideW, height: h - topH))
                }
            }
            cocoaFrames = f

        case .split1x2h:
            // Large top (ratio%) | side-by-side bottom; bottom split by ratio2
            guard appCount > 1 else { cocoaFrames = [v]; break }
            let mainH = (h * ratio).rounded()
            let sideH = h - mainH
            let sideCount = max(appCount - 1, 1)
            var f = [CGRect(x: x, y: y + sideH, width: w, height: mainH)]
            if sideCount == 1 {
                f.append(CGRect(x: x, y: y, width: w, height: sideH))
            } else {
                let leftW = (w * ratio2).rounded()
                f.append(CGRect(x: x,          y: y, width: leftW,     height: sideH))
                f.append(CGRect(x: x + leftW,  y: y, width: w - leftW, height: sideH))
                for _ in 3..<appCount {
                    f.append(CGRect(x: x + leftW, y: y, width: w - leftW, height: sideH))
                }
            }
            cocoaFrames = f

        case .grid2x2:
            // Vertical split at ratio, horizontal split at ratio2
            let colW = (w * ratio).rounded()
            let rowH = (h * ratio2).rounded()
            let slots: [CGRect] = [
                CGRect(x: x,          y: y + h - rowH, width: colW,     height: rowH),       // top-left
                CGRect(x: x + colW,   y: y + h - rowH, width: w - colW, height: rowH),       // top-right
                CGRect(x: x,          y: y,             width: colW,     height: h - rowH),   // bottom-left
                CGRect(x: x + colW,   y: y,             width: w - colW, height: h - rowH),   // bottom-right
            ]
            cocoaFrames = (0..<max(appCount, 1)).map { slots[min($0, slots.count - 1)] }
        }

        return cocoaFrames.map(toCG)
    }

    // Apply a window frame via the Accessibility API.
    // Returns false when the window doesn't exist yet OR when the AX write didn't stick
    // (which happens silently when Accessibility permission hasn't been granted).
    @discardableResult
    private func applyFrame(_ frame: CGRect, toApp app: NSRunningApplication) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // Get the window list.
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              !windows.isEmpty else { return false }

        // Prefer the AXMain window (primary document window), fall back to first.
        let window: AXUIElement = windows.first(where: { w in
            var ref: CFTypeRef?
            return AXUIElementCopyAttributeValue(w, kAXMainAttribute as CFString, &ref) == .success
                && (ref as? Bool) == true
        }) ?? windows[0]

        // Unminimize if needed — AX cannot resize a minimized window.
        var minimizedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
           (minimizedRef as? Bool) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFBoolean)
            Thread.sleep(forTimeInterval: 0.25)
        }

        let targetPos  = CGPoint(x: frame.minX, y: frame.minY)
        let targetSize = CGSize(width: frame.width, height: frame.height)

        // Position → Size → Position.
        // Re-applying position after size is necessary because some apps (Safari, Finder,
        // Terminal) nudge the origin after a resize.
        if let pv = AXValue.from(point: targetPos)  { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pv) }
        if let sv = AXValue.from(size: targetSize)  { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sv) }
        if let pv = AXValue.from(point: targetPos)  { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pv) }

        // Read the position back to verify the write actually stuck.
        // If Accessibility permission is not granted, the set calls above are silently
        // ignored by the system and the read-back will show the original position.
        var posReadRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posReadRef) == .success,
              let posVal = posReadRef,
              let axPos = AXValue.point(from: posVal) else { return false }

        // Allow 8 px tolerance for apps that clamp to display bounds.
        let tolerance: CGFloat = 8
        return abs(axPos.x - targetPos.x) < tolerance && abs(axPos.y - targetPos.y) < tolerance
    }

    private func saveShortcutsInBackground(_ snapshot: [SavedShortcut], revision: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.shortcutsRevision == revision else {
                return
            }

            DispatchQueue.global(qos: .utility).async {
                RewindpadShortcutDiskStore.save(snapshot)
            }
        }
    }

    private func storageSafeShortcut(_ shortcut: SavedShortcut) -> SavedShortcut {
        RewindpadShortcutDiskStore.storageSafe(shortcut)
    }

    private func backfillShortcutIconsIfNeeded() {
        // Disabled: storing or pushing icon base64 in saved shortcuts was the main memory issue.
    }

    private func shortcutOfficialIconData() -> String? {
        let possiblePaths = [
            "/System/Applications/Shortcuts.app",
            "/Applications/Shortcuts.app"
        ]

        guard let path = possiblePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return nil
        }

        return officialIconData(forAppAt: path)
    }

    private func fetchAppleShortcuts() -> [AppleShortcut] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            return output
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { AppleShortcut(id: $0, name: $0, iconData: nil) }
        } catch {
            return []
        }
    }

    private func applyAppleShortcutsSnapshot(_ appleShortcuts: [AppleShortcut], forcePush: Bool) {
        let appleNames = Set(appleShortcuts.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var didPruneSavedShortcuts = false

        if !appleNames.isEmpty {
            let oldCount = shortcuts.count
            shortcuts.removeAll { savedShortcut in
                guard savedShortcut.type == "shortcut" else { return false }

                let title = savedShortcut.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let target = savedShortcut.target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let id = savedShortcut.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

                return !appleNames.contains(title) && !appleNames.contains(target) && !appleNames.contains(id)
            }

            didPruneSavedShortcuts = shortcuts.count != oldCount
        }

        if didPruneSavedShortcuts {
            shortcutsRevision += 1
            saveShortcuts()
            pushSavedShortcutsUpdate()
            pushAvailableShortcutsUpdate()
        } else if forcePush {
            pushSavedShortcutsUpdate()
            pushAvailableShortcutsUpdate()
        }
    }

    private func refreshAppleShortcutsAsync() {
        refreshAppleShortcutsIfChangedAsync(forcePush: true)
    }

    // MARK: - Browser history

    func refreshBrowsingHistory() {
        guard !isFetchingHistory else { return }
        isFetchingHistory = true
        Task {
            let links = await BrowserHistoryFetcher.shared.fetchAll()
            await MainActor.run { [weak self] in
                self?.suggestedLinks = links
                self?.isFetchingHistory = false
            }
        }
    }

    private func refreshAppleShortcutsIfChangedAsync(forcePush: Bool = false) {
        if isAppleShortcutsRefreshRunning {
            pendingAppleShortcutsRefresh = true
            return
        }

        isAppleShortcutsRefreshRunning = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let shortcuts = self?.fetchAppleShortcuts() ?? []
            let signature = shortcuts.map { $0.name }.joined(separator: "\u{1F}")

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                self.isAppleShortcutsRefreshRunning = false
                let shouldPush = forcePush || signature != self.lastAvailableShortcutsSignature

                if shouldPush {
                    self.lastAvailableShortcutsSignature = signature
                    self.availableShortcuts = shortcuts
                    self.syncShortcutNamesInAppGroups(shortcuts)
                    self.applyAppleShortcutsSnapshot(shortcuts, forcePush: forcePush)
                    self.pushAvailableShortcutsUpdate()
                    self.pushShortcutSyncUpdate(forceRescan: false)
                } else if forcePush {
                    self.applyAppleShortcutsSnapshot(shortcuts, forcePush: true)
                }

                if self.pendingAppleShortcutsRefresh {
                    self.pendingAppleShortcutsRefresh = false
                    self.refreshAppleShortcutsIfChangedAsync()
                }
            }
        }
    }

    /// Reconcile all stored AppGroup shortcut entries against the fresh list:
    ///   • Remove entries for shortcuts that were deleted (ID no longer present).
    ///   • Update names for shortcuts that were renamed (ID matches, name changed).
    /// Matches by the stable shortcut UUID embedded in entry.id ("shortcut-<uuid>").
    /// Saves and pushes only if something changed.
    /// Reconcile persisted appGroups with the fresh shortcut list.
    /// We never auto-remove shortcuts: since Apple's CLI only provides names (no stable UUIDs),
    /// a rename is indistinguishable from delete+new. Only update names for exact ID matches.
    /// Shortcuts are only removed when the user explicitly does so in the editor.
    private func syncShortcutNamesInAppGroups(_ freshShortcuts: [AppleShortcut]) {
        let lookup = Dictionary(uniqueKeysWithValues: freshShortcuts.map { ("shortcut-\($0.id)", $0) })
        var changed = false
        var updatedGroups = appGroups
        for gi in updatedGroups.indices {
            var apps = updatedGroups[gi].apps
            for ei in apps.indices {
                guard apps[ei].isShortcut, let fresh = lookup[apps[ei].id] else { continue }
                if apps[ei].shortcutName != fresh.name || apps[ei].appName != fresh.name {
                    apps[ei].shortcutName = fresh.name
                    apps[ei].appName      = fresh.name
                    changed = true
                }
            }
            updatedGroups[gi].apps = apps
        }
        guard changed else { return }
        appGroups = updatedGroups
        AppGroupStore.save(appGroups)
        pushAppGroupsToPhone()
    }

    private func scheduleAppleShortcutsRefresh(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.refreshAppleShortcutsAsync()
        }
    }

    private func runAppleShortcut(_ name: String) {
        // Primary: the shortcuts CLI — runs silently in the background with no
        // UI and no Apple Events permission prompt.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        task.arguments = ["run", name]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            return
        } catch {
            print("shortcuts CLI failed (\(error)) — falling back to Shortcuts Events")
        }

        // Fallback: "Shortcuts Events", the background-only Shortcuts agent.
        // NSAppleScript is NOT thread-safe — it must run on the main thread
        // (executing it from a background queue fails silently).
        let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Shortcuts Events\" to run shortcut named \"\(escaped)\""
        DispatchQueue.main.async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let err = error {
                print("Shortcuts Events error: \(err)")
            }
        }
    }

    private func performCommand(_ command: String) {
        switch command {
        case "openFinder":
            openPath(NSHomeDirectory())

        case "openDownloads":
            if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                openPath(downloads.path)
            }

        case "openDesktop":
            if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
                openPath(desktop.path)
            }

        case "openDocuments":
            if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                openPath(documents.path)
            }

        case "openApplications":
            openPath("/Applications")

        case "clearClipboard":
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                self.clipboardHistory.removeAll()
                self.pushStateUpdate()
            }

        case "lockMac":
            runShell("/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession", ["-suspend"])

        case "sleepDisplay":
            runShell("/usr/bin/pmset", ["displaysleepnow"])

        case "sleepMac":
            runShell("/usr/bin/pmset", ["sleepnow"])

        case "mute":
            runAppleScript("set volume output muted true")

        case "unmute":
            runAppleScript("set volume output muted false")

        case "restartMac":
            runAppleScript("tell application \"System Events\" to restart")

        case "shutdownMac":
            runAppleScript("tell application \"System Events\" to shut down")

        case "showDesktop":
            runAppleScript("""
            tell application "System Events"
                key code 103 using {command down}
            end tell
            """)

        case "missionControl":
            runAppleScript("""
            tell application "System Events"
                key code 126 using {control down}
            end tell
            """)

        case "spotlight":
            runAppleScript("""
            tell application "System Events"
                key code 49 using {command down}
            end tell
            """)

        default:
            break
        }
    }

    private func openPath(_ path: String) {
        DispatchQueue.main.async {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    private func runShell(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        do {
            try process.run()
        } catch {
            print("Shell command error: \(error)")
        }
    }

}


// MARK: - Suggested Links (browser history)

struct SuggestedLink: Identifiable, Equatable {
    let id: String       // root URL (scheme+host) — stable identity and what gets added to a Scene
    let title: String
    let url: String      // root URL: https://example.com (no path/query)
    let domain: String
    let lastVisited: Date?

    /// The short brand/website name shown as the primary label.
    /// Uses a known-brand lookup first, then falls back to a prettified domain part.
    var brandName: String { SuggestedLink.resolveBrand(for: domain) }

    /// Returns just scheme://host — strips path, query, fragment.
    static func rootURL(from urlString: String) -> String {
        guard let parsed = URL(string: urlString),
              let scheme = parsed.scheme,
              let host   = parsed.host
        else { return urlString }
        return "\(scheme)://\(host)"
    }

    static func extractDomain(from urlString: String) -> String {
        guard let host = URL(string: urlString)?.host else { return urlString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: Brand name resolution

    static func resolveBrand(for domain: String) -> String {
        let parts = domain.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return domain }

        // Check from the registrable domain inward (most specific first).
        // e.g. "statics.teams.cdn.office.net" checks: "office", then "cdn", then "teams"
        let tldStripped = parts.dropLast()   // drop TLD (.com / .net / .io …)
        for part in tldStripped.reversed() {
            let key = part.lowercased()
            if let brand = knownBrands[key] { return brand }
        }

        // Fallback: prettify the registrable domain part (second-to-last before TLD)
        let key = parts[parts.count - 2]
        return key
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static let knownBrands: [String: String] = [
        // Google
        "google": "Google", "gmail": "Gmail", "youtube": "YouTube",
        "docs": "Google Docs", "drive": "Google Drive", "meet": "Google Meet",
        "calendar": "Google Calendar", "maps": "Google Maps",
        // Apple
        "apple": "Apple", "icloud": "iCloud",
        // Microsoft
        "microsoft": "Microsoft", "office": "Microsoft Office",
        "office365": "Microsoft 365", "live": "Microsoft",
        "outlook": "Outlook", "teams": "Microsoft Teams",
        "sharepoint": "SharePoint", "onedrive": "OneDrive",
        "azure": "Azure", "bing": "Bing",
        // ServiceNow
        "service-now": "ServiceNow", "servicenow": "ServiceNow",
        // Salesforce
        "salesforce": "Salesforce", "force": "Salesforce",
        "lightning": "Salesforce",
        // Dev tools
        "github": "GitHub", "gitlab": "GitLab",
        "bitbucket": "Bitbucket", "atlassian": "Atlassian",
        "jira": "Jira", "confluence": "Confluence", "trello": "Trello",
        "linear": "Linear", "vercel": "Vercel", "netlify": "Netlify",
        "heroku": "Heroku", "aws": "AWS", "cloudflare": "Cloudflare",
        "stackoverflow": "Stack Overflow",
        // Productivity
        "notion": "Notion", "figma": "Figma", "miro": "Miro",
        "asana": "Asana", "monday": "Monday.com",
        "airtable": "Airtable", "clickup": "ClickUp",
        "basecamp": "Basecamp", "slack": "Slack",
        "zoom": "Zoom", "loom": "Loom",
        "dropbox": "Dropbox", "box": "Box",
        "hubspot": "HubSpot", "zendesk": "Zendesk",
        "intercom": "Intercom", "stripe": "Stripe",
        // Social / Media
        "twitter": "Twitter", "x": "X",
        "facebook": "Facebook", "instagram": "Instagram",
        "linkedin": "LinkedIn", "reddit": "Reddit",
        "medium": "Medium", "substack": "Substack",
        "netflix": "Netflix", "spotify": "Spotify",
        "amazon": "Amazon", "openai": "OpenAI",
        "anthropic": "Anthropic",
    ]
}

// MARK: - Browser history fetcher

final class BrowserHistoryFetcher {
    static let shared = BrowserHistoryFetcher()
    private let limitPerSource = 100

    func fetchAll() async -> [SuggestedLink] {
        var all: [SuggestedLink] = []
        await withTaskGroup(of: [SuggestedLink].self) { group in
            group.addTask { await self.fetchSafari() }
            group.addTask { await self.fetchChromiumDB(label: "chrome",
                path: "Library/Application Support/Google/Chrome/Default/History") }
            group.addTask { await self.fetchChromiumDB(label: "edge",
                path: "Library/Application Support/Microsoft Edge/Default/History") }
            group.addTask { await self.fetchChromiumDB(label: "arc",
                path: "Library/Application Support/Arc/User Data/Default/History") }
            for await batch in group { all.append(contentsOf: batch) }
        }
        return deduplicated(all)
    }

    // MARK: - Safari

    private func fetchSafari() async -> [SuggestedLink] {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Safari/History.db")
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        return await readSQLite(path: path) { db in
            var rows: [SuggestedLink] = []
            let sql = """
                SELECT hi.url, COALESCE(hi.title,''), MAX(hv.visit_time)
                FROM history_items hi
                JOIN history_visits hv ON hv.history_item = hi.id
                WHERE hi.url NOT LIKE 'about:%'
                GROUP BY hi.id
                ORDER BY MAX(hv.visit_time) DESC
                LIMIT \(self.limitPerSource)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let urlPtr = sqlite3_column_text(stmt, 0) else { continue }
                let url   = String(cString: urlPtr)
                let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let ts    = sqlite3_column_double(stmt, 2)
                let date: Date? = ts > 0 ? Date(timeIntervalSinceReferenceDate: ts) : nil
                let dom  = SuggestedLink.extractDomain(from: url)
                let root = SuggestedLink.rootURL(from: url)
                guard !dom.isEmpty else { continue }
                rows.append(SuggestedLink(id: root, title: title, url: root,
                                         domain: dom, lastVisited: date))
            }
            return rows
        }
    }

    // MARK: - Chromium-based (Chrome / Edge / Arc)

    private func fetchChromiumDB(label: String, path: String) async -> [SuggestedLink] {
        let fullPath = (NSHomeDirectory() as NSString).appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: fullPath) else { return [] }
        return await readSQLite(path: fullPath) { db in
            var rows: [SuggestedLink] = []
            let sql = """
                SELECT url, COALESCE(title,''), last_visit_time
                FROM urls
                WHERE url NOT LIKE 'chrome://%'
                  AND url NOT LIKE 'chrome-extension://%'
                  AND url NOT LIKE 'edge://%'
                  AND url NOT LIKE 'about:%'
                ORDER BY last_visit_time DESC
                LIMIT \(self.limitPerSource)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let urlPtr = sqlite3_column_text(stmt, 0) else { continue }
                let url   = String(cString: urlPtr)
                let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let ts    = sqlite3_column_int64(stmt, 2)
                // Chrome stores microseconds since Jan 1 1601
                let date: Date? = ts > 0
                    ? Date(timeIntervalSince1970: Double(ts) / 1_000_000.0 - 11_644_473_600.0)
                    : nil
                let dom  = SuggestedLink.extractDomain(from: url)
                let root = SuggestedLink.rootURL(from: url)
                guard !dom.isEmpty else { continue }
                rows.append(SuggestedLink(id: root, title: title, url: root,
                                         domain: dom, lastVisited: date))
            }
            return rows
        }
    }

    // MARK: - SQLite helper — copies the file first to avoid lock conflicts

    private func readSQLite(path: String,
                            query: @escaping (OpaquePointer?) -> [SuggestedLink]) async -> [SuggestedLink] {
        return await Task.detached(priority: .utility) {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".db")
            defer { try? FileManager.default.removeItem(at: tmp) }
            do { try FileManager.default.copyItem(atPath: path, toPath: tmp.path) }
            catch { return [] }

            var db: OpaquePointer?
            guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_close(db) }
            return query(db)
        }.value
    }

    // MARK: - Deduplication

    private func deduplicated(_ links: [SuggestedLink]) -> [SuggestedLink] {
        // Sort newest-first so we keep the most-recently-visited URL for each domain.
        let sorted = links.sorted {
            ($0.lastVisited ?? .distantPast) > ($1.lastVisited ?? .distantPast)
        }
        var seenDomains = Set<String>()
        var result: [SuggestedLink] = []
        for link in sorted {
            guard !seenDomains.contains(link.domain) else { continue }
            seenDomains.insert(link.domain)
            result.append(link)
            if result.count == 50 { break }
        }
        return result
    }
}

private extension AXValue {
    static func from(point: CGPoint) -> AXValue? {
        var p = point
        return AXValueCreate(AXValueType.cgPoint, &p)
    }

    static func from(size: CGSize) -> AXValue? {
        var s = size
        return AXValueCreate(AXValueType.cgSize, &s)
    }

    // Read a CGPoint back from an opaque AXValue CFTypeRef.
    static func point(from ref: CFTypeRef) -> CGPoint? {
        guard CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        let axVal = ref as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axVal, .cgPoint, &point) else { return nil }
        return point
    }
}




// MARK: - CGRect min-size clamping

private extension CGRect {
    /// Expands the rect so it is at least as large as the AX window's minimum size.
    /// The origin stays fixed; only width/height grow if needed.
    func clamped(toMinSizeOf win: AXUIElement) -> CGRect {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, "AXMinSize" as CFString, &ref) == .success,
              let v = ref, CFGetTypeID(v) == AXValueGetTypeID() else { return self }
        var minSz = CGSize.zero
        AXValueGetValue(v as! AXValue, .cgSize, &minSz)
        guard minSz.width > 0 || minSz.height > 0 else { return self }
        return CGRect(
            x:      minX,
            y:      minY,
            width:  max(width,  minSz.width),
            height: max(height, minSz.height)
        )
    }
}

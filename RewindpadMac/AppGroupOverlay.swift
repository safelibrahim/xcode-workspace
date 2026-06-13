import AppKit
import SwiftUI
import ApplicationServices

// MARK: - Data

/// One overlay button slot — tracks which app is currently in that layout position.
struct OverlaySlot {
    let slotID: String
    let groupID: String
    var entry: AppGroupEntry
    /// Offset of the button cluster's bottom-left from the window's top-right corner
    /// (NS coords). Negative values move the cluster inside the window (the default).
    var relativeOffset: NSPoint
    let panel: SwitchOverlayPanel
}

// MARK: - Floating panel

final class SwitchOverlayPanel: NSPanel {
    // Panel hosts a cluster of up to three 32 × 32 glass buttons (+ / switch / −)
    // with ~12 pt of clear margin around it.  The margin serves two purposes:
    //   • The system window-server shadow (hasShadow = true) renders outside the
    //     panel bounds and needs space so it isn't cut off.
    //   • The hover scaleEffect expands a button slightly; the CALayer-backed
    //     hosting view clips anything that overflows the panel rect.
    static let height: CGFloat = 56

    /// Panel width for a given number of visible buttons — sized tightly so the
    /// transparent area never swallows clicks meant for the app window beneath
    /// (NSWindow hit-testing is rect-based, not pixel-alpha-based).
    static func width(buttons: Int) -> CGFloat {
        CGFloat(buttons) * 32 + CGFloat(max(buttons - 1, 0)) * 6 + 24
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0,
                                width: SwitchOverlayPanel.width(buttons: 3),
                                height: SwitchOverlayPanel.height),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        // .floating keeps the buttons above the scene's app windows — at .normal
        // level, clicking an app raised its window over the buttons and they vanished.
        level              = .floating
        isOpaque           = false
        backgroundColor    = .clear
        // hasShadow provides the system window-server drop shadow that renders *outside*
        // the panel bounds — unlike SwiftUI .shadow() which is clipped to the view rect.
        hasShadow          = true
        hidesOnDeactivate  = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
    }
}

// MARK: - Overlay Manager

/// Manages one +/switch/− button cluster per App Group window slot.
/// Lives on the main thread; the server owns a single shared instance.
final class AppGroupSwitchOverlayManager: NSObject {

    private var slots: [String: OverlaySlot] = [:]
    private var trackingTimer: Timer?
    private var moveObservers: [String: NSObjectProtocol] = [:]

    /// Weak back-reference so the manager can call `placeAppInFrame`.
    weak var server: RewindpadServer?

    // MARK: Public API

    /// Creates one overlay cluster per entry. Safe to call multiple times for the same
    /// groupID — old overlays are cleaned up first. `canAdd` controls whether the
    /// + button is shown (hidden when the layout has no more slot capacity).
    func showOverlays(for groupID: String, entries: [AppGroupEntry], canAdd: Bool = false) {
        removeOverlays(for: groupID)

        for entry in entries {
            let slotID = "\(groupID)-\(entry.id)"
            let panel  = SwitchOverlayPanel()

            let content = SlotButtonCluster(
                showsAdd:   canAdd,
                // Hide − when this is the only slot left: removing it would just
                // stop the scene, which the Stop control already does explicitly.
                showsRemove: entries.count > 1,
                onAdd:    { [weak self] in self?.showAddMenu(for: slotID) },
                onSwitch: { [weak self] in self?.showSwitchMenu(for: slotID) },
                onRemove: { [weak self] in
                    guard let self, let slot = self.slots[slotID] else { return }
                    self.server?.removeSlotApp(groupID: slot.groupID, entryID: slot.entry.id)
                }
            )
            let host = NSHostingController(rootView: content)
            host.view.wantsLayer = true
            host.view.layer?.backgroundColor = NSColor.clear.cgColor
            // Prevent the CALayer from clipping the hover scaleEffect overflow.
            host.view.layer?.masksToBounds = false
            let buttonCount = 1 + (canAdd ? 1 : 0) + (entries.count > 1 ? 1 : 0)
            panel.contentViewController = host
            panel.setContentSize(NSSize(width: SwitchOverlayPanel.width(buttons: buttonCount),
                                        height: SwitchOverlayPanel.height))

            slots[slotID] = OverlaySlot(
                slotID: slotID,
                groupID: groupID,
                entry: entry,
                relativeOffset: NSPoint(x: -2, y: -2),
                panel: panel
            )

            // Detect user drag so we can update the stored relative offset.
            let obs = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in self?.panelDidMove(slotID: slotID) }
            moveObservers[slotID] = obs
        }

        startTracking()
        updatePositions()   // position immediately on first pass
    }

    /// Hides and destroys all overlays belonging to `groupID`.
    func removeOverlays(for groupID: String) {
        let toRemove = slots.filter { $0.value.groupID == groupID }.map(\.key)
        toRemove.forEach { closeSlot(slotID: $0) }
        if slots.isEmpty { stopTracking() }
    }

    /// Hides and destroys every overlay across all groups.
    func removeAllOverlays() {
        Array(slots.keys).forEach { closeSlot(slotID: $0) }
        stopTracking()
    }

    /// When true, all show/orderFront calls are suppressed (workspace window is visible).
    var isSuppressed = false

    func hideAll() {
        isSuppressed = true
        slots.values.forEach { $0.panel.orderOut(nil) }
    }

    func showAll() {
        isSuppressed = false
        slots.values.forEach { $0.panel.orderFront(nil) }   // isSuppressed already cleared above
    }

    // MARK: - Private helpers

    private func closeSlot(slotID: String) {
        guard let slot = slots[slotID] else { return }
        slot.panel.orderOut(nil)
        if let obs = moveObservers[slotID] {
            NotificationCenter.default.removeObserver(obs)
            moveObservers.removeValue(forKey: slotID)
        }
        slots.removeValue(forKey: slotID)
    }

    // MARK: Tracking timer

    private func startTracking() {
        stopTracking()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.updatePositions()
        }
    }

    private func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    private var isUpdating = false

    private func updatePositions() {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }

        let screenH = NSScreen.screens.first?.frame.height ?? 800

        for (_, slot) in slots {
            guard let winNS = windowNSRect(for: slot.entry, screenHeight: screenH) else {
                if slot.panel.isVisible { slot.panel.orderOut(nil) }
                continue
            }
            let pw = slot.panel.frame.width
            let ph = slot.panel.frame.height
            let origin = NSPoint(
                x: winNS.maxX - pw + slot.relativeOffset.x,
                y: winNS.maxY - ph + slot.relativeOffset.y
            )
            slot.panel.setFrameOrigin(origin)
            // Only show panel if the workspace window is not suppressing overlays.
            if !slot.panel.isVisible, !isSuppressed { slot.panel.orderFrontRegardless() }
        }
    }

    // MARK: User drag

    private func panelDidMove(slotID: String) {
        guard var slot = slots[slotID] else { return }
        let screenH = NSScreen.screens.first?.frame.height ?? 800
        let pw = slot.panel.frame.width
        let ph = slot.panel.frame.height
        guard let winNS = windowNSRect(for: slot.entry, screenHeight: screenH) else { return }

        let panelOrigin = slot.panel.frame.origin
        var newOffset = NSPoint(
            x: panelOrigin.x - (winNS.maxX - pw),
            y: panelOrigin.y - (winNS.maxY - ph)
        )
        // Clamp so the cluster stays inside the window bounds.
        newOffset.x = max(-(winNS.width - pw), min(0, newOffset.x))
        newOffset.y = max(-(winNS.height - ph), min(0, newOffset.y))

        slot.relativeOffset = newOffset
        slots[slotID] = slot

        // Snap to clamped position
        let snapped = NSPoint(
            x: winNS.maxX - pw + newOffset.x,
            y: winNS.maxY - ph + newOffset.y
        )
        slot.panel.setFrameOrigin(snapped)
    }

    // MARK: AX window rect helper

    /// Returns the current window rect for `entry` in NS (bottom-left origin) screen coordinates.
    private func windowNSRect(for entry: AppGroupEntry, screenHeight: CGFloat) -> NSRect? {
        // Shortcuts run without a stable window to anchor an overlay to.
        if entry.isShortcut { return nil }

        // Match the running app by bundle ID first (robust to apps living in
        // ~/Applications, symlinks, or a path that differs from the stored
        // one), then fall back to an exact path match. This is what makes the
        // overlay buttons appear on EVERY launched window, not just the ones
        // whose recorded path happens to equal the running bundle path.
        let running = NSWorkspace.shared.runningApplications
        let app = running.first {
            !entry.bundleID.isEmpty && $0.bundleIdentifier == entry.bundleID
        } ?? running.first { $0.bundleURL?.path == entry.path }
        guard let app else { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // Prefer the app's main window; fall back to its first standard window.
        var win: AXUIElement?
        var mainRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &mainRef) == .success,
           let mv = mainRef, CFGetTypeID(mv) == AXUIElementGetTypeID() {
            win = (mv as! AXUIElement)
        }
        if win == nil {
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement] {
                win = windows.first
            }
        }
        guard let win else { return nil }

        var posRef:  CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)  == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute    as CFString, &sizeRef) == .success,
              let pv = posRef,  let sv = sizeRef,
              CFGetTypeID(pv) == AXValueGetTypeID(),
              CFGetTypeID(sv) == AXValueGetTypeID()
        else { return nil }

        var cgPos  = CGPoint.zero
        var cgSize = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &cgPos)   // safe: type ID verified above
        AXValueGetValue(sv as! AXValue, .cgSize,  &cgSize)

        // CG has y=0 at top of screen; NS has y=0 at bottom — convert.
        return NSRect(
            x: cgPos.x,
            y: screenHeight - cgPos.y - cgSize.height,
            width:  cgSize.width,
            height: cgSize.height
        )
    }

    // MARK: Running-app menu (shared by Switch and Add)

    /// Regular running apps not already occupying a slot in this group.
    private func candidateApps(excludingGroupOf slot: OverlaySlot) -> [NSRunningApplication] {
        let groupPaths = Set(slots.filter { $0.value.groupID == slot.groupID }
                                  .map(\.value.entry.path))
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { app in
                guard let path = app.bundleURL?.path else { return false }
                return !groupPaths.contains(path)
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func popUpMenu(_ menu: NSMenu, over slot: OverlaySlot) {
        if let contentView = slot.panel.contentView {
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: contentView.bounds.maxY + 4),
                in: contentView
            )
        }
    }

    private func menuItem(for app: NSRunningApplication,
                          action: Selector,
                          represented: Any) -> NSMenuItem {
        let item = NSMenuItem(
            title: app.localizedName ?? "Unknown",
            action: action,
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = represented
        if let icon = app.icon {
            let img = icon.copy() as! NSImage
            img.size = NSSize(width: 16, height: 16)
            item.image = img
        }
        return item
    }

    // MARK: Switch menu

    private func showSwitchMenu(for slotID: String) {
        guard let slot = slots[slotID] else { return }
        let candidates = candidateApps(excludingGroupOf: slot)
        guard !candidates.isEmpty else { return }

        let menu = NSMenu(title: "")
        let header = NSMenuItem(title: "Switch slot to…", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        for app in candidates {
            menu.addItem(menuItem(for: app,
                                  action: #selector(handleSwitchSelection(_:)),
                                  represented: SwitchMenuSelection(slotID: slotID, app: app)))
        }
        popUpMenu(menu, over: slot)
    }

    // MARK: Add menu

    private func showAddMenu(for slotID: String) {
        guard let slot = slots[slotID] else { return }
        // Hide apps whose minimum window size can't fit the remaining space —
        // offering them would only lead to a "can't add" dead end.
        let candidates = candidateApps(excludingGroupOf: slot).filter { app in
            server?.canAddToScene(groupID: slot.groupID, app: app) ?? true
        }
        guard !candidates.isEmpty else { return }

        let menu = NSMenu(title: "")
        let header = NSMenuItem(title: "Add app to Scene…", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        for app in candidates {
            menu.addItem(menuItem(for: app,
                                  action: #selector(handleAddSelection(_:)),
                                  represented: SwitchMenuSelection(slotID: slotID, app: app)))
        }
        popUpMenu(menu, over: slot)
    }

    @objc private func handleAddSelection(_ sender: NSMenuItem) {
        guard let sel  = sender.representedObject as? SwitchMenuSelection,
              let slot = slots[sel.slotID],
              let path = sel.app.bundleURL?.path
        else { return }

        let newEntry = AppGroupEntry(
            id:       UUID().uuidString,
            appName:  sel.app.localizedName ?? "Unknown",
            bundleID: sel.app.bundleIdentifier ?? "",
            path:     path
        )
        server?.addSlotApp(groupID: slot.groupID, newEntry: newEntry)
    }

    @objc private func handleSwitchSelection(_ sender: NSMenuItem) {
        guard let sel  = sender.representedObject as? SwitchMenuSelection,
              var slot = slots[sel.slotID]
        else { return }

        let app      = sel.app
        let screenH  = NSScreen.screens.first?.frame.height ?? 800

        guard let winNS = windowNSRect(for: slot.entry, screenHeight: screenH) else { return }

        // Convert NS → CG frame (what activateAndPlace expects).
        let cgFrame = CGRect(
            x: winNS.minX,
            y: screenH - winNS.maxY,
            width:  winNS.width,
            height: winNS.height
        )

        guard let path = app.bundleURL?.path else { return }
        let newEntry = AppGroupEntry(
            id:       UUID().uuidString,
            appName:  app.localizedName ?? "Unknown",
            bundleID: app.bundleIdentifier ?? "",
            path:     path
        )

        let groupID = slot.groupID   // capture before slot mutation below

        // Open the replacement app, then place it in the same layout slot.
        // Pass groupID so the placement loop is tied to the group's placement token —
        // this means stopAppGroup will immediately cancel it (same as original launch apps).
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.server?.placeAppInFrame(entry: newEntry, frame: cgFrame, groupID: groupID)
        }

        let oldPath = slot.entry.path

        // Optionally hide the app that was just swapped out.
        if let old = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == oldPath }) {
            old.hide()
        }

        // Update this slot to track the new app; reset cluster to default corner position.
        slot.entry = newEntry
        slot.relativeOffset = NSPoint(x: -10, y: -10)
        slots[sel.slotID] = slot

        // Keep the server's owned-path set in sync so stopAppGroup controls the right apps.
        // The switched-in app is now part of the session; the swapped-out app is no longer owned.
        server?.switchSlotApp(in: slot.groupID, oldPath: oldPath, newPath: path)
    }
}

// Carries the selection context through NSMenuItem's representedObject.
private final class SwitchMenuSelection: NSObject {
    let slotID: String
    let app: NSRunningApplication
    init(slotID: String, app: NSRunningApplication) {
        self.slotID = slotID; self.app = app
    }
}

// MARK: - SwiftUI button cluster  (liquid glass)

/// One round liquid-glass button used inside the slot cluster.
struct GlassCircleButton: View {
    let systemName: String
    let action: () -> Void
    var iconSize: CGFloat = 12

    @State private var isHovered = false
    @State private var isPressed = false

    private let buttonSize: CGFloat = 32

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                Circle()
                    .fill(Color.black.opacity(isHovered ? 0.18 : 0.32))
                Circle()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.12), location: 0.00),
                                .init(color: .clear,               location: 0.46),
                                .init(color: .black.opacity(0.14), location: 1.00),
                            ],
                            startPoint: .top,
                            endPoint:   .bottom
                        )
                    )
                Circle()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.45), location: 0.00),
                                .init(color: .white.opacity(0.12), location: 0.42),
                                .init(color: .clear,               location: 0.70),
                            ],
                            startPoint: UnitPoint(x: 0.50, y: 0.04),
                            endPoint:   UnitPoint(x: 0.50, y: 0.52)
                        )
                    )
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.70), location: 0.00),
                                .init(color: .white.opacity(0.22), location: 0.35),
                                .init(color: .white.opacity(0.05), location: 0.65),
                                .init(color: .black.opacity(0.10), location: 1.00),
                            ],
                            startPoint: .topLeading,
                            endPoint:   .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
                Image(systemName: systemName)
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.50), radius: 2, x: 0, y: 1)
            }
            .frame(width: buttonSize, height: buttonSize)
            .scaleEffect(isPressed ? 0.87 : isHovered ? 1.07 : 1.0)
            .brightness(isPressed ? -0.06 : 0)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isHovered)
        .animation(.spring(response: 0.13, dampingFraction: 0.78), value: isPressed)
    }
}

/// The +/switch/− cluster shown on each scene slot.
/// + adds an app (hidden when the layout is full), − removes this slot,
/// switch swaps this slot's app for another running app.
struct SlotButtonCluster: View {
    let showsAdd:    Bool
    let showsRemove: Bool
    let onAdd:    () -> Void
    let onSwitch: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if showsRemove {
                GlassCircleButton(systemName: "minus", action: onRemove, iconSize: 13)
            }
            if showsAdd {
                GlassCircleButton(systemName: "plus", action: onAdd, iconSize: 13)
            }
            GlassCircleButton(systemName: "square.stack.3d.down.forward.fill",
                              action: onSwitch, iconSize: 12)
        }
        .padding(.trailing, 12)
        // Fill the panel (sized per visible button count), hugging the
        // window's top-right corner.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

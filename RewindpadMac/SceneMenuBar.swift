// SceneMenuBar.swift — Workspace Menu Bar Panel

import SwiftUI
import Combine
import Carbon
import AppKit

extension Notification.Name {
    /// Asks the main window's Workspaces view to open the creator modal.
    static let openWorkspaceCreator = Notification.Name("openWorkspaceCreator")
}

// MARK: - Root ─────────────────────────────────────────────────────────────────

struct SceneMenuBarView: View {
    @ObservedObject var server: RewindpadServer

    @State private var now        = Date()
    @State private var startTimes: [String: Date] = [:]

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var activeIDs: Set<String> { Set(server.activeAppGroups.keys) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 16)
            if server.appGroups.isEmpty {
                emptyState
            } else {
                sceneGrid.padding(12)
            }
            Divider().padding(.horizontal, 16)
            footer
        }
        .frame(width: 340)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
        .onAppear {
            // Menu bar extra opened → hide the workspace window
            NotificationCenter.default.post(name: .menuBarExtraDidOpen, object: nil)
        }
        .onReceive(tick) { now = $0 }
        .onChange(of: activeIDs) { _, ids in
            for id in ids where startTimes[id] == nil { startTimes[id] = .init() }
            startTimes = startTimes.filter { ids.contains($0.key) }
        }
    }

    // MARK: Header ─────────────────────────────────────────────────────────────

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white)
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                Image("WorkspaceIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 24)
                    .foregroundStyle(.blue)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text("Workspace")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Your environments")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button { toggleMainWindow() } label: {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.08))
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: Empty state ─────────────────────────────────────────────────────────

    /// Shown when no workspaces exist yet — explains what a workspace is and
    /// offers a clear CTA into the editor.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.split.2x2")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)

            VStack(spacing: 3) {
                Text("No workspaces yet")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Text("Group your apps into one-click work environments.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                openMainWindow()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Create Workspace")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
    }

    /// Brings the main Workspace window to the front, then opens the
    /// workspace-creator modal directly — the popover CTA drops the user
    /// straight into creating, not just onto the window.
    private func openMainWindow() {
        closeMenuBar()
        // Flag first: if the Workspaces view isn't mounted yet (another sidebar
        // tab was selected), it opens the creator from this flag on appear.
        server.pendingOpenWorkspaceCreator = true
        if let w = NSApp.windows.first(where: { $0.title == "Workspace" }) {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        // Let the window come on screen, then switch to the Workspaces tab and
        // (if it was already mounted) open the creator directly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NotificationCenter.default.post(name: .openWorkspaceCreator, object: nil)
        }
    }

    // MARK: Scene grid ──────────────────────────────────────────────────────────

    private var sceneGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
            spacing: 10
        ) {
            ForEach(server.appGroups) { group in
                SceneTile(
                    group:    group,
                    isActive: activeIDs.contains(group.id),
                    onTap: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            if activeIDs.contains(group.id) {
                                server.stopAppGroup(id: group.id)
                            } else {
                                server.launchAppGroup(id: group.id)
                                closeMenuBar()
                            }
                        }
                    }
                )
            }
        }
    }

    // MARK: Footer ──────────────────────────────────────────────────────────────

    private var footer: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "iphone")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(server.isConnected ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.isConnected ? (server.connectedDeviceName ?? "iPhone") : "iPhone")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(server.isConnected ? "Connected" : "Not connected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().frame(height: 28)

            Button { NSApplication.shared.terminate(nil) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .medium))
                    Text("Quit")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    // MARK: Helpers ────────────────────────────────────────────────────────────

    private func closeMenuBar() {
        // Close the MenuBarExtra popover window immediately.
        // The MenuBarExtra window is the only NSPanel-style window whose title contains
        // an empty string and whose delegate is nil — find it by style mask.
        for window in NSApp.windows {
            if window.className.contains("NSStatusBarWindow") ||
               window.className.contains("_NSPopoverWindow") ||
               (window.styleMask.contains(.nonactivatingPanel) && window.title.isEmpty && window.isVisible) {
                window.orderOut(nil)
            }
        }
    }

    private func toggleMainWindow() {
        guard let w = NSApp.windows.first(where: { $0.title == "Workspace" }) else { return }
        if w.isVisible {
            w.orderOut(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .openScenesTab, object: nil)
        }
    }
}

// MARK: - Scene tile ──────────────────────────────────────────────────────────

private struct SceneTile: View {
    let group:    AppGroup
    let isActive: Bool
    let onTap:    () -> Void

    @State private var isHovered = false
    private var icon: String { group.icon.isEmpty ? "rectangle.3.group" : group.icon }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(isActive ? .white : .secondary)
                    .frame(width: 30, height: 30)
                    .symbolEffect(.bounce, value: isActive)

                Spacer(minLength: 12)

                Text(group.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isActive ? .white : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(isActive ? "On" : "\(group.apps.count) App\(group.apps.count == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? .white.opacity(0.75) : .secondary)
                    .padding(.top, 2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .aspectRatio(1, contentMode: .fit)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isActive
                          ? AnyShapeStyle(Color.blue)
                          : AnyShapeStyle(Color.primary.opacity(isHovered ? 0.10 : 0.06)))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.14), value: isHovered)
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: isActive)
    }
}

// MARK: - Notification name

extension Notification.Name {
    static let openScenesTab = Notification.Name("rw.openScenesTab")
}

// MARK: - Global hotkey manager (⌘⌥1–⌘⌥9) ────────────────────────────────────

final class SceneHotkeyManager {
    static let shared = SceneHotkeyManager()
    private var registeredHotkeys: [Int: EventHotKeyRef] = [:]
    private var indexToGroupID:    [Int: String]         = [:]
    private var eventHandler:       EventHandlerRef?
    private init() { installHandler() }

    private let keyCodes: [Int: UInt32] = [
        1:18, 2:19, 3:20, 4:21, 5:23, 6:22, 7:26, 8:28, 9:25
    ]

    func sync(with groups: [AppGroup]) {
        unregisterAll()
        for group in groups {
            guard let idx = group.hotkeyIndex, (1...9).contains(idx),
                  let kc  = keyCodes[idx] else { continue }
            var hkID = EventHotKeyID()
            hkID.signature = OSType(truncatingIfNeeded: 0x52574D42)
            hkID.id        = UInt32(idx)
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(kc, UInt32(cmdKey | optionKey),
                                   hkID, GetEventDispatcherTarget(), 0, &ref) == noErr,
               let r = ref {
                registeredHotkeys[idx] = r; indexToGroupID[idx] = group.id
            }
        }
    }

    private func unregisterAll() {
        registeredHotkeys.values.forEach { UnregisterEventHotKey($0) }
        registeredHotkeys.removeAll(); indexToGroupID.removeAll()
    }

    private func installHandler() {
        var et = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                               eventKind:  UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(),
            { _, ev, _ -> OSStatus in SceneHotkeyManager.shared.fire(ev); return noErr },
            1, &et, nil, &eventHandler)
    }

    private func fire(_ event: EventRef?) {
        guard let event else { return }
        var hkID = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject),
                          EventParamType(typeEventHotKeyID), nil,
                          MemoryLayout<EventHotKeyID>.size, nil, &hkID)
        guard let gid = indexToGroupID[Int(hkID.id)] else { return }
        DispatchQueue.main.async { RewindpadServer.shared.launchAppGroup(id: gid) }
    }

    deinit { unregisterAll() }
}

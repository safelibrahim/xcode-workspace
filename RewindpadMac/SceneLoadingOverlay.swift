import AppKit
import Combine
import SwiftUI

// MARK: - Loading overlay panel

/// Full-screen dark shield shown while a scene launches — apps opening and
/// windows snapping into place look chaotic for a moment; this covers the
/// shuffle with a calm branded loading state, then fades away.
final class SceneLoadingOverlayManager {

    private var panel: NSPanel?
    private var dismissTask: DispatchWorkItem?
    private var shownAt: Date?
    /// The shield is always visible at least this long, so the loader never
    /// just blinks even when apps settle instantly.
    private let minimumDisplayTime: TimeInterval = 2.0

    /// Shows the overlay immediately and auto-dismisses after `duration` seconds.
    func show(sceneName: String, icon: String, screen: NSScreen,
              duration: TimeInterval = 2.0) {
        dismissTask?.cancel()
        panel?.orderOut(nil)

        let p = NSPanel(
            contentRect: screen.frame,
            styleMask:   [.nonactivatingPanel, .borderless],
            backing:     .buffered,
            defer:       false
        )
        // One step above the divider/button overlays so the shield covers everything.
        p.level              = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        p.isOpaque           = false
        p.backgroundColor    = .clear
        p.hasShadow          = false
        // NSPanel default is true — the shield would vanish the instant the
        // first scene app activates and Rewindpad deactivates.
        p.hidesOnDeactivate  = false
        p.ignoresMouseEvents = true     // purely visual — never trap a click
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let host = NSHostingController(
            rootView: SceneLoadingView(sceneName: sceneName, icon: icon)
        )
        host.view.frame = NSRect(origin: .zero, size: screen.frame.size)
        p.contentViewController = host
        p.setFrame(screen.frame, display: true)

        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 1
        }

        panel = p
        shownAt = Date()

        let task = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }

    /// Fades the overlay out and releases it. Dismissals arriving before the
    /// minimum display time are deferred until it has elapsed.
    func dismiss() {
        if let shownAt {
            let remaining = minimumDisplayTime - Date().timeIntervalSince(shownAt)
            if remaining > 0 {
                dismissTask?.cancel()
                let task = DispatchWorkItem { [weak self] in self?.dismiss() }
                dismissTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: task)
                return
            }
        }
        dismissTask?.cancel()
        dismissTask = nil
        shownAt = nil
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.40
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }
}

// MARK: - SwiftUI content

private struct SceneLoadingView: View {
    let sceneName: String
    let icon: String

    @State private var spinning = false
    @State private var appeared = false

    var body: some View {
        ZStack {
            // Dark dimming layer
            Color.black.opacity(0.90)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                CubesLoader()
                    .frame(width: 84, height: 84)

                VStack(spacing: 4) {
                    Text(sceneName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Setting up your Scene…")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .scaleEffect(appeared ? 1.0 : 0.92)
            .opacity(appeared ? 1.0 : 0)
        }
        .onAppear {
            spinning = true
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                appeared = true
            }
        }
    }
}

// MARK: - Cubes loader

/// Sliding-puzzle cube loader: three outlined squares in a 2×2 grid; each
/// tick the cube beside the empty slot slides into it, cycling forever.
private struct CubesLoader: View {
    @State private var cubeSlots: [Int] = [0, 1, 2]   // slot index per cube
    @State private var hole = 3                        // the empty slot

    private let cube: CGFloat = 30
    private let gap: CGFloat  = 9

    // Slot centers in a 2×2 grid, clockwise: TL, TR, BR, BL.
    private func center(of slot: Int, in size: CGSize) -> CGPoint {
        let span = cube + gap
        let originX = (size.width  - span) / 2
        let originY = (size.height - span) / 2
        switch slot {
        case 0:  return CGPoint(x: originX,        y: originY)
        case 1:  return CGPoint(x: originX + span, y: originY)
        case 2:  return CGPoint(x: originX + span, y: originY + span)
        default: return CGPoint(x: originX,        y: originY + span)
        }
    }

    var body: some View {
        GeometryReader { geo in
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.white.opacity(0.9), lineWidth: 3.5)
                    .frame(width: cube, height: cube)
                    .position(center(of: cubeSlots[i], in: geo.size))
            }
        }
        // Render-independent loop — re-renders can't restart or stall it,
        // and it ends automatically when the view goes away.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                // The cube sitting counterclockwise of the hole slides into it.
                let source = (hole + 1) % 4
                guard let mover = cubeSlots.firstIndex(of: source) else { continue }
                withAnimation(.easeInOut(duration: 0.22)) {
                    cubeSlots[mover] = hole
                }
                hole = source
            }
        }
        .accessibilityLabel("Loading")
    }
}

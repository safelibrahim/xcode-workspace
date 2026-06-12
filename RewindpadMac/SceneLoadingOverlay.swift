import AppKit
import SwiftUI

// MARK: - Loading overlay panel

/// Full-screen dark shield shown while a scene launches — apps opening and
/// windows snapping into place look chaotic for a moment; this covers the
/// shuffle with a calm branded loading state, then fades away.
final class SceneLoadingOverlayManager {

    private var panel: NSPanel?
    private var dismissTask: DispatchWorkItem?

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

        let task = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }

    /// Fades the overlay out and releases it.
    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
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
            Color.black.opacity(0.62)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    // Spinner ring around the scene icon
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 3)
                        .frame(width: 84, height: 84)
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(
                            Color.white.opacity(0.9),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .frame(width: 84, height: 84)
                        .rotationEffect(.degrees(spinning ? 360 : 0))
                        .animation(
                            .linear(duration: 1.0).repeatForever(autoreverses: false),
                            value: spinning
                        )

                    Image(systemName: icon)
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.white)
                }

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

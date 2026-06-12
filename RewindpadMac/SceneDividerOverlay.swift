import AppKit

// MARK: - Scene Divider Overlay
//
// A non-interactive overlay that sits exactly on the native macOS tiling
// divider.  It never intercepts mouse events — all drag interaction goes to
// the system divider underneath.
//
// Two visual states:
//   • Idle   — 1 px accent line at 12 % opacity.  Always visible so the user
//              can find the divider without hunting.
//   • Active — 3 px accent line at 80 % opacity with a soft glow, spring-
//              animated in/out as the divider is being dragged.
//
// On scene launch the panel pulses once (flash→idle) so the user's eye is
// drawn to the divider location.

// MARK: - DividerPanel

final class DividerPanel: NSPanel {

    // CALayer that visually represents the line (stays centered in the panel).
    private let line = CALayer()
    // Hide timer: fires ~0.45 s after the last drag event to return to idle.
    private var idleTimer: Timer?

    // MARK: Init

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        level              = .floating
        isOpaque           = false
        backgroundColor    = .clear
        hasShadow          = false
        hidesOnDeactivate  = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let host = NSView()
        host.wantsLayer = true
        contentView = host

        line.anchorPoint   = CGPoint(x: 0.5, y: 0.5)
        line.shadowOffset  = .zero
        line.shadowRadius  = 0
        line.shadowOpacity = 0
        host.layer?.addSublayer(line)
    }

    // MARK: Placement

    struct Spec {
        let isVertical:    Bool     // the LINE runs vertically (left/right boundary)
        let positionRatio: Double   // group split ratio to use
        let invertedRatio: Bool     // position = (1 − ratio) × screen dimension
        let startFraction: Double   // 0…1 start along the hint length (screen fraction)
        let endFraction:   Double   // 0…1 end along the hint length
    }

    private var spec:        Spec?
    private var targetScreen: NSScreen?

    func configure(spec: Spec, screen: NSScreen) {
        self.spec         = spec
        self.targetScreen = screen
        reframe()
    }

    private func reframe() {
        guard let spec, let targetScreen else { return }
        let screen = targetScreen
        let sf   = screen.visibleFrame
        let thick: CGFloat = 3          // panel / line thickness

        let fraction = CGFloat(spec.invertedRatio ? 1 - spec.positionRatio : spec.positionRatio)

        let panelRect: NSRect
        if spec.isVertical {
            let x = sf.minX + fraction * sf.width
            panelRect = NSRect(x: x - thick / 2,
                               y: sf.minY + CGFloat(spec.startFraction) * sf.height,
                               width: thick,
                               height: sf.height * CGFloat(spec.endFraction - spec.startFraction))
        } else {
            let y = sf.minY + fraction * sf.height
            panelRect = NSRect(x: sf.minX + CGFloat(spec.startFraction) * sf.width,
                               y: y - thick / 2,
                               width: sf.width * CGFloat(spec.endFraction - spec.startFraction),
                               height: thick)
        }
        setFrame(panelRect, display: false)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.frame           = contentView!.bounds
        line.cornerRadius    = thick / 2
        line.backgroundColor = NSColor.controlAccentColor.cgColor
        line.shadowColor     = NSColor.controlAccentColor.cgColor
        CATransaction.commit()
    }

    // MARK: State transitions

    /// Pulse in on scene launch, then settle to the idle resting state.
    func launchPulse() {
        alphaValue = 0
        orderFrontRegardless()

        // Flash bright
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0.9
        } completionHandler: {
            // Spring back to idle glow
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration   = 0.45
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().alphaValue = 0.12
            } completionHandler: {
                self.applyIdleLayer()
            }
        }
    }

    /// Called on every drag event — bring the line to full brightness.
    func activateForDrag() {
        idleTimer?.invalidate()
        applyActiveLayer()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0.82
        }
        // Schedule return to idle if no further events arrive.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.returnToIdle()
        }
    }

    private func returnToIdle() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 0.12
        } completionHandler: {
            self.applyIdleLayer()
        }
    }

    // MARK: Layer appearance helpers

    private func applyIdleLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.shadowOpacity = 0
        CATransaction.commit()
    }

    private func applyActiveLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.shadowOpacity = 0.65
        line.shadowRadius  = 5
        CATransaction.commit()
    }

    // MARK: Lifecycle

    func hide() {
        idleTimer?.invalidate()
        orderOut(nil)
    }
}

// MARK: - SceneDividerOverlayManager

final class SceneDividerOverlayManager {

    weak var server: RewindpadServer?
    var isSuppressed = false

    private var panels: [String: [DividerPanel]] = [:]

    // MARK: Show / remove

    func showDividers(for groupID: String, group: AppGroup, screen: NSScreen,
                      slotCount: Int? = nil) {
        guard !isSuppressed else { return }
        removeDividers(for: groupID)

        let count = slotCount ?? group.apps.count
        let specs = hintSpecs(for: group, slotCount: count)
        guard !specs.isEmpty else { return }

        var newPanels: [DividerPanel] = []
        for spec in specs {
            let panel = DividerPanel()
            panel.configure(spec: spec, screen: screen)
            panel.launchPulse()
            newPanels.append(panel)
        }
        panels[groupID] = newPanels
    }

    func removeDividers(for groupID: String) {
        panels[groupID]?.forEach { $0.hide() }
        panels.removeValue(forKey: groupID)
    }

    func removeAllDividers() {
        panels.values.flatMap { $0 }.forEach { $0.hide() }
        panels.removeAll()
    }

    func hideAll() {
        panels.values.flatMap { $0 }.forEach { $0.hide() }
    }

    func showAll() {
        // Panels are always present while active — nothing to re-show.
    }

    // MARK: Drag feedback

    /// Called on every AX resize event from a MinSizeWatcher while the user
    /// drags the native tiling divider.  Brings the overlay to its active
    /// (bright) state for the duration of the gesture.
    func notifyDrag(for groupID: String) {
        panels[groupID]?.forEach { $0.activateForDrag() }
    }

    // MARK: Spec builder

    private func hintSpecs(for group: AppGroup, slotCount: Int) -> [DividerPanel.Spec] {
        guard slotCount >= 2 else { return [] }
        let r  = group.effectiveSplitRatio
        let r2 = group.effectiveSplitRatioSecondary

        switch group.layout {

        case .split1x1:
            return [.init(isVertical: true, positionRatio: r, invertedRatio: false,
                          startFraction: 0, endFraction: 1)]

        case .split1x1v:
            return [.init(isVertical: false, positionRatio: r, invertedRatio: true,
                          startFraction: 0, endFraction: 1)]

        case .split1x2:
            var s: [DividerPanel.Spec] = [
                .init(isVertical: true, positionRatio: r, invertedRatio: false,
                      startFraction: 0, endFraction: 1)
            ]
            if slotCount >= 3 {
                s.append(.init(isVertical: false, positionRatio: r2, invertedRatio: true,
                               startFraction: r, endFraction: 1))
            }
            return s

        case .split2x1:
            var s: [DividerPanel.Spec] = [
                .init(isVertical: true, positionRatio: r, invertedRatio: true,
                      startFraction: 0, endFraction: 1)
            ]
            if slotCount >= 3 {
                s.append(.init(isVertical: false, positionRatio: r2, invertedRatio: true,
                               startFraction: 0, endFraction: 1 - r))
            }
            return s

        case .split1x2h:
            var s: [DividerPanel.Spec] = [
                .init(isVertical: false, positionRatio: r, invertedRatio: true,
                      startFraction: 0, endFraction: 1)
            ]
            if slotCount >= 3 {
                s.append(.init(isVertical: true, positionRatio: r2, invertedRatio: false,
                               startFraction: 0, endFraction: 1 - r))
            }
            return s

        case .grid2x2:
            return [
                .init(isVertical: true,  positionRatio: r,  invertedRatio: false,
                      startFraction: 0, endFraction: 1),
                .init(isVertical: false, positionRatio: r2, invertedRatio: true,
                      startFraction: 0, endFraction: 1),
            ]
        }
    }
}

// ScreenCompatibility.swift
// Analyses whether the chosen layout + apps fit on the current Mac screen.
// Purely informational — never blocks saving.

import AppKit
import SwiftUI

// MARK: - Min-size registry

enum AppMinSizeRegistry {
    static let sizes: [String: CGSize] = [
        "com.apple.iBooksX":           CGSize(width: 960,  height: 600),
        "com.apple.Music":             CGSize(width: 940,  height: 602),
        "com.apple.TV":                CGSize(width: 960,  height: 600),
        "com.apple.podcasts":          CGSize(width: 940,  height: 600),
        "com.apple.Photos":            CGSize(width: 900,  height: 600),
        "com.apple.iCal":              CGSize(width: 694,  height: 512),
        "com.apple.reminders":         CGSize(width: 320,  height: 400),
        "com.apple.Notes":             CGSize(width: 400,  height: 400),
        "com.apple.mail":              CGSize(width: 600,  height: 400),
        "com.apple.AddressBook":       CGSize(width: 500,  height: 400),
        "com.apple.MobileSMS":         CGSize(width: 480,  height: 400),
        "com.apple.FaceTime":          CGSize(width: 480,  height: 420),
        "com.apple.Maps":              CGSize(width: 800,  height: 600),
        "com.apple.Home":              CGSize(width: 800,  height: 500),
        "com.apple.News":              CGSize(width: 900,  height: 600),
        "com.apple.Stocks":            CGSize(width: 700,  height: 500),
        "com.apple.freeform":          CGSize(width: 600,  height: 400),
        "com.apple.Terminal":          CGSize(width: 400,  height: 200),
        "com.apple.finder":            CGSize(width: 400,  height: 270),
        "com.apple.dt.Xcode":          CGSize(width: 900,  height: 600),
        "com.spotify.client":          CGSize(width: 940,  height: 600),
        "com.microsoft.VSCode":        CGSize(width: 400,  height: 300),
        "com.microsoft.Excel":         CGSize(width: 600,  height: 400),
        "com.microsoft.Word":          CGSize(width: 600,  height: 400),
        "com.microsoft.Powerpoint":    CGSize(width: 600,  height: 400),
        "com.microsoft.teams2":        CGSize(width: 800,  height: 560),
        "com.tinyspeck.slackmacgap":   CGSize(width: 600,  height: 400),
        "com.figma.desktop":           CGSize(width: 800,  height: 500),
        "com.apple.AppStore":          CGSize(width: 1000, height: 700),
        "com.notion.id":               CGSize(width: 600,  height: 400),
        "com.apple.Safari":            CGSize(width: 400,  height: 300),
        "com.google.Chrome":           CGSize(width: 400,  height: 300),
        "com.brave.Browser":           CGSize(width: 400,  height: 300),
        "org.mozilla.firefox":         CGSize(width: 400,  height: 300),
        "com.microsoft.edgemac":       CGSize(width: 400,  height: 300),
        "company.thebrowser.Browser":  CGSize(width: 460,  height: 320),
        "com.hnc.Discord":             CGSize(width: 940,  height: 500),
        "net.whatsapp.WhatsApp":       CGSize(width: 760,  height: 580),
        "ru.keepcoder.Telegram":       CGSize(width: 380,  height: 450),
        "us.zoom.xos":                 CGSize(width: 660,  height: 460),
        "com.openai.chat":             CGSize(width: 480,  height: 400),
        "md.obsidian":                 CGSize(width: 480,  height: 320),
        "com.linear":                  CGSize(width: 600,  height: 400),
        "com.apple.Preview":           CGSize(width: 400,  height: 300),
        "com.apple.iWork.Pages":       CGSize(width: 600,  height: 450),
        "com.apple.iWork.Numbers":     CGSize(width: 600,  height: 450),
        "com.apple.iWork.Keynote":     CGSize(width: 700,  height: 500),
        "com.apple.SystemPreferences": CGSize(width: 700,  height: 500),
        "com.apple.systempreferences": CGSize(width: 700,  height: 500),
    ]

    static func minSize(for entry: AppGroupEntry) -> CGSize? {
        if entry.isShortcut { return nil }
        if let exact = sizes[entry.bundleID] { return exact }
        // Bundle IDs vary in casing across app versions (com.figma.Desktop
        // vs com.figma.desktop) — fall back to a case-insensitive match.
        let lower = entry.bundleID.lowercased()
        return sizes.first { $0.key.lowercased() == lower }?.value
    }
}

// MARK: - Warning model

struct CompatibilityIssue: Identifiable {
    let id = UUID()
    let appName: String
    let slotIndex: Int          // 0-based index in the layout slot order
    let slotLabel: String
    let dimension: Dimension
    let slotSize: CGFloat
    let minSize: CGFloat

    enum Dimension { case width, height }

    /// Short chip label: "Books · too narrow"
    var shortMessage: String {
        let suffix = dimension == .width ? "too narrow" : "too short"
        return "\(appName) · \(suffix)"
    }

    /// Detail shown below the chip: "needs 960 pt, gets ~740 pt"
    var detailMessage: String {
        let dim = dimension == .width ? "wide" : "tall"
        return "needs \(Int(minSize.rounded())) pt, gets ~\(Int(slotSize.rounded())) pt \(dim)"
    }
}

// MARK: - Checker

struct ScreenCompatibilityChecker {

    static func check(
        apps: [AppGroupEntry],
        layout: AppGroupLayout,
        splitRatio: Double,
        splitRatioSecondary: Double,
        screen: NSScreen,
        minSize: (AppGroupEntry) -> CGSize? = { AppMinSizeRegistry.minSize(for: $0) }
    ) -> [CompatibilityIssue] {

        let slots = apps.filter { !($0.isShortcut && $0.shortcutRunMode == .background) }
        guard slots.count >= 2 else { return [] }

        let v  = screen.visibleFrame
        let W  = v.width, H = v.height
        let r  = max(0.10, min(0.90, CGFloat(splitRatio)))
        let r2 = max(0.10, min(0.90, CGFloat(splitRatioSecondary)))

        typealias SI = (entry: AppGroupEntry, label: String, slotIdx: Int, w: CGFloat, h: CGFloat)
        var slotInfos: [SI] = []

        switch layout {
        case .split1x1:
            if slots.count > 0 { slotInfos.append((slots[0], "left",         0, W * r,       H)) }
            if slots.count > 1 { slotInfos.append((slots[1], "right",        1, W * (1-r),   H)) }

        case .split1x1v:
            if slots.count > 0 { slotInfos.append((slots[0], "top",          0, W, H * r      )) }
            if slots.count > 1 { slotInfos.append((slots[1], "bottom",       1, W, H * (1-r)  )) }

        case .split1x2:
            let mW = W * r; let sW = W - mW
            if slots.count > 0 { slotInfos.append((slots[0], "left",         0, mW, H          )) }
            if slots.count > 1 { slotInfos.append((slots[1], "top-right",    1, sW, H * r2     )) }
            if slots.count > 2 { slotInfos.append((slots[2], "btm-right",    2, sW, H * (1-r2) )) }

        case .split2x1:
            let mW = W * r; let sW = W - mW
            if slots.count > 0 { slotInfos.append((slots[0], "right",        0, mW, H          )) }
            if slots.count > 1 { slotInfos.append((slots[1], "top-left",     1, sW, H * r2     )) }
            if slots.count > 2 { slotInfos.append((slots[2], "btm-left",     2, sW, H * (1-r2) )) }

        case .split1x2h:
            let mH = H * r; let sH = H - mH
            if slots.count > 0 { slotInfos.append((slots[0], "top",          0, W,           mH)) }
            if slots.count > 1 { slotInfos.append((slots[1], "btm-left",     1, W * r2,      sH)) }
            if slots.count > 2 { slotInfos.append((slots[2], "btm-right",    2, W * (1-r2),  sH)) }

        case .grid2x2:
            let cW0 = W*r; let cW1 = W-cW0; let rH0 = H*r2; let rH1 = H-rH0
            let labels = ["top-left","top-right","btm-left","btm-right"]
            let dims: [(CGFloat,CGFloat)] = [(cW0,rH0),(cW1,rH0),(cW0,rH1),(cW1,rH1)]
            for i in 0..<min(slots.count,4) {
                slotInfos.append((slots[i], labels[i], i, dims[i].0, dims[i].1))
            }
        }

        var issues: [CompatibilityIssue] = []
        for info in slotInfos {
            guard let minSz = minSize(info.entry) else { continue }
            if info.w < minSz.width - 1 {
                issues.append(CompatibilityIssue(appName: info.entry.appName,
                    slotIndex: info.slotIdx, slotLabel: info.label,
                    dimension: .width,  slotSize: info.w,  minSize: minSz.width))
            }
            if info.h < minSz.height - 1 {
                issues.append(CompatibilityIssue(appName: info.entry.appName,
                    slotIndex: info.slotIdx, slotLabel: info.label,
                    dimension: .height, slotSize: info.h,  minSize: minSz.height))
            }
        }
        return issues
    }

    /// Returns a better layout that eliminates (or reduces) compatibility issues,
    /// or `nil` if no alternative layout improves things.
    ///
    /// Unlike the simple per-layout default-ratio check, this sweeps a wide range
    /// of primary and secondary split ratios for every candidate layout, so it finds
    /// improvements even when the default ratio is the issue (e.g. Books needs 960 px
    /// on a 1440 px screen — split1x2 at 0.6 fails, but at 0.68 it works fine).
    static func suggestBetterLayout(
        currentLayout: AppGroupLayout,
        apps: [AppGroupEntry],
        screen: NSScreen
    ) -> AppGroupLayout? {

        // Ratio sweep: 0.15 → 0.85 in 0.05 steps = 15 values
        let primaryRatios:   [Double] = stride(from: 0.15, through: 0.85, by: 0.05).map { $0 }
        let secondaryRatios: [Double] = [0.40, 0.50, 0.60]

        /// Minimum achievable issue count for a layout across all ratio combinations.
        func bestCount(for layout: AppGroupLayout) -> Int {
            var best = Int.max
            for r in primaryRatios {
                for r2 in secondaryRatios {
                    let n = check(apps: apps, layout: layout,
                                  splitRatio: r, splitRatioSecondary: r2,
                                  screen: screen).count
                    if n < best { best = n }
                    if best == 0 { return 0 }   // can't do better — short-circuit
                }
            }
            return best == Int.max ? 0 : best
        }

        // Current layout's best-possible outcome across all ratios.
        let currentBest = bestCount(for: currentLayout)
        guard currentBest > 0 else { return nil }   // current layout already has a valid ratio — no suggestion needed

        // Find the candidate layout with the lowest best-possible issue count.
        var suggestedLayout: AppGroupLayout? = nil
        var suggestedBest   = currentBest      // must strictly beat the current layout

        // Prefer layouts that fully eliminate all issues (count == 0).
        // Among equally-scoring options, prefer: Equal > Focus > Grid.
        let preferenceOrder: [AppGroupLayout] = [
            .split1x1, .split1x1v,
            .split1x2, .split2x1, .split1x2h,
            .grid2x2
        ]
        for candidate in preferenceOrder where candidate != currentLayout {
            let count = bestCount(for: candidate)
            if count < suggestedBest {
                suggestedBest   = count
                suggestedLayout = candidate
            }
            if suggestedBest == 0 { break }   // found a perfect fix — stop searching
        }

        return suggestedLayout
    }
}

// MARK: - Layout diagram with highlighted slots

/// Like LayoutIconView but paints problem slots in orange.
struct CompatibilityDiagram: View {
    let layout: AppGroupLayout
    let badSlots: Set<Int>          // slot indices that have issues
    var size: CGFloat = 44

    var body: some View {
        Canvas { ctx, s in
            let gap: CGFloat = max(1, s.width * 0.07)
            let r: CGFloat   = 2.5

            func fill(_ rect: CGRect, slotIdx: Int, baseAlpha: CGFloat) {
                let isBad = badSlots.contains(slotIdx)
                if isBad {
                    // Problem slot: vivid orange fill + bright border
                    ctx.fill(Path(roundedRect: rect, cornerRadius: r),
                             with: .color(Color(red: 0.95, green: 0.28, blue: 0.28).opacity(0.85)))
                    ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: r),
                               with: .color(Color(red: 0.95, green: 0.28, blue: 0.28)), lineWidth: 1)
                } else {
                    // Normal slot: white at reduced opacity — visible on dark bg
                    ctx.fill(Path(roundedRect: rect, cornerRadius: r),
                             with: .color(Color.white.opacity(baseAlpha)))
                }
            }

            switch layout {
            case .split1x1:
                let hw = (s.width - gap) / 2
                fill(CGRect(x: 0,      y: 0, width: hw,             height: s.height), slotIdx: 0, baseAlpha: 0.80)
                fill(CGRect(x: hw+gap, y: 0, width: s.width-hw-gap, height: s.height), slotIdx: 1, baseAlpha: 0.45)

            case .split1x1v:
                let hh = (s.height - gap) / 2
                fill(CGRect(x: 0, y: 0,      width: s.width, height: hh),             slotIdx: 0, baseAlpha: 0.80)
                fill(CGRect(x: 0, y: hh+gap, width: s.width, height: s.height-hh-gap), slotIdx: 1, baseAlpha: 0.45)

            case .split1x2:
                let mw = (s.width * 0.58).rounded()
                let sw = s.width - mw - gap
                let hh = (s.height - gap) / 2
                fill(CGRect(x: 0,      y: 0,      width: mw, height: s.height),            slotIdx: 0, baseAlpha: 0.80)
                fill(CGRect(x: mw+gap, y: 0,      width: sw, height: hh),                  slotIdx: 1, baseAlpha: 0.50)
                fill(CGRect(x: mw+gap, y: hh+gap, width: sw, height: s.height-hh-gap),     slotIdx: 2, baseAlpha: 0.30)

            case .split2x1:
                let mw = (s.width * 0.58).rounded()
                let sw = s.width - mw - gap
                let hh = (s.height - gap) / 2
                fill(CGRect(x: sw+gap, y: 0,      width: mw, height: s.height),            slotIdx: 0, baseAlpha: 0.80)
                fill(CGRect(x: 0,      y: 0,      width: sw, height: hh),                  slotIdx: 1, baseAlpha: 0.50)
                fill(CGRect(x: 0,      y: hh+gap, width: sw, height: s.height-hh-gap),     slotIdx: 2, baseAlpha: 0.30)

            case .split1x2h:
                let mh = (s.height * 0.58).rounded()
                let sh = s.height - mh - gap
                let hw = (s.width - gap) / 2
                fill(CGRect(x: 0,      y: 0,      width: s.width,        height: mh),      slotIdx: 0, baseAlpha: 0.80)
                fill(CGRect(x: 0,      y: mh+gap, width: hw,             height: sh),      slotIdx: 1, baseAlpha: 0.50)
                fill(CGRect(x: hw+gap, y: mh+gap, width: s.width-hw-gap, height: sh),      slotIdx: 2, baseAlpha: 0.30)

            case .grid2x2:
                let hw = (s.width  - gap) / 2
                let hh = (s.height - gap) / 2
                let rects: [CGRect] = [
                    CGRect(x: 0,      y: 0,      width: hw,             height: hh),
                    CGRect(x: hw+gap, y: 0,      width: s.width-hw-gap, height: hh),
                    CGRect(x: 0,      y: hh+gap, width: hw,             height: s.height-hh-gap),
                    CGRect(x: hw+gap, y: hh+gap, width: s.width-hw-gap, height: s.height-hh-gap),
                ]
                let alphas: [CGFloat] = [0.80, 0.60, 0.50, 0.35]
                for (i, rect) in rects.enumerated() {
                    fill(rect, slotIdx: i, baseAlpha: alphas[i])
                }
            }
        }
        .frame(width: size, height: size * 0.72)   // 4:3-ish screen ratio
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .darkGray).opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Warning card view

struct LayoutCompatibilityWarningView: View {
    let issues: [CompatibilityIssue]
    let layout: AppGroupLayout

    // Deduplicate: one chip per unique (app, dimension) pair.
    private var dedupedIssues: [CompatibilityIssue] {
        var seen = Set<String>()
        return issues.filter { seen.insert("\($0.appName)-\($0.dimension)").inserted }
    }

    private var badSlots: Set<Int> { Set(issues.map(\.slotIndex)) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {

            // ── Left: layout diagram ──────────────────────────────────────
            VStack(spacing: 5) {
                CompatibilityDiagram(layout: layout, badSlots: badSlots, size: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text("Layout preview")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            // ── Right: header + issue chips ───────────────────────────────
            VStack(alignment: .leading, spacing: 7) {

                // Header row
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(red: 0.92, green: 0.26, blue: 0.26))
                    Text("May not fit on your screen")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                // Issue chips
                ForEach(dedupedIssues) { issue in
                    IssueChip(issue: issue)
                }

                Text("You can still save — Rewindpad will fit windows as best it can.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(red: 0.92, green: 0.26, blue: 0.26).opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color(red: 0.92, green: 0.26, blue: 0.26).opacity(0.22), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Single issue chip

private struct IssueChip: View {
    let issue: CompatibilityIssue

    var body: some View {
        HStack(spacing: 5) {
            // App icon placeholder / dimension icon
            Image(systemName: issue.dimension == .width ? "arrow.left.and.right" : "arrow.up.and.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(red: 0.92, green: 0.26, blue: 0.26))

            // Short label: "Books · too narrow"
            Text(issue.shortMessage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)

            // Slot badge
            Text(issue.slotLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(red: 0.92, green: 0.26, blue: 0.26).opacity(0.85))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color(red: 0.92, green: 0.26, blue: 0.26).opacity(0.12), in: Capsule())

            Spacer(minLength: 0)

            // Size detail
            Text(issue.detailMessage)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        )
    }
}

// MARK: - Inline danger pill (shown inside each affected window-order row)

struct CompatibilityPill: View {
    let issues: [CompatibilityIssue]

    private static let red = Color(red: 0.92, green: 0.26, blue: 0.26)

    /// Always produces exactly one label regardless of how many issues are passed.
    private var label: String {
        let hasW = issues.contains { $0.dimension == .width  }
        let hasH = issues.contains { $0.dimension == .height }
        if hasW && hasH { return "won't fit" }
        if hasW         { return "too narrow" }
        if hasH         { return "too short"  }
        return "won't fit"
    }

    var body: some View {
        // Single pill — always exactly one HStack capsule, never more.
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8, weight: .bold))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Self.red)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Self.red.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(Self.red.opacity(0.25), lineWidth: 0.75))
        .fixedSize()   // prevents the capsule from stretching and looking like two pills
    }
}

// MARK: - Layout suggestion banner

/// Shown when switching to a different layout would resolve the compatibility issues.
struct LayoutSuggestionBanner: View {
    let suggested: AppGroupLayout
    let onApply: () -> Void

    private static let green = Color(red: 0.18, green: 0.72, blue: 0.42)

    var body: some View {
        HStack(spacing: 10) {
            // Mini diagram of the suggested layout
            CompatibilityDiagram(layout: suggested, badSlots: [], size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("Better fit available")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Self.green)
                Text("\(suggested.displayName) layout fits all apps on your screen.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(action: onApply) {
                HStack(spacing: 4) {
                    Text("Switch")
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Self.green, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Self.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Self.green.opacity(0.22), lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}


# Dynamic Island & Live Activities design guidance (closest Apple analogue to a macOS notch HUD)

Research date: 2026-10-05. Primary sources: the HIG "Live Activities" page (change log's latest entry: **December 16, 2025**, "Updated guidance for all platforms, and added guidance for macOS and CarPlay"), retrieved via Apple's DocC JSON endpoint (`developer.apple.com/tutorials/data/design/human-interface-guidelines/live-activities.json`); WWDC23 session 10194 transcript; ActivityKit/WidgetKit/SwiftUI reference docs; WWDC23 "Animate with springs" (10158); WWDC26 "Live Activities essentials" (223).

Labels used below: **[OFFICIAL]** = stated verbatim or near verbatim by Apple. **[DERIVED]** = arithmetic I did on official numbers. **[3RD-PARTY]** = community measurement, not verified. **[ESTIMATE]** = my judgement, no source.

---

## Q1. What the HIG says about compact, minimal and expanded presentations (sizes, margins, radii, concentricity, camera cutout, density)

### Takeaway
Apple publishes exact point sizes. Compact leading and trailing are each **52.33×36.67 pt** (393-pt-wide phones) or **62.33×36.67 pt** (430-pt-wide phones). Minimal is **36.67–45 × 36.67 pt**. Expanded is **371 or 408 pt wide × 84–160 pt tall**. The island's corner radius is **44 pt**. On a black background, content must sit "snug" against the camera with **no padding** on that side. Every other edge uses even, concentric margins, with inner radius = outer radius − margin. Apple gives the Lock Screen margin (14 pt) but no numeric default margin for the island itself.

### Cited Findings
**Dimensions table [OFFICIAL]** ([HIG Live Activities, Specifications](https://developer.apple.com/design/human-interface-guidelines/live-activities#Specifications)):

| Screen (portrait, pt) | Compact leading | Compact trailing | Minimal (width range) | Expanded (height range) | Lock Screen |
|---|---|---|---|---|---|
| 430×932 | 62.33×36.67 | 62.33×36.67 | 36.67–45 × 36.67 | 408 × 84–160 | 408 × 84–160 |
| 393×852 | 52.33×36.67 | 52.33×36.67 | 36.67–45 × 36.67 | 371 × 84–160 | 371 × 84–160 |

- "The Dynamic Island uses a corner radius of 44 points, and its rounded corner shape matches the TrueDepth camera." [OFFICIAL] — [HIG Live Activities](https://developer.apple.com/design/human-interface-guidelines/live-activities)
- Total Dynamic Island width when compact or minimal: **250 pt** on Pro Max/Plus/Air (430-wide) devices and **230 pt** on Pro/base (393-wide) devices. Expanded width: **408 / 371 pt**. Listed for iPhone 14 Pro through iPhone 17 Pro Max and iPhone Air. [OFFICIAL] — [HIG Live Activities](https://developer.apple.com/design/human-interface-guidelines/live-activities)
- macOS: "Use the provided iOS dimensions." Live Activities "automatically appear in the Menu bar of a paired Mac using the compact, minimal, and expanded presentations. Clicking the Live Activity launches iPhone Mirroring." [OFFICIAL] — [HIG Live Activities, macOS](https://developer.apple.com/design/human-interface-guidelines/live-activities)
- Compact: "two separate elements: one on the leading side of the TrueDepth camera and one on the trailing side… design them to read as a single piece of information, and use consistent color and typography." [OFFICIAL] — [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities)
- "Keep content as narrow as possible and ensure it's snug against the TrueDepth camera… **don't add padding between content and the TrueDepth camera**. Maintain a balanced layout with similarly sized views for both leading and trailing elements; for example, use shortened units or less precise data." [OFFICIAL] — [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities)
- WWDC23: "A key goal is for the encapsulation to be as narrow as possible with no wasted space… aim to have as much as the view filled with content as possible… Consider truncating or shrinking things like units, or maybe showing a less precise version of your data to avoid it getting too wide or unbalanced." [OFFICIAL] — [WWDC23 10194 Design dynamic Live Activities](https://developer.apple.com/videos/play/wwdc2023/10194/)
- Minimal: one Live Activity is attached to the island and one is detached. "Depending on its content size, the detached minimal presentation appears circular or oval." Show live data rather than a logo where possible (for example, Timer shows the remaining time). [OFFICIAL] — [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities)
- Minimal image assets "shouldn't exceed 45x36.67 points". Images larger than the presentation may make the system fail to start the Live Activity. [OFFICIAL] — [ActivityKit: Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
- Expanded: "an enlarged version of the compact or minimal presentation… Ensure information and layouts expand predictably." "Wrap content tightly around the TrueDepth camera… avoid leaving too much room around it… to help diminish the camera's presence." [OFFICIAL] — [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities)
- WWDC23: "avoid having a 'forehead' at the top that calls attention to the sensor region. Rather, try and hug the sensor as tightly as possible and wrap content all the way around it." Expanded views "range from taller views for more content down to shorter pill sized views… avoid a height right on the edge between them." [OFFICIAL] — [WWDC23 10194](https://developer.apple.com/videos/play/wwdc2023/10194/)
- Expanded regions (API): `.center` sits below the camera. `.leading` and `.trailing` sit beside the camera and wrap below it. `.bottom` sits below everything else. "The system first determines the width of the center content while taking into account the minimal width of the leading and trailing content… By default, leading and trailing positions receive an equal amount of horizontal space." A `priority` makes a region full width. "The system may truncate a Live Activity if its height exceeds 160 points." [OFFICIAL] — [ActivityKit docs](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
- Concentric layout: "Use even, matching margins between rounded shapes and the edges of the Live Activity, including corners… when placing a rounded rectangle near a corner of your Live Activity, match its corner radius to the outer corner radius of the Live Activity by **subtracting the margin** and using a SwiftUI container to apply the correct corner radius ([ContainerRelativeShape])." "Keep content compact and snug within a margin that's concentric to the outer edge." "When separating a block of content, place it in an inset container shape or use a thick line. Don't draw content all the way to the edge of the Dynamic Island." [OFFICIAL] — [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities)
- Tip: to align non-rounded content inside the rounded corners, blur it in your drawing tool and make the blurred shape concentric with the outline. WWDC23 says the same: "The visual mass or centroid of the shape should nestle inside the walls of the island… maintain a concentric margin inside the perimeter of the island to avoid it poking into the corners… You can either push content inwards or round their containers." [OFFICIAL] — [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities); [WWDC23 10194](https://developer.apple.com/videos/play/wwdc2023/10194/)
- Margins:
  - Lock Screen: "The standard layout margin for Live Activities on the Lock Screen is 14 points" (it matches notifications).
  - Dynamic Island: the system applies default content margins. You can override them with `.contentMargins(_:_:for: .compact/.minimal/.expanded)`, for example 8 pt on some edges. Apple advises "Avoid placing content too close to the edges of the Dynamic Island" and "Aim to use the system's default content margins."

  [OFFICIAL] — [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities); [WWDC23 10194](https://developer.apple.com/videos/play/wwdc2023/10194/); [DynamicIsland.contentMargins](https://developer.apple.com/documentation/widgetkit/dynamicisland/contentmargins(_:_:for:)); [Creating custom views for Live Activities](https://developer.apple.com/documentation/activitykit/creating-custom-views-for-live-activities)
- Density:
  - "Focus on important information that people need to see at a glance. Your Live Activity doesn't need to display everything."
  - Interactivity: "prefer limiting it to a single element to help people avoid accidentally tapping the wrong control." Music playback is named as a valid case for controls.
  - Expanded: "get to the essence of your activity… not showing too little or too much… It should sort of feel like there's a tiny version of your app living in this space."

  [OFFICIAL] — [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities); [WWDC23 10194](https://developer.apple.com/videos/play/wwdc2023/10194/)
- Height should change with content: "When there's less information to show, reduce the height… When more information becomes available, increase the height." [OFFICIAL] — [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities)
- iOS 27 (WWDC26): compact and minimal views now also show in landscape. "In portrait, compact views are flexible in width but in landscape, they don't have room to grow in width." Provide an alternate narrow trailing view, for example an icon in place of text. [OFFICIAL] — [WWDC26 223 Live Activities essentials](https://developer.apple.com/videos/play/wwdc2026/223/)
- Community measurement of the resting island (iPhone 14 Pro): about **126 × 37.33 pt**, with about **11 pt** from the top of the screen. [3RD-PARTY, not verified; source blocked, seen only in a search snippet] — [Replicating the Dynamic Island Animation in SwiftUI (betterprogramming.pub)](https://betterprogramming.pub/dynamic-island-animation-5869fbce41e6)

### Inferences
- [DERIVED] Compact on a 393-pt phone: 230 − 2×52.33 = **125.34 pt** for the camera/center segment. That matches the third-party resting width of about 126 pt. Read it as: compact = resting pill plus a fixed-height wing of about 52 pt on each side. On 430-pt phones: 250 − 2×62.33 = 125.34 pt, so the camera segment is the same width.
- [DERIVED] A 44-pt radius on a 36.67-pt-tall compact shape is larger than half the height, so in practice compact and minimal are **capsules** (radius = height/2 ≈ 18.3 pt). The 44-pt radius only shows on the expanded shape.
- [DERIVED] Expanded width is 371 = 393 − 2×11 and 408 = 430 − 2×11. The expanded island sits **11 pt** in from each screen edge, which also matches the ~11-pt top gap in the third-party measurement.
- [DERIVED] Concentric formula: `innerRadius = outerRadius − margin`. With outer = 44: a 14-pt margin gives 30 pt, 16 → 28, 20 → 24. For compact capsules (r ≈ 18.3), artwork inset 4–6 pt gives about 12–14 pt. In SwiftUI, prefer `ContainerRelativeShape` or (iOS 26 / macOS 26) `ConcentricRectangle` with `.containerShape(...)` so this is computed for you.
- [ESTIMATE] Suggested starting points for a macOS notch HUD that copies the island:
  - Compact wing ~52–62 pt wide × notch height.
  - Expanded panel ~370–410 pt wide, height snapping between ~84 and 160 pt.
  - Outer radius in the 30–44 pt range for the expanded panel.
  - Content inset ~14–20 pt, concentric.
  - 0 pt padding toward the hardware cutout.

### Gaps
- Apple does not publish the island's default `contentMargins` values for compact/minimal/expanded, or the exact resting-pill size or top offset. Only the third-party ~126×37.33 pt and ~11 pt figures exist, and I could not open that source to confirm them.
- The HIG text links "Templates with default system margins and recommended text sizes" in Apple Design Resources (Figma/Sketch), but the numbers inside those kits are not in text form and I did not extract them.
- No Mac notch dimensions are given. The macOS guidance is limited to "use iOS dimensions" for menu-bar Live Activities.

---

## Q2. What WWDC sessions say about margins, padding, density, typography, color, tint, animation and legibility on black

### Takeaway
The island is always black and opaque, and you can't change its background. Express identity with bold foreground colors and a tinted keyline. Use large, medium-or-heavier text and thicker, extra-rounded shapes. Animate content with system transitions that last at most 2 s. The island should feel "like a living organism, with a deliberate elasticity."

### Cited Findings
- Color and background:
  - "Live Activities in the Dynamic Island use a black opaque background. Consider using bold colors for text and objects to convey the personality and brand of your app."
  - "You can't customize background colors for compact, minimal, and expanded presentations."

  [OFFICIAL] — [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities)
- Keyline: "When the background is dark — for example, in Dark Mode — a key line appears around the Dynamic Island to distinguish it from other content. Choose a key line color that's consistent with the color of other elements." The API is `keylineTint(_:)`: "Applies a subtle tint color to the surrounding border." [OFFICIAL] — [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities); [keylineTint docs](https://developer.apple.com/documentation/widgetkit/dynamicisland/keylinetint(_:))
- Typography: "Use large, heavier-weight text — a medium weight or higher. Use small text sparingly and make sure key information is legible at a glance." WWDC23: "extra rounded, thicker shapes, as well as large, heavier weight, easy-to-read text works well, as well as the use of color to convey identity." In expanded: "emphasizing rounded, thicker shapes, and a liberal use of color." [OFFICIAL] — [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities); [WWDC23 10194](https://developer.apple.com/videos/play/wwdc2023/10194/)
- Logo: "display it without a container… Don't use the entire app icon." [OFFICIAL] — [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities)
- Character: "Inspired by biological form and motion, the Dynamic Island is designed to feel like a living organism, with a deliberate elasticity that serves as a playful contrast to the fixed nature of the hardware." When you leave the app, it "swoops up into the Dynamic Island… designed to feel like the app is going and physically inhabiting that space." [OFFICIAL] — [WWDC23 10194](https://developer.apple.com/videos/play/wwdc2023/10194/)
- Layering: "like notifications, the Dynamic Island floats on a layer above apps. Apps shouldn't draw UI that points to the island or interacts with it." [OFFICIAL] — [WWDC23 10194](https://developer.apple.com/videos/play/wwdc2023/10194/); [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities)
- Alerts: rather than sending a push notification, "when possible, expand the island to present that information." Alert only for essential updates. [OFFICIAL] — [WWDC23 10194](https://developer.apple.com/videos/play/wwdc2023/10194/); [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities)
- Multiple sessions: "consider ticking between the display of them." In the HIG: prefer one Live Activity "that uses a dynamic layout and rotates through events." [OFFICIAL] — [WWDC23 10194](https://developer.apple.com/videos/play/wwdc2023/10194/); [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities)
- Animation:
  - "Live Activities use system and custom animations with a **maximum duration of two seconds**."
  - Recommended system transitions: content-replace and numeric content transitions, plus custom scale/opacity/movement transitions.
  - Animate existing elements to new positions instead of removing and re-adding them. Avoid overlap: move only the row that changes and fade the others.
  - Animations are not performed in Always-On reduced luminance.

  [OFFICIAL] — [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities); [WWDC23 10194](https://developer.apple.com/videos/play/wwdc2023/10194/)
- In widget code, the system ignores `withAnimation`/`.animation` modifiers and "uses the system's animation timing instead". Text changes animate with blurred content transitions; views added or removed fade in and out. [OFFICIAL] — [ActivityKit docs](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)

### Inferences
- [ESTIMATE] For a custom macOS notch HUD:
  - Use a pure black (`Color.black`) fill so the HUD merges with the hardware notch.
  - Use a single brand accent for glyphs and key numbers, and an optional faint accent-tinted 0.5–1 pt stroke as the "keyline".
  - Use SF Pro at `.medium`/`.semibold` or heavier.
  - Use `.contentTransition(.numericText())` for changing numbers and `.contentTransition(.opacity)`/blur-replace for text swaps.

### Gaps
- Apple names no specific point sizes for island text. Recommended sizes exist only in the Design Resources templates, which I did not extract.
- I found no official color values for the keyline's default (untinted) appearance.

---

## Q3. How Apple's own Now Playing (Music) looks in the Dynamic Island

### Takeaway
Apple does not document Now Playing's internal metrics. Officially, all we have is that music playback is a sanctioned case for interactive controls. Third-party descriptions agree on the anatomy but don't give measurements.

### Cited Findings
- Music playback is named as appropriate for interactive controls ("music playback, workouts, or apps that access the microphone"). [OFFICIAL] — [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities)
- Anatomy, from secondary sources:
  - Compact: album art on the leading side and an audio visualization (waveform) on the trailing side.
  - Expanded (long-press): artwork, title, transport controls (back, play/pause, forward) and a scrubber.

  [3RD-PARTY, descriptive only] — [MacRumors Dynamic Island guide](https://www.macrumors.com/guide/dynamic-island/); [theory7.net](https://www.theory7.net/support/en-us/tips-tricks/dynamic-island-iphone-features)

### Inferences
- [ESTIMATE, not measured] A plausible way to reproduce it, applying Apple's concentric rule:
  - Compact artwork: a rounded square of about 20–24 pt filling most of the 36.67-pt height, with radius about 5–7 pt.
  - Waveform: about 4–6 bars in the artwork's dominant color.
  - Expanded artwork: about 56–64 pt in the leading region, with radius about 12–14 pt.
  - Title in semibold ~15–17 pt (white) and artist ~13–15 pt in secondary gray.
  - Transport glyphs ~24–34 pt, with play/pause the largest.

  Validate all of these against screenshots before use.

### Gaps
- I found no reliable published teardown with Now Playing pixel or point measurements: artwork size and radius, waveform bar count and width, font sizes, control spacing. Two likely sources (uxplanet.org, uiuxtrend.com) were blocked by the network proxy. Recommendation: measure from iPhone screenshots (3× scale), or use Apple's iOS 26 Design Resources Figma kit.

---

## Q4. Documented animation and spring characteristics

### Takeaway
SwiftUI's spring presets all have a **0.5 s perceptual duration**. Their bounce is **0 for .smooth, 0.15 for .snappy and 0.3 for .bouncy**. `.default` (iOS 17+/macOS 14+) is a spring with response 0.55 and dampingFraction 1.0. Apple does not publish the Dynamic Island's own morph spring.

### Cited Findings
- `Animation.smooth(duration: 0.5, extraBounce: 0.0)`: "base bounce of 0". [OFFICIAL] — [Animation.smooth(duration:extraBounce:)](https://developer.apple.com/documentation/swiftui/animation/smooth(duration:extrabounce:))
- `Animation.snappy(duration: 0.5, extraBounce: 0.0)`: "base bounce of 0.15". [OFFICIAL] — [Animation.snappy(duration:extraBounce:)](https://developer.apple.com/documentation/swiftui/animation/snappy(duration:extrabounce:))
- `Animation.bouncy(duration: 0.5, extraBounce: 0.0)`: "base bounce of 0.3". [OFFICIAL] — [Animation.bouncy(duration:extraBounce:)](https://developer.apple.com/documentation/swiftui/animation/bouncy(duration:extrabounce:))
- `duration` is the "perceptual duration… approximately equal to the settling duration, but for very bouncy springs, will be the duration of the period of oscillation." [OFFICIAL] — same docs
- `Animation.default` is a spring with `response` 0.55, `dampingFraction` 1.0 and `blendDuration` 0.0. Before iOS 17/macOS 14 it was easeInOut. [OFFICIAL] — [Animation.default](https://developer.apple.com/documentation/swiftui/animation/default)
- WWDC23 "Animate with springs":
  - "A bounce of 0 feels like a smooth, gradual change. A small bounce, like around 15%… feels a little more brisk. And for larger bounce values like 30%, you do start to feel some noticeable bounciness."
  - "When you're not sure, use a spring with bounce 0."
  - Springs keep their velocity when retargeted, so interruptions feel natural.
  - "Start by finding a duration value that gives a pacing that you like", then tune bounce.

  [OFFICIAL] — [WWDC23 10158 Animate with springs](https://developer.apple.com/videos/play/wwdc2023/10158/)
- Live Activities: max 2 s per animation. System timing overrides custom animation modifiers inside widget/Live Activity views. [OFFICIAL] — [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities); [ActivityKit docs](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
- The island's motion has "a deliberate elasticity" and is "inspired by biological form and motion". This is qualitative only. [OFFICIAL] — [WWDC23 10194](https://developer.apple.com/videos/play/wwdc2023/10194/)
- HIG Motion: "Aim for brevity and precision in feedback animations"; "Let people cancel motion"; "Make motion optional" (respect Reduce Motion). [OFFICIAL] — [HIG Motion](https://developer.apple.com/design/human-interface-guidelines/motion)

### Inferences
- [ESTIMATE] For a notch HUD expand/collapse:
  - Use `.bouncy` or `.spring(duration: 0.4–0.5, bounce: 0.2–0.3)` for the shape morph, matching the island's elastic feel.
  - Use `.snappy` or `.smooth` (bounce 0–0.15) for content cross-fades inside the shape.
  - Keep everything well under 2 s, and fall back to opacity-only under `accessibilityReduceMotion`.
  - Collapse slightly faster and with less bounce than expand. This is a common practice; Apple has not documented it.

### Gaps
- Apple doesn't publish the system Dynamic Island morph spring (duration, bounce or stiffness).

---

## Q5. Documented guidance on keylines, standard margins and concentric radius formulas

### Takeaway
The radius rule is explicit: inner radius = outer radius − margin. In SwiftUI it is implemented by `ContainerRelativeShape` and, in iOS 26 / macOS 26, `ConcentricRectangle`. The documented margins are 14 pt (Lock Screen) and "default system margins" in the island, overridable through `contentMargins`. The island keyline is a tintable thin border shown on dark backgrounds.

### Cited Findings
- "match its corner radius to the outer corner radius of the Live Activity by subtracting the margin and using a SwiftUI container to apply the correct corner radius. For developer guidance, see ContainerRelativeShape." [OFFICIAL] — [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities)
- `ContainerRelativeShape`: "A shape whose dimensions the system calculates from an inset version of the current container shape." [OFFICIAL] — [ContainerRelativeShape](https://developer.apple.com/documentation/swiftui/containerrelativeshape)
- `ConcentricRectangle` (newer API, iOS 26 era):
  - It creates corners that are "squared, rounded, or concentric relative to a container shape's corners".
  - A corner is concentric when its "radius shares a common center with the containing shape's rounded corner radius".
  - It "automatically calculates each corner's radius… without hard-coded values".
  - Corners far from the container corner may resolve to radius 0, so use a minimum-radius rounded corner style.
  - The container shape is set with `.containerShape(_:)`.

  [OFFICIAL] — [ConcentricRectangle](https://developer.apple.com/documentation/swiftui/concentricrectangle)
- Standard margins: 14 pt on the Lock Screen, aligned with notifications. Tighter margins may be acceptable "for elements like graphics or buttons". [OFFICIAL] — [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities); [WWDC23 10194](https://developer.apple.com/videos/play/wwdc2023/10194/)
- `contentMargins` example: `.contentMargins(.trailing, 8, for: .expanded).contentMargins(.all, 20, for: .expanded)` resolves to 8 pt trailing and 20 pt on the other edges. These are examples, not defaults. [OFFICIAL] — [DynamicIsland.contentMargins](https://developer.apple.com/documentation/widgetkit/dynamicisland/contentmargins(_:_:for:))
- Keyline: `keylineTint(_ color: Color?)`. It appears on dark backgrounds, and you should tint it to match your content. [OFFICIAL] — [keylineTint](https://developer.apple.com/documentation/widgetkit/dynamicisland/keylinetint(_:)); [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities)
- StandBy: content is scaled 2× (WWDC23: "200%"). Keep standard margins and don't extend graphics to the edges, or they get cut off when the background extends. [OFFICIAL] — [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities); [WWDC23 10194](https://developer.apple.com/videos/play/wwdc2023/10194/)

### Inferences
- [DERIVED] SwiftUI recipe for a notch HUD:
  ```swift
  let outer: CGFloat = 32          // panel radius (bottom corners on a notch HUD)
  let inset: CGFloat = 14          // standard margin
  let inner = max(outer - inset, 4) // concentric inner radius
  content
    .padding(inset)
    .background(Color.black, in: .rect(cornerRadius: outer))   // or UnevenRoundedRectangle for top-flat notch
    .containerShape(.rect(cornerRadius: outer))                // lets ContainerRelativeShape / ConcentricRectangle resolve
  // inner tiles: ContainerRelativeShape().fill(...) or RoundedRectangle(cornerRadius: inner)
  ```
- [ESTIMATE] A notch-attached HUD is flush with the top edge, so only its **bottom** corners are visible rounded corners. Apply concentricity to the bottom corners. Top-edge content can sit snug to the notch area with no padding, matching the "no padding against the camera" rule.

### Gaps
- No numeric keyline width or default opacity is documented.
- Apple doesn't publish the default island content-margin values.

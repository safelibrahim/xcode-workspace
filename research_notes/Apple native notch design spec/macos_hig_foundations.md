# macOS HIG Foundations for a Native-Quality Black Notch HUD (SwiftUI, macOS 15 / macOS 26)

Method note: The HIG pages were read from Apple's own DocC JSON endpoints (`https://developer.apple.com/tutorials/data/design/human-interface-guidelines/<page>.json`), which are the data behind the rendered HIG pages. Every value tagged "documented" below comes verbatim from those pages or from Apple's SwiftUI API documentation JSON. The HIG pages were retrieved on 2026-10-05. Their change logs show the Color page was last updated Dec 16, 2025 and the Typography page carries the macOS 26 (Liquid Glass) era content. Values tagged "estimate" or "inference" are mine.

---

## 1. Typography: macOS text styles, minimum sizes, SF Pro Text vs Display, tracking

### Takeaway
macOS text styles are much smaller than iOS ones. Body and headline are 13 pt, and the smallest styles (footnote, caption1, caption2) are 10 pt. 10 pt is the documented macOS minimum. macOS has no Dynamic Type. SF Pro is a variable font with dynamic optical sizes, so you never pick "Text" or "Display" yourself in code. The system also applies size-specific tracking automatically. Use `Font.TextStyle` (or `.system(size:weight:)`) and don't hand-tune tracking.

### Cited Findings
- **macOS built-in text styles (documented):** [HIG Typography – Specifications](https://developer.apple.com/design/human-interface-guidelines/typography#Specifications)

  | Text style | Weight | Size (pt) | Line height (pt) | Emphasized weight |
  |---|---|---|---|---|
  | Large Title | Regular | 26 | 32 | Bold |
  | Title 1 | Regular | 22 | 26 | Bold |
  | Title 2 | Regular | 17 | 22 | Bold |
  | Title 3 | Regular | 15 | 20 | Semibold |
  | Headline | **Bold** | 13 | 16 | Heavy |
  | Body | Regular | 13 | 16 | Semibold |
  | Callout | Regular | 12 | 15 | Semibold |
  | Subheadline | Regular | 11 | 14 | Semibold |
  | Footnote | Regular | 10 | 13 | Semibold |
  | Caption 1 | Regular | 10 | 13 | Medium |
  | Caption 2 | **Medium** | 10 | 13 | Semibold |

- **Default and minimum sizes (documented):** macOS default is 13 pt and the minimum is 10 pt. iOS is 17/11 for comparison. — [HIG Typography – Ensuring legibility](https://developer.apple.com/design/human-interface-guidelines/typography); the same table appears in [HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- The HIG says to "avoid light font weights… prefer Regular, Medium, Semibold, or Bold… avoid Ultralight, Thin, and Light… especially when text is small." — [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- "SF Pro is the system font in macOS… macOS doesn't support Dynamic Type." — [HIG Typography – macOS](https://developer.apple.com/design/human-interface-guidelines/typography)
- **SF Pro Text vs Display (documented):** "the system fonts support dynamic optical sizes, which merge discrete optical sizes (like Text and Display) and weights into a single, continuous design… With dynamic optical sizes, you don't need to use discrete optical sizes unless you're working with a design tool that doesn't support all the features of the variable font format." — [HIG Typography – Using system fonts](https://developer.apple.com/design/human-interface-guidelines/typography)
- **Tracking (documented):** "In a running app, the system font dynamically adjusts tracking at every point size… you might need to adjust the tracking [in mockups]." — [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography#Tracking-values)
- **macOS tracking table, relevant sizes (documented):** [HIG Typography – Tracking values](https://developer.apple.com/design/human-interface-guidelines/typography#Tracking-values)

  | Size (pt) | Tracking (1/1000 em) | Tracking (pt) |
  |---|---|---|
  | 9 | +19 | +0.17 |
  | 10 | +12 | +0.12 |
  | 11 | +6 | +0.06 |
  | 12 | 0 | 0.0 |
  | 13 | −6 | −0.08 |
  | 14 | −11 | −0.15 |
  | 15 | −16 | −0.23 |
  | 16 | −20 | −0.31 |
  | 17 | −26 | −0.43 |
  | 20 | −23 | −0.45 |
  | 22 | −12 | −0.26 |
  | 24 | +3 | +0.07 |
  | 26 | +8 | +0.22 |
  | 28 | +14 | +0.38 |

- Symbolic traits (bold, tight or loose leading) may modify text styles. "If you need to display three or more lines of text, avoid tight leading even in areas where height is limited." — [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- SF Symbols weights correspond to SF font weights, "so you can achieve precise weight matching between symbols and adjacent text." — [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- macOS dynamic font variants (`menuBarFont(ofSize:)`, `menuFont`, `labelFont`, `controlContentFont`, `toolTipsFont`, etc.) can be used "to match the text in standard controls." — [HIG Typography – macOS](https://developer.apple.com/design/human-interface-guidelines/typography)
- Widgets: "display text using fonts at 11 points or larger." — [HIG Widgets](https://developer.apple.com/design/human-interface-guidelines/widgets)

### Inferences
- For a notch HUD, map the styles like this:
  - primary row titles: `.body` (13 pt Regular) or `.headline` (13 pt Bold), or 13 pt Semibold if Bold feels heavy (`.body.weight(.semibold)` is the documented "emphasized" body)
  - secondary metadata (times, locations): `.subheadline` (11 pt) or `.callout` (12 pt) in secondaryLabel
  - tiny badges: `.caption2` (10 pt Medium)
  - nothing below 10 pt
- Use `.monospacedDigit()` for times and countdowns so digits don't jitter. Use `.contentTransition(.numericText())` for changing numbers. This follows standard SwiftUI practice; I did not find it in the HIG text.
- Don't apply manual `.tracking()` when using the system font. The system already applies the table values. Only add it to replicate a mockup.
- Because there is no Dynamic Type on macOS, the HUD can use fixed sizes. Still honor Bold Text: the system font does this automatically.

### Gaps
- The HIG documents no explicit "minimum size for menu-bar/HUD text". The macOS menu bar font is about 13 pt (`menuBarFont`), but I did not retrieve an official numeric value for macOS 26's taller menu bar.

---

## 2. Color: label opacities, separators, system colors (dark), accent, contrast, Increase Contrast

### Takeaway
On a pure black HUD, use the semantic label hierarchy. In dark mode the labels are white at about 85% / 55% / 25% / 10% alpha. Use system colors only for meaning. The June 2025 "unified" palette changed the hex values (for example, dark Blue is now #0091FF rather than the older #0A84FF), so use `Color.blue` and similar APIs instead of hard-coded values. Body text needs 4.5:1 contrast. Only label and secondaryLabel pass on black. tertiaryLabel (about 2:1) and quaternaryLabel are not text-legible and are for disabled or decorative use only.

### Cited Findings
- **macOS label colors (measured NSColor dumps, Big Sur/Monterey; not published as numbers by Apple):** [gist: Output system colors from macOS](https://gist.github.com/andrejilderda/8677c565cddc969e6aae7df48622d47c); consistent with [NSColor catalog gist](https://gist.github.com/martinhoeller/38509f37d42814526a9aecbb24928f46) and [swiftuicolors.com macOS colors](https://swiftuicolors.com/macos-colors)

  | NSColor | Dark (RGBA) | Light (RGBA) | Effective gray on #000 | Contrast vs #000 (my calc) |
  |---|---|---|---|---|
  | labelColor | 255,255,255, **0.847** | 0,0,0, 0.847 | #D8D8D8 | 14.7:1 |
  | secondaryLabelColor | 255,255,255, **0.549** | 0,0,0, 0.498 | #8C8C8C | 6.3:1 |
  | tertiaryLabelColor | 255,255,255, **0.247** | 0,0,0, 0.259 | #3F3F3F | 2.0:1 (fails text) |
  | quaternaryLabelColor | 255,255,255, **0.098** | 0,0,0, 0.098 | #191919 | 1.2:1 |
  | separatorColor | 255,255,255, **0.098** | 0,0,0, 0.098 | — | — |
  | controlAccentColor (blue) | 0,122,255 | 0,122,255 | — | — |
  | keyboardFocusIndicatorColor | 26,169,255, 0.498 (Monterey) | 0,103,244, 0.498 | — | — |

- The HIG lists the semantic macOS colors (labelColor, secondaryLabelColor, tertiaryLabelColor, quaternaryLabelColor "such as watermark text", separatorColor, controlAccentColor, keyboardFocusIndicatorColor, etc.) but publishes no numeric values for them. — [HIG Color – macOS](https://developer.apple.com/design/human-interface-guidelines/color)
- "Avoid hard-coding system color values… The actual color values may fluctuate from release to release." "Don't use the separator color as a text color, or secondaryLabel color as a background color." — [HIG Color – System colors](https://developer.apple.com/design/human-interface-guidelines/color)
- **System colors, current unified palette (documented; RGB taken from the swatch alt text in the HIG JSON, last updated June 9, 2025 "Updated system color values"):** [HIG Color – Specifications](https://developer.apple.com/design/human-interface-guidelines/color#Specifications). The hex conversions and contrast ratios are my calculations.

  | Name | Light | **Dark** | IC Light | **IC Dark** | Dark vs #000 | IC Dark vs #000 |
  |---|---|---|---|---|---|---|
  | Red | #FF383C | **#FF4245** | #E9152D | **#FF6165** | 6.1:1 | 7.1:1 |
  | Orange | #FF8D28 | **#FF9230** | #C55300 | **#FFA056** | 9.4:1 | 10.4:1 |
  | Yellow | #FFCC00 | **#FFD600** | #A16A00 | **#FEDF43** | 14.9:1 | 15.9:1 |
  | Green | #34C759 | **#30D158** | #008932 | **#4AD968** | 10.4:1 | 11.4:1 |
  | Mint | #00C8B3 | **#00DAC3** | #008575 | **#54DFCB** | 11.8:1 | 12.8:1 |
  | Teal | #00C3D0 | **#00D2E0** | #008198 | **#3BDDEC** | 11.3:1 | 12.7:1 |
  | Cyan | #00C0E8 | **#3CD3FE** | #007EAE | **#6DD9FF** | 11.9:1 | 13.0:1 |
  | Blue | #0088FF | **#0091FF** | #1E6EF4 | **#5CB8FF** | 6.5:1 | 9.8:1 |
  | Indigo | #6155F5 | **#6D7CFF** | #564ADE | **#A7AAFF** | 6.0:1 | 9.8:1 |
  | Purple | #CB30E0 | **#DB34F2** | #B02FC2 | **#EA8DFF** | 5.8:1 | 9.8:1 |
  | Pink | #FF2D55 | **#FF375F** | #E7124D | **#FF8AC4** | 6.0:1 | 9.7:1 |
  | Brown | #AC7F5E | **#B78A66** | #956D51 | **#DBA679** | 6.8:1 | 9.7:1 |

- **Conflict and version note:** Older macOS NSColor dumps (Big Sur/Monterey) give dark systemBlue = 10,132,255 (#0A84FF), systemRed = 255,69,58 (#FF453A), systemOrange = 255,159,10, systemGreen = 50,215,75. — [gist](https://gist.github.com/andrejilderda/8677c565cddc969e6aae7df48622d47c). These differ from the 2025 unified HIG values above, which matches the HIG change log entry "June 9, 2025 | Updated system color values". So macOS 15 likely renders the older values and macOS 26 the newer ones (inference). Use `Color.red` etc. to get whichever is correct at runtime.
- **Contrast (documented):** The Accessibility Inspector uses WCAG AA: up to 17 pt, all weights need 4.5:1; 18 pt and up need 3:1; bold text at any size needs 3:1. "If your app doesn't provide this minimum contrast by default, ensure it at least provides a higher contrast color scheme when the system setting Increase Contrast is turned on." — [HIG Accessibility – Vision](https://developer.apple.com/design/human-interface-guidelines/accessibility). The HIG also names APCA as an alternative standard (same source).
- Dark Mode: "make sure the contrast ratio between colors is no lower than 4.5:1. For custom foreground and background colors, strive for a contrast ratio of 7:1, especially in small text." — [HIG Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)
- Increase Contrast: "the color differences become far more apparent… If you define a custom color, make sure to supply light and dark variants, and an increased contrast option for each variant." — [HIG Color](https://developer.apple.com/design/human-interface-guidelines/color). SwiftUI exposes this as `@Environment(\.colorSchemeContrast)` (`.standard` / `.increased`). — [SwiftUI colorSchemeContrast](https://developer.apple.com/documentation/swiftui/environmentvalues/colorschemecontrast)
- Dark Mode testing: "in Dark Mode with Increase Contrast and Reduce Transparency turned on… you may find places where dark text is less legible when it's on a dark background." — [HIG Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)
- **Accent color (documented):** "Beginning in macOS 11, you can specify an accent color… The system applies your accent color when the current value in General > Accent color settings is multicolor. If people set their accent color… the system applies their chosen color… replacing your accent color." — [HIG Color – App accent colors](https://developer.apple.com/design/human-interface-guidelines/color)
- "Avoid using the same color to mean different things." "Avoid relying solely on color to differentiate between objects, indicate interactivity, or communicate essential information." — [HIG Color](https://developer.apple.com/design/human-interface-guidelines/color)
- Desktop tinting: with the graphite accent, window backgrounds pick up desktop color. The HIG suggests "some transparency in custom component backgrounds" for this. — [HIG Dark Mode – macOS](https://developer.apple.com/design/human-interface-guidelines/dark-mode). (This does not apply to a notch HUD that must read as hardware-black.)

### Inferences
- **HUD palette (pure black, no materials):**
  - background `Color.black`, opaque, to blend with the physical notch
  - primary text `Color.primary`, which on a forced-dark black surface resolves to white at 0.85
  - secondary text `Color.secondary` (0.55)
  - hairline dividers `Color(nsColor: .separatorColor)` (white at 0.10) at 1 px, using `1 / displayScale`
  - hover and pressed fills: white at about 0.06–0.10 (`.quaternary` fill style). This is an estimate based on the quaternary alpha.
- Force the HUD view into `.environment(\.colorScheme, .dark)`. The HUD sits on a black notch even when the system is in light mode, and this makes semantic colors resolve to their dark variants.
- Reserve `Color.accentColor` for the single primary affordance and for selection. Use system red only for destructive or record states.
- Never put the accent color or tertiaryLabel on text smaller than 13 pt without checking ratios. Every dark system color passes 4.5:1 on pure black. Purple is the lowest at 5.8:1.

### Gaps
- Apple publishes no numeric values for macOS semantic label and separator colors. The values above are measured runtime values from older macOS versions, and I could not verify them for macOS 26. Liquid Glass-era macOS 26 may have shifted the label alphas.
- The HIG Color page does not list macOS system gray hex values. Only iOS grays are listed, and as images.

---

## 3. SF Symbols: rendering modes, weight/scale matching, variants, small-control sizing

### Takeaway
Size symbols with the same font or text style as the adjacent text, so weight and cap height match automatically. Use `.imageScale(.small/.medium/.large)` for emphasis instead of changing point size. Use the outline variant next to text or in toolbars, and `.fill` for selected or emphasized states. Use hierarchical rendering for depth with one color and avoid multicolor in a monochrome HUD. Note that SF Symbols 7 "gradient" rendering conflicts with the no-gradients constraint: don't enable it.

### Cited Findings
- There are four rendering modes. Monochrome applies one color to all layers. Hierarchical applies one color at varying opacity per layer. Palette uses two or more colors. Multicolor uses intrinsic colors. "Regardless of rendering mode, using system-provided colors ensures that symbols automatically adapt to accessibility accommodations and appearance modes." — [HIG SF Symbols – Rendering modes](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
- "In SF Symbols 7 and later, gradient rendering generates a smooth linear gradient from a single source color… look best at larger sizes." — [HIG SF Symbols – Gradients](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
- "Each of the nine symbol weights — from ultralight to black — corresponds to a weight of the San Francisco system font… Each symbol is also available in three scales: small, medium (the default), and large. The scales are defined relative to the cap height of the San Francisco system font. Specifying a scale lets you adjust a symbol's emphasis compared to adjacent text, without disrupting the weight matching." — [HIG SF Symbols – Weights and scales](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
- Variants: "The outline variant works well in toolbars, lists, and other places where you display a symbol alongside text." "Symbols that use an enclosing shape — like a square or circle — can improve legibility at small sizes." "The solid areas in a fill variant tend to give a symbol more visual emphasis… places where you use an accent color to communicate selection." "In many cases, the view that displays a symbol determines whether to use outline or fill." — [HIG SF Symbols – Design variants](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
- Use the slash variant to show an item or action is unavailable, and the fill variant to indicate selection. — [HIG SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
- Variable color is for change over time, such as capacity or strength. "Don't use it to communicate depth." — [HIG SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
- Animations include Appear/Disappear, Bounce, Scale, Pulse, Variable color, Replace (down-up, up-up, off-up), Magic Replace (the default replace), Wiggle, Breathe, Rotate, and Draw On/Off (SF Symbols 7). "Apply symbol animations judiciously." — [HIG SF Symbols – Animations](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
- macOS minimum control size is 20×20 pt and the default is 28×28 pt. — [HIG Accessibility – Mobility](https://developer.apple.com/design/human-interface-guidelines/accessibility)

### Inferences
- In SwiftUI, use `Image(systemName:)` with `.font(.body)` (13 pt) next to body text. For 11 pt metadata, use `.font(.subheadline)` with `.imageScale(.small)` or `.medium`. For icon-only buttons in a HUD, a symbol about 13–15 pt inside a 28×28 pt hit area is the default macOS control size. Never make the hit area smaller than 20×20.
- Use `.symbolRenderingMode(.hierarchical)` with `.foregroundStyle(.secondary)` for multi-layer glyphs on black. Use `.symbolVariant(.fill)` for active or selected toggles. Use `.contentTransition(.symbolEffect(.replace))` for state swaps such as play and pause.
- To stay within the no-gradients and no-decoration constraints, avoid `.symbolColorRenderingMode(.gradient)` (the SF Symbols 7 gradient) and multicolor symbols.

### Gaps
- The HIG gives no explicit point-size table for symbols in macOS small controls. The sizes above are inferred from the text styles and minimum control sizes.

---

## 4. Layout: margins, spacing, hit targets, continuous corners, concentric shapes (macOS 26)

### Takeaway
macOS has two classic spacing standards. Content sits 20 pt from the container edge and sibling controls sit 8 pt apart, which is Auto Layout's "standard" spacing. Widgets use 16 pt margins, or 11 pt for tighter groupings. Hit targets default to 28×28 pt with a 20×20 pt minimum. In macOS 26 Apple formalized concentricity: inner radius = outer radius − padding. Use `ConcentricRectangle` with `.containerShape(...)` (macOS 26+). On macOS 15, compute radii manually with `RoundedRectangle(cornerRadius:style: .continuous)`.

### Cited Findings
- Interface Builder standard spacing is "20.0 points between a view and the edge of its superview, and 8.0 points between sibling views." — [Apple Auto Layout Guide (archive)](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/WorkingwithSimpleConstraints.html). This is legacy documentation and not part of the current HIG.
- **Hit targets (documented):** macOS default control size is 28×28 pt and the minimum is 20×20 pt. "In general, it works well to add about 12 points of padding around elements that include a bezel. For elements without a bezel, about 24 points of padding works well around the element's visible edges." — [HIG Accessibility – Mobility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- **Widget margins (documented):** "Use the standard margin width for widgets — 16 points for most widgets… If you need to use tighter margins… setting margins of 11 points can work well. Additionally, note that widgets use smaller margins on the desktop on Mac." "Coordinate the corner radius of your content with the corner radius of the widget… use… ContainerRelativeShape." — [HIG Widgets – Choosing margins and padding](https://developer.apple.com/design/human-interface-guidelines/widgets)
- macOS layout: "Avoid displaying content behind the camera housing at the top edge of the window." (The developer reference is `NSPrefersDisplaySafeAreaCompatibilityMode`.) — [HIG Layout – macOS](https://developer.apple.com/design/human-interface-guidelines/layout)
- Group related items "using negative space, container shapes, or separator lines." "Align elements to make them easier to scan, and use indentation to convey hierarchy." — [HIG Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- **Concentricity (WWDC25 "Get to know the new design system", session 356):** "By aligning radii and margins around a shared center, shapes can comfortably nest within each other… three shape types: fixed shapes have a constant corner radius. Capsules use a radius that's half the height of the container. And concentric shapes calculate their radius by subtracting padding from the parent's." It also says to watch for "corners that feel too pinched — or flared… One place this often shows up is nested containers — like artwork in a card." — [WWDC25 Session 356](https://developer.apple.com/videos/play/wwdc2025/356/)
- The same session says: "On macOS, Mini, Small, and Medium controls will continue using rounded rectangles… Large controls will now use capsule shapes, alongside the new X-Large size." "For iPad and Mac, use a concentric shape that aligns with the window edge." — [WWDC25 Session 356](https://developer.apple.com/videos/play/wwdc2025/356/)
- **`ConcentricRectangle` (documented, macOS 26.0+):** "A shape whose corners you configure, individually or uniformly, to be squared, rounded, or concentric relative to a container shape's corners… ConcentricRectangle automatically calculates each corner's radius relative to the container shape." When corners are far from the container corner "the corner radius… may be zero… use concentric(minimum:) to specify a rounded corner with a minimum." "Use containerShape(_:) to specify a container shape that implements RoundedRectangularShape." — [SwiftUI ConcentricRectangle](https://developer.apple.com/documentation/swiftui/concentricrectangle)
- `containerShape(_ shape: some RoundedRectangularShape)` (macOS 26.0+) "Sets the container shape to use for any container relative shape or concentric rectangle within this view." — [SwiftUI containerShape(_:)](https://developer.apple.com/documentation/swiftui/view/containershape(_:))
- `RoundedCornerStyle` (`.circular` / `.continuous`) is available on macOS 10.15+. — [SwiftUI RoundedCornerStyle](https://developer.apple.com/documentation/swiftui/roundedcornerstyle)

### Inferences
- **Notch HUD grid (proposal):** use an 8 pt base unit with 4 pt half-steps. Content inset is 12–16 pt from the HUD edge: 16 pt for the widget-like expanded state, 11–12 pt for compact. Space rows 8 pt apart and icon-to-label 6–8 pt apart.
- **Radii:** if the expanded HUD bottom corners use radius R (estimate: R about 20–24 pt for a large expanded panel; this is not an Apple-published value), then inner cards or thumbnails at padding p get R − p. For example, R = 24 with p = 12 gives 12. On macOS 26 do this with `.containerShape(RoundedRectangle(cornerRadius: R, style: .continuous))` plus `ConcentricRectangle(corners: .concentric(minimum: 6))`. On macOS 15, compute `max(R − p, minimum)` manually. Always use `style: .continuous` (squircle). Apple hardware and UI corners are continuous; I did not find an explicit Apple statement of this in the fetched docs.
- The notch top edge should be square, flush with the screen top, with the bottom corners rounded. `ConcentricRectangle` or `UnevenRoundedRectangle` allows per-corner styles.

### Gaps
- The current HIG Layout page has no macOS-specific numeric margins. The 20/8 numbers come from legacy Auto Layout docs.
- I found no official radius for the MacBook notch cutout, or for macOS 26 window corners. Third-party reports suggest larger window radii in Tahoe, but I did not verify this against an Apple source.

---

## 5. Motion: HIG guidance, SwiftUI spring presets, Reduce Motion

### Takeaway
Motion should be purposeful, brief, cancelable, and optional. SwiftUI's presets `.smooth`, `.snappy`, and `.bouncy` are springs with a perceptual duration of 0.5 s by default. smooth has no bounce, snappy a small bounce, and bouncy a higher bounce. Apple's docs don't publish the exact preset bounce values; 0.15 and 0.3 are inferred from WWDC23 examples. The default `withAnimation` spring is response 0.55 with damping 1.0. With Reduce Motion on, replace movement and scale with fades and tighten springs.

### Cited Findings
- HIG Motion says: "Add motion purposefully… Don't add motion for the sake of adding motion." "Make motion optional." "Aim for brevity and precision in feedback animations." "In apps, generally avoid adding motion to UI interactions that occur frequently." "Let people cancel motion… don't make people wait for an animation to complete." — [HIG Motion](https://developer.apple.com/design/human-interface-guidelines/motion)
- "Strive for realistic feedback motion that follows people's gestures and expectations… if someone reveals a view by sliding it down from the top, they don't expect to dismiss the view by sliding it to the side." — [HIG Motion](https://developer.apple.com/design/human-interface-guidelines/motion)
- Liquid Glass motion "produces a more subdued effect when a person interacts using a trackpad." — [HIG Motion](https://developer.apple.com/design/human-interface-guidelines/motion)
- **Presets (documented signatures):** `static func smooth(duration: TimeInterval = 0.5, extraBounce: Double = 0.0)` is "a smooth spring animation with a predefined duration and no bounce". `snappy(duration: = 0.5, extraBounce: = 0.0)` is a spring "with… small amount of bounce that feels more snappy". `bouncy(duration: = 0.5, extraBounce: = 0.0)` has a "higher amount of bounce". — [Animation.smooth(duration:extraBounce:)](https://developer.apple.com/documentation/swiftui/animation/smooth(duration:extrabounce:)), [Animation.snappy(duration:extraBounce:)](https://developer.apple.com/documentation/swiftui/animation/snappy(duration:extrabounce:)), [Animation.bouncy(duration:extraBounce:)](https://developer.apple.com/documentation/swiftui/animation/bouncy(duration:extrabounce:))
- **Default animation (documented):** `Animation.default` is `spring(response: 0.55, dampingFraction: 1.0, blendDuration: 0.0)` on macOS 14+. Before macOS 14 it was easeInOut. — [Animation.default](https://developer.apple.com/documentation/swiftui/animation/default)
- **Spring math (documented):** `Spring(duration: 0.5, bounce: 0.3)` corresponds to mass 1.0, stiffness 157.9, damping 17.6. Spring is available on macOS 14+. — [SwiftUI Spring](https://developer.apple.com/documentation/swiftui/spring)
- **WWDC23 "Animate with springs":** the presets are "based on spring values that are used in iOS". The code examples show "Spring with Small Bounce: `.spring(duration: 0.5, bounce: 0.15)`" and "Large Bounce: `.spring(duration: 0.5, bounce: 0.3)`". Bounce ranges from −1.0 to 1.0, and duration is a *perceptual* duration, not settling time. — [WWDC23 Session 10158](https://developer.apple.com/videos/play/wwdc2023/10158/)
- **Reduce Motion (documented):** "reduce automatic and repetitive animations, including zooming, scaling, and peripheral motion." Best practices are:
  - "Tightening animation springs to reduce bounce effects"
  - "Tracking animations directly with people's gestures"
  - "Avoiding animating depth changes in z-axis layers"
  - "Replacing transitions in x-, y-, and z-axes with fades"
  - "Avoiding animating into and out of blurs"

  — [HIG Accessibility – Cognitive](https://developer.apple.com/design/human-interface-guidelines/accessibility). SwiftUI exposes `@Environment(\.accessibilityReduceMotion)`. "UI should avoid large animations, especially those that simulate the third dimension." — [SwiftUI accessibilityReduceMotion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion)
- Widgets: "use standard and custom animations with a duration of up to two seconds" for data updates. — [HIG Widgets](https://developer.apple.com/design/human-interface-guidelines/widgets)

### Inferences
- The values smooth = bounce 0, snappy ≈ bounce 0.15, and bouncy ≈ bounce 0.3 (all at duration 0.5) match the WWDC23 "small" and "large" examples and are widely cited. Apple's API docs only say "no", "small", and "higher" bounce, so treat the numbers as **likely, not documented**.
- **Notch HUD recommendation:**
  - expand/collapse: `.smooth(duration: 0.35–0.45)` or `.snappy(duration: 0.4)`
  - hover feedback: `.snappy(duration: 0.2–0.25)`
  - avoid `.bouncy` for a hardware-like surface
  - with Reduce Motion: `.easeInOut(duration: 0.2)` opacity crossfade with no scale or size spring, or a size change with no bounce (`.smooth`)
  - never animate blur, consistent with the no-blur constraint and the HIG

### Gaps
- No official HIG duration table for macOS (e.g. "use 250 ms"). Apple gives qualitative guidance only.
- I couldn't extract the exact internal parameters of `.snappy` and `.bouncy` from Apple docs.

---

## 6. Accessibility: VoiceOver, keyboard focus, Reduce Transparency/Motion, Differentiate Without Color

### Takeaway
Give every custom HUD element an accessibility label. Group each row into a single element. Hide decorative images. Post layout-change notifications when the HUD expands. Support Full Keyboard Access. Avoid auto-dismissing timers. Honor Reduce Motion, Reduce Transparency (already satisfied by opaque black), Increase Contrast, and Differentiate Without Color.

### Cited Findings
- VoiceOver:
  - "Provide alternative labels for all key interface elements… Add labels to any custom elements your app defines."
  - "Exclude purely decorative images from VoiceOver" (`accessibilityHidden(_:)`).
  - "Specify how elements are grouped, ordered, or linked" (`shouldGroupAccessibilityChildren`).
  - "Inform VoiceOver when visible content or layout changes occur" (`AccessibilityNotification`).
  - "Support the VoiceOver rotor" (`AccessibilityRotorEntry`).

  — [HIG VoiceOver](https://developer.apple.com/design/human-interface-guidelines/voiceover)
- Keyboard: "Let people use the keyboard alone to navigate and interact with your app… Avoid overriding system-defined keyboard shortcuts and evaluate your app to ensure it works well with Full Keyboard Access." — [HIG Accessibility – Speech](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- "Minimize use of time-boxed interface elements. Views and controls that auto-dismiss on a timer can be problematic… Prefer dismissing views with an explicit action." — [HIG Accessibility – Cognitive](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- "Convey information with more than color alone… red-green and blue-orange. Offer visual indicators, like distinct shapes or icons." — [HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility). SwiftUI: `accessibilityDifferentiateWithoutColor`. "UI should not convey information using color alone and instead should use shapes or glyphs." — [SwiftUI docs](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilitydifferentiatewithoutcolor)
- Reduce Transparency: `accessibilityReduceTransparency`. "UI (mainly window) backgrounds should not be semi-transparent; they should be opaque." — [SwiftUI docs](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducetransparency)
- "Offer sufficiently sized controls" (macOS 28×28 default, 20×20 minimum). Support Voice Control by labeling elements appropriately. — [HIG Accessibility – Mobility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- Give people the option to enlarge text by at least 200%, through Dynamic Type or custom UI. — [HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility). macOS lacks Dynamic Type, so a custom setting would be needed (inference).
- Drag and drop: "Offer alternative ways to accomplish drag-and-drop actions… menu commands." — [HIG Drag and drop](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop)

### Inferences
- **SwiftUI checklist:**
  - `.accessibilityElement(children: .combine)` on each event row, with a label such as "Team sync, 2:00 to 2:30 PM, Calendar: Work"
  - `.accessibilityAddTraits(.isButton)` on clickable rows
  - `.accessibilityHidden(true)` on calendar dots when the calendar name is in the label
  - `AccessibilityNotification.LayoutChanged().post()` on expand
  - `.focusable()` and `@FocusState` for keyboard navigation, with the system focus ring (`keyboardFocusIndicatorColor`)
  - `.help("…")` tooltips on icon-only buttons
- With Differentiate Without Color, add a shape or glyph next to the calendar color dot, or a text calendar name. Use symbols plus color for status, not color alone.
- Avoid a hover-only HUD that auto-collapses on a short timer. Provide pinning or explicit dismissal.

### Gaps
- The HIG has no macOS-specific guidance for notch or menu-bar-area HUD accessibility.

---

## 7. Drag and drop on macOS: drag images, feedback, spring-loading

### Takeaway
Show a translucent drag image once the drag has moved about 3 pt. Highlight a destination only while the item hovers over it and only if it can accept the item. Show a count badge for multi-item drags. Use copy, link, or not-allowed pointers. Animate back to the source, or "evaporate", on a failed drop. Support spring-loading (force click on a Magic Trackpad). Keep the dropped item selected.

### Cited Findings
- "Display a drag image as soon as people drag a selection about three points. It works well to create a translucent representation of the content people are dragging." — [HIG Drag and drop – Providing feedback](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop)
- "Show people whether a destination can accept dragged content… display an insertion point or highlight a containing view only when the destination can accept a dragged item, and show no visual feedback — or an explicit 'not allowed' image, like the circle.slash… Display highlighting… only while the content is positioned above the destination." — [HIG Drag and drop](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop)
- On a failed drop, "the item can move back… to its source… or it can scale up and fade out to give the impression of the item evaporating." — [HIG Drag and drop](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop)
- Spring loading: "Spring loading lets people activate certain controls… by dragging selected content over them… On a Mac equipped with a Magic Trackpad, a button or segmented control can activate when people force-click it while continuing to hold the content." — [HIG Drag and drop](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop)
- macOS-specific guidance:
  - "Consider letting people drag content from your app into the Finder… in a format your app can open later," with clippings for text.
  - "Consider displaying a badge during multi-item drag operations. A badge is a small filled oval containing a number."
  - "Consider changing the pointer appearance… copy pointer… drag link, disappearing item, and operation not allowed pointers."
  - "let people select and drag content with a single motion."
  - Allow dragging from inactive windows without activating them.

  — [HIG Drag and drop – macOS](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop)
- General rules:
  - Dropping in the same container moves; dropping in a different container copies; between apps it always copies.
  - Option key forces a copy.
  - "Offer multiple versions of dragged content, ordered from highest to lowest fidelity."
  - "Provide feedback when dropped content needs time to transfer" (progress or placeholder).
  - "After a drop, maintain the content's selection state."
  - Support undo.

  — [HIG Drag and drop](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop)

### Inferences
- **Shelf HUD:**
  - as a drop target, highlight only while hovering, with a 1–2 pt accent stroke or an increase in white fill alpha. No glow or shadow.
  - as a drag source, use `.draggable` / `.onDrag` with `NSItemProvider`, offering file URL first and image second. Provide a custom `.dragPreview` thumbnail. Note that the system drag image is translucent per the HIG.
  - auto-expand the HUD when a drag enters the notch region. This is analogous to spring-loading; it is not documented for notches.

### Gaps
- There are no numeric specs for drag preview size, opacity, or flocking animation on macOS.

---

## 8. Calendar "Up Next" / widgets: event row layout, calendar color, time formatting

### Takeaway
Apple publishes general widget rules but no pixel spec for Calendar's Up Next. The rules are:
- 16 pt margins (11 pt for tight groups)
- system font, 11 pt minimum
- use the system to refresh dates and times
- don't rely on color alone
- stay centered on the widget's main purpose: "all Calendar widgets display a person's upcoming events"

Row anatomy (color bar, title, time) must be estimated from observation.

### Cited Findings
- "All Calendar widgets display a person's upcoming events. In each size, the widget remains centered on events while expanding the range of information as the size increases." — [HIG Widgets](https://developer.apple.com/design/human-interface-guidelines/widgets)
- "Use system functionality to refresh dates and times in your widget" (e.g. `Text(date, style: .relative/.timer)`). — [HIG Widgets](https://developer.apple.com/design/human-interface-guidelines/widgets)
- "Balance information density… essential information at a glance… additional details by taking a longer look." — [HIG Widgets](https://developer.apple.com/design/human-interface-guidelines/widgets)
- "Convey meaning without relying on specific colors to represent information." — [HIG Widgets](https://developer.apple.com/design/human-interface-guidelines/widgets)
- For vibrant and desktop rendering: "Use white or light gray for the most prominent content and darker grayscale values for secondary elements… use opaque grayscale values, rather than opacities of white." — [HIG Widgets](https://developer.apple.com/design/human-interface-guidelines/widgets)
- "Design placeholder content… rectangles of different widths to suggest lines of text." — [HIG Widgets](https://developer.apple.com/design/human-interface-guidelines/widgets)
- Mac widget sizes: small 162×162 (or 160×160 depending on display), medium 350×162, large 350×350, XL 726×350 pt. These come from the HIG widget dimension tables for iPad and Mac in the Specifications section; I could not fully disambiguate which row is Mac. — [HIG Widgets – Specifications](https://developer.apple.com/design/human-interface-guidelines/widgets)

### Inferences (observational estimates, not documented)
- Calendar's Up Next / list widgets typically use:
  - a thin vertical rounded bar (about 3–4 pt wide, full row height, continuous rounded caps) in the calendar's color at the leading edge, or a small dot (about 6–8 pt) in compact layouts
  - the event title in a semibold body or subheadline style in primary label color
  - the time range below or beside it in secondaryLabel at 11–12 pt
  - "All-Day" in place of a time for all-day events
  - for the current or next event, a relative countdown ("in 15 min")
- Use `Date.FormatStyle` and `Text(.., style:)` so 12/24-hour preferences and locale are honored automatically: e.g. `date.formatted(date: .omitted, time: .shortened)` and `Text(timerInterval:)` / `Text(date, style: .relative)`.
- Calendar colors come from `EKCalendar.cgColor`, which is user-chosen. On black, check contrast of the dot or bar; it is non-text, so WCAG asks 3:1. Pair the color with the calendar name for VoiceOver and Differentiate Without Color.

### Gaps
- I found no Apple-published spec for the macOS Calendar Up Next widget or menu-bar layout (bar width, spacing, type sizes). These need verification against screenshots.

---

## 9. Clipboard/shelf precedent: thumbnail corner radius and sizing

### Takeaway
I found no Apple documentation giving corner radii or sizes for Finder Quick Look thumbnails, Photos grid cells, or the screenshot floating thumbnail. The only documented rules that apply are concentricity (inner radius = outer − padding, avoid "pinched or flared" corners in "artwork in a card") and continuous corners.

### Cited Findings
- WWDC25 says nested containers "like artwork in a card" should use concentric shapes so "the system [can] calculate the inner radii automatically." — [WWDC25 Session 356](https://developer.apple.com/videos/play/wwdc2025/356/)
- `ConcentricRectangle(corners: .concentric(minimum:))` keeps a minimum radius when far from the container corner. — [SwiftUI ConcentricRectangle](https://developer.apple.com/documentation/swiftui/concentricrectangle)
- Dark Mode advice for images: "Soften the color of white backgrounds. If you display a content image that includes a white background, consider slightly darkening the image to prevent the background from glowing." — [HIG Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)
- Dark Mode image borders: "an icon that represents a drop of oil might need a slight border to make the edge visible against a dark background." — [HIG Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)

### Inferences (estimates)
- Shelf thumbnails in a black HUD:
  - square-ish tiles about 48–64 pt
  - continuous corner radius about 6–10 pt, or concentric with the HUD (R − padding) with a minimum of about 6 pt
  - a 1 px inner stroke in separatorColor (white at about 0.10) so dark images don't vanish into the black, per the HIG's "slight border" advice for dark images
  - file icons via `NSWorkspace.shared.icon(forFile:)` shown without a radius; only image previews get the clip
  - `QLThumbnailGenerator` for previews
- I did not verify these against Apple sources. Measure them against screenshots of Finder Gallery view and macOS screenshot thumbnails before committing.

### Gaps
- There is no official source for Quick Look, Photos, or screenshot-thumbnail radii or sizes.
- The constraint of no shadows conflicts with the macOS screenshot floating thumbnail, which has a shadow. The HUD must rely on stroke and contrast instead.

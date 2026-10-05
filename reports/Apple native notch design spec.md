# Build Tilora's notch like Apple's Dynamic Island

To make Tilora look like Apple built it, copy Apple's own black-background surface, the Dynamic Island, and lay it out with macOS spacing and type. Apple publishes four hard rules for that surface: an **opaque black background**, **text of medium weight or heavier**, **concentric corners (inner radius = outer radius − margin)**, and **no padding between content and the camera housing** ([HIG: Live Activities](https://developer.apple.com/design/human-interface-guidelines/live-activities)). The macOS HIG supplies the rest. Type uses fixed text styles with a **13 pt default and a 10 pt minimum**. Hit targets are **28×28 pt by default and never smaller than 20×20 pt**. Text contrast must be at least **4.5:1** ([HIG: Typography](https://developer.apple.com/design/human-interface-guidelines/typography); [HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)). Your constraints (no gradients, blur, glass or shadows, and a pure black body) are not a departure from Apple. They describe the Dynamic Island exactly, and they match Apple's documented fallbacks for Liquid Glass: Reduce Transparency, and Increase Contrast, which makes elements "predominantly black or white… with a contrasting border" ([WWDC25 "Meet Liquid Glass"](https://developer.apple.com/videos/play/wwdc2025/219/)).

Apple does **not** publish point measurements for the Music MiniPlayer, the Control Center Now Playing module, artwork radii, scrubber height, transport-glyph sizes, Calendar's Up Next rows, or thumbnail radii. Every value for those below is an estimate, labeled as one. The research notes found no published teardown with those numbers. The biggest quality risks are three easy mistakes: using `tertiaryLabel` for real text (it reaches only about **2:1** on black), tinting the chrome instead of letting artwork supply the color, and using bouncy motion on a surface that should feel like hardware.

## Apple documents the container rules but not the media metrics

The Dynamic Island guidance is the only Apple specification written for a black HUD attached to a hardware cutout. It is also the only one with real numbers. The island's corner radius is **44 pt**, matching the TrueDepth camera. Compact leading and trailing elements are **52.33×36.67 pt** on 393-pt-wide phones. The expanded presentation is **371 or 408 pt wide** and **84–160 pt tall**, and the system may truncate anything taller than 160 pt ([HIG: Live Activities](https://developer.apple.com/design/human-interface-guidelines/live-activities); [ActivityKit docs](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)). For macOS, Apple's only guidance is "Use the provided iOS dimensions" for Live Activities shown in the Mac menu bar ([HIG: Live Activities](https://developer.apple.com/design/human-interface-guidelines/live-activities)). That makes the island sizes a defensible starting point for a Mac notch.

The layout rules matter more than the sizes. Apple asks for "even, matching margins" and inner radii computed "by **subtracting the margin**" from the outer radius, implemented with `ContainerRelativeShape`. Content should never be drawn "all the way to the edge". Separate blocks of content with "an inset container shape or a thick line". Content should "hug the sensor as tightly as possible" with no "forehead" above it ([HIG: Live Activities](https://developer.apple.com/design/human-interface-guidelines/live-activities); [WWDC23 10194](https://developer.apple.com/videos/play/wwdc2023/10194/)). WWDC25 made concentricity a rule for the whole system: there are fixed shapes, capsules (radius = half the height), and concentric shapes. Watch especially for "pinched or flared" corners on "artwork in a card" ([WWDC25 356](https://developer.apple.com/videos/play/wwdc2025/356/)). On macOS 26, `ConcentricRectangle` with `.containerShape(_:)` calculates the inner radii, and `.concentric(minimum:)` keeps a minimum radius on corners far from the container's corners ([ConcentricRectangle](https://developer.apple.com/documentation/swiftui/concentricrectangle)).

Apple deliberately leaves the media surfaces undocumented. It tells Now Playing apps they have no "direct control over what information the system displays, or its formatting" ([MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter)). The Music MiniPlayer is documented only by behavior. It is artwork-first, and its controls appear when the pointer moves over the artwork ([Apple Support: MiniPlayer](https://support.apple.com/guide/music/use-music-miniplayer-mus71d7dcfce/mac)). In macOS 26.2 the track title also became hover-only. Users complained ([Apple Community 256229550](https://discussions.apple.com/thread/256229550)), which is a good reason to keep the title visible whenever Tilora is expanded. In the island, Apple's own Now Playing shows album art on the leading side and a waveform on the trailing side when compact. When expanded it shows art, title, transport controls and a scrubber. That anatomy comes from third-party descriptions; Apple has not specified it ([MacRumors Dynamic Island guide](https://www.macrumors.com/guide/dynamic-island/)).

## The typography and color system fits on one card

macOS text styles are small and fixed. macOS "doesn't support Dynamic Type", and the system font sets optical size and tracking automatically, so do not apply `.tracking()` by hand ([HIG: Typography](https://developer.apple.com/design/human-interface-guidelines/typography)). The documented styles relevant to a HUD are **Headline 13/16 Bold**, **Body 13/16 Regular (emphasized: Semibold)**, **Callout 12/15**, **Subheadline 11/14**, **Footnote 10/13**, and **Caption 2 10/13 Medium**. The documented minimum is 10 pt ([HIG: Typography](https://developer.apple.com/design/human-interface-guidelines/typography)). The island rule is "medium weight or higher". Together these push every primary label to **13 pt Semibold**. On black, Body Regular reads as too thin.

The color system is semantic, not hex values. In dark mode the macOS label colors measure as white at **0.847 / 0.549 / 0.247 / 0.098** alpha. On pure black that gives about **14.7:1, 6.3:1, 2.0:1 and 1.2:1** contrast. These are runtime measurements from Big Sur and Monterey; Apple publishes no numbers and the values could not be re-verified on macOS 26 ([NSColor dump gist](https://gist.github.com/andrejilderda/8677c565cddc969e6aae7df48622d47c)). The consequence is firm. **Only primary and secondary may carry text**, because Apple requires 4.5:1 for text up to 17 pt ([HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)). One research note suggested tertiary for elapsed-time labels; on black, tertiary fails that requirement. Apple also warns that "the actual color values may fluctuate from release to release". The 2025 unified palette did change, for example dark Blue went from #0A84FF to **#0091FF**. So use `Color.blue` and similar rather than hard-coded hex ([HIG: Color](https://developer.apple.com/design/human-interface-guidelines/color)). Every dark-mode system color passes 4.5:1 on black. Purple is the lowest at 5.8:1 ([HIG: Color specs](https://developer.apple.com/design/human-interface-guidelines/color#Specifications)). Apple's restraint rule for color is explicit: "Avoid tinting all your elements… If you want to imbue color into your app, do it in the content layer instead" ([WWDC25 219](https://developer.apple.com/videos/play/wwdc2025/219/)). In Tilora, the album art, calendar colors and clipboard thumbnails supply all the color. The chrome stays black, white and gray.

| Token | Value | Basis |
|---|---|---|
| Notch body | `Color.black`, opaque, no stroke by default | **Documented** (island "black opaque background") |
| Color scheme | Force `.dark` on the HUD hierarchy | Estimate (needed so semantic colors resolve on black in Light Mode) |
| Text primary | `.primary` (≈ white 0.85) | Documented semantic; alpha measured |
| Text secondary | `.secondary` (≈ white 0.55, 6.3:1) | Documented semantic; alpha measured |
| Tertiary | `.tertiary`: glyph placeholders and disabled states only, **never text** | Derived from 2.0:1 contrast |
| Hairline divider | `Color(nsColor: .separatorColor)`, `1 / displayScale` pt | Documented semantic |
| Hover/pressed fill | white 0.08 hover, 0.14 pressed, solid | Estimate (≈ quaternary alpha) |
| Scrubber | track white 0.20; fill `.primary` | Estimate |
| Accent | none in chrome; `Color.blue` only for AirPlay-active; `EKCalendar.cgColor` for event bars | Documented principle; usage estimated |
| Title | 13 pt Semibold (`.body.weight(.semibold)`), 1 line, tail truncation | Documented style; mapping estimated |
| Secondary line | 11 pt Regular (`.subheadline`), `.secondary` | Documented style; mapping estimated |
| Time and duration | 10–11 pt, `.monospacedDigit()`, `.secondary` | Documented minimum; mapping estimated |
| Minimum text | 10 pt | **Documented** |

## Layout, glyphs and motion translate the island to a Mac notch

The proposed geometry fits Apple's documented ranges and values. The specific numbers are **estimates**. Collapsed, the HUD matches the hardware notch, read at runtime from `NSScreen`. With media playing, it grows compact wings about **52 pt** wide each, matching the island's 52.33 pt. The leading wing holds a **22 pt** artwork tile with a **6 pt** radius. The trailing wing holds a small level indicator or the play-state glyph, set snug to the cutout with **0 pt** padding on the camera side, as documented. Expanded, the panel is **400 pt** wide, inside the island's 371–408 pt range. Its content area below the notch is **no more than 160 pt** tall, the island's documented truncation limit. The top edge is square and flush with the top of the screen. Only the bottom corners are rounded, at **R = 24 pt**, continuous. Content margins are **14 pt**, Apple's documented Live Activity layout margin ([HIG: Live Activities](https://developer.apple.com/design/human-interface-guidelines/live-activities)). That gives a concentric inner radius of **24 − 14 = 10 pt** for every card, artwork and thumbnail near the panel's edge. Sibling spacing is **8 pt**, the legacy macOS standard ([Auto Layout Guide](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/WorkingwithSimpleConstraints.html)). Icon-to-label spacing is 6 pt.

The panel shows one module at a time, not all three at once. Apple's island guidance says "doesn't need to display everything" and "prefer limiting [interactivity] to a single element" ([HIG: Live Activities](https://developer.apple.com/design/human-interface-guidelines/live-activities)). A three-symbol switcher sits in the wings beside the notch: `play.circle`, `calendar`, `doc.on.clipboard`. The selected symbol uses `.fill` and `.primary`; the others use `.secondary`. The HIG reserves the fill variant for selection ([HIG: SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)). The modules lay out as follows (all estimates). **Now Playing** has 56 pt artwork, a title and artist stack, a 4 pt capsule scrubber that grows to 6 pt on hover, and a transport row. **Today** shows up to three event rows, each 36 pt tall, with a 3 pt calendar-color bar, a 13 pt Semibold title, and an 11 pt secondary time range, or "All-Day". **Clipboard** is a horizontal strip of **64 pt** tiles with 10 pt radii and 8 pt gaps. Five tiles plus four gaps take 352 pt, which fits the 372 pt content width. Every tile gets a 1-pixel separator-color stroke, following the HIG's "slight border" advice for dark images on dark backgrounds ([HIG: Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)).

Transport glyphs are `backward.fill`, `play.fill`/`pause.fill`, and `forward.fill`. Use `airplay.audio` for AirPlay, falling back to `airplayaudio`, and `music.note` for the empty state. All are monochrome and borderless ([Cult of Mac](https://www.cultofmac.com/how-to/apple-music-signs-symbols-icons); [HIG: SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)). Set skip glyphs at **15 pt Semibold** and play/pause at **20 pt Semibold**, each in a **28×28 pt** hit area. That hit area is the documented macOS default control size; the glyph sizes are estimates. Swap play and pause with `.contentTransition(.symbolEffect(.replace))`. Do not use SF Symbols 7 gradient rendering or multicolor symbols, which break the no-gradient rule ([HIG: SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)).

The motion presets are documented. `.smooth`, `.snappy` and `.bouncy` default to a **0.5 s perceptual duration**, with base bounce **0 / 0.15 / 0.3**. `Animation.default` is a spring with **response 0.55 and dampingFraction 1.0** ([Animation.snappy](https://developer.apple.com/documentation/swiftui/animation/snappy(duration:extrabounce:)); [Animation.default](https://developer.apple.com/documentation/swiftui/animation/default)). One research note read the API pages as giving only "small"/"higher" bounce. The other quoted "base bounce of 0.15" verbatim. The values match the WWDC23 examples either way ([WWDC23 10158](https://developer.apple.com/videos/play/wwdc2023/10158/)). Apple calls the island's motion "a deliberate elasticity" ([WWDC23 10194](https://developer.apple.com/videos/play/wwdc2023/10194/)), but a notch fused to hardware should feel more restrained. The estimated recommendation is **expand `.snappy(duration: 0.4)`** (bounce 0.15), **collapse `.smooth(duration: 0.3)`**, content cross-fade 0.18 s, and hover `.snappy(duration: 0.2)`. Everything stays well under the documented 2 s cap. Never animate blur. Under Reduce Motion, the HIG asks you to replace x/y/z movement with fades and to tighten springs ([HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)). Tilora should then switch to `.easeInOut(duration: 0.2)` opacity changes with no scale.

## Accessibility and drag-out are where third-party HUDs fall short

Apple's documented requirements are concrete. Add labels to every custom element. Hide decorative images. Group related elements. Post a layout-change notification when the content changes ([HIG: VoiceOver](https://developer.apple.com/design/human-interface-guidelines/voiceover)). Support keyboard-only use and Full Keyboard Access. Avoid views that "auto-dismiss on a timer". Never convey meaning by color alone ([HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)). People also "expect to press Space… to play or pause" ([HIG: Playing video](https://developer.apple.com/design/human-interface-guidelines/playing-video)). In practice, each event row becomes one combined element, for example "Team sync, 2:00 to 2:30 PM, Work calendar". The color bar is hidden from VoiceOver because the calendar name carries the same information. The scrubber is adjustable, with a value such as "1:23 of 3:45". Controls that appear on hover stay in the accessibility tree. Increase Contrast (`colorSchemeContrast == .increased`) adds a 1 pt white stroke at 0.5 alpha around the expanded panel. That follows Apple's own Increase Contrast treatment and the island's dark-mode keyline ([keylineTint](https://developer.apple.com/documentation/widgetkit/dynamicisland/keylinetint(_:))). The panel is already opaque, so it meets Reduce Transparency by construction.

For drag and drop, the HIG asks for a translucent drag image once the pointer has moved **about 3 pt**. Destination highlighting appears only while a drag hovers over a target that can accept it. Multi-item drags show a count badge, a "small filled oval containing a number". The pointer changes to the copy pointer. Content dragged to Finder should land in a format the app can reopen. Offer data representations "from highest to lowest fidelity". And there must be a non-drag alternative, such as menu commands ([HIG: Drag and drop](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop)). For Tilora, each clipboard tile's `NSItemProvider` registers, in order, a file URL (written to a temp file for images, so Finder gets a real file), PNG/TIFF data (what Figma consumes), and plain text. The drag preview is the tile thumbnail itself, with no shadow. The HUD must stay expanded while a drag session is active and must not collapse on mouse-exit until the drag ends. Each tile also gets a context menu with Copy, Save to Downloads and Reveal in Finder. That menu is Apple's documented alternative to drag and drop.

## Conclusion

Tilora's constraints are mostly an asset. Pure black, no materials and no shadows match the one Apple surface with published numbers: the island. They also avoid the contrast problems users reported with Tahoe's translucent Music bar ([Apple Community 256142581](https://discussions.apple.com/thread/256142581)). Tilora will stand or fall on discipline, not decoration. That means one concentric radius chain (24 → 14 → 10), only two text colors, color coming only from content, restrained motion, and full keyboard and VoiceOver support. Most third-party notch apps skip that last part.

The remaining uncertainty is measurement, not principle. Treat the 400 pt width, the 24 pt radius, the 56 and 64 pt tiles and the glyph sizes as starting values. Check them against the Accessibility Inspector and pixel-measured screenshots of macOS 26 Control Center and the Music MiniPlayer before you lock them in. If they need to change, adjust them only within the documented constraints above.

## Ready-to-paste prompt for Claude Code

````text
You are working in my macOS SwiftUI Xcode project. It contains a notch HUD app ("Tilora") that shows Now Playing, today's calendar events, and today's clipboard items (with drag-out to Figma/Finder). The Xcode target or project may have a different name. Find the notch HUD views yourself (search for NSPanel/NSWindow subclasses near the menu bar, "notch", "NowPlaying", "Calendar", "EventKit", "Clipboard", "NSPasteboard"). Do NOT ask me any questions. Make reasonable decisions, record them in a short summary at the end, and keep going until the self-check passes.

GOAL
Restyle and harden the notch HUD so it looks and feels Apple-made, following the spec below. Work on a new git branch named design/apple-native-notch. Commit when done.

HARD CONSTRAINTS (never violate)
- Notch body is solid, opaque Color.black. NO gradients (including SF Symbols gradient rendering), NO blur, NO NSVisualEffectView/.material/.glassEffect, NO shadows (remove any existing .shadow()). Grep the HUD code for: LinearGradient, RadialGradient, AngularGradient, .gradient, Material, .ultraThin, .regularMaterial, glassEffect, NSVisualEffectView, .blur(, .shadow( and remove all of them from HUD code.
- Force .environment(\.colorScheme, .dark) on the HUD root so semantic colors resolve correctly on black, even in Light Mode.
- Do not hard-code system color hex values. Use Color.blue etc.
- All text >= 10 pt. Text uses only .primary or .secondary foreground styles. Never use .tertiary/.quaternary for text (they fail contrast on black).
- No HUD element may be smaller than 20x20 pt for a hit target. The default hit target is 28x28 pt.

1) CREATE DesignSystem.swift (enum Tilora.DS or a similar namespace) containing ALL tokens below. Replace magic numbers in HUD views with these tokens.
Colors:
  body = Color.black
  textPrimary = Color.primary; textSecondary = Color.secondary
  glyphPlaceholder = Color.secondary.opacity(0.5) (non-text only)
  hairline = Color(nsColor: .separatorColor), drawn at 1/displayScale pt
  hoverFill = Color.white.opacity(0.08); pressedFill = Color.white.opacity(0.14)
  scrubTrack = Color.white.opacity(0.20); scrubFill = Color.primary
  airplayActive = Color.blue (only when routed to an external device)
  increasedContrastStroke = Color.white.opacity(0.5), 1 pt
Typography (SF system font only, no manual tracking):
  title = .system(size: 13, weight: .semibold)            // Body emphasized
  secondary = .system(size: 11, weight: .regular)         // Subheadline
  meta = .system(size: 11, weight: .regular).monospacedDigit()
  caption = .system(size: 10, weight: .medium)             // Caption 2, minimum size
  All single-line labels: .lineLimit(1).truncationMode(.tail)
Geometry:
  notchSize = read at runtime from the NSScreen that has the notch: height = screen.safeAreaInsets.top; width = screen.frame.width - auxiliaryTopLeftArea.width - auxiliaryTopRightArea.width. Fallback is 185 x 32 when there is no notch.
  compactWingWidth = 52; compactArtwork = 22, radius 6
  expandedWidth = 400; maxContentHeight = 160 (below the notch)
  outerRadius = 24 (bottom corners only; top edge square and flush with the screen top). Use UnevenRoundedRectangle(bottomLeading: 24, bottomTrailing: 24, style: .continuous).
  margin = 14; innerRadius = outerRadius - margin = 10 (concentric). On macOS 26+ use .containerShape + ConcentricRectangle(corners: .concentric(minimum: 6)). Otherwise compute radii manually. Always style: .continuous.
  spacing: sibling = 8, iconToLabel = 6, rowHeight = 36
  hitTarget = 28 (minimum 20)
  Content sits snug against the notch cutout: 0 pt padding on the cutout side. No empty "forehead" above the content.
Symbols (monochrome, borderless, no button backgrounds at rest):
  backward.fill / forward.fill at 15 pt semibold; play.fill / pause.fill at 20 pt semibold; airplay.audio at 13 pt (fall back to airplayaudio); music.note for empty state
  Module switcher in the wings: play.circle, calendar, doc.on.clipboard. Selected = .symbolVariant(.fill) + .primary; others = .secondary.
  Play/pause swap: .contentTransition(.symbolEffect(.replace)). Never use .symbolRenderingMode(.multicolor) or gradient rendering.
Motion:
  expand = .snappy(duration: 0.4); collapse = .smooth(duration: 0.3); contentFade = .easeOut(duration: 0.18); hover = .snappy(duration: 0.2); pressScale = 0.92
  Reduce Motion (@Environment(\.accessibilityReduceMotion)): use .easeInOut(duration: 0.2), opacity only, no scale/offset, no marquee
  Never animate blur. Nothing longer than 2 s.

2) LAYOUT
- Collapsed with nothing playing: exactly the hardware notch size, black, invisible against the notch.
- Collapsed while playing (compact): leading wing has 22 pt artwork (radius 6). Trailing wing has a small 3-4 bar level indicator in white (static under Reduce Motion) or the play state glyph. Wings are equal width.
- Expanded: 400 pt wide. Module switcher sits in the wings beside the notch. Below it is one module at a time, margin 14 on all sides. The height snaps to the module's content (<= 160 pt).
  Now Playing: 56 pt artwork, radius 10, 1-pixel hairline stroke. To its right is title (title token, primary) over artist (secondary token). Below is the scrubber: a 4 pt capsule that grows to 6 pt on hover, with elapsed time at leading and "-remaining" at trailing (meta token, secondary). Transport row is centered: previous / play-pause / next, plus AirPlay at trailing. Hover on a glyph = circular hoverFill behind it. Pressed = scale 0.92. Empty state: a 56 pt rounded square in white 0.08 with music.note in glyphPlaceholder, plus "Not Playing" in secondary.
  Today: up to 3 rows of 36 pt, each with a leading 3 pt-wide capsule bar in the EKCalendar color, the title (title token), and the time range below it (secondary/meta; "All-Day" for all-day events) formatted with Date.FormatStyle (.omitted date, .shortened time) so 12/24h follows the locale. The current/next event can show a relative time via Text(date, style: .relative). Empty state: "No more events today" in secondary.
  Clipboard: horizontal row of 64x64 tiles, radius 10, gap 8, 1-pixel hairline stroke. Images are clipped; file icons (NSWorkspace icon) are shown unclipped; text items show the first 2 lines at 10-11 pt on hoverFill. Overflow scrolls horizontally with the scroll indicator hidden.
- Color only comes from content (artwork, calendar colors, thumbnails). Do not tint the chrome.

3) DRAG AND DROP (clipboard tiles)
- Use .onDrag / NSItemProvider (or .draggable with Transferable). Register representations in order of fidelity: file URL (write images to a temp file so Finder receives a real file), PNG data (for Figma), TIFF, then plain text / URL where relevant.
- The drag preview is the tile thumbnail itself, with no shadow.
- Keep the HUD expanded while a drag session is active. Do not collapse on mouse-exit until the drag ends.
- Add a context menu to each tile: Copy, Save to Downloads, Reveal in Finder (the non-drag alternative).
- If the HUD accepts drops anywhere, highlight the target only while a valid item hovers over it (hoverFill plus a 1 pt white 0.5 stroke). No glow.

4) ACCESSIBILITY
- Labels: "Previous", "Play"/"Pause" (follow state), "Next", "AirPlay", and module switcher names. Add .help("...") tooltips on icon-only buttons.
- Track info: .accessibilityElement(children: .combine) so it reads "Title, Artist". Scrubber: .accessibilityValue("1:23 of 3:45") plus .accessibilityAdjustableAction.
- Event row: one combined element, e.g. "Team sync, 2:00 to 2:30 PM, Work calendar". Hide the color bar with .accessibilityHidden(true). With Differentiate Without Color on, also show the calendar name as text.
- Clipboard tile: label with item type and a short preview; add .accessibilityAddTraits(.isButton).
- Hover-revealed controls must remain in the accessibility tree and be keyboard-focusable (do not remove them).
- Post AccessibilityNotification.LayoutChanged() when the HUD expands or switches module.
- Keyboard: when the HUD has focus, Space toggles play/pause, Left/Right arrows switch modules, Esc collapses. Do not auto-collapse on a short timer while the pointer, keyboard focus or a drag is in the HUD.
- @Environment(\.colorSchemeContrast) == .increased: add the 1 pt increasedContrastStroke around the expanded panel (sides and bottom) and use .primary for all text.

5) DEBUG HOOKS (needed for screenshots; keep them out of release behavior)
- Launch arguments: -TiloraForceExpanded YES, -TiloraModule nowPlaying|today|clipboard, -TiloraMockData YES (supplies a fake track with artwork, 3 fake events in different calendar colors, and 5 fake clipboard items: 2 images, 1 file, 2 text).
- Add a #if DEBUG helper that renders each module's view with SwiftUI ImageRenderer (scale 2) to PNGs in /tmp/tilora-shots/ (nowPlaying.png, today.png, clipboard.png, compact.png, empty-nowPlaying.png) when launched with -TiloraRenderSnapshots YES, and then exits.

6) BUILD, LAUNCH, SCREENSHOT
- Find the scheme with: xcodebuild -list. Build with: xcodebuild -scheme <Scheme> -configuration Debug -derivedDataPath ./.build-dd build. Fix every error and every new warning in the files you touched.
- Run the built app binary with -TiloraRenderSnapshots YES -TiloraMockData YES and confirm the PNGs exist.
- Then launch it normally with -TiloraForceExpanded YES -TiloraMockData YES and run: screencapture -x -R0,0,<screenWidth>,260 /tmp/tilora-shots/live-<module>.png for each module. If screen capture is not permitted, rely on the ImageRenderer PNGs and say so.
- Open and inspect every PNG yourself.

7) SELF-CHECK (fix and repeat until everything passes, then report)
[ ] grep shows no gradient/material/glass/blur/shadow API in HUD code
[ ] body is pure black; the top edge is square and flush; only the bottom corners are rounded (24, continuous)
[ ] margins are 14; inner radii are 10 (concentric); no content touches the panel edge; no forehead gap under the screen top
[ ] no text below 10 pt; no text in .tertiary/.quaternary; title is 13 semibold; secondary is 11 regular; times use monospaced digits
[ ] only content supplies color; AirPlay is blue only when active
[ ] every button has a hit area >= 28x28 (minimum 20) and an accessibility label
[ ] Reduce Motion path uses opacity only; nothing animates blur; durations are <= 0.4 s
[ ] drag a clipboard image to Finder creates a file; PNG data is present for Figma; HUD stays open during the drag; context menu works
[ ] screenshots visually match the layout described above
Finish with a summary: files changed, the decisions you made, any spec items you could not meet and why, and the screenshot paths.
````

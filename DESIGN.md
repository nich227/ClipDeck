# ClipDeck Design System

This file defines how ClipDeck looks and moves. Every token has a Swift definition in `ClipDeck/Utilities/Constants.swift`. Every surface must match this file.

ClipDeck's quiet design uses Liquid Glass, generous space, motion that settles, and the user's Mac accent color. Copied content stays prominent, while the chrome stays secondary.

## 1. Color and surface

The panel and copy confirmation use macOS Liquid Glass (`NSGlassEffectView`, regular style). ClipDeck has no background color. The wallpaper and windows behind the panel show through. The system appearance makes the glass light or dark. ClipDeck uses color only as a signal.

### Fills on glass

| Token | Value | With Increase Contrast | Use |
|---|---|---|---|
| `surface1` | label color at 0.06 | 0.12 | Hovered row, key hint, thumbnail well |
| `surface2` | label color at 0.11 | 0.22 | Selected row |
| `hairline` | label color at 0.10 | 0.40 | Dividers |

These fills use the label color, so they darken light glass and lighten dark glass without another token set. Each fill is a `SurfaceFill`, which reads the Increase Contrast setting when it is drawn.

### Accent

| Token | Value | Use |
|---|---|---|
| `accent` | `Color.accentColor` | Selection bar, empty state paperclip, HUD check, recorder text, progress bar |
| `accentSoft` | accent at 0.12 | Tinted fills behind accent text |

ClipDeck has no color of its own. `accent` is the color the user picked in System Settings, Appearance. Native controls in Settings use the same setting without a project override. Multicolor resolves to blue.

### Signal

| Token | Light | Dark | Use |
|---|---|---|---|
| `caution` | `#B25E00` | `#FF9F43` | Missing file or image, a history that can't be loaded |
| `danger` | `#D70015` | `#FF453A` | Errors, refused shortcut |

Both use 11 point text. Each has a darker Light Mode value that maintains a 4.5:1 contrast ratio on white. A signal always includes words, a symbol, or both, so it does not rely on color alone. A missing item's thumbnail and artwork draw at 0.5 opacity (`Constants.Panel.missingItemOpacity`) beside the words Not Found.

### Text

| Token | Value | Use |
|---|---|---|
| `textPrimary` | `.primary` | Row titles, search text, preview text, empty state title, "Copied" |
| `textSecondary` | `.secondary` | Row subtitles, metadata, key hints, the footer line, a missing item's title, HUD item name |
| `textTertiary` | `tertiaryLabelColor` | The search glyph, which matches the placeholder beside it |

The system label hierarchy keeps text legible on glass in both appearances. It also darkens when Increase Contrast is on. Anything a person reads uses primary or secondary text. Tertiary text is only for a glyph that repeats the adjacent text. Never set panel text to white or black.

### Glyph

The app's mark is a paper clip. The app icon is an Icon Composer document. In the light appearance, it uses a white rounded square and a black glass paperclip. In the dark appearance, it uses a near-black square and a white glass paperclip. The paperclip fills 78% of the canvas. The glass layer uses 0.75 translucency with specular highlights, so the wire looks like glass without washing out on white.

macOS picks the appearance from the Icon and widget style setting. When Dark is set to Automatic, it follows Dark Mode. The document supplies both appearances.

In the menu bar, the same paperclip uses `MenuBarIcon`, a template vector. It uses the menu bar's color and the accent color in About. The menu is a system menu. It has a Recent section header, 20 point thumbnails, and gray key equivalents on the right. Rows use Command-1 through Command-9 and Command-0. Open ClipDeck shows the global shortcut. The menu has no custom views, so macOS 26 draws it in Liquid Glass like every other menu.

The empty state uses the same paperclip in the Lottie animation (`paperclip.json`) with a single wire. The wire draws on, holds, and unwinds. The animation rotates the wire 45 degrees, so the large loop sits at the top right like the icon. Menu rows use 16 point SF Symbols or 20 point rounded thumbnails.

A file without a thumbnail shows its file type's icon in both the panel and menu. The icon comes from the type, so ClipDeck does not read the disk for it. Text and images without thumbnails show their kind's symbol in a `surface1` well.

### The disk image

The install window shows the branded background with the wordmark, instruction, and version footer in dark ink on white. Finder paints a white surface behind any background picture in both appearances, so the window is also white in Dark Mode by design. `make-dmg.sh --plain` drops the picture. Finder's surface and labels then follow the appearance.

## 2. Voice

All ClipDeck text follows Apple's conventions, so the app reads like part of macOS. Menu items, buttons, toggles, and section headers use title-style capitalization (Clear History, Limit Storage, Show in Menu Bar). Descriptions, messages, and empty states use sentence style and address the user directly (Items you copy will appear here. You can't undo this action.). Keys use Apple's names: Return, Escape, Up Arrow, and Shift-Command-C. Menu and settings paths use `>`.

On the Mac, people click and choose. They press only keys and never tap. The Clear History sheet follows Safari. It has a "Clear:" popup with lowercase ranges and a destructive Clear History button.

A message that explains a consequence or recovery wraps and never truncates. An error says what failed and what to do next. A search with no results names the query: No Results for "query".

A window hides its title-bar title when its content has a heading, so the name appears once. The title still identifies the window in the Window menu and VoiceOver.

## 3. Typography

ClipDeck uses SF, the system font, for everything except the app's name. The app's name uses Instrument Serif Regular, a condensed high contrast serif. The name is 34 points in About and 36 points on the disk image, with no tracking. The app's name is the only place where a second typeface appears.

Never use Instrument Serif for a sentence. Use regular through semibold weights with generous tracking. No text is lighter than regular because light strokes at 11 points do not hold on glass. Use opacity before size to differentiate text. Set type with `deckFont(_:)`, which applies the size, weight, and tracking together.

| Role | Size | Weight | Tracking | Swift |
|---|---|---|---|---|
| Wordmark | 34 | Instrument Serif Regular | 0 | `.deckFont(.wordmark)` |
| Title | 20 | semibold | 0 | `.deckFont(.title)` |
| Search | 20 | regular | 0 | `.deckFont(.search)` |
| Body | 15 | regular | 0.35 | `.deckFont(.body)` |
| Label | 13 | medium | 0.3 | `.deckFont(.label)` |
| Caption | 11 | regular | 0.5 | `.deckFont(.caption)` |
| Mono (key hints, text preview) | 12 | regular, monospaced | 0.5 | `.deckFont(.mono)` |

Search uses the Title size at regular weight. The field gets Title size without Title's weight so that it is prominent when the panel opens.

## 4. Space and radius

Use one ramp for each and no other numbers.

- Space: `2 4 8 12 16 20 24 32 40` (`Space.xxxs` through `Space.xxxl`). The first step only sets a title on the line that describes it.
- Radius: `4 8 12 20` (`Radius.xs`, `sm`, `md`, `lg`)
  - Thumbnails and key hints: 4
  - Rows and preview artwork: 8
  - The Welcome list: 12
  - Panel: 20, the glass corner
  - HUD: a capsule, half its height
- Glyph: `16 20 28 44 72` (`Glyph.inline`, `row`, `state`, `mark`, `illustration`)
  - The search glyph and a row's kind symbol: 16
  - Welcome row symbols, the granted mark, and menu thumbnails: 20
  - The symbol in an empty artwork well or the load-failed state, and the check in the copy confirmation: 28
  - The paperclip mark in About and Welcome: 44
  - A drawn animation and the preview's file type icon: 72

The panel is 720 by 470. A row is 48 points tall with a 32 point thumbnail. Rows sit 4 points apart, so seven whole rows show at rest. Every row has the same height. The list depends on this height because it places and builds rows from the scroll offset alone.

The list area shows one thing at a time. It shows the rows, empty history (the paperclip, No Items), or no search results (the glass, No Results for "query"). It can also show a history that can't be loaded (a `caution` warning symbol, Can't Load History, and what to do next). The three states share one layout. Each has a 72 point slot for the drawing or symbol, a Label title, and a Caption line. The area stays empty until the first page arrives, so no state flashes before the rows.

Settings panes share one width, 560. Each pane is as tall as its content, and the window follows when a row appears.

## 5. Motion

SwiftUI curves move the panel, and springs move the copy confirmation. Lottie handles every drawn animation.

| Token | Curve | Duration | Use |
|---|---|---|---|
| `Anim.quick` | ease-out | 0.2 | Press and quick state changes |
| `Anim.standard` | cubic-bezier(0.16, 1, 0.3, 1) | 0.35 | Panel entrance |
| `Anim.entrance` | cubic-bezier(0.16, 1, 0.3, 1) | 0.8 | Larger reveals |
| `Spring.arrive` | response 0.45, damping fraction 0.72 | settles in about 0.6 | HUD drops below the menu bar with one small overshoot |
| `Spring.depart` | response 0.35, damping fraction 1 | about 0.35 | HUD leaves with no bounce |

The pill's layer uses `CASpringAnimation`s. The table gives each spring's response and damping fraction. `CopyHUDController.Spring` converts them to stiffness and damping.

### The drawn animations

| File | Canvas | Length | Plays | What happens | Still frame |
|---|---|---|---|---|---|
| `paperclip.json` | 120 × 120 | 2.9 s | Loop, in the empty history | A wire 7 points thick draws on over 1.2 s. It holds, unwinds from its start over 0.6 s, and repeats | The whole wire, at 1.2 s |
| `copied.json` | 60 × 60 | 1 s | Once, in the copy confirmation and when file access is granted | A ring draws on over 0.43 s. At 0.23 s, a check draws on inside it and pops from 70% to 108% to 100% | The ring and the check, at 0.77 s |
| `noresults.json` | 120 × 120 | 0.67 s | Once, when a search finds nothing | A magnifying glass uses one 7 point stroke. The lens draws around from where the handle meets it. Then the handle extends to the lower right | The whole glass, the last frame |

All use white strokes with round caps, tinted at run time with `accent` through `DeckAnimation`. Every drawn animation uses this component, and nothing else in the app draws one. Their generator is `scripts/make-animations.py`.

- A drawn animation is a Lottie file. A window, pill, or panel that moves or fades into place is not a drawn animation. It uses a SwiftUI curve or a Core Animation spring from the table above.
- A loop repeats the whole file. A one-shot plays from the first frame to the still frame and holds it. `DeckAnimation.still` shows only the still frame when the state was already true before its surface appeared.
- Each file marks its still frame with a marker named `reduced motion`.
- Lottie uses only its Core Animation engine. The render server plays the animation, and ClipDeck does no work per frame.

### Rules

- The panel and HUD enter fast and settle slowly. The panel fades in and drops 8 points into place. The panel closes instantly. The HUD arrives on a spring and leaves on a stiffer one.
- One thing moves at a time.
- Nothing animates while off screen. Every `DeckAnimation` takes `isActive`. When its surface is hidden, a loop releases its layers and a one-shot keeps its still frame.
- Reduce Motion turns every animation off. `Anim.allowed(_:reduceMotion:)` returns nil. The HUD fades in place. Each Lottie animation shows its still frame.

## 6. Accessibility

- VoiceOver: every row is one element. It reads the title, Not Found when it applies, and then the subtitle. Its action copies the item. Focus stays in the search field. ClipDeck announces each selection move, each copy, each failed copy, and each history load failure. A copy is announced even when the confirmation pill is turned off. A failed copy also plays the alert sound. Symbols that repeat the text beside them are hidden.
- Keyboard: the panel is fully usable from the search field. Up Arrow, Down Arrow, Page Up, and Page Down move the selection. Return copies. Escape clears a search, then closes the panel. When the selection moves, the hover fill turns off until the pointer moves. Thus, a row that scrolls under a still pointer is not highlighted.
- Increase Contrast: the system darkens the label colors, and the fills use the stronger opacities in section 1.
- Reduce Transparency: macOS makes the glass opaque. ClipDeck draws nothing behind it that would need to change.
- Reduce Motion: see section 5.
- Color is never the only signal. A missing item says Not Found, and an error has a symbol and words.

## 7. Coherence checklist

A surface matches this design only if all of these hold:

- [ ] Use macOS glass, only the system accent, and label-color fills at the opacities above.
- [ ] Use the system font and type roles above.
- [ ] Use spacing, radius, and glyph sizes from the ramps. Define each required control width as a named constant beside the control.
- [ ] Use motion from the token set and animations through `DeckAnimation`. Nothing moves when Reduce Motion is on.
- [ ] Write copy in Apple's register. Use title style for controls, sentence style for messages, and Apple's key names.
- [ ] Text a person reads is primary or secondary, and a message that matters wraps.
- [ ] Every control and row has a VoiceOver name, and the surface works from the keyboard.

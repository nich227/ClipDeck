# ClipDeck Design System

This file defines how ClipDeck looks and moves. Every token has a Swift definition in `ClipDeck/Utilities/Constants.swift`. If a surface disagrees with this file, the surface is wrong.

ClipDeck has a quiet design with Liquid Glass, generous space, motion that settles, and the accent color the user chose for their Mac. Copied content stays prominent, and the chrome stays secondary.

## 1. Color and surface

The panel and copy confirmation use Liquid Glass drawn by macOS (`NSGlassEffectView`, regular style). ClipDeck has no background color. The wallpaper and windows behind the panel show through. The system appearance decides whether the glass looks light or dark. ClipDeck uses color only as a signal.

### Fills on glass

| Token | Value | Use |
|---|---|---|
| `surface1` | label color at 0.06 | Hovered row, key hint, thumbnail well |
| `surface2` | label color at 0.11 | Selected row |
| `hairline` | label color at 0.10 | Dividers |

These fills use the label color, so they darken light glass and lighten dark glass without another token set.

### Accent

| Token | Value | Use |
|---|---|---|
| `accent` | `Color.accentColor` | Selection bar, empty state paperclip, HUD check, recorder text, progress bar |
| `accentSoft` | accent at 0.12 | Tinted fills behind accent text |

ClipDeck has no color of its own. `accent` is the color the user picked in System Settings, Appearance. Native controls in Settings use the same setting without a project override. Multicolor resolves to blue.

### Signal

| Token | Value | Use |
|---|---|---|
| `caution` | `#FF9F43` | Missing file or image |
| `danger` | `#FF3B30` | Errors, refused shortcut |

### Text

| Token | Value | Use |
|---|---|---|
| `textPrimary` | `.primary` | Row titles, search text, preview text, "Copied" |
| `textSecondary` | `.secondary` | Empty state, key glyphs, HUD item name |
| `textTertiary` | `tertiaryLabelColor` | Subtitles, hints, metadata |

The system label hierarchy keeps text legible on glass in both appearances. Never set white or black text in the panel.

### Glyph

The app's mark is a paper clip. The app icon is an Icon Composer document. In the light appearance, it uses a white rounded square and a black glass paperclip. In the dark appearance, it uses a near-black square and a white glass paperclip. The paperclip fills 78% of the canvas. The glass layer uses 0.75 translucency with specular highlights enabled, so the wire looks like glass without washing out on white.

macOS picks the appearance from the Icon and widget style setting (Dark set to Automatic follows Dark Mode). The document supplies both appearances.

In the menu bar, the same paperclip uses `MenuBarIcon`, a template vector. It takes the menu bar's color and the accent in About. The menu itself is the system's. It has a Recent section header, 20 point thumbnails, and key equivalents in the menu's own gray on the right. The rows carry Command-1 to Command-9 and Command-0. Open ClipDeck carries the global shortcut. Nothing in it is a custom view, so macOS 26 draws it in Liquid Glass like every other menu.

The empty state uses the same paperclip in a Lottie animation (`paperclip.json`) with a single wire. The wire draws on, holds, and unwinds. The animation rotates the wire 45 degrees so the large loop sits at the top right like the icon. Menu rows use SF Symbols at 14 points or a rounded thumbnail at 16 points.

### The disk image

The install window shows the branded background: the wordmark, the instruction, and the version footer in dark ink on white. Finder paints a white surface behind any background picture in both appearances, so the window is white in Dark Mode too, by design. `make-dmg.sh --plain` drops the picture, and Finder's own surface and labels then follow the appearance.

## 2. Voice

Everything a person reads in ClipDeck follows Apple's conventions, so the app reads like part of macOS. Menu items, buttons, toggles, and section headers use title-style capitalization (Clear History, Limit Storage, Show in Menu Bar). Descriptions, messages, and empty states use sentence style and address the user directly (Items you copy will appear here. You can't undo this action.). Keys use Apple's names: Return, Escape, Up Arrow, Shift-Command-C. Paths through menus and settings use `>`.

On the Mac, people click and choose. They press only keys and never tap. The Clear History sheet follows Safari. It has a "Clear:" popup with lowercase ranges and a destructive Clear History button.

## 3. Typography

ClipDeck uses SF, the system font, for everything except the app's name. The app's name uses Instrument Serif Regular, a condensed high contrast serif. The name is 34 points in About and 36 points on the disk image, with no tracking. The app's name is the only place where a second typeface appears.

Instrument Serif never sets a sentence. Use light to regular weights with generous tracking. Use opacity before size to differentiate text. Set type with `deckFont(_:)`, which applies the size, weight, and tracking together.

| Role | Size | Weight | Tracking | Swift |
|---|---|---|---|---|
| Wordmark | 34 | Instrument Serif Regular | 0 | `.deckFont(.wordmark)` |
| Title | 20 | semibold | 0 | `.deckFont(.title)` |
| Search | 20 | regular | 0 | `.deckFont(.search)` |
| Body | 15 | regular | 0.35 | `.deckFont(.body)` |
| Label | 13 | medium | 0.3 | `.deckFont(.label)` |
| Caption | 11 | light | 0.5 | `.deckFont(.caption)` |
| Mono (key hints, text preview) | 12 | regular, monospaced | 0.5 | `.deckFont(.mono)` |

Search uses the Title size at regular weight. The field is where the eye goes when the panel opens, so it gets Title size without Title's weight.

## 4. Space and radius

Use one ramp for each and no other numbers.

- Space: `4 8 12 16 20 24 32 40` (`Space.xxs` through `Space.xxxl`)
- Radius: `4 8 12 20` (`Radius.xs`, `sm`, `md`, `lg`)
  - Thumbnails and key hints: 4
  - Rows: 8
  - Panel: 20, the glass corner
  - HUD: a capsule, half its height

## 5. Motion

Motion has two kinds: SwiftUI curves for the panel and springs for the copy confirmation. Lottie handles the two drawn animations.

| Token | Curve | Duration | Use |
|---|---|---|---|
| `Anim.quick` | ease-out | 0.2 | Press and quick state changes |
| `Anim.standard` | cubic-bezier(0.16, 1, 0.3, 1) | 0.35 | Panel entrance |
| `Anim.entrance` | cubic-bezier(0.16, 1, 0.3, 1) | 0.8 | Larger reveals |
| `Spring.arrive` | response 0.45, damping fraction 0.72 | settles in about 0.6 | HUD drops below the menu bar with one small overshoot |
| `Spring.depart` | response 0.35, damping fraction 1 | about 0.35 | HUD leaves with no bounce |

The pill's layer uses `CASpringAnimation`s. The table states each spring's response and damping fraction. `CopyHUDController.Spring` converts them to stiffness and damping.

### The drawn animations

| File | Canvas | Length | What happens |
|---|---|---|---|
| `paperclip.json` | 120 × 120 | 2.9 s loop | A wire 7 points thick draws on over 1.2 s. It holds, unwinds from its start over 0.6 s, and repeats |
| `copied.json` | 60 × 60 | 1 s | A ring draws on over 0.43 s. At 0.23 s, a check draws on inside it and pops from 70% to 108% to 100% |

Both use white strokes tinted at run time with `accent` through `DeckAnimation`. Every animation uses this component. Their generator is `scripts/make-animations.py`.

### Rules

- Enter fast, settle slow. The panel fades in and drops 8 points into place. The panel closes instantly. The HUD arrives on a spring and leaves on a stiffer one.
- One thing moves at a time.
- Nothing animates while off screen. Every `DeckAnimation` takes `isActive` and pauses when its surface is hidden.
- Reduce Motion turns every animation off. `Anim.allowed(_:reduceMotion:)` returns nil. The HUD fades in place. Each Lottie animation shows its final frame.

## 6. Coherence checklist

A surface matches this design only if all of these hold:

- [ ] Use macOS glass, only the system accent, and label-color fills at the opacities above.
- [ ] Use the system font and type roles above.
- [ ] Use spacing and radius from the ramps.
- [ ] Use motion from the token set and animations through `DeckAnimation`. Nothing moves when Reduce Motion is on.
- [ ] Write copy in Apple's register. Use title style for controls, sentence style for messages, and Apple's key names.

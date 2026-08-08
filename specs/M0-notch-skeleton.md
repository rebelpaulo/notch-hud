# M0 spec — Notch skeleton (for GPT-5.6 Sol to implement)

Build the thinnest walking skeleton of a macOS notch HUD app. This milestone is UI scaffolding only: NO session detection, NO Codex/Claude hooks, NO focus logic yet. Hardcode the data. Target macOS 14, Swift 6, SwiftUI + AppKit, SPM executable.

## Deliverables (create these files under the repo root)

### 1. `Package.swift`
- swift-tools-version 6.0
- Platform: `.macOS(.v14)`
- One executable target `Vibenotch` in `Sources/Vibenotch`
- Dependency: DynamicNotchKit — `.package(url: "https://github.com/MrKai77/DynamicNotchKit.git", from: "1.1.0")`, product `"DynamicNotchKit"` (verify the exact product name from the package; adjust if it differs)
- Resource handling: none needed yet

### 2. `Sources/Vibenotch/App/VibenotchApp.swift`
- `@main` struct using `NSApplicationDelegateAdaptor`
- In `applicationDidFinishLaunching`: set `NSApp.setActivationPolicy(.accessory)` (agent app, no Dock icon), create `AppEnvironment`, boot a `NotchWindowManager`
- Also set `LSUIElement` via an Info.plist (see file 6) — do both the plist key and the runtime `.accessory` call
- Observe `NSApplication.didChangeScreenParametersNotification` and tell `NotchWindowManager` to re-pin to the built-in (notched) screen

### 3. `Sources/Vibenotch/App/AppEnvironment.swift`
- Holds constants: `spoolURL = ~/.vibenotch/sessions` (create the dir, 0700, on init), staleness thresholds (`workingStaleSeconds = 90`, `dropSeconds = 900`)
- Pure data/config holder for now (later milestones inject the store here)

### 4. `Sources/Vibenotch/Notch/NotchWindowManager.swift`
- Wraps DynamicNotchKit. Read the package's current API from Package.resolved / its README-style symbols and use the real types (e.g. `DynamicNotch`, `DynamicNotchInfo`, `.expand()/.hide()` or whatever the installed version exposes). Do not invent API — inspect the checked-out source under `.build/checkouts/DynamicNotchKit`.
- Two visual states:
  - **peek** (at rest): a compact view (`NotchPeekView`) showing a hardcoded count, e.g. "3" with three small colored dots (blue/yellow/green). Panel `ignoresMouseEvents = true` in this state.
  - **expanded** (on hover): `NotchPanelView` — a dark rounded panel that drops below the notch showing a hardcoded static list of 3 fake sessions (project name + a colored status dot). Mouse enabled.
- Pin to the screen where `NSScreen.safeAreaInsets.top > 0` (built-in notched display). If none has a notch (`safeAreaInsets.top == 0` everywhere), fall back to a top-center floating pill using the same views (DynamicNotchKit may handle this; if not, log it and still show the pill).

### 5. `Sources/Vibenotch/Notch/HoverController.swift`
- Hybrid hover detection:
  - An always-on invisible borderless non-activating `NSPanel` positioned exactly over the notch rect, with an `NSTrackingArea` (`.mouseEnteredAndExited`, `.activeAlways`) → fires enter/exit.
  - Plus `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` as a fallback that hit-tests the cursor against the notch rect (throttle to ~30fps; cheap rect test).
  - Plus a local monitor for events over the app's own expanded window so in-panel hover doesn't collapse it.
- Debounce: ~120ms on enter, ~300ms on exit. Enter → `NotchWindowManager.expand()`, exit → `.collapse()`.
- Compute the notch rect from `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` (the gap between them is the notch) on the built-in screen.

### 6. `Sources/Vibenotch/Info.plist` (and wire it into Package.swift `linkerSettings` or via `unsafeFlags` `-Xlinker -sectcreate`… — simplest: use a `.plist` and `swiftSettings`/`linkerSettings` to embed, or document how `swift run` picks it up)
- `LSUIElement = true`, `LSMinimumSystemVersion = 14.0`, `CFBundleName = Vibenotch`, `CFBundleIdentifier = com.rebelpaulo.vibenotch`
- If embedding the plist into an SPM executable is awkward, instead set the activation policy purely at runtime (`.accessory`) AND note in a `README.md` that a proper `.app` bundle + Info.plist comes in M6. Runtime `.accessory` is sufficient to hide the Dock icon for M0.

### 7. Placeholder SwiftUI views
- `Sources/Vibenotch/Notch/NotchPeekView.swift` and `NotchPanelView.swift` and `SessionRowView.swift`. Dark background (`Color(red:0.04,green:0.04,blue:0.047)`), white text, colored status dots (blue `#0A84FF`, yellow `#FFD60A`, green `#30D158`). Rounded corners ~10pt. Keep it clean; real design is M6.

## Constraints
- Must compile with `swift build` on macOS 26 / Swift 6.1 targeting macOS 14.
- No force-unwraps that can crash at launch. No private APIs.
- If DynamicNotchKit's API differs from assumptions, adapt to the real installed API (inspect `.build/checkouts/DynamicNotchKit/Sources`). Prefer using the library over hand-rolling the notch window.
- Keep everything hardcoded/static. The goal is: it builds, it runs, and hovering the notch shows a panel.

## Acceptance (the GATE — manager verifies, do not self-certify)
1. `swift build` exits 0 with no errors.
2. `swift run` launches with no Dock icon.
3. Hovering the notch expands a dark panel listing 3 fake sessions; moving away collapses it.
4. App survives switching to another Space and opening a fullscreen app (panel still reachable).

Write all files now. After writing, run `swift build` yourself and fix any compile errors before reporting done.

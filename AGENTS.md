# AnyDrag

macOS menu bar utility that lets you move any window by holding a modifier key and dragging anywhere on it -- bypasses Accessibility API lag by simulating a native title bar drag at the window server level.

## Tech Stack
- Swift 5.9, macOS 13.0+. AppKit core (engine, menu bar, overlays); the Settings window is SwiftUI hosted in an `NSHostingController`.
- XcodeGen (`project.yml`) generates the Xcode project
- Localized: English, Simplified Chinese (via `Localizable.strings` + `LocalizationOverride`; SwiftUI reads them through the `L(_:)` helper)

## Architecture
- `main.swift` -- manual NSApplication setup (no storyboards, no @main)
- `DragEngine` -- CGEvent tap on a dedicated high-priority thread intercepts mouse events when modifier held
- `TitleBarDragStrategy` -- rewrites mouse coordinates to title bar region so the window server handles the drag natively (zero per-frame IPC)
- `MenuBarController` -- NSStatusItem menu bar UI
- `TilingPanel` -- right-click tiling overlay (halves, quarters, fill)
- `KeyboardShortcuts` + the hot-key section of `DragEngine` -- optional global shortcuts for the tile actions (issue #40), registered with Carbon `RegisterEventHotKey` (no Input Monitoring permission needed, unlike a keyDown event tap); off by default; released while an excluded app or AnyDrag itself is frontmost
- `PermissionManager` -- Accessibility permission prompt
- Settings (`Sources/Settings/`) -- a SwiftUI `NavigationSplitView` with a native System-Settings-style sidebar, aligned with the sibling app HyperCapslock. `PreferencesWindowController` hosts `SettingsRootView`; `SettingsStore` is the one ObservableObject bridging SwiftUI bindings to the live `DragEngine` + `Preferences` (UserDefaults) + `Analytics`. Pages: Window Drag / Window Resize / Middle Click / Keyboard Shortcuts / Excluded Apps / General / More Apps / About.
- More Apps -- the sidebar page listing the author's other apps, with a Get button that downloads, verifies, installs and opens one. All of it (catalog, installer, views, analytics event names) comes from the shared `MoreAppsKit` Swift package, which the sibling apps embed too; AnyDrag only adds `MoreAppsSettingsPage` (the wrapper), the entry row on the About page, and `Analytics.trackMoreApps`. `SettingsStore.moreApps` owns the package's store. See the package's README for the catalog format and how to add an app.

## Build
```bash
brew install xcodegen
xcodegen generate
open AnyDrag.xcodeproj  # then Cmd+R
```

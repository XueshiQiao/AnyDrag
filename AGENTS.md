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
- `PermissionManager` -- Accessibility permission prompt
- Settings (`Sources/Settings/`) -- a SwiftUI `NavigationSplitView` with a native System-Settings-style sidebar, aligned with the sibling app HyperCapslock. `PreferencesWindowController` hosts `SettingsRootView`; `SettingsStore` is the one ObservableObject bridging SwiftUI bindings to the live `DragEngine` + `Preferences` (UserDefaults) + `Analytics`. Pages: Window Drag / Window Resize / Middle Click / Excluded Apps / General / About.

## Build
```bash
brew install xcodegen
xcodegen generate
open AnyDrag.xcodeproj  # then Cmd+R
```

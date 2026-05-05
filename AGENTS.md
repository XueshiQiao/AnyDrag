# AnyDrag

macOS menu bar utility that lets you move any window by holding a modifier key and dragging anywhere on it -- bypasses Accessibility API lag by simulating a native title bar drag at the window server level.

## Tech Stack
- Swift 5.9, AppKit (no SwiftUI), macOS 13.0+
- No third-party dependencies
- XcodeGen (`project.yml`) generates the Xcode project
- Localized: English, Simplified Chinese

## Architecture
- `main.swift` -- manual NSApplication setup (no storyboards, no @main)
- `DragEngine` -- CGEvent tap on a dedicated high-priority thread intercepts mouse events when modifier held
- `TitleBarDragStrategy` -- rewrites mouse coordinates to title bar region so the window server handles the drag natively (zero per-frame IPC)
- `MenuBarController` -- NSStatusItem menu bar UI
- `TilingPanel` -- right-click tiling overlay (halves, quarters, fill)
- `PermissionManager` -- Accessibility permission prompt

## Build
```bash
brew install xcodegen
xcodegen generate
open AnyDrag.xcodeproj  # then Cmd+R
```

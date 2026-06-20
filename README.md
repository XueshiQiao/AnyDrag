# AnyDrag

[中文文档](README_CN.md)

**Drags as smoothly as a native title bar — no other modifier-drag tool on macOS matches it.**

Move any window by holding a modifier key and dragging anywhere on the window — no need to grab the title bar.

https://github.com/user-attachments/assets/82b18801-0f96-4e9d-b05a-ac7cdd18d490

## Why AnyDrag?

Tools like BetterTouchTool offer similar modifier+drag features, but they move windows through the Accessibility API — an indirect path that goes through the target app's process, adding noticeable lag. AnyDrag takes a different approach: it simulates a native title bar drag at the window server level, achieving the same smoothness as dragging a title bar by hand.

## Install

### Homebrew

```bash
brew install --cask XueshiQiao/tap/anydrag
```

### Manual

Download the latest `.dmg` from [Releases](https://github.com/XueshiQiao/AnyDrag/releases), open it, and drag AnyDrag to your Applications folder.

---

The app is signed with an Apple Developer ID certificate and notarized by Apple, so you can install it without any security warnings.

On first launch, macOS will ask for **Accessibility permission** — this is required to detect modifier keys and move windows.

## Usage

1. Launch AnyDrag — it lives in your menu bar
2. Hold **Option** (default) and drag any window
3. Hold the modifier key and **double-click** a window to maximize it; double-click again to restore its original size
4. Hold the modifier key and **right-click** a window to open the **tiling panel** — quickly snap windows to halves, corners, or arrange multiple windows side by side
5. Or set **Middle-click action** to *Tile by direction*, then hold the middle button and drag toward an edge or corner — on a multi-monitor setup the panel lays out every display so you can pick any display × any zone in one gesture
6. Click the menu bar icon to change the modifier key or toggle on/off

If macOS "Hold Option key while dragging windows to tile" is enabled and AnyDrag's modifier is not `Option`, you can also hold `Option` as an extra key to use native tiling. For example, with AnyDrag set to `fn`, `fn + option + drag` starts a native drag from anywhere in the window and still triggers system tiling.

## Screenshots

<img src="screenshots/AnyDrag-drag-en.jpg" width="700" alt="AnyDrag" />

<img src="screenshots/AnyDrag-middle-mouse-en.jpg" width="700" alt="Middle-click → Tile by direction" />



### Supported Modifiers

- Option
- Command
- Control
- fn
- Option + Command
- ...

## Requirements

- macOS 13+

## Build from Source

```bash
brew install xcodegen
git clone https://github.com/XueshiQiao/AnyDrag.git
cd AnyDrag
xcodegen generate
open AnyDrag.xcodeproj
```

Then build and run in Xcode (⌘R).

## Known Issues

- When used together with macOS three-finger drag, there is a one-frame snap flicker at drag-end.

## License

GPL-3.0

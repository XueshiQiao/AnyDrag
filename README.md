# AnyDrag

[中文文档](README_CN.md)

Move any window by holding a modifier key and dragging anywhere on the window — no need to grab the title bar.

<!-- ![AnyDrag Demo](demo.png) -->

## Why AnyDrag?

Tools like BetterTouchTool offer similar modifier+drag features, but they move windows through the Accessibility API — an indirect path that goes through the target app's process, adding noticeable lag. AnyDrag takes a different approach: it simulates a native title bar drag at the window server level, achieving the same smoothness as dragging a title bar by hand.

## Install

Download the latest `.dmg` from [Releases](https://github.com/XueshiQiao/AnyDrag/releases), open it, and drag AnyDrag to your Applications folder.

The app is signed with an Apple Developer ID certificate and notarized by Apple, so you can install it without any security warnings.

On first launch, macOS will ask for **Accessibility permission** — this is required to detect modifier keys and move windows.

## Usage

1. Launch AnyDrag — it lives in your menu bar
2. Hold **Option** (default) and drag any window
3. Hold the modifier key and **double-click** a window to maximize it; double-click again to restore its original size
4. Hold the modifier key and **right-click** a window to open the **tiling panel** — quickly snap windows to halves, corners, or arrange multiple windows side by side

   ![Tiling Panel](tiling_panel.png)
5. Click the menu bar icon to change the modifier key or toggle on/off

If macOS "Hold Option key while dragging windows to tile" is enabled and AnyDrag's modifier is not `Option`, you can also hold `Option` as an extra key to use native tiling. For example, with AnyDrag set to `fn`, `fn + option + drag` starts a native drag from anywhere in the window and still triggers system tiling.

### Supported Modifiers

- Option
- Command
- Control
- fn
- Option + Command

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

## License

GPL-3.0

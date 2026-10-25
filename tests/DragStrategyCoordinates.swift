import Cocoa
import ApplicationServices

// Isolate the real drag strategy from preferences and the visual debug overlay.
// The test never runs AppKit's main loop or activates a real target window.
enum Preferences {
    static let defaultTitleBarYOffset: CGFloat = 4
    static let defaultTitleBarLeftInset: CGFloat = 80
    static let defaultTitleBarRightInset: CGFloat = 80
}
struct TitleBarXOffsets {
    var left: CGFloat
    var right: CGFloat
}
final class DebugDotOverlay {
    func flash(at: CGPoint, caption: String?) {}
}

@main
struct DragStrategyCoordinatesTest {
    static func main() {
        var failures = 0
        let display = CGDisplayBounds(CGMainDisplayID())
        for fixedX in [false, true] {
            for middleButton in [false, true] {
                for origin in [CGPoint(x: 100, y: 200), CGPoint(x: -1200, y: -100),
                               CGPoint(x: display.minX + 20, y: display.minY + 40)] {
                    for fraction: CGFloat in [0, 0.125, 0.453125, 0.828125] {
                        let strategy = TitleBarDragStrategy(coveringPID: { _, _ in nil })
                        strategy.useFixedTitleBarX = fixedX
                        let start = CGPoint(x: origin.x + 100 + fraction, y: origin.y + 150 + fraction)
                        let down = mouse(middleButton ? .otherMouseDown : .leftMouseDown, at: start)
                        _ = strategy.handleMouseDown(pid: getpid(), windowID: 0,
                            windowFrame: CGRect(origin: origin, size: CGSize(width: 586, height: 488)), event: down, rewriteToLeftButton: middleButton)
                        let first = mouse(middleButton ? .otherMouseDragged : .leftMouseDragged, at: CGPoint(x: start.x + 1, y: start.y + 1))
                        _ = strategy.handleMouseDragged(event: first)
                        let frame = CGRect(origin: origin, size: CGSize(width: 586, height: 488))
                        let targetX = frame.minX + Preferences.defaultTitleBarLeftInset
                        if fixedX && display.contains(CGPoint(x: targetX, y: origin.y + 4)) && first.location.x != targetX {
                            print("FAIL: fixed-X drag did not start at left inset")
                            failures += 1
                        }
                        // Settings changes during a gesture must not change its anchor.
                        strategy.useFixedTitleBarX.toggle()
                        strategy.titleBarLeftInset = 150
                        strategy.titleBarRightInset = 200
                        let moved = mouse(middleButton ? .otherMouseDragged : .leftMouseDragged, at: CGPoint(x: start.x + 14.625, y: start.y + 34.734375))
                        _ = strategy.handleMouseDragged(event: moved)
                        let up = mouse(middleButton ? .otherMouseUp : .leftMouseUp, at: CGPoint(x: start.x + 14.625, y: start.y + 34.734375))
                        _ = strategy.handleMouseUp(event: up)
                        if first.type != .leftMouseDown || moved.type != .leftMouseDragged || up.type != .leftMouseUp {
                            print("FAIL: synthetic drag uses incorrect button event types")
                            failures += 1
                        }
                        let translation = CGPoint(x: up.location.x - first.location.x,
                                                  y: up.location.y - first.location.y)
                        if translation.x != translation.x.rounded() || translation.y != translation.y.rounded() {
                            print("FAIL: native drag ends at fractional translation \(translation)")
                            failures += 1
                        }
                        if moved.location != up.location || strategy.isActive {
                            print("FAIL: release changes final position or leaves strategy active")
                            failures += 1
                        }
                        if abs(translation.x - 14.625) > 1 || abs(translation.y - 34.734375) > 1 {
                            print("FAIL: drag no longer follows pointer displacement")
                            failures += 1
                        }
                    }
                }
            }
        }
        // An app-specific override enables fixed X even when the global option is off.
        for middleButton in [false, true] {
            let strategy = TitleBarDragStrategy(coveringPID: { _, _ in nil })
            strategy.titleBarLeftInset = 300
            let frame = CGRect(x: display.minX + 20, y: display.minY + 40, width: 586, height: 488)
            let start = CGPoint(x: frame.minX + 100.125, y: frame.minY + 150.125)
            _ = strategy.handleMouseDown(pid: getpid(), windowID: 0, windowFrame: frame,
                event: mouse(.leftMouseDown, at: start), rewriteToLeftButton: middleButton,
                titleBarXOffsets: TitleBarXOffsets(left: 37, right: 113))
            let first = mouse(.leftMouseDragged, at: start)
            _ = strategy.handleMouseDragged(event: first)
            let up = mouse(.leftMouseUp, at: CGPoint(x: start.x + 10, y: start.y + 20))
            _ = strategy.handleMouseUp(event: up)
            if first.location.x != frame.minX + 37 || up.location.x != first.location.x + 10 {
                print("FAIL: per-app override was not applied independently of global mode and inset")
                failures += 1
            }
        }
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800)]
        for (frame, leftInset, rightInset, expected) in [
            // Left wins while both anchors are visible; offsets are independent.
            (CGRect(x: 100, y: 100, width: 600, height: 400), CGFloat(60), CGFloat(120), CGFloat(160)),
            // Clamp inside narrow windows.
            (CGRect(x: 100, y: 100, width: 50, height: 400), CGFloat(80), CGFloat(80), CGFloat(142)),
            (CGRect(x: 100, y: 100, width: 10, height: 400), CGFloat(80), CGFloat(80), CGFloat(105)),
            // Left offscreen: use the independently configured right anchor.
            (CGRect(x: -200, y: 100, width: 600, height: 400), CGFloat(60), CGFloat(120), CGFloat(280)),
            // Right offscreen: still prefer the visible left anchor.
            (CGRect(x: 800, y: 100, width: 600, height: 400), CGFloat(60), CGFloat(120), CGFloat(860)),
            // Both anchors offscreen: preserve the original mouse X.
            (CGRect(x: -200, y: 100, width: 1600, height: 400), CGFloat(60), CGFloat(120), CGFloat(825))
        ] {
            let actual = TitleBarDragStrategy.titleBarX(cursorX: 825.125, windowFrame: frame,
                titleBarY: frame.minY + 4, leftInset: leftInset, rightInset: rightInset, displayBounds: screens)
            if actual != expected {
                print("FAIL: target X \(actual), expected \(expected)")
                failures += 1
            }
        }
        let multiDisplayX = TitleBarDragStrategy.titleBarX(cursorX: 125, windowFrame:
            CGRect(x: -900, y: -100, width: 1200, height: 400), titleBarY: -96,
            leftInset: 60, rightInset: 120, displayBounds:
            screens + [CGRect(x: -1000, y: -200, width: 1000, height: 800)])
        if multiDisplayX != -840 {
            print("FAIL: visible left anchor on secondary display was not preferred")
            failures += 1
        }
        guard failures == 0 else { exit(1) }
        print("PASS: 50 left/middle-button drag sequences including per-app overrides preserve movement and release; fixed anchors, narrow windows, offscreen fallback, and multiple displays checked")
    }

    static func mouse(_ type: CGEventType, at point: CGPoint) -> CGEvent {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
        event.flags = [.maskControl, .maskAlternate]
        return event
    }
}

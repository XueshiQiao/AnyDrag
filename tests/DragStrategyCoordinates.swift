import Cocoa
import ApplicationServices

// Isolate the real drag strategy from preferences and the visual debug overlay.
// The test never runs AppKit's main loop or activates a real target window.
enum Preferences {
    static let defaultTitleBarYOffset: CGFloat = 4
}
final class DebugDotOverlay {
    func flash(at: CGPoint, caption: String?) {}
}

@main
struct DragStrategyCoordinatesTest {
    static func main() {
        var failures = 0
        for origin in [CGPoint(x: 100, y: 200), CGPoint(x: -1200, y: -100)] {
            for fraction: CGFloat in [0, 0.125, 0.453125, 0.828125] {
                let strategy = TitleBarDragStrategy()
                let start = CGPoint(x: origin.x + 100 + fraction, y: origin.y + 150 + fraction)
                let down = mouse(.leftMouseDown, at: start)
                _ = strategy.handleMouseDown(pid: getpid(), windowID: 0,
                    windowFrame: CGRect(origin: origin, size: CGSize(width: 586, height: 488)), event: down)
                let first = mouse(.leftMouseDragged, at: CGPoint(x: start.x + 1, y: start.y + 1))
                _ = strategy.handleMouseDragged(event: first)
                let moved = mouse(.leftMouseDragged, at: CGPoint(x: start.x + 14.625, y: start.y + 34.734375))
                _ = strategy.handleMouseDragged(event: moved)
                let up = mouse(.leftMouseUp, at: CGPoint(x: start.x + 14.625, y: start.y + 34.734375))
                _ = strategy.handleMouseUp(event: up)
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
        guard failures == 0 else { exit(1) }
        print("PASS: 8 native drag sequences finish at whole-point translations and release cleanly")
    }

    static func mouse(_ type: CGEventType, at point: CGPoint) -> CGEvent {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
        event.flags = [.maskControl, .maskAlternate]
        return event
    }
}

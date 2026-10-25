import Cocoa
import ApplicationServices

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

// Interpose the AX entry points at compile time, exercising the real strategy
// without focusing or rearranging the user's desktop. The three opaque handles
// stand for one app and two sibling windows; only the selected window may rise.
private let app = ApplicationServices.AXUIElementCreateApplication(900001)
private let sibling = ApplicationServices.AXUIElementCreateApplication(900002)
private let selected = ApplicationServices.AXUIElementCreateApplication(900003)
private let selectedOrigin = CGPoint(x: 200, y: 200)
private var writes: [(AXUIElement, String)] = []
private var raises: [AXUIElement] = []
private var failRaise = false
private var missingWindow = false
private var failMain = false

func AXUIElementCreateApplication(_ pid: pid_t) -> AXUIElement { app }

@discardableResult
func AXUIElementCopyAttributeValue(_ element: AXUIElement, _ attribute: CFString,
                                  _ value: UnsafeMutablePointer<CFTypeRef?>) -> AXError {
    switch attribute as String {
    case kAXWindowsAttribute:
        value.pointee = (missingWindow ? [] : [sibling, selected]) as CFArray
    case kAXPositionAttribute:
        var origin = CFEqual(element, selected) ? selectedOrigin : CGPoint(x: 700, y: 200)
        value.pointee = AXValueCreate(.cgPoint, &origin)
    default:
        return .attributeUnsupported
    }
    return .success
}

@discardableResult
func AXUIElementSetAttributeValue(_ element: AXUIElement, _ attribute: CFString,
                                 _ value: CFTypeRef) -> AXError {
    writes.append((element, attribute as String))
    return failMain ? .cannotComplete : .success
}

func AXUIElementPerformAction(_ element: AXUIElement, _ action: CFString) -> AXError {
    precondition(action as String == kAXRaiseAction)
    raises.append(element)
    return failRaise ? .actionUnsupported : .success
}

@main
struct DragWindowFocusTest {
    static func main() {
        var failures = 0
        var cases = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition { print("FAIL: " + message); failures += 1 }
        }
        let frame = CGRect(origin: selectedOrigin, size: CGSize(width: 500, height: 400))
        let start = CGPoint(x: 300, y: 350)
        let otherApp: pid_t = 777

        // Target selection and activation. Only the selected window may rise;
        // activation never asks for all windows; a floating panel never activates
        // its app. When the AX window can't be found the app-wide AXFrontmost
        // that shipped before is the fallback.
        for middleButton in [false, true] {
            for unsupportedRaise in [false, true] {
                for noWindow in [false, true] {
                    for activateApp in [false, true] {
                        cases += 1
                        writes = []
                        raises = []
                        failRaise = unsupportedRaise
                        missingWindow = noWindow
                        var activated = false
                        let strategy = TitleBarDragStrategy(activateApplication: { pid, options in
                            check(pid == 900001 && options.isEmpty, "activation requests all windows or the wrong app")
                            check(raises.last.map { CFEqual($0, selected) } == true, "activation precedes target selection")
                            check(writes.contains { CFEqual($0.0, selected) && $0.1 == kAXMainAttribute },
                                  "activation can bring an unrelated main window forward")
                            activated = true
                            return true
                        }, coveringPID: { _, _ in nil })
                        _ = strategy.handleMouseDown(pid: 900001, windowID: 42, windowFrame: frame,
                            event: mouse(middleButton ? .otherMouseDown : .leftMouseDown, start),
                            rewriteToLeftButton: middleButton, activateApp: activateApp)
                        check(activated == (!noWindow && activateApp), "inactive target not activated, or floating panel activates")
                        let appWrites = writes.filter { CFEqual($0.0, app) }
                        check(appWrites.count == (noWindow && activateApp ? 1 : 0)
                              && appWrites.allSatisfy { $0.1 == kAXFrontmostAttribute },
                              "app-wide AXFrontmost used when AppKit activation works, or missing when the window can't be found")
                        check(raises.count == (noWindow ? 0 : 1) && !raises.contains { !CFEqual($0, selected) },
                              "raises a sibling instead of the selected window")
                        let windowWrites = writes.filter { !CFEqual($0.0, app) }
                        let expectedWrites = !noWindow && (activateApp || unsupportedRaise) ? 1 : 0
                        check(windowWrites.count == expectedWrites && !windowWrites.contains {
                            !CFEqual($0.0, selected) || $0.1 != kAXMainAttribute
                        }, "main-window selection changes another window")
                        let first = mouse(middleButton ? .otherMouseDragged : .leftMouseDragged, start)
                        _ = strategy.handleMouseDragged(event: first)
                        let up = mouse(middleButton ? .otherMouseUp : .leftMouseUp, start)
                        _ = strategy.handleMouseUp(event: up)
                        check(first.type == .leftMouseDown && first.location == CGPoint(x: 300, y: 204)
                              && up.type == .leftMouseUp && !strategy.isActive, "native drag lifecycle changed")
                    }
                }
            }
        }

        // Successful activation is not proof that the target is exposed yet.
        // While another app covers the click point, hold the press back — but
        // only for the grace period. The check may delay the press, never
        // cancel the drag.
        for middleButton in [false, true] {
            cases += 1
            missingWindow = false
            failRaise = false
            var coverer: pid_t? = otherApp
            var clock: TimeInterval = 0
            let strategy = TitleBarDragStrategy(activateApplication: { _, _ in true },
                coveringPID: { window, _ in window == 42 ? coverer : nil }, now: { clock })
            _ = strategy.handleMouseDown(pid: 900001, windowID: 42, windowFrame: frame,
                event: mouse(.leftMouseDown, start), rewriteToLeftButton: middleButton)
            check(strategy.handleMouseDragged(event: mouse(.leftMouseDragged, start)) == nil,
                  "synthetic press clicks the covering app before activation completes")
            clock = 0.05
            coverer = nil
            let first = mouse(.leftMouseDragged, start)
            check(strategy.handleMouseDragged(event: first) != nil && first.type == .leftMouseDown,
                  "doesn't start dragging after the target becomes exposed")
            _ = strategy.handleMouseUp(event: mouse(.leftMouseUp, start))

            // Released while the press is still held back: nothing was pressed,
            // so nothing may be released.
            cases += 1
            strategy.reset()
            clock = 0
            coverer = otherApp
            _ = strategy.handleMouseDown(pid: 900001, windowID: 42, windowFrame: frame,
                event: mouse(.leftMouseDown, start), rewriteToLeftButton: middleButton)
            check(strategy.handleMouseDragged(event: mouse(.leftMouseDragged, start)) == nil,
                  "press sent while another app covers the target")
            check(strategy.handleMouseUp(event: mouse(.leftMouseUp, start)) == nil && !strategy.isActive,
                  "held-back startup leaks an unmatched mouse-up")

            // Grace period over and another app still covers the point: send the
            // press anyway (the behaviour that shipped before the check).
            cases += 1
            strategy.reset()
            clock = 0
            coverer = otherApp
            _ = strategy.handleMouseDown(pid: 900001, windowID: 42, windowFrame: frame,
                event: mouse(.leftMouseDown, start), rewriteToLeftButton: middleButton)
            clock = TitleBarDragStrategy.startupGracePeriod
            let late = mouse(.leftMouseDragged, start)
            check(strategy.handleMouseDragged(event: late) != nil && late.type == .leftMouseDown
                  && late.location == CGPoint(x: 300, y: 204),
                  "drag cancelled instead of falling back to the plain press after the grace period")
            let lateUp = mouse(.leftMouseUp, start)
            check(strategy.handleMouseUp(event: lateUp) != nil && lateUp.type == .leftMouseUp && !strategy.isActive,
                  "mouse-up swallowed after a late press")

            // A window of the target's own app over the point — a sheet, a child
            // window, a transparent helper — must not delay the press at all.
            cases += 1
            strategy.reset()
            clock = 0
            coverer = 900001
            _ = strategy.handleMouseDown(pid: 900001, windowID: 42, windowFrame: frame,
                event: mouse(.leftMouseDown, start), rewriteToLeftButton: middleButton)
            let sameApp = mouse(.leftMouseDragged, start)
            check(strategy.handleMouseDragged(event: sameApp) != nil && sameApp.type == .leftMouseDown,
                  "same-app window over the title bar blocks the drag")
            _ = strategy.handleMouseUp(event: mouse(.leftMouseUp, start))
        }

        // Failed main-window selection or a declined activation request falls
        // back to the app-wide AXFrontmost that shipped before, and never asks
        // AppKit for all windows. The drag still goes out after the grace period.
        for middleButton in [false, true] {
            for selectionFails in [false, true] {
                cases += 1
                writes = []
                raises = []
                missingWindow = false
                failRaise = false
                failMain = selectionFails
                var activationCount = 0
                var clock: TimeInterval = 0
                let strategy = TitleBarDragStrategy(activateApplication: { _, options in
                    check(options.isEmpty, "denied activation falls back to all windows")
                    activationCount += 1
                    return false
                }, coveringPID: { _, _ in otherApp }, now: { clock })
                _ = strategy.handleMouseDown(pid: 900001, windowID: 42, windowFrame: frame,
                    event: mouse(.leftMouseDown, start), rewriteToLeftButton: middleButton)
                check(activationCount == (selectionFails ? 0 : 1), "activation ignores failed target selection")
                check(writes.filter { CFEqual($0.0, app) }.map { $0.1 } == [kAXFrontmostAttribute],
                      "declined activation has no AXFrontmost fallback")
                check(strategy.handleMouseDragged(event: mouse(.leftMouseDragged, start)) == nil,
                      "press sent while another app still covers the target")
                clock = 0.3
                let late = mouse(.leftMouseDragged, start)
                check(strategy.handleMouseDragged(event: late) != nil && late.type == .leftMouseDown,
                      "drag cancelled after declined activation")
                check(strategy.handleMouseUp(event: mouse(.leftMouseUp, start)) != nil,
                      "mouse-up swallowed after a late press")
                failMain = false
            }
        }
        guard failures == 0 else { exit(1) }
        print("PASS: \(cases) focus cases cover selected-window activation, panels, delayed exposure, same-app cover, grace-period fallback and activation fallback")
    }

    static func mouse(_ type: CGEventType, _ point: CGPoint) -> CGEvent {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
    }
}

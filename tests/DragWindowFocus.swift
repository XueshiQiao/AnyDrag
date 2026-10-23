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
                        }, windowIsExposed: { _, _ in true })
                        let start = CGPoint(x: 300, y: 350)
                        _ = strategy.handleMouseDown(pid: 900001, windowID: 42,
                            windowFrame: CGRect(origin: selectedOrigin, size: CGSize(width: 500, height: 400)),
                            event: mouse(middleButton ? .otherMouseDown : .leftMouseDown, start),
                            rewriteToLeftButton: middleButton, activateApp: activateApp)
                        check(activated == (!noWindow && activateApp), "inactive target not activated, or floating panel activates")
                        check(!writes.contains { CFEqual($0.0, app) }, "app-wide AXFrontmost activation")
                        check(raises.count == (noWindow ? 0 : 1) && !raises.contains { !CFEqual($0, selected) },
                              "raises a sibling instead of the selected window")
                        let expectedWrites = !noWindow && (activateApp || unsupportedRaise) ? 1 : 0
                        check(writes.count == expectedWrites && !writes.contains {
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
        // Hold back the real synthetic down until the compositor confirms it.
        for middleButton in [false, true] {
            cases += 1
            missingWindow = false
            failRaise = false
            var ready = false
            var clock: TimeInterval = 0
            let strategy = TitleBarDragStrategy(activateApplication: { _, _ in true },
                windowIsExposed: { window, _ in window == 42 && ready }, now: { clock })
            let start = CGPoint(x: 300, y: 350)
            _ = strategy.handleMouseDown(pid: 900001, windowID: 42,
                windowFrame: CGRect(origin: selectedOrigin, size: CGSize(width: 500, height: 400)),
                event: mouse(.leftMouseDown, start), rewriteToLeftButton: middleButton)
            check(strategy.handleMouseDragged(event: mouse(.leftMouseDragged, start)) == nil,
                  "synthetic press clicks the covering app before activation completes")
            clock = 0.05
            ready = true
            let first = mouse(.leftMouseDragged, start)
            check(strategy.handleMouseDragged(event: first) != nil && first.type == .leftMouseDown,
                  "doesn't start dragging after the target becomes exposed")
            _ = strategy.handleMouseUp(event: mouse(.leftMouseUp, start))

            cases += 1
            strategy.reset()
            clock = 0
            ready = false
            _ = strategy.handleMouseDown(pid: 900001, windowID: 42,
                windowFrame: CGRect(origin: selectedOrigin, size: CGSize(width: 500, height: 400)),
                event: mouse(.leftMouseDown, start), rewriteToLeftButton: middleButton)
            clock = 0.3
            check(strategy.handleMouseDragged(event: mouse(.leftMouseDragged, start)) == nil,
                  "timed-out startup clicks another app")
            ready = true
            check(strategy.handleMouseDragged(event: mouse(.leftMouseDragged, start)) == nil,
                  "timed-out startup unexpectedly resumes late")
            check(strategy.handleMouseUp(event: mouse(.leftMouseUp, start)) == nil && !strategy.isActive,
                  "aborted startup leaks an unmatched mouse-up")
        }
        // Failed main-window selection or denied activation must not fall back
        // to AXFrontmost or send a press while a different app covers the target.
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
                }, windowIsExposed: { _, _ in false }, now: { clock })
                let start = CGPoint(x: 300, y: 350)
                _ = strategy.handleMouseDown(pid: 900001, windowID: 42,
                    windowFrame: CGRect(origin: selectedOrigin, size: CGSize(width: 500, height: 400)),
                    event: mouse(.leftMouseDown, start), rewriteToLeftButton: middleButton)
                clock = 0.3
                check(activationCount == (selectionFails ? 0 : 1), "activation ignores failed target selection")
                check(!writes.contains { CFEqual($0.0, app) }, "activation failure uses app-wide fallback")
                check(strategy.handleMouseDragged(event: mouse(.leftMouseDragged, start)) == nil,
                      "failed activation clicks the covering app")
                check(strategy.handleMouseUp(event: mouse(.leftMouseUp, start)) == nil,
                      "failed activation leaks unmatched mouse-up")
                failMain = false
            }
        }
        guard failures == 0 else { exit(1) }
        print("PASS: \(cases) focus cases cover selected-window activation, panels, delayed exposure, timeout and release")
    }

    static func mouse(_ type: CGEventType, _ point: CGPoint) -> CGEvent {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
    }
}

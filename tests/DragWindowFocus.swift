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
    return .success
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
        for middleButton in [false, true] {
            for unsupportedRaise in [false, true] {
                for noWindow in [false, true] {
                    writes = []
                    raises = []
                    failRaise = unsupportedRaise
                    missingWindow = noWindow
                    let strategy = TitleBarDragStrategy()
                    let start = CGPoint(x: 300, y: 350)
                    _ = strategy.handleMouseDown(pid: 900001, windowID: 42,
                        windowFrame: CGRect(origin: selectedOrigin, size: CGSize(width: 500, height: 400)),
                        event: mouse(middleButton ? .otherMouseDown : .leftMouseDown, start),
                        rewriteToLeftButton: middleButton)

                    if writes.contains(where: { CFEqual($0.0, app) }) {
                        print("FAIL: dragging one window activates its entire app")
                        failures += 1
                    }
                    let expectedRaises = noWindow ? 0 : 1
                    if raises.count != expectedRaises || raises.contains(where: { !CFEqual($0, selected) }) {
                        print("FAIL: drag does not raise only the selected window")
                        failures += 1
                    }
                    let windowWrites = writes.filter { !CFEqual($0.0, app) }
                    let expectedWrites = !noWindow && unsupportedRaise ? 1 : 0
                    if windowWrites.count != expectedWrites || windowWrites.contains(where: {
                        !CFEqual($0.0, selected) || $0.1 != kAXMainAttribute
                    }) {
                        print("FAIL: raise fallback changes something other than the selected window")
                        failures += 1
                    }
                    let first = mouse(middleButton ? .otherMouseDragged : .leftMouseDragged, start)
                    _ = strategy.handleMouseDragged(event: first)
                    let up = mouse(middleButton ? .otherMouseUp : .leftMouseUp, start)
                    _ = strategy.handleMouseUp(event: up)
                    if first.type != .leftMouseDown || first.location != CGPoint(x: 300, y: 204)
                        || up.type != .leftMouseUp || strategy.isActive {
                        print("FAIL: window focus change breaks the native drag lifecycle")
                        failures += 1
                    }
                }
            }
        }
        guard failures == 0 else { exit(1) }
        print("PASS: 8 left/middle drag startups raise only the selected window, including unsupported AXRaise and missing-window paths")
    }

    static func mouse(_ type: CGEventType, _ point: CGPoint) -> CGEvent {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
    }
}

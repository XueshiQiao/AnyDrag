import Cocoa

// Stand-ins for the two things KeyboardShortcuts.swift borrows from the app:
// the tile action enum and the UserDefaults key names.
enum Preferences { enum Key { static let keyboardShortcuts = "AnyDragKeyboardShortcuts" } }
enum TileAction: Hashable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case centered, restoreOriginal, minimize
    case fill, fillRight, leftAndRight, quarters
    var analyticsKey: String { "\(self)" }
}

@main
struct KeyboardShortcutsTest {
    static var failures = 0
    static var cases = 0
    static func check(_ ok: Bool, _ message: String) {
        cases += 1
        if !ok { failures += 1; print("FAIL: \(message)") }
    }

    static func main() {
        let rect = ShortcutPreset.rectangle.table
        let spec = ShortcutPreset.spectacle.table

        // Event flags → modifier bits. The fn flag macOS puts on arrow keys must not matter.
        let arrowFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskSecondaryFn, .maskNumericPad]
        check(KeyShortcut.modifierBits(of: arrowFlags) == KeyShortcut.control | KeyShortcut.option,
              "fn / numpad flags leaked into the modifier bits")
        let pressed = KeyShortcut(keyCode: 123, modifiers: KeyShortcut.modifierBits(of: arrowFlags), label: "")
        check(pressed == rect[.leftHalf]!, "⌃⌥← with fn flag does not match the left-half shortcut")

        // Display text.
        check(rect[.leftHalf]!.display == "⌃⌥←", "left half should print as ⌃⌥←, got \(rect[.leftHalf]!.display)")
        check(rect[.centered]!.display == "⌃⌥C", "center should print as ⌃⌥C")
        check(spec[.bottomRight]!.display == "⌃⇧⌘→", "Spectacle bottom right should print as ⌃⇧⌘→, got \(spec[.bottomRight]!.display)")

        // Defaults: Rectangle preset binds eleven actions and none twice; the four with no convention are empty.
        check(rect.count == 11, "Rectangle preset should bind 11 actions, got \(rect.count)")
        check(Set(rect.values).count == rect.count, "Rectangle preset binds one shortcut to two actions")
        check(Set(spec.values).count == spec.count, "Spectacle preset binds one shortcut to two actions")
        for a in [TileAction.minimize, .fillRight, .leftAndRight, .quarters] {
            check(rect[a] == nil, "\(a) should have no default shortcut")
        }
        check(rect.values.allSatisfy { $0.isUsable } && spec.values.allSatisfy { $0.isUsable }, "a preset shortcut has no ⌃⌥⌘")

        // Usability: bare keys and ⇧-only are refused.
        check(!KeyShortcut(keyCode: 8, modifiers: 0, label: "C").isUsable, "bare C accepted")
        check(!KeyShortcut(keyCode: 8, modifiers: KeyShortcut.shift, label: "C").isUsable, "⇧C accepted")
        check(KeyShortcut(keyCode: 8, modifiers: KeyShortcut.command, label: "C").isUsable, "⌘C refused")

        // Preset matching is computed, so editing one key turns it into "custom".
        check(ShortcutPreset.matching(rect) == .rectangle, "Rectangle table should match the Rectangle preset")
        var edited = rect
        edited[.leftHalf] = nil
        check(ShortcutPreset.matching(edited) == nil, "an edited table still matches a preset")

        // Storage: nothing saved ⇒ Rectangle; a saved table round-trips, including a cleared action.
        let suite = UserDefaults(suiteName: "anydrag.kbd.test")!
        suite.removePersistentDomain(forName: "anydrag.kbd.test")
        check(KeyboardShortcutStore.load(from: suite) == rect, "empty storage should load the Rectangle preset")
        KeyboardShortcutStore.save(edited, to: suite)
        check(KeyboardShortcutStore.load(from: suite) == edited, "a cleared action came back after save and load")
        suite.removePersistentDomain(forName: "anydrag.kbd.test")

        guard failures == 0 else { exit(1) }
        print("PASS: \(cases) keyboard shortcut checks")
    }
}

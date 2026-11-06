import AppKit
import CoreGraphics
import Carbon.HIToolbox

// Keyboard shortcuts for the tile actions (issue #40). A shortcut is a key plus
// some of ⌃ ⌥ ⇧ ⌘. fn is deliberately not a modifier here: macOS adds the fn
// flag to every arrow-key event by itself, so comparing it would make ⌃⌥←
// arrive as ⌃⌥fn← and never match.

struct KeyShortcut: Codable, Hashable {
    /// Bit values of the four modifiers a shortcut may use.
    static let control: UInt = 1 << 0
    static let option: UInt  = 1 << 1
    static let shift: UInt   = 1 << 2
    static let command: UInt = 1 << 3

    var keyCode: UInt16
    var modifiers: UInt
    /// What the key is printed as ("C", "←"). Only used for display, so it is
    /// left out of equality and hashing: two shortcuts with the same key code
    /// and modifiers are the same shortcut.
    var label: String

    static func == (a: KeyShortcut, b: KeyShortcut) -> Bool {
        a.keyCode == b.keyCode && a.modifiers == b.modifiers
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers)
    }

    /// The modifier bits of a CGEvent's flags (the four this type knows).
    static func modifierBits(of flags: CGEventFlags) -> UInt {
        var bits: UInt = 0
        if flags.contains(.maskControl)   { bits |= control }
        if flags.contains(.maskAlternate) { bits |= option }
        if flags.contains(.maskShift)     { bits |= shift }
        if flags.contains(.maskCommand)   { bits |= command }
        return bits
    }

    static func modifierBits(of flags: NSEvent.ModifierFlags) -> UInt {
        var bits: UInt = 0
        if flags.contains(.control) { bits |= control }
        if flags.contains(.option)  { bits |= option }
        if flags.contains(.shift)   { bits |= shift }
        if flags.contains(.command) { bits |= command }
        return bits
    }

    /// A shortcut without ⌃, ⌥ or ⌘ would be an ordinary typing key (or ⇧ plus
    /// a letter), and grabbing it would break typing everywhere.
    var isUsable: Bool {
        modifiers & (Self.control | Self.option | Self.command) != 0
    }

    /// The modifiers as the Carbon hot key API wants them.
    var carbonModifiers: UInt32 {
        var m = 0
        if modifiers & Self.control != 0 { m |= controlKey }
        if modifiers & Self.option != 0  { m |= optionKey }
        if modifiers & Self.shift != 0   { m |= shiftKey }
        if modifiers & Self.command != 0 { m |= cmdKey }
        return UInt32(m)
    }

    /// "⌃⌥←", in the order Apple prints modifiers.
    var display: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0  { s += "⌥" }
        if modifiers & Self.shift != 0   { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s + label
    }

    /// The label for keys that print as a symbol (arrows, Return, ...), or nil
    /// for a key whose label comes from the typed character.
    static func specialLabel(forKeyCode code: UInt16) -> String? {
        switch code {
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 36: return "↩"
        case 76: return "⌤"
        case 51: return "⌫"
        case 117: return "⌦"
        case 48: return "⇥"
        case 49: return "Space"
        case 53: return "⎋"
        case 116: return "⇞"
        case 121: return "⇟"
        case 115: return "↖"
        case 119: return "↘"
        default: return nil
        }
    }
}

// MARK: - Which actions have shortcuts, and the default key for each

extension TileAction {
    /// All actions a shortcut can be bound to, grouped the way the Settings
    /// page lists them.
    static let shortcutGroups: [(titleKey: String, actions: [TileAction])] = [
        ("kbd.group.halves",   [.leftHalf, .rightHalf, .topHalf, .bottomHalf]),
        ("kbd.group.quarters", [.topLeft, .topRight, .bottomLeft, .bottomRight]),
        ("kbd.group.window",   [.fill, .centered, .restoreOriginal, .minimize]),
        ("kbd.group.arrange",  [.leftAndRight, .fillRight, .quarters]),
    ]

    /// Localized name shown next to the action in Settings and in tooltips.
    var shortcutNameKey: String {
        switch self {
        case .leftHalf:        return "kbd.action.leftHalf"
        case .rightHalf:       return "kbd.action.rightHalf"
        case .topHalf:         return "kbd.action.topHalf"
        case .bottomHalf:      return "kbd.action.bottomHalf"
        case .topLeft:         return "kbd.action.topLeft"
        case .topRight:        return "kbd.action.topRight"
        case .bottomLeft:      return "kbd.action.bottomLeft"
        case .bottomRight:     return "kbd.action.bottomRight"
        case .centered:        return "kbd.action.centered"
        case .restoreOriginal: return "kbd.action.restore"
        case .minimize:        return "kbd.action.minimize"
        case .fill:            return "kbd.action.fill"
        case .fillRight:       return "kbd.action.fillRight"
        case .leftAndRight:    return "kbd.action.leftAndRight"
        case .quarters:        return "kbd.action.quarters"
        }
    }

    /// Reverse of `analyticsKey`, used to read the saved shortcut table back.
    init?(analyticsKey: String) {
        guard let match = Self.allCases.first(where: { $0.analyticsKey == analyticsKey }) else { return nil }
        self = match
    }

    static let allCases: [TileAction] = shortcutGroups.flatMap { $0.actions }
}

// MARK: - Presets

enum ShortcutPreset: String, CaseIterable {
    /// ⌃⌥ + arrows / Return / C / U I J K: what Rectangle and Magnet ship with.
    case rectangle
    /// ⌘⌥ + arrows / F / C: what Spectacle shipped with.
    case spectacle

    var titleKey: String {
        switch self {
        case .rectangle: return "kbd.preset.rectangle"
        case .spectacle: return "kbd.preset.spectacle"
        }
    }

    var table: [TileAction: KeyShortcut] {
        func k(_ code: UInt16, _ mods: UInt, _ label: String? = nil) -> KeyShortcut {
            KeyShortcut(keyCode: code, modifiers: mods,
                        label: label ?? KeyShortcut.specialLabel(forKeyCode: code) ?? "?")
        }
        let c = KeyShortcut.control, o = KeyShortcut.option
        let s = KeyShortcut.shift, m = KeyShortcut.command
        switch self {
        case .rectangle:
            return [
                .leftHalf: k(123, c | o), .rightHalf: k(124, c | o),
                .topHalf: k(126, c | o), .bottomHalf: k(125, c | o),
                .fill: k(36, c | o), .centered: k(8, c | o, "C"),
                .topLeft: k(32, c | o, "U"), .topRight: k(34, c | o, "I"),
                .bottomLeft: k(38, c | o, "J"), .bottomRight: k(40, c | o, "K"),
                .restoreOriginal: k(51, c | o),
            ]
        case .spectacle:
            return [
                .leftHalf: k(123, m | o), .rightHalf: k(124, m | o),
                .topHalf: k(126, m | o), .bottomHalf: k(125, m | o),
                .fill: k(3, m | o, "F"), .centered: k(8, m | o, "C"),
                .topLeft: k(123, c | m), .topRight: k(124, c | m),
                .bottomLeft: k(123, c | m | s), .bottomRight: k(124, c | m | s),
                .restoreOriginal: k(51, c | o),
            ]
        }
    }

    /// The preset whose table is exactly `table`, or nil for a customized one.
    /// Worked out each time instead of saved, so it can never disagree with the
    /// shortcuts that are actually in effect.
    static func matching(_ table: [TileAction: KeyShortcut]) -> ShortcutPreset? {
        allCases.first { $0.table == table }
    }
}

// MARK: - Storage

enum KeyboardShortcutStore {
    /// Read the saved table. Nothing saved yet ⇒ the Rectangle preset. Once the
    /// user changes anything the whole table is saved, so an action they
    /// cleared stays cleared instead of coming back from the preset.
    static func load(from defaults: UserDefaults = .standard) -> [TileAction: KeyShortcut] {
        guard let data = defaults.data(forKey: Preferences.Key.keyboardShortcuts),
              let raw = try? JSONDecoder().decode([String: KeyShortcut].self, from: data)
        else { return ShortcutPreset.rectangle.table }
        var table: [TileAction: KeyShortcut] = [:]
        // Sorted, so if a hand-edited file binds one shortcut to two actions the
        // same action keeps it on every launch.
        for (key, shortcut) in raw.sorted(by: { $0.key < $1.key }) {
            guard let action = TileAction(analyticsKey: key), shortcut.isUsable,
                  !table.values.contains(shortcut) else { continue }
            table[action] = shortcut
        }
        return table
    }

    static func save(_ table: [TileAction: KeyShortcut], to defaults: UserDefaults = .standard) {
        let raw = Dictionary(uniqueKeysWithValues: table.map { ($0.key.analyticsKey, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Preferences.Key.keyboardShortcuts)
        }
    }
}

import SwiftUI
import AppKit

// SwiftUI re-implementation of the modifier-key chip row. Multi-select (empty
// is valid = "off") for the primary modifier, or single-select radio for the
// left-resize augment. Enforces the same Hyper-is-exclusive rule the old AppKit
// `ModifierChipRow` did: Hyper never coexists with the flag modifiers.

struct ModifierChipPicker: View {
    /// The accepted selection (owned by the store; never optimistically flipped).
    let selection: ModifierCombination
    /// When non-nil, only these single-key elements get a chip; nil shows all.
    var candidates: [ModifierCombination]? = nil
    /// Radio behavior: at most one on, and the on chip can't be toggled off.
    var singleSelect: Bool = false
    /// Shown greyed-out and inert (e.g. keys already taken by the base modifier).
    var disabledElements: ModifierCombination = []
    /// Returns true to accept the proposed combination, false to reject it.
    let onChange: (ModifierCombination) -> Bool

    private struct Spec {
        let element: ModifierCombination
        let glyph: String
        let title: String
    }

    private static func allSpecs() -> [Spec] {
        [
            Spec(element: .fn,      glyph: "fn", title: L("fn")),
            Spec(element: .control, glyph: "⌃",  title: L("Control")),
            Spec(element: .option,  glyph: "⌥",  title: L("Option")),
            Spec(element: .shift,   glyph: "⇧",  title: L("Shift")),
            Spec(element: .command, glyph: "⌘",  title: L("Command")),
            // Virtual "Hyper" = hold CapsLock via HyperCapslock. macOS CapsLock
            // glyph (⇪); accessibility label stays the word "Hyper".
            Spec(element: .hyper,   glyph: "⇪",  title: L("Hyper")),
        ]
    }

    private var specs: [Spec] {
        let all = Self.allSpecs()
        guard let candidates else { return all }
        return all.filter { spec in candidates.contains(spec.element) }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(specs, id: \.element.rawValue) { spec in
                ModifierChip(
                    glyph: spec.glyph,
                    title: spec.title,
                    isOn: selection.contains(spec.element),
                    isDisabled: !disabledElements.isDisjoint(with: spec.element)
                ) {
                    toggle(spec.element)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Modifier Keys"))
    }

    private func toggle(_ element: ModifierCombination) {
        guard disabledElements.isDisjoint(with: element) else { return }

        var proposed = selection
        if singleSelect {
            // Radio: clicking the already-on chip keeps it; clicking another moves it.
            guard !proposed.contains(element) else { return }
            proposed = element
        } else if proposed.contains(element) {
            proposed.remove(element)
        } else {
            proposed.insert(element)
            // Hyper is exclusive with the real flag modifiers.
            if element == .hyper {
                proposed = .hyper
            } else {
                proposed.remove(.hyper)
            }
        }
        _ = onChange(proposed)
    }
}

// MARK: - Single chip

private struct ModifierChip: View {
    let glyph: String
    let title: String
    let isOn: Bool
    let isDisabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Text(glyph)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isOn ? Color(nsColor: .alternateSelectedControlTextColor)
                                  : Color(nsColor: .labelColor))
            .frame(width: 56, height: 36)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fillColor))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(borderColor, lineWidth: 1))
            // The whole chip is clickable — not just the glyph.
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(isDisabled ? 0.35 : 1)
            .onHover { hovering = isDisabled ? false : $0 }
            .onTapGesture { if !isDisabled { action() } }
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private var fillColor: Color {
        if isOn { return hovering ? Color.accentColor.opacity(0.88) : Color.accentColor }
        if hovering { return Color(nsColor: .controlColor) }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var borderColor: Color {
        isOn ? Color.accentColor : Color(nsColor: .separatorColor)
    }
}

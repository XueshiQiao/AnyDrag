import SwiftUI
import AppKit

// SwiftUI re-implementation of the radio-style card picker: a row of
// equal-width cards (SF Symbol + title) with the selected option's subtitle
// shown below. Used for both the middle-click action and the resize trigger.

struct CardOption: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    var subtitle: String
}

struct CardOptionPicker: View {
    let options: [CardOption]
    let selectedID: String
    var isEnabled: Bool = true
    var accessibilityLabel: String = ""
    let onChange: (String) -> Void

    private var selectedSubtitle: String {
        options.first { $0.id == selectedID }?.subtitle ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ForEach(options) { opt in
                    OptionCard(option: opt, isSelected: opt.id == selectedID) {
                        if opt.id != selectedID { onChange(opt.id) }
                    }
                }
            }
            if !selectedSubtitle.isEmpty {
                Text(selectedSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
        .allowsHitTesting(isEnabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Single card

private struct OptionCard: View {
    let option: CardOption
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: option.symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(height: 26)
            Text(option.title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.accentColor : Color(nsColor: .labelColor))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 78)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(bgColor))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(borderColor, lineWidth: isSelected ? 1.5 : 1))
        // The whole card is clickable, padding included.
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { action() }
        .accessibilityElement()
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var bgColor: Color {
        if isSelected { return Color.accentColor.opacity(0.10) }
        if hovering { return Color(nsColor: .controlColor) }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var borderColor: Color {
        isSelected ? Color.accentColor : Color(nsColor: .separatorColor)
    }
}

// MARK: - Typed option builders

enum MiddleActionOptions {
    static func all() -> [CardOption] {
        MiddleAction.allCases.map {
            CardOption(id: $0.rawValue, title: $0.displayName, symbol: symbol(for: $0), subtitle: subtitle(for: $0))
        }
    }
    private static func symbol(for action: MiddleAction) -> String {
        switch action {
        case .off:             return "nosign"
        case .dragWindow:      return "hand.draw"
        case .tileByDirection: return "square.split.2x2"
        }
    }
    private static func subtitle(for action: MiddleAction) -> String {
        switch action {
        case .off:             return L("middleAction.off.subtitle")
        case .dragWindow:      return L("middleAction.drag.subtitle")
        case .tileByDirection: return L("middleAction.tile.subtitle")
        }
    }
}

enum ResizeTriggerOptions {
    /// `secondarySymbol` is spliced into the left-drag subtitle so it tracks the
    /// user's current secondary modifier (e.g. ⇧) — the only key that triggers
    /// the left-drag resize.
    static func all(secondarySymbol: String) -> [CardOption] {
        ResizeTrigger.allCases.map {
            CardOption(id: $0.rawValue, title: $0.displayName, symbol: symbol(for: $0),
                       subtitle: subtitle(for: $0, secondarySymbol: secondarySymbol))
        }
    }
    private static func symbol(for trigger: ResizeTrigger) -> String {
        switch trigger {
        case .off:        return "nosign"
        case .rightClick: return "arrow.up.left.and.arrow.down.right"
        case .leftClick:  return "arrow.up.right.and.arrow.down.left"
        }
    }
    private static func subtitle(for trigger: ResizeTrigger, secondarySymbol: String) -> String {
        switch trigger {
        case .off:        return L("resizeTrigger.off.subtitle")
        case .rightClick: return L("resizeTrigger.right.subtitle")
        case .leftClick:  return String(format: L("resizeTrigger.left.subtitle"), secondarySymbol)
        }
    }
}

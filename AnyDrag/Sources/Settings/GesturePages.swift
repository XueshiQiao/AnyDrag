import SwiftUI

// The three core gesture pages, each a grouped Form: Window Drag (primary
// modifier + drag/maximize/tiling toggles), Window Resize (trigger + secondary
// modifier + corner bracket), and Middle Click (action + tile sub-options).
// Together they replace the old single "Advanced" pane.

// MARK: - Window Drag

struct WindowDragPage: View {
    @EnvironmentObject var store: SettingsStore

    private var previewText: String {
        let combo = store.modifiers
        if combo.isEmpty { return L("modifier.preview.empty") }
        return String(format: L("modifier.preview.format"), combo.symbol, combo.displayName)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    ModifierChipPicker(selection: store.modifiers) { proposed in
                        store.setModifiers(proposed)
                    }
                    Text(previewText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if store.modifiers.contains(.hyper) {
                        Text(L("modifier.hyper.hint"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text(L("label.primaryModifier"))
            }

            Section {
                Toggle(isOn: Binding(get: { store.dragEnabled }, set: { store.setDragEnabled($0) })) {
                    featureLabel("hand.draw.fill", .blue, L("Drag window"), L("feature.drag.subtitle"))
                }
                Toggle(isOn: Binding(get: { store.maximizeEnabled }, set: { store.setMaximizeEnabled($0) })) {
                    featureLabel("macwindow", .green, L("Maximize / Restore"), L("feature.maximize.subtitle"))
                }
                Toggle(isOn: Binding(get: { store.tilingEnabled }, set: { store.setTilingEnabled($0) })) {
                    featureLabel("square.grid.2x2.fill", .purple, L("Window tiling"), L("feature.tiling.subtitle"))
                }
            }
            .disabled(store.modifiers.isEmpty)
        }
        .formStyle(.grouped)
        .navigationTitle(L("section.windowDrag"))
    }
}

// MARK: - Window Resize

struct WindowResizePage: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                CardOptionPicker(
                    options: ResizeTriggerOptions.all(secondarySymbol: store.leftResizeModifier.symbol),
                    selectedID: store.resizeTrigger.rawValue,
                    isEnabled: !store.modifiers.isEmpty,
                    accessibilityLabel: L("section.windowResize")
                ) { id in
                    if let trigger = ResizeTrigger(rawValue: id) { store.setResizeTrigger(trigger) }
                }
                .padding(.vertical, 4)
            } header: {
                Text(L("section.windowResize"))
            }

            // Secondary modifier — only relevant for the left-drag trigger.
            if store.resizeTrigger == .leftClick {
                Section {
                    ModifierChipPicker(
                        selection: store.leftResizeModifier,
                        candidates: ModifierCombination.augmentCandidates,
                        singleSelect: true,
                        disabledElements: store.augmentDisabledElements
                    ) { proposed in
                        store.setAugment(proposed)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(L("leftResize.augment"))
                }
            }

            // Corner bracket — only matters during a resize, so hidden when off.
            if store.resizeTrigger != .off {
                Section {
                    Toggle(isOn: Binding(get: { store.cornerBracketEnabled }, set: { store.setCornerBracketEnabled($0) })) {
                        featureLabel("viewfinder", .teal, L("feature.cornerBracket"), L("feature.cornerBracket.subtitle"))
                    }
                    .disabled(store.modifiers.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("section.windowResize"))
    }
}

// MARK: - Middle Click

struct MiddleClickPage: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                // Middle-click fires on the button alone — no modifier needed —
                // so this picker is always enabled.
                CardOptionPicker(
                    options: MiddleActionOptions.all(),
                    selectedID: store.middleAction.rawValue,
                    accessibilityLabel: L("Middle-click action")
                ) { id in
                    if let action = MiddleAction(rawValue: id) { store.setMiddleAction(action) }
                }
                .padding(.vertical, 4)
            } header: {
                Text(L("Middle-click action"))
            }

            // Tile sub-options apply only to "Tile by direction".
            if store.middleAction == .tileByDirection {
                Section {
                    Toggle(isOn: Binding(get: { store.multiDisplayBentoEnabled }, set: { store.setMultiDisplayBentoEnabled($0) })) {
                        featureLabel("rectangle.on.rectangle", .indigo, L("feature.multiDisplayBento"), L("feature.multiDisplayBento.subtitle"))
                    }
                    Toggle(isOn: Binding(get: { store.tileByDirectionDragOnly }, set: { store.setTileDragOnly($0) })) {
                        featureLabel("cursorarrow.motionlines", .pink, L("feature.tileDragOnly"), L("feature.tileDragOnly.subtitle"))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("Middle-click action"))
    }
}

import SwiftUI
import AppKit

// The three core gesture pages, each a grouped Form: Window Drag (primary
// modifier + drag/maximize/tiling toggles), Window Resize (trigger + secondary
// modifier + corner bracket), and Middle Click (action + tile sub-options).
// Together they replace the old single "Advanced" pane.

// MARK: - Window Drag

struct WindowDragPage: View {
    @EnvironmentObject var store: SettingsStore
    @State private var showAddOffsetApp = false

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

            // ─── Advanced: per-app title-bar Y offset ───────────────
            Section {
                Text(L("perAppOffset.note"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(store.perAppOffsets, id: \.bundleID) { item in
                    perAppOffsetRow(item)
                }

                Button {
                    showAddOffsetApp = true
                } label: {
                    Label(L("perAppOffset.add"), systemImage: "plus.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showAddOffsetApp, arrowEdge: .bottom) {
                    AppPickerPopover(
                        runningApps: store.addableRunningAppsForOffset(),
                        icon: { store.icon(forBundleID: $0) },
                        onPick: { app in
                            store.addPerAppOffset(app)
                            showAddOffsetApp = false
                        },
                        onBrowse: {
                            showAddOffsetApp = false
                            DispatchQueue.main.async { store.addPerAppOffsets(pickAppBundles()) }
                        }
                    )
                }
            } header: {
                Text(L("section.advanced"))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("section.windowDrag"))
    }

    /// Fixed width of the "N pt" value label. Trailing-aligned within it so the
    /// digits stay flush-right against the constant gap to the stepper whether the
    /// value is 1 or 2 digits.
    private static let perAppValueWidth: CGFloat = 42

    /// Uniform gap between the right-cluster controls (value ↔ stepper ↔ remove)
    /// and between the icon and name. Only the name↔cluster gap is flexible.
    private static let perAppRowSpacing: CGFloat = 8

    /// One per-app override row — strictly a single line: app icon + name
    /// (left-aligned; hover the name to reveal its bundle id), a flexible spacer,
    /// then a right-aligned cluster of the live value, a stepper, and
    /// a remove button. Removing the row reverts that app to the global offset.
    @ViewBuilder
    private func perAppOffsetRow(_ item: AppTitleBarOffset) -> some View {
        HStack(spacing: Self.perAppRowSpacing) {
            Image(nsImage: store.icon(forBundleID: item.bundleID))
                .resizable().frame(width: 22, height: 22)
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(item.bundleID)
            Spacer(minLength: Self.perAppRowSpacing)
            Text("\(Int(item.offset.rounded())) pt")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: Self.perAppValueWidth, alignment: .trailing)
            Stepper(
                value: Binding(
                    get: { Double(item.offset) },
                    set: { store.setPerAppOffset(bundleID: item.bundleID, value: CGFloat($0)) }
                ),
                in: Double(Preferences.perAppTitleBarYOffsetRange.lowerBound)...Double(Preferences.perAppTitleBarYOffsetRange.upperBound),
                step: 1
            ) {
                EmptyView()
            }
            .labelsHidden()
            Button {
                store.removePerAppOffset(bundleID: item.bundleID)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L("perAppOffset.remove"))
        }
        .padding(.vertical, 2)
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

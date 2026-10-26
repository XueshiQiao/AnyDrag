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
                // Three-finger drag stands in for the modifier on the left
                // button. It only works with the macOS three-finger-drag
                // option on, so say so up front, and point at the switch
                // whenever the feature is on but the system option isn't.
                Toggle(isOn: Binding(get: { store.threeFingerDragEnabled }, set: { store.setThreeFingerDragEnabled($0) })) {
                    featureLabel("hand.raised.fingers.spread.fill", .orange, L("feature.threeFingerDrag"), threeFingerSubtitle)
                }
                .disabled(!store.dragEnabled)
                if store.threeFingerDragEnabled && store.dragEnabled && !store.systemThreeFingerDragEnabled {
                    threeFingerSetupHint
                }
                Toggle(isOn: Binding(get: { store.maximizeEnabled }, set: { store.setMaximizeEnabled($0) })) {
                    featureLabel("macwindow", .green, L("Maximize / Restore"), L("feature.maximize.subtitle"))
                }
                Toggle(isOn: Binding(get: { store.tilingEnabled }, set: { store.setTilingEnabled($0) })) {
                    featureLabel("square.grid.2x2.fill", .purple, L("Window tiling"), L("feature.tiling.subtitle"))
                }
            }
            .disabled(store.modifiers.isEmpty)

            // ─── Advanced: centered-window size + per-app title-bar Y offset ──
            Section {
                // One value for every centered path — the tiling panel's Center
                // button and the middle-click drag-down gesture (its live
                // preview included). See DragEngine.centeredSizePercent.
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("centeredSize.title"))
                        Text(L("centeredSize.note"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Picker("", selection: Binding(
                        get: { store.centeredSizePercent },
                        set: { store.setCenteredSizePercent($0) }
                    )) {
                        ForEach(Preferences.centeredPercentStops, id: \.self) { percent in
                            Text(String(format: L("centeredSize.value.format"), percent))
                                .tag(percent)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 84)
                }
                .padding(.vertical, 2)

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

    /// The setup path, plus the resize key while a resize trigger is on
    /// (three fingers + that key resizes instead of moving).
    private var threeFingerSubtitle: String {
        var text = L("feature.threeFingerDrag.subtitle")
        if store.resizeTrigger != .off {
            text += "\n" + String(format: L("feature.threeFingerDrag.resizeHint"), store.leftResizeModifier.symbol)
        }
        return text
    }

    /// Shown while "Three-finger drag" is on but macOS's own three-finger-drag
    /// option is off — the gesture emits no mouse events until it is enabled.
    private var threeFingerSetupHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("feature.threeFingerDrag.systemOff"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("feature.threeFingerDrag.openSettings")) {
                    store.openTrackpadDragSettings()
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    /// Fixed width of the "N pt" value label. Trailing-aligned within it so the
    /// digits stay flush-right against the constant gap to the stepper whether the
    /// value is 1 or 2 digits.
    private static let perAppValueWidth: CGFloat = 42

    /// Uniform gap between the right-cluster controls (value ↔ stepper ↔ remove)
    /// and between the icon and name. Only the name↔cluster gap is flexible.
    private static let perAppRowSpacing: CGFloat = 8

    /// App identity and Y tuning, with optional independent horizontal anchors.
    /// Removing the app restores all global defaults.
    @ViewBuilder
    private func perAppOffsetRow(_ item: AppTitleBarOffset) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: Self.perAppRowSpacing) {
                Image(nsImage: store.icon(forBundleID: item.bundleID))
                    .resizable().frame(width: 22, height: 22)
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(item.bundleID)
                Spacer(minLength: Self.perAppRowSpacing)
                Text(L("perAppOffset.y"))
                    .font(.caption).foregroundStyle(.secondary)
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
            if store.useFixedTitleBarX || item.xOffsets != nil {
                HStack {
                    Text(L(item.xOffsets == nil ? "perAppOffset.xGlobal" : "perAppOffset.xCustom"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("perAppOffset.useGlobalX")) {
                        store.resetPerAppXInsets(bundleID: item.bundleID)
                    }
                    .controlSize(.small)
                    .disabled(item.xOffsets == nil)
                }
                perAppXInsetRow(item, left: true, value: item.xOffsets?.left ?? store.titleBarLeftInset)
                perAppXInsetRow(item, left: false, value: item.xOffsets?.right ?? store.titleBarRightInset)
            } else {
                Button(L("perAppOffset.customizeX")) {
                    store.customizePerAppXInsets(bundleID: item.bundleID)
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }
    private func perAppXInsetRow(_ item: AppTitleBarOffset, left: Bool, value: CGFloat) -> some View {
        HStack(spacing: Self.perAppRowSpacing) {
            Text(L(left ? "diagnostics.titleBarLeftInset" : "diagnostics.titleBarRightInset"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("\(Int(value)) pt")
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .frame(width: Self.perAppValueWidth, alignment: .trailing)
            Stepper(value: Binding(
                get: { Double(value) },
                set: { store.setPerAppXInset(bundleID: item.bundleID, left: left, value: CGFloat($0)) }
            ), in: 8...400, step: 1) { EmptyView() }
                .labelsHidden()
                .accessibilityLabel(L(left ? "diagnostics.titleBarLeftInset" : "diagnostics.titleBarRightInset"))
        }
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

            // Secondary modifier — for the left-drag trigger, and for the
            // three-finger drag (three fingers + this key resizes) with any
            // trigger that is on.
            let threeFingerResize = store.threeFingerDragEnabled && store.resizeTrigger != .off
            if store.resizeTrigger == .leftClick || threeFingerResize {
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
                    Text(L(store.resizeTrigger == .leftClick ? "leftResize.augment" : "threeFinger.resize.augment"))
                } footer: {
                    if threeFingerResize {
                        Text(String(format: L("threeFinger.resize.note"), store.leftResizeModifier.symbol))
                    }
                }
            }

            // Resize options only apply while a resize trigger is enabled.
            if store.resizeTrigger != .off {
                Section {
                    Toggle(isOn: Binding(get: { store.resizeFromBottomRightOnly }, set: { store.setResizeFromBottomRightOnly($0) })) {
                        featureLabel("arrow.down.right", .teal, L("feature.resizeFromBottomRightOnly"), L("feature.resizeFromBottomRightOnly.subtitle"))
                    }
                    .disabled(store.modifiers.isEmpty)
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
                    Toggle(isOn: Binding(get: { store.overlayEdgeSafeEnabled }, set: { store.setOverlayEdgeSafeEnabled($0) })) {
                        featureLabel("cursorarrow.rays", .teal, L("feature.overlayEdgeSafe"), L("feature.overlayEdgeSafe.subtitle"))
                    }
                    Picker(selection: Binding(
                        get: { store.oppositeHalfMode },
                        set: { store.setOppositeHalfMode($0) }
                    )) {
                        ForEach(OppositeHalfMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    } label: {
                        featureLabel("uiwindow.split.2x1", .blue, L("feature.oppositeHalfMode"), L("feature.oppositeHalfMode.subtitle"))
                    }
                    if store.oppositeHalfMode == .snapAssist {
                        LabeledContent {
                            if store.screenRecordingGranted {
                                Text(L("accessibility.granted"))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(Color.green.opacity(0.15)))
                            } else {
                                Button(L("accessibility.grantButton")) {
                                    store.authorizeScreenRecording()
                                }
                            }
                        } label: {
                            featureLabel("photo.on.rectangle.angled", .cyan, L("feature.snapAssistThumbnails"), L("feature.snapAssistThumbnails.subtitle"))
                        }
                    }
                    // Linked resize belongs with tiling: it acts on an
                    // AnyDrag-tiled pair (plain left-drag on the shared seam).
                    Toggle(isOn: Binding(get: { store.linkedResizeEnabled }, set: { store.setLinkedResizeEnabled($0) })) {
                        featureLabel("rectangle.split.2x1", .orange, L("feature.linkedResize"), L("feature.linkedResize.subtitle"))
                    }
                    Toggle(isOn: Binding(get: { store.bentoWindowActionsEnabled }, set: { store.setBentoWindowActionsEnabled($0) })) {
                        featureLabel("menubar.dock.rectangle", .yellow, L("feature.bentoWindowActions"), L("feature.bentoWindowActions.subtitle"))
                    }
                }

                // Overlay looks — DEBUG only. The shipping look is fixed (no
                // border, `.popover` glass, accent wash); these knobs stay in
                // the code so the look can be re-evaluated without rewriting
                // anything, but Release users never see the choice.
                #if DEBUG
                Section {
                    Toggle(isOn: Binding(get: { store.bentoBorderEnabled }, set: { store.setBentoBorderEnabled($0) })) {
                        featureLabel("square.dashed", .gray, L("feature.bentoBorder"), L("feature.bentoBorder.subtitle"))
                    }
                    optionRow(
                        symbol: "circle.lefthalf.filled",
                        color: .purple,
                        title: L("feature.bentoMaterial"),
                        subtitle: L("feature.bentoMaterial.subtitle")
                    ) {
                        Picker("", selection: Binding(
                            get: { store.bentoMaterial },
                            set: { store.setBentoMaterial($0) }
                        )) {
                            ForEach(BentoMaterial.allCases, id: \.self) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 168)
                    }
                    optionRow(
                        symbol: "paintpalette",
                        color: .mint,
                        title: L("feature.bentoTint"),
                        subtitle: L("feature.bentoTint.subtitle")
                    ) {
                        Picker("", selection: Binding(
                            get: { store.bentoTint },
                            set: { store.setBentoTint($0) }
                        )) {
                            ForEach(BentoTint.allCases, id: \.self) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 168)
                    }
                } header: {
                    // The marker is intentionally un-localized: it only ever
                    // renders in a debug build, for us.
                    Text(L("bentoAppearance.section") + " · DEBUG ONLY")
                }
                #endif
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("Middle-click action"))
    }
}

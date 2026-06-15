import Cocoa

/// Advanced settings pane: the modifier picker, per-feature toggles, and the
/// middle-click action card picker. Splits out from General to keep each pane
/// short — General now holds language / launch / diagnostics only.
final class AdvancedPaneViewController: NSViewController {

    private let dragEngine: DragEngine

    private let modifierChipRow = ModifierChipRow(initial: ModifierCombination())
    private let modifierPreview = NSTextField(labelWithString: "")
    /// Shown only when the virtual "Hyper" chip is selected — explains it needs
    /// HyperCapslock running with its broadcast setting on.
    private let hyperHint = NSTextField(wrappingLabelWithString: "")

    private let dragSwitch     = NSSwitch()
    private let maximizeSwitch = NSSwitch()
    private let tilingSwitch   = NSSwitch()
    private let cornerBracketSwitch = NSSwitch()
    private let multiDisplayBentoSwitch = NSSwitch()
    private let tileDragOnlySwitch = NSSwitch()

    /// Three-card picker for how resize is triggered (off / right-drag / left-drag).
    private let resizeTriggerPicker = ResizeTriggerCardPicker(initial: .rightClick)

    /// Single-select picker for the secondary modifier held with the primary to
    /// trigger a left-drag resize. Limited to the eligible augment keys.
    private let augmentChipRow = ModifierChipRow(
        initial: .shift,
        candidates: ModifierCombination.augmentCandidates,
        singleSelect: true
    )
    private let augmentLabel = SettingsRowBuilder.subLabel("")
    /// The "Secondary Modifier" label + chip row, wrapped so it can be
    /// shown/hidden as a unit. Visible only when the resize trigger is left-drag.
    private weak var augmentSubBlock: NSStackView?
    /// The two tile sub-options (multi-display + drag-only), shown only for the
    /// "Tile by direction" middle action.
    private weak var middleTileOptionsBlock: NSStackView?

    private let middleActionPicker = MiddleActionCardPicker(initial: .off)

    private var modifierGatedRows: [FeatureRowViews] = []

    private struct FeatureRowViews {
        let title: NSTextField
        let subtitle: NSTextField
        let toggle: NSSwitch
    }

    private func buildFeatureRow(title: String, subtitle: String?, toggle: NSSwitch, action: Selector) -> SettingsRow {
        let row = SettingsRowBuilder.feature(title: title, subtitle: subtitle, toggle: toggle, target: self, action: action)
        if let subtitleLabel = row.subtitle {
            modifierGatedRows.append(FeatureRowViews(title: row.title, subtitle: subtitleLabel, toggle: toggle))
        }
        return row
    }

    /// The resize-trigger card picker plus the secondary-modifier picker, grouped
    /// as one card cell. The secondary-modifier picker shows only when the
    /// trigger is left-drag.
    private func buildResizeTriggerBlock() -> NSView {
        resizeTriggerPicker.selection = dragEngine.resizeTrigger
        resizeTriggerPicker.setPrimaryModifierSymbol(dragEngine.modifiers.symbol)
        resizeTriggerPicker.onChange = { [weak self] trigger in
            guard let self = self else { return }
            let previous = self.dragEngine.resizeTrigger
            self.dragEngine.resizeTrigger = trigger
            UserDefaults.standard.set(trigger.rawValue, forKey: Preferences.Key.resizeTrigger)
            // Show/hide the secondary-modifier picker for the left-drag trigger,
            // re-fitting the window when that changes its height.
            if self.updateAugmentPickerState() {
                self.resizeWindowToFitPane()
            }
            if previous != trigger {
                Analytics.trackPreferenceChanged(key: "resize_trigger", value: trigger.rawValue)
            }
        }

        augmentLabel.stringValue = NSLocalizedString("leftResize.augment", comment: "")

        augmentChipRow.onChange = { [weak self] proposed in
            guard let self = self else { return false }
            // Only a single eligible key that doesn't collide with the primary —
            // otherwise the left-drag trigger wouldn't differ from the move trigger.
            guard proposed.isValidAugment,
                  proposed.isDisjoint(with: self.dragEngine.modifiers) else { return false }
            let previous = self.dragEngine.leftResizeModifier
            self.dragEngine.leftResizeModifier = proposed
            UserDefaults.standard.set(proposed.rawValue, forKey: Preferences.Key.leftResizeModifier)
            if previous != proposed {
                Analytics.trackPreferenceChanged(key: "left_resize_modifier", value: proposed.analyticsKey)
            }
            return true
        }

        let augmentSubBlock = NSStackView(views: [augmentLabel, augmentChipRow])
        augmentSubBlock.orientation = .vertical
        augmentSubBlock.alignment = .leading
        augmentSubBlock.spacing = 6
        // Shown only for the left-drag trigger. Set before the window measures
        // the pane's fitting height so it opens at the right size; an NSStackView
        // collapses hidden arranged subviews, so the card shrinks when hidden.
        augmentSubBlock.isHidden = (dragEngine.resizeTrigger != .leftClick)
        self.augmentSubBlock = augmentSubBlock

        let block = NSStackView(views: [resizeTriggerPicker, augmentSubBlock])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 12
        block.translatesAutoresizingMaskIntoConstraints = false
        // Stretch the picker and the sub-block to the full card width; the
        // vertical stack's .leading alignment won't do it on its own.
        NSLayoutConstraint.activate([
            resizeTriggerPicker.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            resizeTriggerPicker.trailingAnchor.constraint(equalTo: block.trailingAnchor),
            augmentSubBlock.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            augmentSubBlock.trailingAnchor.constraint(equalTo: block.trailingAnchor),
        ])
        return block
    }

    /// The middle-click action picker plus its two tile sub-options, grouped as
    /// one card cell. The sub-options apply only to "Tile by direction", so they
    /// collapse out of view for the other actions — kept in one card row so
    /// hiding them never strands a separator.
    private func buildMiddleClickBlock() -> NSView {
        let multiDisplayRow = buildFeatureRow(
            title: NSLocalizedString("feature.multiDisplayBento", comment: ""),
            subtitle: NSLocalizedString("feature.multiDisplayBento.subtitle", comment: ""),
            toggle: multiDisplayBentoSwitch,
            action: #selector(multiDisplayBentoToggled(_:))
        )
        let tileDragOnlyRow = buildFeatureRow(
            title: NSLocalizedString("feature.tileDragOnly", comment: ""),
            subtitle: NSLocalizedString("feature.tileDragOnly.subtitle", comment: ""),
            toggle: tileDragOnlySwitch,
            action: #selector(tileDragOnlyToggled(_:))
        )

        let tileOptions = NSStackView(views: [multiDisplayRow.view, tileDragOnlyRow.view])
        tileOptions.orientation = .vertical
        tileOptions.alignment = .leading
        tileOptions.spacing = 12
        tileOptions.isHidden = (dragEngine.middleAction != .tileByDirection)
        self.middleTileOptionsBlock = tileOptions

        let block = NSStackView(views: [middleActionPicker, tileOptions])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 12
        block.translatesAutoresizingMaskIntoConstraints = false
        // Stretch the picker and each sub-row to the full card width; the
        // vertical stack's .leading alignment won't do it on its own.
        NSLayoutConstraint.activate([
            middleActionPicker.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            middleActionPicker.trailingAnchor.constraint(equalTo: block.trailingAnchor),
            tileOptions.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            tileOptions.trailingAnchor.constraint(equalTo: block.trailingAnchor),
            multiDisplayRow.view.leadingAnchor.constraint(equalTo: tileOptions.leadingAnchor),
            multiDisplayRow.view.trailingAnchor.constraint(equalTo: tileOptions.trailingAnchor),
            tileDragOnlyRow.view.leadingAnchor.constraint(equalTo: tileOptions.leadingAnchor),
            tileDragOnlyRow.view.trailingAnchor.constraint(equalTo: tileOptions.trailingAnchor),
        ])
        return block
    }

    /// Show the tile sub-options only for "Tile by direction". Returns whether
    /// visibility changed, so the caller can re-fit the window.
    @discardableResult
    private func updateMiddleTileOptionsVisibility() -> Bool {
        let show = (dragEngine.middleAction == .tileByDirection)
        let changed = (middleTileOptionsBlock?.isHidden == show)
        middleTileOptionsBlock?.isHidden = !show
        return changed
    }

    init(dragEngine: DragEngine) {
        self.dragEngine = dragEngine
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 14
        container.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        container.translatesAutoresizingMaskIntoConstraints = false

        // ─── Window Drag card ─────────────────────────────────────────
        modifierChipRow.onChange = { [weak self] proposed in
            guard let self = self else { return false }
            let previous = self.dragEngine.modifiers
            self.dragEngine.modifiers = proposed
            UserDefaults.standard.set(proposed.rawValue, forKey: Preferences.Key.modifierFlags)
            self.updateModifierPreview()
            self.updateFeatureRowsEnabled()
            self.revalidateAugmentForBaseChange()
            self.updateResizeTriggerSubtitle()
            if previous != proposed {
                Analytics.trackPreferenceChanged(key: "modifier", value: proposed.analyticsKey)
            }
            return true
        }

        modifierPreview.font = .systemFont(ofSize: 11)
        modifierPreview.textColor = .secondaryLabelColor

        hyperHint.font = .systemFont(ofSize: 11)
        hyperHint.textColor = .secondaryLabelColor
        hyperHint.lineBreakMode = .byWordWrapping
        hyperHint.maximumNumberOfLines = 0
        hyperHint.stringValue = NSLocalizedString("modifier.hyper.hint", comment: "")

        // The primary modifier is the most important control in the pane, so its
        // label is bold and full-size (matching the other row titles) rather than
        // a small grey sub-label.
        let primaryModifierLabel = NSTextField(labelWithString: NSLocalizedString("label.primaryModifier", comment: ""))
        primaryModifierLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let modifierBlock = NSStackView(views: [
            primaryModifierLabel,
            modifierChipRow,
            modifierPreview,
            hyperHint,
        ])
        modifierBlock.orientation = .vertical
        modifierBlock.alignment = .leading
        modifierBlock.spacing = 6

        let dragToggleRow = buildFeatureRow(
            title: NSLocalizedString("Drag window", comment: ""),
            subtitle: NSLocalizedString("feature.drag.subtitle", comment: ""),
            toggle: dragSwitch,
            action: #selector(dragToggled(_:))
        )
        let maximizeRow = buildFeatureRow(
            title: NSLocalizedString("Maximize / Restore", comment: ""),
            subtitle: NSLocalizedString("feature.maximize.subtitle", comment: ""),
            toggle: maximizeSwitch,
            action: #selector(maximizeToggled(_:))
        )
        let tilingRow = buildFeatureRow(
            title: NSLocalizedString("Window tiling", comment: ""),
            subtitle: NSLocalizedString("feature.tiling.subtitle", comment: ""),
            toggle: tilingSwitch,
            action: #selector(tilingToggled(_:))
        )

        SettingsCardLayout.addSection(
            to: container,
            header: NSLocalizedString("section.windowDrag", comment: ""),
            rows: [modifierBlock, dragToggleRow.view, maximizeRow.view, tilingRow.view]
        )

        // ─── Window Resize card ───────────────────────────────────────
        let resizeTriggerBlock = buildResizeTriggerBlock()
        let cornerBracketRow = buildFeatureRow(
            title: NSLocalizedString("feature.cornerBracket", comment: ""),
            subtitle: NSLocalizedString("feature.cornerBracket.subtitle", comment: ""),
            toggle: cornerBracketSwitch,
            action: #selector(cornerBracketToggled(_:))
        )

        SettingsCardLayout.addSection(
            to: container,
            header: NSLocalizedString("section.windowResize", comment: ""),
            rows: [resizeTriggerBlock, cornerBracketRow.view]
        )

        // ─── Middle-click action card ─────────────────────────────────
        middleActionPicker.onChange = { [weak self] action in
            guard let self = self else { return }
            let previous = self.dragEngine.middleAction
            self.dragEngine.middleAction = action
            UserDefaults.standard.set(action.rawValue, forKey: Preferences.Key.middleAction)
            // The two tile sub-options only apply to "Tile by direction"; show
            // them only for that action and re-fit the window when that changes.
            if self.updateMiddleTileOptionsVisibility() {
                self.resizeWindowToFitPane()
            }
            if previous != action {
                Analytics.trackPreferenceChanged(key: "middle_action", value: action.rawValue)
            }
        }

        SettingsCardLayout.addSection(
            to: container,
            header: NSLocalizedString("Middle-click action", comment: ""),
            rows: [buildMiddleClickBlock()],
            bottomSpacing: 0
        )

        let view = NSView()
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
        ])
        self.view = view
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshFromState()
    }

    private func refreshFromState() {
        modifierChipRow.selection = dragEngine.modifiers
        updateModifierPreview()

        dragSwitch.state            = dragEngine.dragEnabled ? .on : .off
        maximizeSwitch.state        = dragEngine.maximizeEnabled ? .on : .off
        tilingSwitch.state          = dragEngine.tilingEnabled ? .on : .off
        cornerBracketSwitch.state   = dragEngine.cornerBracketEnabled ? .on : .off
        multiDisplayBentoSwitch.state = dragEngine.multiDisplayBentoEnabled ? .on : .off
        tileDragOnlySwitch.state    = dragEngine.tileByDirectionDragOnly ? .on : .off

        resizeTriggerPicker.selection = dragEngine.resizeTrigger
        augmentChipRow.selection = dragEngine.leftResizeModifier
        updateAugmentPickerState()
        updateResizeTriggerSubtitle()

        updateFeatureRowsEnabled()

        middleActionPicker.selection = dragEngine.middleAction
        updateMiddleTileOptionsVisibility()
    }

    private func updateModifierPreview() {
        let combo = dragEngine.modifiers
        if combo.isEmpty {
            modifierPreview.stringValue = NSLocalizedString("modifier.preview.empty", comment: "")
        } else {
            let format = NSLocalizedString("modifier.preview.format", comment: "")
            modifierPreview.stringValue = String(format: format, combo.symbol, combo.displayName)
        }
        hyperHint.isHidden = !combo.contains(.hyper)
    }

    /// When no modifier is selected, AnyDrag has nothing to listen for, so the
    /// per-feature toggles dim. Stored on/off values are untouched.
    private func updateFeatureRowsEnabled() {
        let enabled = !dragEngine.modifiers.isEmpty
        for row in modifierGatedRows {
            row.toggle.isEnabled = enabled
            row.title.textColor = enabled ? .labelColor : .tertiaryLabelColor
            row.subtitle.textColor = enabled ? .secondaryLabelColor : .tertiaryLabelColor
        }
        // Resize needs a primary modifier to fire, so dim its picker when none
        // is set (mirrors the gated toggles). The middle-click picker is left
        // enabled — it triggers on the middle button alone, no modifier needed.
        resizeTriggerPicker.isEnabled = enabled
    }

    // MARK: - Actions

    @objc private func dragToggled(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        let previous = dragEngine.dragEnabled
        dragEngine.dragEnabled = on
        UserDefaults.standard.set(on, forKey: Preferences.Key.dragEnabled)
        if previous != on {
            Analytics.trackPreferenceChanged(key: "drag_enabled", value: String(on))
        }
    }

    @objc private func maximizeToggled(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        let previous = dragEngine.maximizeEnabled
        dragEngine.maximizeEnabled = on
        UserDefaults.standard.set(on, forKey: Preferences.Key.maximizeEnabled)
        if previous != on {
            Analytics.trackPreferenceChanged(key: "maximize_enabled", value: String(on))
        }
    }

    @objc private func tilingToggled(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        let previous = dragEngine.tilingEnabled
        dragEngine.tilingEnabled = on
        UserDefaults.standard.set(on, forKey: Preferences.Key.tilingEnabled)
        if previous != on {
            Analytics.trackPreferenceChanged(key: "tiling_enabled", value: String(on))
        }
    }

    /// Re-render the resize picker's left-drag subtitle so its inline
    /// primary-modifier symbol tracks changes in the primary-modifier picker.
    private func updateResizeTriggerSubtitle() {
        resizeTriggerPicker.setPrimaryModifierSymbol(dragEngine.modifiers.symbol)
    }

    /// Mask of every eligible augment key, for intersection math against the base.
    private var augmentCandidatesMask: ModifierCombination {
        ModifierCombination.augmentCandidates.reduce(into: ModifierCombination()) { $0.formUnion($1) }
    }

    /// Show the augment picker only while "Resize with left-click" is on; when
    /// visible, forbid any key already taken by the base modifier. Returns
    /// whether the visibility changed, so the caller can re-fit the window.
    @discardableResult
    private func updateAugmentPickerState() -> Bool {
        let enabled = dragEngine.leftResizeEnabled
        let visibilityChanged = (augmentSubBlock?.isHidden == enabled)
        augmentSubBlock?.isHidden = !enabled
        if enabled {
            augmentChipRow.disabledElements = augmentCandidatesMask.intersection(dragEngine.modifiers)
        }
        return visibilityChanged
    }

    /// Re-fit the Settings window to this pane after showing/hiding the augment
    /// picker changes its height. Mirrors the General pane's diagnostics
    /// disclosure: width stays locked, height follows the new fitting size,
    /// top-aligned so the window grows/shrinks from the bottom edge.
    private func resizeWindowToFitPane() {
        guard let window = view.window else { return }
        view.layoutSubtreeIfNeeded()
        let targetHeight = view.fittingSize.height
        let currentContent = window.contentRect(forFrameRect: window.frame)
        let contentSize = NSSize(width: currentContent.width, height: targetHeight)
        let targetFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        let current = window.frame
        let topAligned = NSRect(
            x: current.origin.x,
            y: current.origin.y + current.height - targetFrame.height,
            width: targetFrame.width,
            height: targetFrame.height
        )
        window.setFrame(topAligned, display: true, animate: true)
    }

    /// After the base modifier changes, move the augment off any key it now
    /// collides with (persisting + reflecting the move) and refresh the picker.
    private func revalidateAugmentForBaseChange() {
        let sanitized = dragEngine.leftResizeModifier.sanitizedAugment(base: dragEngine.modifiers)
        if sanitized != dragEngine.leftResizeModifier {
            dragEngine.leftResizeModifier = sanitized
            UserDefaults.standard.set(sanitized.rawValue, forKey: Preferences.Key.leftResizeModifier)
            augmentChipRow.selection = sanitized
        }
        updateAugmentPickerState()
    }

    @objc private func cornerBracketToggled(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        let previous = dragEngine.cornerBracketEnabled
        dragEngine.cornerBracketEnabled = on
        UserDefaults.standard.set(on, forKey: Preferences.Key.cornerBracketEnabled)
        if previous != on {
            Analytics.trackPreferenceChanged(key: "corner_bracket_enabled", value: String(on))
        }
    }

    @objc private func multiDisplayBentoToggled(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        let previous = dragEngine.multiDisplayBentoEnabled
        dragEngine.multiDisplayBentoEnabled = on
        UserDefaults.standard.set(on, forKey: Preferences.Key.multiDisplayBentoEnabled)
        if previous != on {
            Analytics.trackPreferenceChanged(key: "multi_display_bento_enabled", value: String(on))
        }
    }

    @objc private func tileDragOnlyToggled(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        let previous = dragEngine.tileByDirectionDragOnly
        dragEngine.tileByDirectionDragOnly = on
        UserDefaults.standard.set(on, forKey: Preferences.Key.tileDragOnly)
        if previous != on {
            Analytics.trackPreferenceChanged(key: "tile_drag_only", value: String(on))
        }
    }

}

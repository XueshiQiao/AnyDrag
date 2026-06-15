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
    private let resizeSwitch   = NSSwitch()
    private let leftResizeSwitch = NSSwitch()
    private let cornerBracketSwitch = NSSwitch()
    private let multiDisplayBentoSwitch = NSSwitch()
    private let tileDragOnlySwitch = NSSwitch()

    /// Single-select picker for the extra key held with the base modifier to
    /// trigger a left-click resize. Limited to the eligible augment keys.
    private let augmentChipRow = ModifierChipRow(
        initial: .shift,
        candidates: ModifierCombination.augmentCandidates,
        singleSelect: true
    )
    private let augmentLabel = SettingsRowBuilder.subLabel("")
    /// The "Secondary Modifier" label + chip row, wrapped so it can be
    /// shown/hidden as a unit. Visible only while "Resize with left-click" is on.
    private weak var augmentSubBlock: NSStackView?
    /// The left-resize toggle's subtitle, kept so it can re-render the live
    /// primary-modifier symbol when the base modifier changes.
    private weak var leftResizeSubtitleLabel: NSTextField?

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

    /// The "Resize with left-click" toggle plus its extra-key picker, grouped as
    /// one card cell (no hairline between them) since the picker only makes
    /// sense as a sub-setting of the toggle.
    private func buildLeftResizeBlock() -> NSView {
        let leftResizeRow = buildFeatureRow(
            title: NSLocalizedString("feature.leftResize", comment: ""),
            subtitle: leftResizeSubtitleText(),
            toggle: leftResizeSwitch,
            action: #selector(leftResizeToggled(_:))
        )
        leftResizeSubtitleLabel = leftResizeRow.subtitle

        augmentLabel.stringValue = NSLocalizedString("leftResize.augment", comment: "")

        augmentChipRow.onChange = { [weak self] proposed in
            guard let self = self else { return false }
            // Only a single eligible key that doesn't collide with the base —
            // otherwise the resize trigger wouldn't differ from the move trigger.
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
        // Hidden unless the feature is on. Set here (before the window measures
        // the pane's fitting height) so it opens at the right size; an NSStackView
        // collapses hidden arranged subviews, so the card shrinks to just the
        // toggle row when off.
        augmentSubBlock.isHidden = !dragEngine.leftResizeEnabled
        self.augmentSubBlock = augmentSubBlock

        let block = NSStackView(views: [leftResizeRow.view, augmentSubBlock])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 10
        block.translatesAutoresizingMaskIntoConstraints = false
        // The toggle row must span the full card width so the switch sits at the
        // right edge; the vertical stack's .leading alignment won't stretch it.
        NSLayoutConstraint.activate([
            leftResizeRow.view.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            leftResizeRow.view.trailingAnchor.constraint(equalTo: block.trailingAnchor),
        ])
        return block
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
            self.updateLeftResizeSubtitle()
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
        let resizeRow = buildFeatureRow(
            title: NSLocalizedString("feature.resize", comment: ""),
            subtitle: NSLocalizedString("feature.resize.subtitle", comment: ""),
            toggle: resizeSwitch,
            action: #selector(resizeToggled(_:))
        )
        let leftResizeBlock = buildLeftResizeBlock()
        let cornerBracketRow = buildFeatureRow(
            title: NSLocalizedString("feature.cornerBracket", comment: ""),
            subtitle: NSLocalizedString("feature.cornerBracket.subtitle", comment: ""),
            toggle: cornerBracketSwitch,
            action: #selector(cornerBracketToggled(_:))
        )

        SettingsCardLayout.addSection(
            to: container,
            header: NSLocalizedString("section.windowResize", comment: ""),
            rows: [resizeRow.view, cornerBracketRow.view, leftResizeBlock]
        )

        // ─── Middle-click action card ─────────────────────────────────
        middleActionPicker.onChange = { [weak self] action in
            guard let self = self else { return }
            let previous = self.dragEngine.middleAction
            self.dragEngine.middleAction = action
            UserDefaults.standard.set(action.rawValue, forKey: Preferences.Key.middleAction)
            if previous != action {
                Analytics.trackPreferenceChanged(key: "middle_action", value: action.rawValue)
            }
        }

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

        SettingsCardLayout.addSection(
            to: container,
            header: NSLocalizedString("Middle-click action", comment: ""),
            rows: [middleActionPicker, multiDisplayRow.view, tileDragOnlyRow.view],
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
        resizeSwitch.state          = dragEngine.resizeEnabled ? .on : .off
        leftResizeSwitch.state      = dragEngine.leftResizeEnabled ? .on : .off
        cornerBracketSwitch.state   = dragEngine.cornerBracketEnabled ? .on : .off
        multiDisplayBentoSwitch.state = dragEngine.multiDisplayBentoEnabled ? .on : .off
        tileDragOnlySwitch.state    = dragEngine.tileByDirectionDragOnly ? .on : .off

        augmentChipRow.selection = dragEngine.leftResizeModifier
        updateAugmentPickerState()
        updateLeftResizeSubtitle()

        updateFeatureRowsEnabled()

        middleActionPicker.selection = dragEngine.middleAction
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

    @objc private func resizeToggled(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        let previous = dragEngine.resizeEnabled
        dragEngine.resizeEnabled = on
        UserDefaults.standard.set(on, forKey: Preferences.Key.resizeEnabled)
        if previous != on {
            Analytics.trackPreferenceChanged(key: "resize_enabled", value: String(on))
        }
    }

    @objc private func leftResizeToggled(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        let previous = dragEngine.leftResizeEnabled
        dragEngine.leftResizeEnabled = on
        UserDefaults.standard.set(on, forKey: Preferences.Key.leftResizeEnabled)
        if updateAugmentPickerState() {
            resizeWindowToFitPane()
        }
        if previous != on {
            Analytics.trackPreferenceChanged(key: "left_resize_enabled", value: String(on))
        }
    }

    /// The left-resize subtitle with the current primary-modifier symbol spliced
    /// into its "%@" slot (e.g. "Hold the primary modifier (⇧) + …").
    private func leftResizeSubtitleText() -> String {
        String(format: NSLocalizedString("feature.leftResize.subtitle", comment: ""),
               dragEngine.modifiers.symbol)
    }

    /// Re-render the left-resize subtitle so its inline primary-modifier symbol
    /// tracks changes made in the primary-modifier picker.
    private func updateLeftResizeSubtitle() {
        leftResizeSubtitleLabel?.stringValue = leftResizeSubtitleText()
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

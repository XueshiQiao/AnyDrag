import SwiftUI
import AppKit
import Carbon.HIToolbox

// The Keyboard Shortcuts page (issue #40): an on/off switch, a preset menu, and
// one recorder row per tile action.

struct KeyboardShortcutsPage: View {
    @EnvironmentObject var store: SettingsStore
    /// Bumped when AnyDrag's windows come to the front, so the warnings below
    /// (which depend on other apps) are worked out again.
    @State private var refresh = 0

    /// Window managers that ship the same ⌃⌥ shortcuts. While one of them runs,
    /// AnyDrag's keyboard tap sees the keys first and Rectangle/Magnet stop
    /// receiving them, so it is worth saying so.
    private static let rivalBundleIDs: [String: String] = [
        "com.knollsoft.Rectangle": "Rectangle",
        "com.knollsoft.Hookshot": "Rectangle Pro",
        "com.crowdcafe.windowmagnet": "Magnet",
    ]

    private var runningRival: String? {
        _ = refresh
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, let name = Self.rivalBundleIDs[id] { return name }
        }
        return nil
    }

    private var currentPresetName: String {
        ShortcutPreset.matching(store.keyboardShortcuts).map { L($0.titleKey) } ?? L("kbd.preset.custom")
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { store.keyboardShortcutsEnabled },
                                     set: { store.setKeyboardShortcutsEnabled($0) })) {
                    featureLabel("keyboard.fill", .indigo, L("kbd.enable"), L("kbd.enable.subtitle"))
                }
                if store.keyboardShortcutsEnabled, let rival = runningRival {
                    note(String(format: L("kbd.warn.rival"), rival))
                }
                if store.keyboardShortcutsEnabled, (refresh >= 0 && IsSecureEventInputEnabled()) {
                    note(L("kbd.warn.secureInput"))
                }
            }

            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Menu(currentPresetName) {
                            ForEach(ShortcutPreset.allCases, id: \.self) { preset in
                                Button(L(preset.titleKey)) { store.applyShortcutPreset(preset) }
                            }
                        }
                        .fixedSize()
                        Button(L("kbd.restoreDefaults")) { store.applyShortcutPreset(.rectangle) }
                            .disabled(ShortcutPreset.matching(store.keyboardShortcuts) == .rectangle)
                    }
                } label: {
                    iconLabel("slider.horizontal.3", .teal, L("kbd.preset.title"))
                }
                note(L("kbd.hint"))
            }

            ForEach(TileAction.shortcutGroups, id: \.titleKey) { group in
                Section {
                    ForEach(group.actions, id: \.self) { action in
                        HStack(spacing: 12) {
                            TileIconView(action: action, isHovered: false)
                                .frame(width: 44, height: 30)
                            Text(L(action.shortcutNameKey))
                            Spacer()
                            ShortcutRecorder(
                                shortcut: store.keyboardShortcuts[action],
                                onChange: { store.setKeyboardShortcut($0, for: action) },
                                onRecording: { store.setShortcutRecording($0) }
                            )
                            .frame(width: 140, height: 24)
                        }
                    }
                } header: {
                    Text(L(group.titleKey))
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh += 1
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Recorder

/// A click-to-record field. Click it, press the shortcut; Esc cancels, and
/// ⌫ with no modifier clears the action. A shortcut with ⌃, ⌥ or ⌘ in it is
/// recorded as pressed, so ⌃⌥⌫ (the default for Restore) can be recorded too.
struct ShortcutRecorder: NSViewRepresentable {
    var shortcut: KeyShortcut?
    var onChange: (KeyShortcut?) -> Void
    var onRecording: (Bool) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.setAccessibilityRole(.button)
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.shortcut = shortcut
        view.onChange = onChange
        view.onRecording = onRecording
        view.needsDisplay = true
    }

    static func dismantleNSView(_ view: RecorderView, coordinator: ()) {
        view.endRecording()
    }

    final class RecorderView: NSView {
        var shortcut: KeyShortcut?
        var onChange: ((KeyShortcut?) -> Void)?
        var onRecording: ((Bool) -> Void)?
        private var recording = false
        private var hint: String?
        private var resignObserver: NSObjectProtocol?
        private var clickMonitor: Any?

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 140, height: 24) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resignObserver.map(NotificationCenter.default.removeObserver)
            resignObserver = nil
            guard let window else { endRecording(); return }
            // Clicking another window mid-recording must not leave the global
            // shortcuts paused.
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in self?.endRecording() }
        }

        deinit { resignObserver.map(NotificationCenter.default.removeObserver) }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        override func becomeFirstResponder() -> Bool {
            recording = true
            hint = nil
            onRecording?(true)
            // A click on a button or menu elsewhere on the page doesn't take
            // focus away from this field, so watch for it and stop recording.
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, self.recording else { return event }
                let local = self.convert(event.locationInWindow, from: nil)
                if event.window !== self.window || !self.bounds.contains(local) { self.endRecording() }
                return event
            }
            needsDisplay = true
            return true
        }

        override func resignFirstResponder() -> Bool {
            stopRecording()
            hint = nil
            needsDisplay = true
            return true
        }

        func endRecording() {
            guard recording else { return }
            if window?.firstResponder === self { window?.makeFirstResponder(nil) } else { stopRecording() }
        }

        private func stopRecording() {
            guard recording else { return }
            recording = false
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
            onRecording?(false)
            needsDisplay = true
        }

        // ⌘-combinations reach a view as key equivalents, not as keyDown.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return false }
            capture(event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            capture(event)
        }

        private func capture(_ event: NSEvent) {
            let mods = KeyShortcut.modifierBits(of: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            if mods == 0 {
                switch Int(event.keyCode) {
                case kVK_Escape:
                    window?.makeFirstResponder(nil)
                    return
                case kVK_Delete, kVK_ForwardDelete:
                    onChange?(nil)
                    window?.makeFirstResponder(nil)
                    return
                default: break
                }
            }
            let label = KeyShortcut.specialLabel(forKeyCode: event.keyCode)
                ?? event.charactersIgnoringModifiers?.uppercased()
                ?? "?"
            let candidate = KeyShortcut(keyCode: event.keyCode, modifiers: mods, label: label)
            guard candidate.isUsable else {
                hint = NSLocalizedString("kbd.record.needModifier", comment: "")
                needsDisplay = true
                return
            }
            onChange?(candidate)
            window?.makeFirstResponder(nil)
        }

        override func draw(_ dirtyRect: NSRect) {
            let box = bounds.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
            (recording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.quaternaryLabelColor.withAlphaComponent(0.12)).setFill()
            path.fill()
            (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = recording ? 1.5 : 1
            path.stroke()

            let text: String
            var color = NSColor.labelColor
            if recording {
                text = hint ?? NSLocalizedString("kbd.record.prompt", comment: "")
                color = hint == nil ? .secondaryLabelColor : .systemOrange
            } else if let shortcut {
                text = shortcut.display
            } else {
                text = NSLocalizedString("kbd.record.none", comment: "")
                color = .tertiaryLabelColor
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: color,
            ]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(
                at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2),
                withAttributes: attrs)
        }

        override func accessibilityLabel() -> String? {
            shortcut?.display ?? NSLocalizedString("kbd.record.none", comment: "")
        }
    }
}

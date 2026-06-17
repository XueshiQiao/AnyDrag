import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The General page (Accessibility permission, Launch at Login, Language, and
// the advanced Diagnostics tuning) and the Excluded Apps page (the blacklist
// list with add/remove). Both are SwiftUI, replacing the old General pane.

// MARK: - General

struct GeneralPage: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        Form {
            // ─── Accessibility permission ───────────────────────────
            Section {
                LabeledContent {
                    if store.accessibilityGranted {
                        Text(L("accessibility.granted"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.green.opacity(0.15)))
                    } else {
                        Button(L("accessibility.grantButton")) { store.openAccessibilitySettings() }
                    }
                } label: {
                    iconLabel("accessibility", .blue, L("accessibility.row.title"))
                }
            }

            // ─── Launch at Login + Language ─────────────────────────
            Section {
                Toggle(isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) })) {
                    iconLabel("power", .green, L("Launch at Login"))
                }
                Picker(selection: Binding(
                    get: { store.languageCode ?? Self.systemTag },
                    set: { store.setLanguage($0 == Self.systemTag ? nil : $0) }
                )) {
                    Text(L("language.followSystem")).tag(Self.systemTag)
                    ForEach(LocalizationOverride.supportedCodes, id: \.self) { code in
                        Text(LocalizationOverride.nativeName(for: code)).tag(code)
                    }
                } label: {
                    iconLabel("globe", .cyan, L("Language"))
                }
            }

            // ─── Diagnostics (advanced) ─────────────────────────────
            Section {
                Text(L("diagnostics.advanced.note"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: Binding(get: { store.showDebugDot }, set: { store.setShowDebugDot($0) })) {
                    featureLabel("smallcircle.filled.circle", Color(nsColor: .systemGray),
                                 L("diagnostics.showDot"), L("diagnostics.showDot.subtitle"))
                }

                sliderRow(
                    symbol: "arrow.up.and.down", color: .orange,
                    title: L("diagnostics.titleBarYOffset"), hint: L("diagnostics.titleBarYOffset.hint"),
                    value: store.titleBarYOffset,
                    range: Preferences.titleBarYOffsetRange,
                    isDefault: store.titleBarYOffset == Preferences.defaultTitleBarYOffset,
                    set: { store.setTitleBarYOffset($0) }, reset: { store.resetTitleBarYOffset() }
                )

                sliderRow(
                    symbol: "arrow.down.right.and.arrow.up.left", color: .teal,
                    title: L("diagnostics.resizeCornerInset"), hint: L("diagnostics.resizeCornerInset.hint"),
                    value: store.resizeCornerInset,
                    range: Preferences.resizeCornerInsetRange,
                    isDefault: store.resizeCornerInset == Preferences.defaultResizeCornerInset,
                    set: { store.setResizeCornerInset($0) }, reset: { store.resetResizeCornerInset() }
                )
            } header: {
                Text(L("Diagnostics"))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("General"))
    }

    private static let systemTag = "__system__"

    /// A diagnostics slider block: icon + title, live value, Reset, the slider,
    /// and a wrapping hint below.
    private func sliderRow(
        symbol: String, color: Color, title: String, hint: String,
        value: CGFloat, range: ClosedRange<CGFloat>, isDefault: Bool,
        set: @escaping (CGFloat) -> Void, reset: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                iconLabel(symbol, color, title)
                Spacer()
                Text("\(Int(value.rounded())) px")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                Button(L("diagnostics.reset")) { reset() }
                    .controlSize(.small)
                    .disabled(isDefault)
            }
            Slider(
                value: Binding(get: { Double(value) }, set: { set(CGFloat($0)) }),
                in: Double(range.lowerBound)...Double(range.upperBound), step: 1
            )
            Text(hint)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Excluded Apps

struct ExcludedAppsPage: View {
    @EnvironmentObject var store: SettingsStore
    @State private var selection = Set<String>()
    @State private var showAdd = false

    var body: some View {
        // A List MUST be the page root here — nesting it in a VStack inside the
        // NavigationSplitView detail collapses its layout (rows spill into the
        // title bar). The explanatory note is the section footer (the System
        // Settings idiom); the +/- bar is a bottom safe-area inset.
        List(selection: $selection) {
            Section {
                if store.blacklist.isEmpty {
                    Text(L("blacklist.empty")).foregroundStyle(.secondary)
                } else {
                    ForEach(store.blacklist, id: \.bundleID) { app in
                        HStack(spacing: 10) {
                            Image(nsImage: store.icon(forBundleID: app.bundleID))
                                .resizable().frame(width: 22, height: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name)
                                Text(app.bundleID)
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                        }
                        .tag(app.bundleID)
                    }
                }
            } footer: {
                Text(L("blacklist.note"))
                    .textCase(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle(L("blacklist.title"))
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                // + and − are the SAME control: a plain Button drawing the same
                // PlusMinusBezel. A SwiftUI Menu renders its label inconsistently
                // (its chrome ignored/overrode the custom bezel), so the add list
                // is shown from a popover instead — keeping the two buttons
                // pixel-identical by construction.
                Button { showAdd = true } label: {
                    PlusMinusBezel(symbol: "plus")
                }
                .buttonStyle(.plain)
                .help(L("blacklist.add"))
                .popover(isPresented: $showAdd, arrowEdge: .bottom) { addPopover }

                Button {
                    store.removeBlacklistedApps(bundleIDs: selection)
                    selection.removeAll()
                } label: {
                    PlusMinusBezel(symbol: "minus", enabled: !selection.isEmpty)
                }
                .buttonStyle(.plain)
                .disabled(selection.isEmpty)
                .help(L("blacklist.remove"))

                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.bar)
        }
    }

    /// The "add app" popover: running, Dock-visible apps to add in one click,
    /// plus Browse… for apps that aren't running.
    private var addPopover: some View {
        let running = store.addableRunningApps()
        return VStack(alignment: .leading, spacing: 0) {
            if running.isEmpty {
                Text(L("blacklist.noRunningApps"))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                Text(L("blacklist.runningApps"))
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(running, id: \.bundleID) { app in
                            AddAppRow(name: app.name, icon: store.icon(forBundleID: app.bundleID)) {
                                store.addBlacklistedApp(app)
                                showAdd = false
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            Divider()
            AddAppRow(name: L("blacklist.browse"), icon: nil) {
                showAdd = false
                // Defer so the popover finishes dismissing before the modal panel.
                DispatchQueue.main.async { browse() }
            }
        }
        .frame(width: 260)
        .padding(.vertical, 4)
    }

    /// Pick app bundles that aren't currently running (NSOpenPanel into /Applications).
    private func browse() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("blacklist.choose")
        guard panel.runModal() == .OK else { return }
        var apps: [BlacklistedApp] = []
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { continue }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            apps.append(BlacklistedApp(bundleID: bundleID, name: name))
        }
        store.addBlacklistedApps(apps)
    }
}

/// One tappable row in the "add app" popover, with a menu-like hover highlight.
private struct AddAppRow: View {
    let name: String
    let icon: NSImage?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: "folder").frame(width: 16, height: 16).foregroundStyle(.secondary)
                }
                Text(name).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(hover ? Color.accentColor.opacity(0.15) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The shared +/- control bezel: a fixed 30×24 rounded rect with a centered
/// glyph. Used as the (plain) label for both the add and remove buttons so the
/// two controls are pixel-identical regardless of the system chrome each would
/// otherwise draw.
private struct PlusMinusBezel: View {
    let symbol: String
    var enabled: Bool = true

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(enabled ? Color.primary : Color.secondary)
            .frame(width: 30, height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .controlColor)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

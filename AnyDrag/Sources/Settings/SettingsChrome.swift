import SwiftUI
import AppKit

// Settings "chrome": the shared visual language (aurora background, colored icon
// tiles, sidebar icons, status dot) plus the root `NavigationSplitView` that
// hosts the sidebar + detail panes. Aligned with HyperCapslock's ContentView /
// UIHelpers so both apps' Settings windows read as one family.

/// Short alias for the bundle-localized string lookup. Keeps SwiftUI call sites
/// terse while still flowing through `NSLocalizedString` (and therefore the
/// `LocalizationOverride` bundle swap), so we reuse AnyDrag's existing
/// Localizable.strings rather than an in-code table.
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

// MARK: - Sidebar pages

enum SettingsPage: Hashable, CaseIterable {
    case windowDrag, windowResize, middleClick, excludedApps, general, about

    /// Existing Localizable.strings key reused as the page title / sidebar label.
    var titleKey: String {
        switch self {
        case .windowDrag:   return "section.windowDrag"
        case .windowResize: return "section.windowResize"
        case .middleClick:  return "Middle-click action"
        case .excludedApps: return "blacklist.title"
        case .general:      return "General"
        case .about:        return "About"
        }
    }

    var symbol: String {
        switch self {
        case .windowDrag:   return "arrow.up.and.down.and.arrow.left.and.right"
        case .windowResize: return "arrow.down.right.and.arrow.up.left"
        case .middleClick:  return "square.split.2x2.fill"
        case .excludedApps: return "nosign"
        case .general:      return "gearshape.fill"
        case .about:        return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .windowDrag:   return .blue
        case .windowResize: return .teal
        case .middleClick:  return .orange
        case .excludedApps: return .red
        case .general:      return Color(nsColor: .systemGray)
        case .about:        return .pink
        }
    }

    /// Stable, language-independent id stem for accessibility identifiers.
    var axID: String {
        switch self {
        case .windowDrag:   return "window_drag"
        case .windowResize: return "window_resize"
        case .middleClick:  return "middle_click"
        case .excludedApps: return "excluded_apps"
        case .general:      return "general"
        case .about:        return "about"
        }
    }
}

// MARK: - Aurora background

extension View {
    /// The signature soft aurora wash, composited over an OPAQUE window base.
    /// Opaque matters for performance: paired with `.scrollContentBackground(.hidden)`
    /// on the Form, a translucent wash would let the window vibrancy re-sample
    /// the desktop on every drag frame. Mirrors HyperCapslock's `auroraBackground`.
    func auroraBackground() -> some View {
        background(
            Color(nsColor: .windowBackgroundColor)
                .overlay(
                    LinearGradient(colors: [Color(.sRGB, red: 0.40, green: 0.55, blue: 1.00, opacity: 0.10),
                                            Color(.sRGB, red: 1.00, green: 0.55, blue: 0.85, opacity: 0.07),
                                            Color(.sRGB, red: 0.35, green: 0.85, blue: 0.70, opacity: 0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                .ignoresSafeArea()
        )
    }
}

// MARK: - Colored icon tiles

/// 26pt rounded gradient tile in `color`, with a hairline white edge.
private struct ColorTile: ViewModifier {
    let color: Color
    func body(content: Content) -> some View {
        content
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(
                LinearGradient(colors: [color, color.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.18)))
    }
}
extension View { func colorTile(_ color: Color) -> some View { modifier(ColorTile(color: color)) } }

/// White SF Symbol on a colored tile.
struct IconTile: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .colorTile(color)
    }
}

/// A white template-rendered asset (e.g. a brand logo) on a colored tile.
struct AssetIconTile: View {
    let asset: String
    let color: Color
    var glyph: CGFloat = 15
    var body: some View {
        Image(asset).renderingMode(.template).resizable().scaledToFit()
            .frame(width: glyph, height: glyph)
            .foregroundStyle(.white)
            .colorTile(color)
    }
}

/// Leading "icon tile + text" label used in almost every settings row.
func iconLabel(_ symbol: String, _ color: Color, _ text: String) -> some View {
    HStack(spacing: 10) { IconTile(symbol: symbol, color: color); Text(text) }
}

/// A feature row's leading label: icon tile + title over a wrapping secondary
/// subtitle. Used as the label of the toggle rows in the gesture pages.
func featureLabel(_ symbol: String, _ color: Color, _ title: String, _ subtitle: String) -> some View {
    HStack(spacing: 10) {
        IconTile(symbol: symbol, color: color)
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Sidebar row icon

/// A System-Settings-style sidebar row icon: a white SF Symbol on a colored
/// rounded square. Rasterized so the row-selection vibrancy can't tint it.
struct SidebarIcon: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(
                LinearGradient(colors: [color.opacity(0.98), color.opacity(0.68)],
                               startPoint: .top, endPoint: .bottom)))
            .drawingGroup()
    }
}

// MARK: - Status dot

/// Solid green when active, orange when off / blocked.
struct StatusDot: View {
    let active: Bool
    var body: some View {
        Circle()
            .fill(active ? Color.green : Color.orange)
            .frame(width: 9, height: 9)
            .frame(width: 12, height: 12)
    }
}

// MARK: - Root view

struct SettingsRootView: View {
    @EnvironmentObject var store: SettingsStore

    /// AnyDrag's honest top-level status: permission first, then whether a
    /// primary modifier is set (no modifier ⇒ the engine has nothing to arm on).
    private var statusActive: Bool {
        store.accessibilityGranted && !store.modifiers.isEmpty
    }

    private var statusText: String {
        if !store.accessibilityGranted { return L("status.permission") }
        return store.modifiers.isEmpty ? L("status.off") : L("status.on")
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $store.page) {
                ForEach(SettingsPage.allCases, id: \.self) { page in
                    sidebarRow(page)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 216, max: 240)
            .safeAreaInset(edge: .top, spacing: 0) { brand }
            .safeAreaInset(edge: .bottom, spacing: 0) { statusFooter }
        } detail: {
            Group {
                switch store.page {
                case .windowDrag:   WindowDragPage()
                case .windowResize: WindowResizePage()
                case .middleClick:  MiddleClickPage()
                case .excludedApps: ExcludedAppsPage()
                case .general:      GeneralPage()
                case .about:        AboutPage()
                }
            }
            .accessibilityIdentifier("page.\(store.page.axID)")
            .environment(\.defaultMinListRowHeight, 34)
            .scrollContentBackground(.hidden)
            .auroraBackground()
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(action: toggleSidebar) { Image(systemName: "sidebar.leading") }
                        .help(L("nav.toggleSidebar"))
                }
            }
        }
        .frame(minWidth: 720, minHeight: 540)
        // Re-key the whole tree when the in-app language changes so every
        // NSLocalizedString-derived label re-reads. `store.page` is store-backed,
        // so the selected page survives the rebuild.
        .id(store.languageRevision)
    }

    private func sidebarRow(_ page: SettingsPage) -> some View {
        HStack(spacing: 9) {
            SidebarIcon(symbol: page.symbol, color: page.color)
            Text(L(page.titleKey))
        }
        .padding(.vertical, 2)
        .tag(page)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nav.\(page.axID)")
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text("AnyDrag").font(.system(size: 14, weight: .bold))
                Text("v\(appVersion)").font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
    }

    private var statusFooter: some View {
        HStack(spacing: 7) {
            StatusDot(active: statusActive)
            Text(statusText)
                .font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// Toggle the split view's sidebar by sending the AppKit `toggleSidebar:`
    /// action up the responder chain (the SwiftUI split view is backed by an
    /// NSSplitViewController that handles it).
    private func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?.tryToPerform(
            #selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
    }
}

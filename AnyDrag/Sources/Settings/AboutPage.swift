import SwiftUI
import AppKit

// The About page: a centered app hero, author/cross-promo link rows, the
// anonymous-usage opt-out, and copyright. A check-for-updates button lives in
// the page toolbar. Mirrors HyperCapslock's AboutPage.
struct AboutPage: View {
    @EnvironmentObject var store: SettingsStore
    @State private var updateSpin = 0

    private static let githubURL  = "https://github.com/XueshiQiao/AnyDrag"
    private static let xURL       = "https://x.com/XueshiQiao"
    private static let websiteURL = "https://xueshi.dev"
    private static let brandTint  = Color(red: 0.16, green: 0.17, blue: 0.20)

    private var versionString: String {
        let bundle = Bundle.main
        let short = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
        return String(format: L("about.version.format"), short, build)
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                    Text("AnyDrag").font(.title2).fontWeight(.bold)
                    Text(versionString).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                linkRow(asset: "GitHubLogo", tint: Self.brandTint, title: L("GitHub Repository"), url: Self.githubURL)
                linkRow(asset: "XLogo", tint: Self.brandTint, title: "@XueshiQiao", url: Self.xURL)
                linkRow(systemImage: "globe", tint: .blue,
                        title: "\(L("about.website.description")) xueshi.dev", url: Self.websiteURL)
            }

            Section {
                Toggle(isOn: Binding(get: { store.analyticsEnabled }, set: { store.setAnalyticsEnabled($0) })) {
                    iconLabel("chart.bar.fill", .purple, L("about.analytics.toggle"))
                }
                Text(L("about.analytics.subtitle"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Text(L("about.copyright"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("About"))
        .toolbar {
            ToolbarItem {
                Button {
                    updateSpin += 1
                    store.updateController.checkForUpdates(nil)
                } label: {
                    if #available(macOS 15, *) {
                        Label(L("Check for Updates…"), systemImage: "arrow.triangle.2.circlepath")
                            .symbolEffect(.rotate, value: updateSpin)
                    } else {
                        Label(L("Check for Updates…"), systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(!store.updateController.canCheckForUpdates)
            }
        }
    }

    private func linkRow(asset: String? = nil, systemImage: String? = nil,
                         tint: Color, title: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            HStack(spacing: 10) {
                if let asset { AssetIconTile(asset: asset, color: tint) }
                else if let systemImage { IconTile(symbol: systemImage, color: tint) }
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

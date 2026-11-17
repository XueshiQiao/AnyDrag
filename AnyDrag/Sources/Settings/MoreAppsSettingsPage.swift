import SwiftUI
import MoreAppsKit

// The "More Apps" sidebar page: the author's other apps, each with a button
// that downloads it, installs it into the Applications folder and opens it.
//
// All of the content and behaviour comes from the shared MoreAppsKit package,
// which the author's other apps embed too. This wrapper only supplies the page
// title and the store that `SettingsStore` owns.
struct MoreAppsSettingsPage: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        MoreAppsPage(store: store.moreApps)
            .navigationTitle(L("More Apps"))
    }
}

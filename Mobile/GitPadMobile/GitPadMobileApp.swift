import SwiftUI

@main
struct GitPadMobileApp: App {
    @StateObject private var store = MobileStore()
    @AppStorage("theme") private var themeID = "System"

    var body: some Scene {
        WindowGroup {
            let theme = Theme.named(themeID)
            Group {
                if store.isConnected { LibraryView(store: store) } else { SetupView(store: store) }
            }
            .environment(\.theme, theme)
            .tint(theme.accent)
            .preferredColorScheme(theme.scheme)
        }
    }
}

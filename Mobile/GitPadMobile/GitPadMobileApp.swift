import SwiftUI

@main
struct GitPadMobileApp: App {
    @StateObject private var store = MobileStore()

    var body: some Scene {
        WindowGroup {
            if store.isConnected {
                LibraryView(store: store)
            } else {
                SetupView(store: store)
            }
        }
    }
}

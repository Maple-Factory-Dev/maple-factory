import MapleKit
import SwiftUI

/// Maple Factory for iPhone. `-demo YES` opens the sample factory; otherwise the last factory
/// signed into, or the sign-in screen.
@main
struct MapleFactoryApp: App {
    @State private var store = FactoryStore()

    init() {
        ErrorReports.start()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if store.isSignedIn {
                    RootView()
                } else {
                    SignInView()
                }
            }
            .environment(store)
            .tint(Theme.accent)
            .animation(.default, value: store.isSignedIn)
            .task {
                if UserDefaults.standard.bool(forKey: "demo") { store.startDemo() } else { store.restore() }
            }
            .onOpenURL { url in
                // maplefactory://task/<id> or maplefactory://session/<machine>/<id>; RootView opens it
                // once you're signed in. Anything else is ignored.
                if let link = FactoryLink(url: url) { store.pendingLink = link }
            }
        }
    }
}

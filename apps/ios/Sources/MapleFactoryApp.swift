import SwiftUI

@main
struct MapleFactoryApp: App {
    init() {
        ErrorReports.start()
    }

    var body: some Scene {
        WindowGroup { Text("Maple Factory") }
    }
}

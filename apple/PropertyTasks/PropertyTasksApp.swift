import SwiftUI

@main
struct PropertyTasksApp: App {
    @State private var session = Session()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
        }
        #if os(macOS)
        Settings {
            SettingsView().environment(session)
        }
        #endif
    }
}

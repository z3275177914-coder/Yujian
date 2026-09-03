import SwiftUI
import ImageViewerCore

@main
@MainActor
struct ImageViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: ImageViewerModel

    init() {
        // This must run before ImageViewerModel initializes its published
        // settings and Keychain-backed AI state.
        AppIdentityMigration.run()
        _model = StateObject(wrappedValue: ImageViewerModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                initialURL: appDelegate.consumePendingOpenURL(),
                initialToolURLs: appDelegate.consumePendingLocalToolURLs()
            )
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            ViewerCommands(model: model)
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

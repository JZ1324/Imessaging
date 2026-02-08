import SwiftUI
import AppKit

@main
struct ImessageStatsMacApp: App {
    init() {
        // Ensure the app shows a window when launched from Terminal / SwiftPM.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    UpdaterService.shared.checkForUpdates()
                }
                .keyboardShortcut("u", modifiers: [.command, .option])
            }
        }
    }
}

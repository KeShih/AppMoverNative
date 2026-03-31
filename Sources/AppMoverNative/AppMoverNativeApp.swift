import AppKit
import SwiftUI

@main
struct AppMoverNativeApp: App {
    @StateObject private var viewModel = AppMoverViewModel()

    init() {
        installAppIconIfAvailable()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 980, minHeight: 560)
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
    }

    private func installAppIconIfAvailable() {
        guard
            let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
            let iconImage = NSImage(contentsOf: iconURL)
        else {
            return
        }

        NSApplication.shared.applicationIconImage = iconImage
    }
}

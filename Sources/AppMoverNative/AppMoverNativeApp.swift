import SwiftUI

@main
struct AppMoverNativeApp: App {
    @StateObject private var viewModel = AppMoverViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 1120, minHeight: 720)
        }
    }
}

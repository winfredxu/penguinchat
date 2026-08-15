import PenguinChatCore
import SwiftUI

@main
struct PenguinChatMacApp: App {
    private let environment = AppEnvironment.resolve()

    var body: some Scene {
        WindowGroup("PenguinChat") {
            RootView(environment: environment)
                .frame(minWidth: 840, minHeight: 560)
        }
        .defaultSize(width: 1040, height: 680)
        .windowResizability(.contentMinSize)
    }
}

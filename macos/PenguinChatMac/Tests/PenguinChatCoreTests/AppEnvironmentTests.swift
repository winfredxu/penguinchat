import Foundation
import Testing
@testable import PenguinChatCore

@Test func environmentDefaultsToLocalAPI() {
    #expect(AppEnvironment.resolve(environment: [:]) == .local)
    #expect(AppEnvironment.local.apiBaseURL.absoluteString == "http://127.0.0.1:3000")
}

@Test func environmentAcceptsHTTPOverride() {
    let environment = AppEnvironment.resolve(environment: [
        AppEnvironment.apiURLVariable: "https://chat.example.test/api"
    ])
    #expect(environment.apiBaseURL.absoluteString == "https://chat.example.test/api")
}

@Test func environmentRejectsInvalidOverride() {
    let environment = AppEnvironment.resolve(environment: [
        AppEnvironment.apiURLVariable: "file:///private/tmp/server"
    ])
    #expect(environment == .local)
}

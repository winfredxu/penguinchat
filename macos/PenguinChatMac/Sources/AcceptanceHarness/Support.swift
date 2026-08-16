import Foundation
import PenguinChatCore
import PenguinChatSocketIO

/// Tokens live only in memory for a harness run. The acceptance path must not
/// touch the Keychain item the shipping app owns, and must not leave credentials
/// on disk.
actor InMemoryCredentialStore: CredentialStoring {
    private var tokens: Tokens?

    func loadTokens() async throws -> Tokens? { tokens }
    func saveTokens(_ tokens: Tokens) async throws { self.tokens = tokens }
    func deleteTokens() async throws { tokens = nil }
}

@MainActor
final class Report {
    private(set) var failures: [String] = []
    private var passed = 0

    func check(_ name: String, _ satisfied: Bool, detail: String = "") {
        if satisfied {
            passed += 1
            print("PASS  \(name)")
        } else {
            failures.append(name)
            print("FAIL  \(name)" + (detail.isEmpty ? "" : " — \(detail)"))
        }
    }

    func note(_ message: String) {
        print("      \(message)")
    }

    func summarize() {
        print("")
        print("\(passed) passed, \(failures.count) failed")
        for failure in failures { print("  failed: \(failure)") }
    }
}

/// Polls `condition` until it holds or the timeout elapses. Real-time assertions
/// are inherently racy against a live server, so every check that depends on a
/// round trip goes through here instead of a fixed sleep.
@MainActor
func waitFor(
    timeout: Duration = .seconds(15),
    interval: Duration = .milliseconds(100),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return await condition()
}

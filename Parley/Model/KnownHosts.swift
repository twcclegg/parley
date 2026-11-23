import Foundation
import Observation
import ParleyCore

/// Server host keys you've trusted, by endpoint, like `~/.ssh/known_hosts`.
@MainActor @Observable
final class KnownHosts {
    private(set) var keys: [String: String]
    private let defaultsKey = "knownHosts"

    init() {
        keys = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    func key(for endpoint: String) -> String? { keys[endpoint] }

    func trust(_ keyLine: String, for endpoint: String) {
        keys[endpoint] = keyLine
        UserDefaults.standard.set(keys, forKey: defaultsKey)
    }

    func forget(_ endpoint: String) {
        keys[endpoint] = nil
        UserDefaults.standard.set(keys, forKey: defaultsKey)
    }
}

/// Asks you whether to trust a server you haven't connected to before.
@MainActor @Observable
final class HostKeyPrompter {
    struct Prompt: Identifiable {
        let id = UUID()
        let hostLabel: String
        let keyType: String
        let fingerprint: String
        fileprivate let continuation: CheckedContinuation<Bool, Never>
    }

    var current: Prompt?
    let known: KnownHosts
    /// Why the last check said no, when it was a changed key rather than your choice.
    private(set) var mismatches: [String: String] = [:]

    init(known: KnownHosts) {
        self.known = known
    }

    func validate(_ keyLine: String, for host: Host) async -> Bool {
        let endpoint = host.endpoint
        let presented = OpenSSHKey.fingerprint(of: keyLine)
        if let saved = known.key(for: endpoint) {
            if Self.sameKey(saved, keyLine) {
                mismatches[endpoint] = nil
                return true
            }
            let savedPrint = OpenSSHKey.fingerprint(of: saved)?.fingerprint ?? "unknown"
            mismatches[endpoint] =
                "The server's host key has changed. Saved: \(savedPrint). Now: \(presented?.fingerprint ?? "unknown"). If you expected this, forget the saved key in the server's settings and connect again."
            return false
        }
        // Only one question at a time.
        while current != nil { try? await Task.sleep(for: .milliseconds(200)) }
        let accepted = await withCheckedContinuation { continuation in
            current = Prompt(
                hostLabel: host.port == 22 ? host.hostname : "\(host.hostname):\(host.port)",
                keyType: presented?.type ?? "unknown",
                fingerprint: presented?.fingerprint ?? "unknown",
                continuation: continuation
            )
        }
        if accepted { known.trust(keyLine, for: endpoint) }
        return accepted
    }

    func answer(_ trust: Bool) {
        guard let prompt = current else { return }
        current = nil
        prompt.continuation.resume(returning: trust)
    }

    func mismatch(for host: Host) -> String? { mismatches[host.endpoint] }

    private static func sameKey(_ a: String, _ b: String) -> Bool {
        let fieldsA = a.split(separator: " "), fieldsB = b.split(separator: " ")
        return fieldsA.count >= 2 && fieldsB.count >= 2 && fieldsA[0] == fieldsB[0] && fieldsA[1] == fieldsB[1]
    }
}

import Foundation
import Observation

/// The servers you've added, kept in a JSON file in Application Support.
@MainActor @Observable
final class HostStore {
    private(set) var hosts: [Host] = []
    private let file: URL

    init() {
        let folder = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        file = folder.appendingPathComponent("hosts.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Host].self, from: data) {
            hosts = saved
        }
    }

    func host(_ id: Host.ID) -> Host? { hosts.first { $0.id == id } }

    func save(_ host: Host) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        persist()
    }

    func update(_ id: Host.ID, _ change: (inout Host) -> Void) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        change(&hosts[index])
        persist()
    }

    func delete(_ id: Host.ID) {
        hosts.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

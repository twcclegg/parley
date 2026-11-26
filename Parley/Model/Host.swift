import Foundation

/// A server Parley reaches over SSH, and where to start Claude Code on it.
struct Host: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name = ""
    var hostname = ""
    var port = 22
    var username = ""
    /// The folder Claude Code starts in. `~` is the home folder.
    var directory = "~"
    /// The `claude` executable, when it isn't on the login shell's PATH.
    var claudePath = ""
    /// `--permission-mode` for new sessions, or nil for the server's own setting.
    var permissionMode: String?
    /// The last session Claude Code reported, to continue it later.
    var lastSessionId: String?
    /// The Claude Code process Parley left running on the server, to reattach to it.
    var runId: String?

    var displayName: String { name.isEmpty ? hostname : name }

    /// The key under which the server's host key is remembered.
    var endpoint: String { port == 22 ? hostname.lowercased() : "[\(hostname.lowercased())]:\(port)" }

    var isComplete: Bool {
        !hostname.trimmingCharacters(in: .whitespaces).isEmpty && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && (1...65535).contains(port)
    }
}

/// The permission modes Parley offers. `bypassPermissions` is left out on purpose.
enum PermissionMode: String, CaseIterable, Identifiable {
    case manual
    case acceptEdits
    case auto
    case plan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "Ask Before Acting"
        case .acceptEdits: "Accept Edits"
        case .auto: "Auto"
        case .plan: "Plan Only"
        }
    }
}

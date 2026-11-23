import ParleyCore
import ParleySSH
import SwiftUI

/// Signs in once with a password and adds this device's key to `~/.ssh/authorized_keys`.
struct InstallKeyView: View {
    let host: Host
    @Environment(DeviceKeyStore.self) private var keys
    @Environment(HostKeyPrompter.self) private var prompter
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var working = false
    @State private var outcome: Outcome?

    enum Outcome {
        case installed
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password for \(host.username)", text: $password)
                        .textContentType(.password)
                        .onSubmit { Task { await install() } }
                } footer: {
                    Text("Used once to sign in to \(host.hostname) and add this device's key. Parley doesn't keep it.")
                }
                if let outcome {
                    Section {
                        switch outcome {
                        case .installed:
                            Label("The key is installed. You can chat with this server now.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failed(let reason):
                            Label(reason, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Install Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Install", systemImage: "checkmark") { Task { await install() } }
                            .disabled(password.isEmpty)
                    }
                }
            }
        }
    }

    private func install() async {
        guard !password.isEmpty, !working else { return }
        working = true
        defer { working = false }
        do {
            let key = try keys.deviceKey()
            let host = self.host
            let prompter = self.prompter
            let connection = try await SSHConnection.connect(
                host: host.hostname,
                port: host.port,
                username: host.username,
                authentication: [.password(password)],
                validateHostKey: { line in await prompter.validate(line, for: host) }
            )
            let line = ClaudeCommand.quote(key.publicKeyLine)
            let script =
                "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && (grep -qxF \(line) ~/.ssh/authorized_keys || printf '%s\\n' \(line) >> ~/.ssh/authorized_keys)"
            let result = try await connection.run("sh -c " + ClaudeCommand.quote(script))
            await connection.close()
            password = ""
            if result.status == 0 {
                outcome = .installed
            } else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                outcome = .failed("The server couldn't add the key." + (detail.isEmpty ? "" : " " + detail))
            }
        } catch {
            outcome = .failed(prompter.mismatch(for: host) ?? ChatSession.describe(error))
        }
    }
}

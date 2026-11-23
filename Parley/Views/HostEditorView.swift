import SwiftUI

struct HostEditorView: View {
    @Environment(HostStore.self) private var hosts
    @Environment(KnownHosts.self) private var known
    @Environment(\.dismiss) private var dismiss
    @State private var host: Host
    @State private var portText: String
    @State private var installing = false
    private let isNew: Bool

    init(host: Host) {
        _host = State(initialValue: host)
        _portText = State(initialValue: String(host.port))
        isNew = host.hostname.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $host.name, prompt: Text("Optional"))
                    TextField("Host", text: $host.hostname, prompt: Text("server.local or 192.0.2.10"))
                        .keyboardType(.URL)
                        .plainEntry()
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                        .onChange(of: portText) { _, text in host.port = Int(text) ?? 0 }
                    TextField("User", text: $host.username)
                        .plainEntry()
                } header: {
                    Text("Server")
                }

                Section {
                    TextField("Folder", text: $host.directory, prompt: Text("~"))
                        .plainEntry()
                    TextField("Claude Command", text: $host.claudePath, prompt: Text("claude"))
                        .plainEntry()
                } header: {
                    Text("Claude Code")
                } footer: {
                    Text("Claude Code starts in this folder. Leave the command empty to use `claude` from your login shell's PATH.")
                }

                Section {
                    Button("Install This Device's Key…", systemImage: "key.viewfinder") { installing = true }
                        .disabled(!host.isComplete)
                    if known.key(for: host.endpoint) != nil {
                        Button("Forget Saved Host Key", systemImage: "xmark.shield", role: .destructive) {
                            known.forget(host.endpoint)
                        }
                    }
                } header: {
                    Text("Access")
                } footer: {
                    Text("Parley signs in with this device's key. If the server accepts passwords, Parley can add the key for you; otherwise add it to ~/.ssh/authorized_keys yourself (see This Device's Key).")
                }
            }
            .navigationTitle(isNew ? "Add Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        host.hostname = host.hostname.trimmingCharacters(in: .whitespaces)
                        host.username = host.username.trimmingCharacters(in: .whitespaces)
                        hosts.save(host)
                        dismiss()
                    }
                    .disabled(!host.isComplete)
                }
            }
            .sheet(isPresented: $installing) {
                InstallKeyView(host: host)
            }
        }
    }
}

extension View {
    /// For addresses, user names and paths: no capitals, no corrections.
    func plainEntry() -> some View {
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}

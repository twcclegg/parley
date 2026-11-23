import SwiftUI

struct DeviceKeyView: View {
    @Environment(DeviceKeyStore.self) private var keys
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var confirmingNewKey = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                if let key = keys.key {
                    Section {
                        Text(key.publicKeyLine)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                        Button(copied ? "Copied" : "Copy Public Key", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            UIPasteboard.general.string = key.publicKeyLine
                            copied = true
                        }
                        ShareLink("Share Public Key", item: key.publicKeyLine)
                    } header: {
                        Text("Public Key")
                    } footer: {
                        Text("Add this line to ~/.ssh/authorized_keys on each server, or use Install This Device's Key in a server's settings.")
                    }
                    Section {
                        LabeledContent("Fingerprint") {
                            Text(key.fingerprint).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        }
                        LabeledContent("Kept In", value: key.isSecureEnclave ? "Secure Enclave" : "Keychain")
                    } footer: {
                        Text(key.isSecureEnclave
                             ? "The private key was made in this device's Secure Enclave and can't be copied off it."
                             : "This device has no Secure Enclave, so the private key is kept in the Keychain.")
                    }
                    Section {
                        Button("Make a New Key…", role: .destructive) { confirmingNewKey = true }
                    }
                } else {
                    Section {
                        Button("Make This Device's Key", systemImage: "key") { make() }
                    } footer: {
                        Text("Parley signs in to servers with a key made on this device.")
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("This Device's Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .confirmationDialog("Make a new key?", isPresented: $confirmingNewKey, titleVisibility: .visible) {
                Button("Make New Key", role: .destructive) {
                    do { try keys.regenerate(); copied = false } catch { self.error = error.localizedDescription }
                }
            } message: {
                Text("The current key is deleted. Servers that accept it won't accept the new one until you add it.")
            }
            .onAppear { if keys.key == nil { make() } }
        }
    }

    private func make() {
        do { _ = try keys.deviceKey() } catch { self.error = error.localizedDescription }
    }
}

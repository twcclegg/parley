import SwiftUI

@main
struct ParleyApp: App {
    @State private var hosts = HostStore()
    @State private var keys = DeviceKeyStore()
    @State private var prompter = HostKeyPrompter(known: KnownHosts())
    @State private var sessions = SessionStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HostListView()
                .environment(hosts)
                .environment(keys)
                .environment(prompter)
                .environment(prompter.known)
                .environment(sessions)
                .hostKeyPrompt(prompter)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await sessions.resumeDropped() }
            }
        }
    }
}

private struct HostKeyPromptModifier: ViewModifier {
    @Bindable var prompter: HostKeyPrompter

    func body(content: Content) -> some View {
        content.alert(
            "Trust This Server?",
            isPresented: Binding(
                get: { prompter.current != nil },
                set: { shown in if !shown { prompter.answer(false) } }
            ),
            presenting: prompter.current
        ) { _ in
            Button("Trust") { prompter.answer(true) }
            Button("Cancel", role: .cancel) { prompter.answer(false) }
        } message: { prompt in
            Text(
                "This is the first connection to \(prompt.hostLabel). Its \(prompt.keyType) host key is:\n\n\(prompt.fingerprint)\n\nTo check it, run ssh-keygen -lf on the server's /etc/ssh/ssh_host_*_key.pub files."
            )
        }
    }
}

extension View {
    func hostKeyPrompt(_ prompter: HostKeyPrompter) -> some View {
        modifier(HostKeyPromptModifier(prompter: prompter))
    }
}

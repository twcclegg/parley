import SwiftTerm
import SwiftUI

/// The side terminal, shown as a sheet over the conversation.
struct ShellView: View {
    let shell: ShellSession
    let hostName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TerminalHost(view: shell.view)
                .ignoresSafeArea(.container, edges: .bottom)
                .overlay {
                    switch shell.phase {
                    case .connecting:
                        ProgressView("Connecting…")
                            .padding()
                            .parleyGlass(in: .rect(cornerRadius: 16))
                    case .ended(let reason):
                        VStack(spacing: 12) {
                            Text("Shell disconnected").font(.headline)
                            if let reason { Text(reason).font(.footnote).foregroundStyle(.secondary) }
                            Button("Reconnect") { Task { await shell.start() } }
                                .buttonStyle(.parleyGlassProminent)
                        }
                        .multilineTextAlignment(.center)
                        .padding(20)
                        .parleyGlass(in: .rect(cornerRadius: 20))
                        .padding()
                    case .idle, .connected:
                        EmptyView()
                    }
                }
                .navigationTitle(shell.title.isEmpty ? hostName : shell.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close", systemImage: "chevron.down") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("Shell", systemImage: "ellipsis") {
                            Button("Reconnect", systemImage: "arrow.clockwise") { Task { await shell.start() } }
                            Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { shell.close() }
                        }
                    }
                }
        }
        .onAppear {
            shell.startIfNeeded()
            DispatchQueue.main.async { _ = shell.view.becomeFirstResponder() }
        }
    }
}

private struct TerminalHost: UIViewRepresentable {
    let view: TerminalView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.keyboardLayoutGuide.topAnchor),
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Puts a command into the side shell, for views deep in the transcript.
extension EnvironmentValues {
    @Entry var runInShell: ((String) -> Void)?
}

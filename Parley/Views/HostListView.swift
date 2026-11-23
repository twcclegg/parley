import SwiftUI

struct HostListView: View {
    @Environment(HostStore.self) private var hosts
    @Environment(DeviceKeyStore.self) private var keys
    @Environment(HostKeyPrompter.self) private var prompter
    @Environment(SessionStore.self) private var sessions
    @State private var editing: Host?
    @State private var showingKey = false
    @State private var path: [Host.ID] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(hosts.hosts) { host in
                    NavigationLink(value: host.id) {
                        HostRow(host: host, session: sessions.existing(host.id))
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Task { await sessions.remove(host.id) }
                            hosts.delete(host.id)
                        }
                        Button("Edit", systemImage: "pencil") { editing = host }
                            .tint(.gray)
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editing = host }
                    }
                }
            }
            .overlay {
                if hosts.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("No Servers", systemImage: "server.rack")
                    } description: {
                        Text("Add a server you reach over SSH, then chat with Claude Code running there.")
                    } actions: {
                        Button("Add Server") { editing = Host() }
                            .buttonStyle(.glassProminent)
                    }
                }
            }
            .navigationTitle("Parley")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("This Device's Key", systemImage: "key") { showingKey = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Server", systemImage: "plus") { editing = Host() }
                }
            }
            .navigationDestination(for: Host.ID.self) { id in
                if let host = hosts.host(id) {
                    ChatView(session: sessions.session(for: host, store: hosts, keys: keys, prompter: prompter))
                }
            }
            .sheet(item: $editing) { host in
                HostEditorView(host: host)
            }
            .sheet(isPresented: $showingKey) {
                DeviceKeyView()
            }
        }
    }
}

private struct HostRow: View {
    let host: Host
    let session: ChatSession?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName).font(.headline)
                Text("\(host.username)@\(host.hostname) · \(host.directory)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let session {
                switch session.phase {
                case .connected:
                    Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.green)
                        .accessibilityLabel("Connected")
                case .connecting:
                    ProgressView()
                default:
                    EmptyView()
                }
            }
        }
        .padding(.vertical, 4)
    }
}

import ParleyCore
import SwiftUI

struct ChatView: View {
    @Bindable var session: ChatSession
    @State private var followsEnd = true
    @State private var confirmingNew = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(session.transcript.items) { item in
                        TranscriptItemView(item: item, session: session)
                            .id(item.id)
                    }
                    if showsWorking {
                        WorkingIndicator()
                            .id("working")
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 80
            } action: { _, atEnd in
                followsEnd = atEnd
            }
            .onChange(of: session.transcript.revision) {
                guard followsEnd else { return }
                proxy.scrollTo("end", anchor: .bottom)
            }
            .overlay {
                if session.transcript.items.isEmpty {
                    StartView(session: session)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                ConnectionBanner(session: session)
                if session.phase == .connected {
                    Composer(session: session)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(session.host.displayName).font(.headline)
                    Text(session.host.directory).font(.caption).foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Conversation", systemImage: "ellipsis") {
                    Button("New Conversation", systemImage: "square.and.pencil") { confirmingNew = true }
                    if session.host.lastSessionId != nil {
                        Button("Continue Last Conversation", systemImage: "arrow.uturn.forward") {
                            Task { await session.start(continuing: true) }
                        }
                    }
                    Picker(selection: permissionModeBinding) {
                        ForEach(PermissionMode.allCases) { mode in
                            Text(mode.title).tag(Optional(mode))
                        }
                    } label: {
                        Label("Permissions", systemImage: "hand.raised")
                    }
                    .pickerStyle(.menu)
                    if session.phase == .connected {
                        Button("Disconnect", systemImage: "bolt.horizontal.circle", role: .destructive) {
                            Task { await session.disconnect() }
                        }
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Start a new conversation?", isPresented: $confirmingNew, titleVisibility: .visible) {
            Button("New Conversation") { Task { await session.start(continuing: false) } }
        } message: {
            Text("The current conversation stays on the server; you can continue it later from Claude Code.")
        }
    }

    private var showsWorking: Bool {
        guard session.transcript.isBusy, !session.hasPendingQuestion else { return false }
        // While text is streaming in, the text itself shows that Claude is working.
        if case .assistant(let text) = session.transcript.items.last?.kind, !text.isEmpty { return false }
        return true
    }

    private var permissionModeBinding: Binding<PermissionMode?> {
        Binding(
            get: { PermissionMode(rawValue: session.transcript.permissionMode ?? session.host.permissionMode ?? "") },
            set: { mode in if let mode { Task { await session.setPermissionMode(mode) } } }
        )
    }
}

/// Shown before the first message: start fresh or pick up where you left off.
private struct StartView: View {
    let session: ChatSession

    var body: some View {
        switch session.phase {
        case .idle:
            ContentUnavailableView {
                Label(session.host.displayName, systemImage: "bubble.left.and.text.bubble.right")
            } description: {
                Text("Claude Code runs on the server in \(session.host.directory).")
            } actions: {
                Button("New Conversation") { Task { await session.start(continuing: false) } }
                    .buttonStyle(.glassProminent)
                if session.host.lastSessionId != nil {
                    Button("Continue Last Conversation") { Task { await session.start(continuing: true) } }
                        .buttonStyle(.glass)
                }
            }
        case .connecting:
            ProgressView("Connecting to \(session.host.hostname)…")
        case .connected:
            ContentUnavailableView(
                "Ready",
                systemImage: "sparkles",
                description: Text("Ask Claude to do something in \(session.host.directory).")
            )
        case .ended:
            EmptyView()
        }
    }
}

/// Connection state, when it needs your attention.
private struct ConnectionBanner: View {
    let session: ChatSession

    var body: some View {
        switch session.phase {
        case .connecting where !session.transcript.items.isEmpty:
            HStack(spacing: 8) {
                ProgressView()
                Text("Connecting…")
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect()
        case .ended:
            HStack(spacing: 12) {
                Text("Disconnected").font(.subheadline)
                Button("Reconnect") { Task { await session.start(continuing: session.transcript.sessionId != nil) } }
                    .buttonStyle(.glassProminent)
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .glassEffect()
            .padding(.bottom, 8)
        default:
            EmptyView()
        }
    }
}

private struct WorkingIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Working…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

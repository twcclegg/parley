import ParleyCore
import SwiftUI

/// Where you type: the system keyboard, with its suggestions and dictation.
struct Composer: View {
    @Bindable var session: ChatSession
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if !matchingCommands.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(matchingCommands) { command in
                                Button("/" + command.name) {
                                    session.draft = "/" + command.name + " "
                                }
                                .buttonStyle(.glass)
                                .accessibilityHint(command.description)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            GlassEffectContainer(spacing: 10) {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Message Claude", text: $session.draft, axis: .vertical)
                        .lineLimit(1...8)
                        .focused($focused)
                        .submitLabel(.return)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))

                    if session.transcript.isBusy && session.draft.isEmpty {
                        Button("Stop", systemImage: "stop.fill") {
                            Task { await session.interrupt() }
                        }
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .frame(width: 26, height: 26)
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        .tint(.red)
                    } else {
                        Button("Send", systemImage: "arrow.up") {
                            Task { await session.sendDraft() }
                        }
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .frame(width: 26, height: 26)
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        .disabled(!session.canSend)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    private var matchingCommands: [SlashCommand] {
        let draft = session.draft
        guard draft.hasPrefix("/"), !draft.contains(" ") else { return [] }
        let typed = draft.dropFirst().lowercased()
        return session.transcript.slashCommands
            .filter { typed.isEmpty || $0.name.lowercased().hasPrefix(typed) }
            .prefix(12)
            .map { $0 }
    }
}

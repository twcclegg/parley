import ParleyCore
import SwiftUI

struct TranscriptItemView: View {
    let item: TranscriptItem
    let session: ChatSession

    var body: some View {
        switch item.kind {
        case .user(let text):
            UserBubble(text: text)
        case .assistant(let text):
            if !text.isEmpty { MarkdownText(text: text) }
        case .thinking(let text):
            if !text.isEmpty { ThinkingView(text: text) }
        case .tool(let call):
            ToolCallView(call: call)
        case .permission(let request):
            PermissionCard(request: request, session: session)
        case .question(let request):
            QuestionCard(request: request, session: session)
        case .notice(let text, let isError):
            Text(text)
                .font(.footnote)
                .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
    }
}

private struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.tint.opacity(0.18), in: .rect(cornerRadius: 20))
        }
    }
}

private struct ThinkingView: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                Label("Thinking", systemImage: expanded ? "chevron.down" : "chevron.right")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(.subheadline)
                    .italic()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct ToolCallView: View {
    let call: ToolCall
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(call.name).font(.subheadline.weight(.semibold))
                        if !call.summary.isEmpty {
                            Text(call.summary)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(expanded ? nil : 1)
                        }
                    }
                    Spacer(minLength: 0)
                    status
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if expanded, let result = call.result, !result.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(result.count > 6000 ? String(result.prefix(6000)) + "\n…" : result)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(call.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                        .textSelection(.enabled)
                        .padding(10)
                }
                .background(.background.secondary, in: .rect(cornerRadius: 10))
            }
        }
        .padding(12)
        .background(.fill.quaternary, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var status: some View {
        if call.result == nil {
            ProgressView().controlSize(.small)
        } else if call.isError {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Failed")
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
        }
    }

    private var icon: String {
        switch call.name {
        case "Bash", "BashOutput": "terminal"
        case "Read": "doc.text"
        case "Write": "doc.badge.plus"
        case "Edit", "MultiEdit", "NotebookEdit": "pencil"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Task", "Agent": "person.2"
        case "TodoWrite": "checklist"
        default: "wrench.and.screwdriver"
        }
    }
}

private struct PermissionCard: View {
    let request: PermissionRequest
    let session: ChatSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
            if !request.summary.isEmpty {
                Text(request.summary)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let description = request.description, description != request.summary {
                Text(description).font(.footnote).foregroundStyle(.secondary)
            }
            if request.toolName == "ExitPlanMode", let plan = request.input["plan"]?.string {
                MarkdownText(text: plan)
            }
            switch request.state {
            case .pending:
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button("Deny", role: .destructive) { Task { await session.deny(request) } }
                            .buttonStyle(.glass)
                        if !request.suggestedRules.isEmpty {
                            Button("Always Allow") { Task { await session.allow(request, always: true) } }
                                .buttonStyle(.glass)
                        }
                        Button("Allow") { Task { await session.allow(request, always: false) } }
                            .buttonStyle(.glassProminent)
                    }
                }
                .disabled(session.phase != .connected)
            case .allowed:
                outcome("Allowed", "checkmark")
            case .allowedAlways:
                outcome("Always allowed", "checkmark.seal")
            case .denied:
                outcome("Denied", "xmark")
            case .cancelled:
                outcome("No longer needed", "minus.circle")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(request.state == .pending ? .orange.opacity(0.25) : .clear), in: .rect(cornerRadius: 20))
    }

    private var title: String {
        request.toolName == "ExitPlanMode" ? "Claude has a plan" : "Claude wants to use \(request.displayName)"
    }

    private func outcome(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.footnote).foregroundStyle(.secondary)
    }
}

private struct QuestionCard: View {
    let request: QuestionRequest
    let session: ChatSession
    @State private var chosen: [String: Set<String>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(request.questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    if let header = question.header {
                        Text(header.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(question.question).font(.subheadline.weight(.semibold))
                    ForEach(question.options) { option in
                        optionButton(option, in: question)
                    }
                }
            }
            switch request.state {
            case .pending:
                HStack {
                    Button("Skip", role: .cancel) { Task { await session.decline(request) } }
                        .buttonStyle(.glass)
                    Spacer()
                    if needsSubmit {
                        Button("Send Answers") { submit() }
                            .buttonStyle(.glassProminent)
                            .disabled(!allAnswered)
                    }
                }
                .disabled(session.phase != .connected)
            case .answered(let answers):
                Label(answers.isEmpty ? "Answered" : answers.values.sorted().joined(separator: ", "), systemImage: "checkmark")
                    .font(.footnote).foregroundStyle(.secondary)
            case .declined:
                Label("Skipped", systemImage: "xmark").font(.footnote).foregroundStyle(.secondary)
            case .cancelled:
                Label("No longer needed", systemImage: "minus.circle").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(request.state == .pending ? .blue.opacity(0.2) : .clear), in: .rect(cornerRadius: 20))
    }

    private func optionButton(_ option: QuestionRequest.Option, in question: QuestionRequest.Question) -> some View {
        let selected = chosen[question.question, default: []].contains(option.label)
        return Button {
            guard request.state == .pending else { return }
            if question.multiSelect {
                chosen[question.question, default: []].formSymmetricDifference([option.label])
            } else {
                chosen[question.question] = [option.label]
                if !needsSubmit { submit() }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? (question.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle") : (question.multiSelect ? "square" : "circle"))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                    if let description = option.description {
                        Text(description).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(request.state != .pending || session.phase != .connected)
    }

    /// One single-choice question sends as soon as you pick; anything more waits for Send.
    private var needsSubmit: Bool {
        request.questions.count > 1 || request.questions.contains(where: \.multiSelect)
    }

    private var allAnswered: Bool {
        request.questions.allSatisfy { !(chosen[$0.question] ?? []).isEmpty }
    }

    private func submit() {
        var answers: [String: String] = [:]
        for question in request.questions {
            let labels = question.options.map(\.label).filter { chosen[question.question, default: []].contains($0) }
            answers[question.question] = labels.joined(separator: ", ")
        }
        Task { await session.answer(request, with: answers) }
    }
}

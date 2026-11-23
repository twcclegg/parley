import SwiftUI

/// Claude's Markdown: paragraphs with inline styling, headings, and fenced code blocks that
/// scroll sideways instead of wrapping.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let markdown):
                    Text(Self.attributed(markdown))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .heading(let markdown):
                    Text(Self.attributed(markdown))
                        .font(.headline)
                        .textSelection(.enabled)
                case .code(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                    }
                    .background(.fill.quaternary, in: .rect(cornerRadius: 12))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum Block: Equatable {
        case prose(String)
        case heading(String)
        case code(String)
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var prose: [Substring] = []
        var code: [Substring]?

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { blocks.append(.prose(joined)) }
            prose = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flushProse()
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else if trimmed.hasPrefix("#") {
                flushProse()
                blocks.append(.heading(String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.isEmpty {
                flushProse()
            } else {
                prose.append(line)
            }
        }
        // A code block still streaming in shows as code.
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flushProse()
        return blocks
    }

    static func attributed(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(markdown)
    }
}

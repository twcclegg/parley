import ParleyCore
import PhotosUI
import SwiftUI

/// Where you type: the system keyboard, with its suggestions and dictation. Paste or pick
/// images to send them to Claude with the message.
struct Composer: View {
    @Bindable var session: ChatSession
    @State private var pickedPhotos: [PhotosPickerItem] = []

    var body: some View {
        VStack(spacing: 8) {
            if !matchingCommands.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    ParleyGlassGroup(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(matchingCommands) { command in
                                Button("/" + command.name) {
                                    session.draft = "/" + command.name + " "
                                }
                                .buttonStyle(.parleyGlass)
                                .accessibilityHint(command.description)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            if !session.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(session.attachments) { attachment in
                            AttachmentThumbnail(attachment: attachment, size: 64)
                                .overlay(alignment: .topTrailing) {
                                    Button("Remove", systemImage: "xmark.circle.fill") {
                                        session.attachments.removeAll { $0.id == attachment.id }
                                    }
                                    .labelStyle(.iconOnly)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                                    .padding(3)
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            ParleyGlassGroup(spacing: 10) {
                HStack(alignment: .bottom, spacing: 10) {
                    PhotosPicker(selection: $pickedPhotos, maxSelectionCount: 10, matching: .images) {
                        Label("Add Photos", systemImage: "plus")
                            .labelStyle(.iconOnly)
                            .font(.body.weight(.semibold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.parleyGlass)
                    .buttonBorderShape(.circle)

                    ComposerField(text: $session.draft, placeholder: "Message Claude") { images in
                        session.addImages(images)
                    }
                    .parleyGlass(interactive: true, in: .rect(cornerRadius: 22))

                    if session.transcript.isBusy && session.draft.isEmpty && session.attachments.isEmpty {
                        Button("Stop", systemImage: "stop.fill") {
                            Task { await session.interrupt() }
                        }
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .frame(width: 26, height: 26)
                        .buttonStyle(.parleyGlassProminent)
                        .buttonBorderShape(.circle)
                        .tint(.red)
                    } else {
                        Button("Send", systemImage: "arrow.up") {
                            Task { await session.sendDraft() }
                        }
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .frame(width: 26, height: 26)
                        .buttonStyle(.parleyGlassProminent)
                        .buttonBorderShape(.circle)
                        .disabled(!session.canSend)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        session.addImageData(data)
                    }
                }
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

/// A square preview of an image; tap to see it whole.
struct AttachmentThumbnail: View {
    let attachment: ImageAttachment
    var size: CGFloat = 120
    @State private var showsFull = false

    var body: some View {
        if let image = UIImage(data: attachment.data) {
            Button {
                showsFull = true
            } label: {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Image")
            .fullScreenCover(isPresented: $showsFull) {
                ImageViewer(image: image)
            }
        }
    }
}

/// An image filling the screen, to zoom into and share.
private struct ImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width * zoom)
                        .frame(minHeight: geometry.size.height)
                }
                .defaultScrollAnchor(.center)
            }
            .gesture(MagnifyGesture().onChanged { value in zoom = min(max(value.magnification, 1), 6) })
            .background(.black)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("Image", image: Image(uiImage: image)))
                }
            }
        }
    }
}

import SwiftUI
import UIKit

/// The message field: the system text view, so you get the keyboard's suggestions, dictation
/// and Paste — and Paste also takes images, which a SwiftUI TextField can't.
struct ComposerField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var maxLines = 8
    var onPasteImages: ([UIImage]) -> Void

    func makeUIView(context: Context) -> PastingTextView {
        let view = PastingTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 11, left: 16, bottom: 11, right: 16)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityLabel = placeholder
        view.placeholder.text = placeholder
        return view
    }

    func updateUIView(_ view: PastingTextView, context: Context) {
        context.coordinator.parent = self
        view.onPasteImages = onPasteImages
        // Leave text alone mid-composition, such as while dictating or typing with a pinyin keyboard.
        if view.text != text, view.markedTextRange == nil {
            view.text = text
        }
        view.placeholder.isHidden = !text.isEmpty
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: PastingTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        let fitting = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = view.font?.lineHeight ?? 20
        let limit = lineHeight * CGFloat(maxLines) + view.textContainerInset.top + view.textContainerInset.bottom
        let scrolls = fitting.height > limit
        if view.isScrollEnabled != scrolls {
            DispatchQueue.main.async { view.isScrollEnabled = scrolls }
        }
        return CGSize(width: width, height: min(fitting.height, limit))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerField

        init(_ parent: ComposerField) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            (view as? PastingTextView)?.placeholder.isHidden = !view.text.isEmpty
            view.invalidateIntrinsicContentSize()
        }
    }
}

final class PastingTextView: UITextView {
    var onPasteImages: (([UIImage]) -> Void)?
    let placeholder = UILabel()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.isAccessibilityElement = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            placeholder.topAnchor.constraint(equalTo: topAnchor, constant: 11),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasImages, let images = pasteboard.images, !images.isEmpty {
            onPasteImages?(images)
            // Text copied along with the image, such as a caption, still pastes.
            if pasteboard.hasStrings, let string = pasteboard.string, !string.isEmpty {
                insertText(string)
            }
            return
        }
        super.paste(sender)
    }
}

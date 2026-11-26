import Foundation

/// An image sent to Claude inside a message, or shown from one.
public struct ImageAttachment: Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    /// `image/jpeg`, `image/png`, `image/gif` or `image/webp`: the types Claude accepts.
    public let mediaType: String
    public let data: Data

    public init(id: UUID = UUID(), mediaType: String, data: Data) {
        self.id = id
        self.mediaType = mediaType
        self.data = data
    }

    /// The Messages API content block for this image.
    public var contentBlock: JSON {
        [
            "type": "image",
            "source": ["type": "base64", "media_type": .string(mediaType), "data": .string(data.base64EncodedString())],
        ]
    }

    /// Reads an image content block, as Claude Code echoes it or returns it from a tool.
    public init?(contentBlock block: JSON) {
        guard block["type"]?.string == "image",
            let source = block["source"],
            source["type"]?.string == "base64",
            let encoded = source["data"]?.string,
            let data = Data(base64Encoded: encoded)
        else { return nil }
        self.init(mediaType: source["media_type"]?.string ?? "image/png", data: data)
    }

    /// The images among a list of content blocks.
    public static func all(in content: JSON?) -> [ImageAttachment] {
        content?.array?.compactMap(ImageAttachment.init(contentBlock:)) ?? []
    }
}

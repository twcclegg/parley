import ParleyCore
import UIKit

/// Turns a picture from the clipboard or the photo library into something Claude accepts:
/// at most 1568 pixels on the long side (larger gains nothing) and under the 5 MB limit once
/// encoded. Screenshots stay PNG so text stays sharp; photos become JPEG.
enum ImagePreparation {
    static let maxDimension: CGFloat = 1568
    /// 5 MB of base64 is 3.75 MB of image.
    static let maxBytes = 3_750_000

    static func attachment(from image: UIImage, preferPNG: Bool = false) -> ImageAttachment? {
        let scaled = downscaled(image)
        if preferPNG || hasAlpha(scaled), let png = scaled.pngData(), png.count <= maxBytes {
            return ImageAttachment(mediaType: "image/png", data: png)
        }
        for quality in [0.85, 0.7, 0.5, 0.3] {
            if let jpeg = scaled.jpegData(compressionQuality: quality), jpeg.count <= maxBytes {
                return ImageAttachment(mediaType: "image/jpeg", data: jpeg)
            }
        }
        return nil
    }

    /// Data from the photo library or a file: kept as it is when Claude accepts it already.
    static func attachment(from data: Data) -> ImageAttachment? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size.applying(.init(scaleX: image.scale, y: image.scale))
        if max(size.width, size.height) <= maxDimension, data.count <= maxBytes, let type = mediaType(of: data) {
            return ImageAttachment(mediaType: type, data: data)
        }
        return attachment(from: image, preferPNG: mediaType(of: data) == "image/png")
    }

    private static func downscaled(_ image: UIImage) -> UIImage {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longest = max(pixels.width, pixels.height)
        let factor = longest > maxDimension ? maxDimension / longest : 1
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !hasAlpha(image)
        let size = CGSize(width: (pixels.width * factor).rounded(), height: (pixels.height * factor).rounded())
        // Drawing also applies the photo's orientation, which Claude would otherwise ignore.
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func hasAlpha(_ image: UIImage) -> Bool {
        switch image.cgImage?.alphaInfo {
        case .first?, .last?, .premultipliedFirst?, .premultipliedLast?: true
        default: false
        }
    }

    private static func mediaType(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if bytes.count >= 12, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46], bytes[8..<12] == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        return nil
    }
}

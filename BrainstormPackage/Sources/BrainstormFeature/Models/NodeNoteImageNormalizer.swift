import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decodes imported images, strips metadata, bounds dimensions, and emits a single PNG frame.
public enum NodeNoteImageNormalizer {
    public static let maxInputBytes = 50_000_000

    public static func normalize(
        _ inputData: Data,
        altText: String,
        caption: String? = nil,
        id: UUID = UUID(),
        path: String = "$.image"
    ) throws -> NoteImageAttachment {
        guard !inputData.isEmpty, inputData.count <= maxInputBytes,
              let source = CGImageSourceCreateWithData(inputData as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else {
            throw NodeNoteValidationError(
                code: .invalidImage,
                path: path,
                message: "The selected file is not a supported image."
            )
        }

        let sourceDimensions = dimensions(of: source)
        guard sourceDimensions.width > 0, sourceDimensions.height > 0 else {
            throw NodeNoteValidationError(
                code: .invalidImage,
                path: path,
                message: "The selected image has invalid dimensions."
            )
        }

        var targetLongEdge = boundedLongEdge(
            width: sourceDimensions.width,
            height: sourceDimensions.height
        )
        var lastResult: (data: Data, width: Int, height: Int)?

        // PNG size is content-dependent. Reduce dimensions until the normalized
        // payload fits instead of accepting an unexpectedly huge lossless image.
        for _ in 0..<8 {
            guard let image = thumbnail(from: source, maxPixelSize: targetLongEdge),
                  let png = encodePNG(image)
            else {
                throw NodeNoteValidationError(
                    code: .invalidImage,
                    path: path,
                    message: "The selected image could not be normalized."
                )
            }
            lastResult = (png, image.width, image.height)
            if png.count <= NodeNoteValidator.maxImageBytes {
                let attachment = NoteImageAttachment(
                    id: id,
                    pngBase64: png.base64EncodedString(),
                    pixelWidth: image.width,
                    pixelHeight: image.height,
                    altText: altText,
                    caption: caption
                ).canonicalized()
                try NodeNoteValidator.validate(
                    attachment: .image(attachment),
                    path: path
                )
                return attachment
            }
            targetLongEdge = max(64, Int(Double(targetLongEdge) * 0.78))
        }

        let byteCount = lastResult?.data.count ?? inputData.count
        throw NodeNoteValidationError(
            code: .imageTooLarge,
            path: path,
            message: "Normalized PNG is \(byteCount) bytes and exceeds the \(NodeNoteValidator.maxImageBytes)-byte limit."
        )
    }

    /// Confirms persisted bytes are actually a PNG and dimensions match the envelope.
    public static func validateNormalizedPNG(
        _ data: Data,
        width: Int,
        height: Int,
        path: String = "$.image"
    ) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              (CGImageSourceGetType(source) as String?) == UTType.png.identifier
        else {
            throw NodeNoteValidationError(
                code: .invalidImage,
                path: "\(path).pngBase64",
                message: "Embedded image bytes must contain one normalized PNG frame."
            )
        }
        let actual = dimensions(of: source)
        guard actual.width == width, actual.height == height else {
            throw NodeNoteValidationError(
                code: .imageDimensions,
                path: path,
                message: "Stored image dimensions do not match the embedded PNG."
            )
        }
    }

    private static func dimensions(of source: CGImageSource) -> (width: Int, height: Int) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
              let width = integerValue(properties[kCGImagePropertyPixelWidth]),
              let height = integerValue(properties[kCGImagePropertyPixelHeight])
        else {
            return (0, 0)
        }
        return (width, height)
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let value = value as? Int {
            return value
        }
        return nil
    }

    private static func boundedLongEdge(width: Int, height: Int) -> Int {
        let longEdge = max(width, height)
        let sourcePixels = max(1, Double(width) * Double(height))
        let pixelScale = sqrt(
            Double(NodeNoteValidator.maxImagePixels) / sourcePixels
        )
        let pixelBound = Int(floor(Double(longEdge) * min(1, pixelScale)))
        return max(1, min(NodeNoteValidator.maxImageLongEdge, pixelBound))
    }

    private static func thumbnail(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

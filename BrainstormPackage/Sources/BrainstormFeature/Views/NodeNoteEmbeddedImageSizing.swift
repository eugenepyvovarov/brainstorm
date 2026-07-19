import CoreGraphics

/// Shared display bounds for inline note images in the native WYSIWYG editor.
enum NodeNoteEmbeddedImageSizing {
    static let maximumSize = CGSize(width: 320, height: 220)

    static func displaySize(for source: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else {
            return .zero
        }
        let scale = min(
            1,
            min(
                maximumSize.width / source.width,
                maximumSize.height / source.height
            )
        )
        return CGSize(
            width: source.width * scale,
            height: source.height * scale
        )
    }
}

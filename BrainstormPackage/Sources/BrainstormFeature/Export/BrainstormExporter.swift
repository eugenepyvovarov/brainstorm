import AppKit
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

public enum BrainstormExportFormat: String, CaseIterable, Sendable {
    case png
    case pdf

    public var contentType: UTType {
        switch self {
        case .png: .png
        case .pdf: .pdf
        }
    }

    public var fileExtension: String { rawValue }

    public var menuTitle: String {
        switch self {
        case .png: "PNG Image…"
        case .pdf: "PDF Document…"
        }
    }
}

public enum BrainstormExportError: LocalizedError {
    case invalidCanvasSize
    case imageRenderingFailed
    case pngEncodingFailed
    case pdfContextCreationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidCanvasSize:
            "The mind map has no drawable canvas."
        case .imageRenderingFailed:
            "The mind map image could not be rendered."
        case .pngEncodingFailed:
            "The rendered image could not be encoded as PNG."
        case .pdfContextCreationFailed:
            "The PDF document could not be created."
        }
    }
}

/// Renders the complete laid-out map, independent of viewport pan and zoom.
@MainActor
public enum BrainstormExporter {
    private static let preferredPNGScale: CGFloat = 2
    private static let maximumPNGDimension: CGFloat = 16_384
    private static let maximumPNGPixelCount: CGFloat = 64_000_000
    private static let maximumPDFDimension: CGFloat = 14_400

    public static func data(
        root: BrainstormNode,
        theme: AppTheme,
        colorScheme: ColorScheme,
        format: BrainstormExportFormat
    ) throws -> Data {
        let layout = LayoutEngine().layout(root: root)
        guard layout.contentSize.width > 0, layout.contentSize.height > 0 else {
            throw BrainstormExportError.invalidCanvasSize
        }

        let surface = BrainstormExportSurface(
            rootID: root.id,
            layout: layout,
            theme: theme,
            colorScheme: colorScheme
        )
        switch format {
        case .png:
            return try pngData(surface: surface, canvasSize: layout.contentSize)
        case .pdf:
            return try pdfData(surface: surface, canvasSize: layout.contentSize)
        }
    }

    public static func write(
        root: BrainstormNode,
        theme: AppTheme,
        colorScheme: ColorScheme,
        format: BrainstormExportFormat,
        to url: URL
    ) throws {
        let exportData = try data(
            root: root,
            theme: theme,
            colorScheme: colorScheme,
            format: format
        )
        try exportData.write(to: url, options: .atomic)
    }

    private static func pngData(
        surface: BrainstormExportSurface,
        canvasSize: CGSize
    ) throws -> Data {
        let dimensionScale = min(
            maximumPNGDimension / canvasSize.width,
            maximumPNGDimension / canvasSize.height
        )
        let areaScale = sqrt(
            maximumPNGPixelCount / max(1, canvasSize.width * canvasSize.height)
        )
        let scale = max(0.01, min(preferredPNGScale, dimensionScale, areaScale))

        let renderer = ImageRenderer(content: surface)
        renderer.proposedSize = ProposedViewSize(canvasSize)
        renderer.scale = scale
        renderer.isOpaque = true

        guard let cgImage = renderer.cgImage else {
            throw BrainstormExportError.imageRenderingFailed
        }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw BrainstormExportError.pngEncodingFailed
        }
        return data
    }

    private static func pdfData(
        surface: BrainstormExportSurface,
        canvasSize: CGSize
    ) throws -> Data {
        let pageScale = min(
            1,
            maximumPDFDimension / max(canvasSize.width, canvasSize.height)
        )
        let pageSize = CGSize(
            width: canvasSize.width * pageScale,
            height: canvasSize.height * pageScale
        )
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw BrainstormExportError.pdfContextCreationFailed
        }

        let renderer = ImageRenderer(content: surface)
        renderer.proposedSize = ProposedViewSize(canvasSize)
        renderer.scale = 1

        context.beginPDFPage(nil)
        context.saveGState()
        context.scaleBy(x: pageScale, y: pageScale)
        renderer.render { _, render in
            render(context)
        }
        context.restoreGState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

/// Non-interactive view shared by PNG and PDF export so both formats match.
private struct BrainstormExportSurface: View {
    let rootID: UUID
    let layout: LayoutResult
    let theme: AppTheme
    let colorScheme: ColorScheme
    @FocusState private var focusedNodeID: UUID?

    var body: some View {
        ZStack(alignment: .topLeading) {
            CanvasBackgroundFill(theme: theme)
                .frame(width: layout.contentSize.width, height: layout.contentSize.height)

            EdgeCanvas(edges: layout.edges, theme: theme, canvasSize: layout.contentSize)
                .frame(width: layout.contentSize.width, height: layout.contentSize.height)

            ForEach(layout.nodes) { node in
                BrainstormNodeView(
                    layoutNode: node,
                    isRoot: node.id == rootID,
                    isSelected: false,
                    isEditing: false,
                    isDropTarget: false,
                    isSearchMatch: false,
                    isDimmed: false,
                    isFreeDragging: false,
                    isExporting: true,
                    editSeed: nil,
                    editSelectAll: true,
                    focusToken: $focusedNodeID,
                    onSelect: {},
                    onBeginEdit: {},
                    onCommitEdit: {},
                    onCancelEdit: {},
                    onDraftChange: { _ in },
                    onLiveTitle: { _ in },
                    onToggleExpand: {},
                    onAddChild: {},
                    onDelete: {},
                    onDeleteSingle: {},
                    onDeleteEmptyWhileEditing: {},
                    onFreeDragChanged: { _, _ in },
                    onFreeDragEnded: { _, _ in },
                    onResetPosition: {}
                )
                .position(x: node.frame.midX, y: node.frame.midY)
            }
        }
        .frame(width: layout.contentSize.width, height: layout.contentSize.height)
        .clipped()
        .environment(\.brainstormTheme, theme)
        .environment(\.colorScheme, colorScheme)
    }
}

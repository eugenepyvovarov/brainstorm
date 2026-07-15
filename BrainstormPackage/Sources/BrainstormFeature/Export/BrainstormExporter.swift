import AppKit
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

public enum BrainstormExportFormat: String, CaseIterable, Sendable {
    case png
    case pdf
    case markdown
    case mermaid
    case plantuml

    public var contentType: UTType {
        switch self {
        case .png: .png
        case .pdf: .pdf
        case .markdown, .mermaid, .plantuml:
            UTType(filenameExtension: fileExtension, conformingTo: .plainText) ?? .plainText
        }
    }

    public var fileExtension: String {
        switch self {
        case .png, .pdf: rawValue
        case .markdown: "md"
        case .mermaid: "mmd"
        case .plantuml: "puml"
        }
    }

    public var menuTitle: String {
        switch self {
        case .png: "PNG Image…"
        case .pdf: "PDF Document…"
        case .markdown: "Markdown Outline…"
        case .mermaid: "Mermaid Mindmap…"
        case .plantuml: "PlantUML Mindmap…"
        }
    }

    public var displayName: String {
        switch self {
        case .png: "PNG"
        case .pdf: "PDF"
        case .markdown: "Markdown"
        case .mermaid: "Mermaid"
        case .plantuml: "PlantUML"
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
        switch format {
        case .markdown, .mermaid, .plantuml:
            return Data(BrainstormTextExporter.string(root: root, format: format).utf8)
        case .png, .pdf:
            break
        }

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
        case .markdown, .mermaid, .plantuml:
            preconditionFailure("Text exports return before canvas layout")
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

/// Deterministic, complete-tree text exports shared by the app and CLI.
public enum BrainstormTextExporter {
    public static func string(root: BrainstormNode, format: BrainstormExportFormat) -> String {
        switch format {
        case .markdown:
            markdown(root: root)
        case .mermaid:
            mermaid(root: root)
        case .plantuml:
            plantUML(root: root)
        case .png, .pdf:
            preconditionFailure("Raster formats are rendered by BrainstormExporter")
        }
    }

    private static func markdown(root: BrainstormNode) -> String {
        let heading = markdownInline(root.title, multilineSeparator: "<br>")
        var lines = ["# \(heading)", ""]
        appendMarkdownNode(root, depth: 0, to: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendMarkdownNode(
        _ node: BrainstormNode,
        depth: Int,
        to lines: inout [String]
    ) {
        let title = markdownInline(node.title, multilineSeparator: "<br>")
        lines.append(String(repeating: "    ", count: depth) + "- " + title)
        for child in node.children {
            appendMarkdownNode(child, depth: depth + 1, to: &lines)
        }
    }

    private static func markdownInline(_ value: String, multilineSeparator: String) -> String {
        let parts = normalizedLines(value).map { line in
            line
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "*", with: "\\*")
                .replacingOccurrences(of: "_", with: "\\_")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        return parts.joined(separator: multilineSeparator)
    }

    private static func mermaid(root: BrainstormNode) -> String {
        var lines = ["mindmap"]
        var nextID = 0
        appendMermaidNode(root, depth: 1, nextID: &nextID, to: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendMermaidNode(
        _ node: BrainstormNode,
        depth: Int,
        nextID: inout Int,
        to lines: inout [String]
    ) {
        let id = nextID
        nextID += 1
        lines.append(
            String(repeating: "  ", count: depth) + "n\(id)[\"\(mermaidLabel(node.title))\"]"
        )
        for child in node.children {
            appendMermaidNode(child, depth: depth + 1, nextID: &nextID, to: &lines)
        }
    }

    private static func mermaidLabel(_ value: String) -> String {
        normalizedLines(value)
            .map {
                $0.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "\"", with: "&quot;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
            }
            .joined(separator: "<br/>")
    }

    private static func plantUML(root: BrainstormNode) -> String {
        var lines = ["@startmindmap"]
        appendPlantUMLNode(root, depth: 1, to: &lines)
        lines.append("@endmindmap")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendPlantUMLNode(
        _ node: BrainstormNode,
        depth: Int,
        to lines: inout [String]
    ) {
        lines.append(String(repeating: "*", count: depth) + " " + plantUMLLabel(node.title))
        for child in node.children {
            appendPlantUMLNode(child, depth: depth + 1, to: &lines)
        }
    }

    private static func plantUMLLabel(_ value: String) -> String {
        normalizedLines(value)
            .map {
                $0.replacingOccurrences(of: "~", with: "~~")
                    .replacingOccurrences(of: "<", with: "~<")
                    .replacingOccurrences(of: ">", with: "~>")
            }
            .joined(separator: "\\n")
    }

    private static func normalizedLines(_ value: String) -> [String] {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
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

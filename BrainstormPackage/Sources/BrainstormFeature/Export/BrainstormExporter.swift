import AppKit
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

public enum BrainstormExportFormat: String, CaseIterable, Sendable {
    case png
    case pdf
    case html
    case markdown
    case mermaid
    case plantuml

    public var contentType: UTType {
        switch self {
        case .png: .png
        case .pdf: .pdf
        case .html: .html
        case .markdown, .mermaid, .plantuml:
            UTType(filenameExtension: fileExtension, conformingTo: .plainText) ?? .plainText
        }
    }

    public var fileExtension: String {
        switch self {
        case .png, .pdf, .html: rawValue
        case .markdown: "md"
        case .mermaid: "mmd"
        case .plantuml: "puml"
        }
    }

    public var menuTitle: String {
        switch self {
        case .png: "PNG Image"
        case .pdf: "PDF Document"
        case .html: "HTML Viewer"
        case .markdown: "Markdown Outline"
        case .mermaid: "Mermaid Mindmap"
        case .plantuml: "PlantUML Mindmap"
        }
    }

    public static var menuCases: [Self] {
        allCases.sorted { $0.menuTitle.lowercased() < $1.menuTitle.lowercased() }
    }

    public var displayName: String {
        switch self {
        case .png: "PNG"
        case .pdf: "PDF"
        case .html: "HTML"
        case .markdown: "Markdown"
        case .mermaid: "Mermaid"
        case .plantuml: "PlantUML"
        }
    }
}

/// Controls which note payloads are included in an export.
///
/// Hidden notes are not private. Use ``none`` when the exported bytes must not
/// contain note text or attachments.
public enum BrainstormNoteInclusion: String, CaseIterable, Codable, Sendable {
    /// Include notes whose saved visibility is shown.
    case visible
    /// Include every non-empty note, regardless of saved visibility.
    case all
    /// Omit note text and attachments entirely.
    case none
}

/// The scene shown when a self-contained HTML export first opens.
public enum BrainstormHTMLInitialMode: String, CaseIterable, Codable, Sendable {
    case map
    case presentation
}

/// Format-independent options shared by app and CLI exports.
public struct BrainstormExportOptions: Equatable, Sendable {
    public var noteInclusion: BrainstormNoteInclusion
    public var htmlInitialMode: BrainstormHTMLInitialMode

    public init(
        noteInclusion: BrainstormNoteInclusion = .visible,
        htmlInitialMode: BrainstormHTMLInitialMode = .map
    ) {
        self.noteInclusion = noteInclusion
        self.htmlInitialMode = htmlInitialMode
    }

    public static let `default` = BrainstormExportOptions()

    /// HTML always embeds notes for an in-viewer toggle; launch on the map.
    public static let htmlDefault = BrainstormExportOptions(
        noteInclusion: .all,
        htmlInitialMode: .map
    )
}

public struct BrainstormExportDescriptor: Equatable, Sendable {
    public let fileExtension: String
    public let contentType: UTType
    public let isArchive: Bool

    public init(
        fileExtension: String,
        contentType: UTType,
        isArchive: Bool
    ) {
        self.fileExtension = fileExtension
        self.contentType = contentType
        self.isArchive = isArchive
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

    /// Suggested export basename: spaces become underscores and special
    /// characters are removed so HTML downloads stay portable across hosts.
    public static func sanitizedExportBaseName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled" }

        var result = ""
        result.reserveCapacity(trimmed.count)
        var previousWasSeparator = false
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !previousWasSeparator && !result.isEmpty {
                    result.append("_")
                    previousWasSeparator = true
                }
                continue
            }
            if CharacterSet.alphanumerics.contains(scalar)
                || scalar == "_"
                || scalar == "-"
            {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = scalar == "_" || scalar == "-"
                continue
            }
            // Drop punctuation and other specials without introducing separators.
        }

        while result.hasPrefix("_") || result.hasPrefix("-") {
            result.removeFirst()
        }
        while result.hasSuffix("_") || result.hasSuffix("-") {
            result.removeLast()
        }
        return result.isEmpty ? "Untitled" : result
    }

    public static func descriptor(
        root: BrainstormNode,
        format: BrainstormExportFormat,
        options: BrainstormExportOptions = .default
    ) -> BrainstormExportDescriptor {
        if format == .markdown,
           BrainstormMarkdownBundle.includedNoteCount(
               root: root,
               inclusion: options.noteInclusion
           ) > 0
        {
            return BrainstormExportDescriptor(
                fileExtension: "zip",
                contentType: .zip,
                isArchive: true
            )
        }
        return BrainstormExportDescriptor(
            fileExtension: format.fileExtension,
            contentType: format.contentType,
            isArchive: false
        )
    }

    public static func data(
        root: BrainstormNode,
        theme: AppTheme,
        colorScheme: ColorScheme,
        format: BrainstormExportFormat,
        options: BrainstormExportOptions = .default
    ) throws -> Data {
        switch format {
        case .markdown:
            let bundle = try BrainstormMarkdownBundle.make(
                root: root,
                inclusion: options.noteInclusion
            )
            if bundle.isArchive {
                return try BrainstormZIPArchive.data(entries: bundle.entries)
            }
            return Data(bundle.indexMarkdown.utf8)
        case .mermaid, .plantuml:
            return Data(
                BrainstormTextExporter.string(
                    root: root,
                    format: format,
                    options: options
                ).utf8
            )
        case .png, .pdf, .html:
            break
        }

        // Notes are an interactive/document layer. Raster and PDF exports are
        // intentionally the clean mind map only; HTML and Markdown provide the
        // note-aware export experiences.
        //
        // Folded branches are a live-canvas concern only. Every visual export
        // lays out the complete stored tree so PNG/PDF/HTML always include
        // descendants that remain collapsed in the `.bs` document.
        // HTML always embeds every non-empty note so the viewer can toggle
        // note steps live; the in-page Notes checkbox starts unchecked.
        let resolvedOptions = format == .html
            ? BrainstormExportOptions(
                noteInclusion: .all,
                htmlInitialMode: options.htmlInitialMode
            )
            : options
        let layoutNoteInclusion = layoutNoteInclusion(for: format)
        let layout = LayoutEngine().layout(
            root: root,
            noteInclusion: layoutNoteInclusion,
            placementPolicy: .allDescendants
        )
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
        case .html:
            return BrainstormHTMLRenderer.data(
                layout: layout,
                rootID: root.id,
                theme: theme,
                colorScheme: colorScheme,
                mapTitle: root.title,
                root: root,
                options: resolvedOptions
            )
        case .markdown, .mermaid, .plantuml:
            preconditionFailure("Text exports return before canvas layout")
        }
    }

    static func layoutNoteInclusion(
        for format: BrainstormExportFormat
    ) -> BrainstormNoteInclusion {
        switch format {
        case .png, .pdf, .html, .markdown, .mermaid, .plantuml:
            .none
        }
    }

    public static func write(
        root: BrainstormNode,
        theme: AppTheme,
        colorScheme: ColorScheme,
        format: BrainstormExportFormat,
        to url: URL,
        options: BrainstormExportOptions = .default
    ) throws {
        let exportData = try data(
            root: root,
            theme: theme,
            colorScheme: colorScheme,
            format: format,
            options: options
        )
        try exportData.write(to: url, options: .atomic)
    }

    /// Label-order convenience for callers that construct options before the destination.
    public static func write(
        root: BrainstormNode,
        theme: AppTheme,
        colorScheme: ColorScheme,
        format: BrainstormExportFormat,
        options: BrainstormExportOptions,
        to url: URL
    ) throws {
        try write(
            root: root,
            theme: theme,
            colorScheme: colorScheme,
            format: format,
            to: url,
            options: options
        )
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
///
/// For Markdown with included notes, this returns the `map.md` index text.
/// Use ``BrainstormExporter`` to receive the complete ZIP bundle containing
/// linked note documents and assets.
public enum BrainstormTextExporter {
    public static func string(
        root: BrainstormNode,
        format: BrainstormExportFormat,
        options: BrainstormExportOptions = .default
    ) -> String {
        switch format {
        case .markdown:
            BrainstormMarkdownBundle.indexMarkdown(
                root: root,
                inclusion: options.noteInclusion
            )
        case .mermaid:
            mermaid(root: root)
        case .plantuml:
            plantUML(root: root)
        case .png, .pdf, .html:
            preconditionFailure("Visual formats are rendered by BrainstormExporter")
        }
    }

    static func markdownInline(_ value: String, multilineSeparator: String) -> String {
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

    static func normalizedLines(_ value: String) -> [String] {
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
                    hasNote: false,
                    showNoteAction: false,
                    showNoteIndicator: false,
                    editSeed: nil,
                    editSelectAll: true,
                    noteFocusNamespace: nil,
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
                    onResetPosition: {},
                    onOpenNote: {}
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

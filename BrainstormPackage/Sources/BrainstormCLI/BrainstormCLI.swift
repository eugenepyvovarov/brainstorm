import Darwin
import Foundation
import BrainstormFeature
import SwiftUI

@main
@MainActor
struct BrainstormCLI {
    static func main() {
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.isEmpty || arguments.first == "help" || arguments.first == "--help" {
                printHelp()
                return
            }
            let command = arguments.removeFirst()
            let options = try CLIOptions(arguments)
            let response = try run(command: command, options: options)
            if command != "export" || options.value("output") != "-" {
                try writeJSON(response, pretty: options.hasFlag("pretty"), to: .standardOutput)
            }
        } catch {
            let failure = CLIErrorResponse(
                ok: false,
                error: CLIErrorPayload(
                    type: String(describing: type(of: error)),
                    message: error.localizedDescription
                )
            )
            try? writeJSON(failure, pretty: true, to: .standardError)
            Darwin.exit(1)
        }
    }

    private static func run(command: String, options: CLIOptions) throws -> CLIResponse {
        switch command {
        case "themes": return try themes(options)
        case "create": return try create(options)
        case "inspect": return try inspect(options)
        case "add": return try add(options)
        case "update": return try update(options)
        case "style": return try style(options)
        case "move": return try move(options)
        case "delete": return try delete(options)
        case "export": return try export(options)
        case "validate": return try validate(options)
        case "apply": return try apply(options)
        default: throw CLIUsageError("Unknown command '\(command)'. Run 'brainstorm help'.")
        }
    }

    private static func themes(_ options: CLIOptions) throws -> CLIResponse {
        try options.allowing(["pretty"])
        guard options.positionals.count <= 1 else {
            throw CLIUsageError("Usage: brainstorm themes [theme-id] [--pretty]")
        }
        if let themeID = options.positionals.first {
            guard let theme = AppTheme.all.first(where: { $0.id == themeID }) else {
                throw CLIUsageError("Unknown theme '\(themeID)'.")
            }
            return CLIResponse(command: "themes", changed: false, theme: theme)
        }
        return CLIResponse(command: "themes", changed: false, themes: AppTheme.all)
    }

    private static func create(_ options: CLIOptions) throws -> CLIResponse {
        try options.allowing(["title", "theme", "root-id", "force", "dry-run", "pretty"])
        let url = try documentURL(options)
        if FileManager.default.fileExists(atPath: url.path), !options.hasFlag("force") {
            throw CLIUsageError("File already exists. Pass --force to replace it: \(url.path)")
        }
        let themeID = options.value("theme") ?? AppTheme.system.id
        guard AppTheme.all.contains(where: { $0.id == themeID }) else {
            throw CLIUsageError("Unknown theme '\(themeID)'.")
        }
        let rootID = try options.value("root-id").map(parseUUID) ?? UUID()
        let title = BrainstormDocumentEditor.normalizedTitle(options.value("title") ?? "Main Idea")
        let file = BrainstormFile(root: BrainstormNode(id: rootID, title: title), themeID: themeID)
        try BrainstormDocumentEditor.validate(file)
        let dryRun = options.hasFlag("dry-run")
        if !dryRun { try BrainstormCodec.save(file, to: url) }
        return CLIResponse(
            command: "create", file: url.path, changed: true, dryRun: dryRun,
            document: file, node: file.root
        )
    }

    private static func inspect(_ options: CLIOptions) throws -> CLIResponse {
        try options.allowing(["flat", "pretty"])
        let url = try documentURL(options)
        let file = try loadValidated(url)
        return CLIResponse(
            command: "inspect", file: url.path, changed: false,
            document: file,
            nodes: options.hasFlag("flat") ? flattenedNodes(file.root) : nil
        )
    }

    private static func add(_ options: CLIOptions) throws -> CLIResponse {
        try options.allowing(["parent", "id", "title", "index", "dry-run", "pretty"])
        let url = try documentURL(options)
        var file = try loadValidated(url)
        let parentID = try nodeReference(options.required("parent"), in: file)
        let id = try options.value("id").map(parseUUID) ?? UUID()
        let index = try options.value("index").map(parseInt)
        let node = try BrainstormDocumentEditor.addNode(
            to: &file,
            parentID: parentID,
            id: id,
            title: options.required("title"),
            index: index
        )
        return try finishMutation("add", url: url, file: file, node: node, options: options)
    }

    private static func update(_ options: CLIOptions) throws -> CLIResponse {
        try options.allowing([
            "node", "title", "expanded", "emoji", "sticker", "image", "offset-x", "offset-y",
            "note-text", "note-file", "note-visible", "note-image", "note-image-alt",
            "note-image-caption", "note-youtube", "note-youtube-caption", "note-remove",
            "note-move", "note-index", "note-clear", "dry-run", "pretty",
        ])
        let url = try documentURL(options)
        var file = try loadValidated(url)
        let id = try nodeReference(options.required("node"), in: file)
        guard options.hasAnyValue([
            "title", "expanded", "emoji", "sticker", "image", "offset-x", "offset-y",
            "note-text", "note-file", "note-visible", "note-image", "note-youtube",
            "note-remove", "note-move", "note-index",
        ]) || options.hasFlag("note-clear") else {
            throw CLIUsageError("update requires at least one field to change.")
        }
        if options.value("note-text") != nil, options.value("note-file") != nil {
            throw CLIUsageError("Use only one of --note-text or --note-file.")
        }
        if options.value("note-index") != nil, options.value("note-move") == nil {
            throw CLIUsageError("--note-index requires --note-move <attachment-uuid>.")
        }

        let title = options.value("title")
        let expanded = try options.value("expanded").map(parseBool)
        let emoji = options.value("emoji")
        let sticker = options.value("sticker")
        let image = options.value("image")
        let imageBase64: String?
        if let image, !isNone(image) {
            let imageURL = URL(fileURLWithPath: image)
            do {
                imageBase64 = try Data(contentsOf: imageURL).base64EncodedString()
            } catch {
                throw CLIUsageError("Could not read image '\(imageURL.path)': \(error.localizedDescription)")
            }
        } else {
            imageBase64 = nil
        }
        let offsetX = try optionalNumber(options.value("offset-x"))
        let offsetY = try optionalNumber(options.value("offset-y"))
        let noteBody = try noteBodyValue(options)
        let noteVisibility = try options.value("note-visible").map(parseNoteVisibility)
        let noteImage: NoteImageAttachment?
        if let path = options.value("note-image") {
            guard let altText = options.value("note-image-alt"),
                  !altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw CLIUsageError("--note-image requires non-empty --note-image-alt text.")
            }
            let imageURL = URL(fileURLWithPath: path).standardizedFileURL
            let data: Data
            do {
                data = try Data(contentsOf: imageURL)
            } catch {
                throw CLIUsageError(
                    "Could not read note image '\(imageURL.path)': \(error.localizedDescription)"
                )
            }
            noteImage = try NodeNoteImageNormalizer.normalize(
                data,
                altText: altText,
                caption: options.value("note-image-caption"),
                path: "$.root.note.attachments"
            )
        } else {
            noteImage = nil
        }
        let noteYouTube: NoteYouTubeAttachment?
        if let reference = options.value("note-youtube") {
            let parsed = try YouTubeReferenceParser.parse(reference)
            noteYouTube = NoteYouTubeAttachment(
                videoID: parsed.videoID,
                startSeconds: parsed.startSeconds,
                caption: options.value("note-youtube-caption")
            )
        } else {
            noteYouTube = nil
        }
        let noteRemoveID = try options.value("note-remove").map(parseUUID)
        let noteMoveID = try options.value("note-move").map(parseUUID)
        let noteMoveIndex = try options.value("note-index").map(parseInt)
        let existingAttachmentIDs = Set(
            BrainstormDocumentEditor.node(in: file, id: id)?.note?.attachments.map(\.id) ?? []
        )
        if let noteRemoveID, !existingAttachmentIDs.contains(noteRemoveID) {
            throw CLIUsageError("Note attachment not found: \(noteRemoveID.uuidString).")
        }
        if let noteMoveID {
            guard let noteMoveIndex else {
                throw CLIUsageError("--note-move requires --note-index <n>.")
            }
            guard existingAttachmentIDs.contains(noteMoveID) else {
                throw CLIUsageError("Note attachment not found: \(noteMoveID.uuidString).")
            }
            let maximumIndex = max(0, existingAttachmentIDs.count - 1)
            guard (0...maximumIndex).contains(noteMoveIndex) else {
                throw CLIUsageError("--note-index must be between 0 and \(maximumIndex).")
            }
        }

        try BrainstormDocumentEditor.updateNode(in: &file, id: id) { node in
            if let title { node.title = BrainstormDocumentEditor.normalizedTitle(title) }
            if let expanded { node.isExpanded = expanded }
            if let emoji { node.media.setExclusiveEmoji(isNone(emoji) ? nil : emoji) }
            if let sticker { node.media.setExclusiveSticker(isNone(sticker) ? nil : sticker) }
            if let image {
                if isNone(image) {
                    node.media.setExclusiveImageBase64(nil)
                } else {
                    node.media.setExclusiveImageBase64(imageBase64)
                }
            }
            if options.value("offset-x") != nil { node.offsetX = offsetX }
            if options.value("offset-y") != nil { node.offsetY = offsetY }

            if options.hasFlag("note-clear") {
                node.note = nil
            }
            if noteBody != nil || noteVisibility != nil || noteImage != nil || noteYouTube != nil {
                var note = node.note ?? NodeNote()
                if let noteBody {
                    note.bodyMarkdown = NodeNote.normalizeLineEndings(noteBody)
                }
                if let noteVisibility {
                    note.visibility = noteVisibility
                }
                if let noteImage {
                    note.attachments.append(.image(noteImage))
                }
                if let noteYouTube {
                    note.attachments.append(.youtube(noteYouTube))
                }
                node.note = note.isEmpty ? nil : note.canonicalized()
            }
            if let noteRemoveID, var note = node.note {
                note.attachments.removeAll { $0.id == noteRemoveID }
                node.note = note.isEmpty ? nil : note
            }
            if let noteMoveID, let noteMoveIndex, var note = node.note,
               let sourceIndex = note.attachments.firstIndex(where: { $0.id == noteMoveID }),
               note.attachments.indices.contains(sourceIndex)
            {
                let attachment = note.attachments.remove(at: sourceIndex)
                let destination = min(max(0, noteMoveIndex), note.attachments.count)
                note.attachments.insert(attachment, at: destination)
                node.note = note
            }
        }
        let node = BrainstormDocumentEditor.node(in: file, id: id)
        return try finishMutation("update", url: url, file: file, node: node, options: options)
    }

    private static func style(_ options: CLIOptions) throws -> CLIResponse {
        try options.allowing([
            "node", "fill", "text", "branch", "border", "border-width", "shape", "font-size",
            "bold", "italic", "dry-run", "pretty",
        ])
        let url = try documentURL(options)
        var file = try loadValidated(url)
        let id = try nodeReference(options.required("node"), in: file)
        guard options.hasAnyValue([
            "fill", "text", "branch", "border", "border-width", "shape", "font-size", "bold", "italic",
        ]) else {
            throw CLIUsageError("style requires at least one field to change.")
        }

        let fill = try optionalHex(options.value("fill"))
        let text = try optionalHex(options.value("text"))
        let branch = try optionalHex(options.value("branch"))
        let border = try optionalHex(options.value("border"))
        let borderWidth = try optionalNumber(options.value("border-width"))
        let fontSize = try optionalNumber(options.value("font-size"))
        let shape = try options.value("shape").map(parseShape)
        let bold = try options.value("bold").map(parseBool)
        let italic = try options.value("italic").map(parseBool)
        if let borderWidth, !(0...6).contains(borderWidth) {
            throw CLIUsageError("--border-width must be between 0 and 6, or 'none'.")
        }
        if let fontSize, !(8...72).contains(fontSize) {
            throw CLIUsageError("--font-size must be between 8 and 72, or 'none'.")
        }

        try BrainstormDocumentEditor.updateNode(in: &file, id: id) { node in
            if options.value("fill") != nil { node.style.fillHex = fill }
            if options.value("text") != nil { node.style.textHex = text }
            if options.value("branch") != nil { node.style.branchHex = branch }
            if options.value("border") != nil { node.style.borderHex = border }
            if options.value("border-width") != nil { node.style.borderWidth = borderWidth }
            if options.value("font-size") != nil { node.style.fontSize = fontSize }
            if let shape { node.style.shape = shape }
            if let bold { node.style.isBold = bold }
            if let italic { node.style.isItalic = italic }
        }
        let node = BrainstormDocumentEditor.node(in: file, id: id)
        return try finishMutation("style", url: url, file: file, node: node, options: options)
    }

    private static func move(_ options: CLIOptions) throws -> CLIResponse {
        try options.allowing(["node", "parent", "index", "dry-run", "pretty"])
        let url = try documentURL(options)
        var file = try loadValidated(url)
        let id = try nodeReference(options.required("node"), in: file)
        let parentID = try nodeReference(options.required("parent"), in: file)
        let index = try options.value("index").map(parseInt)
        try BrainstormDocumentEditor.moveNode(in: &file, id: id, toParent: parentID, index: index)
        let node = BrainstormDocumentEditor.node(in: file, id: id)
        return try finishMutation("move", url: url, file: file, node: node, options: options)
    }

    private static func delete(_ options: CLIOptions) throws -> CLIResponse {
        try options.allowing(["node", "dry-run", "pretty"])
        let url = try documentURL(options)
        var file = try loadValidated(url)
        let id = try nodeReference(options.required("node"), in: file)
        let removed = try BrainstormDocumentEditor.deleteNode(in: &file, id: id)
        return try finishMutation("delete", url: url, file: file, node: removed, options: options)
    }

    private static func export(_ options: CLIOptions) throws -> CLIResponse {
        try options.allowing([
            "format", "output", "appearance", "notes", "presentation", "pretty",
        ])
        let url = try documentURL(options)
        let file = try loadValidated(url)
        guard let format = BrainstormExportFormat(rawValue: try options.required("format").lowercased()) else {
            throw CLIUsageError("--format must be png, pdf, html, markdown, mermaid, or plantuml.")
        }
        let outputPath = try options.required("output")
        let theme = AppTheme.theme(id: file.themeID ?? AppTheme.system.id)
        let appearance = options.value("appearance")?.lowercased()
        guard appearance == nil || appearance == "light" || appearance == "dark" else {
            throw CLIUsageError("--appearance must be light or dark.")
        }
        if options.hasFlag("notes") {
            throw CLIUsageError("--notes requires visible, all, or none.")
        }
        let noteInclusion = try options.value("notes").map(parseNoteInclusion) ?? .visible
        if options.hasFlag("presentation"), format != .html {
            throw CLIUsageError("--presentation is available only with --format html.")
        }
        let exportOptions = BrainstormExportOptions(
            noteInclusion: noteInclusion,
            htmlInitialMode: options.hasFlag("presentation") ? .presentation : .map
        )
        let scheme: ColorScheme = appearance == "dark" || (appearance == nil && theme.isDark) ? .dark : .light
        let descriptor = BrainstormExporter.descriptor(
            root: file.root,
            format: format,
            options: exportOptions
        )
        if outputPath == "-" {
            let data = try BrainstormExporter.data(
                root: file.root,
                theme: theme,
                colorScheme: scheme,
                format: format,
                options: exportOptions
            )
            try FileHandle.standardOutput.write(contentsOf: data)
            return CLIResponse(command: "export", file: url.path, changed: false, output: "-")
        }

        let output = URL(fileURLWithPath: outputPath).standardizedFileURL
        if format == .markdown,
           output.pathExtension.lowercased() != descriptor.fileExtension
        {
            let kind = descriptor.isArchive
                ? "included notes produce a ZIP archive"
                : "no note files are included"
            throw CLIUsageError(
                "Markdown export \(kind); use --output <name>."
                    + descriptor.fileExtension
                    + " or --output -."
            )
        }
        try BrainstormExporter.write(
            root: file.root,
            theme: theme,
            colorScheme: scheme,
            format: format,
            to: output,
            options: exportOptions
        )
        return CLIResponse(command: "export", file: url.path, changed: false, output: output.path)
    }

    private static func validate(_ options: CLIOptions) throws -> CLIResponse {
        try options.allowing(["pretty"])
        let url = try documentURL(options)
        let file = try BrainstormCodec.load(from: url)
        let issues = BrainstormDocumentEditor.validationIssues(in: file)
        if !issues.isEmpty { throw BrainstormDocumentEditError.validationFailed(issues) }
        return CLIResponse(command: "validate", file: url.path, changed: false, issues: [])
    }

    private static func apply(_ options: CLIOptions) throws -> CLIResponse {
        try options.allowing(["input", "dry-run", "pretty"])
        let url = try documentURL(options)
        var file = try loadValidated(url)
        let input = options.value("input") ?? "-"
        let data = try input == "-"
            ? FileHandle.standardInput.readToEnd() ?? Data()
            : Data(contentsOf: URL(fileURLWithPath: input))
        let request = try JSONDecoder().decode(BatchRequest.self, from: data)
        guard !request.operations.isEmpty else {
            throw CLIUsageError("Batch request contains no operations.")
        }

        var results: [BatchResult] = []
        for operation in request.operations {
            results.append(try apply(operation, to: &file))
        }
        file.version = BrainstormFile.currentVersion
        try BrainstormDocumentEditor.validate(file)
        let dryRun = options.hasFlag("dry-run")
        if !dryRun { try BrainstormCodec.save(file, to: url) }
        return CLIResponse(
            command: "apply", file: url.path, changed: true, dryRun: dryRun,
            document: file, operations: results
        )
    }

    private static func apply(_ operation: BatchOperation, to file: inout BrainstormFile) throws -> BatchResult {
        switch operation.op {
        case "add":
            let parentID = try nodeReference(operation.parent ?? "root", in: file)
            let id = try operation.id.map(parseUUID) ?? UUID()
            let node = try BrainstormDocumentEditor.addNode(
                to: &file, parentID: parentID, id: id,
                title: operation.title ?? "New node", index: operation.index
            )
            return BatchResult(op: operation.op, nodeID: node.id)
        case "update":
            let id = try nodeReference(operation.node ?? "", in: file)
            try BrainstormDocumentEditor.updateNode(in: &file, id: id) { node in
                if let title = operation.title { node.title = BrainstormDocumentEditor.normalizedTitle(title) }
                if let expanded = operation.expanded { node.isExpanded = expanded }
                if let emoji = operation.emoji { node.media.setExclusiveEmoji(isNone(emoji) ? nil : emoji) }
                if let sticker = operation.sticker { node.media.setExclusiveSticker(isNone(sticker) ? nil : sticker) }
                if let x = operation.offsetX { node.offsetX = x }
                if let y = operation.offsetY { node.offsetY = y }
            }
            return BatchResult(op: operation.op, nodeID: id)
        case "note.set":
            let id = try nodeReference(operation.node ?? "", in: file)
            guard operation.bodyMarkdown != nil || operation.visibility != nil else {
                throw CLIUsageError("note.set requires bodyMarkdown and/or visibility.")
            }
            let visibility = try operation.visibility.map(parseNoteVisibility)
            try BrainstormDocumentEditor.updateNode(in: &file, id: id) { node in
                var note = node.note ?? NodeNote()
                if let body = operation.bodyMarkdown {
                    note.bodyMarkdown = NodeNote.normalizeLineEndings(body)
                }
                if let visibility {
                    note.visibility = visibility
                }
                node.note = note.isEmpty ? nil : note.canonicalized()
            }
            return BatchResult(op: operation.op, nodeID: id)
        case "note.clear":
            let id = try nodeReference(operation.node ?? "", in: file)
            try BrainstormDocumentEditor.updateNode(in: &file, id: id) { node in
                node.note = nil
            }
            return BatchResult(op: operation.op, nodeID: id)
        case "note.image":
            let id = try nodeReference(operation.node ?? "", in: file)
            guard let imagePath = operation.imagePath,
                  let altText = operation.altText,
                  !altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw CLIUsageError("note.image requires imagePath and non-empty altText.")
            }
            let imageURL = URL(fileURLWithPath: imagePath).standardizedFileURL
            let data: Data
            do {
                data = try Data(contentsOf: imageURL)
            } catch {
                throw CLIUsageError(
                    "Could not read note image '\(imageURL.path)': \(error.localizedDescription)"
                )
            }
            let image = try NodeNoteImageNormalizer.normalize(
                data,
                altText: altText,
                caption: operation.caption,
                path: "$.root.note.attachments"
            )
            try BrainstormDocumentEditor.updateNode(in: &file, id: id) { node in
                var note = node.note ?? NodeNote()
                note.attachments.append(.image(image))
                node.note = note
            }
            return BatchResult(op: operation.op, nodeID: id, attachmentID: image.id)
        case "note.youtube":
            let id = try nodeReference(operation.node ?? "", in: file)
            guard let input = operation.youtube else {
                throw CLIUsageError("note.youtube requires youtube.")
            }
            let parsed = try YouTubeReferenceParser.parse(input)
            let youtube = NoteYouTubeAttachment(
                videoID: parsed.videoID,
                startSeconds: parsed.startSeconds,
                caption: operation.caption
            )
            try BrainstormDocumentEditor.updateNode(in: &file, id: id) { node in
                var note = node.note ?? NodeNote()
                note.attachments.append(.youtube(youtube))
                node.note = note
            }
            return BatchResult(op: operation.op, nodeID: id, attachmentID: youtube.id)
        case "note.remove":
            let id = try nodeReference(operation.node ?? "", in: file)
            guard let rawAttachmentID = operation.attachmentID else {
                throw CLIUsageError("note.remove requires attachmentID.")
            }
            let attachmentID = try parseUUID(rawAttachmentID)
            guard BrainstormDocumentEditor.node(in: file, id: id)?.note?.attachments
                .contains(where: { $0.id == attachmentID }) == true
            else {
                throw CLIUsageError("Note attachment not found: \(attachmentID.uuidString).")
            }
            try BrainstormDocumentEditor.updateNode(in: &file, id: id) { node in
                guard var note = node.note else { return }
                note.attachments.removeAll { $0.id == attachmentID }
                node.note = note.isEmpty ? nil : note
            }
            return BatchResult(
                op: operation.op,
                nodeID: id,
                attachmentID: attachmentID
            )
        case "note.move":
            let id = try nodeReference(operation.node ?? "", in: file)
            guard let rawAttachmentID = operation.attachmentID,
                  let destination = operation.attachmentIndex
            else {
                throw CLIUsageError("note.move requires attachmentID and attachmentIndex.")
            }
            let attachmentID = try parseUUID(rawAttachmentID)
            guard let note = BrainstormDocumentEditor.node(in: file, id: id)?.note,
                  let source = note.attachments.firstIndex(where: { $0.id == attachmentID })
            else {
                throw CLIUsageError("Note attachment not found: \(attachmentID.uuidString).")
            }
            guard (0..<note.attachments.count).contains(destination) else {
                throw CLIUsageError(
                    "attachmentIndex must be between 0 and \(max(0, note.attachments.count - 1))."
                )
            }
            try BrainstormDocumentEditor.updateNode(in: &file, id: id) { node in
                guard var note = node.note else { return }
                let attachment = note.attachments.remove(at: source)
                note.attachments.insert(attachment, at: destination)
                node.note = note
            }
            return BatchResult(
                op: operation.op,
                nodeID: id,
                attachmentID: attachmentID
            )
        case "style":
            let id = try nodeReference(operation.node ?? "", in: file)
            let shape = try operation.shape.map(parseShape)
            try BrainstormDocumentEditor.updateNode(in: &file, id: id) { node in
                if let fill = operation.fill { node.style.fillHex = isNone(fill) ? nil : fill }
                if let text = operation.text { node.style.textHex = isNone(text) ? nil : text }
                if let branch = operation.branch { node.style.branchHex = isNone(branch) ? nil : branch }
                if let border = operation.border { node.style.borderHex = isNone(border) ? nil : border }
                if let width = operation.borderWidth { node.style.borderWidth = width }
                if let size = operation.fontSize { node.style.fontSize = size }
                if let shape { node.style.shape = shape }
                if let bold = operation.bold { node.style.isBold = bold }
                if let italic = operation.italic { node.style.isItalic = italic }
            }
            return BatchResult(op: operation.op, nodeID: id)
        case "move":
            let id = try nodeReference(operation.node ?? "", in: file)
            let parentID = try nodeReference(operation.parent ?? "root", in: file)
            try BrainstormDocumentEditor.moveNode(
                in: &file, id: id, toParent: parentID, index: operation.index
            )
            return BatchResult(op: operation.op, nodeID: id)
        case "delete":
            let id = try nodeReference(operation.node ?? "", in: file)
            _ = try BrainstormDocumentEditor.deleteNode(in: &file, id: id)
            return BatchResult(op: operation.op, nodeID: id)
        case "theme":
            guard let themeID = operation.theme,
                  AppTheme.all.contains(where: { $0.id == themeID })
            else { throw CLIUsageError("Batch theme operation requires a valid theme id.") }
            file.themeID = themeID
            return BatchResult(op: operation.op)
        default:
            throw CLIUsageError("Unknown batch operation '\(operation.op)'.")
        }
    }

    private static func finishMutation(
        _ command: String,
        url: URL,
        file: BrainstormFile,
        node: BrainstormNode?,
        options: CLIOptions
    ) throws -> CLIResponse {
        var canonicalFile = file
        canonicalFile.version = BrainstormFile.currentVersion
        try BrainstormDocumentEditor.validate(canonicalFile)
        let dryRun = options.hasFlag("dry-run")
        if !dryRun { try BrainstormCodec.save(canonicalFile, to: url) }
        return CLIResponse(
            command: command, file: url.path, changed: true, dryRun: dryRun,
            document: canonicalFile,
            node: node.flatMap { BrainstormDocumentEditor.node(in: canonicalFile, id: $0.id) }
        )
    }

    private static func loadValidated(_ url: URL) throws -> BrainstormFile {
        let file = try BrainstormCodec.load(from: url)
        try BrainstormDocumentEditor.validate(file)
        return file
    }

    private static func documentURL(_ options: CLIOptions) throws -> URL {
        guard let path = options.positionals.first else {
            throw CLIUsageError("A .bs file path is required.")
        }
        guard options.positionals.count == 1 else {
            throw CLIUsageError("Unexpected positional arguments: \(options.positionals.dropFirst().joined(separator: " "))")
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private static func nodeReference(_ raw: String, in file: BrainstormFile) throws -> UUID {
        if raw.lowercased() == "root" { return file.root.id }
        return try parseUUID(raw)
    }

    private static func flattenedNodes(_ root: BrainstormNode) -> [FlatNode] {
        var records: [FlatNode] = []
        func visit(_ node: BrainstormNode, parentID: UUID?, index: Int) {
            records.append(FlatNode(
                id: node.id,
                parentID: parentID,
                index: index,
                title: node.title,
                isExpanded: node.isExpanded,
                childIDs: node.children.map(\.id),
                style: node.style,
                media: node.media,
                note: node.note,
                offsetX: node.offsetX,
                offsetY: node.offsetY
            ))
            for (childIndex, child) in node.children.enumerated() {
                visit(child, parentID: node.id, index: childIndex)
            }
        }
        visit(root, parentID: nil, index: 0)
        return records
    }

    private static func noteBodyValue(_ options: CLIOptions) throws -> String? {
        if let body = options.value("note-text") {
            return NodeNote.normalizeLineEndings(body)
        }
        guard let input = options.value("note-file") else { return nil }
        let data: Data
        do {
            if input == "-" {
                data = try FileHandle.standardInput.readToEnd() ?? Data()
            } else {
                data = try Data(contentsOf: URL(fileURLWithPath: input).standardizedFileURL)
            }
        } catch {
            throw CLIUsageError("Could not read note text from '\(input)': \(error.localizedDescription)")
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw CLIUsageError("Note text input must be valid UTF-8.")
        }
        return NodeNote.normalizeLineEndings(body)
    }

    private static func parseNoteVisibility(_ raw: String) throws -> NodeNoteVisibility {
        switch raw.lowercased() {
        case "shown", "show", "visible", "true", "yes", "1":
            return .shown
        case "hidden", "hide", "false", "no", "0":
            return .hidden
        default:
            throw CLIUsageError("--note-visible must be shown/hidden or true/false.")
        }
    }

    private static func parseNoteInclusion(_ raw: String) throws -> BrainstormNoteInclusion {
        guard let inclusion = BrainstormNoteInclusion(rawValue: raw.lowercased()) else {
            throw CLIUsageError("--notes must be visible, all, or none.")
        }
        return inclusion
    }

    private static func parseUUID(_ raw: String) throws -> UUID {
        guard let id = UUID(uuidString: raw) else { throw CLIUsageError("Invalid UUID '\(raw)'.") }
        return id
    }

    private static func parseInt(_ raw: String) throws -> Int {
        guard let value = Int(raw) else { throw CLIUsageError("Expected an integer, got '\(raw)'.") }
        return value
    }

    private static func parseBool(_ raw: String) throws -> Bool {
        switch raw.lowercased() {
        case "true", "yes", "1": true
        case "false", "no", "0": false
        default: throw CLIUsageError("Expected true or false, got '\(raw)'.")
        }
    }

    private static func parseShape(_ raw: String) throws -> NodeShape {
        guard let shape = NodeShape(rawValue: raw) else {
            throw CLIUsageError("Unknown shape '\(raw)'.")
        }
        return shape
    }

    private static func optionalNumber(_ raw: String?) throws -> Double? {
        guard let raw else { return nil }
        if isNone(raw) { return nil }
        guard let value = Double(raw), value.isFinite else {
            throw CLIUsageError("Expected a number or 'none', got '\(raw)'.")
        }
        return value
    }

    private static func optionalHex(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        if isNone(raw) { return nil }
        let value = raw.hasPrefix("#") ? raw : "#\(raw)"
        let digits = value.dropFirst()
        guard digits.count == 6, digits.allSatisfy({ $0.isHexDigit }) else {
            throw CLIUsageError("Expected a #RRGGBB color or 'none', got '\(raw)'.")
        }
        return value.uppercased()
    }

    private static func isNone(_ value: String) -> Bool {
        ["none", "null", "clear"].contains(value.lowercased())
    }

    private static func writeJSON<T: Encodable>(
        _ value: T,
        pretty: Bool,
        to handle: FileHandle
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        var data = try encoder.encode(value)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func printHelp() {
        print(Self.help)
    }

    private static let help = """
    brainstorm — create, edit, validate, and export Brainstorm .bs mind maps

    Usage:
      brainstorm themes [theme-id] [--pretty]
      brainstorm create <file.bs> --title <text> [--theme <id>] [--force]
      brainstorm inspect <file.bs> [--flat] [--pretty]
      brainstorm add <file.bs> --parent <root|uuid> --title <text> [--id <uuid>] [--index <n>]
      brainstorm update <file.bs> --node <root|uuid> [--title <text>] [--expanded true|false]
                         [--emoji <value|none>] [--sticker <symbol|none>] [--image <path|none>]
                         [--offset-x <n|none>] [--offset-y <n|none>]
                         [--note-text <markdown>|--note-file <path|->]
                         [--note-visible shown|hidden] [--note-clear]
                         [--note-image <path> --note-image-alt <text>]
                         [--note-image-caption <text>]
                         [--note-youtube <id|url>] [--note-youtube-caption <text>]
                         [--note-remove <attachment-uuid>]
                         [--note-move <attachment-uuid> --note-index <n>]
      brainstorm style <file.bs> --node <root|uuid> [--fill <hex|none>] [--text <hex|none>]
                        [--branch <hex|none>] [--border <hex|none>] [--border-width <n|none>]
                        [--shape roundedRect|capsule|rectangle|diamond]
                        [--font-size <n|none>] [--bold true|false] [--italic true|false]
      brainstorm move <file.bs> --node <uuid> --parent <root|uuid> [--index <n>]
      brainstorm delete <file.bs> --node <uuid>
      brainstorm export <file.bs> --format png|pdf|html|markdown|mermaid|plantuml --output <path|->
                        [--appearance light|dark] [--notes visible|all|none]
                        [--presentation]
      brainstorm validate <file.bs>
      brainstorm apply <file.bs> [--input <request.json|->] [--dry-run]

    Note text supports paragraphs, **bold**, _italic_, and ordered/unordered lists.
    Images are normalized and embedded in the .bs document; YouTube stores a validated video id.
    Markdown writes one .md outline when no notes are included. When notes are included it writes
    a .zip containing map.md, linked notes/*.md files, and extracted image assets.
    --presentation makes an HTML export open directly in its depth-first presentation mode.
    Mutations save atomically by default. Add --dry-run to preview JSON without writing.
    Use --output - to stream exported bytes to stdout without a JSON response.
    Other successes emit machine-readable JSON; failures emit JSON to stderr and exit nonzero.
    """
}

private struct CLIOptions {
    let positionals: [String]
    private let values: [String: String]
    private let flags: Set<String>

    init(_ arguments: [String]) throws {
        var positionals: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []
        let booleanFlags: Set<String> = [
            "force", "dry-run", "pretty", "flat", "note-clear", "presentation",
        ]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                positionals.append(argument)
                index += 1
                continue
            }
            let body = String(argument.dropFirst(2))
            guard !body.isEmpty else { throw CLIUsageError("Invalid option '--'.") }
            if let equals = body.firstIndex(of: "=") {
                let key = String(body[..<equals])
                let value = String(body[body.index(after: equals)...])
                values[key] = value
                index += 1
            } else if booleanFlags.contains(body) {
                flags.insert(body)
                index += 1
            } else if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                values[body] = arguments[index + 1]
                index += 2
            } else {
                flags.insert(body)
                index += 1
            }
        }
        self.positionals = positionals
        self.values = values
        self.flags = flags
    }

    func value(_ key: String) -> String? { values[key] }
    func hasFlag(_ key: String) -> Bool { flags.contains(key) }
    func hasAnyValue(_ keys: [String]) -> Bool { keys.contains { values[$0] != nil } }

    func required(_ key: String) throws -> String {
        guard let value = values[key], !value.isEmpty else {
            throw CLIUsageError("Missing required option --\(key).")
        }
        return value
    }

    func allowing(_ allowed: Set<String>) throws {
        let supplied = Set(values.keys).union(flags)
        let unknown = supplied.subtracting(allowed)
        if let first = unknown.sorted().first {
            throw CLIUsageError("Unknown option --\(first).")
        }
    }
}

private struct CLIResponse: Encodable {
    let ok = true
    let command: String
    var file: String? = nil
    let changed: Bool
    var dryRun: Bool? = nil
    var output: String? = nil
    var document: BrainstormFile? = nil
    var node: BrainstormNode? = nil
    var nodes: [FlatNode]? = nil
    var issues: [String]? = nil
    var operations: [BatchResult]? = nil
    var theme: AppTheme? = nil
    var themes: [AppTheme]? = nil
}

private struct FlatNode: Encodable {
    let id: UUID
    let parentID: UUID?
    let index: Int
    let title: String
    let isExpanded: Bool
    let childIDs: [UUID]
    let style: NodeStyle
    let media: NodeMedia
    let note: NodeNote?
    let offsetX: Double?
    let offsetY: Double?
}

private struct CLIErrorResponse: Encodable {
    let ok: Bool
    let error: CLIErrorPayload
}

private struct CLIErrorPayload: Encodable {
    let type: String
    let message: String
}

private struct BatchRequest: Decodable {
    let operations: [BatchOperation]
}

private struct BatchOperation: Decodable {
    let op: String
    var node: String?
    var parent: String?
    var id: String?
    var title: String?
    var index: Int?
    var expanded: Bool?
    var emoji: String?
    var sticker: String?
    var offsetX: Double?
    var offsetY: Double?
    var fill: String?
    var text: String?
    var branch: String?
    var border: String?
    var borderWidth: Double?
    var shape: String?
    var fontSize: Double?
    var bold: Bool?
    var italic: Bool?
    var theme: String?
    var bodyMarkdown: String?
    var visibility: String?
    var imagePath: String?
    var altText: String?
    var caption: String?
    var youtube: String?
    var attachmentID: String?
    var attachmentIndex: Int?
}

private struct BatchResult: Encodable {
    let op: String
    var nodeID: UUID? = nil
    var attachmentID: UUID? = nil
}

private struct CLIUsageError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

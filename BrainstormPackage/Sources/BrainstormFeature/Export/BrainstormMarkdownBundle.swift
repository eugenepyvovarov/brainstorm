import Foundation

struct BrainstormMarkdownBundle {
    struct Entry: Equatable, Sendable {
        let path: String
        let data: Data
    }

    private struct IncludedNote {
        let node: BrainstormNode
        let note: NodeNote
        let stem: String

        var notePath: String {
            "notes/\(stem).md"
        }
    }

    let indexMarkdown: String
    let noteFileCount: Int
    let entries: [Entry]

    var isArchive: Bool {
        noteFileCount > 0
    }

    static func includedNoteCount(
        root: BrainstormNode,
        inclusion: BrainstormNoteInclusion
    ) -> Int {
        includedNotes(root: root, inclusion: inclusion).count
    }

    static func indexMarkdown(
        root: BrainstormNode,
        inclusion: BrainstormNoteInclusion
    ) -> String {
        let notes = includedNotes(root: root, inclusion: inclusion)
        let pathsByNodeID = Dictionary(
            uniqueKeysWithValues: notes.map { ($0.node.id, $0.notePath) }
        )
        var lines = [
            "# \(BrainstormTextExporter.markdownInline(root.title, multilineSeparator: "<br>"))",
            "",
        ]
        appendNode(
            root,
            depth: 0,
            notePathsByNodeID: pathsByNodeID,
            to: &lines
        )
        return lines.joined(separator: "\n") + "\n"
    }

    static func make(
        root: BrainstormNode,
        inclusion: BrainstormNoteInclusion
    ) throws -> BrainstormMarkdownBundle {
        let notes = includedNotes(root: root, inclusion: inclusion)
        let index = indexMarkdown(root: root, inclusion: inclusion)
        guard !notes.isEmpty else {
            return BrainstormMarkdownBundle(
                indexMarkdown: index,
                noteFileCount: 0,
                entries: [Entry(path: "map.md", data: Data(index.utf8))]
            )
        }

        var noteEntries: [Entry] = []
        var assetEntries: [Entry] = []
        noteEntries.reserveCapacity(notes.count)

        for included in notes {
            let noteTitle = BrainstormTextExporter.markdownInline(
                included.node.title,
                multilineSeparator: "<br>"
            )
            var lines = ["# \(noteTitle)"]
            let body = NodeNoteRendering.sanitizedMarkdownBody(
                included.note.bodyMarkdown
            )
            if !body.isEmpty {
                lines.append("")
                lines.append(body)
            }

            for attachment in included.note.attachments {
                lines.append("")
                switch attachment {
                case .image(let image):
                    guard let pngData = image.pngData else {
                        throw BrainstormMarkdownBundleError.invalidImage(
                            nodeID: included.node.id,
                            attachmentID: image.id
                        )
                    }
                    let assetName =
                        "\(included.stem)--\(image.id.uuidString.lowercased()).png"
                    let assetPath = "assets/\(assetName)"
                    let alternativeText = BrainstormTextExporter.markdownInline(
                        NodeNoteRendering.nonEmpty(image.altText) ?? "Note image",
                        multilineSeparator: " "
                    )
                    lines.append("![\(alternativeText)](../\(assetPath))")
                    if let caption = NodeNoteRendering.nonEmpty(image.caption) {
                        lines.append("")
                        let escapedCaption =
                            BrainstormTextExporter.markdownInline(
                                caption,
                                multilineSeparator: "<br>"
                            )
                        lines.append(
                            "*\(escapedCaption)*"
                        )
                    }
                    assetEntries.append(Entry(path: assetPath, data: pngData))
                case .youtube(let youtube):
                    let label = BrainstormTextExporter.markdownInline(
                        NodeNoteRendering.nonEmpty(youtube.caption)
                            ?? "YouTube video",
                        multilineSeparator: " "
                    )
                    lines.append(
                        "[\(label)](\(youtube.canonicalURL.absoluteString))"
                    )
                }
            }

            let markdown = lines.joined(separator: "\n") + "\n"
            noteEntries.append(
                Entry(path: included.notePath, data: Data(markdown.utf8))
            )
        }

        return BrainstormMarkdownBundle(
            indexMarkdown: index,
            noteFileCount: notes.count,
            entries: [
                Entry(path: "map.md", data: Data(index.utf8)),
            ] + noteEntries + assetEntries
        )
    }

    private static func includedNotes(
        root: BrainstormNode,
        inclusion: BrainstormNoteInclusion
    ) -> [IncludedNote] {
        var result: [IncludedNote] = []

        func visit(_ node: BrainstormNode) {
            if let note = node.note, inclusion.includes(note) {
                result.append(
                    IncludedNote(
                        node: node,
                        note: note,
                        stem: safeStem(title: node.title, nodeID: node.id)
                    )
                )
            }
            for child in node.children {
                visit(child)
            }
        }

        visit(root)
        return result
    }

    private static func appendNode(
        _ node: BrainstormNode,
        depth: Int,
        notePathsByNodeID: [UUID: String],
        to lines: inout [String]
    ) {
        let indentation = String(repeating: "    ", count: depth)
        let title = BrainstormTextExporter.markdownInline(
            node.title,
            multilineSeparator: "<br>"
        )
        if let notePath = notePathsByNodeID[node.id] {
            lines.append(
                "\(indentation)- \(title) — [Note](\(notePath))"
            )
        } else {
            lines.append("\(indentation)- \(title)")
        }
        for child in node.children {
            appendNode(
                child,
                depth: depth + 1,
                notePathsByNodeID: notePathsByNodeID,
                to: &lines
            )
        }
    }

    private static func safeStem(title: String, nodeID: UUID) -> String {
        let folded = title.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var slug = ""
        var pendingSeparator = false
        for scalar in folded.unicodeScalars {
            let value = scalar.value
            let isDigit = value >= 48 && value <= 57
            let isLowercaseLetter = value >= 97 && value <= 122
            let isUppercaseLetter = value >= 65 && value <= 90
            if isDigit || isLowercaseLetter || isUppercaseLetter {
                if pendingSeparator, !slug.isEmpty, slug.count < 48 {
                    slug.append("-")
                }
                pendingSeparator = false
                if slug.count < 48 {
                    slug.append(Character(String(scalar).lowercased()))
                }
            } else if !slug.isEmpty {
                pendingSeparator = true
            }
        }
        while slug.last == "-" {
            slug.removeLast()
        }
        if slug.isEmpty {
            slug = "node"
        }
        return "\(slug)--\(nodeID.uuidString.lowercased())"
    }
}

enum BrainstormMarkdownBundleError: LocalizedError, Equatable {
    case invalidImage(nodeID: UUID, attachmentID: UUID)

    var errorDescription: String? {
        switch self {
        case .invalidImage(let nodeID, let attachmentID):
            "The note image \(attachmentID.uuidString) on node "
                + "\(nodeID.uuidString) could not be decoded."
        }
    }
}

enum BrainstormZIPArchive {
    private struct CentralEntry {
        let entry: BrainstormMarkdownBundle.Entry
        let nameData: Data
        let checksum: UInt32
        let localOffset: UInt32
    }

    static func data(
        entries: [BrainstormMarkdownBundle.Entry]
    ) throws -> Data {
        guard entries.count <= Int(UInt16.max) else {
            throw BrainstormZIPArchiveError.tooManyEntries
        }

        var seenPaths: Set<String> = []
        var archive = Data()
        var centralEntries: [CentralEntry] = []
        centralEntries.reserveCapacity(entries.count)

        for entry in entries {
            guard isSafePath(entry.path), seenPaths.insert(entry.path).inserted else {
                throw BrainstormZIPArchiveError.invalidEntryPath(entry.path)
            }
            let nameData = Data(entry.path.utf8)
            guard nameData.count <= Int(UInt16.max),
                  entry.data.count <= Int(UInt32.max),
                  archive.count <= Int(UInt32.max)
            else {
                throw BrainstormZIPArchiveError.archiveTooLarge
            }

            let checksum = crc32(entry.data)
            let localOffset = UInt32(archive.count)
            archive.appendLittleEndian(UInt32(0x0403_4B50))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(0x0800))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(33))
            archive.appendLittleEndian(checksum)
            archive.appendLittleEndian(UInt32(entry.data.count))
            archive.appendLittleEndian(UInt32(entry.data.count))
            archive.appendLittleEndian(UInt16(nameData.count))
            archive.appendLittleEndian(UInt16(0))
            archive.append(nameData)
            archive.append(entry.data)

            centralEntries.append(
                CentralEntry(
                    entry: entry,
                    nameData: nameData,
                    checksum: checksum,
                    localOffset: localOffset
                )
            )
        }

        guard archive.count <= Int(UInt32.max) else {
            throw BrainstormZIPArchiveError.archiveTooLarge
        }
        let centralOffset = UInt32(archive.count)

        for central in centralEntries {
            archive.appendLittleEndian(UInt32(0x0201_4B50))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(0x0800))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(33))
            archive.appendLittleEndian(central.checksum)
            archive.appendLittleEndian(UInt32(central.entry.data.count))
            archive.appendLittleEndian(UInt32(central.entry.data.count))
            archive.appendLittleEndian(UInt16(central.nameData.count))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt32(0))
            archive.appendLittleEndian(central.localOffset)
            archive.append(central.nameData)
        }

        guard archive.count <= Int(UInt32.max) else {
            throw BrainstormZIPArchiveError.archiveTooLarge
        }
        let centralSize = UInt32(archive.count) - centralOffset
        let entryCount = UInt16(centralEntries.count)
        archive.appendLittleEndian(UInt32(0x0605_4B50))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(entryCount)
        archive.appendLittleEndian(entryCount)
        archive.appendLittleEndian(centralSize)
        archive.appendLittleEndian(centralOffset)
        archive.appendLittleEndian(UInt16(0))
        return archive
    }

    private static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("\\"),
              !path.contains("//"),
              path.utf8.allSatisfy({ $0 < 128 })
        else {
            return false
        }
        return path.split(separator: "/").allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var value = UInt32.max
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(0) &- (value & 1)
                value = (value >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return ~value
    }
}

enum BrainstormZIPArchiveError: LocalizedError, Equatable {
    case tooManyEntries
    case archiveTooLarge
    case invalidEntryPath(String)

    var errorDescription: String? {
        switch self {
        case .tooManyEntries:
            "The Markdown bundle contains too many files for a ZIP archive."
        case .archiveTooLarge:
            "The Markdown bundle is too large for a ZIP archive."
        case .invalidEntryPath(let path):
            "The Markdown bundle contains an invalid archive path: \(path)"
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) {
            append(contentsOf: $0)
        }
    }
}

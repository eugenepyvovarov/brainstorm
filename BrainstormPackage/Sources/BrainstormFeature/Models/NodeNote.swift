import Foundation

// MARK: - Note model

/// Legacy saved per-note inclusion used by static exports and CLI automation.
public enum NodeNoteVisibility: String, Codable, CaseIterable, Hashable, Sendable {
    case shown
    case hidden
}

/// Optional information attached to a mind-map node.
///
/// Empty notes are canonicalized to `nil` by `BrainstormNode` and the codec.
public struct NodeNote: Codable, Equatable, Hashable, Sendable {
    public var visibility: NodeNoteVisibility
    public var bodyMarkdown: String
    public var attachments: [NodeNoteAttachment]

    private enum CodingKeys: String, CodingKey {
        case visibility
        case bodyMarkdown
        case attachments
    }

    public init(
        visibility: NodeNoteVisibility = .shown,
        bodyMarkdown: String = "",
        attachments: [NodeNoteAttachment] = []
    ) {
        self.visibility = visibility
        self.bodyMarkdown = bodyMarkdown
        self.attachments = attachments
    }

    /// Visibility alone does not make a note meaningful.
    public var isEmpty: Bool {
        bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachments.isEmpty
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        visibility = try c.decodeIfPresent(NodeNoteVisibility.self, forKey: .visibility) ?? .shown
        bodyMarkdown = try c.decodeIfPresent(String.self, forKey: .bodyMarkdown) ?? ""
        attachments = try c.decodeIfPresent([NodeNoteAttachment].self, forKey: .attachments) ?? []
    }

    /// Default visibility and empty collections are omitted from v3 JSON.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if visibility != .shown {
            try c.encode(visibility, forKey: .visibility)
        }
        if !bodyMarkdown.isEmpty {
            try c.encode(bodyMarkdown, forKey: .bodyMarkdown)
        }
        if !attachments.isEmpty {
            try c.encode(attachments, forKey: .attachments)
        }
    }

    public func canonicalized() -> NodeNote {
        NodeNote(
            visibility: visibility,
            bodyMarkdown: Self.normalizeLineEndings(bodyMarkdown),
            attachments: attachments.map { $0.canonicalized() }
        )
    }

    public static func normalizeLineEndings(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

/// A stable, ordered, typed note attachment.
///
/// JSON is deliberately a flat tagged object rather than Swift's synthesized
/// associated-value representation so `.bs` files remain portable and easy to
/// inspect:
///
/// `{ "type": "image", ... }` or `{ "type": "youtube", ... }`.
public enum NodeNoteAttachment: Codable, Equatable, Hashable, Sendable, Identifiable {
    case image(NoteImageAttachment)
    case youtube(NoteYouTubeAttachment)

    public enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case image
        case youtube
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case pngBase64
        case pixelWidth
        case pixelHeight
        case altText
        case caption
        case videoID
        case startSeconds
    }

    public var id: UUID {
        switch self {
        case .image(let attachment): attachment.id
        case .youtube(let attachment): attachment.id
        }
    }

    public var kind: Kind {
        switch self {
        case .image: .image
        case .youtube: .youtube
        }
    }

    public var caption: String? {
        switch self {
        case .image(let attachment): attachment.caption
        case .youtube(let attachment): attachment.caption
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(Kind.self, forKey: .type)
        let id = try c.decode(UUID.self, forKey: .id)
        switch type {
        case .image:
            self = .image(
                NoteImageAttachment(
                    id: id,
                    pngBase64: try c.decode(String.self, forKey: .pngBase64),
                    pixelWidth: try c.decode(Int.self, forKey: .pixelWidth),
                    pixelHeight: try c.decode(Int.self, forKey: .pixelHeight),
                    altText: try c.decode(String.self, forKey: .altText),
                    caption: try c.decodeIfPresent(String.self, forKey: .caption)
                )
            )
        case .youtube:
            self = .youtube(
                NoteYouTubeAttachment(
                    id: id,
                    videoID: try c.decode(String.self, forKey: .videoID),
                    startSeconds: try c.decodeIfPresent(Int.self, forKey: .startSeconds),
                    caption: try c.decodeIfPresent(String.self, forKey: .caption)
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .image(let attachment):
            try c.encode(Kind.image, forKey: .type)
            try c.encode(attachment.id, forKey: .id)
            try c.encode(attachment.pngBase64, forKey: .pngBase64)
            try c.encode(attachment.pixelWidth, forKey: .pixelWidth)
            try c.encode(attachment.pixelHeight, forKey: .pixelHeight)
            try c.encode(attachment.altText, forKey: .altText)
            try c.encodeIfPresent(attachment.caption, forKey: .caption)
        case .youtube(let attachment):
            try c.encode(Kind.youtube, forKey: .type)
            try c.encode(attachment.id, forKey: .id)
            try c.encode(attachment.videoID, forKey: .videoID)
            try c.encodeIfPresent(attachment.startSeconds, forKey: .startSeconds)
            try c.encodeIfPresent(attachment.caption, forKey: .caption)
        }
    }

    public func canonicalized() -> NodeNoteAttachment {
        switch self {
        case .image(let attachment):
            return .image(attachment.canonicalized())
        case .youtube(let attachment):
            return .youtube(attachment.canonicalized())
        }
    }
}

public struct NoteImageAttachment: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Normalized PNG bytes encoded for portable JSON storage.
    public var pngBase64: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var altText: String
    public var caption: String?

    public init(
        id: UUID = UUID(),
        pngBase64: String,
        pixelWidth: Int,
        pixelHeight: Int,
        altText: String,
        caption: String? = nil
    ) {
        self.id = id
        self.pngBase64 = pngBase64
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.altText = altText
        self.caption = caption
    }

    public var pngData: Data? {
        Data(base64Encoded: pngBase64)
    }

    public func canonicalized() -> NoteImageAttachment {
        let canonicalBase64 = Data(base64Encoded: pngBase64)?.base64EncodedString() ?? pngBase64
        return NoteImageAttachment(
            id: id,
            pngBase64: canonicalBase64,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            altText: altText.trimmingCharacters(in: .whitespacesAndNewlines),
            caption: Self.canonicalCaption(caption)
        )
    }

    fileprivate static func canonicalCaption(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = NodeNote.normalizeLineEndings(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

public struct NoteYouTubeAttachment: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Validated eleven-character YouTube video identifier.
    public var videoID: String
    public var startSeconds: Int?
    public var caption: String?

    public init(
        id: UUID = UUID(),
        videoID: String,
        startSeconds: Int? = nil,
        caption: String? = nil
    ) {
        self.id = id
        self.videoID = videoID
        self.startSeconds = startSeconds
        self.caption = caption
    }

    public var canonicalURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "youtu.be"
        components.path = "/\(videoID)"
        if let startSeconds, startSeconds > 0 {
            components.queryItems = [URLQueryItem(name: "t", value: "\(startSeconds)")]
        }
        // The fixed scheme/host and validated id always form a valid URL.
        return components.url ?? URL(string: "https://youtu.be/\(videoID)")!
    }

    public func canonicalized() -> NoteYouTubeAttachment {
        NoteYouTubeAttachment(
            id: id,
            videoID: videoID,
            startSeconds: startSeconds.flatMap { $0 > 0 ? $0 : nil },
            caption: NoteImageAttachment.canonicalCaption(caption)
        )
    }
}

// MARK: - Validation

/// Structured validation failure suitable for CLI and UI presentation.
public struct NodeNoteValidationError: Error, LocalizedError, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case nodeNotFound = "note.node_not_found"
        case bodyTooLong = "note.body_too_long"
        case tooManyAttachments = "note.too_many_attachments"
        case duplicateAttachmentID = "note.duplicate_attachment_id"
        case invalidImage = "note.image_invalid"
        case imageTooLarge = "note.image_too_large"
        case imageDimensions = "note.image_dimensions"
        case documentImageBudget = "note.document_image_budget"
        case altTextRequired = "note.alt_text_required"
        case altTextTooLong = "note.alt_text_too_long"
        case captionTooLong = "note.caption_too_long"
        case invalidYouTubeReference = "note.youtube_invalid"
        case invalidYouTubeStart = "note.youtube_start_invalid"
        case invalidAttachmentIndex = "note.attachment_index_invalid"
        case attachmentNotFound = "note.attachment_not_found"
    }

    public var code: Code
    public var path: String
    public var message: String

    public init(code: Code, path: String, message: String) {
        self.code = code
        self.path = path
        self.message = message
    }

    public var errorDescription: String? {
        "\(message) [\(code.rawValue) at \(path)]"
    }
}

public enum NodeNoteValidator {
    public static let maxBodyCharacters = 100_000
    public static let maxAttachmentsPerNote = 32
    public static let maxAltTextCharacters = 1_000
    public static let maxCaptionCharacters = 2_000
    public static let maxYouTubeStartSeconds = 604_800
    public static let maxImageLongEdge = 2_048
    public static let maxImagePixels = 4_194_304
    public static let maxImageBytes = 5_000_000
    public static let maxDocumentImageBytes = 20_000_000

    public static func validate(note: NodeNote, path: String = "$.note") throws {
        try validateBody(note.bodyMarkdown, path: "\(path).bodyMarkdown")
        guard note.attachments.count <= maxAttachmentsPerNote else {
            throw NodeNoteValidationError(
                code: .tooManyAttachments,
                path: "\(path).attachments",
                message: "A note can contain at most \(maxAttachmentsPerNote) attachments."
            )
        }

        var ids = Set<UUID>()
        for (index, attachment) in note.attachments.enumerated() {
            let attachmentPath = "\(path).attachments[\(index)]"
            guard ids.insert(attachment.id).inserted else {
                throw NodeNoteValidationError(
                    code: .duplicateAttachmentID,
                    path: "\(attachmentPath).id",
                    message: "Attachment identifiers must be unique within a note."
                )
            }
            try validate(attachment: attachment, path: attachmentPath)
        }
    }

    public static func validateBody(
        _ bodyMarkdown: String,
        path: String = "$.note.bodyMarkdown"
    ) throws {
        guard bodyMarkdown.count <= maxBodyCharacters else {
            throw NodeNoteValidationError(
                code: .bodyTooLong,
                path: path,
                message: "Note text exceeds \(maxBodyCharacters) characters."
            )
        }
    }

    public static func validate(attachment: NodeNoteAttachment, path: String = "$.attachment") throws {
        switch attachment {
        case .image(let image):
            try validate(image: image, path: path)
        case .youtube(let youtube):
            try validate(youtube: youtube, path: path)
        }
    }

    public static func validate(root: BrainstormNode) throws {
        var documentImageBytes = 0

        func walk(_ node: BrainstormNode, path: String) throws {
            if let note = node.note {
                let notePath = "\(path).note"
                try validate(note: note, path: notePath)
                for attachment in note.attachments {
                    if case .image(let image) = attachment,
                       let byteCount = image.pngData?.count
                    {
                        documentImageBytes += byteCount
                    }
                }
            }
            for (index, child) in node.children.enumerated() {
                try walk(child, path: "\(path).children[\(index)]")
            }
        }

        try walk(root, path: "$.root")
        guard documentImageBytes <= maxDocumentImageBytes else {
            throw NodeNoteValidationError(
                code: .documentImageBudget,
                path: "$.root",
                message: "Embedded note images exceed the \(maxDocumentImageBytes)-byte document budget."
            )
        }
    }

    private static func validate(image: NoteImageAttachment, path: String) throws {
        let (pixelCount, pixelCountOverflow) = image.pixelWidth.multipliedReportingOverflow(
            by: image.pixelHeight
        )
        guard !pixelCountOverflow,
              image.pixelWidth > 0,
              image.pixelHeight > 0,
              image.pixelWidth <= maxImageLongEdge,
              image.pixelHeight <= maxImageLongEdge,
              pixelCount <= maxImagePixels
        else {
            throw NodeNoteValidationError(
                code: .imageDimensions,
                path: path,
                message: "Image dimensions exceed the supported bounds."
            )
        }
        guard image.pngBase64.utf8.count <= ((maxImageBytes + 2) / 3) * 4 + 8,
              let data = image.pngData
        else {
            throw NodeNoteValidationError(
                code: .invalidImage,
                path: "\(path).pngBase64",
                message: "Image data is not valid base64."
            )
        }
        guard data.count <= maxImageBytes else {
            throw NodeNoteValidationError(
                code: .imageTooLarge,
                path: "\(path).pngBase64",
                message: "Normalized PNG exceeds \(maxImageBytes) bytes."
            )
        }
        try NodeNoteImageNormalizer.validateNormalizedPNG(
            data,
            width: image.pixelWidth,
            height: image.pixelHeight,
            path: path
        )

        let trimmedAlt = image.altText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAlt.isEmpty else {
            throw NodeNoteValidationError(
                code: .altTextRequired,
                path: "\(path).altText",
                message: "Image alternative text is required."
            )
        }
        guard image.altText.count <= maxAltTextCharacters else {
            throw NodeNoteValidationError(
                code: .altTextTooLong,
                path: "\(path).altText",
                message: "Image alternative text exceeds \(maxAltTextCharacters) characters."
            )
        }
        try validateCaption(image.caption, path: "\(path).caption")
    }

    private static func validate(youtube: NoteYouTubeAttachment, path: String) throws {
        guard YouTubeReferenceParser.isValidVideoID(youtube.videoID) else {
            throw NodeNoteValidationError(
                code: .invalidYouTubeReference,
                path: "\(path).videoID",
                message: "YouTube video ID must contain exactly eleven URL-safe characters."
            )
        }
        if let startSeconds = youtube.startSeconds,
           !(0...maxYouTubeStartSeconds).contains(startSeconds)
        {
            throw NodeNoteValidationError(
                code: .invalidYouTubeStart,
                path: "\(path).startSeconds",
                message: "YouTube start time must be between 0 and \(maxYouTubeStartSeconds) seconds."
            )
        }
        try validateCaption(youtube.caption, path: "\(path).caption")
    }

    private static func validateCaption(_ caption: String?, path: String) throws {
        guard let caption else { return }
        guard caption.count <= maxCaptionCharacters else {
            throw NodeNoteValidationError(
                code: .captionTooLong,
                path: path,
                message: "Attachment caption exceeds \(maxCaptionCharacters) characters."
            )
        }
    }
}

import AppKit
import Foundation

extension BrainstormNoteInclusion {
    func includes(_ note: NodeNote) -> Bool {
        guard !note.isEmpty else { return false }
        switch self {
        case .visible:
            return note.visibility == .shown
        case .all:
            return true
        case .none:
            return false
        }
    }
}

enum NodeNoteInlineStyle: Equatable, Sendable {
    case plain
    case bold
    case italic
    case boldItalic
}

struct NodeNoteInlineRun: Equatable, Sendable {
    let text: String
    let style: NodeNoteInlineStyle
    let linkDestination: URL?

    init(
        text: String,
        style: NodeNoteInlineStyle,
        linkDestination: URL? = nil
    ) {
        self.text = text
        self.style = style
        self.linkDestination = linkDestination
    }
}

enum NodeNoteBlock: Equatable, Sendable {
    /// Consecutive source lines in one paragraph. Manual line breaks are retained.
    case paragraph([[NodeNoteInlineRun]])
    case unordered([[NodeNoteInlineRun]])
    case ordered(start: Int, [[NodeNoteInlineRun]])
}

/// One allow-listed parser used by native, Markdown, and HTML note renderers.
enum NodeNoteRendering {
    /// A real HTTPS identity for native YouTube embeds. Loading a small local
    /// iframe document against this base URL gives WebKit a stable origin and
    /// lets it send the HTTP referrer now required by YouTube players.
    static let nativeYouTubeClientPageURL = URL(
        string: "https://selfhosted.ninja/projects/brainstorm/"
    )!

    struct Metrics: Sendable {
        let fontSize: CGFloat
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        let blockSpacing: CGFloat
        let attachmentSpacing: CGFloat
        let maximumImageHeight: CGFloat
        let youtubeCardHeight: CGFloat
    }

    static func metrics(for mode: NodeNoteRenderMode) -> Metrics {
        switch mode {
        case .preview:
            Metrics(
                fontSize: 13,
                horizontalPadding: 14,
                verticalPadding: 14,
                blockSpacing: 7,
                attachmentSpacing: 10,
                maximumImageHeight: 260,
                youtubeCardHeight: 92
            )
        case .canvas:
            Metrics(
                fontSize: 12,
                horizontalPadding: 12,
                verticalPadding: 12,
                blockSpacing: 6,
                attachmentSpacing: 8,
                maximumImageHeight: 180,
                youtubeCardHeight: 78
            )
        case .presentation:
            Metrics(
                fontSize: 18,
                horizontalPadding: 24,
                verticalPadding: 22,
                blockSpacing: 10,
                attachmentSpacing: 14,
                maximumImageHeight: 420,
                youtubeCardHeight: 118
            )
        case .staticExport:
            Metrics(
                fontSize: 12,
                horizontalPadding: 12,
                verticalPadding: 12,
                blockSpacing: 6,
                attachmentSpacing: 8,
                maximumImageHeight: 180,
                youtubeCardHeight: 78
            )
        }
    }

    static func blocks(from markdown: String) -> [NodeNoteBlock] {
        do {
            let document = try SafeMarkdownParser.parse(markdown)
            return document.blocks.map { block in
                switch block {
                case .paragraph(let content):
                    return .paragraph(splitIntoLines(content))
                case .unorderedList(let items):
                    return .unordered(
                        items.map { inlineRuns(from: $0.content) }
                    )
                case .orderedList(let start, let items):
                    let renderedItems = items.map {
                        inlineRuns(from: $0.content)
                    }
                    // The parser accepts every positive Int as an ordered-list
                    // start. A hostile start near Int.max must not trap when
                    // renderers derive the following item numbers.
                    guard orderedListCanRepresentEveryNumber(
                        start: start,
                        itemCount: renderedItems.count
                    ) else {
                        return .unordered(renderedItems)
                    }
                    return .ordered(start: start, renderedItems)
                }
            }
        } catch {
            // Invalid oversized input can still be inspected safely. Treat every
            // character literally instead of interpreting unsupported syntax.
            return [
                .paragraph(
                    normalizedLines(markdown).map {
                        [NodeNoteInlineRun(text: $0, style: .plain)]
                    }
                ),
            ]
        }
    }

    static func sanitizedMarkdownBody(_ value: String) -> String {
        blocks(from: value)
            .map { block in
                switch block {
                case .paragraph(let lines):
                    return lines.map {
                        SafeMarkdownEscaping.escapeParagraphListMarker(
                            markdownInline($0)
                        )
                    }
                    .joined(separator: "\n")
                case .unordered(let items):
                    return items.map { "- \(markdownInline($0))" }.joined(separator: "\n")
                case .ordered(let start, let items):
                    return items.enumerated()
                        .map { "\(start + $0.offset). \(markdownInline($0.element))" }
                        .joined(separator: "\n")
                }
            }
            .joined(separator: "\n\n")
    }

    static func htmlBody(_ value: String) -> String {
        blocks(from: value)
            .map { block in
                switch block {
                case .paragraph(let lines):
                    let content = lines.map(htmlInline).joined(separator: "<br>")
                    return "<p>\(content)</p>"
                case .unordered(let items):
                    let content = items.map { "<li>\(htmlInline($0))</li>" }
                        .joined()
                    return "<ul>\(content)</ul>"
                case .ordered(let start, let items):
                    let content = items.map { "<li>\(htmlInline($0))</li>" }
                        .joined()
                    let startAttribute = start == 1 ? "" : " start=\"\(start)\""
                    return "<ol\(startAttribute)>\(content)</ol>"
                }
            }
            .joined(separator: "\n")
    }

    static func measuredHeight(
        note: NodeNote,
        width: CGFloat,
        mode: NodeNoteRenderMode
    ) -> CGFloat {
        let metrics = metrics(for: mode)
        let contentWidth = max(1, width - metrics.horizontalPadding * 2)
        var height = metrics.verticalPadding * 2
        var hasPreviousContent = false

        let body = attributedBody(note.bodyMarkdown, fontSize: metrics.fontSize)
        if body.length > 0 {
            let bounds = body.boundingRect(
                with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            height += max(ceil(bounds.height), ceil(metrics.fontSize * 1.3))
            hasPreviousContent = true
        }

        for attachment in note.attachments {
            if hasPreviousContent {
                height += metrics.attachmentSpacing
            }
            switch attachment {
            case .image(let image):
                let pixelWidth = max(1, CGFloat(image.pixelWidth))
                let pixelHeight = max(1, CGFloat(image.pixelHeight))
                height += min(
                    metrics.maximumImageHeight,
                    contentWidth * pixelHeight / pixelWidth
                )
                if let caption = nonEmpty(image.caption) {
                    height += metrics.blockSpacing
                    height += measuredCaptionHeight(
                        caption,
                        width: contentWidth,
                        fontSize: max(10, metrics.fontSize - 1)
                    )
                }
            case .youtube(let youtube):
                height += metrics.youtubeCardHeight
                if let caption = nonEmpty(youtube.caption) {
                    height += metrics.blockSpacing
                    height += measuredCaptionHeight(
                        caption,
                        width: contentWidth,
                        fontSize: max(10, metrics.fontSize - 1)
                    )
                }
            }
            hasPreviousContent = true
        }

        return ceil(max(1, height))
    }

    static func canonicalYouTubeURL(
        videoID: String,
        startSeconds: Int?
    ) -> String {
        var value = "https://youtu.be/\(videoID)"
        if let startSeconds, startSeconds > 0 {
            value += "?t=\(startSeconds)s"
        }
        return value
    }

    static func embedYouTubeURL(
        videoID: String,
        startSeconds: Int?
    ) -> String {
        var value = "https://www.youtube-nocookie.com/embed/\(videoID)"
        if let startSeconds, startSeconds > 0 {
            value += "?start=\(startSeconds)"
        }
        return value
    }

    static func nativeYouTubePlayerDocument(
        videoID: String,
        startSeconds: Int?
    ) -> String {
        let clientURL = nativeYouTubeClientPageURL
        let origin =
            "\(clientURL.scheme ?? "https")://\(clientURL.host ?? "selfhosted.ninja")"
        var components = URLComponents(
            string: embedYouTubeURL(
                videoID: videoID,
                startSeconds: startSeconds
            )
        )!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "origin", value: origin),
            URLQueryItem(
                name: "widget_referrer",
                value: clientURL.absoluteString
            ),
        ]
        let source = escapeHTML(components.url!.absoluteString)
        return """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta
              name="referrer"
              content="strict-origin-when-cross-origin"
            >
            <meta
              name="viewport"
              content="width=device-width, initial-scale=1"
            >
            <style>
              html, body, iframe {
                width: 100%;
                height: 100%;
                margin: 0;
                border: 0;
                padding: 0;
                overflow: hidden;
                background: #000;
              }
            </style>
          </head>
          <body>
            <iframe
              src="\(source)"
              title="YouTube video player"
              allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
              allowfullscreen
              referrerpolicy="strict-origin-when-cross-origin"
            ></iframe>
          </body>
        </html>
        """
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func splitIntoLines(
        _ content: [SafeMarkdownInline]
    ) -> [[NodeNoteInlineRun]] {
        var lines: [[NodeNoteInlineRun]] = [[]]
        appendSafeInline(
            content,
            isBold: false,
            isItalic: false,
            linkDestination: nil
        ) { value, style, destination in
            if value == "\n" {
                lines.append([])
            } else {
                appendRun(
                    value,
                    style: style,
                    linkDestination: destination,
                    to: &lines[lines.count - 1]
                )
            }
        }
        return lines
    }

    private static func inlineRuns(
        from content: [SafeMarkdownInline]
    ) -> [NodeNoteInlineRun] {
        var runs: [NodeNoteInlineRun] = []
        appendSafeInline(
            content,
            isBold: false,
            isItalic: false,
            linkDestination: nil
        ) { value, style, destination in
            appendRun(
                value,
                style: style,
                linkDestination: destination,
                to: &runs
            )
        }
        return runs
    }

    private static func appendSafeInline(
        _ content: [SafeMarkdownInline],
        isBold: Bool,
        isItalic: Bool,
        linkDestination: URL?,
        append: (String, NodeNoteInlineStyle, URL?) -> Void
    ) {
        for inline in content {
            switch inline {
            case .text(let value):
                let style: NodeNoteInlineStyle
                switch (isBold, isItalic) {
                case (true, true): style = .boldItalic
                case (true, false): style = .bold
                case (false, true): style = .italic
                case (false, false): style = .plain
                }
                append(value, style, linkDestination)
            case .bold(let children):
                appendSafeInline(
                    children,
                    isBold: true,
                    isItalic: isItalic,
                    linkDestination: linkDestination,
                    append: append
                )
            case .italic(let children):
                appendSafeInline(
                    children,
                    isBold: isBold,
                    isItalic: true,
                    linkDestination: linkDestination,
                    append: append
                )
            case .link(let label, let destination):
                appendSafeInline(
                    label,
                    isBold: isBold,
                    isItalic: isItalic,
                    linkDestination: destination,
                    append: append
                )
            case .lineBreak:
                append("\n", .plain, linkDestination)
            }
        }
    }

    // MARK: - Native measurement

    private static func attributedBody(
        _ markdown: String,
        fontSize: CGFloat
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseFont = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        let boldFont = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        let boldItalicFont = NSFontManager.shared.convert(
            boldFont,
            toHaveTrait: [.boldFontMask, .italicFontMask]
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2
        paragraphStyle.paragraphSpacing = 5

        func append(
            _ runs: [NodeNoteInlineRun],
            prefix: String = "",
            suffix: String
        ) {
            if !prefix.isEmpty {
                result.append(
                    NSAttributedString(
                        string: prefix,
                        attributes: [.font: baseFont, .paragraphStyle: paragraphStyle]
                    )
                )
            }
            for run in runs {
                let font: NSFont
                switch run.style {
                case .plain: font = baseFont
                case .bold: font = boldFont
                case .italic: font = italicFont
                case .boldItalic: font = boldItalicFont
                }
                result.append(
                    NSAttributedString(
                        string: run.text,
                        attributes: [.font: font, .paragraphStyle: paragraphStyle]
                    )
                )
            }
            result.append(
                NSAttributedString(
                    string: suffix,
                    attributes: [.font: baseFont, .paragraphStyle: paragraphStyle]
                )
            )
        }

        for (blockIndex, block) in blocks(from: markdown).enumerated() {
            if blockIndex > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            switch block {
            case .paragraph(let lines):
                for (lineIndex, line) in lines.enumerated() {
                    append(line, suffix: lineIndex == lines.count - 1 ? "" : "\n")
                }
            case .unordered(let items):
                for (itemIndex, item) in items.enumerated() {
                    append(
                        item,
                        prefix: "• ",
                        suffix: itemIndex == items.count - 1 ? "" : "\n"
                    )
                }
            case .ordered(let start, let items):
                for (itemIndex, item) in items.enumerated() {
                    append(
                        item,
                        prefix: "\(start + itemIndex). ",
                        suffix: itemIndex == items.count - 1 ? "" : "\n"
                    )
                }
            }
        }
        return result
    }

    private static func measuredCaptionHeight(
        _ value: String,
        width: CGFloat,
        fontSize: CGFloat
    ) -> CGFloat {
        let bounds = (value as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: fontSize)]
        )
        return ceil(bounds.height)
    }

    // MARK: - Safe subset serialization

    private static func markdownInline(_ runs: [NodeNoteInlineRun]) -> String {
        return runs.map { run in
            let escaped = escapeMarkdownLiteral(run.text)
            let styled = switch run.style {
            case .plain: escaped
            case .bold: "**\(escaped)**"
            case .italic: "_\(escaped)_"
            case .boldItalic: "**_\(escaped)_**"
            }
            guard let destination = run.linkDestination else { return styled }
            return "[\(styled)](\(escapeMarkdownDestination(destination.absoluteString)))"
        }
        .joined()
    }

    private static func htmlInline(_ runs: [NodeNoteInlineRun]) -> String {
        return runs.map { run in
            let escaped = escapeHTML(run.text)
            let styled = switch run.style {
            case .plain: escaped
            case .bold: "<strong>\(escaped)</strong>"
            case .italic: "<em>\(escaped)</em>"
            case .boldItalic: "<strong><em>\(escaped)</em></strong>"
            }
            guard let destination = run.linkDestination else { return styled }
            return """
            <a href="\(escapeHTML(destination.absoluteString))" target="_blank" rel="noopener noreferrer">\(styled)</a>
            """
        }
        .joined()
    }

    private static func escapeMarkdownDestination(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: " ", with: "%20")
    }

    private static func escapeMarkdownLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "!", with: "\\!")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "#", with: "\\#")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func orderedListCanRepresentEveryNumber(
        start: Int,
        itemCount: Int
    ) -> Bool {
        guard itemCount > 1 else { return true }
        return !start.addingReportingOverflow(itemCount - 1).overflow
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func appendRun(
        _ text: String,
        style: NodeNoteInlineStyle,
        linkDestination: URL?,
        to runs: inout [NodeNoteInlineRun]
    ) {
        guard !text.isEmpty else { return }
        if let last = runs.last,
           last.style == style,
           last.linkDestination == linkDestination
        {
            runs[runs.count - 1] = NodeNoteInlineRun(
                text: last.text + text,
                style: style,
                linkDestination: linkDestination
            )
        } else {
            runs.append(NodeNoteInlineRun(
                text: text,
                style: style,
                linkDestination: linkDestination
            ))
        }
    }

    private static func unorderedItem(in line: String) -> String? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else {
            return nil
        }
        return String(trimmed.dropFirst(2))
    }

    private static func orderedItem(in line: String) -> String? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let dot = trimmed.firstIndex(of: "."),
              dot > trimmed.startIndex,
              trimmed[trimmed.startIndex..<dot].allSatisfy(\.isNumber)
        else {
            return nil
        }
        let afterDot = trimmed.index(after: dot)
        guard afterDot < trimmed.endIndex, trimmed[afterDot] == " " else {
            return nil
        }
        return String(trimmed[trimmed.index(after: afterDot)...])
    }

    private static func normalizedLines(_ value: String) -> [String] {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }
}

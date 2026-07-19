import AppKit
import Foundation

/// Converts Brainstorm's intentionally small Markdown subset to an editable,
/// source-free attributed representation and back again.
///
/// The text view never contains Markdown delimiters or list prefixes. Bold,
/// italic, links, and lists are represented by AppKit attributes; the `.bs`
/// document continues to store deterministic Markdown in `bodyMarkdown`.
@MainActor
enum NodeNoteRichTextCodec {
    private struct FontTraits: OptionSet {
        let rawValue: Int

        static let bold = FontTraits(rawValue: 1 << 0)
        static let italic = FontTraits(rawValue: 1 << 1)
    }

    private enum InlineMarker: Equatable {
        case bold
        case italic

        var source: String {
            switch self {
            case .bold: "**"
            case .italic: "_"
            }
        }
    }

    private struct StyledRun {
        var text: String
        var traits: FontTraits
    }

    struct YouTubeDetection: Equatable {
        let reference: String
        let range: NSRange
        let retainsVisibleText: Bool
    }

    struct YouTubeExtraction: Equatable {
        let references: [String]
        let bodyMarkdown: String
    }

    static var baseFont: NSFont {
        .preferredFont(forTextStyle: .body)
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle(),
        ]
    }

    static func attributedString(from markdown: String) -> NSAttributedString {
        guard let document = try? SafeMarkdownParser.parse(markdown) else {
            return NSAttributedString(
                string: NodeNote.normalizeLineEndings(markdown),
                attributes: baseAttributes
            )
        }

        let output = NSMutableAttributedString(string: "")
        for (blockIndex, block) in document.blocks.enumerated() {
            if blockIndex > 0 {
                output.append(NSAttributedString(string: "\n\n", attributes: baseAttributes))
            }

            switch block {
            case .paragraph(let content):
                append(content, to: output)
            case .unorderedList(let items):
                appendList(items, start: nil, to: output)
            case .orderedList(let start, let items):
                appendList(items, start: start, to: output)
            }
        }

        applyDetectedWebLinks(to: output)
        return output
    }

    static func markdown(from attributedString: NSAttributedString) -> String {
        let body = bodyAttributedString(from: attributedString)
        let source = body.string as NSString
        guard source.length > 0 else { return "" }

        var lines: [String] = []
        var location = 0
        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let contentRange = rangeRemovingLineEnding(lineRange, in: source)
            let prefix = listPrefix(
                in: body,
                contentRange: contentRange,
                fallbackRange: lineRange
            )
            let inline = inlineMarkdown(in: body, range: contentRange)
            lines.append(
                prefix.isEmpty
                    ? SafeMarkdownEscaping.escapeParagraphListMarker(inline)
                    : prefix + inline
            )
            location = NSMaxRange(lineRange)
        }

        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private static func bodyAttributedString(
        from attributedString: NSAttributedString
    ) -> NSAttributedString {
        guard attributedString.length > 0 else {
            return attributedString
        }

        var imageRanges: [NSRange] = []
        attributedString.enumerateAttribute(
            .nodeNoteInlineImageID,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, range, _ in
            if value != nil {
                imageRanges.append(range)
            }
        }
        guard !imageRanges.isEmpty else { return attributedString }

        let body = NSMutableAttributedString(
            attributedString: attributedString
        )
        for range in imageRanges.reversed() {
            body.deleteCharacters(in: range)
        }
        return body
    }

    /// Adds `.link` attributes to bare HTTP(S) URLs while preserving links
    /// that originated as `[label](destination)` Markdown.
    @discardableResult
    static func applyDetectedWebLinks(to attributedString: NSMutableAttributedString) -> Bool {
        let source = attributedString.string as NSString
        guard source.length > 0,
              let expression = try? NSRegularExpression(
                  pattern: #"https?://[^\s<>]+"#,
                  options: [.caseInsensitive]
              )
        else {
            return false
        }

        var changed = false
        for match in expression.matches(
            in: source as String,
            range: NSRange(location: 0, length: source.length)
        ) {
            let range = trimmingURLPunctuation(from: match.range, in: source)
            guard range.length > 0,
                  attributedString.attribute(.link, at: range.location, effectiveRange: nil) == nil,
                  let url = validatedWebURL(source.substring(with: range))
            else {
                continue
            }
            attributedString.addAttribute(.link, value: url, range: range)
            changed = true
        }
        return changed
    }

    /// Finds every supported YouTube destination in document order.
    ///
    /// A Markdown link is already represented as attributed label text here.
    /// Its human-readable label is retained and only the link attribute is
    /// removed after the video attachment is accepted. A bare URL is removed
    /// after acceptance so it is not duplicated beside the embedded player.
    static func youtubeDetections(
        in attributedString: NSAttributedString
    ) -> [YouTubeDetection] {
        let source = attributedString.string as NSString
        guard source.length > 0 else { return [] }

        var detections: [YouTubeDetection] = []
        let fullRange = NSRange(location: 0, length: source.length)
        attributedString.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard let destination = linkURL(from: value),
                  isYouTubeURL(destination)
            else {
                return
            }

            let visibleRange = trimmingWhitespace(from: range, in: source)
            guard visibleRange.length > 0 else { return }
            let visible = source.substring(with: visibleRange)
            let visibleIsYouTubeURL = validatedWebURL(visible).map(isYouTubeURL) == true
            detections.append(
                YouTubeDetection(
                    reference: destination.absoluteString,
                    range: range,
                    retainsVisibleText: !visibleIsYouTubeURL
                )
            )
        }

        guard let expression = try? NSRegularExpression(
            pattern: #"https?://[^\s<>]+"#,
            options: [.caseInsensitive]
        ) else {
            return detections
        }
        for match in expression.matches(
            in: source as String,
            range: fullRange
        ) {
            let range = trimmingURLPunctuation(from: match.range, in: source)
            guard range.length > 0,
                  !detections.contains(where: {
                      NSIntersectionRange($0.range, range).length > 0
                  }),
                  let destination = validatedWebURL(source.substring(with: range)),
                  isYouTubeURL(destination)
            else {
                continue
            }
            detections.append(
                YouTubeDetection(
                    reference: destination.absoluteString,
                    range: range,
                    retainsVisibleText: false
                )
            )
        }

        return detections.sorted {
            if $0.range.location != $1.range.location {
                return $0.range.location < $1.range.location
            }
            if $0.range.length != $1.range.length {
                return $0.range.length > $1.range.length
            }
            return $0.reference < $1.reference
        }
    }

    static func extractingYouTubeReferences(
        from markdown: String
    ) -> YouTubeExtraction {
        let detections = youtubeDetections(
            in: attributedString(from: markdown)
        )
        return YouTubeExtraction(
            references: detections.map(\.reference),
            // A detected player is additional presentation behavior. The
            // author-visible link remains ordinary WYSIWYG note content.
            bodyMarkdown: markdown
        )
    }

    /// Returns supported YouTube destinations without changing visible note
    /// text. The production Markdown editor keeps these links clickable while
    /// Brainstorm adds a corresponding typed player attachment once.
    static func youtubeReferences(in markdown: String) -> [String] {
        youtubeDetections(
            in: attributedString(from: markdown)
        ).map(\.reference)
    }

    static func font(
        byToggling trait: NSFontTraitMask,
        in font: NSFont,
        removing: Bool
    ) -> NSFont {
        let manager = NSFontManager.shared
        return removing
            ? manager.convert(font, toNotHaveTrait: trait)
            : manager.convert(font, toHaveTrait: trait)
    }

    static func fontHasTrait(_ trait: NSFontTraitMask, font: NSFont) -> Bool {
        let traits = font.fontDescriptor.symbolicTraits
        if trait == .boldFontMask {
            return traits.contains(.bold)
        }
        if trait == .italicFontMask {
            return traits.contains(.italic)
        }
        return false
    }

    static func paragraphStyle(
        textList: NSTextList? = nil,
        basedOn existing: NSParagraphStyle? = nil
    ) -> NSMutableParagraphStyle {
        let style = (existing?.mutableCopy() as? NSMutableParagraphStyle)
            ?? NSMutableParagraphStyle()
        style.lineSpacing = 1
        style.paragraphSpacing = textList == nil ? 0 : 3
        style.textLists = textList.map { [$0] } ?? []
        style.firstLineHeadIndent = 0
        style.headIndent = textList == nil ? 0 : 24
        return style
    }

    private static func appendList(
        _ items: [SafeMarkdownListItem],
        start: Int?,
        to output: NSMutableAttributedString
    ) {
        let textList = NSTextList(
            markerFormat: start == nil ? .disc : .decimal,
            options: [],
            startingItemNumber: max(1, start ?? 1)
        )
        let style = paragraphStyle(textList: textList)

        for (index, item) in items.enumerated() {
            let itemStart = output.length
            append(item.content, to: output)
            if index + 1 < items.count {
                output.append(NSAttributedString(string: "\n", attributes: baseAttributes))
            }
            let itemLength = output.length - itemStart
            if itemLength > 0 {
                output.addAttribute(
                    .paragraphStyle,
                    value: style,
                    range: NSRange(location: itemStart, length: itemLength)
                )
            }
        }
    }

    private static func append(
        _ inlines: [SafeMarkdownInline],
        traits: FontTraits = [],
        link: URL? = nil,
        to output: NSMutableAttributedString
    ) {
        for inline in inlines {
            switch inline {
            case .text(let value):
                var attributes = baseAttributes
                attributes[.font] = font(for: traits)
                if let link {
                    attributes[.link] = link
                }
                output.append(NSAttributedString(string: value, attributes: attributes))
            case .bold(let children):
                append(children, traits: traits.union(.bold), link: link, to: output)
            case .italic(let children):
                append(children, traits: traits.union(.italic), link: link, to: output)
            case .link(let label, let destination):
                append(label, traits: traits, link: destination, to: output)
            case .lineBreak:
                var attributes = baseAttributes
                attributes[.font] = font(for: traits)
                if let link {
                    attributes[.link] = link
                }
                output.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
    }

    private static func font(for traits: FontTraits) -> NSFont {
        let manager = NSFontManager.shared
        var result = baseFont
        if traits.contains(.bold) {
            result = manager.convert(result, toHaveTrait: .boldFontMask)
        }
        if traits.contains(.italic) {
            result = manager.convert(result, toHaveTrait: .italicFontMask)
        }
        return result
    }

    private static func listPrefix(
        in attributedString: NSAttributedString,
        contentRange: NSRange,
        fallbackRange: NSRange
    ) -> String {
        guard attributedString.length > 0 else { return "" }
        let candidate = contentRange.length > 0 ? contentRange.location : fallbackRange.location
        let location = min(candidate, attributedString.length - 1)
        guard let style = attributedString.attribute(
            .paragraphStyle,
            at: location,
            effectiveRange: nil
        ) as? NSParagraphStyle,
            let textList = style.textLists.last
        else {
            return ""
        }

        guard textList.isOrdered else { return "- " }
        let item = max(1, attributedString.itemNumber(in: textList, at: location))
        let number = max(1, textList.startingItemNumber) + item - 1
        return "\(number). "
    }

    private static func inlineMarkdown(
        in attributedString: NSAttributedString,
        range: NSRange
    ) -> String {
        guard range.length > 0 else { return "" }
        let end = NSMaxRange(range)
        var location = range.location
        var result = ""

        while location < end {
            var effectiveRange = NSRange(location: location, length: 0)
            let value = attributedString.attribute(
                .link,
                at: location,
                longestEffectiveRange: &effectiveRange,
                in: range
            )
            effectiveRange = NSIntersectionRange(effectiveRange, range)
            let styled = styledMarkdown(in: attributedString, range: effectiveRange)
            if let destination = linkURL(from: value), !styled.isEmpty {
                result += "[\(styled)](\(destination.absoluteString))"
            } else {
                result += styled
            }
            location = NSMaxRange(effectiveRange)
        }
        return result
    }

    private static func styledMarkdown(
        in attributedString: NSAttributedString,
        range: NSRange
    ) -> String {
        guard range.length > 0 else { return "" }

        var runs: [StyledRun] = []
        attributedString.enumerateAttribute(.font, in: range) { value, runRange, _ in
            let font = value as? NSFont ?? baseFont
            var traits: FontTraits = []
            if fontHasTrait(.boldFontMask, font: font) {
                traits.insert(.bold)
            }
            if fontHasTrait(.italicFontMask, font: font) {
                traits.insert(.italic)
            }
            let text = (attributedString.string as NSString).substring(with: runRange)
            if runs.last?.traits == traits {
                runs[runs.count - 1].text += text
            } else {
                runs.append(StyledRun(text: text, traits: traits))
            }
        }

        var output = ""
        var active: [InlineMarker] = []
        for run in runs {
            let desired = markers(for: run.traits)
            let commonCount = zip(active, desired).prefix { $0 == $1 }.count
            for marker in active[commonCount...].reversed() {
                output += marker.source
            }
            for marker in desired[commonCount...] {
                output += marker.source
            }
            output += SafeMarkdownEscaping.escapeInlineLiteral(run.text)
            active = desired
        }
        for marker in active.reversed() {
            output += marker.source
        }
        return output
    }

    private static func markers(for traits: FontTraits) -> [InlineMarker] {
        var result: [InlineMarker] = []
        if traits.contains(.bold) {
            result.append(.bold)
        }
        if traits.contains(.italic) {
            result.append(.italic)
        }
        return result
    }

    private static func isYouTubeURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased()
        else {
            return false
        }
        let allowed = host == "youtu.be"
            || host.hasSuffix(".youtu.be")
            || host == "youtube.com"
            || host.hasSuffix(".youtube.com")
            || host == "youtube-nocookie.com"
            || host.hasSuffix(".youtube-nocookie.com")
        guard allowed else { return false }
        return (try? YouTubeReferenceParser.parse(url.absoluteString)) != nil
    }

    private static func linkURL(from value: Any?) -> URL? {
        if let url = value as? URL {
            return validatedWebURL(url.absoluteString)
        }
        if let url = value as? NSURL {
            return validatedWebURL(url.absoluteString ?? "")
        }
        if let value = value as? String {
            return validatedWebURL(value)
        }
        return nil
    }

    private static func validatedWebURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false
        else {
            return nil
        }
        return components.url
    }

    private static func rangeRemovingLineEnding(
        _ range: NSRange,
        in source: NSString
    ) -> NSRange {
        var length = range.length
        while length > 0 {
            let character = source.character(at: range.location + length - 1)
            guard character == 10 || character == 13 else { break }
            length -= 1
        }
        return NSRange(location: range.location, length: length)
    }

    private static func trimmingWhitespace(
        from range: NSRange,
        in source: NSString
    ) -> NSRange {
        var lower = range.location
        var upper = NSMaxRange(range)
        let whitespace = CharacterSet.whitespaces
        while lower < upper,
              let scalar = UnicodeScalar(source.character(at: lower)),
              whitespace.contains(scalar)
        {
            lower += 1
        }
        while upper > lower,
              let scalar = UnicodeScalar(source.character(at: upper - 1)),
              whitespace.contains(scalar)
        {
            upper -= 1
        }
        return NSRange(location: lower, length: upper - lower)
    }

    private static func trimmingURLPunctuation(
        from range: NSRange,
        in source: NSString
    ) -> NSRange {
        var length = range.length
        let sentencePunctuation = CharacterSet(charactersIn: ".,;:!?")
        while length > 0 {
            let last = source.character(at: range.location + length - 1)
            if let scalar = UnicodeScalar(last),
               sentencePunctuation.contains(scalar)
            {
                length -= 1
                continue
            }

            let opening: unichar
            switch last {
            case 0x29: opening = 0x28 // )
            case 0x5D: opening = 0x5B // ]
            case 0x7D: opening = 0x7B // }
            default:
                return NSRange(location: range.location, length: length)
            }

            let candidate = NSRange(location: range.location, length: length)
            var openingCount = 0
            var closingCount = 0
            for index in candidate.location..<NSMaxRange(candidate) {
                switch source.character(at: index) {
                case opening:
                    openingCount += 1
                case last:
                    closingCount += 1
                default:
                    break
                }
            }
            guard closingCount > openingCount else {
                return candidate
            }
            length -= 1
        }
        return NSRange(location: range.location, length: length)
    }
}

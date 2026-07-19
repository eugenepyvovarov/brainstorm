import Foundation

/// Allow-listed render tree for Brainstorm's intentionally small Markdown subset.
public struct SafeMarkdownDocument: Equatable, Sendable {
    public var blocks: [SafeMarkdownBlock]

    public init(blocks: [SafeMarkdownBlock] = []) {
        self.blocks = blocks
    }
}

public enum SafeMarkdownBlock: Equatable, Sendable {
    case paragraph([SafeMarkdownInline])
    case unorderedList([SafeMarkdownListItem])
    case orderedList(start: Int, items: [SafeMarkdownListItem])
}

public struct SafeMarkdownListItem: Equatable, Sendable {
    public var content: [SafeMarkdownInline]

    public init(content: [SafeMarkdownInline]) {
        self.content = content
    }
}

public indirect enum SafeMarkdownInline: Equatable, Sendable {
    case text(String)
    case bold([SafeMarkdownInline])
    case italic([SafeMarkdownInline])
    /// A validated web link. Only HTTP(S) destinations enter the render tree.
    case link(label: [SafeMarkdownInline], destination: URL)
    case lineBreak

    public var plainText: String {
        switch self {
        case .text(let value):
            return value
        case .bold(let children), .italic(let children):
            return children.map(\.plainText).joined()
        case .link(let label, _):
            return label.map(\.plainText).joined()
        case .lineBreak:
            return "\n"
        }
    }
}

/// Canonical escaping shared by the WYSIWYG editor and safe parser.
///
/// Brainstorm stores Markdown for portability, but a visible punctuation
/// character is not formatting unless the editor assigned that semantic
/// attribute. Plain delimiters are therefore backslash-escaped on write and
/// restored as literal text on read.
enum SafeMarkdownEscaping {
    static func escapeInlineLiteral(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            if character == "\\"
                || character == "*"
                || character == "_"
                || character == "["
                || character == "]"
            {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    static func escapeParagraphListMarker(_ value: String) -> String {
        let indentationEnd = value.firstIndex {
            $0 != " " && $0 != "\t"
        } ?? value.endIndex
        guard indentationEnd < value.endIndex else { return value }

        let remainder = value[indentationEnd...]
        if remainder.hasPrefix("- ") || remainder.hasPrefix("+ ") {
            return insertingBackslash(in: value, at: indentationEnd)
        }
        // `*` is escaped by `escapeInlineLiteral`, but retain this safeguard
        // for callers that serialize an already-styled line.
        if remainder.hasPrefix("* ") {
            return insertingBackslash(in: value, at: indentationEnd)
        }

        var cursor = indentationEnd
        while cursor < value.endIndex, value[cursor].isNumber {
            cursor = value.index(after: cursor)
        }
        guard cursor > indentationEnd,
              cursor < value.endIndex,
              value[cursor] == "."
        else {
            return value
        }
        let afterDot = value.index(after: cursor)
        guard afterDot < value.endIndex, value[afterDot] == " " else {
            return value
        }
        return insertingBackslash(in: value, at: cursor)
    }

    static func unescapeInlineLiteral(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        var cursor = value.startIndex

        while cursor < value.endIndex {
            let character = value[cursor]
            guard character == "\\" else {
                result.append(character)
                cursor = value.index(after: cursor)
                continue
            }

            let next = value.index(after: cursor)
            guard next < value.endIndex,
                  isASCIIPunctuation(value[next])
            else {
                result.append("\\")
                cursor = next
                continue
            }
            result.append(value[next])
            cursor = value.index(after: next)
        }
        return result
    }

    static func isEscaped(
        _ index: String.Index,
        in value: Substring
    ) -> Bool {
        var cursor = index
        var backslashCount = 0
        while cursor > value.startIndex {
            let previous = value.index(before: cursor)
            guard value[previous] == "\\" else { break }
            backslashCount += 1
            cursor = previous
        }
        return backslashCount.isMultiple(of: 2) == false
    }

    private static func insertingBackslash(
        in value: String,
        at index: String.Index
    ) -> String {
        String(value[..<index]) + "\\" + String(value[index...])
    }

    private static func isASCIIPunctuation(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.isASCII
        else {
            return false
        }
        switch scalar.value {
        case 33...47, 58...64, 91...96, 123...126:
            return true
        default:
            return false
        }
    }
}

/// Deterministic parser that recognizes only paragraphs, line breaks, bold,
/// italic, and ordered/unordered lists. HTML and unsupported Markdown are text.
public enum SafeMarkdownParser {
    public static func parse(
        _ markdown: String,
        path: String = "$.note.bodyMarkdown"
    ) throws -> SafeMarkdownDocument {
        guard markdown.count <= NodeNoteValidator.maxBodyCharacters else {
            throw NodeNoteValidationError(
                code: .bodyTooLong,
                path: path,
                message: "Note text exceeds \(NodeNoteValidator.maxBodyCharacters) characters."
            )
        }

        let lines = NodeNote.normalizeLineEndings(markdown)
            .components(separatedBy: "\n")
        var blocks: [SafeMarkdownBlock] = []
        var index = 0

        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if let item = unorderedItem(in: lines[index]) {
                var items: [SafeMarkdownListItem] = []
                var current: String? = item
                while let value = current {
                    items.append(SafeMarkdownListItem(content: parseInline(value)))
                    index += 1
                    current = index < lines.count ? unorderedItem(in: lines[index]) : nil
                }
                blocks.append(.unorderedList(items))
                continue
            }

            if let first = orderedItem(in: lines[index]) {
                var items: [SafeMarkdownListItem] = []
                let start = first.number
                var current: (number: Int, body: String)? = first
                while let value = current {
                    items.append(SafeMarkdownListItem(content: parseInline(value.body)))
                    index += 1
                    current = index < lines.count ? orderedItem(in: lines[index]) : nil
                }
                blocks.append(.orderedList(start: start, items: items))
                continue
            }

            var paragraphLines: [String] = []
            while index < lines.count,
                  !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                  unorderedItem(in: lines[index]) == nil,
                  orderedItem(in: lines[index]) == nil
            {
                paragraphLines.append(lines[index])
                index += 1
            }
            var content: [SafeMarkdownInline] = []
            for (lineIndex, line) in paragraphLines.enumerated() {
                if lineIndex > 0 {
                    content.append(.lineBreak)
                }
                content.append(contentsOf: parseInline(line))
            }
            blocks.append(.paragraph(content))
        }

        return SafeMarkdownDocument(blocks: blocks)
    }

    public static func parseInline(_ value: String) -> [SafeMarkdownInline] {
        parseInline(value[value.startIndex...], depth: 0)
    }

    private static func unorderedItem(in line: String) -> String? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.count >= 2 else { return nil }
        let prefix = trimmed.prefix(2)
        guard prefix == "- " || prefix == "* " || prefix == "+ " else { return nil }
        return String(trimmed.dropFirst(2))
    }

    private static func orderedItem(in line: String) -> (number: Int, body: String)? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let dot = trimmed.firstIndex(of: "."),
              dot != trimmed.startIndex
        else {
            return nil
        }
        let numberText = trimmed[..<dot]
        guard numberText.allSatisfy(\.isNumber),
              let number = Int(numberText),
              number > 0
        else {
            return nil
        }
        let afterDot = trimmed.index(after: dot)
        guard afterDot < trimmed.endIndex, trimmed[afterDot] == " " else { return nil }
        return (number, String(trimmed[trimmed.index(after: afterDot)...]))
    }

    private static func parseInline(
        _ value: Substring,
        depth: Int
    ) -> [SafeMarkdownInline] {
        guard !value.isEmpty else { return [] }
        guard depth < 8 else {
            return [.text(SafeMarkdownEscaping.unescapeInlineLiteral(String(value)))]
        }

        var result: [SafeMarkdownInline] = []
        var cursor = value.startIndex

        while cursor < value.endIndex {
            let remaining = value[cursor...]
            var matches: [InlineMatch] = []
            if let range = delimitedRange(in: remaining, delimiter: "**") {
                matches.append(InlineMatch(range: range, kind: .bold))
            }
            if let range = delimitedRange(in: remaining, delimiter: "_") {
                matches.append(InlineMatch(range: range, kind: .italic))
            }
            if let link = linkMatch(in: remaining) {
                matches.append(link)
            }
            guard let selected = matches.min(by: { lhs, rhs in
                if lhs.range.lowerBound == rhs.range.lowerBound {
                    // Prefer the outer link at a shared opener so formatting
                    // inside its label remains part of the same destination.
                    return lhs.kind.priority < rhs.kind.priority
                }
                return lhs.range.lowerBound < rhs.range.lowerBound
            }) else {
                appendText(String(value[cursor...]), to: &result)
                break
            }
            if cursor < selected.range.lowerBound {
                appendText(String(value[cursor..<selected.range.lowerBound]), to: &result)
            }

            switch selected.kind {
            case .bold:
                let contentStart = value.index(selected.range.lowerBound, offsetBy: 2)
                let contentEnd = value.index(selected.range.upperBound, offsetBy: -2)
                let children = parseInline(value[contentStart..<contentEnd], depth: depth + 1)
                result.append(.bold(children))
            case .italic:
                let contentStart = value.index(after: selected.range.lowerBound)
                let contentEnd = value.index(before: selected.range.upperBound)
                let children = parseInline(value[contentStart..<contentEnd], depth: depth + 1)
                result.append(.italic(children))
            case .link(let labelRange, let destination):
                let label = parseInline(value[labelRange], depth: depth + 1)
                result.append(.link(label: label, destination: destination))
            }
            cursor = selected.range.upperBound
        }

        return result
    }

    private static func delimitedRange(
        in value: Substring,
        delimiter: String
    ) -> Range<String.Index>? {
        guard let opener = firstUnescapedRange(
            of: delimiter,
            in: value,
            range: value.startIndex..<value.endIndex
        ) else {
            return nil
        }
        let contentStart = opener.upperBound
        guard contentStart < value.endIndex,
              let closer = firstUnescapedRange(
                of: delimiter,
                in: value,
                range: contentStart..<value.endIndex
              ),
              closer.lowerBound > contentStart
        else {
            return nil
        }
        return opener.lowerBound..<closer.upperBound
    }

    private static func linkMatch(in value: Substring) -> InlineMatch? {
        var searchStart = value.startIndex
        while searchStart < value.endIndex,
              let opener = firstUnescapedIndex(
                  of: "[",
                  in: value,
                  range: searchStart..<value.endIndex
              )
        {
            let labelStart = value.index(after: opener)
            guard let labelEnd = firstUnescapedIndex(
                of: "]",
                in: value,
                range: labelStart..<value.endIndex
            ) else {
                return nil
            }
            let parenthesis = value.index(after: labelEnd)
            guard parenthesis < value.endIndex,
                  value[parenthesis] == "(",
                  !SafeMarkdownEscaping.isEscaped(parenthesis, in: value)
            else {
                searchStart = value.index(after: opener)
                continue
            }
            let destinationStart = value.index(after: parenthesis)
            guard let close = closingLinkParenthesis(
                in: value,
                startingAt: destinationStart
            ) else {
                return nil
            }
            let labelRange = value.index(after: opener)..<labelEnd
            let destinationText = SafeMarkdownEscaping.unescapeInlineLiteral(
                String(value[destinationStart..<close])
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !labelRange.isEmpty,
                  let destination = validatedWebURL(destinationText)
            else {
                searchStart = value.index(after: opener)
                continue
            }
            return InlineMatch(
                range: opener..<value.index(after: close),
                kind: .link(labelRange: labelRange, destination: destination)
            )
        }
        return nil
    }

    private static func closingLinkParenthesis(
        in value: Substring,
        startingAt start: String.Index
    ) -> String.Index? {
        var cursor = start
        var nestedDepth = 0

        while cursor < value.endIndex {
            let character = value[cursor]
            if !SafeMarkdownEscaping.isEscaped(cursor, in: value) {
                if character == "(" {
                    nestedDepth += 1
                } else if character == ")" {
                    if nestedDepth == 0 {
                        return cursor
                    }
                    nestedDepth -= 1
                }
            }
            cursor = value.index(after: cursor)
        }
        return nil
    }

    private static func firstUnescapedRange(
        of delimiter: String,
        in value: Substring,
        range: Range<String.Index>
    ) -> Range<String.Index>? {
        var searchStart = range.lowerBound
        while searchStart < range.upperBound,
              let match = value.range(
                  of: delimiter,
                  range: searchStart..<range.upperBound
              )
        {
            if !SafeMarkdownEscaping.isEscaped(match.lowerBound, in: value) {
                return match
            }
            searchStart = value.index(after: match.lowerBound)
        }
        return nil
    }

    private static func firstUnescapedIndex(
        of character: Character,
        in value: Substring,
        range: Range<String.Index>
    ) -> String.Index? {
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            if value[cursor] == character,
               !SafeMarkdownEscaping.isEscaped(cursor, in: value)
            {
                return cursor
            }
            cursor = value.index(after: cursor)
        }
        return nil
    }

    private static func validatedWebURL(_ value: String) -> URL? {
        guard value.count <= 4_096,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false,
              let url = components.url
        else {
            return nil
        }
        return url
    }

    private static func appendText(_ value: String, to result: inout [SafeMarkdownInline]) {
        let literal = SafeMarkdownEscaping.unescapeInlineLiteral(value)
        guard !literal.isEmpty else { return }
        if case .text(let previous)? = result.last {
            result[result.count - 1] = .text(previous + literal)
        } else {
            result.append(.text(literal))
        }
    }

    private struct InlineMatch {
        let range: Range<String.Index>
        let kind: InlineMatchKind
    }

    private enum InlineMatchKind {
        case link(labelRange: Range<String.Index>, destination: URL)
        case bold
        case italic

        var priority: Int {
            switch self {
            case .link: 0
            case .bold: 1
            case .italic: 2
            }
        }
    }
}

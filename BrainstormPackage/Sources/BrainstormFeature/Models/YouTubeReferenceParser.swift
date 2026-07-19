import Foundation

public struct ParsedYouTubeReference: Equatable, Hashable, Sendable {
    public var videoID: String
    public var startSeconds: Int?

    public init(videoID: String, startSeconds: Int? = nil) {
        self.videoID = videoID
        self.startSeconds = startSeconds
    }
}

/// Parses common YouTube links while persisting only the portable video id and start time.
public enum YouTubeReferenceParser {
    private static let fullHosts: Set<String> = [
        "youtube.com",
        "www.youtube.com",
        "m.youtube.com",
        "music.youtube.com",
        "youtube-nocookie.com",
        "www.youtube-nocookie.com",
    ]

    public static func isValidVideoID(_ value: String) -> Bool {
        guard value.utf8.count == 11, value.count == 11 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 48...57, 65...90, 95, 97...122:
                return true
            default:
                return false
            }
        }
    }

    public static func parse(
        _ input: String,
        path: String = "$.youtube"
    ) throws -> ParsedYouTubeReference {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isValidVideoID(trimmed) {
            return ParsedYouTubeReference(videoID: trimmed)
        }

        let candidate: String
        if trimmed.contains("://") {
            candidate = trimmed
        } else {
            candidate = "https://\(trimmed)"
        }
        guard let components = URLComponents(string: candidate),
              let rawHost = components.host?.lowercased()
        else {
            throw invalidReference(path: path)
        }

        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        let pathSegments = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        let videoID: String?
        if host == "youtu.be" || host == "www.youtu.be" {
            videoID = pathSegments.first
        } else if fullHosts.contains(host) {
            if let first = pathSegments.first?.lowercased(),
               ["embed", "shorts", "live"].contains(first)
            {
                videoID = pathSegments.dropFirst().first
            } else {
                videoID = components.queryItems?
                    .first(where: { $0.name.lowercased() == "v" })?
                    .value
            }
        } else {
            videoID = nil
        }

        guard let videoID, isValidVideoID(videoID) else {
            throw invalidReference(path: path)
        }

        let startValue = components.queryItems?
            .first(where: {
                ["t", "start", "time_continue"].contains($0.name.lowercased())
            })?
            .value
            ?? fragmentStartValue(components.fragment)
        let startSeconds = try startValue.flatMap {
            try parseStartSeconds($0, path: "\(path).startSeconds")
        }

        return ParsedYouTubeReference(
            videoID: videoID,
            startSeconds: startSeconds.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    public static func parseStartSeconds(
        _ input: String,
        path: String = "$.youtube.startSeconds"
    ) throws -> Int {
        let value = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !value.isEmpty else {
            throw invalidStart(path: path)
        }

        if let seconds = Int(value) {
            return try bounded(seconds, path: path)
        }

        var total = 0
        var digits = ""
        var consumedUnit = false
        for character in value {
            if character.isNumber {
                digits.append(character)
                continue
            }
            guard let amount = Int(digits), amount >= 0 else {
                throw invalidStart(path: path)
            }
            digits = ""
            switch character {
            case "h":
                total = try adding(total, scaled(amount, by: 3_600, path: path), path: path)
            case "m":
                total = try adding(total, scaled(amount, by: 60, path: path), path: path)
            case "s":
                total = try adding(total, amount, path: path)
            default:
                throw invalidStart(path: path)
            }
            consumedUnit = true
        }
        guard consumedUnit, digits.isEmpty else {
            throw invalidStart(path: path)
        }
        return try bounded(total, path: path)
    }

    private static func fragmentStartValue(_ fragment: String?) -> String? {
        guard let fragment else { return nil }
        let value = fragment.hasPrefix("t=") ? String(fragment.dropFirst(2)) : fragment
        return value.isEmpty ? nil : value
    }

    private static func scaled(_ value: Int, by multiplier: Int, path: String) throws -> Int {
        let (product, overflow) = value.multipliedReportingOverflow(by: multiplier)
        guard !overflow else { throw invalidStart(path: path) }
        return product
    }

    private static func adding(_ lhs: Int, _ rhs: Int, path: String) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw invalidStart(path: path) }
        return try bounded(sum, path: path)
    }

    private static func bounded(_ value: Int, path: String) throws -> Int {
        guard (0...NodeNoteValidator.maxYouTubeStartSeconds).contains(value) else {
            throw invalidStart(path: path)
        }
        return value
    }

    private static func invalidReference(path: String) -> NodeNoteValidationError {
        NodeNoteValidationError(
            code: .invalidYouTubeReference,
            path: path,
            message: "Enter a valid YouTube video ID or youtube.com/youtu.be URL."
        )
    }

    private static func invalidStart(path: String) -> NodeNoteValidationError {
        NodeNoteValidationError(
            code: .invalidYouTubeStart,
            path: path,
            message: "YouTube start time must be a bounded number of seconds or a value such as 1m30s."
        )
    }
}

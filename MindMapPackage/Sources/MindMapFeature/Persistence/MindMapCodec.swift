import Foundation

public enum MindMapCodecError: Error, LocalizedError, Sendable {
    case unsupportedVersion(Int)
    case encodingFailed
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "Unsupported mind map version \(v)."
        case .encodingFailed:
            return "Failed to encode mind map."
        case .decodingFailed(let detail):
            return "Failed to decode mind map: \(detail)"
        }
    }
}

public enum MindMapCodec {
    public static let fileExtension = "mindmap"
    public static let contentTypeIdentifier = "public.json"

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    public static func encode(_ file: MindMapFile) throws -> Data {
        do {
            return try encoder.encode(file)
        } catch {
            throw MindMapCodecError.encodingFailed
        }
    }

    public static func decode(from data: Data) throws -> MindMapFile {
        let file: MindMapFile
        do {
            file = try decoder.decode(MindMapFile.self, from: data)
        } catch {
            throw MindMapCodecError.decodingFailed(error.localizedDescription)
        }
        guard file.version == MindMapFile.currentVersion else {
            throw MindMapCodecError.unsupportedVersion(file.version)
        }
        return file
    }

    public static func load(from url: URL) throws -> MindMapFile {
        let data = try Data(contentsOf: url)
        return try decode(from: data)
    }

    public static func save(_ file: MindMapFile, to url: URL) throws {
        let data = try encode(file)
        try data.write(to: url, options: .atomic)
    }
}

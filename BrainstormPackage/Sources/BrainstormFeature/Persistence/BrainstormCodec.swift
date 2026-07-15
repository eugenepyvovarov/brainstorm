import Foundation
import UniformTypeIdentifiers

public enum BrainstormCodecError: Error, LocalizedError, Sendable {
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

public enum BrainstormCodec {
    /// User-facing Brainstorm document extension (`.bs`).
    public static let fileExtension = "bs"
    /// Exported UTI declared in the app Info.plist.
    public static let contentTypeIdentifier = "com.eugenep.Brainstorm.bs"

    /// UTType for Save / Open panels (exported by Brainstorm).
    public static var contentType: UTType {
        if let exported = UTType(contentTypeIdentifier) {
            return exported
        }
        if let byExt = UTType(filenameExtension: fileExtension) {
            return byExt
        }
        return UTType(exportedAs: contentTypeIdentifier, conformingTo: .json)
    }

    /// Types accepted when opening files.
    public static var openContentTypes: [UTType] {
        [contentType]
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Keep key order deterministic for clean diffs. The custom model
        // encoders below make the content sparse; sorted keys only affect
        // presentation, not the document semantics.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    public static func encode(_ file: BrainstormFile) throws -> Data {
        do {
            return try encoder.encode(file)
        } catch {
            throw BrainstormCodecError.encodingFailed
        }
    }

    public static func decode(from data: Data) throws -> BrainstormFile {
        let file: BrainstormFile
        do {
            file = try decoder.decode(BrainstormFile.self, from: data)
        } catch {
            throw BrainstormCodecError.decodingFailed(error.localizedDescription)
        }
        // v1 = title tree only; v2 adds style/media/offsets (decoded with
        // defaults, so both verbose and sparse v2 files are accepted).
        guard (1...BrainstormFile.currentVersion).contains(file.version) else {
            throw BrainstormCodecError.unsupportedVersion(file.version)
        }
        return file
    }

    public static func load(from url: URL) throws -> BrainstormFile {
        let data = try Data(contentsOf: url)
        return try decode(from: data)
    }

    public static func save(_ file: BrainstormFile, to url: URL) throws {
        let data = try encode(file)
        try data.write(to: url, options: .atomic)
    }
}

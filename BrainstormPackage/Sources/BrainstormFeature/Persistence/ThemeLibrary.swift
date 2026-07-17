import Foundation
import Observation
import zlib

/// An imported native Zed theme file. The source JSON is retained unchanged.
public struct ImportedZedThemeFile: Identifiable, Hashable, Sendable {
    public let sourceURL: URL
    public let familyName: String
    public let author: String
    public let themes: [AppTheme]

    public var id: String { sourceURL.path }
}

/// Public metadata for an extension in Zed's registry.
public struct ZedRegistryExtension: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public let authors: [String]
    public let repository: String?
    public let provides: [String]
    public let downloadCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, version, description, authors, repository, provides
        case downloadCount = "download_count"
    }

    public var isTheme: Bool {
        provides.contains { $0.caseInsensitiveCompare("themes") == .orderedSame }
    }
}

/// A native Zed JSON file contained in a downloaded extension archive.
public struct ZedNativeThemeFile: Hashable, Sendable {
    public let path: String
    public let data: Data

    public init(path: String, data: Data) {
        self.path = path
        self.data = data
    }
}

public enum ZedRegistrySource: String, Equatable, Sendable {
    case network
    case freshCache
    case staleCache
}

public struct ZedRegistrySnapshot: Sendable {
    public let themes: [ZedRegistryExtension]
    public let source: ZedRegistrySource

    public init(themes: [ZedRegistryExtension], source: ZedRegistrySource) {
        self.themes = themes
        self.source = source
    }
}

/// Persistent, actor-isolated storage for the public catalog and selected
/// extension archives. Cached archives remain the original Zed payload.
public actor ZedThemeRegistryCache {
    public static let shared = ZedThemeRegistryCache()

    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.directory = directory
            ?? base
                .appendingPathComponent("Brainstorm", isDirectory: true)
                .appendingPathComponent("Zed Theme Registry", isDirectory: true)
        self.fileManager = fileManager
    }

    public func registryData(maxAge: TimeInterval, now: Date = Date()) -> Data? {
        let url = directory.appendingPathComponent("registry.json")
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              max(0, now.timeIntervalSince(modified)) <= maxAge
        else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    public func staleRegistryData() -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent("registry.json"))
    }

    public func storeRegistryData(_ data: Data) throws {
        try prepareDirectory()
        try data.write(
            to: directory.appendingPathComponent("registry.json"),
            options: .atomic
        )
    }

    public func archiveData(cacheKey: String) -> Data? {
        try? Data(contentsOf: archiveURL(cacheKey: cacheKey))
    }

    public func storeArchiveData(_ data: Data, cacheKey: String) throws {
        try prepareDirectory()
        let archiveDirectory = directory.appendingPathComponent("Archives", isDirectory: true)
        try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        try data.write(to: archiveURL(cacheKey: cacheKey), options: .atomic)
    }

    public func removeArchive(cacheKey: String) {
        try? fileManager.removeItem(at: archiveURL(cacheKey: cacheKey))
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func archiveURL(cacheKey: String) -> URL {
        let safeKey = cacheKey.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "_"
        }
        return directory
            .appendingPathComponent("Archives", isDirectory: true)
            .appendingPathComponent(String(safeKey))
            .appendingPathExtension("tar.gz")
    }
}

/// Zed's public extension registry. It supplies the catalog metadata; a
/// selected extension is downloaded only when it needs a local preview.
public enum ZedThemeRegistry {
    private static let maxSchemaVersion = "1"
    private static let maxWasmAPIVersion = "0.9.0"
    private static let registryFreshness: TimeInterval = 6 * 60 * 60

    public static func listURL() -> URL {
        var components = URLComponents(string: "https://api.zed.dev/extensions")!
        components.queryItems = [
            URLQueryItem(name: "max_schema_version", value: maxSchemaVersion),
            URLQueryItem(name: "max_wasm_api_version", value: maxWasmAPIVersion),
        ]
        return components.url!
    }

    public static func downloadURL(id: String) -> URL {
        var components = URLComponents(string: "https://api.zed.dev/extensions/\(id)/download")!
        components.queryItems = [
            URLQueryItem(name: "min_schema_version", value: "0"),
            URLQueryItem(name: "max_schema_version", value: maxSchemaVersion),
            URLQueryItem(name: "min_wasm_api_version", value: "0.0.1"),
            URLQueryItem(name: "max_wasm_api_version", value: maxWasmAPIVersion),
        ]
        return components.url!
    }

    public static func fetchSnapshot(
        forceRefresh: Bool = false,
        cache: ZedThemeRegistryCache = .shared
    ) async throws -> ZedRegistrySnapshot {
        if !forceRefresh,
           let data = await cache.registryData(maxAge: registryFreshness),
           let themes = try? sortedThemes(from: data)
        {
            return ZedRegistrySnapshot(themes: themes, source: .freshCache)
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: listURL())
            guard let http = response as? HTTPURLResponse, 200 ..< 300 ~= http.statusCode else {
                throw ZedThemeImportError.registryUnavailable
            }
            let themes = try sortedThemes(from: data)
            try? await cache.storeRegistryData(data)
            return ZedRegistrySnapshot(themes: themes, source: .network)
        } catch {
            if let data = await cache.staleRegistryData(),
               let themes = try? sortedThemes(from: data)
            {
                return ZedRegistrySnapshot(themes: themes, source: .staleCache)
            }
            throw ZedThemeImportError.registryUnavailable
        }
    }

    public static func fetchThemes() async throws -> [ZedRegistryExtension] {
        try await fetchSnapshot().themes
    }

    public static func downloadThemeFiles(
        for theme: ZedRegistryExtension,
        cache: ZedThemeRegistryCache = .shared
    ) async throws -> [ZedNativeThemeFile] {
        let cacheKey = archiveCacheKey(for: theme)
        if let data = await cache.archiveData(cacheKey: cacheKey) {
            do {
                return try ZedThemeArchive.themeFiles(fromGzipTar: data)
            } catch {
                await cache.removeArchive(cacheKey: cacheKey)
            }
        }

        let (data, response) = try await URLSession.shared.data(from: downloadURL(id: theme.id))
        guard let http = response as? HTTPURLResponse, 200 ..< 300 ~= http.statusCode else {
            throw ZedThemeImportError.downloadFailed
        }
        let files = try ZedThemeArchive.themeFiles(fromGzipTar: data)
        try? await cache.storeArchiveData(data, cacheKey: cacheKey)
        return files
    }

    public static func extensions(from data: Data) throws -> [ZedRegistryExtension] {
        struct Response: Decodable { let data: [ZedRegistryExtension] }
        do {
            return try JSONDecoder().decode(Response.self, from: data).data
        } catch {
            throw ZedThemeImportError.registryUnavailable
        }
    }

    public static func archiveCacheKey(for theme: ZedRegistryExtension) -> String {
        "\(theme.id)@\(theme.version)@schema-\(maxSchemaVersion)@wasm-\(maxWasmAPIVersion)"
    }

    private static func sortedThemes(from data: Data) throws -> [ZedRegistryExtension] {
        try extensions(from: data)
            .filter(\.isTheme)
            .sorted {
                let leftCount = $0.downloadCount ?? 0
                let rightCount = $1.downloadCount ?? 0
                if leftCount != rightCount { return leftCount > rightCount }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }
}

/// A deliberately small, defensive reader for Zed's gzip-compressed tar
/// extension archives. It only returns regular JSON files below `themes/`.
public enum ZedThemeArchive {
    private static let blockSize = 512
    private static let maximumExpandedBytes = 16 * 1024 * 1024

    public static func themeFiles(fromGzipTar archive: Data) throws -> [ZedNativeThemeFile] {
        try themeFiles(fromTar: gunzip(archive))
    }

    public static func themeFiles(fromTar archive: Data) throws -> [ZedNativeThemeFile] {
        var files: [ZedNativeThemeFile] = []
        var offset = 0

        while offset + blockSize <= archive.count {
            let header = Data(archive[offset ..< offset + blockSize])
            if header.allSatisfy({ $0 == 0 }) { break }

            let name = string(in: header, range: 0 ..< 100)
            let prefix = string(in: header, range: 345 ..< 500)
            let rawPath = prefix.isEmpty ? name : "\(prefix)/\(name)"
            // Zed extension archives commonly store their root entries as
            // `./themes/...`; this is equivalent to `themes/...`, not a path
            // traversal. Keep any later `.` or `..` component for validation.
            let path = rawPath
                .split(separator: "/", omittingEmptySubsequences: true)
                .drop(while: { $0 == "." })
                .joined(separator: "/")
            let size = try octalSize(in: header)
            let type = header[156]
            let contentsStart = offset + blockSize
            guard size >= 0, contentsStart + size <= archive.count else {
                throw ZedThemeImportError.invalidArchive
            }

            // `0` and NUL are regular tar file entries.
            if (type == 0 || type == 48), isSafeThemeJSONPath(path) {
                files.append(ZedNativeThemeFile(
                    path: path,
                    data: Data(archive[contentsStart ..< contentsStart + size])
                ))
            }

            let paddedSize = ((size + blockSize - 1) / blockSize) * blockSize
            offset = contentsStart + paddedSize
        }

        guard !files.isEmpty else { throw ZedThemeImportError.extensionHasNoThemes }
        return files
    }

    public static func gunzip(_ compressed: Data) throws -> Data {
        var stream = z_stream()
        let initialization = inflateInit2_(
            &stream,
            15 + 16, // zlib window plus gzip decoding
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialization == Z_OK else { throw ZedThemeImportError.invalidArchive }
        defer { inflateEnd(&stream) }

        return try compressed.withUnsafeBytes { rawBuffer in
            guard let input = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
                throw ZedThemeImportError.invalidArchive
            }
            stream.next_in = UnsafeMutablePointer(mutating: input)
            stream.avail_in = uInt(rawBuffer.count)

            var output = Data()
            var status: Int32 = Z_OK
            repeat {
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                let written = chunk.withUnsafeMutableBytes { chunkBuffer -> Int in
                    stream.next_out = chunkBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkBuffer.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return chunkBuffer.count - Int(stream.avail_out)
                }
                guard output.count + written <= maximumExpandedBytes else {
                    status = Z_MEM_ERROR
                    return output
                }
                output.append(chunk, count: written)
            } while status == Z_OK

            guard status == Z_STREAM_END else { throw ZedThemeImportError.invalidArchive }
            return output
        }
    }

    private static func string(in header: Data, range: Range<Int>) -> String {
        let bytes = header[range]
        let trimmed = bytes.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    private static func octalSize(in header: Data) throws -> Int {
        let bytes = header[124 ..< 136]
        let value = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        guard value.isEmpty || value.allSatisfy({ $0 >= "0" && $0 <= "7" }),
              let size = Int(value.isEmpty ? "0" : value, radix: 8)
        else {
            throw ZedThemeImportError.invalidArchive
        }
        return size
    }

    private static func isSafeThemeJSONPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.count >= 2
            && parts.first == "themes"
            && !parts.contains(where: { $0 == "." || $0 == ".." })
            && path.lowercased().hasSuffix(".json")
    }
}

public enum ZedThemeImportError: LocalizedError {
    case invalidThemeFile
    case registryUnavailable
    case downloadFailed
    case invalidArchive
    case extensionHasNoThemes

    public var errorDescription: String? {
        switch self {
        case .invalidThemeFile:
            "This is not a valid Zed theme JSON file."
        case .registryUnavailable:
            "The Zed theme registry could not be loaded."
        case .downloadFailed:
            "The selected Zed theme extension could not be downloaded."
        case .invalidArchive:
            "The downloaded Zed extension archive is invalid."
        case .extensionHasNoThemes:
            "This Zed extension does not contain any theme JSON files."
        }
    }
}

/// Converts Zed's editor-oriented colors into a deliberate Brainstorm canvas
/// palette. Zed frequently publishes translucent overlays; Brainstorm stores
/// opaque role colors, so overlays are composited against their semantic base.
enum ZedPaletteBuilder {
    struct Palette: Equatable {
        let canvas: String
        let grid: String
        let chromeBackground: String
        let chromeForeground: String
        let secondaryText: String
        let separator: String
        let rootFill: String
        let rootText: String
        let nodeFill: String
        let nodeText: String
        let branch: String
        let edge: String
        let selection: String
        let searchHighlight: String
    }

    static func build(style: [String: Any], isDark: Bool) -> Palette {
        let fallbackCanvas = RGB(hex: isDark ? "#1E1E1E" : "#FFFFFF")!
        let fallbackForeground = RGB(hex: isDark ? "#E6E6E6" : "#202020")!
        let canvas = color(
            ["editor.background", "background", "surface.background"],
            in: style,
            over: fallbackCanvas
        ) ?? fallbackCanvas
        let foreground = color(
            ["editor.foreground", "text", "terminal.foreground"],
            in: style,
            over: canvas
        ) ?? fallbackForeground

        let branch = visibleColor(
            color(
                ["text.accent", "icon.accent", "border.focused", "terminal.ansi.blue"],
                in: style,
                over: canvas
            ) ?? RGB(hex: isDark ? "#5B9BD5" : "#0066CC")!,
            against: canvas,
            fallback: foreground,
            minimumContrast: 2
        )
        let rootAccent = color(
            ["terminal.ansi.blue", "icon.accent", "text.accent", "border.focused"],
            in: style,
            over: canvas
        ) ?? branch

        let nodeCandidates = [
            "background",
            "surface.background",
            "panel.background",
            "element.background",
        ].compactMap { color([$0], in: style, over: canvas) }
        let nodeFill = nodeCandidates.first(where: { $0.contrast(with: canvas) >= 1.08 })
            ?? canvas.mixed(with: foreground, amount: isDark ? 0.10 : 0.07)

        let selected = color(
            ["element.selected", "border.selected", "editor.active_line.background"],
            in: style,
            over: canvas
        )
        var rootFill = selected.flatMap {
            $0.contrast(with: canvas) >= 1.22 && $0.contrast(with: nodeFill) >= 1.12 ? $0 : nil
        } ?? rootAccent
        if rootFill.contrast(with: canvas) < 1.3 || rootFill.contrast(with: nodeFill) < 1.12 {
            rootFill = canvas.mixed(with: rootAccent, amount: isDark ? 0.62 : 0.28)
        }

        var separator = color(
            ["border", "border.variant", "editor.wrap_guide"],
            in: style,
            over: canvas
        ) ?? canvas.mixed(with: foreground, amount: 0.18)
        if separator.contrast(with: canvas) < 1.12 {
            separator = canvas.mixed(with: foreground, amount: isDark ? 0.22 : 0.14)
        }

        var grid = color(
            ["editor.active_line.background", "editor.gutter.background", "border.variant"],
            in: style,
            over: canvas
        ) ?? separator
        if grid.contrast(with: canvas) > 1.28 {
            grid = canvas.mixed(with: grid, amount: 0.42)
        }

        let chromeBackground = color(
            ["toolbar.background", "panel.background", "surface.background", "element.background"],
            in: style,
            over: canvas
        ) ?? nodeFill
        let secondary = color(
            ["text.muted", "editor.line_number", "text.placeholder"],
            in: style,
            over: chromeBackground
        ) ?? chromeBackground.mixed(with: foreground, amount: isDark ? 0.68 : 0.58)
        let search = color(
            ["search.active_match_background", "search.match_background", "element.selected"],
            in: style,
            over: canvas
        ) ?? canvas.mixed(with: branch, amount: isDark ? 0.34 : 0.24)

        return Palette(
            canvas: canvas.hex,
            grid: grid.hex,
            chromeBackground: chromeBackground.hex,
            chromeForeground: readableText(preferred: foreground, on: chromeBackground).hex,
            secondaryText: secondary.hex,
            separator: separator.hex,
            rootFill: rootFill.hex,
            rootText: readableText(preferred: foreground, on: rootFill).hex,
            nodeFill: nodeFill.hex,
            nodeText: readableText(preferred: foreground, on: nodeFill).hex,
            branch: branch.hex,
            edge: separator.hex,
            selection: rootAccent.hex,
            searchHighlight: search.hex
        )
    }

    private static func color(
        _ keys: [String],
        in style: [String: Any],
        over background: RGB
    ) -> RGB? {
        keys.lazy.compactMap { key -> RGB? in
            guard let value = style[key] as? String,
                  let parsed = RGB(hex: value)
            else {
                return nil
            }
            return parsed.composited(over: background)
        }.first
    }

    private static func visibleColor(
        _ color: RGB,
        against background: RGB,
        fallback: RGB,
        minimumContrast: Double
    ) -> RGB {
        guard color.contrast(with: background) < minimumContrast else { return color }
        let stronger = background.mixed(with: fallback, amount: 0.72)
        return stronger.contrast(with: background) > color.contrast(with: background)
            ? stronger
            : color
    }

    private static func readableText(preferred: RGB, on fill: RGB) -> RGB {
        if preferred.contrast(with: fill) >= 4.5 { return preferred }
        let light = RGB(hex: ColorContrast.lightTextHex)!
        let dark = RGB(hex: ColorContrast.darkTextHex)!
        return light.contrast(with: fill) >= dark.contrast(with: fill) ? light : dark
    }

    private struct RGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
            self.red = min(max(red, 0), 1)
            self.green = min(max(green, 0), 1)
            self.blue = min(max(blue, 0), 1)
            self.alpha = min(max(alpha, 0), 1)
        }

        init?(hex value: String) {
            var body = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard body.hasPrefix("#") else { return nil }
            body.removeFirst()
            guard body.allSatisfy(\.isHexDigit) else { return nil }

            func component(_ value: String) -> Double? {
                UInt8(value, radix: 16).map { Double($0) / 255 }
            }

            switch body.count {
            case 3, 4:
                let expanded = body.map { "\($0)\($0)" }
                guard let red = component(expanded[0]),
                      let green = component(expanded[1]),
                      let blue = component(expanded[2])
                else {
                    return nil
                }
                let alpha = body.count == 4 ? (component(expanded[3]) ?? 1) : 1
                self.init(red: red, green: green, blue: blue, alpha: alpha)
            case 6, 8:
                let components = stride(from: 0, to: body.count, by: 2).map { index in
                    let start = body.index(body.startIndex, offsetBy: index)
                    let end = body.index(start, offsetBy: 2)
                    return String(body[start ..< end])
                }
                guard let red = component(components[0]),
                      let green = component(components[1]),
                      let blue = component(components[2])
                else {
                    return nil
                }
                let alpha = body.count == 8 ? (component(components[3]) ?? 1) : 1
                self.init(red: red, green: green, blue: blue, alpha: alpha)
            default:
                return nil
            }
        }

        var hex: String {
            func byte(_ value: Double) -> Int {
                Int((min(max(value, 0), 1) * 255).rounded())
            }
            return String(
                format: "#%02X%02X%02X",
                byte(red),
                byte(green),
                byte(blue)
            )
        }

        func composited(over background: RGB) -> RGB {
            guard alpha < 1 else { return RGB(red: red, green: green, blue: blue) }
            return RGB(
                red: red * alpha + background.red * (1 - alpha),
                green: green * alpha + background.green * (1 - alpha),
                blue: blue * alpha + background.blue * (1 - alpha)
            )
        }

        func mixed(with other: RGB, amount: Double) -> RGB {
            let amount = min(max(amount, 0), 1)
            return RGB(
                red: red * (1 - amount) + other.red * amount,
                green: green * (1 - amount) + other.green * amount,
                blue: blue * (1 - amount) + other.blue * amount
            )
        }

        func contrast(with other: RGB) -> Double {
            let lighter = max(luminance, other.luminance)
            let darker = min(luminance, other.luminance)
            return (lighter + 0.05) / (darker + 0.05)
        }

        private var luminance: Double {
            func linear(_ value: Double) -> Double {
                value <= 0.03928
                    ? value / 12.92
                    : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
    }
}

/// Stores imported themes as their original Zed JSON files, never as a
/// Brainstorm-specific theme format. The palette used by the app is derived
/// from Zed's published UI color keys each time the library is loaded.
@Observable
public final class ThemeLibrary: @unchecked Sendable {
    public static let shared = ThemeLibrary()

    public private(set) var importedFiles: [ImportedZedThemeFile] = []

    private let fileManager: FileManager
    private var removedThemeIDsBySource: [String: Set<String>] = [:]
    public let storageDirectory: URL

    private var removedSubthemesURL: URL {
        storageDirectory.appendingPathComponent(".removed-subthemes.json")
    }

    public convenience init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.init(
            storageDirectory: base
                .appendingPathComponent("Brainstorm", isDirectory: true)
                .appendingPathComponent("Zed Themes", isDirectory: true),
            fileManager: fileManager
        )
    }

    /// Test / custom-location initializer.
    public init(storageDirectory: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.storageDirectory = storageDirectory
        reload()
    }

    public var themes: [AppTheme] {
        importedFiles.flatMap(\.themes)
    }

    public func reload() {
        try? fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        removedThemeIDsBySource = loadRemovedSubthemes()
        let urls = (try? fileManager.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        importedFiles = urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? parse(data: data, sourceURL: url)
            }
            .compactMap(applyingRemovedSubthemes)
            .sorted { $0.familyName.localizedCaseInsensitiveCompare($1.familyName) == .orderedAscending }
    }

    @discardableResult
    public func importNativeZedTheme(from sourceURL: URL) throws -> ImportedZedThemeFile {
        let data = try Data(contentsOf: sourceURL)
        return try importNativeZedTheme(
            data: data,
            sourceName: sourceURL.deletingPathExtension().lastPathComponent
        )
    }

    /// Keep the exact downloaded JSON bytes and derive Brainstorm's palette from them.
    @discardableResult
    public func importNativeZedTheme(data: Data, sourceName: String) throws -> ImportedZedThemeFile {
        // Validate before writing so invalid files never enter the managed library.
        _ = try parse(data: data, sourceURL: storageDirectory.appendingPathComponent("validation.json"))
        try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        if let existing = importedFiles.first(where: {
            (try? Data(contentsOf: $0.sourceURL)) == data
        }) {
            let key = sourceKey(for: existing.sourceURL)
            if let previous = removedThemeIDsBySource.removeValue(forKey: key) {
                do {
                    try persistRemovedSubthemes()
                } catch {
                    removedThemeIDsBySource[key] = previous
                    throw error
                }
                reload()
                return importedFiles.first(where: { $0.sourceURL == existing.sourceURL }) ?? existing
            }
            return existing
        }
        let safeName = Self.slug(sourceName)
        let destination = storageDirectory.appendingPathComponent(
            "\(safeName)-\(UUID().uuidString).json"
        )
        try data.write(to: destination, options: .atomic)
        let imported = try parse(data: data, sourceURL: destination)
        importedFiles.append(imported)
        importedFiles.sort {
            $0.familyName.localizedCaseInsensitiveCompare($1.familyName) == .orderedAscending
        }
        return imported
    }

    /// Parse an extension's native theme files for a temporary in-app preview.
    public func previewZedThemeFiles(
        _ files: [ZedNativeThemeFile],
        extensionID: String
    ) throws -> [ImportedZedThemeFile] {
        let previews = try files.map { file in
            try parse(
                data: file.data,
                sourceURL: storageDirectory.appendingPathComponent(
                    "preview-\(Self.slug(extensionID))-\(Self.slug(file.path)).json"
                )
            )
        }
        guard !previews.isEmpty else { throw ZedThemeImportError.extensionHasNoThemes }
        return previews
    }

    /// Add each original JSON file from a selected Zed extension unchanged.
    @discardableResult
    public func importZedThemeFiles(
        _ files: [ZedNativeThemeFile],
        extensionID: String
    ) throws -> [ImportedZedThemeFile] {
        let imported = try files.map { file in
            try importNativeZedTheme(
                data: file.data,
                sourceName: "\(extensionID)-\(file.path)"
            )
        }
        guard !imported.isEmpty else { throw ZedThemeImportError.extensionHasNoThemes }
        return imported
    }

    public func delete(_ file: ImportedZedThemeFile) throws {
        let preferredThemeID = AppTheme.preferredDefaultID
        let removedThemes = importedFiles
            .first(where: { $0.sourceURL == file.sourceURL })?
            .themes ?? file.themes
        try fileManager.removeItem(at: file.sourceURL)
        importedFiles.removeAll { $0.sourceURL == file.sourceURL }
        removedThemeIDsBySource.removeValue(forKey: sourceKey(for: file.sourceURL))
        try? persistRemovedSubthemes()
        if removedThemes.contains(where: { $0.id == preferredThemeID }) {
            AppTheme.setPreferredDefault(AppTheme.system.id)
        }
    }

    /// Hide one imported variant without rewriting its original Zed source.
    /// Removing the final visible variant removes the source file itself.
    public func delete(_ theme: AppTheme, from file: ImportedZedThemeFile) throws {
        guard let currentFile = importedFiles.first(where: { $0.sourceURL == file.sourceURL }),
              currentFile.themes.contains(where: { $0.id == theme.id })
        else {
            return
        }
        if currentFile.themes.count == 1 {
            try delete(currentFile)
            return
        }

        let wasPreferred = AppTheme.preferredDefaultID == theme.id
        let key = sourceKey(for: currentFile.sourceURL)
        let previous = removedThemeIDsBySource[key]
        removedThemeIDsBySource[key, default: []].insert(theme.id)
        do {
            try persistRemovedSubthemes()
        } catch {
            if let previous {
                removedThemeIDsBySource[key] = previous
            } else {
                removedThemeIDsBySource.removeValue(forKey: key)
            }
            throw error
        }
        reload()
        if wasPreferred {
            AppTheme.setPreferredDefault(AppTheme.system.id)
        }
    }

    private func parse(data: Data, sourceURL: URL) throws -> ImportedZedThemeFile {
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(
                with: data,
                options: .json5Allowed
            )
        } catch {
            throw ZedThemeImportError.invalidThemeFile
        }

        guard let root = decoded as? [String: Any],
              let rawThemes = root["themes"] as? [[String: Any]]
        else {
            throw ZedThemeImportError.invalidThemeFile
        }

        let familyName = (root["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedFamilyName = (familyName?.isEmpty == false ? familyName : nil)
            ?? sourceURL.deletingPathExtension().lastPathComponent
        let author = (root["author"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sourceSlug = Self.slug(sourceURL.deletingPathExtension().lastPathComponent)

        let themes = rawThemes.enumerated().compactMap { index, rawTheme -> AppTheme? in
            guard let style = rawTheme["style"] as? [String: Any] else { return nil }
            let name = ((rawTheme["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
                .flatMap { $0.isEmpty ? nil : $0 } ?? resolvedFamilyName
            let isDark = (rawTheme["appearance"] as? String)?.lowercased() != "light"
            let palette = ZedPaletteBuilder.build(style: style, isDark: isDark)

            return AppTheme(
                id: "zed-\(sourceSlug)-\(index)-\(Self.slug(name))",
                name: name,
                subtitle: author.isEmpty ? "Zed · \(resolvedFamilyName)" : "Zed · \(author)",
                isDark: isDark,
                canvasBackground: palette.canvas,
                grid: palette.grid,
                chromeBackground: palette.chromeBackground,
                chromeForeground: palette.chromeForeground,
                secondaryText: palette.secondaryText,
                separator: palette.separator,
                rootFill: palette.rootFill,
                rootText: palette.rootText,
                nodeFill: palette.nodeFill,
                nodeText: palette.nodeText,
                branch: palette.branch,
                edge: palette.edge,
                selection: palette.selection,
                searchHighlight: palette.searchHighlight
            )
        }

        guard !themes.isEmpty else { throw ZedThemeImportError.invalidThemeFile }
        return ImportedZedThemeFile(
            sourceURL: sourceURL,
            familyName: resolvedFamilyName,
            author: author,
            themes: themes
        )
    }

    private static func slug(_ value: String) -> String {
        let result = value.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: "-")
        return result.isEmpty ? "theme" : result
    }

    private func applyingRemovedSubthemes(
        to file: ImportedZedThemeFile
    ) -> ImportedZedThemeFile? {
        let removedIDs = removedThemeIDsBySource[sourceKey(for: file.sourceURL)] ?? []
        guard !removedIDs.isEmpty else { return file }
        let visibleThemes = file.themes.filter { !removedIDs.contains($0.id) }
        guard !visibleThemes.isEmpty else { return nil }
        return ImportedZedThemeFile(
            sourceURL: file.sourceURL,
            familyName: file.familyName,
            author: file.author,
            themes: visibleThemes
        )
    }

    private func sourceKey(for url: URL) -> String {
        url.lastPathComponent
    }

    private func loadRemovedSubthemes() -> [String: Set<String>] {
        guard let data = try? Data(contentsOf: removedSubthemesURL),
              let stored = try? JSONDecoder().decode([String: [String]].self, from: data)
        else {
            return [:]
        }
        return stored.mapValues(Set.init)
    }

    private func persistRemovedSubthemes() throws {
        try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let stored = removedThemeIDsBySource.mapValues { $0.sorted() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(stored)
        try data.write(to: removedSubthemesURL, options: .atomic)
    }
}

import CoreGraphics
import Foundation

// MARK: - Style

/// Visual appearance of a node. Missing values fall back to app defaults.
public struct NodeStyle: Codable, Equatable, Hashable, Sendable {
    public var fillHex: String?
    public var textHex: String?
    /// Color of the edge from this node to its children.
    public var branchHex: String?
    /// Optional node outline color. `nil` uses the theme's subtle outline.
    public var borderHex: String?
    /// Outline width in points. `nil` uses the root/child default.
    public var borderWidth: Double?
    public var shape: NodeShape
    /// Points; `nil` uses root/child defaults (16 / 14).
    public var fontSize: Double?
    public var isBold: Bool
    public var isItalic: Bool

    public init(
        fillHex: String? = nil,
        textHex: String? = nil,
        branchHex: String? = nil,
        borderHex: String? = nil,
        borderWidth: Double? = nil,
        shape: NodeShape = .roundedRect,
        fontSize: Double? = nil,
        isBold: Bool = false,
        isItalic: Bool = false
    ) {
        self.fillHex = fillHex
        self.textHex = textHex
        self.branchHex = branchHex
        self.borderHex = borderHex
        self.borderWidth = borderWidth
        self.shape = shape
        self.fontSize = fontSize
        self.isBold = isBold
        self.isItalic = isItalic
    }

    public static let `default` = NodeStyle()

    public var isDefault: Bool {
        fillHex == nil
            && textHex == nil
            && branchHex == nil
            && borderHex == nil
            && borderWidth == nil
            && shape == .roundedRect
            && fontSize == nil
            && !isBold
            && !isItalic
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fillHex = try c.decodeIfPresent(String.self, forKey: .fillHex)
        textHex = try c.decodeIfPresent(String.self, forKey: .textHex)
        branchHex = try c.decodeIfPresent(String.self, forKey: .branchHex)
        borderHex = try c.decodeIfPresent(String.self, forKey: .borderHex)
        borderWidth = try c.decodeIfPresent(Double.self, forKey: .borderWidth)
        shape = try c.decodeIfPresent(NodeShape.self, forKey: .shape) ?? .roundedRect
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize)
        isBold = try c.decodeIfPresent(Bool.self, forKey: .isBold) ?? false
        isItalic = try c.decodeIfPresent(Bool.self, forKey: .isItalic) ?? false
    }
}

public enum NodeShape: String, Codable, CaseIterable, Sendable, Identifiable {
    case roundedRect
    case capsule
    case rectangle
    case diamond

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .roundedRect: return "Rounded"
        case .capsule: return "Capsule"
        case .rectangle: return "Rectangle"
        case .diamond: return "Diamond"
        }
    }
}

// MARK: - Media

/// Optional decoration on a node (emoji, SF Symbol sticker, or embedded image).
/// At most one kind is active at a time — emoji | sticker | image.
public struct NodeMedia: Codable, Equatable, Hashable, Sendable {
    public var emoji: String?
    /// SF Symbol name used as a sticker.
    public var sticker: String?
    /// PNG image bytes, base64-encoded for JSON.
    public var imageBase64: String?

    public init(emoji: String? = nil, sticker: String? = nil, imageBase64: String? = nil) {
        self.emoji = emoji
        self.sticker = sticker
        self.imageBase64 = imageBase64
    }

    public var isEmpty: Bool {
        activeKind == nil
    }

    /// Which decoration to show (priority: emoji → sticker → image).
    public var activeKind: Kind? {
        if let emoji, !emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emoji(emoji)
        }
        if let sticker, !sticker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .sticker(sticker)
        }
        if let imageBase64, !imageBase64.isEmpty {
            return .image(imageBase64)
        }
        return nil
    }

    public enum Kind: Equatable, Sendable {
        case emoji(String)
        case sticker(String)
        case image(String)
    }

    /// Assign emoji and clear sticker/image (or clear all when `nil`).
    public mutating func setExclusiveEmoji(_ value: String?) {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emoji = value
            sticker = nil
            imageBase64 = nil
        } else {
            emoji = nil
        }
    }

    /// Assign SF Symbol sticker and clear emoji/image (or clear sticker when `nil`).
    public mutating func setExclusiveSticker(_ value: String?) {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sticker = value
            emoji = nil
            imageBase64 = nil
        } else {
            sticker = nil
        }
    }

    /// Assign image and clear emoji/sticker (or clear image when `nil`).
    public mutating func setExclusiveImageBase64(_ value: String?) {
        if let value, !value.isEmpty {
            imageBase64 = value
            emoji = nil
            sticker = nil
        } else {
            imageBase64 = nil
        }
    }

    public static let empty = NodeMedia()
}

// MARK: - Node

/// A single node in the mind map tree.
public struct BrainstormNode: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var isExpanded: Bool
    public var children: [BrainstormNode]
    public var style: NodeStyle
    public var media: NodeMedia
    /// Manual offset from automatic layout position (document points). `nil` = auto.
    public var offsetX: Double?
    public var offsetY: Double?

    public init(
        id: UUID = UUID(),
        title: String = "New node",
        isExpanded: Bool = true,
        children: [BrainstormNode] = [],
        style: NodeStyle = .default,
        media: NodeMedia = .empty,
        offsetX: Double? = nil,
        offsetY: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.isExpanded = isExpanded
        self.children = children
        self.style = style
        self.media = media
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    public var hasChildren: Bool { !children.isEmpty }

    public var hasManualPosition: Bool {
        (offsetX != nil && offsetX != 0) || (offsetY != nil && offsetY != 0)
    }

    public var manualOffset: CGSize {
        CGSize(width: offsetX ?? 0, height: offsetY ?? 0)
    }

    /// Fresh main node title is empty so the user can type immediately (BrainstormNode first-map UX).
    public static func root(title: String = "") -> BrainstormNode {
        BrainstormNode(title: title, isExpanded: true, children: [])
    }

    public static let mainPlaceholder = "Main Idea"
    public static let nodePlaceholder = "New node"

    // Backward-compatible decode for maps saved before style/media/offset existed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        isExpanded = try c.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        children = try c.decodeIfPresent([BrainstormNode].self, forKey: .children) ?? []
        style = try c.decodeIfPresent(NodeStyle.self, forKey: .style) ?? .default
        media = try c.decodeIfPresent(NodeMedia.self, forKey: .media) ?? .empty
        offsetX = try c.decodeIfPresent(Double.self, forKey: .offsetX)
        offsetY = try c.decodeIfPresent(Double.self, forKey: .offsetY)
    }
}

/// On-disk document envelope.
public struct BrainstormFile: Codable, Equatable, Sendable {
    public var version: Int
    public var root: BrainstormNode
    /// Editor theme id (`AppTheme.id`). Optional for older files.
    public var themeID: String?

    public init(
        version: Int = Self.currentVersion,
        root: BrainstormNode,
        themeID: String? = AppTheme.system.id
    ) {
        self.version = version
        self.root = root
        self.themeID = themeID
    }

    /// v2 adds style/media/offsets; themeID is optional on the envelope.
    public static let currentVersion = 2

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        root = try c.decode(BrainstormNode.self, forKey: .root)
        themeID = try c.decodeIfPresent(String.self, forKey: .themeID)
    }
}

// MARK: - Color helpers

public enum NodeColorPalette {
    /// Fixed accent fills (optional highlights). Prefer theme swatches first.
    public static let accentFills: [(name: String, hex: String)] = [
        ("Sky", "#D6EAF8"),
        ("Mint", "#D5F5E3"),
        ("Lemon", "#FCF3CF"),
        ("Peach", "#FADBD8"),
        ("Lavender", "#E8DAEF"),
        ("Coral", "#F5B7B1"),
        ("Slate", "#D5D8DC"),
        ("Ink", "#2C3E50"),
    ]

    public static let accentBranches: [(name: String, hex: String)] = [
        ("Blue", "#5DADE2"),
        ("Green", "#58D68D"),
        ("Orange", "#F5B041"),
        ("Purple", "#AF7AC5"),
        ("Red", "#EC7063"),
        ("Gray", "#85929E"),
    ]

    public static let accentTexts: [(name: String, hex: String)] = [
        ("Ink", "#1C1C1E"),
        ("White", "#FFFFFF"),
        ("Blue", "#1A5276"),
        ("Green", "#196F3D"),
    ]

    /// Legacy fixed lists (tests / callers); prefer theme-aware helpers below.
    public static let fills: [(name: String, hex: String)] =
        [("Theme", "")] + accentFills
    public static let branches: [(name: String, hex: String)] =
        [("Theme", "")] + accentBranches
    public static let texts: [(name: String, hex: String)] =
        [("Auto", "")] + accentTexts

    /// Fill swatches: Theme default first, then this theme’s root/node colors, then accents.
    public static func fills(for theme: AppTheme) -> [(name: String, hex: String)] {
        var items: [(name: String, hex: String)] = [("Theme", "")]
        appendUnique(theme.rootFill, name: "Root", into: &items)
        appendUnique(theme.nodeFill, name: "Node", into: &items)
        appendUnique(theme.selection, name: "Accent", into: &items)
        for a in accentFills { appendUnique(a.hex, name: a.name, into: &items) }
        return items
    }

    public static func texts(for theme: AppTheme) -> [(name: String, hex: String)] {
        var items: [(name: String, hex: String)] = [("Auto", "")]
        appendUnique(theme.rootText, name: "Root", into: &items)
        appendUnique(theme.nodeText, name: "Node", into: &items)
        appendUnique(theme.secondaryText, name: "Muted", into: &items)
        for a in accentTexts { appendUnique(a.hex, name: a.name, into: &items) }
        return items
    }

    public static func branches(for theme: AppTheme) -> [(name: String, hex: String)] {
        var items: [(name: String, hex: String)] = [("Theme", "")]
        appendUnique(theme.branch, name: "Branch", into: &items)
        appendUnique(theme.edge, name: "Edge", into: &items)
        appendUnique(theme.selection, name: "Accent", into: &items)
        for a in accentBranches { appendUnique(a.hex, name: a.name, into: &items) }
        return items
    }

    private static func appendUnique(
        _ hex: String,
        name: String,
        into items: inout [(name: String, hex: String)]
    ) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if items.contains(where: { $0.hex.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return
        }
        items.append((name, trimmed))
    }

    public static let stickers: [String] = [
        "star.fill", "heart.fill", "bolt.fill", "flag.fill",
        "lightbulb.fill", "bookmark.fill", "checkmark.circle.fill",
        "exclamationmark.triangle.fill", "leaf.fill", "flame.fill",
        "person.fill", "house.fill", "briefcase.fill", "cart.fill",
        "airplane", "car.fill", "book.fill", "music.note",
    ]
}

/// WCAG-ish luminance contrast helpers for pairing fill + text.
public enum ColorContrast: Sendable {
    public static let lightTextHex = "#FFFFFF"
    public static let darkTextHex = "#1C1C1E"

    /// Relative luminance 0…1 (sRGB). `nil` if hex is invalid.
    public static func relativeLuminance(hex: String) -> Double? {
        guard let rgb = parseRGB(hex) else { return nil }
        func channel(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = channel(rgb.r)
        let g = channel(rgb.g)
        let b = channel(rgb.b)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// `true` when the fill is dark enough that light text reads better.
    public static func prefersLightText(onFill hex: String) -> Bool {
        // Midpoint ~0.45 works well for pastel vs ink palette.
        (relativeLuminance(hex: hex) ?? 1) < 0.45
    }

    /// Contrasting text hex for a fill (or dark ink when fill is nil/invalid).
    public static func contrastingTextHex(forFill fillHex: String?) -> String? {
        guard let fillHex, !fillHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return prefersLightText(onFill: fillHex) ? lightTextHex : darkTextHex
    }

    /// Effective text color hex: explicit override, else auto from fill, else nil (system primary).
    public static func effectiveTextHex(style: NodeStyle) -> String? {
        if let text = style.textHex, !text.isEmpty {
            return text
        }
        return contrastingTextHex(forFill: style.fillHex)
    }

    public static func parseRGB(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        if s.count == 8 {
            return (
                Double((value >> 16) & 0xFF) / 255,
                Double((value >> 8) & 0xFF) / 255,
                Double(value & 0xFF) / 255
            )
        }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }
}

import Foundation
import SwiftUI

/// Editor-wide color theme inspired by popular Zed / VS Code palettes.
///
/// Canvas, node fills, text, and branch/edge colors all resolve from the theme.
/// Per-node `style.fillHex` / `textHex` / `branchHex` are optional overrides;
/// `nil` always follows the active theme (and updates when the theme changes).
public struct AppTheme: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let subtitle: String
    public let isDark: Bool

    // Canvas / chrome
    public let canvasBackground: String
    public let grid: String
    public let chromeBackground: String
    public let chromeForeground: String
    public let secondaryText: String
    public let separator: String

    // Defaults for unstyled nodes
    public let rootFill: String
    public let rootText: String
    public let nodeFill: String
    public let nodeText: String
    public let branch: String
    public let edge: String
    public let selection: String
    public let searchHighlight: String

    public init(
        id: String,
        name: String,
        subtitle: String,
        isDark: Bool,
        canvasBackground: String,
        grid: String,
        chromeBackground: String,
        chromeForeground: String,
        secondaryText: String,
        separator: String,
        rootFill: String,
        rootText: String,
        nodeFill: String,
        nodeText: String,
        branch: String,
        edge: String,
        selection: String,
        searchHighlight: String
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.isDark = isDark
        self.canvasBackground = canvasBackground
        self.grid = grid
        self.chromeBackground = chromeBackground
        self.chromeForeground = chromeForeground
        self.secondaryText = secondaryText
        self.separator = separator
        self.rootFill = rootFill
        self.rootText = rootText
        self.nodeFill = nodeFill
        self.nodeText = nodeText
        self.branch = branch
        self.edge = edge
        self.selection = selection
        self.searchHighlight = searchHighlight
    }

    // MARK: - Catalog (Zed / VS Code–inspired)

    /// Adaptive system look (uses AppKit semantic colors where possible).
    public static let system = AppTheme(
        id: "system",
        name: "System",
        subtitle: "Follows macOS appearance",
        isDark: false,
        canvasBackground: "",
        grid: "",
        chromeBackground: "",
        chromeForeground: "",
        secondaryText: "",
        separator: "",
        rootFill: "",
        rootText: "",
        nodeFill: "",
        nodeText: "",
        branch: "",
        edge: "",
        selection: "",
        searchHighlight: ""
    )

    /// VS Code Dark+
    public static let vsCodeDark = AppTheme(
        id: "vscode-dark",
        name: "Dark+",
        subtitle: "VS Code",
        isDark: true,
        canvasBackground: "#1E1E1E",
        grid: "#2A2A2A",
        chromeBackground: "#252526",
        chromeForeground: "#CCCCCC",
        secondaryText: "#858585",
        separator: "#3C3C3C",
        rootFill: "#264F78",
        rootText: "#FFFFFF",
        nodeFill: "#2D2D30",
        nodeText: "#D4D4D4",
        branch: "#569CD6",
        edge: "#6A6A6A",
        selection: "#007ACC",
        searchHighlight: "#613214"
    )

    /// VS Code Light+
    public static let vsCodeLight = AppTheme(
        id: "vscode-light",
        name: "Light+",
        subtitle: "VS Code",
        isDark: false,
        canvasBackground: "#FFFFFF",
        grid: "#E8E8E8",
        chromeBackground: "#F3F3F3",
        chromeForeground: "#333333",
        secondaryText: "#6E6E6E",
        separator: "#E0E0E0",
        rootFill: "#ADD6FF",
        rootText: "#000000",
        nodeFill: "#F3F3F3",
        nodeText: "#333333",
        branch: "#001080",
        edge: "#A0A0A0",
        selection: "#0078D4",
        searchHighlight: "#FFE066"
    )

    /// One Dark (Atom / common Zed pick)
    public static let oneDark = AppTheme(
        id: "one-dark",
        name: "One Dark",
        subtitle: "Atom / Zed",
        isDark: true,
        canvasBackground: "#282C34",
        grid: "#2F343E",
        chromeBackground: "#21252B",
        chromeForeground: "#ABB2BF",
        secondaryText: "#5C6370",
        separator: "#3E4451",
        rootFill: "#3E4451",
        rootText: "#E5C07B",
        nodeFill: "#2C313A",
        nodeText: "#ABB2BF",
        branch: "#61AFEF",
        edge: "#4B5263",
        selection: "#528BFF",
        searchHighlight: "#5C3A1E"
    )

    /// Dracula
    public static let dracula = AppTheme(
        id: "dracula",
        name: "Dracula",
        subtitle: "VS Code / Zed",
        isDark: true,
        canvasBackground: "#282A36",
        grid: "#323442",
        chromeBackground: "#21222C",
        chromeForeground: "#F8F8F2",
        secondaryText: "#6272A4",
        separator: "#44475A",
        rootFill: "#44475A",
        rootText: "#FF79C6",
        nodeFill: "#343746",
        nodeText: "#F8F8F2",
        branch: "#BD93F9",
        edge: "#6272A4",
        selection: "#BD93F9",
        searchHighlight: "#4D3800"
    )

    /// Nord
    public static let nord = AppTheme(
        id: "nord",
        name: "Nord",
        subtitle: "Arctic / VS Code",
        isDark: true,
        canvasBackground: "#2E3440",
        grid: "#3B4252",
        chromeBackground: "#3B4252",
        chromeForeground: "#ECEFF4",
        secondaryText: "#D8DEE9",
        separator: "#4C566A",
        rootFill: "#5E81AC",
        rootText: "#ECEFF4",
        nodeFill: "#3B4252",
        nodeText: "#E5E9F0",
        branch: "#88C0D0",
        edge: "#4C566A",
        selection: "#81A1C1",
        searchHighlight: "#4C3A1A"
    )

    /// Catppuccin Mocha
    public static let catppuccinMocha = AppTheme(
        id: "catppuccin-mocha",
        name: "Catppuccin Mocha",
        subtitle: "Zed / VS Code",
        isDark: true,
        canvasBackground: "#1E1E2E",
        grid: "#313244",
        chromeBackground: "#181825",
        chromeForeground: "#CDD6F4",
        secondaryText: "#A6ADC8",
        separator: "#45475A",
        rootFill: "#89B4FA",
        rootText: "#1E1E2E",
        nodeFill: "#313244",
        nodeText: "#CDD6F4",
        branch: "#CBA6F7",
        edge: "#585B70",
        selection: "#89B4FA",
        searchHighlight: "#5C4015"
    )

    /// Tokyo Night
    public static let tokyoNight = AppTheme(
        id: "tokyo-night",
        name: "Tokyo Night",
        subtitle: "VS Code",
        isDark: true,
        canvasBackground: "#1A1B26",
        grid: "#24283B",
        chromeBackground: "#16161E",
        chromeForeground: "#A9B1D6",
        secondaryText: "#565F89",
        separator: "#292E42",
        rootFill: "#7AA2F7",
        rootText: "#1A1B26",
        nodeFill: "#24283B",
        nodeText: "#C0CAF5",
        branch: "#BB9AF7",
        edge: "#3B4261",
        selection: "#7AA2F7",
        searchHighlight: "#4A3A10"
    )

    /// GitHub Dark
    public static let githubDark = AppTheme(
        id: "github-dark",
        name: "GitHub Dark",
        subtitle: "VS Code",
        isDark: true,
        canvasBackground: "#0D1117",
        grid: "#161B22",
        chromeBackground: "#010409",
        chromeForeground: "#E6EDF3",
        secondaryText: "#8B949E",
        separator: "#30363D",
        rootFill: "#1F6FEB",
        rootText: "#FFFFFF",
        nodeFill: "#161B22",
        nodeText: "#E6EDF3",
        branch: "#58A6FF",
        edge: "#30363D",
        selection: "#1F6FEB",
        searchHighlight: "#3D2E00"
    )

    /// Solarized Dark
    public static let solarizedDark = AppTheme(
        id: "solarized-dark",
        name: "Solarized Dark",
        subtitle: "Classic",
        isDark: true,
        canvasBackground: "#002B36",
        grid: "#073642",
        chromeBackground: "#073642",
        chromeForeground: "#93A1A1",
        secondaryText: "#657B83",
        separator: "#586E75",
        rootFill: "#268BD2",
        rootText: "#FDF6E3",
        nodeFill: "#073642",
        nodeText: "#839496",
        branch: "#2AA198",
        edge: "#586E75",
        selection: "#268BD2",
        searchHighlight: "#5C4400"
    )

    /// Zed Pro Light–inspired soft light theme
    public static let zedLight = AppTheme(
        id: "zed-light",
        name: "Zed Light",
        subtitle: "Zed-inspired",
        isDark: false,
        canvasBackground: "#FAFAFA",
        grid: "#EDEDED",
        chromeBackground: "#F5F5F5",
        chromeForeground: "#1A1A1A",
        secondaryText: "#6B6B6B",
        separator: "#E0E0E0",
        rootFill: "#E8F0FE",
        rootText: "#1A1A1A",
        nodeFill: "#FFFFFF",
        nodeText: "#1A1A1A",
        branch: "#5B8DEF",
        edge: "#C8C8C8",
        selection: "#5B8DEF",
        searchHighlight: "#FFF3A3"
    )

    /// Themes that ship with Brainstorm and cannot be removed.
    public static let builtIn: [AppTheme] = [
        .system,
        .vsCodeDark,
        .vsCodeLight,
        .oneDark,
        .dracula,
        .nord,
        .catppuccinMocha,
        .tokyoNight,
        .githubDark,
        .solarizedDark,
        .zedLight,
    ]

    /// Built-in palettes plus imported native Zed theme files.
    public static var all: [AppTheme] {
        builtIn + ThemeLibrary.shared.themes
    }

    public static func theme(id: String) -> AppTheme {
        all.first { $0.id == id } ?? .system
    }

    public var isSystem: Bool { id == "system" }

    /// Whether this palette should paint as dark.
    /// System follows the live macOS color scheme; fixed themes use `isDark`.
    public func resolvesAsDark(in colorScheme: ColorScheme) -> Bool {
        isSystem ? colorScheme == .dark : isDark
    }

    // MARK: - Preferred default for new maps

    private static let preferredDefaultKey = "Brainstorm.preferredThemeID"

    /// Theme used for newly created maps (File → New, first launch, empty window).
    /// Updated whenever the user picks a theme in the editor.
    public static var preferredDefaultID: String {
        let raw = UserDefaults.standard.string(forKey: preferredDefaultKey) ?? system.id
        return theme(id: raw).id
    }

    public static var preferredDefault: AppTheme { theme(id: preferredDefaultID) }

    /// Remember the user's theme choice as the default for future new files.
    public static func setPreferredDefault(_ id: String) {
        UserDefaults.standard.set(theme(id: id).id, forKey: preferredDefaultKey)
    }
}

// MARK: - SwiftUI environment

private struct BrainstormThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .system
}

public extension EnvironmentValues {
    var brainstormTheme: AppTheme {
        get { self[BrainstormThemeKey.self] }
        set { self[BrainstormThemeKey.self] = newValue }
    }
}

// MARK: - Resolved colors

public extension AppTheme {
    func color(_ hex: String, fallback: Color) -> Color {
        guard !hex.isEmpty, let c = Color(hex: hex) else { return fallback }
        return c
    }

    var canvasBackgroundColor: Color {
        // System: under-page / text background so the map tracks light & dark.
        color(canvasBackground, fallback: Color(nsColor: .textBackgroundColor))
    }

    var gridColor: Color {
        color(grid, fallback: Color.primary.opacity(0.06))
    }

    var chromeBackgroundColor: Color {
        // App chrome prefers semantic window color so it always tracks system appearance.
        if isSystem {
            return Color(nsColor: .windowBackgroundColor)
        }
        return color(chromeBackground, fallback: Color(nsColor: .windowBackgroundColor))
    }

    var selectionColor: Color {
        color(selection, fallback: Color.accentColor)
    }

    var edgeColor: Color {
        color(edge, fallback: Color.secondary.opacity(0.55))
    }

    var branchColor: Color {
        color(branch, fallback: Color.accentColor.opacity(0.75))
    }

    var searchHighlightColor: Color {
        color(searchHighlight, fallback: Color.yellow.opacity(0.28))
    }

    /// Default fill for a node that has no custom fill.
    func defaultFill(isRoot: Bool) -> String? {
        let hex = isRoot ? rootFill : nodeFill
        return hex.isEmpty ? nil : hex
    }

    func defaultText(isRoot: Bool) -> String? {
        let hex = isRoot ? rootText : nodeText
        return hex.isEmpty ? nil : hex
    }

    /// Effective fill hex: per-node override, else theme root/node default.
    func resolvedFillHex(style: NodeStyle, isRoot: Bool) -> String? {
        if let fill = style.fillHex?.trimmingCharacters(in: .whitespacesAndNewlines), !fill.isEmpty {
            return fill
        }
        return defaultFill(isRoot: isRoot)
    }

    /// Effective branch/edge hex from a parent node’s style (or theme branch).
    func resolvedBranchHex(style: NodeStyle) -> String? {
        if let branch = style.branchHex?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty {
            return branch
        }
        if !self.branch.isEmpty { return self.branch }
        if !edge.isEmpty { return edge }
        return nil
    }

    /// Resolved SwiftUI text color for a node.
    func resolvedTextColor(style: NodeStyle, isRoot: Bool, isPlaceholder: Bool = false) -> Color {
        if isPlaceholder {
            return color(secondaryText, fallback: .secondary)
        }
        if let hex = style.textHex?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hex.isEmpty,
           let c = Color(hex: hex)
        {
            return c
        }
        // Custom fill without explicit text → auto contrast against that fill.
        if let fill = style.fillHex?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fill.isEmpty,
           let auto = ColorContrast.contrastingTextHex(forFill: fill),
           let c = Color(hex: auto)
        {
            return c
        }
        // Theme default text.
        if let hex = defaultText(isRoot: isRoot), let c = Color(hex: hex) {
            return c
        }
        // Theme fill without theme text → contrast against theme fill.
        if let fill = defaultFill(isRoot: isRoot),
           let auto = ColorContrast.contrastingTextHex(forFill: fill),
           let c = Color(hex: auto)
        {
            return c
        }
        return .primary
    }

    /// Hex strings that belong to this theme’s node/branch palette (for remapping).
    var linkedColorHexes: Set<String> {
        [rootFill, rootText, nodeFill, nodeText, branch, edge, selection]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
            .reduce(into: Set<String>()) { $0.insert($1) }
    }

    /// Map a color that matched `from`’s theme tokens onto `to`’s corresponding token.
    static func remapLinkedHex(_ hex: String?, from: AppTheme, to: AppTheme) -> String? {
        guard let hex else { return nil }
        let key = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        func eq(_ a: String, _ b: String) -> Bool {
            !b.isEmpty && a.caseInsensitiveCompare(b) == .orderedSame
        }
        if eq(key, from.rootFill) { return to.rootFill.isEmpty ? nil : to.rootFill }
        if eq(key, from.nodeFill) { return to.nodeFill.isEmpty ? nil : to.nodeFill }
        if eq(key, from.rootText) { return to.rootText.isEmpty ? nil : to.rootText }
        if eq(key, from.nodeText) { return to.nodeText.isEmpty ? nil : to.nodeText }
        if eq(key, from.branch) || eq(key, from.edge) {
            return to.branch.isEmpty ? (to.edge.isEmpty ? nil : to.edge) : to.branch
        }
        if eq(key, from.selection) { return to.selection.isEmpty ? nil : to.selection }
        // Auto-contrast text for theme fills should follow the new theme fill contrast.
        if eq(key, ColorContrast.lightTextHex) || eq(key, ColorContrast.darkTextHex) {
            return hex // keep absolute contrast; fill remap handles pairing
        }
        return hex // custom color — leave alone
    }
}

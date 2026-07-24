import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Which color channel the shared swatch grid is editing.
private enum StyleColorRole: String, CaseIterable, Identifiable {
    case fill
    case text
    case border
    case branch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fill: return "Fill"
        case .text: return "Text"
        case .border: return "Border"
        case .branch: return "Branch"
        }
    }
}

/// Trailing style sidebar — solid column beside the canvas (not a floating drawer).
/// Uses an explicit ScrollView so mouse-wheel scrolling always works (canvas
/// scroll monitor is scoped to the canvas only).
struct NodeInspectorView: View {
    @Bindable var store: BrainstormStore
    @State private var uiPreferences = BrainstormUIPreferences.shared
    @State private var emojiHistory = EmojiUsageStore.shared
    @State private var showEmojiPalette = false
    @State private var colorRole: StyleColorRole = .fill
    @Environment(\.openWindow) private var openWindow

    private var node: BrainstormNode? { store.selectedNode }

    private var colorsExpanded: Binding<Bool> {
        Binding(
            get: { uiPreferences.colorsExpanded },
            set: { uiPreferences.colorsExpanded = $0 }
        )
    }

    private var typeExpanded: Binding<Bool> {
        Binding(
            get: { uiPreferences.typeExpanded },
            set: { uiPreferences.typeExpanded = $0 }
        )
    }

    private var mediaExpanded: Binding<Bool> {
        Binding(
            get: { uiPreferences.mediaExpanded },
            set: { uiPreferences.mediaExpanded = $0 }
        )
    }

    private var resetExpanded: Binding<Bool> {
        Binding(
            get: { uiPreferences.resetExpanded },
            set: { uiPreferences.resetExpanded = $0 }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            // Explicit edge so the sidebar reads as a layout column, not an overlay.
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().opacity(0.45)
                styleInspector
            }
            .frame(width: BrainstormChrome.inspectorWidth)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity)
        .background { sidebarBackground }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("styleSidebar")
    }

    private var styleInspector: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                themeSection
                if let node {
                    if store.selectedIDs.count > 1 {
                        multiSelectionNote
                    }
                    colorsSection(node)
                    typeSection(node)
                    if store.selectedIDs.count == 1 {
                        mediaSection(node)
                    } else {
                        singleNodeOnlyNote
                    }
                    resetSection()
                } else {
                    emptyState
                        .frame(minHeight: 160)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // Do not use fixedSize(vertical:) here — it freezes ideal height and
            // can prevent collapsible sections from growing after expand.
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "paintpalette.fill")
                .foregroundStyle(Color.accentColor)
            Text(inspectorSummary)
                .font(.headline)
                .accessibilityIdentifier("styleSelectionSummary")
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var inspectorSummary: String {
        return store.selectedIDs.count > 1
            ? "Style · \(store.selectedIDs.count) nodes"
            : "Style"
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("Select a node")
                .font(.callout.weight(.medium))
            Text("Colors, shapes, emoji, and free position live here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    /// Opaque system sidebar fill — tracks light/dark without glass drawer chrome.
    private var sidebarBackground: some View {
        Color(nsColor: .controlBackgroundColor)
            .ignoresSafeArea()
    }

    // MARK: - Sections

    private var multiSelectionNote: some View {
        Label(
            "Changes below apply to all \(store.selectedIDs.count) selected nodes. Values shown are from the primary node.",
            systemImage: "square.stack.3d.up.fill"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private var singleNodeOnlyNote: some View {
        Text("Emoji and images are available when one node is selected.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
    }

    private var themeSection: some View {
        InspectorSection(title: "Map theme") {
            // Same catalog as the toolbar; Manage Themes… is first in the menu.
            Menu {
                ThemeSelectionMenu.items(
                    themeID: store.themeID,
                    onSelect: { store.applyTheme($0) },
                    onManageThemes: {
                        openWindow(id: BrainstormWindowID.themeManager)
                    }
                )
            } label: {
                HStack(spacing: 8) {
                    ThemeSwatchStrip(theme: store.theme)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.theme.name)
                            .foregroundStyle(.primary)
                        Text(store.theme.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("styleSidebarThemeMenu")
            .help("Manage Themes… is at the top of this menu")

            Text(store.theme.isSystem
                 ? "System follows macOS light/dark. Toolbar and chrome always match the system appearance."
                 : "Canvas uses this palette. App chrome still follows macOS light/dark.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Colors (shared grid + role picker)

    private func colorsSection(_ node: BrainstormNode) -> some View {
        InspectorDisclosureSection(title: "Colors", isExpanded: colorsExpanded) {
            Picker("Color role", selection: $colorRole) {
                ForEach(StyleColorRole.allCases) { role in
                    Text(role.title).tag(role)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier("styleColorRolePicker")

            colorGrid(
                palette(for: colorRole),
                selected: selectedHex(for: colorRole, style: node.style)
            ) { hex in
                applyColor(hex, role: colorRole)
            }
            .accessibilityIdentifier("styleColorGrid")

            Text(colorCaption(for: colorRole, style: node.style))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func palette(for role: StyleColorRole) -> [(name: String, hex: String)] {
        switch role {
        case .fill:
            return NodeColorPalette.fills(for: store.theme)
        case .text:
            return NodeColorPalette.texts(for: store.theme)
        case .border, .branch:
            return NodeColorPalette.branches(for: store.theme)
        }
    }

    private func selectedHex(for role: StyleColorRole, style: NodeStyle) -> String? {
        switch role {
        case .fill:
            return style.fillHex
        case .text:
            return isAutoText(style) ? "" : style.textHex
        case .border:
            return style.borderHex
        case .branch:
            return style.branchHex
        }
    }

    private func applyColor(_ hex: String, role: StyleColorRole) {
        let value = hex.isEmpty ? nil : hex
        switch role {
        case .fill:
            store.setFillColor(value)
        case .text:
            store.setTextColor(value)
        case .border:
            store.setBorderColor(value)
        case .branch:
            store.setBranchColor(value)
        }
    }

    private func colorCaption(for role: StyleColorRole, style: NodeStyle) -> String {
        switch role {
        case .fill:
            return style.fillHex == nil
                ? "Using theme \(store.theme.name) fill."
                : "Custom fill. Choose Theme to track the map theme again."
        case .text:
            return isAutoText(style)
                ? "Using theme text (or contrast from fill)."
                : "Custom text color."
        case .border:
            return style.borderHex == nil
                ? "No custom border color."
                : "Custom border color."
        case .branch:
            return style.branchHex == nil
                ? "Using theme branch color."
                : "Custom branch. Choose Theme to track the map theme again."
        }
    }

    // MARK: - Type (shape, weight, size, border width)

    private func typeSection(_ node: BrainstormNode) -> some View {
        InspectorDisclosureSection(title: "Type", isExpanded: typeExpanded) {
            labeledMenu("Shape") {
                Picker("Shape", selection: Binding(
                    get: { node.style.shape },
                    set: { store.setShape($0) }
                )) {
                    ForEach(NodeShape.allCases) { shape in
                        Text(shape.label).tag(shape)
                    }
                }
            }

            HStack(spacing: 12) {
                Toggle("Bold", isOn: Binding(
                    get: { node.style.isBold },
                    set: { store.setBold($0) }
                ))
                .toggleStyle(.checkbox)

                Toggle("Italic", isOn: Binding(
                    get: { node.style.isItalic },
                    set: { store.setItalic($0) }
                ))
                .toggleStyle(.checkbox)
            }

            labeledMenu("Size") {
                Picker("Size", selection: Binding(
                    get: { node.style.fontSize.map(Int.init) ?? 0 },
                    set: { store.setFontSize($0 == 0 ? nil : Double($0)) }
                )) {
                    Text("Default").tag(0)
                    Text("12").tag(12)
                    Text("14").tag(14)
                    Text("16").tag(16)
                    Text("18").tag(18)
                    Text("22").tag(22)
                }
            }

            labeledMenu("Border width") {
                Picker("Width", selection: Binding(
                    get: { node.style.borderWidth.map(Int.init) ?? 0 },
                    set: { store.setBorderWidth($0 == 0 ? nil : Double($0)) }
                )) {
                    Text("Default").tag(0)
                    Text("1 pt").tag(1)
                    Text("2 pt").tag(2)
                    Text("3 pt").tag(3)
                    Text("4 pt").tag(4)
                }
            }
        }
    }

    private func labeledMenu<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            content()
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Media / position (collapsed by default)

    private func mediaSection(_ node: BrainstormNode) -> some View {
        let shortlist = emojiHistory.shortlist(documentEmojis: store.documentEmojis())

        return InspectorDisclosureSection(
            title: "Emoji & stickers",
            isExpanded: mediaExpanded
        ) {
            // Current selection chip
            if let emoji = node.media.emoji, !emoji.isEmpty {
                HStack(spacing: 8) {
                    Text("Current")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button {
                        store.setEmoji(nil)
                    } label: {
                        Text(emoji)
                            .font(.system(size: 28))
                            .frame(width: 40, height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.18))
                            )
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
            }

            EmojiSelectorRow(
                shortlist: shortlist,
                selected: node.media.emoji,
                onSelect: { store.setEmoji($0) },
                onClear: { store.setEmoji(nil) },
                onOpenPicker: { showEmojiPalette = true }
            )
            .background {
                EmojiPickerBridge(isPresented: $showEmojiPalette) { emoji in
                    store.setEmoji(emoji)
                }
                .frame(width: 0, height: 0)
            }

            // Optional paste path for power users
            HStack(spacing: 8) {
                TextField(
                    "Paste emoji",
                    text: Binding(
                        get: { "" },
                        set: { newValue in
                            let n = EmojiUsageStore.normalize(newValue)
                            if !n.isEmpty { store.setEmoji(n) }
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
            }

            Divider().opacity(0.4)

            Text("Icons")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 6)], spacing: 6) {
                ForEach(NodeColorPalette.stickers, id: \.self) { symbol in
                    let isSelected = node.media.sticker == symbol
                    Button {
                        store.setSticker(symbol)
                    } label: {
                        Image(systemName: symbol)
                            .frame(width: 30, height: 30)
                            .background {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.2))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Button("Choose Image…") { pickImage() }
                    .controlSize(.small)
                Button("Clear media") { store.clearMedia() }
                    .controlSize(.small)
            }
        }
    }

    private func resetSection() -> some View {
        InspectorDisclosureSection(
            title: "Reset",
            isExpanded: resetExpanded
        ) {
            Text("Applies to every node on this map.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button("Reset Positions") {
                store.resetAllPositions()
            }
            .controlSize(.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Clear free positions and restore automatic layout for all nodes")
            .accessibilityIdentifier("styleSidebarResetPositions")

            Button("Reset Styles") {
                store.resetAllStyles()
            }
            .controlSize(.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Clear fill, text, branch, border, shape, and font overrides so every node uses the map theme")
            .accessibilityIdentifier("styleSidebarResetStyles")
        }
    }

    private func colorGrid(
        _ colors: [(name: String, hex: String)],
        selected: String?,
        onPick: @escaping (String) -> Void
    ) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 28), spacing: 6)], spacing: 6) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, item in
                ColorSwatchButton(
                    hex: item.hex,
                    name: item.name,
                    isSelected: (selected ?? "") == item.hex
                        || (selected == nil && item.hex.isEmpty)
                ) {
                    onPick(item.hex)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Auto when text is nil (theme or contrast-from-fill at render time).
    private func isAutoText(_ style: NodeStyle) -> Bool {
        style.textHex == nil
            || style.textHex?.isEmpty == true
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP, .tiff, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image for this node"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        let png = Self.thumbnailPNG(from: data, maxSide: 128) ?? data
        store.setImagePNGData(png)
    }

    private static func thumbnailPNG(from data: Data, maxSide: CGFloat) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width),
            pixelsHigh: Int(target.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Section chrome

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Material (not glassEffect) — glass inflated section height in ScrollView.
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

/// Collapsible inspector block. Full header row is the hit target (not a tiny chevron).
private struct InspectorDisclosureSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Use a real control-sized button so AppKit hit-testing in ScrollView works.
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(isExpanded ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapse section" : "Expand section")

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Force layout invalidation when expand state flips (ScrollView + material
        // backgrounds can otherwise keep the previous ideal height).
        .id("\(title)-\(isExpanded)")
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func toggle() {
        isExpanded.toggle()
    }
}

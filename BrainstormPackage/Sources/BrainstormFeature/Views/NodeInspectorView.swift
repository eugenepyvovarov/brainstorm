import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Trailing inspector — style, media, and position for the selected node.
/// Uses an explicit ScrollView so mouse-wheel scrolling always works (canvas
/// scroll monitor is scoped to the canvas only).
struct NodeInspectorView: View {
    @Bindable var store: BrainstormStore
    @State private var emojiHistory = EmojiUsageStore.shared
    @State private var showEmojiPalette = false

    private var node: BrainstormNode? { store.selectedNode }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    themeSection
                    if let node {
                        if store.selectedIDs.count > 1 {
                            multiSelectionNote
                        }
                        fillSection(node)
                        textSection(node)
                        shapeSection(node)
                        borderSection(node)
                        branchSection(node)
                        if store.selectedIDs.count == 1 {
                            mediaSection(node)
                            positionSection(node)
                        } else {
                            singleNodeOnlyNote
                        }
                    } else {
                        emptyState
                            .frame(minHeight: 160)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: BrainstormChrome.inspectorWidth)
        .frame(maxHeight: .infinity)
        .background { inspectorBackground }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "paintpalette.fill")
                .foregroundStyle(Color.accentColor)
            Text(store.selectedIDs.count > 1 ? "Style · \(store.selectedIDs.count) nodes" : "Style")
                .font(.headline)
                .accessibilityIdentifier("styleSelectionSummary")
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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

    @ViewBuilder
    private var inspectorBackground: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: .rect(cornerRadius: 0))
        } else {
            Color(nsColor: .windowBackgroundColor).opacity(0.92)
        }
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
        Text("Emoji, images, and position are available when one node is selected.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
    }

    private var themeSection: some View {
        InspectorSection(title: "Map theme") {
            Picker("Theme", selection: Binding(
                get: { store.themeID },
                set: { store.applyTheme($0) }
            )) {
                ForEach(AppTheme.all) { theme in
                    Text("\(theme.name) — \(theme.subtitle)")
                        .tag(theme.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            ThemeSwatchStrip(theme: store.theme)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(store.theme.isSystem
                 ? "System follows macOS light/dark. Toolbar and chrome always match the system appearance."
                 : "Canvas uses this palette. App chrome still follows macOS light/dark.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func fillSection(_ node: BrainstormNode) -> some View {
        InspectorSection(title: "Fill") {
            colorGrid(NodeColorPalette.fills(for: store.theme), selected: node.style.fillHex) { hex in
                store.setFillColor(hex.isEmpty ? nil : hex)
            }
            Text(node.style.fillHex == nil
                 ? "Using theme \(store.theme.name) fill."
                 : "Custom fill. Choose Theme to track the map theme again.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func textSection(_ node: BrainstormNode) -> some View {
        InspectorSection(title: "Text") {
            colorGrid(
                NodeColorPalette.texts(for: store.theme),
                selected: isAutoText(node.style) ? "" : node.style.textHex
            ) { hex in
                store.setTextColor(hex.isEmpty ? nil : hex)
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
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func shapeSection(_ node: BrainstormNode) -> some View {
        InspectorSection(title: "Shape") {
            // Menu avoids clipping long labels in a narrow sidebar.
            Picker("Shape", selection: Binding(
                get: { node.style.shape },
                set: { store.setShape($0) }
            )) {
                ForEach(NodeShape.allCases) { shape in
                    Text(shape.label).tag(shape)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func branchSection(_ node: BrainstormNode) -> some View {
        InspectorSection(title: "Branch color") {
            colorGrid(NodeColorPalette.branches(for: store.theme), selected: node.style.branchHex) { hex in
                store.setBranchColor(hex.isEmpty ? nil : hex)
            }
            Text(node.style.branchHex == nil
                 ? "Using theme branch color."
                 : "Custom branch. Choose Theme to track the map theme again.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func borderSection(_ node: BrainstormNode) -> some View {
        InspectorSection(title: "Border") {
            colorGrid(
                NodeColorPalette.branches(for: store.theme),
                selected: node.style.borderHex
            ) { hex in
                store.setBorderColor(hex.isEmpty ? nil : hex)
            }

            Picker("Width", selection: Binding(
                get: { node.style.borderWidth.map(Int.init) ?? 0 },
                set: { store.setBorderWidth($0 == 0 ? nil : Double($0)) }
            )) {
                Text("Default width").tag(0)
                Text("1 pt").tag(1)
                Text("2 pt").tag(2)
                Text("3 pt").tag(3)
                Text("4 pt").tag(4)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func mediaSection(_ node: BrainstormNode) -> some View {
        let shortlist = emojiHistory.shortlist(documentEmojis: store.documentEmojis())

        return InspectorSection(title: "Emoji & stickers") {
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

    private func positionSection(_ node: BrainstormNode) -> some View {
        InspectorSection(title: "Position") {
            if node.hasManualPosition {
                Label("Manually positioned", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset Position") { store.resetPosition() }
                    .controlSize(.small)
            } else {
                Text("Automatic layout")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Drag a node to free-position · ⌥R resets · ⌘-drop to reparent")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Button("Reset All Positions") { store.resetAllPositions() }
                .controlSize(.small)
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
        .fixedSize(horizontal: false, vertical: true)
    }
}

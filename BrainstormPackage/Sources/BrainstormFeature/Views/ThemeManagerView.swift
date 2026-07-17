import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A native browser for Zed's theme registry alongside Brainstorm's local
/// built-in and imported theme library.
public struct ThemeManagerView: View {
    @State private var importedFiles = ThemeLibrary.shared.importedFiles
    @State private var registrySearchText = ""
    @State private var registryThemes: [ZedRegistryExtension] = []
    @State private var registrySource: ZedRegistrySource?
    @State private var selectedRegistryID: String?
    @State private var previewRequestGeneration = 0
    @State private var previewedThemeFiles: [ZedNativeThemeFile] = []
    @State private var previewedFiles: [ImportedZedThemeFile] = []
    @State private var selectedPreviewThemeID: String?
    @State private var defaultThemeID = AppTheme.preferredDefaultID
    @State private var isLoadingRegistry = false
    @State private var loadingPreviewID: String?
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var pendingDeletion: ImportedThemeDeletion?

    private var selectedRegistryTheme: ZedRegistryExtension? {
        guard let selectedRegistryID else { return nil }
        return registryThemes.first { $0.id == selectedRegistryID }
    }

    private var previewThemes: [AppTheme] {
        previewedFiles.flatMap(\.themes)
    }

    private var selectedPreviewTheme: AppTheme? {
        guard let selectedPreviewThemeID else { return previewThemes.first }
        return previewThemes.first { $0.id == selectedPreviewThemeID } ?? previewThemes.first
    }

    private var previewTaskID: String {
        "\(selectedRegistryID ?? "none")#\(previewRequestGeneration)"
    }

    private var filteredRegistryThemes: [ZedRegistryExtension] {
        let query = registrySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return registryThemes }
        return registryThemes.filter { theme in
            theme.name.localizedCaseInsensitiveContains(query)
                || theme.id.localizedCaseInsensitiveContains(query)
                || theme.description.localizedCaseInsensitiveContains(query)
                || theme.authors.contains(where: { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var deletionBinding: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }

    public init() {}

    public var body: some View {
        HSplitView {
            ThemeLibraryPane(
                builtInThemes: AppTheme.builtIn,
                importedFiles: importedFiles,
                defaultThemeID: defaultThemeID,
                onSetDefault: setDefault,
                onDelete: { file, theme in
                    pendingDeletion = ImportedThemeDeletion(file: file, theme: theme)
                },
                onImport: importFile,
                onReload: reloadLibrary
            )
            .frame(minWidth: 245, idealWidth: 280, maxWidth: 330)

            ZedRegistryPane(
                searchText: $registrySearchText,
                themes: filteredRegistryThemes,
                totalThemeCount: registryThemes.count,
                source: registrySource,
                selectedThemeID: selectedRegistryID,
                isLoading: isLoadingRegistry,
                onSelect: selectRegistryTheme,
                onRefresh: reloadRegistry
            )
            .frame(minWidth: 310, idealWidth: 370, maxWidth: 440)

            ThemePreviewPane(
                registryTheme: selectedRegistryTheme,
                previewTheme: selectedPreviewTheme,
                previewThemes: previewThemes,
                selectedPreviewThemeID: $selectedPreviewThemeID,
                nativeFileCount: previewedThemeFiles.count,
                isLoading: loadingPreviewID != nil,
                isImporting: isImporting,
                onImport: importSelectedRegistryTheme
            )
            .frame(minWidth: 360, idealWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            reloadLibrary()
            await loadRegistry(forceRefresh: false)
        }
        .task(id: previewTaskID) {
            guard let theme = selectedRegistryTheme else { return }
            await loadPreview(for: theme)
        }
        .alert("Couldn’t Load Zed Theme", isPresented: errorBinding) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Delete Imported Theme?", isPresented: deletionBinding, presenting: pendingDeletion) { deletion in
            Button("Delete", role: .destructive) { delete(deletion) }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { deletion in
            if deletion.removesSourceFile {
                Text("This removes “\(deletion.theme.name)” and its imported Zed source file from Brainstorm. Built-in themes are not affected.")
            } else {
                Text("This removes only the “\(deletion.theme.name)” variant from Brainstorm. The original imported Zed file remains unchanged.")
            }
        }
    }

    private func reloadRegistry() {
        Task { await loadRegistry(forceRefresh: true) }
    }

    private func loadRegistry(forceRefresh: Bool) async {
        guard !isLoadingRegistry else { return }
        isLoadingRegistry = true
        defer { isLoadingRegistry = false }
        do {
            let snapshot = try await ZedThemeRegistry.fetchSnapshot(forceRefresh: forceRefresh)
            registryThemes = snapshot.themes
            registrySource = snapshot.source
            if let selectedRegistryID,
               !registryThemes.contains(where: { $0.id == selectedRegistryID })
            {
                clearPreview()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func selectRegistryTheme(_ theme: ZedRegistryExtension) {
        selectedRegistryID = theme.id
        clearPreview(keepingSelection: true)
        previewRequestGeneration += 1
    }

    private func loadPreview(for theme: ZedRegistryExtension) async {
        loadingPreviewID = theme.id
        defer {
            if loadingPreviewID == theme.id {
                loadingPreviewID = nil
            }
        }
        do {
            let files = try await ZedThemeRegistry.downloadThemeFiles(for: theme)
            try Task.checkCancellation()
            let previews = try ThemeLibrary.shared.previewZedThemeFiles(files, extensionID: theme.id)
            try Task.checkCancellation()
            guard selectedRegistryID == theme.id else { return }
            previewedThemeFiles = files
            previewedFiles = previews
            selectedPreviewThemeID = previews.flatMap(\.themes).first?.id
        } catch is CancellationError {
            return
        } catch {
            guard selectedRegistryID == theme.id else { return }
            clearPreview(keepingSelection: true)
            errorMessage = error.localizedDescription
        }
    }

    private func importSelectedRegistryTheme() {
        guard let extensionID = selectedRegistryID, !previewedThemeFiles.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            _ = try ThemeLibrary.shared.importZedThemeFiles(previewedThemeFiles, extensionID: extensionID)
            reloadLibrary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearPreview(keepingSelection: Bool = false) {
        if !keepingSelection { selectedRegistryID = nil }
        previewedThemeFiles = []
        previewedFiles = []
        selectedPreviewThemeID = nil
        loadingPreviewID = nil
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a native Zed theme JSON file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try ThemeLibrary.shared.importNativeZedTheme(from: url)
            reloadLibrary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ deletion: ImportedThemeDeletion) {
        do {
            try ThemeLibrary.shared.delete(deletion.theme, from: deletion.file)
            reloadLibrary()
        } catch {
            errorMessage = error.localizedDescription
        }
        defaultThemeID = AppTheme.preferredDefaultID
        pendingDeletion = nil
    }

    private func reloadLibrary() {
        ThemeLibrary.shared.reload()
        importedFiles = ThemeLibrary.shared.importedFiles
        defaultThemeID = AppTheme.preferredDefaultID
    }

    private func setDefault(_ id: String) {
        AppTheme.setPreferredDefault(id)
        defaultThemeID = AppTheme.preferredDefaultID
    }
}

private struct ImportedThemeDeletion: Identifiable {
    let file: ImportedZedThemeFile
    let theme: AppTheme

    var id: String { "\(file.id)#\(theme.id)" }
    var removesSourceFile: Bool { file.themes.count == 1 }
}

private struct ThemeLibraryPane: View {
    let builtInThemes: [AppTheme]
    let importedFiles: [ImportedZedThemeFile]
    let defaultThemeID: String
    let onSetDefault: (String) -> Void
    let onDelete: (ImportedZedThemeFile, AppTheme) -> Void
    let onImport: () -> Void
    let onReload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PaneTitle(title: "Theme Library", subtitle: "Installed")

            List {
                if !builtInThemes.isEmpty {
                    Section("Built-in") {
                        ForEach(builtInThemes) { theme in
                            CompactInstalledThemeRow(
                                theme: theme,
                                isDefault: defaultThemeID == theme.id,
                                onSelect: { onSetDefault(theme.id) }
                            )
                            .compactListRow()
                        }
                    }
                }

                if !importedFiles.isEmpty {
                    Section("Imported") {
                        ForEach(importedFiles) { file in
                            ForEach(file.themes) { theme in
                                CompactInstalledThemeRow(
                                    theme: theme,
                                    isDefault: defaultThemeID == theme.id,
                                    onSelect: { onSetDefault(theme.id) },
                                    onDelete: { onDelete(file, theme) }
                                )
                                .compactListRow()
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 32)

            HStack(spacing: 8) {
                Button("Import…", action: onImport)
                    .brainstormGlassButton()
                Button(action: onReload) {
                    Image(systemName: "arrow.clockwise")
                }
                .brainstormGlassButton()
                .accessibilityLabel("Reload installed themes")
                Spacer()
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ZedRegistryPane: View {
    @Binding var searchText: String

    let themes: [ZedRegistryExtension]
    let totalThemeCount: Int
    let source: ZedRegistrySource?
    let selectedThemeID: String?
    let isLoading: Bool
    let onSelect: (ZedRegistryExtension) -> Void
    let onRefresh: () -> Void

    private var subtitle: String {
        switch source {
        case .freshCache:
            "\(totalThemeCount) themes · cached"
        case .staleCache:
            "\(totalThemeCount) themes · offline cache"
        case .network:
            "\(totalThemeCount) themes · Zed Registry"
        case nil:
            totalThemeCount == 0 ? "Native Zed extensions" : "\(totalThemeCount) themes"
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: {
                guard let selectedThemeID,
                      themes.contains(where: { $0.id == selectedThemeID })
                else {
                    return nil
                }
                return selectedThemeID
            },
            set: { id in
                guard let id,
                      id != selectedThemeID,
                      let theme = themes.first(where: { $0.id == id })
                else {
                    return
                }
                onSelect(theme)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                PaneTitle(title: "Zed Themes", subtitle: subtitle)
                Spacer()
                Button(action: onRefresh) {
                    if isLoading, !themes.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .brainstormGlassButton()
                .accessibilityLabel("Refresh Zed theme registry")
                .disabled(isLoading)
            }

            TextField("Search name, author, or description", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("themeManagerRegistrySearch")

            if isLoading, themes.isEmpty {
                Spacer()
                ProgressView("Loading Zed themes…")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if themes.isEmpty {
                Spacer()
                ContentUnavailableView(
                    totalThemeCount == 0 ? "Zed Registry Unavailable" : "No Themes Found",
                    systemImage: totalThemeCount == 0 ? "network.slash" : "magnifyingglass",
                    description: Text(totalThemeCount == 0
                        ? "Refresh the registry or import a local Zed JSON file."
                        : "Try a different name, author, or description.")
                )
                Spacer()
            } else {
                List(selection: selection) {
                    ForEach(themes) { theme in
                        ZedRegistryThemeRow(
                            theme: theme,
                            isSelected: selectedThemeID == theme.id
                        )
                        .tag(theme.id)
                        .compactListRow()
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 44)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ThemePreviewPane: View {
    let registryTheme: ZedRegistryExtension?
    let previewTheme: AppTheme?
    let previewThemes: [AppTheme]
    @Binding var selectedPreviewThemeID: String?
    let nativeFileCount: Int
    let isLoading: Bool
    let isImporting: Bool
    let onImport: () -> Void

    private var importTitle: String {
        nativeFileCount == 1 ? "Import Theme" : "Import \(nativeFileCount) Theme Files"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PaneTitle(title: "Preview", subtitle: registryTheme.map(authorText) ?? "Brainstorm canvas")

            if isLoading {
                Spacer()
                ProgressView("Preparing preview…")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if let registryTheme, let previewTheme {
                VStack(alignment: .leading, spacing: 3) {
                    Text(registryTheme.name)
                        .font(.headline)
                        .lineLimit(1)
                    if !registryTheme.description.isEmpty {
                        Text(registryTheme.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Picker("Variant", selection: $selectedPreviewThemeID) {
                    ForEach(previewThemes) { theme in
                        Text(theme.name).tag(Optional(theme.id))
                    }
                }
                .pickerStyle(.menu)

                ThemeMindMapPreview(theme: previewTheme)
                    .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    ThemeSwatchStrip(theme: previewTheme)
                    Text("\(nativeFileCount) native Zed JSON \(nativeFileCount == 1 ? "file" : "files")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                Button(importTitle, action: onImport)
                    .brainstormGlassButton(prominent: true)
                    .disabled(isImporting || nativeFileCount == 0)
                    .accessibilityIdentifier("themeManagerImportSelected")

                if isImporting {
                    ProgressView("Importing…")
                        .controlSize(.small)
                }
            } else {
                Spacer()
                ContentUnavailableView(
                    "Select a Zed Theme",
                    systemImage: "paintpalette",
                    description: Text("Choose a theme to render a real Brainstorm map before importing it.")
                )
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func authorText(for theme: ZedRegistryExtension) -> String {
        theme.authors.isEmpty ? "Zed extension" : theme.authors.joined(separator: " · ")
    }
}

private struct PaneTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct CompactInstalledThemeRow: View {
    let theme: AppTheme
    let isDefault: Bool
    let onSelect: () -> Void
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    ThemeSwatchStrip(theme: theme)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(theme.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(theme.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: isDefault ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isDefault ? Color.accentColor : Color.secondary.opacity(0.45))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(theme.name), \(isDefault ? "default theme" : "set as default")")

            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete \(theme.name)")
            }
        }
        .frame(minHeight: 34)
    }
}

private struct ZedRegistryThemeRow: View {
    let theme: ZedRegistryExtension
    let isSelected: Bool

    var body: some View {
        rowContent
        .accessibilityLabel("Preview \(theme.name) by \(theme.authors.first ?? "Zed contributor")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var rowContent: some View {
        let content = HStack(spacing: 9) {
            Image(systemName: "paintpalette")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(theme.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(theme.authors.first ?? "Zed contributor")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let count = theme.downloadCount {
                Text(count.formatted(.number.notation(.compactName)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .contentShape(Rectangle())

        if isSelected {
            content
                .brainstormGlassCard(cornerRadius: 9, interactive: true, tint: .accentColor)
        } else {
            content
        }
    }
}

/// A real miniature Brainstorm canvas rendered from the selected theme.
private struct ThemeMindMapPreview: View {
    let theme: AppTheme

    var body: some View {
        GeometryReader { proxy in
            let metrics = PreviewMetrics(size: proxy.size)

            ZStack {
                theme.canvasBackgroundColor
                previewGrid
                previewEdges(metrics: metrics)

                ThemePreviewNode(
                    title: "Main idea",
                    theme: theme,
                    isRoot: true,
                    size: metrics.rootSize
                )
                .position(metrics.rootCenter)

                ThemePreviewNode(
                    title: "Research",
                    theme: theme,
                    isRoot: false,
                    size: metrics.childSize
                )
                .position(metrics.topChildCenter)

                ThemePreviewNode(
                    title: "Plan",
                    theme: theme,
                    isRoot: false,
                    size: metrics.childSize
                )
                .position(metrics.bottomChildCenter)
            }
        }
        .aspectRatio(1.62, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.edgeColor.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(theme.isDark ? 0.28 : 0.08), radius: 8, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Brainstorm map preview using \(theme.name)")
    }

    private var previewGrid: some View {
        Canvas { context, size in
            let step: CGFloat = 28
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(path, with: .color(theme.gridColor.opacity(0.72)), lineWidth: 0.75)
        }
    }

    private func previewEdges(metrics: PreviewMetrics) -> some View {
        Canvas { context, _ in
            for destination in [metrics.topChildCenter, metrics.bottomChildCenter] {
                let from = CGPoint(
                    x: metrics.rootCenter.x + metrics.rootSize.width / 2,
                    y: metrics.rootCenter.y
                )
                let to = CGPoint(
                    x: destination.x - metrics.childSize.width / 2,
                    y: destination.y
                )
                let midX = (from.x + to.x) / 2
                var path = Path()
                path.move(to: from)
                path.addCurve(
                    to: to,
                    control1: CGPoint(x: midX, y: from.y),
                    control2: CGPoint(x: midX, y: to.y)
                )
                context.stroke(
                    path,
                    with: .color(theme.branchColor.opacity(0.9)),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
            }
        }
    }
}

private struct ThemePreviewNode: View {
    let title: String
    let theme: AppTheme
    let isRoot: Bool
    let size: CGSize

    private var cornerRadius: CGFloat {
        isRoot ? BrainstormChrome.rootCorner : BrainstormChrome.nodeCorner
    }

    private var fill: Color {
        let fallback = isRoot
            ? theme.selectionColor.opacity(0.16)
            : Color(nsColor: .controlBackgroundColor)
        return theme.color(theme.defaultFill(isRoot: isRoot) ?? "", fallback: fallback)
    }

    private var textColor: Color {
        theme.resolvedTextColor(style: .default, isRoot: isRoot)
    }

    var body: some View {
        nodeContent
            .modifier(ThemePreviewNodeChrome(
                theme: theme,
                isRoot: isRoot,
                cornerRadius: cornerRadius,
                fill: fill
            ))
            .shadow(
                color: .black.opacity(theme.isDark ? 0.34 : 0.09),
                radius: isRoot ? 4 : 3,
                y: 1
            )
    }

    private var nodeContent: some View {
        Text(title)
            .font(.system(size: isRoot ? 13 : 12, weight: isRoot ? .semibold : .medium))
            .foregroundStyle(textColor)
            .lineLimit(1)
            .frame(width: size.width, height: size.height)
    }
}

private struct ThemePreviewNodeChrome: ViewModifier {
    let theme: AppTheme
    let isRoot: Bool
    let cornerRadius: CGFloat
    let fill: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if theme.isSystem, #available(macOS 26.0, *) {
            content
                .glassEffect(
                    isRoot ? .regular.tint(theme.selectionColor.opacity(0.12)) : .regular,
                    in: .rect(cornerRadius: cornerRadius)
                )
                .overlay(shape.stroke(theme.edgeColor.opacity(0.6), lineWidth: isRoot ? 1.5 : 1))
        } else {
            content
                .background(fill, in: shape)
                .overlay(shape.stroke(theme.edgeColor.opacity(0.6), lineWidth: isRoot ? 1.5 : 1))
        }
    }
}

private struct PreviewMetrics {
    let rootSize: CGSize
    let childSize: CGSize
    let rootCenter: CGPoint
    let topChildCenter: CGPoint
    let bottomChildCenter: CGPoint

    init(size: CGSize) {
        let rootWidth = min(max(size.width * 0.26, 92), 132)
        let childWidth = min(max(size.width * 0.25, 88), 124)
        rootSize = CGSize(width: rootWidth, height: 44)
        childSize = CGSize(width: childWidth, height: 40)
        rootCenter = CGPoint(x: size.width * 0.24, y: size.height * 0.5)
        topChildCenter = CGPoint(x: size.width * 0.76, y: size.height * 0.31)
        bottomChildCenter = CGPoint(x: size.width * 0.76, y: size.height * 0.69)
    }
}

private extension View {
    func compactListRow() -> some View {
        listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

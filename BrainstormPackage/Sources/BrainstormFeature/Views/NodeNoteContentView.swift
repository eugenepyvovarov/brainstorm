import AppKit
import SwiftUI
import WebKit

public enum NodeNoteRenderMode: Sendable {
    case preview
    case canvas
    case presentation
    case staticExport
}

/// Safe, read-only rendering shared by note previews, map cards, presentation,
/// and the PNG/PDF export surface.
public struct NodeNoteContentView: View {
    @Environment(\.brainstormTheme) private var theme

    private let note: NodeNote
    private let mode: NodeNoteRenderMode

    public init(note: NodeNote, mode: NodeNoteRenderMode) {
        self.note = note
        self.mode = mode
    }

    public var body: some View {
        let metrics = NodeNoteRendering.metrics(for: mode)
        VStack(alignment: .leading, spacing: metrics.blockSpacing) {
            noteBody

            ForEach(note.attachments, id: \.id) { attachment in
                attachmentView(attachment, metrics: metrics)
            }
        }
        .font(.system(size: metrics.fontSize))
        .foregroundStyle(primaryTextColor)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.vertical, metrics.verticalPadding)
        .background { cardBackground }
        .overlay { cardBorder }
        .clipShape(cardShape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Node note")
    }

    @ViewBuilder
    private var noteBody: some View {
        let blocks = NodeNoteRendering.blocks(from: note.bodyMarkdown)
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            switch block {
            case .paragraph(let lines):
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, runs in
                        inlineText(runs)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .unordered(let items):
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, runs in
                        listRow(marker: "•", runs: runs)
                    }
                }
            case .ordered(let start, let items):
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, runs in
                        listRow(marker: "\(start + index).", runs: runs)
                    }
                }
            }
        }
    }

    private func listRow(
        marker: String,
        runs: [NodeNoteInlineRun]
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .foregroundStyle(secondaryTextColor)
                .frame(minWidth: mode == .presentation ? 22 : 14, alignment: .trailing)
            inlineText(runs)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inlineText(_ runs: [NodeNoteInlineRun]) -> Text {
        var result = AttributedString()
        for run in runs {
            var value = AttributedString(run.text)
            switch run.style {
            case .plain:
                break
            case .bold:
                value.inlinePresentationIntent = .stronglyEmphasized
            case .italic:
                value.inlinePresentationIntent = .emphasized
            case .boldItalic:
                value.inlinePresentationIntent = [
                    .stronglyEmphasized,
                    .emphasized,
                ]
            }
            value.link = run.linkDestination
            result.append(value)
        }
        return Text(result)
    }

    @ViewBuilder
    private func attachmentView(
        _ attachment: NodeNoteAttachment,
        metrics: NodeNoteRendering.Metrics
    ) -> some View {
        switch attachment {
        case .image(let image):
            VStack(alignment: .leading, spacing: metrics.blockSpacing) {
                if let data = Data(base64Encoded: image.pngBase64),
                   let nsImage = NSImage(data: data)
                {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: metrics.maximumImageHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityLabel(
                            NodeNoteRendering.nonEmpty(image.altText) ?? "Note image"
                        )
                } else {
                    unavailableMedia(
                        systemName: "photo.badge.exclamationmark",
                        label: "Image unavailable"
                    )
                }
                if let caption = NodeNoteRendering.nonEmpty(image.caption) {
                    Text(caption)
                        .font(.system(size: max(10, metrics.fontSize - 1)))
                        .foregroundStyle(secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .youtube(let youtube):
            VStack(alignment: .leading, spacing: metrics.blockSpacing) {
                if mode == .presentation {
                    NodeNoteYouTubePlayerView(attachment: youtube)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    youtubeCard(youtube, metrics: metrics)
                }
                if let caption = NodeNoteRendering.nonEmpty(youtube.caption) {
                    Text(caption)
                        .font(.system(size: max(10, metrics.fontSize - 1)))
                        .foregroundStyle(secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if mode == .presentation {
                    Link("Open on YouTube", destination: youtube.canonicalURL)
                        .font(.system(size: max(10, metrics.fontSize - 1)))
                        .foregroundStyle(secondaryTextColor)
                        .marksPresentationInteractiveControl()
                }
            }
        }
    }

    private func youtubeCard(
        _ youtube: NoteYouTubeAttachment,
        metrics: NodeNoteRendering.Metrics
    ) -> some View {
        StaticYouTubeNoteCard(
            attachment: youtube,
            metrics: metrics,
            mode: mode,
            secondaryColor: secondaryTextColor
        )
    }

    private func unavailableMedia(systemName: String, label: String) -> some View {
        Label(label, systemImage: systemName)
            .foregroundStyle(secondaryTextColor)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(secondaryTextColor.opacity(0.08))
            )
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: mode == .presentation ? 0 : 10,
            style: .continuous
        )
    }

    @ViewBuilder
    private var cardBackground: some View {
        if mode == .presentation {
            Color.clear
        } else {
            theme.chromeBackgroundColor
        }
    }

    @ViewBuilder
    private var cardBorder: some View {
        if mode != .presentation {
            cardShape
                .strokeBorder(secondaryTextColor.opacity(0.2), lineWidth: 1)
        }
    }

    private var primaryTextColor: Color {
        theme.color(theme.chromeForeground, fallback: .primary)
    }

    private var secondaryTextColor: Color {
        theme.color(theme.secondaryText, fallback: .secondary)
    }
}

private struct StaticYouTubeNoteCard: View {
    let attachment: NoteYouTubeAttachment
    let metrics: NodeNoteRendering.Metrics
    let mode: NodeNoteRenderMode
    let secondaryColor: Color

    var body: some View {
        HStack(spacing: horizontalSpacing) {
            playIcon
            metadata
        }
        .padding(cardPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: metrics.youtubeCardHeight,
            alignment: .leading
        )
        .background(cardShape.fill(secondaryColor.opacity(0.08)))
        .overlay(cardShape.strokeBorder(secondaryColor.opacity(0.18), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("YouTube video, \(attachment.canonicalURL.absoluteString)")
    }

    private var playIcon: some View {
        Image(systemName: "play.rectangle.fill")
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(.red)
            .accessibilityHidden(true)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("YouTube video")
                .fontWeight(.semibold)
            Text(attachment.canonicalURL.absoluteString)
                .font(.system(
                    size: max(9, metrics.fontSize - 2),
                    design: .monospaced
                ))
                .foregroundStyle(secondaryColor)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var horizontalSpacing: CGFloat {
        mode == .presentation ? 16 : 10
    }

    private var cardPadding: CGFloat {
        mode == .presentation ? 16 : 10
    }

    private var iconSize: CGFloat {
        mode == .presentation ? 38 : 24
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }
}

/// Presentation-only privacy-enhanced YouTube player.
///
/// A presentation slide shows the real YouTube player immediately, including
/// YouTube's own thumbnail and playback controls. Playback still starts only
/// after the viewer activates the player.
public struct NodeNoteYouTubePlayerView: View {
    private let attachment: NoteYouTubeAttachment

    public init(attachment: NoteYouTubeAttachment) {
        self.attachment = attachment
    }

    public var body: some View {
        PrivacyEnhancedYouTubeWebView(attachment: attachment)
            .marksPresentationInteractiveControl()
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel("YouTube video player")
            .accessibilityHint(
                "Loads the privacy-enhanced player from youtube-nocookie.com. Playback requires network access."
            )
    }
}

private struct PrivacyEnhancedYouTubeWebView: NSViewRepresentable {
    let attachment: NoteYouTubeAttachment

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.preferences.isElementFullscreenEnabled = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = false
        loadPlayer(in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        loadPlayer(in: webView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.loadedPlayerKey = nil
        webView.stopLoading()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        webView.navigationDelegate = nil
    }

    private var playerKey: String {
        "\(attachment.videoID):\(attachment.startSeconds ?? 0)"
    }

    private func loadPlayer(in webView: WKWebView, coordinator: Coordinator) {
        guard coordinator.loadedPlayerKey != playerKey else { return }
        coordinator.loadedPlayerKey = playerKey
        webView.loadHTMLString(
            NodeNoteRendering.nativeYouTubePlayerDocument(
                videoID: attachment.videoID,
                startSeconds: attachment.startSeconds
            ),
            baseURL: NodeNoteRendering.nativeYouTubeClientPageURL
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedPlayerKey: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url.scheme == "about"
                || url.host == "selfhosted.ninja"
                || url.host == "www.youtube-nocookie.com"
                || url.host == "youtube-nocookie.com"
            {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}

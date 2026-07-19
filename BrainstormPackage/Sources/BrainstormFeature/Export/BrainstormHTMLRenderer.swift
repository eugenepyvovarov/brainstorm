import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import SwiftUI

/// Builds Brainstorm's read-only web scene from the same layout snapshot as the live canvas.
///
/// The map is deliberately not rasterized. Branches and card chrome are inline SVG, while
/// titles and media are semantic HTML positioned at LayoutEngine's exact integral frames.
@MainActor
enum BrainstormHTMLRenderer {
    static func data(
        layout: LayoutResult,
        rootID: UUID,
        theme: AppTheme,
        colorScheme: ColorScheme,
        mapTitle: String,
        root: BrainstormNode,
        options: BrainstormExportOptions
    ) -> Data {
        let palette = HTMLPalette(theme: theme, colorScheme: colorScheme)
        let width = number(layout.contentSize.width)
        let height = number(layout.contentSize.height)
        let normalizedTitle = normalizeTitle(mapTitle)
        let documentTitle = normalizedTitle.isEmpty
            ? "Brainstorm Mind Map"
            : "\(normalizedTitle) — Brainstorm"
        let mapDescription = normalizedTitle.isEmpty
            ? "Brainstorm mind map"
            : "Mind map: \(normalizedTitle)"

        let branches = layout.edges
            .map { branchMarkup($0, theme: theme, palette: palette) }
            .joined(separator: "\n")
        // Presentation uses the same geometry as a fully expanded canvas, even
        // when the saved map has folded branches. This lets the web camera
        // retrace the real hierarchy while DFS moves between branch leaves.
        let presentationLayout = LayoutEngine().layout(
            root: root,
            noteInclusion: .none,
            placementPolicy: .allDescendants
        )
        let presentationSequence = PresentationSequence(
            root: root,
            layout: presentationLayout
        )
        let presentationNodes = presentationSequence.items
        let presentationWidth = number(presentationLayout.contentSize.width)
        let presentationHeight = number(presentationLayout.contentSize.height)
        let presentationBranches = presentationLayout.edges
            .map { branchMarkup($0, theme: theme, palette: palette) }
            .joined(separator: "\n")
        let includedNotes: [UUID: NodeNote] = Dictionary(
            uniqueKeysWithValues: presentationNodes.compactMap { item -> (UUID, NodeNote)? in
                guard let note = item.node.note,
                      options.noteInclusion.includes(note)
                else {
                    return nil
                }
                return (item.id, note)
            }
        )
        // A noted map node owns its complete front/back surface so the visible
        // node itself can flip. Keep only unnoted chrome in the shared SVG;
        // otherwise a second static shape would remain visible behind the
        // note back face.
        let shapes = layout.nodes
            .filter { includedNotes[$0.id] == nil }
            .map {
                shapeMarkup(
                    $0,
                    isRoot: $0.id == rootID,
                    theme: theme,
                    palette: palette
                )
            }
            .joined(separator: "\n")
        let nodes = layout.nodes
            .map {
                nodeMarkup(
                    $0,
                    isRoot: $0.id == rootID,
                    note: includedNotes[$0.id],
                    theme: theme,
                    palette: palette
                )
            }
            .joined(separator: "\n")
        let presentationTitles = Dictionary(
            presentationNodes.map {
                (
                    $0.id,
                    displayedTitle($0.node.title, isRoot: $0.id == rootID)
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
        let presentationSlides = presentationNodes
            .enumerated()
            .map { index, item in
                presentationSlideMarkup(
                    item,
                    index: index,
                    count: presentationNodes.count,
                    isRoot: item.id == rootID,
                    previousRelationship: index > 0
                        ? presentationSequence.relationship(from: index, to: index - 1)
                        : nil,
                    nextRelationship: index + 1 < presentationNodes.count
                        ? presentationSequence.relationship(from: index, to: index + 1)
                        : nil,
                    previousRoute: index > 0
                        ? presentationSequence.traversalRoute(from: index, to: index - 1)
                        : nil,
                    nextRoute: index + 1 < presentationNodes.count
                        ? presentationSequence.traversalRoute(from: index, to: index + 1)
                        : nil,
                    presentationTitles: presentationTitles,
                    noteInclusion: options.noteInclusion,
                    theme: theme,
                    palette: palette
                )
            }
            .joined(separator: "\n")
        let colorSchemeName = palette.isDark ? "dark" : "light"

        let htmlTemplate = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta
            http-equiv="Content-Security-Policy"
            content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'sha256-__BRAINSTORM_SCRIPT_SHA256__'; frame-src https://www.youtube-nocookie.com; connect-src 'none'; media-src 'none'; font-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none';"
          >
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <meta name="color-scheme" content="\(colorSchemeName)">
          <title>\(escapeHTML(documentTitle))</title>
          <style>
            :root {
              color-scheme: \(colorSchemeName);
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
            }
            * { box-sizing: border-box; }
            html, body {
              width: 100%;
              height: 100%;
              margin: 0;
              overflow: hidden;
              overscroll-behavior: none;
            }
            body {
              background: var(--canvas);
              color: \(palette.primary.css);
            }
            #viewport {
              position: fixed;
              inset: 0;
              overflow: hidden;
              cursor: grab;
              touch-action: none;
              user-select: none;
              -webkit-user-select: none;
              -webkit-touch-callout: none;
              background-color: var(--canvas);
              background-image:
                linear-gradient(to right, var(--grid) 1px, transparent 1px),
                linear-gradient(to bottom, var(--grid) 1px, transparent 1px);
              background-size: 32px 32px;
              background-position: 0 0;
            }
            #viewport.dragging { cursor: grabbing; }
            #viewport.note-open { touch-action: pan-y; }
            #stage {
              position: absolute;
              top: 0;
              left: 0;
              width: \(width)px;
              height: \(height)px;
              transform-origin: 0 0;
              will-change: transform;
              pointer-events: none;
            }
            #branches,
            #node-shapes,
            #nodes {
              position: absolute;
              inset: 0;
              width: \(width)px;
              height: \(height)px;
              overflow: visible;
            }
            #branches,
            #node-shapes {
              display: block;
              pointer-events: none;
            }
            #nodes {
              margin: 0;
              padding: 0;
              border: 0;
            }
            .node {
              position: absolute;
              display: flex;
              align-items: center;
              gap: var(--node-gap, 0px);
              min-width: 0;
              margin: 0;
              padding: var(--node-padding-y, 10px) 16px;
              color: var(--node-text);
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
              font-size: var(--node-font-size);
              font-style: var(--node-font-style);
              font-weight: var(--node-font-weight);
              line-height: var(--node-line-height);
              pointer-events: none;
            }
            .node[data-has-note="true"] {
              pointer-events: auto;
              cursor: pointer;
            }
            .node[data-has-note="true"]:focus-visible {
              outline: 2px solid var(--accent);
              outline-offset: 3px;
            }
            .node.map-node-flippable {
              display: block;
              z-index: 2;
              overflow: visible;
              padding: 0;
            }
            .node.map-node-flippable[data-face="note"] {
              z-index: 12;
            }
            .map-node-flip {
              position: relative;
              width: 100%;
              height: 100%;
              transform-origin: center;
              transform-style: preserve-3d;
              transition: transform 560ms cubic-bezier(0.2, 0.76, 0.18, 1);
            }
            .node[data-face="note"] .map-node-flip {
              transform: perspective(720px) rotateY(180deg);
            }
            .map-node-front,
            .map-node-note-back {
              position: absolute;
              backface-visibility: hidden;
              -webkit-backface-visibility: hidden;
            }
            .map-node-front {
              inset: 0;
              display: flex;
              min-width: 0;
              align-items: center;
              gap: var(--node-gap, 0px);
              padding: var(--node-padding-y, 10px) 16px;
            }
            .map-node-front .node-title,
            .map-node-front .node-media {
              position: relative;
              z-index: 1;
            }
            .map-node-inline-shape {
              position: absolute;
              z-index: 0;
              inset: 0;
              display: block;
              width: 100%;
              height: 100%;
              overflow: visible;
              pointer-events: none;
            }
            .map-node-note-back {
              top: 50%;
              left: 50%;
              display: flex;
              width: min(340px, calc(100vw - 32px));
              height: min(360px, max(180px, calc(100vh - 144px)));
              flex-direction: column;
              overflow: hidden;
              border: 1px solid var(--note-border);
              border-radius: 22px;
              background: var(--note-background);
              color: var(--note-text);
              box-shadow: 0 18px 46px rgba(0, 0, 0, 0.25);
              font-size: 15px;
              font-style: normal;
              font-weight: 400;
              line-height: 1.48;
              transform:
                translate(-50%, -50%)
                rotateY(180deg)
                scale(var(--map-note-counter-scale, 1));
              transform-origin: center;
              user-select: text;
              -webkit-user-select: text;
            }
            .map-node-note-header {
              display: flex;
              flex: 0 0 auto;
              align-items: center;
              justify-content: space-between;
              gap: 10px;
              padding: 12px 12px 10px 14px;
              border-bottom: 1px solid var(--note-border);
            }
            .map-node-note-header strong {
              min-width: 0;
              overflow: hidden;
              font-size: 14px;
              font-weight: 600;
              text-overflow: ellipsis;
              white-space: nowrap;
            }
            .map-node-note-close {
              flex: 0 0 auto;
              min-height: 30px;
              padding: 4px 9px;
              border: 1px solid var(--note-border);
              border-radius: 999px;
              background: rgba(127, 127, 127, 0.08);
              cursor: pointer;
            }
            .map-node-note-close:hover,
            .map-node-note-close:focus-visible {
              border-color: var(--accent);
              color: var(--accent);
            }
            .map-node-note-close:focus-visible {
              outline: 2px solid var(--accent);
              outline-offset: 2px;
            }
            .map-node-note-scroll {
              flex: 1 1 auto;
              overflow: auto;
              overscroll-behavior: contain;
              padding: 14px;
              touch-action: pan-y;
            }
            .map-node-note-scroll .note-media img {
              max-height: 220px;
            }
            .map-node-front[aria-hidden="true"],
            .map-node-note-back[aria-hidden="true"] {
              pointer-events: none;
            }
            .node-title {
              display: flex;
              flex: 1 1 auto;
              min-width: 0;
              max-height: calc(var(--node-line-height) * 3);
              flex-direction: column;
              justify-content: center;
              overflow: hidden;
            }
            .node-line {
              display: block;
              height: var(--node-line-height);
              min-height: var(--node-line-height);
              overflow: hidden;
              white-space: pre;
              text-overflow: clip;
            }
            .node-media {
              display: flex;
              flex: 0 0 var(--media-size);
              width: var(--media-size);
              height: var(--media-size);
              align-items: center;
              justify-content: center;
              overflow: hidden;
            }
            .node-emoji {
              font-family: "Apple Color Emoji", "Segoe UI Emoji", sans-serif;
              font-size: var(--media-font-size);
              font-style: normal;
              font-weight: 400;
              line-height: var(--media-size);
              text-align: center;
              white-space: nowrap;
            }
            .node-image,
            .sticker-image {
              display: block;
              width: 100%;
              height: 100%;
            }
            .node-image {
              border-radius: 5px;
              object-fit: cover;
            }
            .sticker-image { object-fit: contain; }
            button, a { font: inherit; }
            button { color: inherit; }
            [hidden] { display: none !important; }
            .note-sticker-icon {
              display: block;
              width: 16px;
              height: 16px;
              flex: 0 0 16px;
              color: var(--accent);
              opacity: 0.68;
              pointer-events: none;
            }
            .map-note-marker {
              position: absolute;
              z-index: 3;
              display: grid;
              width: 16px;
              height: 16px;
              place-items: center;
              padding: 0;
              border: 0;
              background: transparent;
              opacity: 0.62;
              pointer-events: none;
            }
            .map-note-marker .note-sticker-icon {
              width: 13px;
              height: 13px;
              flex-basis: 13px;
            }
            .map-note-marker .note-detail-line { display: none; }
            .map-note-marker[data-saved-visible="false"] { opacity: 0.42; }
            .note-body p { margin: 0 0 0.65em; }
            .note-body p:last-child { margin-bottom: 0; }
            .note-body ul,
            .note-body ol {
              margin: 0.25em 0 0.7em;
              padding-left: 1.5em;
            }
            .note-body li + li { margin-top: 0.2em; }
            .note-body a {
              color: var(--accent);
              text-decoration-thickness: 1px;
              text-underline-offset: 0.14em;
              overflow-wrap: anywhere;
            }
            .note-attachments {
              display: grid;
              gap: 10px;
              margin-top: 10px;
            }
            .note-media {
              min-width: 0;
              margin: 0;
            }
            .note-media img {
              display: block;
              width: 100%;
              max-height: 280px;
              border-radius: 8px;
              object-fit: contain;
              background: rgba(127, 127, 127, 0.08);
            }
            .note-media figcaption {
              margin-top: 6px;
              color: var(--note-secondary);
              font-size: 0.9em;
            }
            .youtube-card {
              display: grid;
              grid-template-columns: auto minmax(0, 1fr);
              gap: 10px;
              width: 100%;
              min-height: 76px;
              align-items: center;
              padding: 10px;
              border: 1px solid var(--note-border);
              border-radius: 10px;
              background: rgba(127, 127, 127, 0.08);
              color: inherit;
              text-align: left;
              cursor: pointer;
            }
            .youtube-host {
              width: 100%;
              min-height: 76px;
            }
            .youtube-host[hidden] { display: none; }
            .youtube-card[hidden] { display: none; }
            .youtube-card .play {
              color: #E62117;
              font-size: 28px;
              line-height: 1;
            }
            .youtube-meta {
              min-width: 0;
              overflow-wrap: anywhere;
            }
            .youtube-meta strong { display: block; }
            .youtube-meta small {
              display: block;
              margin-top: 3px;
              color: var(--note-secondary);
            }
            .youtube-frame {
              display: block;
              width: 100%;
              min-height: 200px;
              aspect-ratio: 16 / 9;
              border: 0;
              border-radius: 10px;
              background: #000;
            }
            .youtube-link {
              display: inline-block;
              margin-top: 6px;
              color: var(--accent);
              overflow-wrap: anywhere;
            }
            #viewer-controls {
              position: fixed;
              z-index: 100;
              top: max(12px, env(safe-area-inset-top));
              left: 50%;
              display: flex;
              align-items: center;
              gap: 6px;
              max-width: calc(100vw - 24px);
              padding: 6px;
              border: 1px solid var(--toolbar-border);
              border-radius: 999px;
              background: var(--toolbar-background);
              box-shadow: 0 8px 28px rgba(0, 0, 0, 0.16);
              transform: translateX(-50%);
              backdrop-filter: blur(18px);
              -webkit-backdrop-filter: blur(18px);
            }
            #viewer-controls button {
              min-height: 32px;
              padding: 5px 11px;
              border: 0;
              border-radius: 999px;
              background: transparent;
              cursor: pointer;
            }
            #viewer-controls button[aria-pressed="true"] {
              background: var(--control-active);
              color: var(--control-active-text);
            }
            #brainstorm-attribution {
              position: fixed;
              z-index: 90;
              right: max(12px, env(safe-area-inset-right));
              bottom: max(12px, env(safe-area-inset-bottom));
              display: inline-flex;
              width: 40px;
              height: 30px;
              min-height: 30px;
              justify-content: center;
              align-items: center;
              padding: 4px 5px;
              border: 0;
              border-radius: 9px;
              background: transparent;
              text-decoration: none;
              opacity: 0.68;
              transition:
                opacity 160ms ease,
                background-color 160ms ease,
                transform 160ms ease;
            }
            #brainstorm-attribution:hover,
            #brainstorm-attribution:focus-visible {
              background: var(--toolbar-background);
              opacity: 1;
              transform: translateY(-1px);
            }
            #brainstorm-attribution:focus-visible {
              outline: 2px solid var(--accent);
              outline-offset: 2px;
            }
            .brainstorm-attribution-logo {
              display: block;
              width: 28px;
              height: 28px;
            }
            .brainstorm-attribution-logo-tile {
              fill: var(--accent);
            }
            .brainstorm-attribution-logo-branch {
              fill: none;
              stroke: var(--accent-contrast);
            }
            .brainstorm-attribution-logo-node {
              fill: var(--accent-contrast);
            }
            #presentation-progress {
              min-width: 4.5em;
              padding: 0 8px;
              color: var(--note-secondary);
              font-variant-numeric: tabular-nums;
              text-align: center;
            }
            .presentation-edge-navigation {
              position: fixed;
              z-index: 110;
              top: 50%;
              display: inline-flex;
              width: 48px;
              height: 48px;
              align-items: center;
              justify-content: center;
              padding: 0;
              border: 1px solid var(--toolbar-border);
              border-radius: 999px;
              background: var(--toolbar-background);
              box-shadow: 0 8px 28px rgba(0, 0, 0, 0.18);
              color: var(--accent);
              cursor: pointer;
              opacity: 0.82;
              transform: translateY(-50%);
              transition:
                opacity 160ms ease,
                background-color 160ms ease,
                transform 160ms ease;
              backdrop-filter: blur(18px);
              -webkit-backdrop-filter: blur(18px);
              -webkit-tap-highlight-color: transparent;
              touch-action: manipulation;
            }
            .presentation-edge-navigation[hidden] {
              display: none;
            }
            .presentation-edge-navigation:hover,
            .presentation-edge-navigation:focus-visible {
              background: var(--control-active);
              color: var(--control-active-text);
              opacity: 1;
            }
            .presentation-edge-navigation:focus-visible {
              outline: 2px solid var(--accent);
              outline-offset: 3px;
            }
            .presentation-edge-navigation:active {
              transform: translateY(-50%) scale(0.94);
            }
            .presentation-edge-navigation svg {
              display: block;
              width: 25px;
              height: 25px;
              fill: none;
              stroke: currentColor;
              stroke-linecap: round;
              stroke-linejoin: round;
              stroke-width: 2.25;
            }
            #presentation-previous-button {
              left: max(12px, env(safe-area-inset-left));
            }
            #presentation-next-button {
              right: max(12px, env(safe-area-inset-right));
            }
            #presentation {
              --camera-x: 0px;
              --camera-y: 0px;
              --presentation-travel-duration: 440ms;
              position: fixed;
              z-index: 20;
              inset: 0;
              overflow: hidden;
              background-color: var(--canvas);
              background-image:
                radial-gradient(circle at 50% 45%, var(--presentation-glow), transparent 52%),
                linear-gradient(to right, var(--grid) 1px, transparent 1px),
                linear-gradient(to bottom, var(--grid) 1px, transparent 1px);
              background-size: auto, 32px 32px, 32px 32px;
              background-position:
                center,
                calc(50% - var(--camera-x)) calc(50% - var(--camera-y)),
                calc(50% - var(--camera-x)) calc(50% - var(--camera-y));
            }
            #presentation-stage {
              position: absolute;
              inset: 0;
              overflow: hidden;
              overflow: clip;
              touch-action: pan-y;
              user-select: none;
              -webkit-user-select: none;
            }
            #presentation-world {
              position: absolute;
              top: 50%;
              left: 50%;
              width: \(presentationWidth)px;
              height: \(presentationHeight)px;
              transform-origin: 0 0;
              will-change: auto;
            }
            #presentation-world-branches {
              position: absolute;
              z-index: 0;
              inset: 0;
              display: block;
              width: \(presentationWidth)px;
              height: \(presentationHeight)px;
              overflow: visible;
              pointer-events: none;
            }
            #presentation-world-branches path {
              transition:
                opacity var(--presentation-travel-duration)
                cubic-bezier(0.22, 0.8, 0.2, 1);
              vector-effect: non-scaling-stroke;
            }
            .presentation-slide {
              --presentation-render-scale: 1;
              position: absolute;
              z-index: 1;
              overflow: visible;
              opacity: 0.46;
              pointer-events: none;
              transform-origin: 0 0;
              -webkit-font-smoothing: antialiased;
              text-rendering: geometricPrecision;
              transition:
                opacity var(--presentation-travel-duration)
                cubic-bezier(0.22, 0.8, 0.2, 1);
            }
            .presentation-slide[data-position="current"] {
              z-index: 4;
              opacity: 1;
              pointer-events: auto;
            }
            .presentation-slide[data-position="current"]
              .presentation-node-shape {
              filter: drop-shadow(0 10px 18px rgba(0, 0, 0, 0.22));
            }
            .presentation-slide[data-position="current"]
              .presentation-node-front {
              cursor: pointer;
            }
            .presentation-slide[data-position="previous"] {
              z-index: 3;
              opacity: 0.68;
              cursor: pointer;
              pointer-events: auto;
            }
            .presentation-slide[data-position="next"] {
              z-index: 3;
              opacity: 0.68;
              cursor: pointer;
              pointer-events: auto;
            }
            .presentation-slide[data-position="context"] {
              cursor: pointer;
              pointer-events: auto;
            }
            .presentation-slide:focus-visible {
              outline: none;
            }
            .presentation-slide:focus-visible .presentation-node-selection {
              opacity: 1;
              stroke-width: 3.25;
            }
            .presentation-flip {
              position: relative;
              width: 100%;
              height: 100%;
              transform-origin: center;
              transform-style: preserve-3d;
              transition: transform 640ms cubic-bezier(0.2, 0.76, 0.18, 1);
              will-change: auto;
            }
            .presentation-slide[data-face="note"] .presentation-flip {
              transform: perspective(720px) rotateY(180deg);
            }
            .presentation-node-front,
            .presentation-note-back {
              position: absolute;
              backface-visibility: hidden;
              -webkit-backface-visibility: hidden;
            }
            .presentation-node-front {
              inset: 0;
              display: flex;
              min-width: 0;
              align-items: center;
              gap: var(--rendered-node-gap, var(--node-gap));
              padding:
                var(--rendered-node-padding-y, var(--node-padding-y))
                var(--rendered-node-padding-x, 16px);
              color: var(--slide-text);
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
              font-size: var(--rendered-slide-font-size, var(--slide-font-size));
              font-style: var(--slide-font-style);
              font-weight: var(--slide-font-weight);
              line-height: var(--rendered-slide-line-height, var(--slide-line-height));
            }
            .presentation-node-shape {
              position: absolute;
              z-index: 0;
              inset: 0;
              display: block;
              width: 100%;
              height: 100%;
              overflow: visible;
              pointer-events: none;
            }
            .presentation-node-title,
            .presentation-media {
              position: relative;
              z-index: 1;
            }
            .presentation-node-selection {
              opacity: 0;
              transition:
                opacity var(--presentation-travel-duration)
                cubic-bezier(0.22, 0.8, 0.2, 1);
            }
            .presentation-slide[data-position="current"] .presentation-node-selection {
              opacity: 1;
            }
            .presentation-node-title {
              display: flex;
              flex: 1 1 auto;
              min-width: 0;
              max-height:
                var(
                  --rendered-title-max-height,
                  calc(var(--slide-line-height) * 3)
                );
              flex-direction: column;
              justify-content: center;
              overflow: hidden;
            }
            .presentation-node-title h1 {
              margin: 0;
              font: inherit;
              font-style: var(--slide-font-style);
              font-weight: var(--slide-font-weight);
              line-height:
                var(--rendered-slide-line-height, var(--slide-line-height));
            }
            .presentation-node-line {
              display: block;
              height: var(--rendered-slide-line-height, var(--slide-line-height));
              min-height: var(--rendered-slide-line-height, var(--slide-line-height));
              overflow: hidden;
              white-space: pre;
            }
            .presentation-media {
              display: flex;
              flex: 0 0 var(--rendered-media-size, var(--presentation-media-size));
              width: var(--rendered-media-size, var(--presentation-media-size));
              height: var(--rendered-media-size, var(--presentation-media-size));
              align-items: center;
              justify-content: center;
              overflow: hidden;
              border-radius: 5px;
              background-position: center;
              background-repeat: no-repeat;
              background-size: contain;
              font-size:
                var(
                  --rendered-media-font-size,
                  calc(var(--presentation-media-size) - 4px)
                );
              font-style: normal;
              font-weight: 400;
              line-height: var(--rendered-media-size, var(--presentation-media-size));
              text-align: center;
            }
            .presentation-note-indicator {
              position: absolute;
              z-index: 5;
              top: 6px;
              right: 7px;
              display: inline-flex;
              width: 26px;
              height: 26px;
              align-items: center;
              justify-content: center;
              padding: 0;
              color: var(--accent);
              opacity: 0.84;
              pointer-events: none;
            }
            .presentation-note-indicator .note-sticker-icon {
              width: 22px;
              height: 22px;
              flex-basis: 22px;
              opacity: 1;
              filter: drop-shadow(0 1px 1px rgba(0, 0, 0, 0.14));
            }
            .presentation-node-note-indicator {
              top: var(--presentation-note-marker-inset, 8px);
              right: var(--presentation-note-marker-inset, 8px);
              width: var(--presentation-note-marker-size, 26px);
              height: var(--presentation-note-marker-size, 26px);
            }
            .presentation-node-note-indicator .note-sticker-icon {
              width:
                calc(var(--presentation-note-marker-size, 26px) - 4px);
              height:
                calc(var(--presentation-note-marker-size, 26px) - 4px);
              flex-basis:
                calc(var(--presentation-note-marker-size, 26px) - 4px);
            }
            .presentation-note-back {
              top: 50%;
              left: 50%;
              display: flex;
              width: 380px;
              height: 360px;
              flex-direction: column;
              overflow: hidden;
              border: 1px solid var(--note-border);
              border-radius: 28px;
              background: var(--note-background);
              color: var(--note-text);
              box-shadow: 0 22px 54px rgba(0, 0, 0, 0.26);
              transform:
                translate(-50%, -50%)
                rotateY(180deg)
                scale(var(--note-counter-scale, 1));
            }
            .presentation-note-header {
              display: flex;
              flex: 0 0 auto;
              align-items: center;
              justify-content: space-between;
              gap: 12px;
              padding: 16px 18px 12px;
              border-bottom: 1px solid var(--note-border);
            }
            .presentation-note-header strong {
              min-width: 0;
              overflow: hidden;
              font-size: 16px;
              text-overflow: ellipsis;
              white-space: nowrap;
            }
            .presentation-note-header .presentation-note-indicator {
              position: static;
              display: inline-flex;
              flex: 0 0 auto;
            }
            .presentation-note {
              flex: 1 1 auto;
              overflow: auto;
              overscroll-behavior: contain;
              padding: 18px;
              font-size: 16px;
              line-height: 1.5;
              touch-action: pan-y;
              user-select: text;
              -webkit-user-select: text;
            }
            .presentation-note .note-media img {
              max-height: 210px;
            }
            .presentation-note-back[aria-hidden="true"] {
              pointer-events: none;
            }
            .presentation-node-front[aria-hidden="true"] {
              pointer-events: none;
            }
            @media (max-width: 640px), (max-aspect-ratio: 4 / 5) {
              .presentation-note-back {
                width: 320px;
                height: 390px;
                border-radius: 24px;
              }
              .presentation-edge-navigation {
                width: 52px;
                height: 52px;
              }
              #presentation-previous-button {
                left: max(8px, env(safe-area-inset-left));
              }
              #presentation-next-button {
                right: max(8px, env(safe-area-inset-right));
              }
              #viewer-controls {
                top: auto;
                bottom: max(12px, env(safe-area-inset-bottom));
              }
              #brainstorm-attribution {
                bottom: calc(max(12px, env(safe-area-inset-bottom)) + 7px);
              }
            }
            @media (max-height: 520px) and (orientation: landscape) {
              .presentation-note-back {
                width: min(520px, calc(100vw - 180px));
                height:
                  min(
                    300px,
                    calc(
                      100vh
                      - 128px
                      - env(safe-area-inset-top)
                      - env(safe-area-inset-bottom)
                    )
                  );
                height:
                  min(
                    300px,
                    calc(
                      100dvh
                      - 128px
                      - env(safe-area-inset-top)
                      - env(safe-area-inset-bottom)
                    )
                  );
                border-radius: 20px;
              }
              .presentation-note-header {
                padding: 11px 14px 9px;
              }
              .presentation-note {
                padding: 14px;
                font-size: 15px;
              }
              .presentation-edge-navigation {
                width: 44px;
                height: 44px;
              }
              #viewer-controls {
                top: auto;
                bottom: max(8px, env(safe-area-inset-bottom));
              }
              #brainstorm-attribution {
                bottom:
                  calc(max(8px, env(safe-area-inset-bottom)) + 7px);
              }
            }
            @media (max-width: 420px) {
              .presentation-note-back {
                width: min(320px, calc(100vw - 32px));
                height:
                  min(
                    390px,
                    calc(
                      100vh
                      - 176px
                      - env(safe-area-inset-top)
                    )
                  );
              }
              .presentation-edge-navigation {
                top: max(12px, env(safe-area-inset-top));
                transform: none;
              }
              .presentation-edge-navigation:active {
                transform: scale(0.94);
              }
              #viewer-controls {
                left: max(8px, env(safe-area-inset-left));
                max-width: calc(100vw - 60px);
                transform: none;
              }
              #viewer-controls button {
                padding-right: 8px;
                padding-left: 8px;
              }
              #presentation-progress {
                min-width: 3.6em;
                padding-right: 3px;
                padding-left: 3px;
              }
              #brainstorm-attribution {
                right: max(8px, env(safe-area-inset-right));
              }
            }
            @media (prefers-reduced-motion: reduce) {
              .presentation-slide,
              .presentation-node-front,
              .presentation-note-back,
              .map-node-front,
              .map-node-note-back {
                transition: opacity 120ms linear;
              }
              .presentation-flip,
              .map-node-flip {
                transform: none !important;
                transition: none;
              }
              .presentation-note-back,
              .map-node-note-back {
                opacity: 0;
                transform:
                  translate(-50%, -50%)
                  scale(var(--note-counter-scale, 1));
              }
              .map-node-note-back {
                transform:
                  translate(-50%, -50%)
                  scale(var(--map-note-counter-scale, 1));
              }
              .presentation-slide[data-face="note"]
                .presentation-node-front,
              .node[data-face="note"] .map-node-front {
                opacity: 0;
              }
              .presentation-slide[data-face="note"]
                .presentation-note-back,
              .node[data-face="note"] .map-node-note-back {
                opacity: 1;
              }
              #presentation-world-branches path { transition: none; }
              #stage { will-change: auto; }
            }
            .visually-hidden {
              position: absolute !important;
              width: 1px !important;
              height: 1px !important;
              padding: 0 !important;
              margin: -1px !important;
              overflow: hidden !important;
              clip: rect(0, 0, 0, 0) !important;
              white-space: nowrap !important;
              border: 0 !important;
            }
          </style>
        </head>
        <body
          style="--note-background: \(palette.controlBackground.css); --note-text: \(palette.primary.css); --note-secondary: \(palette.secondary.css); --note-border: \(palette.primary.withOpacity(palette.isDark ? 0.22 : 0.14).css); --accent: \(palette.accent.css); --accent-contrast: \(contrastText(for: palette.accent).css); --toolbar-background: \(palette.controlBackground.withOpacity(0.94).css); --toolbar-border: \(palette.primary.withOpacity(0.14).css); --control-active: \(palette.selection.css); --control-active-text: \(contrastText(for: palette.selection).css); --presentation-glow: \(palette.selection.withOpacity(0.18).css); --canvas: \(palette.canvas.css); --grid: \(palette.grid.css);"
        >
          <nav id="viewer-controls" aria-label="Viewer controls">
            <button
              id="map-mode-button"
              type="button"
              aria-pressed="\(options.htmlInitialMode == .map)"
            >Map</button>
            <button
              id="presentation-mode-button"
              type="button"
              aria-pressed="\(options.htmlInitialMode == .presentation)"
            >Present</button>
            <span
              id="presentation-progress"
              aria-live="polite"
              \(options.htmlInitialMode == .presentation ? "" : "hidden")
            ></span>
          </nav>
          <a
            id="brainstorm-attribution"
            href="https://selfhosted.ninja/projects/brainstorm/"
            target="_blank"
            rel="noopener noreferrer"
            aria-label="Made with Brainstorm"
            title="Made with Brainstorm"
          >
            <svg
              class="brainstorm-attribution-logo"
              viewBox="0 0 1024 1024"
              aria-hidden="true"
              focusable="false"
            >
              <defs>
                <clipPath id="brainstorm-attribution-rounded-icon">
                  <rect width="1024" height="1024" rx="230"/>
                </clipPath>
              </defs>
              <g clip-path="url(#brainstorm-attribution-rounded-icon)">
                <rect class="brainstorm-attribution-logo-tile" x="0" y="0" width="256" height="256" opacity="0.76"/>
                <rect class="brainstorm-attribution-logo-tile" x="256" y="0" width="256" height="256" opacity="0.72"/>
                <rect class="brainstorm-attribution-logo-tile" x="512" y="0" width="256" height="256" opacity="0.88"/>
                <rect class="brainstorm-attribution-logo-tile" x="768" y="0" width="256" height="256" opacity="0.81"/>
                <rect class="brainstorm-attribution-logo-tile" x="0" y="256" width="256" height="256" opacity="0.84"/>
                <rect class="brainstorm-attribution-logo-tile" x="256" y="256" width="256" height="256"/>
                <rect class="brainstorm-attribution-logo-tile" x="512" y="256" width="256" height="256" opacity="0.68"/>
                <rect class="brainstorm-attribution-logo-tile" x="768" y="256" width="256" height="256" opacity="0.78"/>
                <rect class="brainstorm-attribution-logo-tile" x="0" y="512" width="256" height="256" opacity="0.85"/>
                <rect class="brainstorm-attribution-logo-tile" x="256" y="512" width="256" height="256" opacity="0.74"/>
                <rect class="brainstorm-attribution-logo-tile" x="512" y="512" width="256" height="256" opacity="0.9"/>
                <rect class="brainstorm-attribution-logo-tile" x="768" y="512" width="256" height="256" opacity="0.87"/>
                <rect class="brainstorm-attribution-logo-tile" x="0" y="768" width="256" height="256" opacity="0.9"/>
                <rect class="brainstorm-attribution-logo-tile" x="256" y="768" width="256" height="256" opacity="0.8"/>
                <rect class="brainstorm-attribution-logo-tile" x="512" y="768" width="256" height="256"/>
                <rect class="brainstorm-attribution-logo-tile" x="768" y="768" width="256" height="256" opacity="0.94"/>
              </g>
              <g
                class="brainstorm-attribution-logo-branch"
                stroke-width="30"
                stroke-linecap="round"
              >
                <path d="M410 512 C500 512 500 230 620 230"/>
                <path d="M410 512 L620 512"/>
                <path d="M410 512 C500 512 500 794 620 794"/>
              </g>
              <g class="brainstorm-attribution-logo-node">
                <rect x="110" y="412" width="300" height="200" rx="100"/>
                <rect x="620" y="160" width="290" height="140" rx="70"/>
                <rect x="620" y="442" width="290" height="140" rx="70"/>
                <rect x="620" y="724" width="290" height="140" rx="70"/>
              </g>
            </svg>
            <span class="visually-hidden">Made with Brainstorm</span>
          </a>
          <main
            id="viewport"
            data-map-width="\(width)"
            data-map-height="\(height)"
            data-grid-step="32"
            data-theme="\(escapeHTML(theme.id))"
            data-touch-navigation="pan pinch double-tap-fit"
            style="--canvas: \(palette.canvas.css); --grid: \(palette.grid.css);"
            aria-label="\(escapeHTML(mapDescription))"
            aria-describedby="viewer-instructions"
            \(options.htmlInitialMode == .presentation ? "hidden" : "")
          >
            <p id="viewer-instructions" class="visually-hidden">
              Read-only Brainstorm mind map. Select a node with a note icon to flip between its title and bounded note back face. Drag with a mouse or one finger to pan. Use the mouse wheel or pinch with two fingers to zoom. Double-click, double-tap, or press F to fit; press 0 for 100 percent.
            </p>
            <div
              id="stage"
              data-map-width="\(width)"
              data-map-height="\(height)"
              role="group"
              aria-label="Mind map content"
            >
              <svg
                id="branches"
                class="edges"
                viewBox="0 0 \(width) \(height)"
                width="\(width)"
                height="\(height)"
                aria-hidden="true"
              >
        \(indent(branches, spaces: 8))
              </svg>
              <svg
                id="node-shapes"
                viewBox="0 0 \(width) \(height)"
                width="\(width)"
                height="\(height)"
                aria-hidden="true"
              >
        \(indent(shapes, spaces: 8))
              </svg>
              <section id="nodes" role="list" aria-label="Mind map ideas">
        \(indent(nodes, spaces: 8))
              </section>
            </div>
          </main>
          <main
            id="presentation"
            aria-label="Brainstorm presentation"
            \(options.htmlInitialMode == .map ? "hidden" : "")
          >
            <p class="visually-hidden" id="presentation-instructions">
              Use the Previous and Next edge buttons, Left and Right, Up and Down, Space, Page Up, Page Down, Home, or End to move through every node and note step. Select any visible node to continue from it. Press N to move between the current node and its note. Press Escape to return to the map.
            </p>
            <section
              id="presentation-stage"
              aria-describedby="presentation-instructions"
            >
              <div
                id="presentation-world"
                data-map-width="\(presentationWidth)"
                data-map-height="\(presentationHeight)"
              >
                <svg
                  id="presentation-world-branches"
                  viewBox="0 0 \(presentationWidth) \(presentationHeight)"
                  width="\(presentationWidth)"
                  height="\(presentationHeight)"
                  aria-hidden="true"
                  focusable="false"
                >
        \(indent(presentationBranches, spaces: 10))
                </svg>
        \(indent(presentationSlides, spaces: 8))
              </div>
            </section>
            <button
              class="presentation-edge-navigation"
              id="presentation-previous-button"
              type="button"
              aria-label="Previous presentation step"
              aria-controls="presentation-stage"
              hidden
            >
              <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
                <path d="M15 6l-6 6l6 6"/>
              </svg>
            </button>
            <button
              class="presentation-edge-navigation"
              id="presentation-next-button"
              type="button"
              aria-label="Next presentation step"
              aria-controls="presentation-stage"
              hidden
            >
              <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
                <path d="M9 6l6 6l-6 6"/>
              </svg>
            </button>
          </main>
          <script>
            (() => {
              "use strict";

              const viewport = document.getElementById("viewport");
              const stage = document.getElementById("stage");
              const presentation = document.getElementById("presentation");
              const mapModeButton = document.getElementById("map-mode-button");
              const presentationModeButton =
                document.getElementById("presentation-mode-button");
              const progress = document.getElementById("presentation-progress");
              const previousPresentationButton =
                document.getElementById("presentation-previous-button");
              const nextPresentationButton =
                document.getElementById("presentation-next-button");
              const slides = Array.from(
                document.querySelectorAll(".presentation-slide")
              );
              const mapNoteNodes = Array.from(
                document.querySelectorAll('.node[data-has-note="true"]')
              );
              const presentationStage =
                document.getElementById("presentation-stage");
              const presentationWorld =
                document.getElementById("presentation-world");
              const mapWidth = Number(viewport.dataset.mapWidth);
              const mapHeight = Number(viewport.dataset.mapHeight);
              let currentMode = "\(options.htmlInitialMode.rawValue)";
              let currentSlideIndex = 0;
              const currentSlide = () => slides[currentSlideIndex] ?? null;
              const stepCountForSlide = slide =>
                slide?.dataset.hasNote === "true" ? 2 : 1;
              const slideIndexByElement = new WeakMap();
              const slideByNodeID = new Map();
              const childrenByParentID = new Map();
              const slideByParentAndSiblingIndex = new Map();
              const presentationStepOffsets = [];
              let presentationStepCount = 0;
              const parentSiblingKey = (parentID, siblingIndex) =>
                `${parentID}\\u0000${siblingIndex}`;
              slides.forEach((slide, index) => {
                slideIndexByElement.set(slide, index);
                presentationStepOffsets[index] = presentationStepCount;
                presentationStepCount += stepCountForSlide(slide);
                const nodeID = slide.dataset.nodeId;
                if (nodeID) slideByNodeID.set(nodeID, slide);
                const parentID = slide.dataset.parentId || "";
                const siblingIndex = Number(slide.dataset.siblingIndex);
                if (!childrenByParentID.has(parentID)) {
                  childrenByParentID.set(parentID, []);
                }
                childrenByParentID.get(parentID).push(slide);
                if (Number.isFinite(siblingIndex)) {
                  slideByParentAndSiblingIndex.set(
                    parentSiblingKey(parentID, siblingIndex),
                    slide
                  );
                }
              });
              childrenByParentID.forEach(children => {
                children.sort(
                  (first, second) =>
                    Number(first.dataset.siblingIndex)
                    - Number(second.dataset.siblingIndex)
                );
              });
              const presentationStepIndex = () =>
                (presentationStepOffsets[currentSlideIndex] ?? 0)
                  + (currentSlide()?.dataset.face === "note" ? 1 : 0);
              const syncPresentationEdgeNavigation = () => {
                const stepIndex = presentationStepIndex();
                previousPresentationButton.hidden =
                  presentationStepCount === 0 || stepIndex <= 0;
                nextPresentationButton.hidden =
                  presentationStepCount === 0
                  || stepIndex >= presentationStepCount - 1;
              };
              const minimumScale = 0.02;
              const maximumScale = 8;
              let scale = 1;
              let offsetX = 0;
              let offsetY = 0;
              let fitted = true;
              const activePointers = new Map();
              const tapMoveThreshold = 10;
              const doubleTapDistance = 32;
              const doubleTapDelay = 350;
              let tapCandidate = null;
              let mapNodePointer = null;
              let lastTap = null;
              let viewportBounds = viewport.getBoundingClientRect();
              let viewportWidth = viewportBounds.width;
              let viewportHeight = viewportBounds.height;
              const reducedMotion = matchMedia(
                "(prefers-reduced-motion: reduce)"
              );
              let activeCameraAnimation = null;
              let presentationCameraPoint = null;
              let presentationCameraScale = 1;
              let presentationRenderViewportKey = "";
              let presentationSwipe = null;
              let suppressPresentationSlideClickUntil = 0;

              const slideMapPoint = slide => {
                const x = Number(slide?.dataset.mapX);
                const y = Number(slide?.dataset.mapY);
                return Number.isFinite(x) && Number.isFinite(y)
                  ? { x, y }
                  : null;
              };

              const slideMapFrame = slide => {
                const center = slideMapPoint(slide);
                const width = Number(slide?.dataset.mapWidth);
                const height = Number(slide?.dataset.mapHeight);
                if (
                  !center
                  || !Number.isFinite(width)
                  || !Number.isFinite(height)
                ) {
                  return null;
                }
                return {
                  minX: center.x - width / 2,
                  maxX: center.x + width / 2,
                  minY: center.y - height / 2,
                  maxY: center.y + height / 2,
                };
              };

              const parseSpatialRoute = value => {
                if (!value) return [];
                return value
                  .split(";")
                  .map(pair => {
                    const [x, y] = pair.split(",").map(Number);
                    return Number.isFinite(x) && Number.isFinite(y)
                      ? { x, y }
                      : null;
                  })
                  .filter(Boolean);
              };

              const smoothBranchRoute = (points, pivotIndex) => {
                if (
                  !Array.isArray(points)
                  || points.length < 3
                  || !Number.isInteger(pivotIndex)
                  || pivotIndex <= 0
                  || pivotIndex >= points.length - 1
                ) {
                  return points;
                }
                const source = points[0];
                const pivot = points[pivotIndex];
                const destination = points.at(-1);
                // Preserve the map-aware return toward the common ancestor,
                // but use one continuous quadratic path instead of visibly
                // landing on each intermediate parent and reversing.
                return [0, 0.2, 0.4, 0.6, 0.8, 1].map(progress => {
                  const inverse = 1 - progress;
                  return {
                    x:
                      inverse * inverse * source.x
                      + 2 * inverse * progress * pivot.x
                      + progress * progress * destination.x,
                    y:
                      inverse * inverse * source.y
                      + 2 * inverse * progress * pivot.y
                      + progress * progress * destination.y,
                  };
                });
              };

              const presentationSafeRect = () => {
                const width = Math.max(0, window.innerWidth);
                const height = Math.max(0, window.innerHeight);
                const peek = Math.min(
                  28,
                  Math.max(16, Math.min(width, height) * 0.03)
                );
                const controlsAtBottom = matchMedia(
                  "(max-width: 640px), (max-aspect-ratio: 4 / 5), "
                  + "(max-height: 520px) and (orientation: landscape)"
                ).matches;
                const top = controlsAtBottom ? peek : Math.max(peek, 64);
                const bottom = controlsAtBottom ? Math.max(peek, 64) : peek;
                return {
                  minX: peek,
                  maxX: Math.max(peek, width - peek),
                  minY: top,
                  maxY: Math.max(top, height - bottom),
                };
              };

              const presentationPeekCap = (current, candidate) => {
                const center = slideMapPoint(current);
                const frame = slideMapFrame(candidate);
                if (!center || !frame) return 0;
                const safe = presentationSafeRect();
                const screenCenter = {
                  x: window.innerWidth / 2,
                  y: window.innerHeight / 2,
                };
                let capX = Number.POSITIVE_INFINITY;
                if (frame.minX > center.x) {
                  capX =
                    (safe.maxX - screenCenter.x)
                    / (frame.minX - center.x);
                } else if (frame.maxX < center.x) {
                  capX =
                    (screenCenter.x - safe.minX)
                    / (center.x - frame.maxX);
                }
                let capY = Number.POSITIVE_INFINITY;
                if (frame.minY > center.y) {
                  capY =
                    (safe.maxY - screenCenter.y)
                    / (frame.minY - center.y);
                } else if (frame.maxY < center.y) {
                  capY =
                    (screenCenter.y - safe.minY)
                    / (center.y - frame.maxY);
                }
                return Math.max(0, Math.min(capX, capY));
              };

              const presentationNeighborCandidates = slide => {
                if (!slide) return [];
                const slideIndex = slideIndexByElement.get(slide) ?? -1;
                const parentID = slide.dataset.parentId || "";
                const siblingIndex = Number(slide.dataset.siblingIndex);
                const result = [];
                const seen = new Set([slide.dataset.nodeId]);
                const append = candidate => {
                  const id = candidate?.dataset.nodeId;
                  if (!candidate || !id || seen.has(id)) return;
                  seen.add(id);
                  result.push(candidate);
                };

                // Deterministic tie order: next DFS, previous DFS, parent,
                // previous sibling, next sibling, then children in stored order.
                append(slides[slideIndex + 1]);
                append(slides[slideIndex - 1]);
                append(parentID ? slideByNodeID.get(parentID) : null);
                if (parentID && Number.isFinite(siblingIndex)) {
                  append(
                    slideByParentAndSiblingIndex.get(
                      parentSiblingKey(parentID, siblingIndex - 1)
                    )
                  );
                  append(
                    slideByParentAndSiblingIndex.get(
                      parentSiblingKey(parentID, siblingIndex + 1)
                    )
                  );
                }
                (
                  childrenByParentID.get(slide.dataset.nodeId) ?? []
                ).forEach(append);
                return result;
              };

              const presentationScaleFor = slide => {
                if (!slide) return 1;
                const width = Math.max(1, Number(slide.dataset.mapWidth) || 1);
                const height = Math.max(1, Number(slide.dataset.mapHeight) || 1);
                const safe = presentationSafeRect();
                const availableWidth = Math.max(1, safe.maxX - safe.minX);
                const availableHeight = Math.max(1, safe.maxY - safe.minY);
                const base = Math.min(
                  4.8,
                  Math.max(
                    Number.EPSILON,
                    Math.min(
                      availableWidth * 0.72 / width,
                      availableHeight * 0.62 / height
                    )
                  )
                );
                const minimumFocusedScaleRatio =
                  \(number(PresentationNeighborZoomPolicy.minimumFocusedScaleRatio));
                const floor = Math.min(
                  base,
                  Math.max(1, base * minimumFocusedScaleRatio)
                );
                const slideIndex = slideIndexByElement.get(slide) ?? -1;
                const sequential = [
                  {
                    candidate: slides[slideIndex + 1],
                    kind: slide.dataset.nextRelationKind,
                  },
                  {
                    candidate: slides[slideIndex - 1],
                    kind: slide.dataset.previousRelationKind,
                  },
                ]
                  // A branch jump deliberately pulls the camera back while
                  // traveling through its common ancestor. Do not preserve
                  // that overview at rest merely to keep the far-away DFS
                  // predecessor/successor visible; the destination must
                  // settle back to a readable focused-node scale.
                  .filter(
                    item => item.candidate && item.kind !== "branch"
                  )
                  .map(item => item.candidate);
                const sequentialCaps = sequential.map(candidate =>
                  presentationPeekCap(slide, candidate)
                );
                if (
                  sequentialCaps.length > 0
                  && sequentialCaps.length === sequential.length
                  && sequentialCaps.every(cap => cap >= floor)
                ) {
                  // Cap the focus zoom so the real previous and next DFS
                  // surfaces remain partially visible at their true map
                  // bearings, but never sacrifice the focused node's readable
                  // resting size. Camera travel can still zoom farther out
                  // for long branch returns.
                  return Math.min(base, Math.min(...sequentialCaps));
                }

                const candidates = presentationNeighborCandidates(slide);
                if (candidates.length === 0) return base;
                let bestCap = null;
                candidates.forEach(candidate => {
                  const cap = presentationPeekCap(slide, candidate);
                  if (
                    cap >= floor
                    && (bestCap === null || cap > bestCap)
                  ) {
                    bestCap = cap;
                  }
                });
                return Math.min(base, bestCap ?? floor);
              };

              const syncPresentationRenderScale = () => {
                const viewportKey =
                  `${window.innerWidth}x${window.innerHeight}`;
                if (viewportKey === presentationRenderViewportKey) return;
                presentationRenderViewportKey = viewportKey;
                slides.forEach(slide => {
                  // Give every slide a stable intrinsic render resolution
                  // based on the scale it uses when focused. The camera can
                  // then animate the one shared world without resizing node
                  // bodies and text on a separate timeline.
                  const renderScale = presentationScaleFor(slide);
                  const width = Math.max(
                    1,
                    Number(slide.dataset.mapWidth) || 1
                  );
                  const height = Math.max(
                    1,
                    Number(slide.dataset.mapHeight) || 1
                  );
                  const centerX = Number(slide.dataset.mapX) || 0;
                  const centerY = Number(slide.dataset.mapY) || 0;
                  const baseFontSize =
                    Number(slide.dataset.baseFontSize) || 14;
                  const baseLineHeight =
                    Number(slide.dataset.baseLineHeight) || 20;
                  const basePaddingY =
                    Number(slide.dataset.basePaddingY) || 10;
                  const baseGap =
                    Number(slide.dataset.baseGap) || 0;
                  const baseMediaSize =
                    Number(slide.dataset.baseMediaSize) || 20;
                  const focusedNodeHeight = height * renderScale;
                  const noteMarkerSize = Math.min(
                    32,
                    Math.max(16, focusedNodeHeight * 0.16)
                  );
                  const noteMarkerInset = Math.min(
                    12,
                    Math.max(6, noteMarkerSize * 0.32)
                  );

                  slide.style.left = `${centerX}px`;
                  slide.style.top = `${centerY}px`;
                  slide.style.width = `${width * renderScale}px`;
                  slide.style.height = `${height * renderScale}px`;
                  slide.style.transform =
                    `scale(${1 / renderScale}) translate(-50%, -50%)`;
                  slide.style.setProperty(
                    "--presentation-render-scale",
                    String(renderScale)
                  );
                  slide.style.setProperty(
                    "--rendered-slide-font-size",
                    `${baseFontSize * renderScale}px`
                  );
                  slide.style.setProperty(
                    "--rendered-slide-line-height",
                    `${baseLineHeight * renderScale}px`
                  );
                  slide.style.setProperty(
                    "--rendered-title-max-height",
                    `${baseLineHeight * renderScale * 3}px`
                  );
                  slide.style.setProperty(
                    "--rendered-node-padding-y",
                    `${basePaddingY * renderScale}px`
                  );
                  slide.style.setProperty(
                    "--rendered-node-padding-x",
                    `${16 * renderScale}px`
                  );
                  slide.style.setProperty(
                    "--rendered-node-gap",
                    `${baseGap * renderScale}px`
                  );
                  slide.style.setProperty(
                    "--rendered-media-size",
                    `${baseMediaSize * renderScale}px`
                  );
                  slide.style.setProperty(
                    "--rendered-media-font-size",
                    `${Math.max(1, baseMediaSize - 4) * renderScale}px`
                  );
                  slide.style.setProperty(
                    "--presentation-note-marker-size",
                    `${noteMarkerSize}px`
                  );
                  slide.style.setProperty(
                    "--presentation-note-marker-inset",
                    `${noteMarkerInset}px`
                  );
                });
              };

              const syncPresentationNoteScale = (slide, worldScale) => {
                if (!slide || !Number.isFinite(worldScale) || worldScale <= 0) {
                  return;
                }
                // Every slide is rendered at destination resolution and
                // counter-scaled as a whole, so the back cover is already
                // screen-sized and needs no second rasterizing scale.
                slide.style.setProperty(
                  "--note-counter-scale",
                  "1"
                );
              };

              const presentationWorldTransform = (
                point,
                worldScale,
                alignToDevicePixels = true
              ) => {
                const pixelRatio = Math.max(
                  1,
                  Number(window.devicePixelRatio) || 1
                );
                const align = value =>
                  Math.round(value * pixelRatio) / pixelRatio;
                const rawX = -point.x * worldScale;
                const rawY = -point.y * worldScale;
                const x = alignToDevicePixels ? align(rawX) : rawX;
                const y = alignToDevicePixels ? align(rawY) : rawY;
                return `translate(${x}px, ${y}px) scale(${worldScale})`;
              };

              const presentationBackgroundPosition = (point, worldScale) => [
                "center",
                `calc(50% - ${point.x * worldScale}px) `
                  + `calc(50% - ${point.y * worldScale}px)`,
                `calc(50% - ${point.x * worldScale}px) `
                  + `calc(50% - ${point.y * worldScale}px)`,
              ].join(", ");

              const setCameraFrame = (
                point,
                worldScale,
                alignToDevicePixels = true
              ) => {
                if (!point || !Number.isFinite(worldScale)) return;
                presentationWorld.style.transform =
                  presentationWorldTransform(
                    point,
                    worldScale,
                    alignToDevicePixels
                  );
                presentation.style.backgroundPosition =
                  presentationBackgroundPosition(point, worldScale);
                presentationCameraPoint = { x: point.x, y: point.y };
                presentationCameraScale = worldScale;
              };

              const settleCameraFrame = (point, worldScale) => {
                if (!point || !Number.isFinite(worldScale)) return;
                presentationWorld.style.willChange = "auto";
                // Tear down the interpolated camera layer before installing
                // the device-pixel-aligned endpoint. The forced layout is not
                // painted, but it prevents Safari from reusing a blurry
                // in-flight glyph raster at rest.
                presentationWorld.style.transform = "none";
                void presentationWorld.offsetWidth;
                setCameraFrame(point, worldScale);
              };

              const presentationRouteDistance = points => {
                if (!Array.isArray(points) || points.length < 2) return 0;
                return points.slice(1).reduce((total, point, index) => {
                  const previous = points[index];
                  return total + Math.hypot(
                    point.x - previous.x,
                    point.y - previous.y
                  );
                }, 0);
              };

              const presentationTravelDuration = points => {
                if (reducedMotion.matches) return 180;
                const routeLength = Array.isArray(points) ? points.length : 0;
                const viewportSpan = Math.max(
                  1,
                  Math.min(window.innerWidth, window.innerHeight)
                );
                const distanceDuration = Math.min(
                  520,
                  presentationRouteDistance(points) / viewportSpan * 260
                );
                return Math.min(
                  1_200,
                  440
                    + Math.max(0, routeLength - 2) * 130
                    + distanceDuration
                );
              };

              const presentationOverviewScale = (
                points,
                sourceScale,
                destinationScale
              ) => {
                if (points.length < 2) {
                  return Math.min(sourceScale, destinationScale);
                }
                const safe = presentationSafeRect();
                const xs = points.map(point => point.x);
                const ys = points.map(point => point.y);
                const spanX = Math.max(...xs) - Math.min(...xs);
                const spanY = Math.max(...ys) - Math.min(...ys);
                const availableWidth =
                  Math.max(1, safe.maxX - safe.minX) * 0.72;
                const availableHeight =
                  Math.max(1, safe.maxY - safe.minY) * 0.72;
                return Math.max(
                  Number.EPSILON,
                  Math.min(
                    sourceScale,
                    destinationScale,
                    spanX > 1
                      ? availableWidth / spanX
                      : Number.POSITIVE_INFINITY,
                    spanY > 1
                      ? availableHeight / spanY
                      : Number.POSITIVE_INFINITY
                  )
                );
              };

              const presentationCameraFrames = (
                points,
                sourceScale,
                destinationScale
              ) => {
                if (points.length < 2 || reducedMotion.matches) {
                  return [
                    {
                      point: points[0],
                      scale: sourceScale,
                      offset: 0,
                    },
                    {
                      point: points.at(-1),
                      scale: destinationScale,
                      offset: 1,
                    },
                  ];
                }
                const overviewScale = presentationOverviewScale(
                  points,
                  sourceScale,
                  destinationScale
                );
                const anchors = points.length === 2
                  ? [
                      points[0],
                      {
                        x: (points[0].x + points[1].x) / 2,
                        y: (points[0].y + points[1].y) / 2,
                      },
                      points[1],
                    ]
                  : points;
                const segmentLengths = anchors.slice(1).map(
                  (point, index) => Math.hypot(
                    point.x - anchors[index].x,
                    point.y - anchors[index].y
                  )
                );
                const totalDistance = Math.max(
                  1,
                  segmentLengths.reduce((total, length) => total + length, 0)
                );
                let traveled = 0;
                return anchors.map((point, index) => {
                  if (index > 0) traveled += segmentLengths[index - 1];
                  return {
                    point,
                    scale: index === 0
                      ? sourceScale
                      : index === anchors.length - 1
                        ? destinationScale
                        : overviewScale,
                    offset: index === anchors.length - 1
                      ? 1
                      : traveled / totalDistance,
                  };
                });
              };

              const cameraFrameAt = (frames, progress) => {
                const nextIndex = frames.findIndex(
                  frame => frame.offset >= progress
                );
                if (nextIndex <= 0) return frames[0];
                const next = frames[nextIndex];
                const previous = frames[nextIndex - 1];
                const span = Math.max(0.0001, next.offset - previous.offset);
                const localProgress =
                  (progress - previous.offset) / span;
                return {
                  point: {
                    x: previous.point.x
                      + (next.point.x - previous.point.x) * localProgress,
                    y: previous.point.y
                      + (next.point.y - previous.point.y) * localProgress,
                  },
                  scale: previous.scale
                    + (next.scale - previous.scale) * localProgress,
                };
              };

              const cameraEase = progress =>
                progress < 0.5
                  ? 4 * progress * progress * progress
                  : 1 - Math.pow(-2 * progress + 2, 3) / 2;

              const cancelCameraAnimation = () => {
                const animation = activeCameraAnimation;
                if (!animation) return;
                activeCameraAnimation = null;
                cancelAnimationFrame(animation.frameID);
                presentationWorld.style.willChange = "auto";
              };

              const travelCamera = route => {
                const destination = slideMapPoint(currentSlide());
                if (!destination) return;
                const destinationScale =
                  presentationScaleFor(currentSlide());
                syncPresentationRenderScale();
                syncPresentationNoteScale(
                  currentSlide(),
                  destinationScale
                );
                const source =
                  presentationCameraPoint ?? route[0] ?? destination;
                const sourceScale = presentationCameraScale;
                cancelCameraAnimation();
                presentationWorld.style.willChange = "auto";
                const points = route.length > 0 ? [...route] : [source, destination];
                if (
                  points[0]?.x !== source.x
                  || points[0]?.y !== source.y
                ) {
                  points.unshift(source);
                }
                if (
                  points.at(-1)?.x !== destination.x
                  || points.at(-1)?.y !== destination.y
                ) {
                  points.push(destination);
                }
                if (
                  points.length < 2
                  || (
                    Math.abs(source.x - destination.x) < 0.001
                    && Math.abs(source.y - destination.y) < 0.001
                    && Math.abs(sourceScale - destinationScale) < 0.001
                  )
                ) {
                  settleCameraFrame(destination, destinationScale);
                  return;
                }
                presentationWorld.style.willChange = "transform";
                const frames = presentationCameraFrames(
                  points,
                  sourceScale,
                  destinationScale
                );
                const duration = presentationTravelDuration(points);
                const animation = {
                  frameID: 0,
                  startedAt: performance.now(),
                };
                activeCameraAnimation = animation;
                setCameraFrame(source, sourceScale, false);
                const stepCameraAnimation = timestamp => {
                  if (activeCameraAnimation !== animation) return;
                  const rawProgress = Math.min(
                    1,
                    Math.max(0, (timestamp - animation.startedAt) / duration)
                  );
                  const frame = cameraFrameAt(
                    frames,
                    cameraEase(rawProgress)
                  );
                  setCameraFrame(frame.point, frame.scale, false);
                  if (rawProgress < 1) {
                    animation.frameID =
                      requestAnimationFrame(stepCameraAnimation);
                    return;
                  }
                  activeCameraAnimation = null;
                  settleCameraFrame(destination, destinationScale);
                };
                animation.frameID =
                  requestAnimationFrame(stepCameraAnimation);
              };

              const updatePresentationSpatialPositions = () => {
                const destination = slideMapPoint(currentSlide());
                if (!destination) return;
                cancelCameraAnimation();
                syncPresentationRenderScale();
                const worldScale = presentationScaleFor(currentSlide());
                syncPresentationNoteScale(currentSlide(), worldScale);
                settleCameraFrame(
                  destination,
                  worldScale
                );
              };

              const updatePresentationConnections = () => {
                // Connections live in the transformed map world, so they move
                // with the same camera as their nodes and never need synthetic
                // screen-space arrows or straight-line substitutes.
              };

              const originalSlideTabIndexes = new WeakMap();
              const originalMapTabIndexes = new WeakMap();
              const updateMapNodeDescendantFocus = node => {
                if (!node) return;
                const activeFace = node.dataset.face || "node";
                node.querySelectorAll(
                  "button, a[href], iframe, input, textarea, select, [tabindex]"
                ).forEach(element => {
                  if (!originalMapTabIndexes.has(element)) {
                    originalMapTabIndexes.set(
                      element,
                      element.getAttribute("tabindex")
                    );
                  }
                  const belongsToFront =
                    element.closest(".map-node-front") !== null;
                  const belongsToNote =
                    element.closest(".map-node-note-back") !== null;
                  const belongsToActiveFace =
                    (activeFace === "node" && belongsToFront)
                    || (activeFace === "note" && belongsToNote);
                  if (belongsToActiveFace) {
                    const original = originalMapTabIndexes.get(element);
                    if (original === null) {
                      element.removeAttribute("tabindex");
                    } else {
                      element.setAttribute("tabindex", original);
                    }
                  } else {
                    element.tabIndex = -1;
                  }
                });
              };

              const updateSlideDescendantFocus = (slide, isCurrent) => {
                const activeFace = slide.dataset.face || "node";
                slide.querySelectorAll(
                  "button, a[href], iframe, input, textarea, select, [tabindex]"
                ).forEach(element => {
                  if (!originalSlideTabIndexes.has(element)) {
                    originalSlideTabIndexes.set(
                      element,
                      element.getAttribute("tabindex")
                    );
                  }
                  const belongsToNode =
                    element.closest(".presentation-node-front") !== null;
                  const belongsToNote =
                    element.closest(".presentation-note-back") !== null;
                  const belongsToActiveFace =
                    (activeFace === "node" && belongsToNode)
                    || (activeFace === "note" && belongsToNote);
                  if (isCurrent && belongsToActiveFace) {
                    const original = originalSlideTabIndexes.get(element);
                    if (original === null) {
                      element.removeAttribute("tabindex");
                    } else {
                      element.setAttribute("tabindex", original);
                    }
                  } else {
                    element.tabIndex = -1;
                  }
                });
              };

              const supportsEmbeddedYouTube =
                location.protocol === "http:"
                || location.protocol === "https:";

              const resetYouTube = host => {
                const iframe = host.querySelector("iframe.youtube-frame");
                if (iframe) {
                  iframe.src = "about:blank";
                  iframe.remove();
                }
                const button = host.querySelector("[data-youtube-play]");
                host.hidden = !supportsEmbeddedYouTube;
                if (button) button.hidden = !supportsEmbeddedYouTube;
              };

              const loadYouTube = (host, autoplay = false) => {
                if (
                  !supportsEmbeddedYouTube
                  || !host
                  || host.querySelector("iframe.youtube-frame")
                ) return;
                host.hidden = false;
                const videoID = host.dataset.videoId;
                const start = Number(host.dataset.start || 0);
                if (!/^[A-Za-z0-9_-]{11}$/.test(videoID)) return;
                const iframe = document.createElement("iframe");
                iframe.className = "youtube-frame";
                iframe.title = "YouTube video player";
                iframe.allow =
                  "autoplay; encrypted-media; picture-in-picture";
                iframe.allowFullscreen = true;
                iframe.referrerPolicy = "strict-origin-when-cross-origin";
                iframe.src =
                  `https://www.youtube-nocookie.com/embed/${videoID}`
                  + `?playsinline=1&autoplay=${autoplay ? 1 : 0}`
                  + `${start > 0 ? `&start=${start}` : ""}`;
                const button = host.querySelector("[data-youtube-play]");
                if (button) button.hidden = true;
                host.append(iframe);
              };

              const syncPresentationYouTubePlayers = () => {
                const current = currentSlide();
                document
                  .querySelectorAll(
                    ".presentation-slide [data-youtube-host]"
                  )
                  .forEach(host => {
                    const note = host.closest(".presentation-note");
                    const belongsToCurrent = current?.contains(host) === true;
                    if (
                      belongsToCurrent
                      && current?.dataset.face === "note"
                      && note
                      && host.dataset.autoLoad === "true"
                    ) {
                      loadYouTube(host, false);
                    } else {
                      resetYouTube(host);
                    }
                  });
                if (current) updateSlideDescendantFocus(current, true);
              };

              const updatePresentation = (
                direction = 0,
                updateHash = true,
                cameraRoute = []
              ) => {
                currentSlideIndex = Math.min(
                  Math.max(0, currentSlideIndex),
                  Math.max(0, slides.length - 1)
                );
                const durationRoute = cameraRoute.length > 0
                  ? cameraRoute
                  : [
                      presentationCameraPoint,
                      slideMapPoint(currentSlide()),
                    ].filter(Boolean);
                presentation.style.setProperty(
                  "--presentation-travel-duration",
                  `${presentationTravelDuration(durationRoute)}ms`
                );
                slides.forEach((slide, index) => {
                  let position = "context";
                  if (index === currentSlideIndex) position = "current";
                  else if (index === currentSlideIndex - 1) position = "previous";
                  else if (index === currentSlideIndex + 1) position = "next";
                  slide.dataset.position = position;
                  const isCurrent = position === "current";
                  const isPreview = position === "previous" || position === "next";
                  const nodeFace = slide.querySelector(
                    ".presentation-node-front"
                  );
                  const noteFace = slide.querySelector(
                    ".presentation-note-back"
                  );
                  const showsNote =
                    isCurrent && slide.dataset.face === "note";
                  nodeFace?.setAttribute(
                    "aria-hidden",
                    String(!isCurrent || showsNote)
                  );
                  noteFace?.setAttribute(
                    "aria-hidden",
                    String(!isCurrent || !showsNote)
                  );
                  slide.setAttribute(
                    "aria-hidden",
                    String(!isCurrent && !isPreview)
                  );
                  updateSlideDescendantFocus(slide, isCurrent);
                  if (isPreview) {
                    slide.setAttribute("role", "button");
                    slide.tabIndex = 0;
                    const title =
                      slide.dataset.slideTitle?.trim() || "Untitled node";
                    const current = currentSlide();
                    const relation = position === "previous"
                      ? current?.dataset.previousRelationLabel
                      : current?.dataset.nextRelationLabel;
                    slide.setAttribute(
                      "aria-label",
                      position === "previous"
                        ? `Previous slide: ${title}. ${relation || ""}`
                        : `Next slide: ${title}. ${relation || ""}`
                    );
                  } else if (isCurrent) {
                    slide.setAttribute("role", "group");
                    slide.tabIndex = -1;
                    const title =
                      slide.querySelector("h1")?.textContent?.trim()
                      || "Untitled node";
                    const stepTitle = showsNote
                      ? `Note for ${title}`
                      : title;
                    slide.setAttribute(
                      "aria-label",
                      `Step ${presentationStepIndex() + 1}`
                      + ` of ${presentationStepCount}, ${stepTitle}`
                    );
                  } else {
                    slide.removeAttribute("role");
                    slide.tabIndex = -1;
                    slide.removeAttribute("aria-label");
                  }
                });
                travelCamera(cameraRoute);
                syncPresentationYouTubePlayers();
                progress.textContent =
                  presentationStepCount === 0
                    ? "0 of 0"
                    : `${presentationStepIndex() + 1}`
                      + ` of ${presentationStepCount}`;
                syncPresentationEdgeNavigation();
                if (updateHash && currentSlide()) {
                  const faceSuffix =
                    currentSlide().dataset.face === "note"
                      ? "&face=note"
                      : "";
                  history.replaceState(
                    null,
                    "",
                    `#node=${encodeURIComponent(currentSlide().dataset.nodeId)}`
                    + faceSuffix
                  );
                }
                requestAnimationFrame(updatePresentationConnections);
              };

              const setSlideFace = (slide, face) => {
                if (!slide) return;
                const showsNote =
                  face === "note" && slide.dataset.hasNote === "true";
                slide.dataset.face = showsNote ? "note" : "node";
                slide
                  .querySelector(".presentation-node-front")
                  ?.setAttribute("aria-hidden", String(showsNote));
                slide
                  .querySelector(".presentation-note-back")
                  ?.setAttribute("aria-hidden", String(!showsNote));
              };

              const resetPresentationFaces = () => {
                slides.forEach(slide => setSlideFace(slide, "node"));
              };

              const navigatePresentation = delta => {
                const source = currentSlide();
                if (!source || delta === 0) return;
                if (
                  delta > 0
                  && source.dataset.face === "node"
                  && source.dataset.hasNote === "true"
                ) {
                  toggleCurrentNote();
                  return;
                }
                if (delta < 0 && source.dataset.face === "note") {
                  toggleCurrentNote();
                  return;
                }
                const next = Math.min(
                  Math.max(0, currentSlideIndex + delta),
                  Math.max(0, slides.length - 1)
                );
                if (next === currentSlideIndex) return;
                const route = parseSpatialRoute(
                  delta < 0
                    ? source?.dataset.previousRoute
                    : source?.dataset.nextRoute
                );
                const routePivot = Number(
                  delta < 0
                    ? source?.dataset.previousRoutePivot
                    : source?.dataset.nextRoutePivot
                );
                const cameraRoute = smoothBranchRoute(route, routePivot);
                resetPresentationFaces();
                currentSlideIndex = next;
                if (
                  delta < 0
                  && currentSlide()?.dataset.hasNote === "true"
                ) {
                  setSlideFace(currentSlide(), "note");
                }
                updatePresentation(delta, true, cameraRoute);
                requestAnimationFrame(() => {
                  currentSlide()?.focus({ preventScroll: true });
                });
              };

              const navigatePresentationTo = index => {
                if (
                  !Number.isInteger(index)
                  || index < 0
                  || index >= slides.length
                  || index === currentSlideIndex
                ) {
                  return;
                }
                const source = currentSlide();
                let route = [];
                if (index === currentSlideIndex - 1) {
                  route = parseSpatialRoute(source?.dataset.previousRoute);
                } else if (index === currentSlideIndex + 1) {
                  route = parseSpatialRoute(source?.dataset.nextRoute);
                } else {
                  route = [
                    slideMapPoint(source),
                    slideMapPoint(slides[index]),
                  ].filter(Boolean);
                }
                const direction = index < currentSlideIndex ? -1 : 1;
                resetPresentationFaces();
                currentSlideIndex = index;
                updatePresentation(direction, true, route);
                requestAnimationFrame(() => {
                  currentSlide()?.focus({ preventScroll: true });
                });
              };

              const setMode = (mode, updateHash = true) => {
                currentMode = mode === "presentation" ? "presentation" : "map";
                const presents = currentMode === "presentation";
                resetMapNodeFaces();
                viewport.hidden = presents;
                presentation.hidden = !presents;
                mapModeButton.setAttribute("aria-pressed", String(!presents));
                presentationModeButton.setAttribute("aria-pressed", String(presents));
                progress.hidden = !presents;
                if (presents) {
                  updatePresentation(0, updateHash);
                  requestAnimationFrame(() => currentSlide()?.focus());
                } else {
                  resetPresentationFaces();
                  document
                    .querySelectorAll(
                      ".presentation-slide [data-youtube-host]"
                    )
                    .forEach(resetYouTube);
                  updatePresentationConnections();
                  if (updateHash) history.replaceState(null, "", "#map");
                  requestAnimationFrame(fit);
                }
              };

              const toggleCurrentNote = () => {
                const slide = currentSlide();
                if (!slide || slide.dataset.hasNote !== "true") return;
                const nextFace =
                  slide.dataset.face === "note" ? "node" : "note";
                setSlideFace(slide, nextFace);
                updatePresentation(0, true, []);
                requestAnimationFrame(() => {
                  slide.focus({ preventScroll: true });
                });
              };

              const setMapNodeFace = (
                node,
                face,
                syncViewportTouchAction = true
              ) => {
                if (!node || node.dataset.hasNote !== "true") return;
                const showsNote = face === "note";
                node.dataset.face = showsNote ? "note" : "node";
                node.setAttribute("aria-expanded", String(showsNote));
                const title = node.dataset.nodeTitle?.trim() || "Untitled node";
                node.setAttribute(
                  "aria-label",
                  showsNote
                    ? `${title}. Note shown. Press Escape to return to the title.`
                    : `${title}. Has note. Press Enter to show it.`
                );
                const front = node.querySelector(".map-node-front");
                const back = node.querySelector(".map-node-note-back");
                front?.setAttribute("aria-hidden", String(showsNote));
                back?.setAttribute("aria-hidden", String(!showsNote));
                updateMapNodeDescendantFocus(node);
                if (!showsNote) {
                  node
                    .querySelectorAll("[data-youtube-host]")
                    .forEach(resetYouTube);
                }
                if (syncViewportTouchAction) {
                  viewport.classList.toggle("note-open", showsNote);
                }
              };

              const resetMapNodeFaces = () => {
                mapNoteNodes.forEach(
                  node => setMapNodeFace(node, "node", false)
                );
                viewport.classList.remove("note-open");
              };

              const openMapNodeNote = node => {
                if (
                  currentMode !== "map"
                  || node?.dataset.hasNote !== "true"
                ) return;
                const showsNote = node.dataset.face !== "note";
                if (showsNote) {
                  mapNoteNodes.forEach(candidate => {
                    if (candidate !== node) {
                      setMapNodeFace(candidate, "node", false);
                    }
                  });
                }
                setMapNodeFace(node, showsNote ? "note" : "node");
                if (showsNote) {
                  centerMapNode(node);
                }
                requestAnimationFrame(() => {
                  const focusTarget = showsNote
                    ? node.querySelector(".map-node-note-back")
                    : node;
                  focusTarget?.focus({ preventScroll: true });
                });
              };

              const clampScale = value =>
                Math.min(maximumScale, Math.max(minimumScale, value));

              const syncMapNoteCounterScale = () => {
                const counterScale = 1 / Math.max(scale, minimumScale);
                mapNoteNodes.forEach(node => {
                  node.style.setProperty(
                    "--map-note-counter-scale",
                    String(counterScale)
                  );
                });
              };

              const render = () => {
                stage.style.transform =
                  `translate(${offsetX}px, ${offsetY}px) scale(${scale})`;
                syncMapNoteCounterScale();
              };

              const centerMapNode = node => {
                if (!node) return;
                const bounds = viewport.getBoundingClientRect();
                const x = Number(node.dataset.x)
                  + Number(node.dataset.width) / 2;
                const y = Number(node.dataset.y)
                  + Number(node.dataset.height) / 2;
                if (!Number.isFinite(x) || !Number.isFinite(y)) return;
                offsetX = bounds.width / 2 - x * scale;
                offsetY = bounds.height / 2 - y * scale;
                fitted = false;
                render();
              };

              const centerAtScale = nextScale => {
                const bounds = viewport.getBoundingClientRect();
                scale = clampScale(nextScale);
                offsetX = (bounds.width - mapWidth * scale) / 2;
                offsetY = (bounds.height - mapHeight * scale) / 2;
                render();
              };

              const fit = () => {
                const bounds = viewport.getBoundingClientRect();
                const padding = Math.min(
                  48,
                  Math.max(16, Math.min(bounds.width, bounds.height) * 0.05)
                );
                const availableWidth = Math.max(1, bounds.width - padding * 2);
                const availableHeight = Math.max(1, bounds.height - padding * 2);
                fitted = true;
                centerAtScale(
                  Math.min(1, availableWidth / mapWidth, availableHeight / mapHeight)
                );
              };

              const reset = () => {
                fitted = false;
                centerAtScale(1);
              };

              const zoomAt = (viewportX, viewportY, nextScale) => {
                const clampedScale = clampScale(nextScale);
                const safeScale = Math.max(scale, 0.01);
                const documentX = (viewportX - offsetX) / safeScale;
                const documentY = (viewportY - offsetY) / safeScale;
                offsetX = viewportX - documentX * clampedScale;
                offsetY = viewportY - documentY * clampedScale;
                scale = clampedScale;
                fitted = false;
                render();
              };

              const zoomAtCenter = factor => {
                const bounds = viewport.getBoundingClientRect();
                zoomAt(bounds.width / 2, bounds.height / 2, scale * factor);
              };

              const pointerPosition = event => {
                const bounds = viewport.getBoundingClientRect();
                return {
                  x: event.clientX - bounds.left,
                  y: event.clientY - bounds.top
                };
              };

              const twoPointerGesture = () => {
                const points = Array.from(activePointers.values()).slice(0, 2);
                if (points.length < 2) return null;
                const [first, second] = points;
                return {
                  x: (first.x + second.x) / 2,
                  y: (first.y + second.y) / 2,
                  distance: Math.hypot(second.x - first.x, second.y - first.y)
                };
              };

              const applyPinch = (previous, current) => {
                const safeScale = Math.max(scale, 0.01);
                const documentX = (previous.x - offsetX) / safeScale;
                const documentY = (previous.y - offsetY) / safeScale;
                const factor =
                  previous.distance > 0 ? current.distance / previous.distance : 1;
                const nextScale = clampScale(scale * factor);
                offsetX = current.x - documentX * nextScale;
                offsetY = current.y - documentY * nextScale;
                scale = nextScale;
                fitted = false;
                render();
              };

              const registerTap = point => {
                const now = performance.now();
                if (
                  lastTap
                  && now - lastTap.time <= doubleTapDelay
                  && Math.hypot(point.x - lastTap.x, point.y - lastTap.y)
                    <= doubleTapDistance
                ) {
                  lastTap = null;
                  fit();
                  return;
                }
                lastTap = { x: point.x, y: point.y, time: now };
              };

              viewport.addEventListener("wheel", event => {
                event.preventDefault();
                const bounds = viewport.getBoundingClientRect();
                const lineMultiplier =
                  event.deltaMode === WheelEvent.DOM_DELTA_LINE ? 16 : 1;
                const factor = Math.exp(-event.deltaY * lineMultiplier * 0.0015);
                zoomAt(
                  event.clientX - bounds.left,
                  event.clientY - bounds.top,
                  scale * factor
                );
              }, { passive: false });

              viewport.addEventListener("pointerdown", event => {
                if (
                  event.target.closest?.(
                    "button, a, iframe, .map-node-note-back"
                  )
                ) return;
                if (
                  event.pointerType !== "touch"
                  && (!event.isPrimary || event.button !== 0)
                ) return;
                event.preventDefault();
                const point = pointerPosition(event);
                activePointers.set(event.pointerId, point);
                const noteNode = event.target.closest?.(
                  '.node[data-has-note="true"]'
                );
                mapNodePointer = noteNode
                  ? {
                      pointerId: event.pointerId,
                      node: noteNode,
                      startX: point.x,
                      startY: point.y,
                      moved: false
                    }
                  : null;
                if (event.pointerType === "touch" && activePointers.size === 1) {
                  tapCandidate = {
                    pointerId: event.pointerId,
                    startX: point.x,
                    startY: point.y,
                    startedAt: performance.now()
                  };
                } else {
                  tapCandidate = null;
                }
                viewport.classList.add("dragging");
                if (viewport.setPointerCapture) {
                  viewport.setPointerCapture(event.pointerId);
                }
              });

              viewport.addEventListener("pointermove", event => {
                const previousPoint = activePointers.get(event.pointerId);
                if (!previousPoint) return;
                event.preventDefault();
                const previousGesture = twoPointerGesture();
                const point = pointerPosition(event);
                activePointers.set(event.pointerId, point);
                if (
                  mapNodePointer?.pointerId === event.pointerId
                  && Math.hypot(
                    point.x - mapNodePointer.startX,
                    point.y - mapNodePointer.startY
                  ) > tapMoveThreshold
                ) {
                  mapNodePointer.moved = true;
                }

                if (
                  tapCandidate?.pointerId === event.pointerId
                  && Math.hypot(
                    point.x - tapCandidate.startX,
                    point.y - tapCandidate.startY
                  ) > tapMoveThreshold
                ) {
                  tapCandidate = null;
                }

                if (activePointers.size >= 2) {
                  tapCandidate = null;
                  if (mapNodePointer) mapNodePointer.moved = true;
                  const currentGesture = twoPointerGesture();
                  if (previousGesture && currentGesture) {
                    applyPinch(previousGesture, currentGesture);
                  }
                  return;
                }

                const deltaX = point.x - previousPoint.x;
                const deltaY = point.y - previousPoint.y;
                if (deltaX === 0 && deltaY === 0) return;
                offsetX += deltaX;
                offsetY += deltaY;
                fitted = false;
                render();
              });

              const endPointer = (event, cancelled = false) => {
                const point = activePointers.get(event.pointerId);
                if (!point) return;
                const nodeActivation =
                  mapNodePointer?.pointerId === event.pointerId
                    ? mapNodePointer
                    : null;
                const isTap =
                  !cancelled
                  && event.pointerType === "touch"
                  && activePointers.size === 1
                  && tapCandidate?.pointerId === event.pointerId
                  && performance.now() - tapCandidate.startedAt <= doubleTapDelay;

                activePointers.delete(event.pointerId);
                tapCandidate = null;
                if (nodeActivation) mapNodePointer = null;
                if (
                  !cancelled
                  && nodeActivation
                  && !nodeActivation.moved
                ) {
                  openMapNodeNote(nodeActivation.node);
                } else if (isTap) {
                  registerTap(point);
                }
                if (activePointers.size === 0) {
                  viewport.classList.remove("dragging");
                }
                if (viewport.hasPointerCapture(event.pointerId)) {
                  viewport.releasePointerCapture(event.pointerId);
                }
              };
              viewport.addEventListener("pointerup", event => endPointer(event));
              viewport.addEventListener(
                "pointercancel",
                event => endPointer(event, true)
              );
              viewport.addEventListener(
                "lostpointercapture",
                event => endPointer(event, true)
              );
              viewport.addEventListener("dblclick", event => {
                if (event.target.closest?.(".node")) return;
                fit();
              });

              document.addEventListener("keydown", event => {
                const interactiveTarget = event.target.closest?.(
                  "button, a, input, textarea, iframe, [role=button]"
                );
                if (currentMode === "presentation") {
                  if (event.key === "Escape") {
                    event.preventDefault();
                    setMode("map");
                    return;
                  }
                  const previewTarget = event.target.closest?.(
                    '.presentation-slide[data-position="previous"],'
                    + '.presentation-slide[data-position="next"]'
                  );
                  if (
                    previewTarget
                    && (event.key === "Enter" || event.key === " ")
                  ) {
                    event.preventDefault();
                    navigatePresentation(
                      previewTarget.dataset.position === "previous" ? -1 : 1
                    );
                    return;
                  }
                  if (event.key.toLowerCase() === "n") {
                    event.preventDefault();
                    toggleCurrentNote();
                    return;
                  }
                  if (interactiveTarget && !previewTarget) return;
                  if (
                    event.key === "ArrowRight"
                    || event.key === "ArrowDown"
                    || event.key === " "
                    || event.key === "PageDown"
                  ) {
                    event.preventDefault();
                    navigatePresentation(1);
                  } else if (
                    event.key === "ArrowLeft"
                    || event.key === "ArrowUp"
                    || event.key === "PageUp"
                  ) {
                    event.preventDefault();
                    navigatePresentation(-1);
                  } else if (event.key === "Home") {
                    event.preventDefault();
                    resetPresentationFaces();
                    currentSlideIndex = 0;
                    updatePresentation(-1);
                    requestAnimationFrame(() => {
                      currentSlide()?.focus({ preventScroll: true });
                    });
                  } else if (event.key === "End") {
                    event.preventDefault();
                    resetPresentationFaces();
                    currentSlideIndex = Math.max(0, slides.length - 1);
                    if (currentSlide()?.dataset.hasNote === "true") {
                      setSlideFace(currentSlide(), "note");
                    }
                    updatePresentation(1);
                    requestAnimationFrame(() => {
                      currentSlide()?.focus({ preventScroll: true });
                    });
                  }
                  return;
                }

                const mapNoteNode = event.target.closest?.(
                  '.node[data-has-note="true"]'
                );
                if (
                  mapNoteNode
                  && mapNoteNode.dataset.face === "note"
                  && event.key === "Escape"
                ) {
                  event.preventDefault();
                  openMapNodeNote(mapNoteNode);
                  return;
                }
                const mapKeyboardSurface =
                  event.target === mapNoteNode
                  || event.target === mapNoteNode?.querySelector(
                    ".map-node-note-back"
                  );
                if (
                  mapKeyboardSurface
                  && (event.key === "Enter" || event.key === " ")
                ) {
                  event.preventDefault();
                  openMapNodeNote(mapNoteNode);
                  return;
                }
                if (interactiveTarget) return;
                if (event.key === "+" || event.key === "=") {
                  event.preventDefault();
                  zoomAtCenter(1.15);
                } else if (event.key === "-") {
                  event.preventDefault();
                  zoomAtCenter(1 / 1.15);
                } else if (event.key === "0") {
                  event.preventDefault();
                  reset();
                } else if (event.key.toLowerCase() === "f") {
                  event.preventDefault();
                  fit();
                }
              });

              const resizeViewport = () => {
                const bounds = viewport.getBoundingClientRect();
                const nextWidth = bounds.width;
                const nextHeight = bounds.height;
                if (fitted) {
                  fit();
                } else {
                  offsetX += (nextWidth - viewportWidth) / 2;
                  offsetY += (nextHeight - viewportHeight) / 2;
                  render();
                }
                viewportWidth = nextWidth;
                viewportHeight = nextHeight;
                requestAnimationFrame(() => {
                  updatePresentationSpatialPositions();
                  updatePresentationConnections();
                });
              };
              window.addEventListener("resize", resizeViewport);
              window.visualViewport?.addEventListener("resize", resizeViewport);

              mapModeButton.addEventListener("click", () => setMode("map"));
              presentationModeButton.addEventListener(
                "click",
                () => setMode("presentation")
              );
              previousPresentationButton.addEventListener(
                "click",
                () => navigatePresentation(-1)
              );
              nextPresentationButton.addEventListener(
                "click",
                () => navigatePresentation(1)
              );
              presentationStage.addEventListener("pointerdown", event => {
                if (
                  currentMode !== "presentation"
                  || event.pointerType !== "touch"
                  || event.target.closest?.(
                    "button, a, iframe"
                  )
                ) {
                  presentationSwipe = null;
                  return;
                }
                // A new deliberate touch must remain clickable even if it
                // begins during the prior swipe's short suppression window.
                suppressPresentationSlideClickUntil = 0;
                presentationSwipe = {
                  pointerId: event.pointerId,
                  x: event.clientX,
                  y: event.clientY,
                };
              });
              presentationStage.addEventListener("pointerup", event => {
                const start = presentationSwipe;
                presentationSwipe = null;
                if (!start || start.pointerId !== event.pointerId) return;
                const dx = event.clientX - start.x;
                const dy = event.clientY - start.y;
                if (
                  Math.abs(dx) < 48
                  || Math.abs(dx) <= Math.abs(dy) * 1.2
                ) {
                  return;
                }
                // Mobile Safari synthesizes a click after pointerup. Without
                // this guard the click can land on the source slide after the
                // swipe has already advanced, immediately navigating back.
                suppressPresentationSlideClickUntil =
                  performance.now() + 450;
                navigatePresentation(dx < 0 ? 1 : -1);
              });
              presentationStage.addEventListener(
                "pointercancel",
                () => { presentationSwipe = null; }
              );

              document.addEventListener("click", event => {
                const youtube = event.target.closest?.("[data-youtube-play]");
                if (youtube) {
                  event.preventDefault();
                  event.stopPropagation();
                  loadYouTube(
                    youtube.closest("[data-youtube-host]"),
                    true
                  );
                  return;
                }

                const mapNoteClose = event.target.closest?.(
                  "[data-map-note-close]"
                );
                if (mapNoteClose && currentMode === "map") {
                  event.preventDefault();
                  event.stopPropagation();
                  openMapNodeNote(
                    mapNoteClose.closest('.node[data-has-note="true"]')
                  );
                  return;
                }
                const mapNoteBack = event.target.closest?.(
                  ".map-node-note-back"
                );
                if (
                  mapNoteBack
                  && event.target === mapNoteBack
                  && currentMode === "map"
                ) {
                  openMapNodeNote(
                    mapNoteBack.closest('.node[data-has-note="true"]')
                  );
                  return;
                }

                const slide = event.target.closest?.(".presentation-slide");
                if (!slide || currentMode !== "presentation") return;
                if (
                  performance.now() < suppressPresentationSlideClickUntil
                ) {
                  event.preventDefault();
                  event.stopPropagation();
                  return;
                }
                const index = slideIndexByElement.get(slide) ?? -1;
                if (index === currentSlideIndex) {
                  if (slide.dataset.face === "node") {
                    if (slide.dataset.hasNote === "true") {
                      toggleCurrentNote();
                    } else {
                      navigatePresentation(1);
                    }
                  }
                  return;
                }
                navigatePresentationTo(index);
              });

              const applyHash = () => {
                if (location.hash.startsWith("#node=")) {
                  try {
                    const parameters = new URLSearchParams(
                      location.hash.slice(1)
                    );
                    const nodeID = parameters.get("node");
                    const matchedSlide = slideByNodeID.get(nodeID);
                    const index = matchedSlide
                      ? slideIndexByElement.get(matchedSlide) ?? -1
                      : -1;
                    if (index >= 0) {
                      resetPresentationFaces();
                      currentSlideIndex = index;
                      if (
                        parameters.get("face") === "note"
                        && currentSlide()?.dataset.hasNote === "true"
                      ) {
                        setSlideFace(currentSlide(), "note");
                      }
                      setMode("presentation", false);
                      updatePresentation(0, false);
                      return;
                    }
                  } catch {
                    // A malformed shared hash must not prevent the viewer from
                    // initializing in its configured map/presentation mode.
                  }
                }
                if (location.hash === "#map") {
                  setMode("map", false);
                  return;
                }
                setMode(currentMode, false);
              };
              window.addEventListener("hashchange", applyHash);

              requestAnimationFrame(() => {
                updatePresentation(0, false);
                applyHash();
                if (currentMode === "map") fit();
              });
            })();
          </script>
        </body>
        </html>
        """

        let html = applyingInlineScriptHash(to: htmlTemplate)
        return Data(html.utf8)
    }

    /// Restrict executable inline content to the exact generated viewer script.
    /// Styles remain inline because node frames/colors are document-specific,
    /// but note/title escaping regressions cannot introduce executable script.
    private static func applyingInlineScriptHash(to html: String) -> String {
        let placeholder = "__BRAINSTORM_SCRIPT_SHA256__"
        guard let openingRange = html.range(of: "<script>"),
              let closingRange = html.range(
                of: "</script>",
                range: openingRange.upperBound..<html.endIndex
              )
        else {
            return html.replacingOccurrences(of: placeholder, with: "")
        }
        let script = html[openingRange.upperBound..<closingRange.lowerBound]
        let digest = SHA256.hash(data: Data(script.utf8))
        let base64 = Data(digest).base64EncodedString()
        return html.replacingOccurrences(of: placeholder, with: base64)
    }

    // MARK: - Scene markup

    /// A compact folded-note glyph on Tabler's 24×24 grid, embedded so
    /// exported viewers stay self-contained and do not fetch an icon package.
    /// Its quiet theme tint and short text strokes match native presentation.
    private static let tablerNoteIconMarkup = """
    <svg
      class="note-sticker-icon icon-tabler icon-tabler-note"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.75"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path
        d="M5 3h9l7 7v9a2 2 0 0 1 -2 2h-14a2 2 0 0 1 -2 -2v-14a2 2 0 0 1 2 -2z"
        fill="currentColor"
        fill-opacity="0.13"
      ></path>
      <path d="M14 3v6a1 1 0 0 0 1 1h6"></path>
      <path class="note-detail-line" d="M7 14h10"></path>
      <path class="note-detail-line" d="M7 18h7"></path>
    </svg>
    """

    private static func mapNoteMarkerMarkup(
        _ node: LayoutNode,
        note: NodeNote
    ) -> String {
        let noteID = node.id.uuidString
        let localFrame = CGRect(origin: .zero, size: node.frame.size)
        let markerOrigin = noteMarkerOrigin(
            in: localFrame,
            shape: node.style.shape,
            trailingInset: 2,
            topInset: 3
        )
        return """
        <span
          class="map-note-marker"
          data-map-note-node-id="\(noteID)"
          data-shape="\(node.style.shape.rawValue)"
          data-saved-visible="\(note.visibility == .shown)"
          role="img"
          aria-label="Has note: \(escapeHTML(displayedTitle(node.title, isRoot: node.depth == 0)))"
          style="left: \(number(markerOrigin.x))px; top: \(number(markerOrigin.y))px;"
        >\(tablerNoteIconMarkup)</span>
        """
    }

    /// Returns the top-left of the passive 16-point in-node note marker.
    /// Rectangular shapes preserve the compact trailing-corner placement. A
    /// diamond uses a normalized interior point whose available offset is
    /// reduced for narrow nodes, keeping the glyph inside both sloping edges.
    private static func noteMarkerOrigin(
        in frame: CGRect,
        shape: NodeShape,
        trailingInset: CGFloat,
        topInset: CGFloat
    ) -> CGPoint {
        let markerSize: CGFloat = 16
        guard shape == .diamond else {
            return CGPoint(
                x: max(frame.minX, frame.maxX - markerSize - trailingInset),
                y: max(frame.minY, frame.minY + topInset)
            )
        }

        let glyphRadius: CGFloat = 6.5
        let edgeSafety: CGFloat = 0.06
        let horizontalRadius = max(1, frame.width / 2)
        let verticalRadius = max(1, frame.height / 2)
        let desiredHorizontalOffset: CGFloat = 0.20
        let desiredVerticalOffset: CGFloat = 0.28
        let desiredOffset = desiredHorizontalOffset + desiredVerticalOffset
        let availableOffset = max(
            0,
            1
                - (glyphRadius / horizontalRadius)
                - (glyphRadius / verticalRadius)
                - edgeSafety
        )
        let offsetScale = min(1, availableOffset / desiredOffset)
        let center = CGPoint(
            x: frame.midX
                + horizontalRadius * desiredHorizontalOffset * offsetScale,
            y: frame.midY
                - verticalRadius * desiredVerticalOffset * offsetScale
        )

        return CGPoint(
            x: center.x - markerSize / 2,
            y: center.y - markerSize / 2
        )
    }

    private static func presentationSlideMarkup(
        _ item: PresentationItem,
        index: Int,
        count: Int,
        isRoot: Bool,
        previousRelationship: PresentationRelationship?,
        nextRelationship: PresentationRelationship?,
        previousRoute: PresentationTraversalRoute?,
        nextRoute: PresentationTraversalRoute?,
        presentationTitles: [UUID: String],
        noteInclusion: BrainstormNoteInclusion,
        theme: AppTheme,
        palette: HTMLPalette
    ) -> String {
        let node = item.node
        let title = displayedTitle(node.title, isRoot: isRoot)
        let fill = HTMLColor(hex: theme.resolvedFillHex(style: node.style, isRoot: isRoot))
            ?? (isRoot ? palette.selection.withOpacity(0.14) : palette.controlBackground)
        let text: HTMLColor
        if let custom = HTMLColor(hex: node.style.textHex) {
            text = custom
        } else if let fillHex = node.style.fillHex,
                  let contrast = ColorContrast.contrastingTextHex(forFill: fillHex),
                  let resolved = HTMLColor(hex: contrast)
        {
            text = resolved
        } else {
            text = HTMLColor(hex: theme.defaultText(isRoot: isRoot)) ?? palette.primary
        }
        let border = HTMLColor(hex: node.style.borderHex)
            ?? palette.primary.withOpacity(palette.isDark ? 0.25 : 0.14)
        let borderWidth = CGFloat(node.style.borderWidth ?? (isRoot ? 2 : 1.5))
        let frame = item.layoutFrame ?? CGRect(x: 0, y: 0, width: 180, height: 56)
        let localFrame = CGRect(origin: .zero, size: frame.size)
        let nodePath = shapePath(
            localFrame,
            shape: node.style.shape,
            isRoot: isRoot
        )
        let media = presentationMediaMarkup(node.media, palette: palette)
        let includedNote: NodeNote? = node.note.flatMap {
            noteInclusion.includes($0) ? $0 : nil
        }
        let noteBack = includedNote.map { value in
            return """
            <section
              class="presentation-note-back"
              data-saved-visible="\(value.visibility == .shown)"
              aria-hidden="true"
            >
              <header class="presentation-note-header">
                <strong>\(escapeHTML(title))</strong>
                <span class="presentation-note-indicator" aria-hidden="true">
                  \(tablerNoteIconMarkup)
                </span>
              </header>
              <div class="presentation-note">
            \(indent(noteMarkup(value, youtubeBehavior: .presentationAutoLoad), spaces: 4))
              </div>
            </section>
            """
        } ?? ""
        let noteIndicator = includedNote == nil
            ? ""
            : """
              <span
                class="presentation-note-indicator presentation-node-note-indicator"
                aria-hidden="true"
              >
                \(tablerNoteIconMarkup)
              </span>
            """
        let previousMetadata = relationshipMetadata(
            previousRelationship,
            direction: .previous,
            titles: presentationTitles
        )
        let nextMetadata = relationshipMetadata(
            nextRelationship,
            direction: .next,
            titles: presentationTitles
        )
        let center = item.layoutCenter ?? .zero
        let initialPosition: String
        if index == 0 {
            initialPosition = "current"
        } else if index == 1 {
            initialPosition = "next"
        } else {
            initialPosition = "context"
        }
        let fontSize = CGFloat(node.style.fontSize ?? (isRoot ? 16 : 14))
        let fontWeight = node.style.isBold || isRoot ? 600 : 500
        let fontStyle = node.style.isItalic ? "italic" : "normal"
        let verticalPadding: CGFloat = isRoot ? 12 : 10
        let mediaSize: CGFloat = isRoot ? 22 : 20
        let mediaIsActive = node.media.activeKind != nil
        let titleWidth = max(
            1,
            frame.width - 32 - (mediaIsActive ? mediaSize + 6 : 0)
        )
        let font = LayoutEngine().font(for: node.style, isRoot: isRoot)
        let titleLayout = layoutTitle(title, font: font, width: titleWidth)
        let titleLines = titleLayout.lines
            .map {
                """
                <span class="presentation-node-line">\(escapeHTML($0))</span>
                """
            }
            .joined(separator: "\n")
        let slideStyle = [
            "left: \(number(frame.minX))px",
            "top: \(number(frame.minY))px",
            "width: \(number(frame.width))px",
            "height: \(number(frame.height))px",
            "--slide-fill: \(fill.css)",
            "--slide-text: \(text.css)",
            "--slide-border: \(border.css)",
            "--slide-border-width: \(number(borderWidth))px",
            "--slide-font-size: \(number(fontSize))px",
            "--slide-font-weight: \(fontWeight)",
            "--slide-font-style: \(fontStyle)",
            "--slide-line-height: \(number(titleLayout.lineHeight))px",
            "--node-padding-y: \(number(verticalPadding))px",
            "--node-gap: \(mediaIsActive ? "6px" : "0px")",
            "--presentation-media-size: \(number(mediaSize))px",
        ].joined(separator: "; ") + ";"
        let nodeFront = """
        <article
          class="presentation-node-front shape-\(node.style.shape.rawValue)"
          aria-hidden="false"
        >
          <svg
            class="presentation-node-shape"
            viewBox="0 0 \(number(frame.width)) \(number(frame.height))"
            aria-hidden="true"
            focusable="false"
          >
            <path
              d="\(nodePath)"
              fill="\(fill.css)"
              stroke="\(border.css)"
              stroke-width="\(number(borderWidth))"
            ></path>
            <path
              class="presentation-node-selection"
              d="\(nodePath)"
              fill="none"
              stroke="\(palette.accent.css)"
              stroke-width="2.5"
            ></path>
          </svg>
        \(indent(media, spaces: 2))
          <span class="presentation-node-title">
            <h1>
        \(indent(titleLines, spaces: 6))
            </h1>
          </span>
        \(indent(noteIndicator, spaces: 2))
        </article>
        """
        // A no-note slide is only the actual node surface. Avoid wrapping it
        // in a 3D card: Safari can rasterize that otherwise inert layer, and
        // the extra rectangle suggests generic slide chrome that does not
        // exist in the map.
        let presentationSurface = includedNote == nil
            ? nodeFront
            : """
              <div class="presentation-flip">
            \(indent(nodeFront, spaces: 4))
            \(indent(noteBack, spaces: 4))
              </div>
            """

        return """
        <section
          class="presentation-slide"
          data-node-id="\(node.id.uuidString)"
          data-parent-id="\(item.parentID?.uuidString ?? "")"
          data-sibling-index="\(item.siblingIndex)"
          data-slide-title="\(escapeHTML(title))"
          data-depth="\(item.depth)"
          data-map-x="\(number(center.x))"
          data-map-y="\(number(center.y))"
          data-map-width="\(number(frame.width))"
          data-map-height="\(number(frame.height))"
          data-base-font-size="\(number(fontSize))"
          data-base-line-height="\(number(titleLayout.lineHeight))"
          data-base-padding-y="\(number(verticalPadding))"
          data-base-gap="\(mediaIsActive ? "6" : "0")"
          data-base-media-size="\(number(mediaSize))"
          data-has-note="\(includedNote != nil)"
          data-face="node"
          data-previous-relation-kind="\(previousMetadata.kind)"
          data-previous-relation-label="\(escapeHTML(previousMetadata.label))"
          data-previous-route="\(spatialRouteMarkup(previousRoute))"
          data-previous-route-pivot="\(spatialRoutePivotIndex(previousRoute).map(String.init) ?? "")"
          data-next-relation-kind="\(nextMetadata.kind)"
          data-next-relation-label="\(escapeHTML(nextMetadata.label))"
          data-next-route="\(spatialRouteMarkup(nextRoute))"
          data-next-route-pivot="\(spatialRoutePivotIndex(nextRoute).map(String.init) ?? "")"
          data-position="\(initialPosition)"
          aria-label="Slide \(index + 1) of \(count), \(escapeHTML(title))"
          aria-hidden="false"
          style="\(slideStyle)"
        >
        \(indent(presentationSurface, spaces: 2))
        </section>
        """
    }

    private static func presentationMediaMarkup(
        _ media: NodeMedia,
        palette: HTMLPalette
    ) -> String {
        switch media.activeKind {
        case .emoji(let emoji):
            return """
            <span class="presentation-media" aria-label="Emoji \(escapeHTML(emoji))">\(escapeHTML(emoji))</span>
            """
        case .sticker(let symbol):
            guard let dataURL = stickerDataURL(
                symbolName: symbol,
                frame: 72,
                palette: palette
            ) else {
                return ""
            }
            return """
            <span
              class="presentation-media"
              role="img"
              aria-label="Icon \(escapeHTML(symbol))"
              style="background-image: url(\(dataURL));"
            ></span>
            """
        case .image(let encoded):
            guard let data = Data(base64Encoded: encoded),
                  NSImage(data: data) != nil
            else {
                return ""
            }
            return """
            <span
              class="presentation-media"
              role="img"
              aria-label="Image"
              style="background-image: url(data:image/png;base64,\(data.base64EncodedString())); background-size: cover;"
            ></span>
            """
        case .none:
            return ""
        }
    }

    private enum HTMLYouTubeBehavior: Equatable {
        case clickToLoad
        case presentationAutoLoad
    }

    private enum PresentationRelationshipDirection: Equatable {
        case previous
        case next
    }

    private static func spatialRouteMarkup(
        _ route: PresentationTraversalRoute?
    ) -> String {
        guard let points = route?.points else { return "" }
        return points
            .map { "\(number($0.x)),\(number($0.y))" }
            .joined(separator: ";")
    }

    private static func spatialRoutePivotIndex(
        _ route: PresentationTraversalRoute?
    ) -> Int? {
        guard let route else { return nil }
        guard case .branchJump(_, let ascendingLevels, _) =
            route.relationship
        else {
            return nil
        }
        return min(
            max(1, ascendingLevels),
            max(1, route.nodeIDs.count - 2)
        )
    }

    private static func relationshipMetadata(
        _ relationship: PresentationRelationship?,
        direction: PresentationRelationshipDirection,
        titles: [UUID: String]
    ) -> (kind: String, label: String) {
        guard let relationship else { return ("none", "") }
        let directional = direction == .previous ? "Previous" : "Next"
        switch relationship {
        case .parent(let levels):
            return (
                "parent",
                levels == 1 ? "Parent" : "Ancestor · \(levels) levels up"
            )
        case .child(let levels):
            return (
                "child",
                levels == 1 ? "Child" : "Descendant · \(levels) levels down"
            )
        case .sibling(let parentID):
            let parent = parentID.flatMap { titles[$0] } ?? "shared parent"
            return ("sibling", "\(directional) sibling · via \(parent)")
        case .branchJump(let ancestorID, _, _):
            let ancestor = titles[ancestorID] ?? "common branch"
            return (
                "branch",
                "\(directional) branch · via \(ancestor)"
            )
        }
    }

    private static func noteMarkup(
        _ note: NodeNote,
        youtubeBehavior: HTMLYouTubeBehavior
    ) -> String {
        let body = NodeNoteRendering.htmlBody(note.bodyMarkdown)
        let bodyMarkup = body.isEmpty ? "" : "<div class=\"note-body\">\(body)</div>"
        let attachments = note.attachments
            .map {
                noteAttachmentMarkup(
                    $0,
                    youtubeBehavior: youtubeBehavior
                )
            }
            .joined(separator: "\n")
        let attachmentMarkup = attachments.isEmpty
            ? ""
            : "<div class=\"note-attachments\">\n\(indent(attachments, spaces: 2))\n</div>"
        return [bodyMarkup, attachmentMarkup]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func noteAttachmentMarkup(
        _ attachment: NodeNoteAttachment,
        youtubeBehavior: HTMLYouTubeBehavior
    ) -> String {
        switch attachment {
        case .image(let image):
            guard let data = Data(base64Encoded: image.pngBase64),
                  NSImage(data: data) != nil
            else {
                return """
                <div class="note-media" role="img" aria-label="Image unavailable">Image unavailable</div>
                """
            }
            let alternativeText = NodeNoteRendering.nonEmpty(image.altText) ?? "Note image"
            let caption = NodeNoteRendering.nonEmpty(image.caption).map {
                "<figcaption>\(escapeHTML($0))</figcaption>"
            } ?? ""
            return """
            <figure class="note-media note-image">
              <img
                src="data:image/png;base64,\(data.base64EncodedString())"
                alt="\(escapeHTML(alternativeText))"
                loading="eager"
                draggable="false"
              >
            \(indent(caption, spaces: 2))
            </figure>
            """
        case .youtube(let youtube):
            let canonicalURL = youtube.canonicalURL.absoluteString
            let start = max(0, youtube.startSeconds ?? 0)
            let autoLoad = youtubeBehavior == .presentationAutoLoad
            let caption = NodeNoteRendering.nonEmpty(youtube.caption).map {
                "<figcaption>\(escapeHTML($0))</figcaption>"
            } ?? ""
            return """
            <figure class="note-media note-youtube">
              <div
                class="youtube-host"
                data-youtube-host
                data-video-id="\(escapeHTML(youtube.videoID))"
                data-start="\(start)"
                data-auto-load="\(autoLoad)"
              >
                <button
                  class="youtube-card"
                  type="button"
                  data-youtube-play
                  aria-label="Play YouTube video. Playback requires network access."
                >
                  <span class="play" aria-hidden="true">▶</span>
                  <span class="youtube-meta">
                    <strong>\(autoLoad ? "Loading YouTube player" : "Play YouTube video")</strong>
                    <small>Uses the privacy-enhanced youtube-nocookie.com player.</small>
                  </span>
                </button>
              </div>
              <a
                class="youtube-link"
                href="\(escapeHTML(canonicalURL))"
                target="_blank"
                rel="noopener noreferrer"
              >Open on YouTube</a>
            \(indent(caption, spaces: 2))
            </figure>
            """
        }
    }

    private static func branchMarkup(
        _ edge: LayoutEdge,
        theme: AppTheme,
        palette: HTMLPalette
    ) -> String {
        let middleX = (edge.from.x + edge.to.x) / 2
        let path = [
            "M", number(edge.from.x), number(edge.from.y),
            "C", number(middleX), number(edge.from.y),
            number(middleX), number(edge.to.y),
            number(edge.to.x), number(edge.to.y),
        ].joined(separator: " ")
        let color: HTMLColor
        if let override = HTMLColor(hex: edge.colorHex) {
            color = override.withOpacity(0.9)
        } else if let themed = HTMLColor(hex: theme.branch) {
            color = themed.withOpacity(0.9)
        } else {
            color = palette.accent.withOpacity(0.675)
        }
        return """
        <path
          data-edge-from="\(edge.fromID.uuidString)"
          data-edge-to="\(edge.toID.uuidString)"
          data-from-x="\(number(edge.from.x))"
          data-from-y="\(number(edge.from.y))"
          data-to-x="\(number(edge.to.x))"
          data-to-y="\(number(edge.to.y))"
          d="\(path)"
          fill="none"
          stroke="\(color.css)"
          stroke-width="2"
          stroke-linecap="round"
        />
        """
    }

    private static func shapeMarkup(
        _ node: LayoutNode,
        isRoot: Bool,
        theme: AppTheme,
        palette: HTMLPalette
    ) -> String {
        let fill = nodeFill(node, isRoot: isRoot, theme: theme, palette: palette)
        let border = nodeBorder(node, palette: palette)
        let borderWidth = CGFloat(node.style.borderWidth ?? (isRoot ? 1.5 : 1))
        let shadow = HTMLColor(red: 0, green: 0, blue: 0, alpha: palette.isDark ? 0.45 : 0.08)
        return """
        <path
          class="node-shape"
          data-node-id="\(node.id.uuidString)"
          data-shape="\(node.style.shape.rawValue)"
          d="\(shapePath(node.frame, shape: node.style.shape, isRoot: isRoot))"
          fill="\(fill.css)"
          stroke="\(border.css)"
          stroke-width="\(number(borderWidth))"
          style="filter: drop-shadow(0px 1px 3px \(shadow.css));"
        />
        """
    }

    private static func nodeMarkup(
        _ node: LayoutNode,
        isRoot: Bool,
        note: NodeNote?,
        theme: AppTheme,
        palette: HTMLPalette
    ) -> String {
        let hasNote = note != nil
        let fill = nodeFill(node, isRoot: isRoot, theme: theme, palette: palette)
        let text = nodeText(node, isRoot: isRoot, theme: theme, palette: palette)
        let border = nodeBorder(node, palette: palette)
        let borderWidth = CGFloat(node.style.borderWidth ?? (isRoot ? 1.5 : 1))
        let fontSize = CGFloat(node.style.fontSize ?? (isRoot ? 16 : 14))
        let fontWeight = node.style.isBold || isRoot ? 600 : 500
        let fontStyle = node.style.isItalic ? "italic" : "normal"
        let verticalPadding: CGFloat = isRoot ? 12 : 10
        let mediaSize: CGFloat = isRoot ? 22 : 20
        let mediaIsActive = node.media.activeKind != nil
        let titleWidth = max(
            1,
            node.frame.width - 32 - (mediaIsActive ? mediaSize + 6 : 0)
        )
        let title = displayedTitle(node.title, isRoot: isRoot)
        let font = LayoutEngine().font(for: node.style, isRoot: isRoot)
        let titleLayout = layoutTitle(title, font: font, width: titleWidth)
        let lines = titleLayout.lines
            .map { "<span class=\"node-line\">\(escapeHTML($0))</span>" }
            .joined(separator: "\n")
        let media = mediaMarkup(
            node.media,
            isRoot: isRoot,
            palette: palette
        )
        let gap = mediaIsActive ? 6 : 0
        let classes = [
            "node",
            "shape-\(node.style.shape.rawValue)",
            hasNote ? "map-node-flippable" : "",
        ]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let style = [
            "left: \(number(node.frame.minX))px",
            "top: \(number(node.frame.minY))px",
            "width: \(number(node.frame.width))px",
            "height: \(number(node.frame.height))px",
            "--node-fill: \(fill.css)",
            "--node-text: \(text.css)",
            "--node-border: \(border.css)",
            "--node-border-width: \(number(borderWidth))px",
            "--node-font-size: \(number(fontSize))px",
            "--node-font-weight: \(fontWeight)",
            "--node-font-style: \(fontStyle)",
            "--node-line-height: \(number(titleLayout.lineHeight))px",
            "--node-padding-y: \(number(verticalPadding))px",
            "--node-gap: \(gap)px",
            "--media-size: \(number(mediaSize))px",
            "--media-font-size: \(number(max(1, mediaSize - 4)))px",
        ].joined(separator: "; ") + ";"
        let titleMarkup = """
        \(media)
        <span class="node-title">
        \(indent(lines, spaces: 2))
        </span>
        """
        let surfaceMarkup: String
        if let note {
            let localFrame = CGRect(origin: .zero, size: node.frame.size)
            let nodePath = shapePath(
                localFrame,
                shape: node.style.shape,
                isRoot: isRoot
            )
            let shadow = HTMLColor(
                red: 0,
                green: 0,
                blue: 0,
                alpha: palette.isDark ? 0.45 : 0.08
            )
            let marker = mapNoteMarkerMarkup(node, note: note)
            surfaceMarkup = """
            <div class="map-node-flip">
              <div class="map-node-front" aria-hidden="false">
                <svg
                  class="map-node-inline-shape"
                  viewBox="0 0 \(number(node.frame.width)) \(number(node.frame.height))"
                  aria-hidden="true"
                  focusable="false"
                >
                  <path
                    d="\(nodePath)"
                    fill="\(fill.css)"
                    stroke="\(border.css)"
                    stroke-width="\(number(borderWidth))"
                    style="filter: drop-shadow(0px 1px 3px \(shadow.css));"
                  ></path>
                </svg>
            \(indent(titleMarkup, spaces: 4))
            \(indent(marker, spaces: 4))
              </div>
              <section
                class="map-node-note-back"
                data-saved-visible="\(note.visibility == .shown)"
                aria-label="Note for \(escapeHTML(title))"
                aria-hidden="true"
                tabindex="-1"
              >
                <header class="map-node-note-header">
                  <strong>\(escapeHTML(title))</strong>
                  <button
                    class="map-node-note-close"
                    type="button"
                    data-map-note-close
                    aria-label="Show title for \(escapeHTML(title))"
                  >Back</button>
                </header>
                <div class="map-node-note-scroll">
            \(indent(noteMarkup(note, youtubeBehavior: .clickToLoad), spaces: 6))
                </div>
              </section>
            </div>
            """
        } else {
            surfaceMarkup = titleMarkup
        }

        return """
        <article
          class="\(classes)"
          role="listitem"
          data-has-note="\(hasNote)"
          data-face="node"
          data-node-id="\(node.id.uuidString)"
          data-node-title="\(escapeHTML(title))"
          data-x="\(number(node.frame.minX))"
          data-y="\(number(node.frame.minY))"
          data-width="\(number(node.frame.width))"
          data-height="\(number(node.frame.height))"
          data-depth="\(node.depth)"
          data-shape="\(node.style.shape.rawValue)"
          data-expanded="\(node.isExpanded)"
          data-child-count="\(node.childCount)"
          \(hasNote ? #"tabindex="0""# : "")
          \(hasNote ? #"aria-expanded="false""# : "")
          aria-label="\(escapeHTML(hasNote ? "\(title). Has note. Press Enter to show it." : title))"
          style="\(style)"
        >
        \(indent(surfaceMarkup, spaces: 2))
        </article>
        """
    }

    private static func mediaMarkup(
        _ media: NodeMedia,
        isRoot: Bool,
        palette: HTMLPalette
    ) -> String {
        let frame: CGFloat = isRoot ? 22 : 20
        switch media.activeKind {
        case .emoji(let emoji):
            return """
            <span
              class="node-media node-emoji"
              data-media-kind="emoji"
              aria-label="Emoji \(escapeHTML(emoji))"
            >\(escapeHTML(emoji))</span>
            """
        case .sticker(let symbol):
            guard let dataURL = stickerDataURL(
                symbolName: symbol,
                frame: frame,
                palette: palette
            ) else {
                return """
                <span
                  class="node-media"
                  data-media-kind="sticker"
                  data-symbol="\(escapeHTML(symbol))"
                  aria-label="Icon \(escapeHTML(symbol))"
                ></span>
                """
            }
            return """
            <span class="node-media" data-media-kind="sticker">
              <img
                class="sticker-image"
                src="\(dataURL)"
                alt=""
                data-symbol="\(escapeHTML(symbol))"
                draggable="false"
              >
            </span>
            """
        case .image(let encoded):
            guard let imageData = Data(base64Encoded: encoded),
                  NSImage(data: imageData) != nil
            else {
                return """
                <span class="node-media" data-media-kind="image" aria-label="Image"></span>
                """
            }
            return """
            <span class="node-media" data-media-kind="image">
              <img
                class="node-image"
                src="data:image/png;base64,\(imageData.base64EncodedString())"
                alt=""
                draggable="false"
              >
            </span>
            """
        case .none:
            return ""
        }
    }

    // MARK: - Shape paths

    private static func shapePath(
        _ frame: CGRect,
        shape: NodeShape,
        isRoot: Bool
    ) -> String {
        let path: Path
        switch shape {
        case .roundedRect:
            path = RoundedRectangle(
                cornerRadius: isRoot ? 16 : 12,
                style: .continuous
            ).path(in: frame)
        case .capsule:
            path = Capsule(style: .continuous).path(in: frame)
        case .rectangle:
            path = RoundedRectangle(
                cornerRadius: 4,
                style: .continuous
            ).path(in: frame)
        case .diamond:
            var diamond = Path()
            diamond.move(to: CGPoint(x: frame.midX, y: frame.minY))
            diamond.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
            diamond.addLine(to: CGPoint(x: frame.midX, y: frame.maxY))
            diamond.addLine(to: CGPoint(x: frame.minX, y: frame.midY))
            diamond.closeSubpath()
            path = diamond
        }
        return pathData(path.cgPath)
    }

    private static func pathData(_ path: CGPath) -> String {
        var commands: [String] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let points = element.points
            switch element.type {
            case .moveToPoint:
                commands.append("M \(number(points[0].x)) \(number(points[0].y))")
            case .addLineToPoint:
                commands.append("L \(number(points[0].x)) \(number(points[0].y))")
            case .addQuadCurveToPoint:
                commands.append(
                    "Q \(number(points[0].x)) \(number(points[0].y)) "
                        + "\(number(points[1].x)) \(number(points[1].y))"
                )
            case .addCurveToPoint:
                commands.append(
                    "C \(number(points[0].x)) \(number(points[0].y)) "
                        + "\(number(points[1].x)) \(number(points[1].y)) "
                        + "\(number(points[2].x)) \(number(points[2].y))"
                )
            case .closeSubpath:
                commands.append("Z")
            @unknown default:
                break
            }
        }
        return commands.joined(separator: " ")
    }

    // MARK: - Text layout

    private struct HTMLTitleLayout {
        let lines: [String]
        let lineHeight: CGFloat
    }

    private static func layoutTitle(
        _ title: String,
        font: NSFont,
        width: CGFloat
    ) -> HTMLTitleLayout {
        let storage = NSTextStorage(
            attributedString: NSAttributedString(
                string: title,
                attributes: [.font: font]
            )
        )
        let manager = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        container.maximumNumberOfLines = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)

        let source = title as NSString
        let glyphRange = manager.glyphRange(for: container)
        var allLines: [String] = []
        manager.enumerateLineFragments(forGlyphRange: glyphRange) {
            _, _, _, lineGlyphRange, _ in
            let characterRange = manager.characterRange(
                forGlyphRange: lineGlyphRange,
                actualGlyphRange: nil
            )
            var line = source.substring(with: characterRange)
            while line.last == "\n" || line.last == "\r" {
                line.removeLast()
            }
            allLines.append(line)
        }
        if allLines.isEmpty {
            allLines = [title]
        }

        let wasTruncated = allLines.count > LayoutEngine.displayLineLimit
        var visible = Array(allLines.prefix(LayoutEngine.displayLineLimit))
        if wasTruncated, !visible.isEmpty {
            visible[visible.count - 1] = ellipsized(
                visible[visible.count - 1],
                font: font,
                width: width
            )
        }
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return HTMLTitleLayout(lines: visible, lineHeight: lineHeight)
    }

    private static func ellipsized(
        _ value: String,
        font: NSFont,
        width: CGFloat
    ) -> String {
        let ellipsis = "…"
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var result = value
        while !result.isEmpty {
            let candidate = result + ellipsis
            let measured = (candidate as NSString).size(withAttributes: attributes).width
            if measured <= width {
                return candidate
            }
            result.removeLast()
        }
        return ellipsis
    }

    // MARK: - Colors

    private static func nodeFill(
        _ node: LayoutNode,
        isRoot: Bool,
        theme: AppTheme,
        palette: HTMLPalette
    ) -> HTMLColor {
        if let color = HTMLColor(hex: theme.resolvedFillHex(style: node.style, isRoot: isRoot)) {
            return color
        }
        return isRoot
            ? palette.selection.withOpacity(0.12)
            : palette.controlBackground
    }

    private static func nodeText(
        _ node: LayoutNode,
        isRoot: Bool,
        theme: AppTheme,
        palette: HTMLPalette
    ) -> HTMLColor {
        let isPlaceholder = node.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        if isPlaceholder {
            return palette.secondary
        }
        if let custom = HTMLColor(hex: node.style.textHex) {
            return custom
        }
        if let fill = node.style.fillHex,
           let contrast = ColorContrast.contrastingTextHex(forFill: fill),
           let color = HTMLColor(hex: contrast)
        {
            return color
        }
        if let themed = HTMLColor(hex: theme.defaultText(isRoot: isRoot)) {
            return themed
        }
        if let fill = theme.defaultFill(isRoot: isRoot),
           let contrast = ColorContrast.contrastingTextHex(forFill: fill),
           let color = HTMLColor(hex: contrast)
        {
            return color
        }
        return palette.primary
    }

    private static func nodeBorder(
        _ node: LayoutNode,
        palette: HTMLPalette
    ) -> HTMLColor {
        if let custom = HTMLColor(hex: node.style.borderHex) {
            return custom
        }
        return palette.primary.withOpacity(palette.isDark ? 0.18 : 0.1)
    }

    private static func contrastText(for color: HTMLColor) -> HTMLColor {
        func linearized(_ component: Double) -> Double {
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        let luminance =
            0.2126 * linearized(color.red)
            + 0.7152 * linearized(color.green)
            + 0.0722 * linearized(color.blue)
        return luminance > 0.45
            ? HTMLColor(red: 0.05, green: 0.05, blue: 0.06)
            : HTMLColor(red: 1, green: 1, blue: 1)
    }

    private struct HTMLPalette {
        let isDark: Bool
        let canvas: HTMLColor
        let grid: HTMLColor
        let primary: HTMLColor
        let secondary: HTMLColor
        let controlBackground: HTMLColor
        let accent: HTMLColor
        let selection: HTMLColor

        init(theme: AppTheme, colorScheme: ColorScheme) {
            isDark = theme.resolvesAsDark(in: colorScheme)
            let semantic = SemanticColors(colorScheme: colorScheme)
            let themeAccent = HTMLColor(hex: theme.selection) ?? semantic.accent
            primary = semantic.primary
            secondary = HTMLColor(hex: theme.secondaryText) ?? semantic.secondary
            controlBackground = semantic.controlBackground
            accent = themeAccent
            selection = themeAccent
            canvas = HTMLColor(hex: theme.canvasBackground) ?? semantic.textBackground
            grid = HTMLColor(hex: theme.grid) ?? semantic.primary.withOpacity(0.06)
        }
    }

    private struct SemanticColors {
        let textBackground: HTMLColor
        let controlBackground: HTMLColor
        let primary: HTMLColor
        let secondary: HTMLColor
        let accent: HTMLColor

        init(colorScheme: ColorScheme) {
            let appearanceName: NSAppearance.Name =
                colorScheme == .dark ? .darkAqua : .aqua
            let appearance = NSAppearance(named: appearanceName)!
            var resolvedTextBackground = HTMLColor(red: 1, green: 1, blue: 1)
            var resolvedControlBackground = HTMLColor(red: 1, green: 1, blue: 1)
            var resolvedPrimary = HTMLColor(red: 0, green: 0, blue: 0)
            var resolvedSecondary = HTMLColor(red: 0.4, green: 0.4, blue: 0.4)
            var resolvedAccent = HTMLColor(red: 0, green: 0.48, blue: 1)
            appearance.performAsCurrentDrawingAppearance {
                resolvedTextBackground = HTMLColor(nsColor: .textBackgroundColor)
                resolvedControlBackground = HTMLColor(nsColor: .controlBackgroundColor)
                resolvedPrimary = HTMLColor(nsColor: .labelColor)
                resolvedSecondary = HTMLColor(nsColor: .secondaryLabelColor)
                resolvedAccent = HTMLColor(nsColor: .controlAccentColor)
            }
            textBackground = resolvedTextBackground
            controlBackground = resolvedControlBackground
            primary = resolvedPrimary
            secondary = resolvedSecondary
            accent = resolvedAccent
        }
    }

    private struct HTMLColor {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
            self.red = min(1, max(0, red))
            self.green = min(1, max(0, green))
            self.blue = min(1, max(0, blue))
            self.alpha = min(1, max(0, alpha))
        }

        init?(hex: String?) {
            guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else {
                return nil
            }
            if value.hasPrefix("#") {
                value.removeFirst()
            }
            guard value.count == 6 || value.count == 8,
                  let raw = UInt64(value, radix: 16)
            else {
                return nil
            }
            if value.count == 8 {
                alpha = Double((raw >> 24) & 0xFF) / 255
                red = Double((raw >> 16) & 0xFF) / 255
                green = Double((raw >> 8) & 0xFF) / 255
                blue = Double(raw & 0xFF) / 255
            } else {
                alpha = 1
                red = Double((raw >> 16) & 0xFF) / 255
                green = Double((raw >> 8) & 0xFF) / 255
                blue = Double(raw & 0xFF) / 255
            }
        }

        init(nsColor: NSColor) {
            let color = nsColor.usingColorSpace(.sRGB) ?? nsColor
            red = Double(color.redComponent)
            green = Double(color.greenComponent)
            blue = Double(color.blueComponent)
            alpha = Double(color.alphaComponent)
        }

        func withOpacity(_ opacity: Double) -> HTMLColor {
            HTMLColor(red: red, green: green, blue: blue, alpha: alpha * opacity)
        }

        var css: String {
            let r = Int((red * 255).rounded())
            let g = Int((green * 255).rounded())
            let b = Int((blue * 255).rounded())
            if alpha >= 0.9995 {
                return String(format: "#%02X%02X%02X", r, g, b)
            }
            return "rgba(\(r), \(g), \(b), \(number(CGFloat(alpha))))"
        }
    }

    // MARK: - Sticker rendering

    private static func stickerDataURL(
        symbolName: String,
        frame: CGFloat,
        palette: HTMLPalette
    ) -> String? {
        guard let symbol = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        ) else {
            return nil
        }
        let pointSize = max(1, frame - 6)
        let accent = NSColor(
            srgbRed: palette.accent.red,
            green: palette.accent.green,
            blue: palette.accent.blue,
            alpha: palette.accent.alpha
        )
        let sizeConfiguration = NSImage.SymbolConfiguration(
            pointSize: pointSize,
            weight: .semibold
        )
        let colorConfiguration = NSImage.SymbolConfiguration(
            hierarchicalColor: accent
        )
        guard let configured = symbol.withSymbolConfiguration(
            sizeConfiguration.applying(colorConfiguration)
        ) else {
            return nil
        }

        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((frame * scale).rounded()),
            pixelsHigh: Int((frame * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        bitmap.size = NSSize(width: frame, height: frame)
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let intrinsic = configured.size
        let fittingScale = min(
            1,
            min(frame / max(1, intrinsic.width), frame / max(1, intrinsic.height))
        )
        let drawSize = NSSize(
            width: intrinsic.width * fittingScale,
            height: intrinsic.height * fittingScale
        )
        let drawRect = NSRect(
            x: (frame - drawSize.width) / 2,
            y: (frame - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        configured.draw(
            in: drawRect,
            from: NSRect.zero,
            operation: NSCompositingOperation.sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [:]
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return "data:image/png;base64,\(png.base64EncodedString())"
    }

    // MARK: - String helpers

    private static func displayedTitle(_ value: String, isRoot: Bool) -> String {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return isRoot ? BrainstormNode.mainPlaceholder : BrainstormNode.nodePlaceholder
        }
        return value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
    }

    private static func normalizeTitle(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private nonisolated static func number(_ value: CGFloat) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func indent(_ value: String, spaces: Int) -> String {
        guard !value.isEmpty else { return "" }
        let prefix = String(repeating: " ", count: spaces)
        return value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n")
    }
}

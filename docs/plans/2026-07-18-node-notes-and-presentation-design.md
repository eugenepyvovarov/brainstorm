# Node Notes and Presentation Mode Design

## Goal and Chosen Product Contract

Brainstorm will add a second, optional information layer to every node without changing the
node title or replacing the existing emoji, sticker, and thumbnail decoration. A note can contain
formatted text, ordered and unordered lists, embedded images, and YouTube references. Notes remain
portable inside the `.bs` file, participate in undo, autosave, recovery, CLI automation, and every
requested viewing/export surface, and can be shown or hidden independently.

Each note stores a saved visibility value. The app and HTML viewer also provide a global Notes
layer control, while individual note controls update the saved value. Static exports cannot be
interactive, so PNG and PDF default to rendering notes whose saved visibility is shown; the app
and CLI can override that with **Visible**, **All**, or **None**. Markdown uses `<details>` with
the saved visibility mapped to its initial open state, so compatible readers retain a real
show/hide interaction. Hidden content is not private: excluding notes from an export is the only
way to omit their bytes.

Presentation order is deterministic depth-first preorder: root, then every child subtree in
sibling order, including descendants below collapsed branches. One node is fully presented at a
time. The previous and next nodes remain partially visible as clickable edge previews—left/right
in a wide window and top/bottom in a tall or narrow window. Presentation starts at the root, uses
the complete document, and never mutates node expansion, selection, or note visibility.

## Alternatives Considered

Three note-storage approaches were considered. Raw HTML or archived `NSAttributedString` would
make native editing easy, but it would be unsafe to embed in HTML, hard to review in `.bs` JSON,
fragile across OS versions, and difficult to convert reliably into Markdown. A fully normalized
tree of paragraphs, list items, and inline style runs would be the strictest representation, but
it would substantially complicate selection-aware editing and CLI authoring for the deliberately
small formatting feature.

The chosen approach is a safe Markdown subset for the textual body plus typed attachments.
The allowed body syntax is paragraphs, line breaks, `**bold**`, `_italic_`, unordered lists, and
ordered lists. Raw HTML is always escaped and unsupported Markdown constructs remain literal
text. A shared parser produces an allow-listed render tree for SwiftUI, HTML, and validation so
the formats cannot silently disagree. The note editor presents familiar Bold, Italic, Bullets,
and Numbering controls; users do not need to remember the syntax.

Images and YouTube references remain typed rather than being inserted as arbitrary Markdown.
Typed media lets Brainstorm validate, normalize, render, and export it consistently. Attachments
have stable IDs and a user-visible order. Text appears first, followed by the ordered media
collection; captions and accessible image descriptions are supported. This covers the requested
note composition without introducing a general-purpose document editor.

## Document Model, Migration, and Validation

`BrainstormNode` gains an optional sparse `note`. `NodeNote` contains `visibility`,
`bodyMarkdown`, and `[NodeNoteAttachment]`. Attachments use an explicit tagged JSON object:
`image` carries normalized PNG bytes, pixel dimensions, alternative text, and an optional
caption; `youtube` carries only a validated eleven-character video ID, optional bounded start
time, and optional caption. Brainstorm never stores iframe markup or arbitrary remote HTML.

The document version advances from 2 to 3. Brainstorm continues to decode v1 and v2 maps with
empty notes, and every subsequent save writes canonical v3. This is intentionally a version bump:
an older v2 app must reject a note-bearing document rather than open it, ignore unknown note
fields, and erase them on save. Empty notes and default values remain omitted from the JSON.

Image import decodes through ImageIO/AppKit, rejects unsupported or malformed data, strips
metadata by rerendering, constrains the long edge and total pixels, and enforces per-image and
per-document byte budgets before base64 encoding. YouTube input accepts common `youtube.com`,
`youtu.be`, Shorts, and embed URLs but stores only the normalized ID and start time. Validation
also caps note text length and attachment count and reports the exact node/field involved.

Store snapshots, save/load, autosave, recovery, external-file reload, and undo/redo carry the
complete v3 data. Live note typing is coalesced and committed as one logical undo action rather
than copying the entire tree on every keystroke.

## App Notes Experience

The existing inspector becomes a small mode-based composition rather than a larger monolithic
body. Its header offers **Style** and **Notes** modes for a single selected node. Notes mode is a
dedicated `NodeNoteEditorView` with an Edit/Preview switch, selection-aware formatting controls,
image and YouTube attachment actions, attachment removal/reordering, alternative-text and caption
fields, and a **Show on map and static exports** toggle. Multi-selection keeps notes read-only and
explains that a single node is required.

`NodeNoteTextEditor` wraps `NSTextView` so selection, Bold/Italic wrapping, list prefixes, native
copy/paste, text undo, Tab, Return, arrows, and Delete stay inside the editor instead of triggering
canvas commands. Focus remains local to the editor view. A shared `NodeNoteContentView` renders the
allow-listed note tree and media in canvas previews, presentation, and static visual exports.

Nodes with notes show a small persistent note indicator outside the title card. Activating it
selects the node, switches the inspector to Notes, and reveals that note. A toolbar/menu Notes
layer control hides or shows all eligible note cards without changing the document; each note’s
saved visibility still controls whether it participates when the layer is on. Visible note cards
sit beneath their nodes and are included in layout measurement, so they cannot overlap sibling
nodes or branch paths. Hiding the layer restores the compact existing map.

Following the SwiftUI structure guidance, note editing, preview, attachment rows, media playback,
and presentation are separate views with narrow inputs. Shared mutation and validation live in
models/services, not a new optional view model.

## Native Presentation Experience

Presentation replaces the editor workspace inside the active document window and then asks that
same `NSWindow` to enter native full screen. Reusing the window preserves the selected tab’s
`BrainstormStore`, theme, autosave identity, and command routing. Full-screen notifications drive
entry/exit completion, so the UI does not assume the asynchronous AppKit transition has finished.
Escape or the system full-screen command exits presentation cleanly.

A pure `PresentationSequence` snapshots every node in preorder after pending title/note edits are
committed. `PresentationView` owns only transient current-index and direction state. The centered
card renders the themed node, full note text, images, and a lazy YouTube player. Only the current
slide is exposed as primary accessibility content; previous/next edge previews are real labeled
buttons and decorative duplicates are hidden from VoiceOver.

Right, Down, Space, and Page Down advance. Left, Up, and Page Up go back. Home/End jump to the
boundaries, clicking an edge preview navigates, and Escape exits. Progress is announced as
“7 of 24,” with the current title treated as a heading. Directional spring transitions combine
translation, opacity, and a small scale change. Reduce Motion switches to a crossfade or immediate
update.

On macOS 26, grouped interactive controls use one `GlassEffectContainer` with native glass button
styles and consistent capsule/rounded shapes. The modifier is applied after layout, and only
interactive controls receive interactive glass. Earlier macOS uses material-backed controls;
Reduce Transparency receives an opaque high-contrast fallback. The main node and note card retain
the document theme rather than glass so content stays readable.

## Export and HTML Presentation

`BrainstormExportOptions` separates note inclusion from file format. Visual export builds one
snapshot containing the existing visible map layout plus the complete preorder tree. PNG and PDF
reuse the SwiftUI note renderer and layout-integrated note frames; YouTube is represented by a
clear static video card with caption and canonical short URL. The existing one-page PDF contract
remains, subject to its current maximum canvas scaling.

Markdown preserves the existing root heading and complete nested tree. A node note is emitted
under its bullet as a nested `<details>` section, initially open or closed from saved visibility.
The safe body Markdown is retained, images use embedded data URLs to preserve single-file/stdout
behavior, and YouTube becomes a canonical link with caption and start time. `--notes
visible|all|none` applies to PNG, PDF, Markdown, and HTML; default is `visible`.

The self-contained HTML viewer receives both the map snapshot and complete preorder presentation
data. Map mode adds note indicators, per-note toggles, and a global Notes control. A **Present**
action switches to a dedicated presentation DOM rather than zooming the map, because collapsed
descendants do not have map frames. It uses the same adaptive edge previews, keyboard controls,
progress, reduced-motion handling, and initial visibility rules as the app. URL hashes identify
the current node for refresh/deep linking.

All HTML text and attributes are escaped. A content-security policy blocks objects, forms, and
unexpected connections. YouTube uses a click-to-load `youtube-nocookie.com` iframe; until the user
plays it, the export remains offline and makes no request. The UI states that playback requires
network access. PNG, PDF, and Markdown never fetch remote thumbnails during export.

## CLI, Error Handling, and Verification

CLI `inspect` exposes note metadata while redacting embedded image bytes by default; an explicit
flag includes them. `update` supports body/file input, visibility, adding/removing image and
YouTube attachments, and clearing a note. Atomic `apply` gains strict note operations with
explicit clear semantics and rejects unknown fields. Mutations upgrade old documents to v3 before
saving. Validation errors include a stable code, JSON-style path, and readable message.

Automated coverage includes v1/v2 migration, sparse v3 round trips, future-version rejection,
image and YouTube validation, strict CLI set/clear behavior, undo/autosave/recovery, Markdown
formatting, visual note measurement, visibility overrides, and complete preorder traversal
including collapsed nodes. HTML tests execute the generated viewer in `WKWebView` to verify note
toggles, map/presentation switching, boundaries, keyboard navigation, hostile input escaping,
and lazy network behavior. macOS UI tests cover note editing focus, save/reopen, presentation
entry/exit, shortcuts, edge previews, accessibility identifiers, and reduced-motion-safe state.

Completion also requires package tests, macOS build/tests, a generated `.bs` fixture, inspected
PNG/PDF/Markdown/HTML samples, and an app presentation run. README, `brainstorm-skill/SKILL.md`,
the synced Brainstorm Joplin project note, and the live Brainstorm WordPress page are updated
together. The public page is round-tripped in full and verified after publishing.

# Node Notes and Presentation Mode Design

## Goal and Chosen Product Contract

Brainstorm will add a second, optional information layer to every node without changing the
node title or replacing the existing emoji, sticker, and thumbnail decoration. A note can contain
formatted text, ordered and unordered lists, embedded images, and YouTube references. Notes remain
portable inside the `.bs` file and participate in undo, autosave, recovery, CLI automation, and
the note-capable viewing/export surfaces.

Each note retains a saved visibility value for file/CLI and static-export compatibility, but the
native app no longer exposes a per-note show/hide switch. When the global Notes layer is enabled,
every non-empty note receives a compact presence marker. PNG and PDF always remain clean,
note-free map exports. HTML and Markdown expose **Visible**, **All**, or **None**; Markdown uses
that policy to decide which node bullets link to separate note documents. Hidden content is not
private: excluding notes from a note-capable export is the only way to omit their bytes.

Presentation starts from deterministic depth-first node preorder: root, then every child subtree
in sibling order, including descendants below collapsed branches. Each included non-empty note
adds its own step immediately after its node, and reverse navigation retraces the exact combined
sequence. Progress counts both node and note steps. The previous and next nodes remain partially
visible at their actual fully expanded map positions. A spatial camera follows that geometry only
when navigation changes nodes; cross-branch steps climb through the lowest common ancestor before
descending the next branch. Moving from a node step to its note step instead performs an in-place
3D flip at the same camera position. Solid curved connection lines without arrowheads preserve the
map structure. Presentation renders the actual expanded map instead of converting nodes into
generic slide cards. Each active node retains its natural aspect and shape; a note, when present,
lives on its bounded rounded-square back face rather than in a modal or overlay. Presentation
starts at the root, uses the complete document, and never mutates node expansion, selection, or
note visibility.

## Alternatives Considered

Three note-storage approaches were considered. Raw HTML or archived `NSAttributedString` would
make native editing easy, but it would be unsafe to embed in HTML, hard to review in `.bs` JSON,
fragile across OS versions, and difficult to convert reliably into Markdown. A fully normalized
tree of paragraphs, list items, and inline style runs would be the strictest representation, but
it would substantially complicate selection-aware editing and CLI authoring for the deliberately
small formatting feature.

The chosen approach is a safe Markdown subset for the textual body plus typed attachments.
The allowed body syntax is paragraphs, line breaks, `**bold**`, `_italic_`, unordered lists,
ordered lists, and validated HTTP(S) links. Raw HTML, unsafe schemes, and unsupported Markdown constructs remain literal
text. A shared parser produces an allow-listed render tree for SwiftUI, HTML, and validation so
the formats cannot silently disagree. The note editor presents familiar Bold, Italic, Bullets,
and Numbering controls over a live styled Markdown surface; inactive syntax markers are hidden,
and there is no separate raw-source panel.

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

The style inspector stays style-only. The map reserves no permanent space for note-edit controls.
The default-off Notes layer reveals a subtle transient **+ Note** pill when a node is hovered or
selected; after content exists the pill reads **Note**, and a compact presence marker is visible.
The context menu and ⌥⌘N remain available when that visual layer is off. Activating any route
commits any title edit, selects that node, dims and interaction-locks the map, and animates a copy
of the themed node into a centered foreground composition. The rich note area expands directly
below that node. **Done**, Escape, or ⌥⌘N commits the coalesced note session and returns the node to
the map. Normal Tab-child and Return-sibling behavior is unchanged whenever note focus is closed.

The visible editor is an Apple-native AppKit/TextKit attributed surface whose storage contains only
rendered content. This is a strict WYSIWYG boundary: Markdown delimiters and image source tokens
never enter visible text storage. Brainstorm exposes only Bold, Italic, Bullets, and Numbering
commands. Content is canonicalized back to the existing subset—paragraphs, line breaks, bold,
italic, flat ordered/unordered lists, and validated HTTP(S) links—so headings, code, tables, tasks,
wiki links, LaTeX, nested-list structure, and other unsupported constructs remain literal rather
than expanding the `.bs` format. A pasted or typed
YouTube URL/link remains clickable in the editor and also becomes a typed video block; another
HTTP(S) URL remains a clickable link. Pasted/dropped images become typed image blocks without
dedicated Image or YouTube add forms and render as source-free inline text attachments at the
insertion point in the transient editing document. Both raw
image drops and one-or-many Finder file-URL drops are accepted, preserving pasteboard order.
Image embed tokens are an editor implementation
detail outside visible storage and do not expand the persisted Markdown subset. The
composer shows no attachment shelf, does not host a YouTube player, and does not expose media
descriptions, ordering, alternative-text fields, or any other attachment-configuration panel;
those typed fields remain available to the file format and CLI.

A canvas Notes control defaults off and hides or shows the transient note action plus a very small,
low-emphasis, non-interactive SF Symbol
`note.text` inside the top-right corner of every node with a non-empty note, without changing the
document. The symbol is tinted from the active Brainstorm theme and has no circle or button chrome.
It communicates presence only; editing remains available through the transient note action,
context menu, and shortcut. Full note previews are never placed beneath nodes, so the map layout
stays compact and readable. Legacy saved visibility remains available to CLI/static exports but
does not suppress the native presence marker.

Following the SwiftUI structure guidance, note editing, inline attachments, media playback,
and presentation are separate views with narrow inputs. Shared mutation and validation live in
models/services, not a new optional view model.

## Native Presentation Experience

Presentation replaces the editor workspace inside the active document window and then asks that
same `NSWindow` to enter native full screen. Reusing the window preserves the selected tab’s
`BrainstormStore`, theme, autosave identity, and command routing. Full-screen notifications drive
entry/exit completion, so the UI does not assume the asynchronous AppKit transition has finished.
Escape or the system full-screen command exits presentation cleanly.

A pure `PresentationSequence` snapshots every node in preorder after pending title/note edits are
committed, then expands each node into a node step followed by a note step when a non-empty note is
included. Reversing traverses those exact steps—returning from the next node to the prior note
before the prior title—and the progress denominator includes both. The
sequence receives a non-mutating, fully expanded `LayoutEngine` snapshot, so every node keeps its
real frame and center even below a saved-collapsed branch. Each item retains its ancestor path so
adjacent node steps can be classified as parent, child, sibling, or cross-branch through a lowest
common ancestor, and exposes the complete spatial route through that ancestor.

`PresentationView` owns only transient current-step and camera state. It renders the expanded
`LayoutResult` as a real map world and uniformly scales/translates that world so the current node
is maximally readable while keeping its natural frame, shape, style, and media. Surrounding nodes
remain clipped at the viewport and directly navigable. A node step with an upcoming note carries
the compact, readable, non-interactive folded-note glyph inside the node’s top-right corner.
Native and HTML share its translucent active-theme paper, folded edge, and two quiet text strokes.
Its scale is bounded relative to current camera magnification, so it remains visible without
becoming dominant. It has no circle, button chrome, or interactive glass treatment and is not a
**Show note** button. This keeps the presentation toolbar structurally identical on every step. Its
note step flips the same node in place to a bounded rounded-square back face with full formatted
text, links, inline images, descriptions, and a real inline privacy-enhanced YouTube player.
Attachments stay within this one note step and never become additional flip layers. It is never
presented in a modal, AJAX window, or floating overlay. A node without a note never creates that
surface or adds an extra step. Leaving a note step tears down inactive players.

Native WebKit hosts the privacy-enhanced iframe in a small local document whose base URL is the
Brainstorm project’s stable HTTPS page. Its strict-origin referrer policy, `origin`, and
`widget_referrer` parameters give YouTube the required client identity without sending document
content. HTML instantiates the embedded player only from an HTTP(S) origin;
direct `file://` viewing retains the normal YouTube fallback link because a static local document
cannot provide a compliant web origin.

The map's responsive connector rails remain behind the nodes. They are solid curved lines without
arrowheads and use actual expanded-map geometry rather than a viewport-fixed carousel. Reduce
Motion shortens native camera movement and its turn; HTML replaces perspective with a quick
crossfade while preserving the same title/note ordering.

Right, Down, Space, and Page Down advance one step. Left, Up, and Page Up go back one step.
Home/End jump to the first/last combined step, clicking a nearby node selects its node step, and
Escape exits. Progress is announced as “7 of 24,” with both node and note steps counted and the
current title treated as a heading. A node-to-note or note-to-node transition is an in-place 3D
flip at normal motion; spatial camera travel runs only between steps owned by different nodes.
Reduce Motion keeps a short restrained native turn; HTML uses an immediate crossfade without
perspective.

In exported HTML map mode, note-presence icons are always visible for every note included by the
chosen export policy; the viewer has no separate marker switch. Activating a noted map node by
click, tap, Return, or Space flips that map node itself to a screen-bounded note back. Back or
Escape restores its title without a modal or mode change. Dragging from the same node still pans
and does not accidentally open the note.

On macOS 26, grouped interactive controls use one `GlassEffectContainer` with native glass button
styles and consistent capsule/rounded shapes. The modifier is applied after layout, and only
interactive controls receive interactive glass. Earlier macOS uses material-backed controls;
Reduce Transparency receives an opaque high-contrast fallback. The main node and note card retain
the document theme rather than glass so content stays readable.

## Export and HTML Presentation

`BrainstormExportOptions` separates note inclusion from file format. Visual export builds one
snapshot containing the existing visible map layout plus the complete preorder tree. PNG and PDF
always reuse the clean note-free map renderer; neither note markers nor note payloads are drawn.
The existing one-page PDF contract remains, subject to its current maximum canvas scaling.

Markdown preserves the existing root heading and complete nested tree. When no note is included,
the result remains one `.md` file. When notes are included, each corresponding node bullet links
to a separate `notes/*.md` document and the complete result is a ZIP containing `map.md`, the note
documents, and extracted `assets/*.png` files. The safe body Markdown is retained and YouTube
becomes a canonical link with caption and start time. `--notes visible|all|none` applies to
Markdown and HTML; default is `visible`. Note flags cannot add content to PNG or PDF.

The self-contained HTML viewer receives both the map snapshot and complete presentation-step data.
Map mode always shows compact note-presence markers for notes included by the export policy, with
no marker switch and never inline note previews or media. Each marker is a very small,
low-emphasis, non-interactive Tabler note outline inside the
node’s top-right corner, tinted from the active Brainstorm theme with no circle or button chrome.
The export bundles that outline inline rather than loading an icon dependency. A **Present** action
switches to a dedicated presentation DOM backed by a second, non-mutating fully expanded layout
snapshot. Slides serialize safe numeric frames and LCA route points, giving the scene the movement
of a camera traveling over the real map even when saved branches are collapsed.

The HTML sequence inserts each included non-empty note immediately after its node, includes both in
progress, and reverses exactly. Its toolbar never conditionally inserts a **Show note** control, so
the bar remains stable across steps. Node-to-note navigation flips the same DOM element in place
with the full 3D CSS transition during normal motion; Reduce Motion replaces perspective with a
quick crossfade. The note is its real back face, not a modal/AJAX overlay.
Spatial camera travel is reserved for different-node transitions. It renders the same expanded-map
world, natural node fronts, bounded note backs, keyboard controls, progress, and reduced-motion
handling as the app. The settled HTML camera uses a device-pixel-aligned 2D transform, removes
permanent `will-change`, and applies drop-shadow compositing to the vector shape rather than the
whole slide; this prevents Safari from rasterizing node text before presentation magnification.
Its resting scale shares the native readable-focus floor: a remote DFS predecessor or successor
cannot shrink a shallow focused node into an overview merely to remain on screen. Nearby real-map
neighbors may still peek at their true bearings, while long-distance navigation exposes the wider
map during the travel animation and settles back to the same bounded focus at every tree depth.
Perspective is present only on the active flip. The note back retains an exact fixed screen size
through inverse camera scaling and scrolls overflow within that surface. URL hashes identify the
current node for refresh/deep linking.

HTML presentation also places a translucent theme-colored Previous or Next chevron at each
available horizontal safe-area edge. Compact screens use a 52-point touch target. Each control
invokes the same step navigator as keyboard and swipe input, including node-to-note flips, and is
removed from layout and focus order when its direction reaches the sequence boundary.
Every visible presentation node remains pointer-addressable, including non-adjacent context nodes;
activating one jumps to its normal title step and continues the unchanged global sequence. Branch
returns use a continuous quadratic camera path biased toward the lowest common ancestor, avoiding
brief landings on intermediate parents. The title-face note marker derives a bounded size and inset
from the node's focused presentation height so it remains proportionate without touching rounded
corners across zoom levels.

All HTML text and attributes are escaped. A content-security policy blocks objects, forms, and
unexpected connections. Map-view YouTube blocks remain click-to-load. Presentation creates a
non-autoplay `youtube-nocookie.com` iframe automatically only for the active note step and
destroys it when navigation leaves that step or presentation closes, preventing
off-screen audio. The UI states that playback requires network access and that privacy-enhanced
mode still contacts YouTube. PNG, PDF, and Markdown never fetch remote thumbnails during export.

## CLI, Error Handling, and Verification

CLI `inspect` exposes the complete typed note object, including embedded image bytes, so its output
should not be logged or shared carelessly. `update` supports body/file input, visibility,
adding/removing image and YouTube attachments, and clearing a note. Atomic `apply` gains strict
note operations with explicit clear semantics and rejects unknown fields. Mutations upgrade old
documents to v3 before saving. Validation errors include a stable code, JSON-style path, and
readable message.

Automated coverage includes v1/v2 migration, sparse v3 round trips, future-version rejection,
image and YouTube validation, strict CLI set/clear behavior, undo/autosave/recovery, Markdown
formatting, visual note measurement, visibility overrides, and complete preorder traversal
including collapsed nodes. HTML tests execute the generated viewer in `WKWebView` to verify note
toggles, map/presentation switching, boundaries, keyboard navigation, hostile input escaping,
and lazy network behavior. macOS UI tests cover note editing focus, save/reopen, presentation
entry/exit, shortcuts, edge previews, accessibility identifiers, and reduced-motion-safe state.

Completion also requires package tests, macOS build/tests, a generated `.bs` fixture, inspected
PNG/PDF/Markdown/HTML samples, and an app presentation run. README, `brainstorm-skill/SKILL.md`,
and the synced Brainstorm Joplin project note are updated together. The live WordPress project
page is updated only for a release or an explicit publication request; when published, its full
body is round-tripped and the public result is verified.

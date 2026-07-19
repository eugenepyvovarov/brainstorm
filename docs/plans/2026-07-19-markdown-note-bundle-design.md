# Markdown note bundle export

## Goal

Markdown export should remain a readable outline of the complete mind map while
giving every included node note its own portable Markdown document. The outline
links to those note documents instead of expanding note bodies inline.

## Output contract

- With no included non-empty notes, Markdown export remains one UTF-8 `.md`
  file.
- With one or more included notes, export produces a `.zip` archive because the
  result contains more than one Markdown file.
- The archive contains:
  - `map.md` — the complete root-first nested list.
  - `notes/<safe-node-title>--<node-uuid>.md` — one file per included node note.
  - `assets/<safe-node-title>--<node-uuid>--<attachment-uuid>.png` — normalized
    PNG data for note image attachments.
- A node with an included note appends a relative `[Note](...)` Markdown link
  to its note file. A node without an included note remains plain list text.
- `visible`, `all`, and `none` retain their existing inclusion meaning. Excluded
  note text, attachment metadata, image bytes, and video IDs must not appear in
  the result.
- Note files contain the node title as an `#` heading, the sanitized portable
  Markdown body, image references and captions, and canonical YouTube links.

Entry names are ASCII-only, deterministic, collision-safe, and traversal-safe.
UUIDs preserve identity when titles repeat or contain characters unsuitable for
filenames. ZIP output uses a deterministic stored-entry writer so identical
documents produce identical archives without shelling out to system utilities.

## App and CLI behavior

The macOS save panel derives its extension and content type from the current
note-inclusion choice. It proposes `.zip` whenever at least one note file will
be emitted and `.md` otherwise.

The CLI uses the same descriptor. A bundled Markdown export requires a `.zip`
destination (or `--output -` for raw ZIP bytes); a single-file export requires
`.md`. This prevents ZIP bytes from being silently written under a Markdown
filename.

Other formats and the `.bs` source model are unchanged.

## Verification

Tests cover hierarchy and links, visibility filtering, per-note contents,
extracted image assets, YouTube links, hostile/duplicate titles, deterministic
ZIP bytes, descriptor selection, and exclusion of private note payloads.
Integration verification extracts a real CLI-produced archive and checks its
files and relative links.

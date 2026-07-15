# Brainstorm Text Export Design

## Goal

Add complete-tree export from Brainstorm to Markdown nested lists, Mermaid mindmap syntax, and
PlantUML mindmap syntax. The formats are available from both the macOS Export menu and the
`brainstorm export` CLI command.

## Format Contract

All three exporters traverse every node in document order, including descendants of collapsed
nodes. They preserve node titles and hierarchy, but intentionally omit styling, media, collapsed
state, and manual canvas positions because those properties do not have portable equivalents.

Markdown output starts with a level-one heading containing the root title, then repeats the root as
the first bullet and writes descendants as four-space-indented bullets. Mermaid output uses stable
preorder-local identifiers with quoted labels beneath a `mindmap` declaration. PlantUML output uses
the native repeated-asterisk mindmap notation inside `@startmindmap` and `@endmindmap`.

## Architecture and Safety

`BrainstormExporter` remains the single app/CLI export boundary. Raster formats continue through
the production canvas renderer; text formats use a separate deterministic tree serializer and UTF-8
encoding. Format-specific escaping prevents punctuation, quotes, markup characters, and multiline
titles from changing the exported hierarchy or breaking diagram syntax.

The CLI accepts a file path or `-` for `--output` across every format. A dash writes the raw export
bytes to standard output and suppresses the usual JSON success response, keeping both text pipelines
and redirected PNG/PDF data valid.

Unit tests cover the exact output, collapsed descendants, ordering, multiline titles, and reserved
characters. CLI help, the README, agent skill, in-app help, and the public project page document the
new formats.

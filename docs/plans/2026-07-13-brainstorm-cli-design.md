# Brainstorm Agent CLI Design

## Goal

Provide a deterministic, non-interactive command-line interface for AI agents to create, inspect,
edit, save, validate, and export Brainstorm `.bs` mind maps without launching or automating the GUI.

## Architecture

The Swift package exposes an executable product named `brainstorm`. It imports `BrainstormFeature` and
reuses the production `BrainstormFile`, `BrainstormCodec`, themes, layout engine, and PNG/PDF exporter.
Tree mutations live in the reusable `BrainstormDocumentEditor`, which has no session or window state.
Each invocation reads the current file from disk, validates it, performs mutations in memory, then
writes once using the codec's atomic save. Batch operations therefore either all succeed or do not
change the file.

The repository-level `./brainstorm` launcher makes the executable directly usable by local agents.
No external Swift package dependencies are required.

## Command and Data Contract

Commands are `create`, `inspect`, `add`, `update`, `style`, `move`, `delete`, `validate`, `export`,
and `apply`. All successful commands write a JSON object to stdout with `ok`, `command`, `file`, and
command-specific results. Failures write structured JSON to stderr and return a nonzero exit code.
Node UUIDs are the stable addressing mechanism; the alias `root` addresses the main node.

`apply` accepts a JSON operations array from a file or stdin. Agents may assign UUIDs to new nodes
so later operations in the same request can reference them. `--dry-run` validates and returns the
resulting document without saving.

## External Changes and Safety

The GUI compares the current file bytes with its last observed disk revision. Atomic CLI file
replacements are therefore detected even when the inode changes. A clean document reloads
automatically. If the GUI contains unsaved edits, Brainstorm asks whether to reload or keep the local
changes. Opening a path that is already open activates its existing tab.

Validation rejects unsupported versions, duplicate node UUIDs, invalid colors, malformed embedded
images, cycles, invalid indexes, and unsafe root operations. PNG and PDF export use the same renderer
as the app so CLI output matches GUI export.

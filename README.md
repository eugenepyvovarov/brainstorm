# Brainstorm

**Brainstorm** is a native macOS mind-map editor for turning rough ideas into clear, editable plans. It pairs a fast keyboard-first canvas with rich node styling, native document tabs, portable `.bs` files, and a JSON-first CLI for scripts and AI agents.

## Install

Install the latest macOS release with Homebrew:

```sh
brew install --cask eugenepyvovarov/cask/brainstorm

# This works immediately after the cask installation.
brainstorm help
```

## Install the agent instructions

The repository includes Brainstorm agent instructions for automating `.bs` mind maps.

For Codex, Claude Code, and OpenCode, install them from GitHub:

```sh
npx skills add eugenepyvovarov/brainstorm
```

Use `--global` for a user-wide install, or add `--agent codex`, `--agent claude-code`, or `--agent opencode` to target a specific agent. Start a new agent session after installation.

For Grok Build, install the same `SKILL.md` into its global skills directory:

```sh
mkdir -p ~/.grok/skills/brainstorm
curl -fsSL https://raw.githubusercontent.com/eugenepyvovarov/brainstorm/main/brainstorm-skill/SKILL.md \
  -o ~/.grok/skills/brainstorm/SKILL.md
```

Start a new Grok Build session after installation.

![Brainstorm showing a mind map, native tabs, theme controls, icon picker, and style inspector](https://selfhosted.ninja/wp-content/uploads/2026/07/brainstorm-main-screenshot.jpeg)

## Highlights

- Build and explore ideas visually with folding, focus mode, zoom, and a horizontal tree layout.
- Work at keyboard speed: Tab creates a child, Return creates a sibling, and shortcuts cover editing, rearranging, saving, and undo.
- Style one or many nodes with themes, colors, borders, shapes, typography, emoji, and embedded images.
- Use the app and `brainstorm` CLI on the same portable JSON `.bs` files; the app handles safe external-file changes.
- Export the complete map to high-resolution PNG or single-page PDF.

## In action

<p>
  <img src="https://selfhosted.ninja/wp-content/uploads/2026/07/node-creation-dracula.gif" alt="Creating child and sibling nodes" width="48%">
  <img src="https://selfhosted.ninja/wp-content/uploads/2026/07/reorder-dracula.gif" alt="Reordering sibling nodes" width="48%">
</p>
<p>
  <img src="https://selfhosted.ninja/wp-content/uploads/2026/07/style-dracula.gif" alt="Applying styles to nodes" width="48%">
  <img src="https://selfhosted.ninja/wp-content/uploads/2026/07/icons-dracula.gif" alt="Adding emoji and media" width="48%">
</p>
<p>
  <img src="https://selfhosted.ninja/wp-content/uploads/2026/07/themes-dracula.gif" alt="Switching app themes" width="48%">
</p>

## CLI

```sh
brainstorm create plan.bs --title "Product launch"
brainstorm add plan.bs --parent root --title "Research"
brainstorm inspect plan.bs --flat --pretty
brainstorm export plan.bs --format pdf --output plan.pdf
```

Homebrew links the release CLI at `$(brew --prefix)/bin/brainstorm` (`/opt/homebrew/bin/brainstorm` on Apple Silicon and `/usr/local/bin/brainstorm` on Intel Macs). See [`brainstorm-skill/SKILL.md`](brainstorm-skill/SKILL.md) for installation checks, recovery steps, and agent-oriented usage.

For source development, the repository-local `./brainstorm` wrapper builds and runs the CLI with Swift. Open `Brainstorm.xcworkspace` in Xcode to build the macOS app.

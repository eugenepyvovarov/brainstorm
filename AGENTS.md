# Brainstorm project instructions

## Product identity

- The product is **Brainstorm**. Use `Brainstorm` for project targets, Swift modules, source folders, artifacts, documentation, and release titles.
- The supported document type is `.bs` only. Do not restore or advertise `.mindmap` compatibility.
- Keep the command-line executable lowercase as `brainstorm`.

## Release versioning

- A release version is always `<major>.<minor>.<build>`. The initial release line is `1.0`; `1.0.12` is only an example of a Gitea job whose build number is `12`, never a hardcoded release number.
- `BRAINSTORM_MAJOR_VERSION` and `BRAINSTORM_MINOR_VERSION` in `Config/Shared.xcconfig` are the source of truth for the manually chosen release line. Change either only for a deliberate new release line.
- The release workflow must read the Gitea job's positive integer build number and pass it as `CURRENT_PROJECT_VERSION`. It then becomes both the build number and the final version component.
- Every released artifact must use the same resolved version: `CFBundleShortVersionString`, `CFBundleVersion`, archive filename, checksum, Git tag, Gitea Release, GitHub Release, and Homebrew Cask.
- Resolve the Gitea job build number at build time; do not commit a CI build number back into source control. `CURRENT_PROJECT_VERSION = 1` is only a local-development fallback and must be overridden by every release job.

## Feature documentation sync

When adding or changing any user-facing functionality, update all three documentation surfaces in the same change before considering the work complete:

1. `README.md` — explain the behavior, user workflow, CLI command, file format, or installation change.
2. `brainstorm-skill/SKILL.md` — update agent-facing commands, automation behavior, validation rules, and recovery guidance.
3. The live Brainstorm project page at `https://selfhosted.ninja/projects/brainstorm/` — update the relevant feature copy, FAQ, screenshots, or GIFs through the WordPress Manager skill.

Round-trip the full WordPress page body when publishing an update, and verify the public page after syncing it. Keep the README and skill instructions accurate for the released behavior, not only for local development.

## Joplin project notes

- Remote notebook: `Y26/P/Brainstorm` (`bc23eb39a5514fe59b4c27609ede99b9`).
- Local recursive sync directory: `joplin-notes/brainstorm`.
- Run `jnm sync pull` before relying on project notes.
- After editing synced notes, run `jnm sync status` and `jnm sync push`; never force a conflict without explicit approval.

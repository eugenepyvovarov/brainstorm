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

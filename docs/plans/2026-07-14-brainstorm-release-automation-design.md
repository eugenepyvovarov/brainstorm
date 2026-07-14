# Brainstorm release automation

Brainstorm releases use one artifact built on the `macos-ultramac` Gitea runner. The workflow resolves its version as `major.minor.<gitea.run_number>`, signs the app with the Developer ID identity available on Ultramac, archives `Brainstorm.app`, and records its SHA-256 in a manifest.

`scripts/release/publish-release.sh` tags the exact source commit and publishes the same ZIP, checksum, manifest, and signature reports to Gitea and GitHub Releases. The ZIP contains the notarized `Brainstorm.app` and a separately signed universal `brainstorm` CLI. Gitea remains the primary repository; GitHub is its push mirror.

Homebrew is a separate manual workflow. It downloads the public GitHub release ZIP and `.sha256` sidecar, verifies the bytes, and commits `Casks/brainstorm.rb` to `eugenepyvovarov/homebrew-cask`. The cask installs `Brainstorm.app` and links the packaged `brainstorm` binary into Homebrew's `bin` directory.

The public release workflow fails closed when Gatekeeper rejects the app. This requires a notarytool profile installed in the Ultramac runner keychain. Sparkle, appcasts, and Sparkle signing keys are not part of this design.

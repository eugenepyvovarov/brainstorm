#!/usr/bin/env bash
set -euo pipefail

# Manually-dispatched only. Resolve the checksum from GitHub's published asset
# digest rather than accepting a caller-provided value.

version="${1:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[1-9][0-9]*$ ]] || { printf 'Usage: %s <major.minor.build>\n' "$0" >&2; exit 2; }
: "${BRAINSTORM_HOMEBREW_TOKEN:?BRAINSTORM_HOMEBREW_TOKEN is required to update the tap.}"

readonly TAP_REPOSITORY="${HOMEBREW_TAP_REPOSITORY:-eugenepyvovarov/homebrew-cask}"
readonly TAP_BRANCH="${HOMEBREW_TAP_BRANCH:-main}"
readonly TAG="v$version"
readonly ARCHIVE="Brainstorm-$version.dmg"
readonly ASSET_URL="https://github.com/eugenepyvovarov/brainstorm/releases/download/$TAG/$ARCHIVE"
readonly RELEASE_API_URL="https://api.github.com/repos/eugenepyvovarov/brainstorm/releases/tags/$TAG"

readonly TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/brainstorm-homebrew.XXXXXX")"
readonly ASKPASS="$TEMP_DIR/git-askpass"
trap 'rm -rf "$TEMP_DIR"' EXIT

curl -fsSL "$RELEASE_API_URL" -o "$TEMP_DIR/release.json"
expected_sha="$(python3 - "$TEMP_DIR/release.json" "$ARCHIVE" <<'PY'
import json
import sys
from pathlib import Path

release = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
asset_name = sys.argv[2]
for asset in release.get("assets", []):
    if asset.get("name") != asset_name:
        continue
    algorithm, separator, digest = asset.get("digest", "").partition(":")
    if algorithm == "sha256" and separator:
        print(digest)
        raise SystemExit(0)
raise SystemExit(f"GitHub release asset has no SHA-256 digest: {asset_name}")
PY
)"
[[ "$expected_sha" =~ ^[a-fA-F0-9]{64}$ ]] || { printf 'Published GitHub asset digest is invalid: %s\n' "$ARCHIVE" >&2; exit 1; }
curl -fsSL "$ASSET_URL" -o "$TEMP_DIR/$ARCHIVE"
actual_sha="$(shasum -a 256 "$TEMP_DIR/$ARCHIVE" | awk '{print $1}')"
[[ "$actual_sha" == "$expected_sha" ]] || { printf "Downloaded disk image checksum does not match GitHub's published asset digest.\\n" >&2; exit 1; }

cat >"$ASKPASS" <<'EOF'
#!/bin/sh
case "$1" in
  *Username*) printf '%s\n' x-access-token ;;
  *) printf '%s\n' "${BRAINSTORM_HOMEBREW_TOKEN:?}" ;;
esac
EOF
chmod 700 "$ASKPASS"

# The shared cask tap has a large history. Fetch only the cask this release
# manages, which keeps the manual workflow responsive and avoids downloading
# unrelated tap contents on the macOS runner.
GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 git clone --depth 1 --filter=blob:none --no-checkout --branch "$TAP_BRANCH" "https://github.com/$TAP_REPOSITORY.git" "$TEMP_DIR/tap"
git -C "$TEMP_DIR/tap" sparse-checkout set --no-cone Casks/brainstorm.rb
git -C "$TEMP_DIR/tap" checkout
mkdir -p "$TEMP_DIR/tap/Casks"
cat >"$TEMP_DIR/tap/Casks/brainstorm.rb" <<EOF
cask "brainstorm" do
  version "$version"
  sha256 "$expected_sha"

  url "$ASSET_URL",
      verified: "github.com/eugenepyvovarov/"
  name "Brainstorm"
  desc "Native macOS mind-map editor with a JSON-first CLI"
  homepage "https://github.com/eugenepyvovarov/brainstorm"

  app "Brainstorm.app"
  binary "Brainstorm.app/Contents/Helpers/brainstorm"
end
EOF

git -C "$TEMP_DIR/tap" add Casks/brainstorm.rb
if git -C "$TEMP_DIR/tap" diff --cached --quiet; then
  printf 'Homebrew Cask already represents Brainstorm %s.\n' "$version"
  exit 0
fi
git -C "$TEMP_DIR/tap" -c user.name='Brainstorm release automation' -c user.email='releases@lifeisgoodlabs.com' commit -m "brainstorm $version"
GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 git -C "$TEMP_DIR/tap" push origin "$TAP_BRANCH"
printf 'Updated %s/Casks/brainstorm.rb for %s.\n' "$TAP_REPOSITORY" "$version"

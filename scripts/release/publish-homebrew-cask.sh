#!/usr/bin/env bash
set -euo pipefail

# Update eugenepyvovarov/homebrew-cask for a published Brainstorm release.
#
# Usage:
#   publish-homebrew-cask.sh [major.minor.build]
#
# When version is omitted, the latest GitHub release tag is used (vX.Y.Z).
# The script optionally fast-forwards the tap from HOMEBREW_TAP_UPSTREAM
# (default: Homebrew/homebrew-cask when the remote exists as a parent fork),
# then rewrites Casks/brainstorm.rb from the public GitHub release asset digest.

version="${1:-}"

: "${BRAINSTORM_HOMEBREW_TOKEN:?BRAINSTORM_HOMEBREW_TOKEN is required to update the tap.}"

readonly TAP_REPOSITORY="${HOMEBREW_TAP_REPOSITORY:-eugenepyvovarov/homebrew-cask}"
readonly TAP_BRANCH="${HOMEBREW_TAP_BRANCH:-main}"
readonly TAP_UPSTREAM="${HOMEBREW_TAP_UPSTREAM:-Homebrew/homebrew-cask}"
readonly GITHUB_REPO="${BRAINSTORM_GITHUB_REPOSITORY:-eugenepyvovarov/brainstorm}"
readonly GITHUB_API="${BRAINSTORM_GITHUB_API:-https://api.github.com}"
readonly GITHUB_TOKEN="${BRAINSTORM_GITHUB_TOKEN:-${BRAINSTORM_HOMEBREW_TOKEN}}"

readonly TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/brainstorm-homebrew.XXXXXX")"
readonly ASKPASS="$TEMP_DIR/git-askpass"
trap 'rm -rf "$TEMP_DIR"' EXIT

auth_curl() {
  curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@"
}

wait_for_release_json() {
  local tag="$1"
  local out_path="$2"
  local attempt
  local url="${GITHUB_API}/repos/${GITHUB_REPO}/releases/tags/${tag}"
  for attempt in $(seq 1 30); do
    if auth_curl "$url" -o "$out_path" 2>/dev/null; then
      return 0
    fi
    printf 'Waiting for GitHub release %s (attempt %s/30)…\n' "$tag" "$attempt"
    sleep 5
  done
  printf 'GitHub release not available after waiting: %s\n' "$tag" >&2
  return 1
}

resolve_latest_version() {
  local latest_json="$TEMP_DIR/latest.json"
  auth_curl "${GITHUB_API}/repos/${GITHUB_REPO}/releases/latest" -o "$latest_json"
  python3 - "$latest_json" <<'PY'
import json
import re
import sys
from pathlib import Path

release = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
tag = str(release.get("tag_name") or "")
match = re.fullmatch(r"v([0-9]+\.[0-9]+\.[1-9][0-9]*)", tag)
if not match:
    raise SystemExit(f"Latest GitHub release tag is not a Brainstorm version: {tag!r}")
print(match.group(1))
PY
}

if [[ -z "$version" ]]; then
  version="$(resolve_latest_version)"
  printf 'Using latest GitHub release version: %s\n' "$version"
fi

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[1-9][0-9]*$ ]] || {
  printf 'Usage: %s [major.minor.build]\n' "$0" >&2
  exit 2
}

readonly TAG="v$version"
readonly ARCHIVE="Brainstorm-$version.dmg"
readonly ASSET_URL="https://github.com/${GITHUB_REPO}/releases/download/${TAG}/${ARCHIVE}"

wait_for_release_json "$TAG" "$TEMP_DIR/release.json"

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
[[ "$expected_sha" =~ ^[a-fA-F0-9]{64}$ ]] || {
  printf 'Published GitHub asset digest is invalid: %s\n' "$ARCHIVE" >&2
  exit 1
}

# Download may race slightly after the release JSON appears.
for attempt in $(seq 1 12); do
  if curl -fsSL "$ASSET_URL" -o "$TEMP_DIR/$ARCHIVE"; then
    break
  fi
  printf 'Waiting for DMG asset %s (attempt %s/12)…\n' "$ARCHIVE" "$attempt"
  sleep 5
  if [[ "$attempt" -eq 12 ]]; then
    printf 'Could not download release asset: %s\n' "$ASSET_URL" >&2
    exit 1
  fi
done

actual_sha="$(shasum -a 256 "$TEMP_DIR/$ARCHIVE" | awk '{print $1}')"
[[ "$actual_sha" == "$expected_sha" ]] || {
  printf "Downloaded disk image checksum does not match GitHub's published asset digest.\\n" >&2
  exit 1
}

cat >"$ASKPASS" <<'EOF'
#!/bin/sh
case "$1" in
  *Username*) printf '%s\n' x-access-token ;;
  *) printf '%s\n' "${BRAINSTORM_HOMEBREW_TOKEN:?}" ;;
esac
EOF
chmod 700 "$ASKPASS"

# Clone enough history for a pushable merge from the parent tap.
GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 \
  git clone --depth 50 --branch "$TAP_BRANCH" \
  "https://github.com/$TAP_REPOSITORY.git" "$TEMP_DIR/tap"

# Fast-forward the personal tap from its parent (Homebrew/homebrew-cask by default)
# so brainstorm.rb lands on a current main before we rewrite the cask.
if [[ -n "$TAP_UPSTREAM" ]]; then
  printf 'Syncing %s from upstream %s…\n' "$TAP_REPOSITORY" "$TAP_UPSTREAM"
  git -C "$TEMP_DIR/tap" remote add upstream "https://github.com/${TAP_UPSTREAM}.git" 2>/dev/null \
    || git -C "$TEMP_DIR/tap" remote set-url upstream "https://github.com/${TAP_UPSTREAM}.git"
  # Upstream fetch is public; no auth required for Homebrew/* taps.
  if git -C "$TEMP_DIR/tap" fetch --depth 50 upstream "$TAP_BRANCH"; then
    if git -C "$TEMP_DIR/tap" merge --ff-only "upstream/$TAP_BRANCH"; then
      printf 'Tap fast-forwarded to upstream/%s.\n' "$TAP_BRANCH"
    else
      printf 'Warning: could not fast-forward onto upstream/%s; continuing on fork tip.\n' "$TAP_BRANCH" >&2
      git -C "$TEMP_DIR/tap" merge --abort 2>/dev/null || true
    fi
  else
    printf 'Warning: could not fetch upstream %s; continuing on fork tip.\n' "$TAP_UPSTREAM" >&2
  fi
fi

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

git -C "$TEMP_DIR/tap" \
  -c user.name='Brainstorm release automation' \
  -c user.email='releases@lifeisgoodlabs.com' \
  commit -m "brainstorm $version"

# Push upstream sync (if any) + cask bump together.
GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 \
  git -C "$TEMP_DIR/tap" push origin "$TAP_BRANCH"

printf 'Updated %s/Casks/brainstorm.rb for %s.\n' "$TAP_REPOSITORY" "$version"

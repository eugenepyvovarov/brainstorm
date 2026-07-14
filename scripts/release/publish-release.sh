#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest_path="${1:-}"
[[ -n "$manifest_path" ]] || { printf 'Usage: %s <release.json>\n' "$0" >&2; exit 2; }
[[ -f "$manifest_path" ]] || { printf 'Manifest not found: %s\n' "$manifest_path" >&2; exit 2; }

: "${BRAINSTORM_GITEA_TOKEN:?BRAINSTORM_GITEA_TOKEN is required to create the Gitea Release.}"
: "${BRAINSTORM_GITHUB_TOKEN:?BRAINSTORM_GITHUB_TOKEN is required to create the GitHub Release.}"

release_tag="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag"])' "$manifest_path")"
source_commit="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_commit"])' "$manifest_path")"

if git -C "$ROOT_DIR" rev-parse -q --verify "refs/tags/$release_tag" >/dev/null; then
  tag_commit="$(git -C "$ROOT_DIR" rev-list -n 1 "$release_tag")"
  [[ "$tag_commit" == "$source_commit" ]] || { printf 'Existing tag %s points to %s, not %s.\n' "$release_tag" "$tag_commit" "$source_commit" >&2; exit 1; }
else
  git -C "$ROOT_DIR" tag -a "$release_tag" "$source_commit" -m "Brainstorm $release_tag"
fi

git -C "$ROOT_DIR" push origin "refs/tags/$release_tag"

export BRAINSTORM_GITEA_SERVER_URL="${BRAINSTORM_GITEA_SERVER_URL:-https://git.ultramac.work}"
export BRAINSTORM_GITEA_REPOSITORY="${BRAINSTORM_GITEA_REPOSITORY:-lifeisgoodlabs/brainstorm-macos}"
export BRAINSTORM_GITHUB_REPOSITORY="${BRAINSTORM_GITHUB_REPOSITORY:-eugenepyvovarov/brainstorm}"
python3 "$ROOT_DIR/scripts/release/publish_release.py" "$manifest_path"

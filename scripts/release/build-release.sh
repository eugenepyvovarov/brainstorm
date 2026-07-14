#!/usr/bin/env bash
set -euo pipefail

# Build one signed Brainstorm release artifact. This script is intentionally
# Sparkle-free: Homebrew and the release pages consume the generated ZIP/SHA.

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly WORKSPACE_PATH="${BRAINSTORM_WORKSPACE_PATH:-$ROOT_DIR/Brainstorm.xcworkspace}"
readonly SCHEME="${BRAINSTORM_SCHEME:-Brainstorm}"
readonly CONFIGURATION="${BRAINSTORM_CONFIGURATION:-Release}"
readonly DEFAULT_SIGNING_IDENTITY="Developer ID Application: Ievgen Pyvovarov (VXRLZNZH2E)"
readonly SIGNING_IDENTITY="${BRAINSTORM_CODE_SIGN_IDENTITY:-$DEFAULT_SIGNING_IDENTITY}"
readonly SIGNING_TEAM="${BRAINSTORM_DEVELOPMENT_TEAM:-VXRLZNZH2E}"
readonly NOTARIZE_MODE="${NOTARIZE_APP:-auto}"
readonly REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-false}"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

xcconfig_value() {
  local key="$1"
  awk -F '=' -v key="$key" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      value = $2
      sub(/\/\/.*$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "$ROOT_DIR/Config/Shared.xcconfig"
}

is_true() {
  case "${1,,}" in
    1|true|yes) return 0 ;;
    *) return 1 ;;
  esac
}

release_build="${RELEASE_BUILD:-}"
[[ "$release_build" =~ ^[1-9][0-9]*$ ]] || die 'RELEASE_BUILD must be a positive integer (the Gitea job build number).'

major="${RELEASE_MAJOR:-$(xcconfig_value BRAINSTORM_MAJOR_VERSION)}"
minor="${RELEASE_MINOR:-$(xcconfig_value BRAINSTORM_MINOR_VERSION)}"
[[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || die 'Could not resolve numeric Brainstorm major/minor values.'

readonly RELEASE_VERSION="${major}.${minor}.${release_build}"
readonly RELEASE_TAG="${RELEASE_TAG:-v${RELEASE_VERSION}}"
readonly DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist/$RELEASE_TAG}"
readonly DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/DerivedData/$RELEASE_TAG}"
readonly ARCHIVE_NAME="Brainstorm-${RELEASE_VERSION}.zip"
readonly ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"
readonly CHECKSUM_PATH="$ARCHIVE_PATH.sha256"
readonly MANIFEST_PATH="$DIST_DIR/release.json"
readonly SIGNATURE_REPORT="$DIST_DIR/signature.txt"
readonly GATEKEEPER_REPORT="$DIST_DIR/gatekeeper.txt"

if ! is_true "${ALLOW_DIRTY_RELEASE:-false}" && ! git -C "$ROOT_DIR" diff --quiet; then
  die 'Release working tree has unstaged changes. Commit them before building a release.'
fi
if ! is_true "${ALLOW_DIRTY_RELEASE:-false}" && ! git -C "$ROOT_DIR" diff --cached --quiet; then
  die 'Release working tree has staged changes. Commit them before building a release.'
fi

mkdir -p "$DIST_DIR" "$DERIVED_DATA_PATH"

printf 'Building Brainstorm %s (build %s) with %s\n' "$RELEASE_VERSION" "$release_build" "$SIGNING_IDENTITY"
xcodebuild \
  -workspace "$WORKSPACE_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CURRENT_PROJECT_VERSION="$release_build" \
  DEVELOPMENT_TEAM="$SIGNING_TEAM" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  clean build

readonly APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/Brainstorm.app"
[[ -d "$APP_PATH" ]] || die "Built app was not found at $APP_PATH."

bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
bundle_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
[[ "$bundle_version" == "$RELEASE_VERSION" ]] || die "Bundle version $bundle_version does not match $RELEASE_VERSION."
[[ "$bundle_build" == "$release_build" ]] || die "Bundle build $bundle_build does not match $release_build."

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dvvv "$APP_PATH" 2>&1 | tee "$SIGNATURE_REPORT"
grep -F "Authority=$SIGNING_IDENTITY" "$SIGNATURE_REPORT" >/dev/null || die 'The requested Developer ID identity did not sign the app.'

notarized=false
case "${NOTARIZE_MODE,,}" in
  yes|true)
    [[ -n "${NOTARYTOOL_PROFILE:-}" ]] || die 'NOTARYTOOL_PROFILE is required when NOTARIZE_APP is enabled.'
    /usr/bin/ditto -ck --rsrc --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
    /usr/bin/xcrun notarytool submit "$ARCHIVE_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
    /usr/bin/xcrun stapler staple "$APP_PATH"
    /usr/bin/xcrun stapler validate "$APP_PATH"
    notarized=true
    ;;
  auto)
    if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
      /usr/bin/ditto -ck --rsrc --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
      /usr/bin/xcrun notarytool submit "$ARCHIVE_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
      /usr/bin/xcrun stapler staple "$APP_PATH"
      /usr/bin/xcrun stapler validate "$APP_PATH"
      notarized=true
    fi
    ;;
  no|false) ;;
  *) die "NOTARIZE_APP must be auto, yes, or no; got $NOTARIZE_MODE." ;;
esac

rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH"
/usr/bin/ditto -ck --rsrc --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
readonly SHA256="$(/usr/bin/shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
printf '%s  %s\n' "$SHA256" "$ARCHIVE_NAME" >"$CHECKSUM_PATH"

gatekeeper_status=accepted
if ! spctl -a -vv "$APP_PATH" >"$GATEKEEPER_REPORT" 2>&1; then
  gatekeeper_status=rejected
fi

if is_true "$REQUIRE_NOTARIZATION" && [[ "$gatekeeper_status" != accepted ]]; then
  cat "$GATEKEEPER_REPORT" >&2
  die 'Gatekeeper rejected the app. Configure a notarytool profile and retry before publishing.'
fi

readonly SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
cat >"$MANIFEST_PATH" <<EOF
{
  "app_name": "Brainstorm",
  "archive": "$ARCHIVE_NAME",
  "build": "$release_build",
  "bundle_id": "com.eugenep.Brainstorm",
  "gatekeeper_status": "$gatekeeper_status",
  "notarized": $notarized,
  "sha256": "$SHA256",
  "source_commit": "$SOURCE_COMMIT",
  "tag": "$RELEASE_TAG",
  "version": "$RELEASE_VERSION"
}
EOF

printf 'Release artifact: %s\nSHA-256: %s\nManifest: %s\n' "$ARCHIVE_PATH" "$SHA256" "$MANIFEST_PATH"

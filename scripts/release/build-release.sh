#!/usr/bin/env bash
set -euo pipefail

# Build one signed Brainstorm release artifact. This script is intentionally
# Sparkle-free: Homebrew and the release pages consume the generated DMG.

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly WORKSPACE_PATH="${BRAINSTORM_WORKSPACE_PATH:-$ROOT_DIR/Brainstorm.xcworkspace}"
readonly SCHEME="${BRAINSTORM_SCHEME:-Brainstorm}"
readonly CONFIGURATION="${BRAINSTORM_CONFIGURATION:-Release}"
readonly DEFAULT_SIGNING_IDENTITY="Developer ID Application: Ievgen Pyvovarov (VXRLZNZH2E)"
readonly SIGNING_IDENTITY="${BRAINSTORM_CODE_SIGN_IDENTITY:-$DEFAULT_SIGNING_IDENTITY}"
readonly DEFAULT_CODESIGN_KEYCHAIN_PATH="$HOME/Library/Keychains/opencode-signing.keychain-db"
readonly DEFAULT_CODESIGN_KEYCHAIN_PASSWORD_FILE="$HOME/.opencode/codesign/opencode-signing.keychain.pass"
readonly CODESIGN_KEYCHAIN_PATH="${CODESIGN_KEYCHAIN_PATH:-$DEFAULT_CODESIGN_KEYCHAIN_PATH}"
readonly CODESIGN_KEYCHAIN_PASSWORD_FILE="${CODESIGN_KEYCHAIN_PASSWORD_FILE:-$DEFAULT_CODESIGN_KEYCHAIN_PASSWORD_FILE}"
readonly CODESIGN_ENTITLEMENTS_PATH="${BRAINSTORM_CODESIGN_ENTITLEMENTS:-$ROOT_DIR/Config/Brainstorm.entitlements}"
readonly NOTARY_KEYCHAIN_PATH="${NOTARYTOOL_KEYCHAIN_PATH:-$CODESIGN_KEYCHAIN_PATH}"
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
  # macOS ships Bash 3.2, which does not support ${var,,}.
  case "$1" in
    1|true|TRUE|True|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

unlock_codesign_keychain() {
  [[ -f "$CODESIGN_KEYCHAIN_PATH" ]] || return 0

  local keychain_password="${CODESIGN_KEYCHAIN_PASSWORD:-}"
  if [[ -z "$keychain_password" && -f "$CODESIGN_KEYCHAIN_PASSWORD_FILE" ]]; then
    keychain_password="$(<"$CODESIGN_KEYCHAIN_PASSWORD_FILE")"
  fi
  [[ -n "$keychain_password" ]] || die "Codesign keychain is present but its password is unavailable: $CODESIGN_KEYCHAIN_PASSWORD_FILE"

  printf 'Unlocking codesign keychain: %s\n' "$CODESIGN_KEYCHAIN_PATH"
  security unlock-keychain -p "$keychain_password" "$CODESIGN_KEYCHAIN_PATH"

  local existing_keychains=()
  local existing_keychain
  while IFS= read -r existing_keychain; do
    existing_keychain="${existing_keychain#\"}"
    existing_keychain="${existing_keychain%\"}"
    [[ -n "$existing_keychain" && "$existing_keychain" != "$CODESIGN_KEYCHAIN_PATH" ]] || continue
    existing_keychains+=("$existing_keychain")
  done < <(security list-keychains -d user | sed -e 's/^[[:space:]]*//')
  security list-keychains -d user -s "$CODESIGN_KEYCHAIN_PATH" "${existing_keychains[@]}"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$CODESIGN_KEYCHAIN_PATH" >/dev/null
}

sign_app_bundle() {
  [[ -f "$CODESIGN_ENTITLEMENTS_PATH" ]] || die "Codesign entitlements were not found: $CODESIGN_ENTITLEMENTS_PATH"
  codesign \
    --force \
    --timestamp \
    --options runtime \
    --entitlements "$CODESIGN_ENTITLEMENTS_PATH" \
    --sign "$SIGNING_IDENTITY" \
    "$APP_PATH"
}

build_cli() {
  [[ -f "$CLI_PACKAGE_PATH/Package.swift" ]] || die "Brainstorm CLI package was not found: $CLI_PACKAGE_PATH"

  local architectures=(arm64 x86_64)
  local binaries=()
  local arch
  local scratch_path
  local binary_path

  rm -rf "$CLI_BUILD_ROOT"
  for arch in "${architectures[@]}"; do
    scratch_path="$CLI_BUILD_ROOT/$arch"
    swift build \
      --package-path "$CLI_PACKAGE_PATH" \
      --configuration release \
      --arch "$arch" \
      --scratch-path "$scratch_path"
    binary_path="$(swift build \
      --package-path "$CLI_PACKAGE_PATH" \
      --configuration release \
      --arch "$arch" \
      --scratch-path "$scratch_path" \
      --show-bin-path)/brainstorm"
    [[ -x "$binary_path" ]] || die "Built Brainstorm CLI was not found for $arch: $binary_path"
    binaries+=("$binary_path")
  done

  mkdir -p "$(dirname "$CLI_PATH")"
  /usr/bin/lipo -create "${binaries[@]}" -output "$CLI_PATH"
  local cli_architectures
  cli_architectures="$(/usr/bin/lipo -archs "$CLI_PATH")"
  [[ "$cli_architectures" == *arm64* && "$cli_architectures" == *x86_64* ]] || die "Brainstorm CLI is not universal: $cli_architectures"

  codesign \
    --force \
    --timestamp \
    --options runtime \
    --sign "$SIGNING_IDENTITY" \
    "$CLI_PATH"
  codesign --verify --strict --verbose=2 "$CLI_PATH"
}

package_release() {
  rm -f "$ARCHIVE_PATH"
  /usr/bin/hdiutil create \
    -ov \
    -format UDZO \
    -volname Brainstorm \
    -srcfolder "$APP_PATH" \
    "$ARCHIVE_PATH" >/dev/null
}

submit_notarization() {
  local args=(notarytool submit "$ARCHIVE_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait)
  if [[ -f "$NOTARY_KEYCHAIN_PATH" ]]; then
    args+=(--keychain "$NOTARY_KEYCHAIN_PATH")
  fi
  /usr/bin/xcrun "${args[@]}"
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
readonly ARCHIVE_NAME="Brainstorm-${RELEASE_VERSION}.dmg"
readonly ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"
readonly CLI_PACKAGE_PATH="${BRAINSTORM_CLI_PACKAGE_PATH:-$ROOT_DIR/BrainstormPackage}"
readonly CLI_BUILD_ROOT="${CLI_BUILD_ROOT:-$DERIVED_DATA_PATH/BrainstormCLI}"
readonly CLI_NAME="brainstorm"
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

unlock_codesign_keychain
mkdir -p "$DIST_DIR" "$DERIVED_DATA_PATH"

printf 'Building Brainstorm %s (build %s) with %s\n' "$RELEASE_VERSION" "$release_build" "$SIGNING_IDENTITY"
xcodebuild \
  -workspace "$WORKSPACE_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CURRENT_PROJECT_VERSION="$release_build" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  clean build

readonly APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/Brainstorm.app"
[[ -d "$APP_PATH" ]] || die "Built app was not found at $APP_PATH."
readonly CLI_PATH="$APP_PATH/Contents/Helpers/$CLI_NAME"

bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
bundle_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
[[ "$bundle_version" == "$RELEASE_VERSION" ]] || die "Bundle version $bundle_version does not match $RELEASE_VERSION."
[[ "$bundle_build" == "$release_build" ]] || die "Bundle build $bundle_build does not match $release_build."

build_cli
sign_app_bundle
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dvvv "$APP_PATH" 2>&1 | tee "$SIGNATURE_REPORT"
codesign -dvvv "$CLI_PATH" 2>&1 | tee -a "$SIGNATURE_REPORT"
[[ "$(grep -Fxc "Authority=$SIGNING_IDENTITY" "$SIGNATURE_REPORT")" -ge 2 ]] || die 'The requested Developer ID identity did not sign both the app and CLI.'

notarized=false
notarize_mode="$(printf '%s' "$NOTARIZE_MODE" | tr '[:upper:]' '[:lower:]')"
case "$notarize_mode" in
  yes|true)
    [[ -n "${NOTARYTOOL_PROFILE:-}" ]] || die 'NOTARYTOOL_PROFILE is required when NOTARIZE_APP is enabled.'
    package_release
    submit_notarization
    /usr/bin/xcrun stapler staple "$ARCHIVE_PATH"
    /usr/bin/xcrun stapler validate "$ARCHIVE_PATH"
    notarized=true
    ;;
  auto)
    if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
      package_release
      submit_notarization
      /usr/bin/xcrun stapler staple "$ARCHIVE_PATH"
      /usr/bin/xcrun stapler validate "$ARCHIVE_PATH"
      notarized=true
    fi
    ;;
  no|false) ;;
  *) die "NOTARIZE_APP must be auto, yes, or no; got $NOTARIZE_MODE." ;;
esac

if [[ "$notarized" != true ]]; then
  package_release
fi
rm -f "$CHECKSUM_PATH"
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
  "cli": "Brainstorm.app/Contents/Helpers/$CLI_NAME",
  "gatekeeper_status": "$gatekeeper_status",
  "notarized": $notarized,
  "sha256": "$SHA256",
  "source_commit": "$SOURCE_COMMIT",
  "tag": "$RELEASE_TAG",
  "version": "$RELEASE_VERSION"
}
EOF

printf 'Release artifact: %s\nSHA-256: %s\nManifest: %s\n' "$ARCHIVE_PATH" "$SHA256" "$MANIFEST_PATH"

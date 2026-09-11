#!/bin/bash
set -euo pipefail

# ClaudeSwitch — build, sign, notarize, and (with --publish) release.
#
# The release half is ported from doppo-terminal/scripts/build-dmg.sh so every app
# in the family ships through the same pipeline: two notarization submissions, an
# inside-out–signed Sparkle framework, the DMG as a GitHub release asset, and the
# appcast committed to the site repo. Two channels, one build, one feed.
#
#   ./scripts/build-dmg.sh                     local unsigned build
#   ./scripts/build-dmg.sh --beta --publish    cut + publish a Beta
#   ./scripts/build-dmg.sh --stable --publish   promote the current lead to Stable

APP_NAME="ClaudeSwitch"
# Mach-O executable inside Contents/MacOS. Must stay "ClaudeSwitch": it is the
# SwiftPM product name, so the built binary is at .build/release/ClaudeSwitch.
EXEC_NAME="ClaudeSwitch"
# Space-free base for the DMG filename, because it ends up in the appcast
# enclosure URL.
DMG_BASE="ClaudeSwitch"

cd "$(dirname "$0")/.."

# Signing / notary identity is personal to whoever builds a release, so it is NOT
# committed. Put your values in scripts/signing.env (gitignored) — see
# scripts/signing.env.example. Any value can also come from the environment.
# Local unsigned builds work without any of these.
SIGNING_ENV="scripts/signing.env"
if [[ -f "$SIGNING_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$SIGNING_ENV"
fi

BUNDLE_ID="${BUNDLE_ID:-com.irvcassio.ClaudeSwitch}"
TEAM_ID="${TEAM_ID:-}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_APPLE_ID="${NOTARY_APPLE_ID:-}"
NOTARY_TEAM_ID="${NOTARY_TEAM_ID:-${TEAM_ID}}"
SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:-}"   # EdDSA key file for sign_update
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"     # matching base64 key -> Info.plist SUPublicEDKey

# notarytool arguments, shared by BOTH submissions (the .app, then the DMG).
# A stored keychain profile already carries the Apple ID / team / app password.
# Passing empty --apple-id/--team-id makes notarytool fail validation, so they
# are only added when actually set.
NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE" --wait)
[[ -n "$NOTARY_APPLE_ID" ]] && NOTARY_ARGS+=(--apple-id "$NOTARY_APPLE_ID")
[[ -n "$NOTARY_TEAM_ID" ]] && NOTARY_ARGS+=(--team-id "$NOTARY_TEAM_ID")

# Both notarization steps are guarded identically: skip cleanly when the caller
# asked to (SKIP_NOTARIZE=1), when there is no notary profile, or when the build
# is ad-hoc signed (an unsigned bundle cannot be notarized at all).
notarize_enabled() {
  [[ "${SKIP_NOTARIZE:-0}" != "1" && -n "$NOTARY_PROFILE" && -n "$SIGN_IDENTITY" ]]
}

# ── Publish target ───────────────────────────────────────────────────────────
# The DMG and the appcast live in DIFFERENT places, on purpose:
#
#   * The DMG is a GitHub **release asset** in a separate PUBLIC repo, so this
#     repo can stay private while Sparkle downloads the binary unauthenticated
#     (no token ever ships inside the app).
#   * The appcast is a few KB of XML, so it is committed to the Vercel site repo,
#     which gives it a stable, cache-friendly HTTPS URL.
#
# Both are variables: if app-downloads is ever transferred to another account,
# only RELEASE_REPO changes. That is safe for already-published builds — GitHub
# redirects old release URLs, and the EdDSA signature covers the DMG's *content*,
# not its URL.
RELEASE_REPO="${RELEASE_REPO:-irvcassio/app-downloads}"      # public repo hosting the DMG
RELEASE_TAG_PREFIX="${RELEASE_TAG_PREFIX:-claudeswitch-v}"   # claudeswitch-v<marketing>-b<build>
SITE_REPO="${SITE_REPO:-$HOME/doppoworks}"                   # checkout of the site serving the feed
FEED_DIR="${FEED_DIR:-claudeswitch}"                         # <FEED_PATH>/appcast.xml
#
# FEED_PATH is the path INSIDE the site repo, and is a variable rather than a
# hardcoded "public/downloads/..." because sites differ in shape. Hardcoding one
# is how an appcast lands somewhere the web server never looks while the publish
# still reports success — which is exactly what happened to Doppo Console.
FEED_PATH="${FEED_PATH:-public/downloads/${FEED_DIR}}"
FEED_URL="${FEED_URL:-https://www.doppoworks.com/downloads/${FEED_DIR}/appcast.xml}"

# Beta is the default channel: a release that has not been through Beta has not
# been through anything.
CHANNEL="${CHANNEL:-beta}"
PUBLISH="${PUBLISH:-0}"
for arg in "$@"; do
  case "$arg" in
    --stable)  CHANNEL="stable" ;;
    --beta)    CHANNEL="beta" ;;
    --publish) PUBLISH=1 ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done
[[ "$CHANNEL" == "stable" || "$CHANNEL" == "beta" ]] || { echo "CHANNEL must be stable|beta" >&2; exit 2; }

# ── First-publish guard ──────────────────────────────────────────────────────
# There are working scripts/signing.env files for the sibling apps on this
# machine, and copying one over is the obvious thing to do. It is WRONG for two
# values, and neither mistake is recoverable after the fact:
#
#   * SPARKLE_PRIVATE_KEY — ClaudeSwitch needs its OWN EdDSA keypair. Sharing one
#     means a compromise of either product's key forges updates for both, with no
#     way to rotate one without breaking the other.
#   * FEED_URL — publishing into another product's appcast would offer
#     ClaudeSwitch as an update to every install of that product, replacing a
#     working app on the operator's machines with a different one.
#
# So --publish requires an explicit acknowledgement. Generate a keypair with
# Sparkle's `generate_keys --account claudeswitch`, put it in scripts/signing.env,
# then set the flag there once both values are verified against the SHIPPING
# binary (SUPublicEDKey and SUFeedURL inside the installed app).
if [[ "$PUBLISH" == "1" ]]; then
  if [[ -z "$SPARKLE_PRIVATE_KEY" || -z "$SPARKLE_PUBLIC_KEY" ]]; then
    echo "Refusing to publish: ClaudeSwitch has no Sparkle keypair configured." >&2
    echo "Generate one (generate_keys --account claudeswitch) and set" >&2
    echo "SPARKLE_PRIVATE_KEY/SPARKLE_PUBLIC_KEY in scripts/signing.env — a FRESH" >&2
    echo "pair, not Doppo Terminal's, Doppo Browser's, or Canopy's." >&2
    exit 2
  fi
  for foreign in doppo-terminal doppo-browser doppo-console canopy-terminal; do
    if [[ "$FEED_URL" == *"/${foreign}/"* ]]; then
      echo "Refusing to publish: FEED_URL points at ${foreign}'s appcast (${FEED_URL})." >&2
      echo "That would offer ClaudeSwitch as an update to every installed ${foreign}." >&2
      exit 2
    fi
  done
  if [[ "${CLAUDESWITCH_SPARKLE_READY:-0}" != "1" ]]; then
    echo "Refusing to publish: set CLAUDESWITCH_SPARKLE_READY=1 to confirm that" >&2
    echo "  · SPARKLE_PRIVATE_KEY is a keypair generated for THIS product, and" >&2
    echo "  · FEED_URL (${FEED_URL}) is ClaudeSwitch's own feed." >&2
    echo "Persist it in scripts/signing.env once the two values are verified." >&2
    exit 2
  fi
fi

# Suffixed `.noindex` because Spotlight indexes build output as REAL APPLICATIONS,
# leaving a second launchable copy of the app next to the installed one — and
# picking the wrong one launches a stale, unnotarized build. Spotlight
# unconditionally skips any directory whose name ends in `.noindex`.
BUILD_DIR="build.noindex"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
ARCHIVE_DIR="${BUILD_DIR}/release"
BINARY_PATH=".build/release/${EXEC_NAME}"
ICON_SOURCE="Resources/AppIcon.png"

# ── Preflight: refuse a release this machine cannot finish ───────────────────
# Signing is the first step that can fail for reasons outside this script, and it
# used to fail AFTER the build-number ledger had been spent. Actually exercising
# the identity costs about two seconds and turns a mid-build stop into a message
# printed before anything irreversible happens. Existence checks are not enough:
# `security find-identity` lists identities whose key cannot sign.
if [[ -n "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$SIGN_IDENTITY" TEAM_ID="$TEAM_ID" \
    bash scripts/preflight-signing.sh || exit 1
fi

VERSION_FILE="VERSION"
APP_VERSION_SWIFT="Sources/ClaudeSwitchCore/AppVersion.swift"

# ── Version: visible (per channel) + build number ────────────────────────────
# Two numbers, two jobs:
#
#   * CFBundleShortVersionString — what the operator SEES (Settings ▸ Updates).
#     One monotonic counter per channel, with Beta always at or ahead of Stable.
#     That invariant is computed from the tracked VERSION file by version-plan.sh.
#   * CFBundleVersion — the build number Sparkle compares to decide "is there an
#     update?". It means nothing to the operator, but it must strictly increase
#     per shipped artifact or Sparkle strands every installed client on the older
#     build. So it bumps every run.
#
# VERSION is the ONLY source of truth for the visible version. AppVersion.swift is
# a stamped mirror — Settings needs the value at compile time, so the script writes
# it in before `swift build`.
#
# shellcheck source=scripts/version-plan.sh
source scripts/version-plan.sh
[[ -f "$VERSION_FILE" ]] || { echo "VERSION file not found at ${VERSION_FILE}" >&2; exit 1; }
CUR_STABLE=$(sed -n 's/^STABLE=//p' "$VERSION_FILE" | head -1)
CUR_BETA=$(sed -n 's/^BETA=//p' "$VERSION_FILE" | head -1)
[[ -n "$CUR_STABLE" && -n "$CUR_BETA" ]] || { echo "VERSION file missing STABLE=/BETA= lines" >&2; exit 1; }
MARKETING_VERSION="$(vp_next "$CUR_STABLE" "$CUR_BETA" "$CHANNEL")"

# A Stable *publish* that would not advance past the current Stable is a no-op
# promotion — nothing new has been through Beta to promote. Refuse it rather than
# cut an identical "new" release. (A local, non-publish stable build is allowed:
# it just previews the current version.)
if [[ "$PUBLISH" == "1" && "$CHANNEL" == "stable" && "$(vp_cmp "$MARKETING_VERSION" "$CUR_STABLE")" != "1" ]]; then
  echo "Refusing to publish Stable: computed version ${MARKETING_VERSION} does not advance past current Stable ${CUR_STABLE}." >&2
  echo "  Nothing new has shipped to Beta to promote — cut a Beta build first." >&2
  exit 1
fi

BUILD_VERSION=$(sed -n 's/.*static let build = "\([^"]*\)".*/\1/p' "$APP_VERSION_SWIFT" | head -1)
[[ -n "$BUILD_VERSION" ]] || { echo "Could not read the build number from ${APP_VERSION_SWIFT}" >&2; exit 1; }
BUILD_VERSION=$((BUILD_VERSION + 1))

# Stamp both values into the compiled mirror BEFORE the build, so Settings shows
# exactly what the feed advertises. The greps afterwards are the point: a silent
# no-op sed would ship a version that has not been true for several releases,
# and Settings is where the operator checks whether an update landed.
sed -i '' "s/static let marketing = \"[^\"]*\"/static let marketing = \"${MARKETING_VERSION}\"/" "$APP_VERSION_SWIFT"
sed -i '' "s/static let build = \"[^\"]*\"/static let build = \"${BUILD_VERSION}\"/" "$APP_VERSION_SWIFT"
grep -q "static let marketing = \"${MARKETING_VERSION}\"" "$APP_VERSION_SWIFT" \
  && grep -q "static let build = \"${BUILD_VERSION}\"" "$APP_VERSION_SWIFT" \
  || { echo "Could not stamp the version into ${APP_VERSION_SWIFT} — the declarations have moved or been renamed." >&2; exit 1; }

DMG_NAME="${DMG_BASE}-${MARKETING_VERSION}-b${BUILD_VERSION}-arm64.dmg"
DMG_PATH="${ARCHIVE_DIR}/${DMG_NAME}"

echo "=== Building ${APP_NAME} ${MARKETING_VERSION} (build ${BUILD_VERSION}) — channel: ${CHANNEL} ==="

echo "1. Tests..."
swift test 2>&1 | tail -3

echo "2. Release binary..."
swift build -c release --arch arm64
[[ -f "$BINARY_PATH" ]] || { echo "Error: no binary at ${BINARY_PATH}" >&2; exit 1; }

echo "3. App bundle..."
rm -rf "$APP_BUNDLE" "$ARCHIVE_DIR"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources" "$ARCHIVE_DIR"
cp "$BINARY_PATH" "${APP_BUNDLE}/Contents/MacOS/${EXEC_NAME}"

RESOURCE_BUNDLE=$(find .build -path "*/release/${EXEC_NAME}_*.bundle" -type d 2>/dev/null | head -1 || true)
if [[ -n "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "${APP_BUNDLE}/Contents/Resources/"
  echo "   Copied SwiftPM resources"
fi

# LSUIElement keeps it out of the Dock and the app switcher — it lives in the
# menu bar only. SUFeedURL is the URL compiled into the app; changing it after
# ship strands every installed client, so it comes from one variable.
cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleExecutable</key><string>${EXEC_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_VERSION}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>SUFeedURL</key><string>${FEED_URL}</string>
    <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "${APP_BUNDLE}/Contents/PkgInfo"

# SUPublicEDKey is only known once a keypair exists (see signing.env.example).
# Without it Sparkle refuses every update as unsigned, so an unset key is a loud
# warning, not a silent skip.
if [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string ${SPARKLE_PUBLIC_KEY}" \
    "${APP_BUNDLE}/Contents/Info.plist" >/dev/null
  echo "   Info.plist: SUPublicEDKey set"
else
  echo "   ⚠ SPARKLE_PUBLIC_KEY unset — SUPublicEDKey omitted; Sparkle will reject all updates."
  echo "     Generate a keypair (generate_keys --account claudeswitch) and set it in scripts/signing.env."
fi

if [[ -f "$ICON_SOURCE" ]]; then
  echo "   Icon..."
  ICON_TMP=$(mktemp -d); ICONSET="${ICON_TMP}/AppIcon.iconset"; mkdir -p "$ICONSET"
  for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" \
              "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
    set -- $spec
    sips -z "$1" "$1" "$ICON_SOURCE" --out "${ICONSET}/icon_$2.png" > /dev/null
  done
  iconutil -c icns "$ICONSET" -o "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
  rm -rf "$ICON_TMP"
fi

# Sparkle framework embed. SwiftPM unpacks the binary target to
# .build/artifacts/.../Sparkle.xcframework/<slice>/Sparkle.framework — the
# framework already contains Autoupdate, Updater.app and the XPC services under
# Versions/B, so a plain recursive copy (preserving the version symlinks) is
# enough. `cp -R` copies symlinks as symlinks, which is required: a framework
# whose Versions/Current is a real directory fails codesign's bundle checks.
SPARKLE_FW=$(find .build -name "Sparkle.framework" -type d 2>/dev/null | head -1 || true)
if [[ -n "$SPARKLE_FW" ]]; then
  echo "   Embedding Sparkle.framework from ${SPARKLE_FW}"
  mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
  rm -rf "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
  cp -R "$SPARKLE_FW" "${APP_BUNDLE}/Contents/Frameworks/"
  EMBEDDED_FW="${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
  # Fail fast rather than shipping a framework whose helper tools are missing —
  # without Autoupdate/Updater.app the updater silently cannot install.
  for required in \
    "Versions/Current/Sparkle" \
    "Versions/Current/Autoupdate" \
    "Versions/Current/Updater.app/Contents/MacOS/Updater" \
    "Versions/Current/XPCServices/Downloader.xpc" \
    "Versions/Current/XPCServices/Installer.xpc"
  do
    if [[ ! -e "${EMBEDDED_FW}/${required}" ]]; then
      echo "Error: embedded Sparkle.framework is missing ${required}" >&2
      exit 1
    fi
  done
  echo "   Verified Sparkle.framework (Sparkle, Autoupdate, Updater.app, XPCServices)"
else
  echo "   ⚠ Sparkle.framework not found in .build — auto-update NOT embedded."
  echo "     Run 'swift build -c release --arch arm64' first (Sparkle is an SPM dep)."
fi

# Sparkle ships pre-signed ad-hoc and contains four *nested* code objects (two
# XPC services, Updater.app, and the Autoupdate tool). Code signing is inside-out:
# every nested object must carry our identity before the framework is sealed, and
# the framework before the app — otherwise notarization rejects the ad-hoc inner
# signatures even though `codesign --verify` passes locally.
sign_sparkle() {
  local identity="$1"
  local fw="${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
  [[ -d "$fw" ]] || return 0
  local ver="${fw}/Versions/Current"
  echo "   Signing Sparkle.framework inside-out..."
  for nested in \
    "${ver}/XPCServices/Downloader.xpc" \
    "${ver}/XPCServices/Installer.xpc" \
    "${ver}/Updater.app" \
    "${ver}/Autoupdate"
  do
    [[ -e "$nested" ]] || continue
    codesign --force --options runtime --timestamp --sign "$identity" "$nested"
  done
  codesign --force --options runtime --timestamp --sign "$identity" "$fw"
  codesign --verify --deep --strict --verbose=2 "$fw"
}

if [[ -n "$SIGN_IDENTITY" ]]; then
  # Strip extended attributes before signing. A stray com.apple.FinderInfo or
  # resource fork anywhere in the bundle makes `codesign --verify --strict` fail
  # with "resource fork, Finder information, or similar detritus not allowed",
  # and Gatekeeper rejects it on the user's machine — from a build that signed
  # without complaint here.
  xattr -cr "$APP_BUNDLE" 2>/dev/null || true
  echo "4. Signing with ${SIGN_IDENTITY}..."
  sign_sparkle "$SIGN_IDENTITY"
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
  # Re-assert the framework's own verification after the app-level --deep pass,
  # so a broken nested signature can't hide behind the enclosing app's seal.
  if [[ -d "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework" ]]; then
    codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
  fi
  spctl --assess --type execute --verbose=4 "$APP_BUNDLE" || true
else
  echo "4. Ad-hoc signing (unsigned build)."
  sign_sparkle -
  codesign --force --deep --sign - "$APP_BUNDLE"
fi

# ── Notarize + staple the .app itself (submission 1 of 2) ────────────────────
# Notarizing only the DMG leaves the .app INSIDE it without a ticket of its own.
# A normal install is still fine (Gatekeeper validates the DMG, and can check the
# app online), but Sparkle REPLACES the installed .app on auto-update — so the
# first launch after an update, with no network, has no ticket to validate and can
# be blocked. Fix: submit the signed .app, staple it, and only then build the DMG
# from the stapled bundle. Two submissions per release.
APP_NOTARIZED=0
if ! notarize_enabled; then
  echo "4b. Skipping .app notarization (SKIP_NOTARIZE set, no NOTARY_PROFILE, or unsigned build)."
else
  echo "4b. Notarizing the .app (submission 1 of 2)..."
  APP_ZIP="${BUILD_DIR}/${APP_NAME}.zip"
  rm -f "$APP_ZIP"
  ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"
  xcrun notarytool submit "$APP_ZIP" "${NOTARY_ARGS[@]}"
  rm -f "$APP_ZIP"

  echo "4c. Stapling the .app..."
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
  APP_NOTARIZED=1
fi

echo "5. DMG (from the stapled .app)..."
rm -f "$DMG_PATH"
create-dmg \
  --volname "$APP_NAME" \
  --window-pos 200 120 --window-size 660 400 \
  --icon-size 128 \
  --icon "${APP_NAME}.app" 160 185 \
  --app-drop-link 500 185 \
  --hide-extension "${APP_NAME}.app" \
  --no-internet-enable \
  "$DMG_PATH" "$APP_BUNDLE" >/dev/null

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "6. Signing DMG..."
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
else
  echo "6. Skipping DMG signing (no SIGN_IDENTITY)."
fi

# Notarization is required for distribution but not for a local reinstall.
# Set SKIP_NOTARIZE=1 to skip it (e.g. offline, or notary creds unavailable).
NOTARIZED=0
if ! notarize_enabled; then
  echo "7. Skipping DMG notarization (SKIP_NOTARIZE set, no NOTARY_PROFILE, or unsigned build)."
else
  echo "7. Notarizing DMG (submission 2 of 2)..."
  xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}"

  echo "8. Stapling notarization ticket..."
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
  NOTARIZED=1
fi

SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

echo ""
echo "=== Built ==="
echo "App:    ${APP_BUNDLE}"
echo "DMG:    ${DMG_PATH}"
echo "SHA256: ${SHA256}"

# ── Publish (guarded by --publish) ───────────────────────────────────────────
#
# Split target, deliberately:
#   DMG     -> GitHub release asset on $RELEASE_REPO (public, unauthenticated
#              download — that is what lets this repo stay private).
#   appcast -> $SITE_REPO/$FEED_PATH/appcast.xml, pushed to the Vercel site so
#              the feed has a stable HTTPS URL.
# The <enclosure url> therefore points at GitHub, not at doppoworks.com.
if [[ "$PUBLISH" != "1" ]]; then
  echo ""
  echo "Local build only. Re-run with --publish to sign the feed, cut the GitHub"
  echo "release, and push the appcast to the site."
  exit 0
fi

# Never publish something Gatekeeper will block on a user's Mac.
if [[ "$NOTARIZED" != "1" ]]; then
  echo "Refusing to publish an un-notarized DMG (NOTARIZED=0)." >&2
  echo "  Notarization was skipped or unavailable — fix credentials and re-run." >&2
  exit 1
fi
# The .app's own ticket is what keeps an OFFLINE first launch working after a
# Sparkle auto-update replaces the installed bundle. A DMG-only ticket is not
# enough, so an unstapled app is just as much a refusal as an unnotarized DMG.
if [[ "$APP_NOTARIZED" != "1" ]]; then
  echo "Refusing to publish: the .app inside the DMG was not notarized/stapled." >&2
  echo "  Sparkle replaces the installed app on update; without its own ticket an" >&2
  echo "  offline first launch can be Gatekeeper-blocked." >&2
  exit 1
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "Refusing to publish an ad-hoc-signed build (no SIGN_IDENTITY)." >&2
  exit 1
fi

command -v gh >/dev/null || { echo "gh CLI not found — required to publish the release." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not authenticated (run 'gh auth login')." >&2; exit 1; }

DEST_DIR="${SITE_REPO}/${FEED_PATH}"
APPCAST="${DEST_DIR}/appcast.xml"
[[ -d "$SITE_REPO/.git" ]] || { echo "SITE_REPO '${SITE_REPO}' is not a git checkout of the site that serves the feed" >&2; exit 1; }
mkdir -p "$DEST_DIR"

[[ -f "$SPARKLE_PRIVATE_KEY" ]] || { echo "SPARKLE_PRIVATE_KEY file not found: ${SPARKLE_PRIVATE_KEY}" >&2; exit 1; }
SIGN_UPDATE=$(find .build -name "sign_update" -type f 2>/dev/null | head -1 || true)
[[ -n "$SIGN_UPDATE" ]] || { echo "sign_update tool not found (build once so SwiftPM fetches Sparkle)." >&2; exit 1; }

# sign_update already emits the namespace prefix, i.e.
#   sparkle:edSignature="..." length="..."
# so it is interpolated verbatim into the enclosure — prefixing it again would
# produce an invalid sparkle:sparkle:edSignature attribute.
ED_ATTRS=$("$SIGN_UPDATE" "$DMG_PATH" -f "$SPARKLE_PRIVATE_KEY")

RELEASE_TAG="${RELEASE_TAG_PREFIX}${MARKETING_VERSION}-b${BUILD_VERSION}"
RELEASE_TITLE="${APP_NAME} ${MARKETING_VERSION} (${BUILD_VERSION})"
ENCLOSURE_URL="https://github.com/${RELEASE_REPO}/releases/download/${RELEASE_TAG}/${DMG_NAME}"

echo "9. Publishing DMG to ${RELEASE_REPO} as ${RELEASE_TAG} (channel: ${CHANNEL})..."
RELEASE_NOTES="Automated ${CHANNEL} build of ${APP_NAME}.

Version ${MARKETING_VERSION} (build ${BUILD_VERSION})
SHA256: ${SHA256}"

if gh release view "$RELEASE_TAG" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
  echo "   Release ${RELEASE_TAG} exists — uploading asset (clobbering)."
  gh release upload "$RELEASE_TAG" "$DMG_PATH" --repo "$RELEASE_REPO" --clobber
else
  GH_RELEASE_ARGS=(--repo "$RELEASE_REPO" --title "$RELEASE_TITLE" --notes "$RELEASE_NOTES")
  [[ "$CHANNEL" == "beta" ]] && GH_RELEASE_ARGS+=(--prerelease)
  gh release create "$RELEASE_TAG" "$DMG_PATH" "${GH_RELEASE_ARGS[@]}"
fi

# Verify the asset is reachable exactly the way Sparkle will fetch it:
# unauthenticated, following redirects.
echo "   Verifying enclosure URL is publicly reachable..."
ASSET_STATUS=$(curl -sS -o /dev/null -L -w '%{http_code}' "$ENCLOSURE_URL")
if [[ "$ASSET_STATUS" != "200" ]]; then
  echo "Error: ${ENCLOSURE_URL} returned HTTP ${ASSET_STATUS} (expected 200)." >&2
  echo "  Sparkle downloads unauthenticated — the release repo must be public." >&2
  exit 1
fi
echo "   ${ENCLOSURE_URL} -> HTTP 200"

# Beta items carry a channel tag; stable items are untagged. That is Sparkle 2's
# own semantics: an install opted into "beta" receives channel-tagged AND
# untagged items, while a stable install (empty allowed-channel set) receives only
# the untagged ones. A <sparkle:channel>stable</sparkle:channel> tag would hide
# the release from every stable install.
CHANNEL_TAG=""
[[ "$CHANNEL" == "beta" ]] && CHANNEL_TAG=$'\n      <sparkle:channel>beta</sparkle:channel>'
PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

if [[ ! -f "$APPCAST" ]]; then
  cat > "$APPCAST" <<XML
<?xml version="1.0" standalone="yes"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>${APP_NAME}</title>
    <link>${FEED_URL}</link>
    <description>Updates for ${APP_NAME}</description>
    <language>en</language>
  </channel>
</rss>
XML
fi

echo "10. Appending appcast item to ${APPCAST}..."

# The item is staged in a FILE, not an awk -v variable: BSD awk (the macOS
# default) rejects a -v value containing newlines with "newline in string" and
# then emits the feed *without* the item — a silent breakage that still passes a
# well-formedness check, because a <channel> with no <item> is valid XML.
ITEM_FILE=$(mktemp)
cat > "$ITEM_FILE" <<XML
    <item>
      <title>${APP_NAME} ${MARKETING_VERSION} (build ${BUILD_VERSION})</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${BUILD_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${MARKETING_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>${CHANNEL_TAG}
      <enclosure url="${ENCLOSURE_URL}"
                 ${ED_ATTRS}
                 type="application/octet-stream" />
    </item>
XML

TMP=$(mktemp)
awk -v itemfile="$ITEM_FILE" '
  /<\/channel>/ { while ((getline line < itemfile) > 0) print line }
  { print }
' "$APPCAST" > "$TMP" && mv "$TMP" "$APPCAST"
rm -f "$ITEM_FILE"

# Three assertions, because a broken feed strands every installed client and the
# failure mode is silent (Sparkle just never offers an update).
xmllint --noout "$APPCAST" \
  || { echo "Generated appcast is not well-formed XML — not pushing." >&2; exit 1; }
grep -q "<sparkle:version>${BUILD_VERSION}</sparkle:version>" "$APPCAST" \
  || { echo "Appcast is missing the item for build ${BUILD_VERSION} — not pushing." >&2; exit 1; }
grep -q "${ENCLOSURE_URL}" "$APPCAST" \
  || { echo "Appcast is missing the enclosure URL — not pushing." >&2; exit 1; }
echo "    Appcast now advertises $(grep -c '<item>' "$APPCAST") item(s); newest is build ${BUILD_VERSION}."

echo "11. Committing + pushing the feed (Vercel auto-deploys)..."
( cd "$SITE_REPO"
  git add "${FEED_PATH}/appcast.xml"
  git commit -m "release(claudeswitch): ${MARKETING_VERSION} b${BUILD_VERSION} (${CHANNEL})"
  git push )

# Record the version this channel now sits at, so the next run's vp_next() plans
# from what actually shipped. This lands AFTER the feed push on purpose: the
# appcast is the point of no return, and a VERSION bump for a release that never
# went out would silently skip a version number. The edit is left uncommitted in
# THIS repo — commit it alongside the release notes.
echo "12. Recording ${MARKETING_VERSION} for channel ${CHANNEL} in ${VERSION_FILE}..."
CHANNEL_KEY=$(printf '%s' "$CHANNEL" | tr '[:lower:]' '[:upper:]')   # STABLE | BETA
# Portable in-place edit (BSD sed needs the empty -i suffix); only the target
# channel's line changes, so the other channel's recorded version is untouched.
sed -i '' "s/^${CHANNEL_KEY}=.*/${CHANNEL_KEY}=${MARKETING_VERSION}/" "$VERSION_FILE"
grep -q "^${CHANNEL_KEY}=${MARKETING_VERSION}$" "$VERSION_FILE" \
  || { echo "Failed to record ${CHANNEL_KEY}=${MARKETING_VERSION} in ${VERSION_FILE}." >&2; exit 1; }
echo "    VERSION now: $(grep -E '^(STABLE|BETA)=' "$VERSION_FILE" | tr '\n' ' ')"

echo ""
# ── Prove the live feed advertises this build ────────────────────────────────
#
# Everything above can succeed while the appcast lands somewhere the web server
# never looks. That is not hypothetical: Doppo Console 0.1.1 b62 published to an
# empty feed because SITE_REPO was pinned in signing.env, outranking the script
# default, so the item was committed into the wrong checkout. The push succeeded,
# the XML was valid, and the script said Published.
#
# A local file write is not evidence. The only thing that proves a release is
# discoverable is fetching the URL compiled into the app and finding this build in
# it. Sparkle cannot tell an empty feed from "you are up to date", so without this
# you find out when a customer never receives an update.
echo "Verifying the live feed advertises build ${BUILD_VERSION}..."
FEED_OK=0
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS --max-time 20 "$FEED_URL" 2>/dev/null | grep -q "<sparkle:version>${BUILD_VERSION}</sparkle:version>"; then
    FEED_OK=1; break
  fi
  sleep 15
done
if [[ "$FEED_OK" != "1" ]]; then
  echo "" >&2
  echo "PUBLISHED, BUT THE FEED DOES NOT ADVERTISE IT." >&2
  echo "  feed:  ${FEED_URL}" >&2
  echo "  wrote: ${APPCAST}" >&2
  echo "" >&2
  echo "The DMG and the GitHub release are fine — this is a placement problem." >&2
  echo "Check that SITE_REPO (${SITE_REPO}) is the checkout that serves FEED_URL." >&2
  echo "Nothing will auto-update until the appcast is reachable at the URL above." >&2
  exit 1
fi
echo "   ${FEED_URL} advertises build ${BUILD_VERSION}."

echo "=== Published ==="
echo "Feed:    ${FEED_URL}"
echo "Release: https://github.com/${RELEASE_REPO}/releases/tag/${RELEASE_TAG}"
echo "DMG:     ${ENCLOSURE_URL}"

#!/bin/bash
# scripts/preflight-signing.sh — refuse to start a release we cannot finish.
set -euo pipefail

: "${SIGN_IDENTITY:?SIGN_IDENTITY is not set}"
: "${TEAM_ID:?TEAM_ID is not set}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# 1. The identity exists in the keychain.
security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY" \
  || { echo "preflight: identity not found: $SIGN_IDENTITY" >&2; exit 1; }

# codesign reports almost every signing failure as `errSecInternalComponent`,
# which reads like a key-access problem and usually is one. On 2026-09-09 it was
# not. The real reason appeared only in the system log — a trust evaluation that
# could not find an intermediate certificate which WAS present, and whose key id
# matched the leaf's issuer byte for byte. trustd was holding a stale cache, and
# `sudo killall trustd` fixed it outright.
#
# Reaching that one-line fix took an hour of certificate forensics, and a detour
# through `security set-key-partition-list` that changed nothing, because the
# error string on its own points at the wrong organ. So the log line that names
# the real cause is read HERE, while the failure is still fresh, and turned into
# the remedy.
#
# Deliberately NOT matched: the CSSMERR_CSP_ACL_ENTRY_TAG_NOT_FOUND exceptions
# that codesign also logs. They were present during the trustd failure and were
# pure noise — keying on them is exactly the wrong turn this function exists to
# stop the next person from taking.
diagnose_signing_failure() {
  local logged
  command -v log >/dev/null 2>&1 || return 0
  # The probe ran a second ago, so a one-minute window cannot pick up a
  # different codesign run. Failure to read the log is not itself an error:
  # this is a hint on top of the raw stderr above, never a gate.
  logged="$(log show --last 1m --style compact \
              --predicate 'process == "codesign"' 2>/dev/null || true)"
  [ -n "$logged" ] || return 0

  if grep -q "MissingIntermediate" <<<"$logged"; then
    cat >&2 <<'DIAG'

    Diagnosis: trustd is holding a stale trust cache.
      The log shows "Trust evaluate failure: [leaf MissingIntermediate]". Your
      certificate and private key are FINE - the intermediate is on disk and
      trustd simply is not seeing it. Nothing in the keychain needs repairing,
      and no password is required.

      Fix (trustd respawns on demand, so this is non-destructive):

          sudo killall trustd

      Then re-run this build. If it survives that, reboot: the per-user
      trustd.agent instances codesign talks to are cleared on login.
DIAG
    return 0
  fi

  # Unrecognised. Point at the evidence rather than guessing at a cause - the
  # guess is what cost the hour.
  cat >&2 <<'DIAG'

    No known signature in the log for this failure. Read it directly:
        log show --last 5m --style compact --predicate 'process == "codesign"'
    The line that matters usually contains "Trust evaluate failure" or names
    the Security call that returned first.
DIAG
}

# 2. It can actually SIGN. This is the check the pipeline was missing.
#    --timestamp also proves Apple's timestamp server is reachable, which
#    notarization requires and which fails late and confusingly otherwise.
printf 'int main(void){return 0;}\n' > "$TMP/probe.c"
cc -o "$TMP/probe" "$TMP/probe.c"
if ! codesign --force --timestamp --sign "$SIGN_IDENTITY" "$TMP/probe" 2>"$TMP/err"; then
  echo "preflight: signing failed before any build work was done:" >&2
  sed 's/^/    /' "$TMP/err" >&2
  diagnose_signing_failure
  exit 1
fi

# 3. The signature is real and carries the expected team.
got="$(codesign -dv --verbose=2 "$TMP/probe" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[ "$got" = "$TEAM_ID" ] \
  || { echo "preflight: signed as team '$got', expected '$TEAM_ID'" >&2; exit 1; }

# 4. Warn on an anchor that genuinely SHADOWS the system trust store.
#
# This used to warn on ANY copy of Apple Root CA in the login keychain. It fired
# on the release machine, and it was a false alarm: that copy is byte-identical to
# the anchor in SystemRootCertificates.keychain, carries no trust settings in
# either the user or admin domain, and sat there through both a working release
# and a failing one. Trust evaluation dedupes identical certificates, so a
# redundant copy changes nothing.
#
# The false alarm was not free. On 2026-09-09 it read as a lead while the real
# cause - a stale trustd - was somewhere else entirely, and `sudo killall trustd`
# fixed that without touching the keychain, with the duplicate still in place. A
# warning that cannot tell a duplicate from an impostor spends attention it has
# not earned, which is worse than staying quiet.
#
# What would ACTUALLY matter is a certificate calling itself Apple Root CA whose
# fingerprint is not among the system anchors. That is what is checked now.
anchor_fingerprints() { # <keychain path> -> one sha256 per line
  local kc="$1" f
  security find-certificate -a -c "Apple Root CA" -p "$kc" 2>/dev/null > "$TMP/anchors.pem" || return 0
  [ -s "$TMP/anchors.pem" ] || return 0
  rm -f "$TMP"/split*.pem
  awk -v d="$TMP" '/BEGIN CERT/{n++} n{print > (d "/split" n ".pem")}' "$TMP/anchors.pem"
  for f in "$TMP"/split*.pem; do
    [ -s "$f" ] || continue
    openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//'
  done
}
sys_fps="$(anchor_fingerprints /System/Library/Keychains/SystemRootCertificates.keychain)"
login_fps="$(anchor_fingerprints "$HOME/Library/Keychains/login.keychain-db")"
rogue=0
while IFS= read -r fp; do
  [ -n "$fp" ] || continue
  printf '%s\n' "$sys_fps" | grep -qxF "$fp" || rogue=$((rogue + 1))
done <<< "$login_fps"
[ "$rogue" -eq 0 ] \
  || echo "preflight: WARNING - $rogue cert(s) named 'Apple Root CA' in the login keychain are NOT among the system anchors; a real shadow, investigate before releasing" >&2

echo "preflight: signing OK ($SIGN_IDENTITY, team $got)"

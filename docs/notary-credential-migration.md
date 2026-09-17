# Notary credential: `notary-8B3CHTY93V`

**Done 2026-09-17.** Every Mac app signed by `Developer ID Application: Irven Cassio (8B3CHTY93V)`
now notarizes with one shared, account-scoped keychain profile, `notary-8B3CHTY93V`. ClaudeSwitch
1.0.3 shipped with it to both channels (b9 beta, b10 stable).

This file replaces an earlier plan written on the development Mac. That plan assumed a separate
build machine, a never-published ClaudeSwitch, and a Sparkle key to regenerate. None of that was
true — see "Corrections" below before acting on anything from the old version.

## What was wrong

- `xcrun notarytool` returned HTTP 401 for the profile `hivematrix`: the app-specific password
  behind it was dead (Apple revokes those when the Apple ID password changes).
- `hivematrix` is HiveMatrix's own profile name, and a dozen other apps borrowed it. Notarization
  is account-scoped, so sharing the *credential* is right; naming it after one product is not.

The corporate Apple ID (`icassio@luxotticaretail.com`, team 2E44W3L4XP) cannot notarize these
apps and was never the fix. The signing certificate itself was always fine (valid to 2031).

## What exists now

- **Credential:** an App Store Connect **Team API key** (Developer role), key ID `DJD83DWT5U`,
  file `~/.doppo-signing/AuthKey_DJD83DWT5U.p8` (mode 600). API keys do not die when the Apple ID
  password changes. Back the `.p8` up in the password manager — Apple lets you download it once.
- **Profile `notary-8B3CHTY93V`, stored twice** from that key with `store-credentials`:
  once with no `--keychain` (found by `build-dmg.sh`), once with
  `--keychain ~/Library/Keychains/login.keychain-db`. HiveMatrix's `scripts/notary-credentials.sh`
  always passes `--keychain` and preflights the login keychain with `security`, and only finds the
  second copy. Re-storing the key later means running both commands again.
- Both extra flags the scripts add, `--team-id` and `--apple-id`, work with an API-key profile.
- **Apps switched** (`NOTARY_PROFILE="notary-8B3CHTY93V"` in each gitignored `scripts/signing.env`):
  ClaudeSwitch, Canopy, canopy-browser, Glade, doppo-browser, doppo-terminal, doppo-console,
  doppo-desktop, doppo-files, doppo-mail, doppo-message, doppo-brain.
- **HiveMatrix:** default profile renamed in `scripts/notary-credentials.sh`, `setup-notary.sh`,
  `autodeploy-main.sh`, the notary test, and the terminal-lane runbook.
- The old `hivematrix` profile is still in the keychain. Delete it once each app above has
  notarized once under the new name:
  `security delete-generic-password -s com.apple.gke.notary.tool -a com.apple.gke.notary.tool.saved-creds.hivematrix`

## Adding another app

Set `NOTARY_PROFILE="notary-8B3CHTY93V"` and `NOTARY_TEAM_ID="8B3CHTY93V"` in its
`scripts/signing.env`. Nothing else is shared: the app still needs **its own** Sparkle keypair.

## Corrections to the earlier plan

- **ClaudeSwitch had already shipped.** The feed at
  `https://www.doppoworks.com/downloads/claudeswitch/appcast.xml` carried 1.0.1 b4, 1.0.2 b7 and
  1.0.2 b8 before this change. Its DMGs are released from `irvcassio/app-downloads`, not this repo,
  which is why "zero GitHub releases" looked true.
- **Do not regenerate ClaudeSwitch's Sparkle key.** Installed copies trust the public key
  `Il+JNd9dJJkbRWIsEuZWapO28yFBMarwApyT1WNRj4Q=`, whose private half is in the build Mac's login
  keychain (account `claudeswitch`) and at `~/.doppo-signing/claudeswitch-sparkle-ed25519.key`.
  A new key would make every existing install reject every future update. Back that file up.
  (`JrURG…` from older commit messages belonged to a key generated elsewhere; it is unrelated.)
- **Never delete `~/.doppo-signing`.** It holds every Doppo product's Sparkle key and the license
  signing key, not just ClaudeSwitch's.
- HiveMatrix's notary profile lives in `scripts/notary-credentials.sh`, not `release.mjs`.

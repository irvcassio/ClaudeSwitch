# Notary credential: set up `notary-8B3CHTY93V` and retire the borrowed `hivematrix`

**Written 2026-09-16 on the ClaudeSwitch Mac. Run the steps below on the machine that
holds the working notary credential (the Doppo/HiveMatrix build machine).**

Paste the "Prompt" section into Claude Code on that machine, or just follow it by hand.

---

## Background — what was found, and why

**The problem.** `xcrun notarytool` fails with HTTP 401 "Invalid credentials" for the profile
named `hivematrix`. The app-specific password behind it has expired or been revoked.

**Why `icassio@luxotticaretail.com` cannot fix it.** Certificate subjects on the ClaudeSwitch
Mac prove these are different Apple developer teams:

| Identity | Team (UID) | Type | Valid to |
|---|---|---|---|
| `Developer ID Application: Irven Cassio` | **8B3CHTY93V** | Mac, outside App Store | May 2031 |
| `Apple Distribution: Irven Cassio` | 8B3CHTY93V | App Store | Apr 2027 |
| `Apple Development: icassio@luxotticaretail.com` | **2E44W3L4XP** (OU `A2FWPR6E73`) | development only | Jan 2027 |
| `iPhone Distribution: Luxottica Retail NA` / `LUXOTTICA GROUP S.P.A.` | Luxottica teams | iOS only | — |

The Mac apps are signed by **8B3CHTY93V**, an *individual* account (`O=Irven Cassio`, no
organisation). The corporate address belongs to a different team, holds only a development
certificate, and as a managed Apple ID generally **cannot create app-specific passwords at
all**. So no password under it will ever notarize these apps. The notary credential must
belong to the Apple ID that owns 8B3CHTY93V — believed to be `cassio.irv@gmail.com`.

**Nothing is wrong with the Mac signing setup.** `Developer ID Application: Irven Cassio
(8B3CHTY93V)` is exactly the certificate a notarized DMG requires, its private key is present,
and it is valid until 2031. ClaudeSwitch was successfully signed with it on 2026-09-16 — the
chain verified to Apple Root CA. Only notarization is blocked. No account switch is needed.

**Why the name is changing.** `hivematrix` is *HiveMatrix's* profile name — HiveMatrix is its
own product, with its own repo and release pipeline. Canopy then referenced that same profile,
and ClaudeSwitch copied it from Canopy. Each borrowing couples one product's releases to
another product's credential: if HiveMatrix's profile is re-stored under a different Apple ID
or deleted, unrelated products break for no visible reason.

Sharing the *credential* is correct — notarization is account-scoped, and notarizing one app
grants no ability to forge another. Sharing a *product's name* for it is the mistake. Hence one
account-scoped profile, `notary-8B3CHTY93V`, referenced by every app signed under that team.

> This is the opposite of the rule for Sparkle keys. A Sparkle key is a per-product identity —
> holding it lets you push arbitrary updates to that app's installed base — so it must never be
> shared. `build-dmg.sh` enforces that distinction already.

---

## Prompt

> I need to replace an expired notarization credential and retire a profile name that several
> Mac apps borrowed from each other.
>
> Facts already established (do not re-derive):
> - The Mac apps are signed by `Developer ID Application: Irven Cassio (8B3CHTY93V)`, an
>   individual Apple developer account. That certificate is valid until May 2031 and works.
> - The notary profile `hivematrix` returns HTTP 401 — its app-specific password is dead.
> - `icassio@luxotticaretail.com` belongs to a *different* team (`2E44W3L4XP`) and cannot
>   notarize these apps. The correct Apple ID is the one owning 8B3CHTY93V, believed to be
>   `cassio.irv@gmail.com`.
> - `hivematrix` is HiveMatrix's own profile name. Canopy and ClaudeSwitch borrowed it. We are
>   replacing all uses with one account-scoped profile: `notary-8B3CHTY93V`.
>
> Do this:
>
> **1. Confirm the account.** Check which Apple ID owns team 8B3CHTY93V. Report what you find;
> do not guess. If `cassio.irv@gmail.com` is not it, stop and tell me.
>
> **2. Create a credential.** Prefer an App Store Connect **API key** over an app-specific
> password — an API key does not expire the way a password does, which is exactly what broke
> `hivematrix`. In App Store Connect (signed in as the owner of 8B3CHTY93V): Users and Access →
> Integrations → App Store Connect API → generate a key with the Developer role, and download
> the `.p8` (downloadable once only). 8B3CHTY93V is an individual account, so it is an
> *Individual* API Key and `--issuer` must be omitted.
>
> I will create the key and enter any password myself — do not ask me to paste a password or
> key contents into the conversation, and do not type credentials on my behalf.
>
> **3. Store it as `notary-8B3CHTY93V`.** Give me the command to run; `store-credentials`
> validates against Apple before saving, so a 401 there means the account is wrong rather than
> the password:
>
>     mkdir -p ~/.doppo-signing && chmod 700 ~/.doppo-signing
>     mv ~/Downloads/AuthKey_*.p8 ~/.doppo-signing/ && chmod 600 ~/.doppo-signing/AuthKey_*.p8
>     xcrun notarytool store-credentials notary-8B3CHTY93V \
>       --key ~/.doppo-signing/AuthKey_XXXXXXXX.p8 --key-id XXXXXXXX
>
> Verify with `xcrun notarytool history --keychain-profile notary-8B3CHTY93V`. It must return
> without a 401 before continuing.
>
> **4. Audit every Mac app on this machine for the borrowed name.** Find each one and report
> the list before editing anything:
>
>     find ~ -name "signing.env" -not -path "*/node_modules/*" -not -path "*/.Trash/*"
>     grep -rl "hivematrix" ~ --include="*.sh" --include="*.env" --include="*.mjs" \
>       --include="*.json" --include="*.yml" 2>/dev/null | grep -vE "node_modules|/\.build/|\.git/"
>
> Expected candidates: HiveMatrix itself, doppo-terminal, doppo-browser, doppo-console, Canopy,
> and any other app with a `scripts/build-dmg.sh`. On the ClaudeSwitch Mac only Canopy used it.
>
> **5. Update each one, in this order.** Only after step 3 verifies — renaming first would
> leave both names broken:
> - In each `scripts/signing.env`, set `NOTARY_PROFILE="notary-8B3CHTY93V"`.
> - For HiveMatrix, whose pipeline is `scripts/release.mjs` rather than `build-dmg.sh`, find
>   where the profile name is referenced and update it there.
> - `signing.env` is gitignored in these projects — confirm with `git check-ignore -v` and do
>   **not** commit it. If a profile name is hardcoded in a *committed* script, that change does
>   get committed.
> - Leave `hivematrix` stored in the keychain for now. Delete it only once every product has
>   notarized successfully under the new name.
>
> **6. Report** which products you changed, which still reference the old name, and anything
> that looked wrong.
>
> Do not touch any Sparkle signing key. Those are per-product and unrelated to this task.

---

## After the credential exists: publishing ClaudeSwitch

**Publish ClaudeSwitch from the ClaudeSwitch Mac, not this one.** Its Sparkle private key was
generated there on 2026-09-16 (login keychain, account `claudeswitch`, plus a mode-600 export at
`~/.doppo-signing/claudeswitch-sparkle-ed25519.key`). Publishing from a machine without that key
would sign the update feed with a different key, and installed copies would reject every future
update.

An API key is a portable file, so the simple path is to copy the `.p8` to the ClaudeSwitch Mac
and store the same profile there:

    xcrun notarytool store-credentials notary-8B3CHTY93V \
      --key ~/.doppo-signing/AuthKey_XXXXXXXX.p8 --key-id XXXXXXXX

Then, on the ClaudeSwitch Mac:

    cd ~/ClaudeSwitch && ./scripts/build-dmg.sh --beta --publish

That bumps `BETA` to 1.0.3, notarizes, cuts the GitHub release, and pushes the appcast. Already
in place there: `scripts/signing.env`, the Developer ID identity, the Sparkle keypair
(`SUPublicEDKey = JrURGRKjzfZNiPXLIkdtW3TuOIHu42X+Yx06qPevN3M=`), and
`CLAUDESWITCH_SPARKLE_READY=1`. Notarization is the only thing missing.

## Standing risk

**Back up `~/.doppo-signing/claudeswitch-sparkle-ed25519.key`** from the ClaudeSwitch Mac. It is
now ClaudeSwitch's permanent update-signing identity. If it is lost there is no recovery — only
telling users to reinstall by hand. The same applies to every other product's Sparkle key on
whichever machine holds it.

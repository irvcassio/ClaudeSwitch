# Move ClaudeSwitch releases to the build machine, and retire the borrowed `hivematrix`

**Written 2026-09-16. Run everything below on the build machine — the Mac that holds the working
notary credential and builds the Doppo products and HiveMatrix.**

Paste the "Prompt" section into Claude Code on that machine, or just follow it by hand.

## Decision: ClaudeSwitch is built and published only on the build machine

Every ClaudeSwitch build, signature, notarization and publish happens there. The Mac used for
development does not hold a Sparkle key or a `scripts/signing.env`, so it *cannot* publish —
`--publish` refuses outright, which is the intended guard. Local unsigned dev builds still work
there with no configuration.

This follows `VERSION`'s own rule, which this repo already states:

> keypair generation and every `--publish` happen on the build machine only

A Sparkle keypair **was** generated on the development Mac on 2026-09-16, which was a mistake —
wrong machine. It has since been destroyed there: the login-keychain item
(`account claudeswitch`, service `https://sparkle-project.org`) was deleted, and the exported
private key was shredded with `rm -P`. Nothing was lost, because **no ClaudeSwitch build has ever
been published** — no GitHub release, no appcast, and no `SUPublicEDKey` in any user's hands — so
no installed copy depends on that key.

> **The public key `JrURGRKjzfZNiPXLIkdtW3TuOIHu42X+Yx06qPevN3M=` is void.** It appears in earlier
> commit messages and in the repo history. Ignore it. A new keypair is generated in step 3 below,
> and its public half is the only one that matters.

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

> I need to (a) replace an expired notarization credential, (b) retire a profile name that
> several Mac apps borrowed from each other, and (c) make this machine the only place
> ClaudeSwitch is ever built and published.
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
> **3b. Generate ClaudeSwitch's Sparkle keypair HERE.** Clone the repo if it is not already on
> this machine (`git clone https://github.com/irvcassio/ClaudeSwitch.git ~/ClaudeSwitch`), then
> `swift build` once so Sparkle's tools are fetched, and run:
>
>     .build/artifacts/sparkle/Sparkle/bin/generate_keys --account claudeswitch
>
> Confirm first that no key already exists for that account
> (`generate_keys --account claudeswitch -p` should error). Do **not** import the key from the
> development Mac — it was destroyed there on purpose, and a key that never leaves the machine
> that uses it is the point. Export a backup and lock it down:
>
>     mkdir -p ~/.doppo-signing && chmod 700 ~/.doppo-signing
>     .build/artifacts/sparkle/Sparkle/bin/generate_keys --account claudeswitch \
>       -x ~/.doppo-signing/claudeswitch-sparkle-ed25519.key
>     chmod 600 ~/.doppo-signing/claudeswitch-sparkle-ed25519.key
>
> Then write `~/ClaudeSwitch/scripts/signing.env` (gitignored — verify with
> `git check-ignore -v scripts/signing.env` and never commit it):
>
>     BUNDLE_ID="com.irvcassio.ClaudeSwitch"
>     TEAM_ID="8B3CHTY93V"
>     SIGN_IDENTITY="Developer ID Application: Irven Cassio (8B3CHTY93V)"
>     NOTARY_PROFILE="notary-8B3CHTY93V"
>     NOTARY_TEAM_ID="8B3CHTY93V"
>     SPARKLE_PRIVATE_KEY="$HOME/.doppo-signing/claudeswitch-sparkle-ed25519.key"
>     SPARKLE_PUBLIC_KEY="<the public key generate_keys just printed>"
>     CLAUDESWITCH_SPARKLE_READY=1
>
> `chmod 600` it. Check `security find-identity -v -p codesigning` lists
> `Developer ID Application: Irven Cassio (8B3CHTY93V)` on this machine — if it does not, the
> certificate and its private key need to be installed here before anything can be signed, and
> that is a separate task. Report it rather than working around it.
>
> `CLAUDESWITCH_SPARKLE_READY=1` asserts two things; verify both before setting it: the keypair
> was generated for *this* product (it was, in this step), and `FEED_URL` resolves to
> ClaudeSwitch's own feed — `https://www.doppoworks.com/downloads/claudeswitch/appcast.xml`.
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
> **6. Publish the ClaudeSwitch beta** once steps 3 and 3b are verified:
>
>     cd ~/ClaudeSwitch && git pull && swift test && ./scripts/build-dmg.sh --beta --publish
>
> That bumps `BETA` from 1.0.2 to 1.0.3, notarizes, cuts the GitHub release, and commits the
> appcast to the site repo (`~/doppoworks`, which must be checked out here). It is the first
> ClaudeSwitch release ever published, so there is no existing feed to be compatible with.
>
> **7. Report** which products you changed, which still reference the old name, the new Sparkle
> public key, and anything that looked wrong.
>
> Do not touch any *other* product's Sparkle key — those are per-product identities with shipped
> installed bases, and regenerating one would break its users' updates. ClaudeSwitch's is the
> only one being created here, and only because it has never shipped.

---

## Standing risks

**Back up `~/.doppo-signing/claudeswitch-sparkle-ed25519.key`** once it exists on the build
machine. It is ClaudeSwitch's permanent update-signing identity. If it is lost there is no
recovery — only telling users to reinstall by hand. The same applies to every other product's
Sparkle key.

**Do not generate a ClaudeSwitch Sparkle key anywhere else again.** After the first publish, the
public half is baked into every shipped copy, and a second key would be rejected by every install
that already exists. One key, one machine, from here on.

**The development Mac must stay unable to publish.** It has no `scripts/signing.env` and no
Sparkle key, so `--publish` refuses. If someone recreates a `signing.env` there to get signed
local builds, leave the `SPARKLE_*` lines and `CLAUDESWITCH_SPARKLE_READY` out of it.

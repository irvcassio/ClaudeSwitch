# Private-CA trust, made seamless

**Date:** 2026-09-16
**Status:** approved, implementing

## The problem

A first-time user points ClaudeSwitch at an internal HTTPS gateway and gets:

> Cannot reach the server at https://10.80.114.11:4443: the server's TLS certificate is not
> trusted on this Mac. Add the CA that signed it to your login keychain — `security
> add-trusted-cert -r trustRoot -p ssl -k ~/Library/Keychains/login.keychain-db <ca.crt>` —
> after checking its fingerprint with the server's administrator. Claude Code and Claude
> Desktop use the same trust store.

To get from there to a working session they must know to fetch a CA from somewhere, verify a
fingerprint, and run a `security` command. Three manual steps, and the last sentence is wrong.

## The finding that reframes it

**Claude Code does not read the macOS keychain.** Measured on 2026-09-16 against
`https://10.80.114.11:4443`, with Node v26.5.0 (what Claude Code runs on):

| Consumer | TLS stack | Reads macOS keychain? |
|---|---|---|
| ClaudeSwitch's own probe | URLSession | yes |
| Claude Desktop | Electron / Chromium | yes |
| **Claude Code CLI** | **Node** | **no** |

```
node (no extra CA)              -> FAIL: UNABLE_TO_VERIFY_LEAF_SIGNATURE
NODE_EXTRA_CA_CERTS=ca.crt node -> status 401   (TLS fine, no key supplied)
```

So a user who follows the current message *exactly* ends up with ClaudeSwitch green, Claude
Desktop working, and **Claude Code still failing** — with no hint why. That is the same class
of defect as 38644de: confidently precise advice pointing the wrong way.

The lucky part: `NODE_EXTRA_CA_CERTS` is an environment variable, and putting environment
variables into `settings.json` is what this app already does for thirteen other keys. The CLI
half of the fix is one managed key, not new machinery.

## Two constraints discovered while probing

**The CA is not in the handshake.** aiserver's nginx sends only the leaf (1 certificate). We can
read the *issuer name* from the leaf — `aiserver internal CA` — but the anchor itself must be
fetched or supplied.

**The app is unsandboxed.** No entitlements file, no sandbox in the built bundle. Touching trust
settings is therefore a question of judgment, not capability.

## Design

### 1. When it runs

`TLSTrust.check(baseURL)` returns `.trusted` / `.untrusted(leaf:)` / `.notTLS` / `.unreachable`.
One minimal handshake, no request body, run when a base URL is committed (debounced) and again
as probe step 0.

No "is this host internal?" heuristic. The handshake is ground truth: a gateway with a public CA
resolves `.trusted` and renders **nothing at all**, so the proactive check costs nothing on a
healthy destination and we never have to define "internal".

To name the issuer without trusting anything, a `URLSessionDelegate` captures the chain from the
authentication challenge via `SecTrustCopyCertificateChain`, records a summary, and then
**rejects** the challenge. We read the certificate; we never complete real traffic over an
unverified connection.

### 2. The trust sheet

When untrusted, a `TLS` row appears under Base URL — *"signed by `aiserver internal CA`, not
trusted on this Mac"* — with a **Fix…** button.

The sheet obtains a candidate anchor by fetching it from the gateway, or **Choose file…**. There
is no standard path for this, so a short list is tried in order and the first candidate that
verifies the captured leaf wins:

```
/ca.crt   /ca.pem   /ca-bundle.crt   /rootCA.crt
```

Trying several is safe rather than noisy *because* of the validation below: a candidate that does
not parse, or parses but does not verify the leaf, is discarded before the user is ever shown a
fingerprint to confirm. A wrong hit cannot become a trusted anchor.

It then runs **one** validation that subsumes three questions: build a trust evaluation for the
captured leaf with the candidate as the *only* anchor (`SecTrustSetAnchorCertificatesOnly(true)`,
basic X509 policy, no hostname check — the real connection verifies that later). If it evaluates
clean, the candidate is a usable anchor *and* is the one that signed this server *and* chains
correctly. A `CA:FALSE` self-signed server certificate fails here, which is the documented reason
keyportal's own certificate could not be used as an anchor.

Then the gate: subject, issuer, validity and the full SHA-256 in hex groups, plus a field
requiring the **last four pairs typed by hand** (`04D06226` for aiserver). Case-insensitive,
colons optional, exact match or the install button stays disabled. A checkbox gets clicked past;
typing forces the comparison that is the only thing making the bytes trustworthy.

**The honest caveat.** Fetching `/ca.crt` happens over a connection we cannot verify — it is
self-certifying, and a MITM would serve its own CA and leaf which would verify perfectly against
each other. That fetch therefore uses a dedicated session that is **never reused for API
traffic**, and the code comment says plainly that the typed fingerprint is the only thing
breaking the circularity, so nobody later "cleans up" the gate.

### 3. What gets installed — two halves, reported separately

| Half | Action | Fixes | Privileges |
|---|---|---|---|
| CLI | PEM to `~/Library/Application Support/ClaudeSwitch/anchors/<short>.crt`, rebuild `bundle.pem`, set managed `NODE_EXTRA_CA_CERTS` | Claude Code | none |
| Desktop | `security add-trusted-cert -r trustRoot -p ssl -k login.keychain-db` | Claude Desktop, ClaudeSwitch's own probe | OS auth prompt |

Scoped deliberately: `-p ssl` only, **login keychain only** — never `-d`, never the System
keychain. If the user cancels the OS prompt the CLI half still stands, and the sheet says exactly
that rather than reporting blanket failure.

**Undo lives in the same sheet:** `remove-trusted-cert`, delete the anchor, rebuild the bundle,
drop the managed key when no anchors remain. An app that installs a trust anchor must be able to
remove it from the same place.

`Profile` gains `caAnchorFingerprint: String?`, recording *which* anchor a destination needs.
`environment()` emits `NODE_EXTRA_CA_CERTS` pointing at the bundle when it is set. The existing
hand-written `init(from:)` decodes every field with `decodeIfPresent`, so stored profiles migrate
with no special handling.

### 4. Correctness and testing

The false *"same trust store"* sentence is replaced by per-consumer truth. This lands regardless
of the rest.

`security` invocations go behind a `TrustCommandRunner` protocol. Tests assert **the command
built, not its execution** — no test may mutate a real keychain.

Unit-testable pure functions:
- SHA-256 fingerprint formatting, and the last-four-pairs match (case, colons, whitespace)
- PEM/DER parsing, including multiple concatenated blocks
- bundle concatenation from a set of anchor files
- `add`/`remove` argv construction
- managed-key add/remove round-trip through `ClaudeSettingsStore`
- the corrected untrusted-certificate message

The anchor-verifies-leaf evaluation is exercised with a fixture leaf and CA pair embedded as PEM
strings.

### 5. Files

- **new** `Sources/ClaudeSwitchCore/Services/TLSTrust.swift`
- **new** `Sources/ClaudeSwitch/UI/TrustSheet.swift` — its own file; `SettingsWindow.swift` is
  already 737 lines and should not grow
- `Warning` gains an optional `remedy` so a warning can carry an action (3 call sites)
- `ClaudeSettingsStore.managedKeys` += `NODE_EXTRA_CA_CERTS`; `EnvironmentReport` shows it with
  reach `.both`
- `Profile` += `caAnchorFingerprint`

## Out of scope, deliberately

**Client-certificate authentication (mTLS).** Not because it is unlikely, but because supporting
it would be actively misleading. Two facts:

1. The gateway does not ask for one — no `ssl_verify_client` or `ssl_client_certificate` in
   nginx's `http` block or in the `litellm-tls` site. LiteLLM authenticates with a bearer key.
2. **Node has no environment path for client certificates.** `NODE_EXTRA_CA_CERTS` is CA-only;
   there is no `NODE_CLIENT_CERT`. So even if ClaudeSwitch presented a client certificate on its
   own probe, Claude Code could not present one — the probe would go green and every real turn
   would fail.

That is the false-green failure mode this work exists to eliminate. If a gateway ever demands
mTLS, the honest response is a **diagnosis** — detect the certificate request and report that
Claude Code cannot satisfy it — not a capability. Worth building as a check later; never as a
feature that implies it works.

**System-keychain or admin-wide trust.** Login keychain, SSL policy only.

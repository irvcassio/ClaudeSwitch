# ClaudeSwitch

<img src="Resources/AppIcon.png" width="128" align="right" alt="ClaudeSwitch icon">

A macOS menu bar utility that flips **Claude Code** between the Anthropic cloud and a model you
run yourself — Qwen in **LM Studio** on this Mac, behind a **LiteLLM** proxy, or in **Ollama** —
for both the CLI and Claude Desktop. One click (or ⌘T), no dotfile editing.

It does not just write settings. It asks the destination what it can serve, fits the limits to
what the server really enforces, checks that the destination works the way Claude Code will use
it, and says plainly which environment keys are in play.

## How the two halves are moved

**The CLI** reads the `env` block of `~/.claude/settings.json` at launch, and that block beats
shell exports. ClaudeSwitch owns exactly these twelve keys in it:

```
ANTHROPIC_BASE_URL                ANTHROPIC_DEFAULT_OPUS_MODEL        CLAUDE_CODE_MAX_OUTPUT_TOKENS
ANTHROPIC_AUTH_TOKEN              CLAUDE_CODE_EFFORT_LEVEL            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
ANTHROPIC_MODEL                   CLAUDE_CODE_MAX_CONTEXT_TOKENS      CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY
ANTHROPIC_DEFAULT_HAIKU_MODEL     CLAUDE_CODE_AUTO_COMPACT_WINDOW
ANTHROPIC_DEFAULT_SONNET_MODEL
```

Switching back to Anthropic removes them and, if that empties `env`, removes `env` too — so the
file returns to exactly what it was. Top-level `model` / `effortLevel`, which outrank the env
block, are set aside and put back.

**Claude Desktop** cannot be moved that way. It sets `ANTHROPIC_BASE_URL` and an empty
`ANTHROPIC_AUTH_TOKEN` itself for every Code session it hosts, and Claude Code ignores a
settings-file key the host already set (verified against Desktop 2.110 / Claude Code 2.1.200).
The other keys still reach it — so while the CLI is on Qwen, desktop sessions stay on Anthropic
with Qwen aliases in their environment, and a desktop subagent that asks for `haiku` fails.

The desktop's supported route is its own third-party mode. For a destination with **Also switch
Claude Desktop** on, ClaudeSwitch writes the same local configuration the desktop's *Developer →
Configure Third-Party Inference… → Apply Changes* writes, under
`~/Library/Application Support/Claude-3p/`, and sets the desktop to open on that side at its next
launch. Switching back sets it to open on Claude.ai, takes the key off disk, and re-applies any
configuration of your own. It never touches managed preferences, and the desktop's sign-in
screen still offers both sides. The desktop accepts a gateway only over HTTPS or plain HTTP on
this Mac — the relay below provides the latter for a remote proxy.

**The compatibility relay.** Claude Code 2.1.200 puts `{"role": "system"}` messages *inside*
`messages` for models it does not recognise. vLLM's `/v1/messages` — and so a LiteLLM proxy
passing requests through to it — rejects them, and every turn fails. With the relay on,
Claude Code talks to ClaudeSwitch on `127.0.0.1`, which folds those messages into the user turn
(what Claude Code itself falls back to) and streams everything else through untouched. New
LiteLLM destinations start with it on; the probe's *Request shape* check says when the server
no longer needs it. ClaudeSwitch must be running while relayed sessions are in use.

## Install

```bash
git clone https://github.com/irvcassio/ClaudeSwitch.git && cd ClaudeSwitch && ./scripts/build-dmg.sh
```

Then mount `build.noindex/release/ClaudeSwitch-*.dmg` and drag the app to `/Applications`.
Requires macOS 14+ and a Swift 6 toolchain (Xcode 16 or the standalone toolchain).

Once installed, the app updates itself through Sparkle — **Settings… → Updates** picks the
channel (Stable or Beta) and checks on demand.

## Releasing

Two channels, one build, one appcast. The visible version of each channel lives in
[`VERSION`](VERSION); `scripts/version-plan.sh` keeps Beta at or ahead of Stable.

```bash
./scripts/build-dmg.sh                      # local unsigned build, no publish
./scripts/build-dmg.sh --beta   --publish   # cut a Beta
./scripts/build-dmg.sh --stable --publish   # promote that Beta to Stable
```

A stable release is always those last two steps in order, with a soak in between: a
`--stable --publish` that would not advance past the current Stable is refused, because
nothing has been through Beta to promote.

`--publish` signs the appcast, uploads the DMG as a release asset on the public
`app-downloads` repo, commits the feed to the site repo, and only reports success after
fetching the live feed and finding the new build in it. It refuses outright to publish an
ad-hoc-signed, un-notarized, or unstapled artifact.

It also repoints the ClaudeSwitch card on the site's `/beta` download page at the new
build, in the same commit as the feed — Sparkle only reaches people who already have the
app, so without that step a release updates every install while the page still hands
first-timers the previous build. Both channels update the page and the link text says
which (`Download 1.0.2 (beta) →`). Only two lines are rewritten, the DMG filename and the
link row; the card's copy is never generated. If the card is missing the publish prints
the markup to add and carries on — the release is still live and still auto-updates.

Releases are cut on ONE machine — the build machine, which is the machine that
holds the site repo. The keypair is generated there and never leaves it, so
publishing from anywhere else is not a supported path. Before the first publish,
on that machine:

1. Generate ClaudeSwitch's **own** EdDSA keypair, on this build machine —
   `generate_keys --account claudeswitch` from Sparkle's `bin/`, then export it with
   `-x` to a file outside the repo. The exported private key is what signs the feed:
   `build-dmg.sh` passes its **path** to `sign_update -f`, so `SPARKLE_PRIVATE_KEY`
   holds a path, never key material. Generation and every publish happen here and
   nowhere else — the private key is never copied to another machine, never committed,
   and never pasted into a config file. Never reuse another app's key either: one
   compromise would forge updates for every product sharing it, with no way to rotate
   one without breaking the others.
2. Copy [`scripts/signing.env.example`](scripts/signing.env.example) to
   `scripts/signing.env` (gitignored) and fill in the signing identity, notary profile,
   and both key values.
3. Bootstrap an empty, well-formed `appcast.xml` at `downloads/claudeswitch/` in the
   site repo — done, alongside the eight sibling product feeds.
4. Verify `SUPublicEDKey` and `SUFeedURL` in the **shipping bundle** — build once
   without `--publish` and read them back out of `build.noindex/ClaudeSwitch.app`,
   confirming the key matches the keychain and the feed is ClaudeSwitch's own. Then set
   `CLAUDESWITCH_SPARKLE_READY=1` in `signing.env` to unlock `--publish`.

## Using it

1. **Settings… → + → the kind of server.** LM Studio and Ollama fill in their standard local
   address and need no key (ClaudeSwitch sends a placeholder token, so your Anthropic credential
   never goes to them). A LiteLLM proxy needs its address and your key, which goes into the
   login Keychain.
2. **Discover Models.** The server is asked what it can serve, and the model becomes a dropdown.
   LM Studio reports which instance is *loaded* and at what context; only loaded instances are
   offered, because asking for any other id loads another full copy of the weights. ClaudeSwitch
   never loads or unloads models — whatever pins yours (Doppo Console, `lms load --identifier`)
   decides. Ollama reports its served `num_ctx`. A LiteLLM proxy's real ceiling is **measured**:
   an oversized request is refused before generation, and the refusal states vLLM's
   `max_model_len`.
3. **Limits are fitted, not guessed.** The server stops at its length for prompt *and* reply
   together, and Claude Code asks for its output ceiling on top of a conversation near its
   window. So the window is the server length minus the output ceiling minus a 2% margin —
   262,144 becomes 240,518 with a 16,384 output ceiling. Setting the window to the full length is
   what makes long sessions hang: a LiteLLM proxy answers the overflow with HTTP 500 and Claude
   Code retries it. The editor shows the arithmetic and refuses a window that does not fit.
4. **Test Destination** runs what a switch runs, and switching refuses a destination that fails
   it: the listing (model served, loaded, a chat model), the limits against the server's real
   length, a plain turn, a streamed turn **at the configured output ceiling**, a tool call, and
   the request shape Claude Code 2.1.200 sends. A thinking model that spends a small budget
   thinking passes with a caution rather than failing.
5. **Switch** from the menu, or ⌘T to flip between Anthropic and the destination used last.
   New CLI sessions pick it up; the menu counts the ones still on the old destination. Relaunch
   Claude Desktop for it to open on the other side.

The menu shows where the CLI and the desktop each point, whether the active destination is up
(checked every minute without generating — LM Studio's check also notices an unloaded model),
the relay's state, and how many environment keys are set.

## Diagnostics

- **Environment keys.** Every key that decides where a turn goes: what the active destination
  wants, what `settings.json` holds (keys masked), whether they match, which are CLI-only because
  the desktop sets them itself, and any dotfile that exports the same key. A shell export matters
  the moment you switch back to Anthropic: settings.json no longer overrides it, so the CLI would
  quietly keep talking to the gateway while the menu says Anthropic.
- **Claude Desktop.** Which side it opens on, whether ClaudeSwitch's configuration is applied,
  and whether a management profile overrides it.
- Top-level overrides, running CLI sessions, and the backup.

## Safety properties

- **Order-preserving JSON.** `settings.json` is parsed and reprinted by a hand-rolled codec that
  keeps key order and keeps numbers as their original text, so `131072` never comes back as
  `131072.0` and your hand-written file doesn't get reshuffled.
- **Atomic writes.** Written to a temp file and swapped in with `replaceItemAt`. An interrupted
  switch cannot leave a half-written settings file.
- **A backup, once.** The first time ClaudeSwitch writes, it copies your file to
  `~/.claude/settings.json.claudeswitch-backup` and never touches that copy again.
- **Keychain, not plaintext.** Gateway keys live in the login Keychain under
  `com.irvcassio.ClaudeSwitch.authToken`.

### One caveat: first-write reformatting

The codec's printer is canonical — two-space indent, one array element per line. If your
`settings.json` is hand-written in a compact style (`"allow": ["Bash(*)"]` on one line), the
first write reformats it to the canonical style. Key order, values, and numeric text are all
preserved exactly; it is a reformat, not a change. If you diff your dotfiles, expect that one
whitespace-only churn on the first switch and none after.

## Gotchas that are not ours to fix

These are properties of Claude Code and of self-hosted models, encoded here as validation
warnings so you find out before you switch rather than mid-session:

| Symptom | Cause |
| --- | --- |
| Every turn: `400 … Input should be 'user' or 'assistant'` | Claude Code 2.1.200 sends `role: "system"` inside `messages`; vLLM's `/v1/messages` rejects it and Claude Code's fallback does not recognise the wording. Turn on the relay, or fold the messages on the server (a LiteLLM pre-call hook). The *Request shape* check catches it. |
| A long session repeats the same failing turn forever | prompt + `max_tokens` passed the server's length; the proxy answers 500 and Claude Code retries. Use the fitted limits. |
| The model is missing from `/model` | With gateway model discovery on, `/model` only lists ids containing `claude` or `anthropic`. Claude Code 2.1.200 itself runs other ids fine (verified with LM Studio's `qwen36-mlx8`). |
| Every reply is blank, but tokens are billed and `stop_reason` looks fine | The gateway's Anthropic **streaming** adapter opens a `content_block_start` and never sends the matching `content_block_stop`. Claude Code discards an unclosed block, so the text is thrown away while the turn "succeeds". Non-streaming works, which is why the gateway looks healthy and why an OpenAI-dialect client on the same box (Doppo Console, anything on `/v1/chat/completions`) is unaffected. No client-side setting works around it: fix it on the gateway. For LiteLLM, give the model the `hosted_vllm/` provider prefix instead of `openai/`, then upgrade the proxy. ClaudeSwitch's third probe check refuses to switch into this. |
| HTTP 404 on the first turn | The server has no Anthropic-compatible `/v1/messages` — an old LM Studio or Ollama, or an OpenAI-only endpoint. |
| HTTP 500 on the first turn | Effort level. Qwen3.8 rejects `high` and `max`; use `low`, `medium` or `xhigh`. |
| HTTP 403 naming models you didn't ask for | Your key is scoped to a model list that doesn't include the id you configured. |
| No conversation titles | `ANTHROPIC_DEFAULT_HAIKU_MODEL` unmapped, so Claude Code asks the gateway for `haiku`. |
| Context compacts at 200K no matter what | For an id not starting with `claude-`, Claude Code takes its window from `CLAUDE_CODE_MAX_CONTEXT_TOKENS` (default 200,000) and caps `CLAUDE_CODE_AUTO_COMPACT_WINDOW` at it. ClaudeSwitch writes both. |
| Desktop still answers as Claude after a switch | Expected unless the destination has *Also switch Claude Desktop* on — the desktop ignores the base URL and key in settings.json. |

ClaudeSwitch refuses outright on the ones that are unambiguous (a trailing `/v1`, an id the
server doesn't serve or hasn't loaded, a window that overflows the server, a rejected request
shape, a plain-HTTP network gateway for the desktop) and warns on judgment calls (a proxy
profile on a local server's port, plain HTTP with a key, an unsafe Qwen3.8 effort level).

## Layout

```
Sources/ClaudeSwitchCore/        testable core, no UI
  Model/JSONValue.swift          order-preserving JSON codec
  Model/Profile.swift            destination + validation warnings
  Model/Provider.swift           LM Studio / LiteLLM / Ollama / custom
  Model/LimitPlan.swift          fitting the window and output ceiling to the server
  Services/DestinationDiscovery  what a server serves, and its real length
  Services/GatewayProbe          the checks a switch runs; liveness
  Services/CompatibilityRelay    the loopback relay
  Services/DesktopGatewayStore   Claude Desktop's third-party configuration
  Services/EnvironmentReport     which keys are set, where, and what they reach
  Services/…                     settings store, keychain, diagnostics
Sources/ClaudeSwitch/            SwiftUI MenuBarExtra app (LSUIElement, no Dock icon)
Sources/ClaudeSwitchUpdates/     Sparkle updater service + the Updates settings pane
Tests/ClaudeSwitchCoreTests/     swift-testing
VERSION                          visible version per channel — the source of truth
scripts/build-dmg.sh             test → build → bundle → sign → notarize → DMG → publish
scripts/version-plan.sh          per-channel version arithmetic (--selftest)
scripts/preflight-signing.sh     proves the identity can sign before a build spends a number
```

```bash
swift test
# against real servers: LM Studio at its standard address, and a LiteLLM proxy if given
CLAUDESWITCH_LIVE=1 \
CLAUDESWITCH_LIVE_LITELLM_URL=http://proxy.example:4000 \
CLAUDESWITCH_LIVE_LITELLM_KEY=sk-… CLAUDESWITCH_LIVE_LITELLM_MODEL=qwen38-claude \
swift test --filter "Live destinations"
```

The live tests run discovery and the full probe, prove a window set to the server's full length
is caught, and run the real `claude` binary against a throwaway config written by the same
store a switch uses — directly and through the relay.

## License

MIT

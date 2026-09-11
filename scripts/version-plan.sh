#!/bin/bash
set -euo pipefail

# ClaudeSwitch — per-channel visible-version planner.
#
# Vendored verbatim from doppo-terminal/scripts/version-plan.sh (below this
# header) so every app in the family computes versions with the same, self-tested
# arithmetic. Re-copy it rather than editing one of the copies.
#
# VERSION is the only source of truth for the visible version, and
# Sources/ClaudeSwitchCore/AppVersion.swift is a stamped mirror of it (Settings
# has to read the value at compile time; it no longer decides it).
#
# Sourced by build-dmg.sh; run `./scripts/version-plan.sh --selftest` to check
# the arithmetic on its own.
# The two rules, both derived from `lead = max(stable, beta)`:
#
#   * Publishing BETA  → bump(lead). Beta always steps strictly past the current
#     high-water mark of BOTH channels, so it can never come out behind Stable.
#   * Publishing STABLE → lead itself (a *promotion*): Stable adopts the newest
#     already-shipped version, which is the leading Beta. It therefore rises to
#     meet Beta but never overtakes it. A Stable that would not advance (nothing
#     new to promote) is refused by the caller.
#
# Because both rules go through `max(stable, beta)`, a channel that has fallen
# behind self-heals on its next publish. Run `version-plan.sh --selftest` to see
# the invariant proven.

# ── Version arithmetic ───────────────────────────────────────────────────────
# A version is dotted decimal (e.g. 1.0.3). MAJOR.MINOR are held steady by
# convention and only the trailing component is the release counter, but every
# function here treats the whole string generically so a manual 1.0.x → 1.1.0
# bump keeps working without touching this file.

# Component-wise numeric compare. Echoes -1, 0, or 1 (a<b, a==b, a>b). Missing
# trailing components read as 0, so "1.0" and "1.0.0" compare equal.
vp_cmp() {
  local a="$1" b="$2"
  local IFS=.
  local -a pa=($a) pb=($b)
  local n=${#pa[@]}
  (( ${#pb[@]} > n )) && n=${#pb[@]}
  local i ai bi
  for (( i = 0; i < n; i++ )); do
    ai=${pa[i]:-0}; bi=${pb[i]:-0}
    if (( ai < bi )); then echo -1; return; fi
    if (( ai > bi )); then echo 1; return; fi
  done
  echo 0
}

# Echoes whichever of the two versions is greater (ties → the first).
vp_max() {
  if [[ "$(vp_cmp "$1" "$2")" == -1 ]]; then echo "$2"; else echo "$1"; fi
}

# Increments the last component: 1.0.3 → 1.0.4.
vp_bump() {
  local v="$1"
  local IFS=.
  local -a p=($v)
  local last=$(( ${#p[@]} - 1 ))
  p[$last]=$(( ${p[$last]} + 1 ))
  local out="${p[0]}"
  local i
  for (( i = 1; i < ${#p[@]}; i++ )); do out+=".${p[i]}"; done
  echo "$out"
}

# vp_next <stable> <beta> <channel> → the version the given channel's next
# release should carry. Enforces the beta-ahead invariant; see the rules above.
vp_next() {
  local stable="$1" beta="$2" channel="$3"
  local lead
  lead="$(vp_max "$stable" "$beta")"
  case "$channel" in
    beta)   vp_bump "$lead" ;;
    stable) echo "$lead" ;;   # promote the current lead (the newest Beta)
    *) echo "vp_next: unknown channel '$channel' (want beta|stable)" >&2; return 2 ;;
  esac
}

# ── Self-test ────────────────────────────────────────────────────────────────
# The invariant this file exists to guarantee, proven rather than asserted in a
# comment. Wired into `npm run typecheck` (scripts/typecheck.mjs), so a change
# that breaks Beta-ahead-of-Stable fails the merge gate.
vp_selftest() {
  local failures=0
  _expect() { # <label> <got> <want>
    if [[ "$2" != "$3" ]]; then
      echo "  ✗ $1: got '$2', want '$3'" >&2
      failures=$(( failures + 1 ))
    fi
  }

  _expect "cmp 1.0.3 < 1.0.4"  "$(vp_cmp 1.0.3 1.0.4)" "-1"
  _expect "cmp 1.0.10 > 1.0.9" "$(vp_cmp 1.0.10 1.0.9)" "1"
  _expect "cmp 1.0 == 1.0.0"   "$(vp_cmp 1.0 1.0.0)" "0"
  _expect "cmp 2.0.0 > 1.9.9"  "$(vp_cmp 2.0.0 1.9.9)" "1"
  _expect "max picks greater"  "$(vp_max 1.0.3 1.0.10)" "1.0.10"
  _expect "bump patch"         "$(vp_bump 1.0.3)" "1.0.4"
  _expect "bump rolls to 10"   "$(vp_bump 1.0.9)" "1.0.10"

  # The reported bug's exact state: Stable ahead of Beta. The next Beta build
  # must leap past Stable, with no hand-repair.
  _expect "self-heal: next beta > stable" "$(vp_next 1.0.3 1.0.0 beta)" "1.0.4"

  # A full release train, checking the invariant (beta >= stable, both monotonic)
  # holds after every step.
  local stable=1.0.3 beta=1.0.0 v
  # 1. cut a beta → 1.0.4, ahead of stable
  v="$(vp_next "$stable" "$beta" beta)"; beta="$v"
  _expect "train: beta1"        "$beta" "1.0.4"
  _expect "train: beta1>stable" "$(vp_cmp "$beta" "$stable")" "1"
  # 2. cut another beta → 1.0.5
  v="$(vp_next "$stable" "$beta" beta)"; beta="$v"
  _expect "train: beta2"        "$beta" "1.0.5"
  # 3. promote stable → adopts the leading beta (1.0.5), never overtakes it
  v="$(vp_next "$stable" "$beta" stable)"; stable="$v"
  _expect "train: stable promoted" "$stable" "1.0.5"
  _expect "train: stable<=beta"    "$([[ "$(vp_cmp "$stable" "$beta")" == 1 ]] && echo BAD || echo OK)" "OK"
  # 4. next beta moves ahead again → 1.0.6
  v="$(vp_next "$stable" "$beta" beta)"; beta="$v"
  _expect "train: beta after promote" "$beta" "1.0.6"
  _expect "train: beta>stable again"  "$(vp_cmp "$beta" "$stable")" "1"

  if (( failures > 0 )); then
    echo "version-plan selftest: ${failures} failure(s)" >&2
    return 1
  fi
  echo "version-plan selftest: ok"
}

# Run the selftest when invoked as `version-plan.sh --selftest`; otherwise this
# file is meant to be sourced for its vp_* functions.
if [[ "${1:-}" == "--selftest" ]]; then
  vp_selftest
fi

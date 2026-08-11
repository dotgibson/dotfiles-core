---
description: Research the modern-CLI stack for newer/better tools worth adopting
argument-hint: "[tool, category, or theme — optional]"
allowed-tools: Task, Read, Grep, Glob, WebSearch, WebFetch
---

# /tool-scout

Surface **cutting-edge tools and methods** the system does not yet use — the chore
no script can do, because it needs live research and taste. The goal is a
reviewable proposal, not a blind upgrade.

Focus for this run: **$ARGUMENTS** (empty = scan the whole modern-CLI stack).

Delegate the web research to the `tool-scout` subagent (it has WebSearch/WebFetch
and its own context) and relay its ranked proposal.

## Establish the baseline first

Before researching, read what the system already ships so you do not "discover"
something already in use:

- `PORTING-MATRIX.md` — the modern-CLI stack and per-distro package names.
- `zsh/00-tools.zsh`, `zsh/20-aliases.zsh` — what is detected and aliased.
- `mise/config.toml` — pinned language runtimes.
- `zsh/45-plugins.zsh`, `nvim/lazy-lock.json` — pinned plugins.

## What to research

1. **Direct upgrades.** For each tool in the stack (eza, bat, fd, ripgrep, zoxide,
   fzf, git-delta, btop, starship, atuin, yazi, tealdeer, duf, jq/yq, hyperfine,
   ouch, lazygit, sesh, mise), is there a major new release or feature worth
   adopting — or a newer tool that has overtaken it?
2. **New categories.** Tools/methods that fit this stack's philosophy (fast, modern
   replacements for classic Unix tools; ergonomic shell/tmux/nvim workflow) that
   the system has no equivalent for yet.
3. **Method shifts.** Better ways to do what the repo already does (e.g. plugin
   management, runtime pinning, prompt, history, session management).

For each candidate, verify it is real and current (check the project's repo and
latest release date — do not trust a single blog post), and note its packaging
across the distros in `PORTING-MATRIX.md` (this decides how hard it is to adopt).

## Standing re-verification: workarounds premised on upstream behaviour

Some Core code is not a preference but a **workaround for a specific upstream bug**,
and its justification expires when upstream changes. For these, "is there a newer
release?" is the wrong question — the right one is **"does the premise still hold?"**,
and only a measurement answers that; a changelog that does not mention the bug is not
evidence the bug is gone. Check the list below on every run. A version bump past the
one a workaround was verified against is a finding in its own right, not a footnote.

- **atuin — `_core_atuin_daemon_guard` (`zsh/00-tools.zsh`).** Verified against
  **18.19.0**: with the daemon enabled and its socket absent or stale, `atuin history
  start` exits 0, prints a well-formed history id, writes nothing to stderr, and
  **discards the entry** (`atuinsh/atuin#3561`). The guard's throttled re-probe, its
  one-way degrade, and every millisecond it spends on the prompt path are justified by
  that single fact — and it has already changed once, in the direction that makes it
  harder to notice (18.16.1 failed loudly; 18.19.0 fails silently).

  **The trigger is an upstream RELEASE, not the local install.** Compare the verified-
  against version above (grep it out of `zsh/00-tools.zsh`) with atuin's latest release
  — which you are already looking up for "Direct upgrades" — and report a re-verification
  as **required** when upstream has moved past it. Deliberately *not* keyed on the atuin
  installed here: this command has no `Bash` in `allowed-tools`, so it cannot read a local
  version, and it should not try. atuin is installed per-OS across eight machines, so
  there is no single "version in use" to compare against anyway — the fleet-correct
  question is whether a newer atuin exists that any of those machines could be on. The
  operator's own run of the recipe reports the version it measured, which is what closes
  the loop.

  ```bash
  (                                        # subshell: HOME/XDG never leak into your shell
    set -u
    SBOX=$(mktemp -d) || exit 1
    trap 'rm -rf "$SBOX"' EXIT             # and the sandbox always goes away
    export HOME=$SBOX XDG_RUNTIME_DIR=$SBOX/run XDG_DATA_HOME=$SBOX/share XDG_CONFIG_HOME=$SBOX/cfg
    mkdir -p "$XDG_RUNTIME_DIR" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME/atuin"
    export ATUIN_DAEMON__ENABLED=true ATUIN_DAEMON__SOCKET_PATH="$SBOX/not-listening.sock"
    DB="$XDG_DATA_HOME/atuin/history.db"
    rows() { python3 -c "import sqlite3;print(sqlite3.connect('$DB').execute('select count(*) from history').fetchone()[0])" 2>/dev/null || echo 0; }
    atuin history start -- seed >/dev/null 2>&1          # creates the DB
    before=$(rows)
    atuin history start -- canary >/dev/null 2>"$SBOX/err"; rc=$?
    after=$(rows)
    printf '%s\nrc=%s  stderr=%s  rows %s -> %s (delta %s)\n' \
      "$(atuin --version)" "$rc" \
      "$([ -s "$SBOX/err" ] && echo NONEMPTY || echo empty)" \
      "$before" "$after" "$((after - before))"
  )
  ```

  A throwaway `HOME`, so it never touches a real history DB, and it prints the version it
  measured, the exit code, whether stderr was empty, and the row delta — the four facts
  the verdict turns on. **Delta 0 with `rc=0` and empty stderr ⇒ the premise holds** and
  the guard still earns its place. Anything else
  — a non-zero exit, a message on stderr, or rows landing — means `zsh/00-tools.zsh`'s
  rationale block is now overclaiming, and the guard needs retiring, version-gating, or
  reshaping. Say which, and weigh it as an eight-repo change: retiring it removes a
  `precmd` hook from every interactive shell in the fleet.

  Also watch **`atuinsh/atuin#3382`** (the accept-but-silent socket — something is
  listening while the daemon behind it is dead, so a `connect(2)` succeeds and no cheap
  shell-side probe can tell it from health). That is the guard's documented blind spot
  and the reason `atuin/config.toml`, `examples/atuin-daemon.service` and
  `PORTING-MATRIX.md` all steer to the plain always-running unit over socket activation.
  If it is fixed, that steer can be relaxed. Refs #366, #382.

## How to report

Lead with any **required re-verification** from the section above — before the
shortlist, not inside it. It is not a proposal competing for attention on merit; it is
a claim in the repo that may have gone stale, and a stale one costs history rather than
convenience. State the version it was verified against, the newest upstream release you
found, and the recipe — those are the two versions you can actually establish; do not
assert what is installed on this or any other machine, because you cannot see it. If
nothing is due, say so in one line: silence reads the same as forgetting.

Then a ranked shortlist, each with:

- **What it is** and what it replaces or adds.
- **Why it fits** this system's philosophy (or why it does not).
- **Adoption cost** — packaging per distro, config churn, whether it touches the
  load order or the manifest.
- **Recommendation** — adopt / watch / skip, with a one-line rationale.

Propose changes only; do not edit config unless I ask. If I adopt one, the change
is Core (`PORTING-MATRIX.md`, `zsh/`, maybe `mise/`), so keep `core.manifest` in
step, add a `CHANGELOG.md` entry, and `make audit` before the PR.

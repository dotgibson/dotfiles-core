# scripts/audit/30-boundary.sh
# the Core⇄OS boundary: no OS-absolute path in a portable module
#
# A SOURCED FRAGMENT of scripts/audit-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: the PASS/SKIP/FAIL counters, $HERE (already cd'd
# to), the SCOPE_* flags, META_ALLOWLIST/META_PREFIXES, MANIFEST_PATHS/VENDOR_PATHS (parsed
# by 10-manifest.sh, §1), and the pass/skip/skip_env/fail/fail_detail/hdr/have helpers from
# scripts/lib/common.sh. NO EXIT TRAP HERE: the dispatcher installs the one that reaps the
# backgrounded behavioral suite, and `trap … EXIT` REPLACES rather than appends. The §-ids
# below are the STABLE gate ids — CLAUDE.md, CONTRIBUTING.md, VENDORING.md, PORTABILITY.md
# and the CHANGELOG all cite them — and the split did not renumber one; the NN- in this
# file's name carries run order only. See the header of scripts/audit-core.sh for the
# contract.
#
# ONE CROSS-FRAGMENT READ, deliberately visible: §5c derives its scan set from
# MANIFEST_PATHS, which 10-manifest.sh (§1) parses from core.manifest. The NN- ordering is
# what guarantees it is set by the time this file is sourced, and `set -u` makes a missing
# 10- fragment ABORT the run rather than let this gate skip — the loud failure, on purpose.

# ── 5c. Core⇄OS boundary (portable shell modules carry no OS-absolute paths) ──
# README's contract: "if it changes when the OS changes, it does NOT belong in Core."
# That rule is documented but was ungated — a hard-coded /opt/homebrew, /home/linuxbrew,
# or macOS ~/Library path could slip into a portable shell module and fan out to ten repos
# where it is simply wrong. Assert the sourced zsh modules stay OS-agnostic.
#
# THERE ARE NO PER-FILE EXCEPTIONS ANY MORE (#763). zsh/55-maint.zsh used to have one, for
# the `~/Library/LaunchAgents` literal in its built-in unit-directory fallback; deleting
# that fallback deleted the last OS-absolute path in Core, so the exemption guards nothing
# and is gone with it. Do not add another: an exception here is a standing invitation for
# a second literal to ride along beside the sanctioned one.
#
# Pure grep (busybox-safe), and CROSS-CUTTING rather than shell-scoped — the scope is
# the manifest, so it covers configs and the nvim tree too, and no --scope may skip it.
hdr "Core⇄OS boundary (no OS paths in portable Core files)"
# The scope is DERIVED FROM core.manifest, not from a hand-kept list. That list had
# quietly fallen behind the manifest three times: first the symlinked configs were
# ungated (a real /opt/homebrew drift was found downstream, baked into mise/config.toml),
# then bin/, maint/ and tmux/scripts/ — and when THOSE were added, zsh/completions/*,
# lib/ux.sh, lib/bootstrap-lib.sh and .bin/sync-upstream.sh were still missing. Every one
# of those omissions is the same bug, so the fix is structural: the manifest already IS
# the definition of "what is Core", and a file added to it is now scanned automatically.
# The blind spot cannot silently reopen, because reopening it would mean the file is not
# Core at all — which section 1 already fails on.
#
# It is also UNCONDITIONAL now (no SCOPE_SHELL guard). It used to be shell-scoped, but it
# now covers manifested nvim/, toml and config files too, and it is pure sed+grep over
# ~150 small files — cheap and cross-cutting, like the manifest/exec-bit/markdown gates.
# A narrowed --scope run must not be able to skip a fan-out-correctness check.
#
# EXCLUDED, deliberately and visibly — one class, and it is not a file of Core's:
#   · *.example — user-edited illustrations, not the live config.
bnd_fail=0
while IFS= read -r f; do
  case "$f" in
  *.example) continue ;; # user-edited illustration, not live config
  esac
  [[ -f "$f" ]] || continue
  # NOTHING is stripped. Comment-stripping was a false-negative machine: `#` is a comment
  # in shell and toml but the LENGTH OPERATOR in Lua, a delimiter inside a string is code
  # (`export P="#/opt/…"`), and a line inside a heredoc or a Lua long-bracket string is
  # runtime data however it starts. Each fix uncovered the next, because getting it right
  # needs a parser for all five grammars this now scans.
  #
  # So the rule is simply: a manifested Core file must not contain an OS-absolute path
  # ANYWHERE, prose included. Name the prefix instead of spelling it — "the Homebrew
  # prefix", not the literal. That costs one wording choice in a comment and buys a gate
  # with no hiding places at all.
  if grep -qE '/opt/homebrew|/home/linuxbrew|/usr/local/Cellar|/Library/|/mnt/c/' "$f"; then
    bnd_fail=1
    fail "OS-specific path in a portable Core file ($f) — it belongs in the OS layer, not Core"
  fi
done < <(
  # Expand the manifest: directory entries (nvim/) into their files, file entries as-is.
  #
  # _audit_ls, not plain `git ls-files`: this list feeds a CONTENT scan — each file is
  # cat'd and grepped for OS-absolute paths above — so it sits on the content side of the
  # rule in common.sh. It reads like a manifest question and is not one; the manifest
  # names the DIRECTORY, and every file under it is in scope whether or not git has seen
  # it yet. Without this, a new nvim/ lua module hardcoding a Homebrew prefix would pass
  # the boundary gate locally and only fail after `git add` — the same blind spot this
  # rule exists to close, wearing manifest clothing.
  for m in "${MANIFEST_PATHS[@]}"; do
    if [[ "$m" == */ ]]; then _audit_ls "$m"; else printf '%s\n' "$m"; fi
  done | sort -u
)
((bnd_fail)) || pass "every manifested Core file carries no OS-absolute path (scope derived from core.manifest)"

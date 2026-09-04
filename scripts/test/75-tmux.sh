# scripts/test/75-tmux.sh
# tmux status/popup scripts, tmux-claude routing, serve IP discovery
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── tmux status/popup scripts ─────────────────────────────────────────────────
# The tmux helper scripts fan out to nine repos and were covered only by bash -n + shellcheck
# (static). Their PORTABILITY CONTRACT — "emit a styled pill when there's something to show,
# emit NOTHING (segment vanishes) otherwise" — is pure logic that a bad edit could break
# silently (a status helper that errors blanks the whole bar). Drive the two data-driven
# ones hermetically against a stubbed PATH (same technique as the clip ladder): a fake
# `pmset`/`ip` pins the environment so the output is deterministic on every box.
# ── vim-tmux-navigator must not keep C-\ (#652-adjacent; see tmux/tmux.conf) ──
# The plugin binds FIVE keys at the tmux ROOT table, and the fifth (C-\ → select-pane -l)
# collides head-on with zsh's `Ctrl+\ → autosuggest-toggle` (zsh/40-bindings.zsh), which
# tmux/scripts/tmux-cheat.sh advertises by name. tmux wins that race in every shell pane,
# so the documented key was dead fleet-wide. tmux.conf disables just that mapping with an
# EMPTY @vim_navigator_mapping_prev.
#
# Two halves, and BOTH are load-bearing:
#   • the option is set, and set to EMPTY — any non-empty value re-binds a key
#   • it is set ABOVE the `run '…/tpm'` line — tpm sources the plugin's .tmux script, which
#     reads the option at that instant, so setting it afterwards is a silent no-op
# Neither half is visible to `tmux -f … source-file` in CI (no plugin checkout, no server),
# which is exactly why it is pinned here as text, like the gh/carapace order in 45-plugins.
hdr "tmux: vim-tmux-navigator's C-\\ mapping stays disabled (Ctrl+\\ belongs to zsh)"
TMUXCONF="$HERE/tmux/tmux.conf"
_vtn_line="$(grep -n "^[[:space:]]*set -g @vim_navigator_mapping_prev" "$TMUXCONF" | head -1)"
_tpm_line="$(grep -n "^[[:space:]]*run .*tpm/tpm" "$TMUXCONF" | head -1)"
if [[ -n "$_vtn_line" ]]; then
  pass "tmux.conf sets @vim_navigator_mapping_prev"
else fail "tmux.conf no longer sets @vim_navigator_mapping_prev — C-\\ is back on select-pane -l"; fi
if [[ "${_vtn_line#*:}" == *"''"* || "${_vtn_line#*:}" == *'""'* ]]; then
  pass "@vim_navigator_mapping_prev is EMPTY (the plugin's off switch)"
else fail "@vim_navigator_mapping_prev is non-empty — that binds a key: ${_vtn_line#*:}"; fi
if [[ -n "$_vtn_line" && -n "$_tpm_line" ]] && ((${_vtn_line%%:*} < ${_tpm_line%%:*})); then
  pass "@vim_navigator_mapping_prev is set BEFORE tpm runs (or it is a no-op)"
else fail "@vim_navigator_mapping_prev must precede the tpm run line (${_vtn_line%%:*} vs ${_tpm_line%%:*})"; fi
# The keys the plugin exists FOR must still be declared — this guard must never become a
# licence to drop the plugin's navigation along with its fifth key.
if grep -q "christoomey/vim-tmux-navigator" "$TMUXCONF"; then
  pass "vim-tmux-navigator is still loaded (C-h/j/k/l navigation intact)"
else fail "vim-tmux-navigator is gone — C-h/j/k/l no longer cross into nvim"; fi

hdr "tmux status/popup scripts (battery / netinfo, hermetic)"
TMUXBIN="$SANDBOX/tmuxbin"
BATTERY="$HERE/tmux/scripts/tmux-battery.sh"
NETINFO="$HERE/tmux/scripts/tmux-netinfo.sh"
_tmux_stub() { # _tmux_stub <name> <sh-body>
  rm -rf "$TMUXBIN"
  mkdir -p "$TMUXBIN"
  printf '#!/bin/sh\n%s\n' "$2" >"$TMUXBIN/$1"
  chmod +x "$TMUXBIN/$1"
}
# battery: a stubbed macOS `pmset` (87%, discharging) must yield a pill carrying "87%" —
# guarding the awk %-extraction the script's header explains (tmux mangles a literal '%').
_tmux_stub pmset 'printf -- "-InternalBattery-0 (id=1)\t87%%; discharging; 4:32 remaining present: true\n"'
out="$(PATH="$TMUXBIN:$PATH" bash "$BATTERY" 2>/dev/null)"
if [[ "$out" == *"87%"* && "$out" == *"#[fg="* ]]; then
  pass "tmux-battery renders a pill from pmset (87%)"
else fail "tmux-battery did not render the expected 87% pill (got: $out)"; fi
# netinfo: a tunnel iface up → an ORANGE pill naming the iface + addr.
_tmux_stub ip 'case "$*" in *"addr show tun0"*) echo "2: tun0 inet 10.8.0.2/24 scope global tun0" ;; esac'
out="$(PATH="$TMUXBIN:$PATH" bash "$NETINFO" 2>/dev/null)"
if [[ "$out" == *"tun0"* && "$out" == *"10.8.0.2"* ]]; then
  pass "tmux-netinfo renders the tunnel pill when a tun iface is up"
else fail "tmux-netinfo tunnel pill missing (got: $out)"; fi
# netinfo: no tunnel but a routable LAN → a GREEN pill with the LAN IP.
_tmux_stub ip 'case "$*" in *"route get"*) echo "1.1.1.1 via 192.168.1.1 dev en0 src 192.168.1.50 uid 0" ;; esac'
out="$(PATH="$TMUXBIN:$PATH" bash "$NETINFO" 2>/dev/null)"
if [[ "$out" == *"192.168.1.50"* ]]; then
  pass "tmux-netinfo falls back to the LAN pill"
else fail "tmux-netinfo LAN pill missing (got: $out)"; fi
# netinfo: nothing reachable → NOTHING printed (the segment vanishes — the portability
# contract that keeps it safe to ship to every repo). A non-empty output here is the bug.
_tmux_stub ip ':'
out="$(PATH="$TMUXBIN:$PATH" bash "$NETINFO" 2>/dev/null)"
if [[ -z "$out" ]]; then
  pass "tmux-netinfo emits nothing when no tunnel/LAN (segment vanishes)"
else fail "tmux-netinfo should be silent with no net, printed: $out"; fi

# ── tmux-claude.sh session routing (hermetic) ─────────────────────────────────
# Same reasoning as the block above, and the same technique: this script decides WHICH
# conversation you get, and every branch of that decision is invisible to the static
# gates (bash -n, lint). Getting it wrong is not a blank status bar but a lost thread —
# attaching to another repo's Claude, or spraying tmux errors instead of opening one. The
# `tmux` stub logs its argv and is programmable: TMUX_HAS_ON says from which has-session
# call onward the session "exists" (0 = never), TMUX_NEW_FAILS makes new-session fail.
# `cksum` is deliberately NOT stubbed — the duplicate-basename test is only meaningful if
# it exercises the real hash.
hdr "tmux-claude.sh session routing (hermetic)"
CLAUDESH="$HERE/tmux/scripts/tmux-claude.sh"
CBIN="$SANDBOX/claudebin"
_claude_env() { # _claude_env <cwd> [extra env assignments...]
  rm -f "$SANDBOX/tmux.log" "$SANDBOX/tmux.state"
  mkdir -p "$CBIN"
  cat >"$CBIN/tmux" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$TMUX_LOG"
case "$1" in
  has-session)
    n=$(cat "$TMUX_STATE" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s' "$n" >"$TMUX_STATE"
    [ "${TMUX_HAS_ON:-0}" -ne 0 ] && [ "$n" -ge "${TMUX_HAS_ON:-0}" ] && exit 0
    exit 1 ;;
  new-session) [ -n "${TMUX_NEW_FAILS:-}" ] && exit 1; printf '%s\n' '$42' ;;
  show-option) printf '%s\n' tmux-256color ;;
esac
exit 0
STUB
  cat >"$CBIN/git" <<'STUB'
#!/bin/sh
[ -n "${GIT_ROOT:-}" ] || exit 128
printf '%s\n' "$GIT_ROOT"
STUB
  printf '#!/bin/sh\nexit 0\n' >"$CBIN/claude"
  chmod +x "$CBIN/tmux" "$CBIN/git" "$CBIN/claude"
}
_claude_run() { # _claude_run <cwd> ; env comes from the caller
  ( cd "$1" && PATH="$CBIN:$PATH" TERM=xterm \
    TMUX_LOG="$SANDBOX/tmux.log" TMUX_STATE="$SANDBOX/tmux.state" \
    bash "$CLAUDESH" >/dev/null 2>&1 )
}

# 1. No `claude` on PATH → the gate fires: a status-line message, and NO session created.
#    PATH is the STUB DIR ALONE here, not stub-dir-first: deleting the stub is not enough when
#    the box running the suite has a real `claude` installed (this very repo's CI does), and the
#    gate is the first thing the script does, so it needs nothing else on PATH to reach it.
_claude_env
rm -f "$CBIN/claude"
#    bash by ABSOLUTE path: a `PATH=… bash …` prefix sets PATH before the command is looked
#    up too, so a bare `bash` would not be found in the stub dir and nothing would run.
( cd /tmp && PATH="$CBIN" TERM=xterm GIT_ROOT=/tmp/repo-a TMUX_HAS_ON=0 \
  TMUX_LOG="$SANDBOX/tmux.log" TMUX_STATE="$SANDBOX/tmux.state" \
  "$(command -v bash)" "$CLAUDESH" >/dev/null 2>&1 )
if grep -q '^display-message' "$SANDBOX/tmux.log" && ! grep -q '^new-session' "$SANDBOX/tmux.log"; then
  pass "tmux-claude: absent \`claude\` gates out (message, no session)"
else fail "tmux-claude: absent-binary gate wrong: $(tr '\n' '|' <"$SANDBOX/tmux.log")"; fi

# 2. Inside a git repo → the session is named + rooted from the GIT ROOT, not the cwd.
_claude_env
GIT_ROOT=/tmp/repo-a TMUX_HAS_ON=0 _claude_run /tmp
if grep -q 'new-session .*-s _popup_claude_repo-a_[0-9]* -c /tmp/repo-a' "$SANDBOX/tmux.log"; then
  pass "tmux-claude: session is keyed and rooted on the git root"
else fail "tmux-claude: git-root routing wrong: $(grep '^new-session' "$SANDBOX/tmux.log")"; fi

# 3. Outside a repo (git fails) → fall back to the cwd rather than erroring out.
_claude_env
GIT_ROOT='' TMUX_HAS_ON=0 _claude_run /tmp
if grep -q 'new-session .*-s _popup_claude_tmp_[0-9]* -c /tmp' "$SANDBOX/tmux.log"; then
  pass "tmux-claude: falls back to cwd outside a git repo"
else fail "tmux-claude: non-repo fallback wrong: $(grep '^new-session' "$SANDBOX/tmux.log")"; fi

# 4. Session already exists → REUSE. A second new-session would fork the conversation.
_claude_env
GIT_ROOT=/tmp/repo-a TMUX_HAS_ON=1 _claude_run /tmp
if ! grep -q '^new-session' "$SANDBOX/tmux.log" && grep -q '^attach' "$SANDBOX/tmux.log"; then
  pass "tmux-claude: reuses an existing session instead of forking one"
else fail "tmux-claude: reuse path wrong: $(tr '\n' '|' <"$SANDBOX/tmux.log")"; fi

# 5. Two repos sharing a basename must NOT collide onto one conversation — the path hash is
#    the only thing separating them, so this is the test that keeps `docs/` from being shared.
_claude_env
GIT_ROOT=/tmp/one/docs TMUX_HAS_ON=0 _claude_run /tmp
n1="$(grep -o '_popup_claude_docs_[0-9]*' "$SANDBOX/tmux.log" | head -1)"
_claude_env
GIT_ROOT=/tmp/two/docs TMUX_HAS_ON=0 _claude_run /tmp
n2="$(grep -o '_popup_claude_docs_[0-9]*' "$SANDBOX/tmux.log" | head -1)"
if [[ -n "$n1" && -n "$n2" && "$n1" != "$n2" ]]; then
  pass "tmux-claude: same-basename repos get distinct sessions ($n1 vs $n2)"
else fail "tmux-claude: duplicate-basename collision ($n1 vs $n2)"; fi

# 6. The created session is made inert to tmux, or keystrokes never reach Claude's TUI.
_claude_env
GIT_ROOT=/tmp/repo-a TMUX_HAS_ON=0 _claude_run /tmp
missing=""
for o in "key-table popup" "status off" "prefix None" "detach-on-destroy on"; do
  grep -q "set-option .*$o" "$SANDBOX/tmux.log" || missing="$missing [$o]"
done
if [[ -z "$missing" ]]; then
  pass "tmux-claude: sets key-table/status/prefix/detach-on-destroy on the session"
else fail "tmux-claude: session options missing:$missing"; fi

# 7. RACE: new-session loses to a sibling client, but the session now exists. The loser must
#    attach to it, not carry an empty target into every command below (there is no `set -e`).
_claude_env
GIT_ROOT=/tmp/repo-a TMUX_HAS_ON=2 TMUX_NEW_FAILS=1 _claude_run /tmp
if grep -q '^attach -t _popup_claude_repo-a_[0-9]*$' "$SANDBOX/tmux.log"; then
  pass "tmux-claude: a lost create race still attaches to the winner's session"
else fail "tmux-claude: race path did not attach by name: $(tr '\n' '|' <"$SANDBOX/tmux.log")"; fi

# 8. Genuine creation failure (nothing exists afterwards) → report it, and do NOT attach to an
#    empty target, which is what produces the confusing bare tmux error.
_claude_env
GIT_ROOT=/tmp/repo-a TMUX_HAS_ON=0 TMUX_NEW_FAILS=1 _claude_run /tmp
if grep -q '^display-message could not start' "$SANDBOX/tmux.log" && ! grep -q '^attach' "$SANDBOX/tmux.log"; then
  pass "tmux-claude: a real creation failure reports instead of attaching to nothing"
else fail "tmux-claude: creation-failure path wrong: $(tr '\n' '|' <"$SANDBOX/tmux.log")"; fi

# ── serve macOS IP discovery (_serve_advertise, hermetic) ─────────────────────
# serve()'s tunnel/LAN URL discovery is split into _serve_advertise so this
# platform-specific path is testable without the blocking http.server. macOS ships
# no ip(8), so we isolate PATH to a stub bin WITHOUT `ip` (forcing the route+ipconfig
# branch), stub ipconfig/route to canned answers, and assert the advertised URLs —
# mirroring the tmux-netinfo hermetic tests above. ui.zsh/30-functions.zsh are pure
# definitions (no source-time forks), so they source cleanly under the isolated PATH.
hdr "serve macOS IP discovery (_serve_advertise, hermetic)"
SRVBIN="$SANDBOX/srvbin"
_serve_net() { # _serve_net <ipconfig-sh-body> <route-sh-body>
  rm -rf "$SRVBIN"
  mkdir -p "$SRVBIN"
  printf '#!/bin/sh\n%s\n' "$1" >"$SRVBIN/ipconfig"
  printf '#!/bin/sh\n%s\n' "$2" >"$SRVBIN/route"
  chmod +x "$SRVBIN/ipconfig" "$SRVBIN/route"
  local t
  for t in awk cut head; do
    [[ -e "$SRVBIN/$t" ]] || ln -s "$(command -v "$t")" "$SRVBIN/$t" 2>/dev/null
  done
}
# 1) a tunnel iface up → the tunnel URL is advertised first, naming the iface.
_serve_net 'case "$2" in tun0) echo 10.8.0.2 ;; esac' ':'
ucheck "serve: macOS discovery advertises the tunnel addr first (no ip(8))" \
  "source '$UI' || exit 1; source '$FN' || exit 1; out=\$(_serve_advertise 8000); [[ \$out == *'(tun0)'* && \$out == *'10.8.0.2'* ]]" \
  PATH="$SRVBIN"
# 2) no tunnel, default route present → the LAN addr from route(8)+ipconfig.
_serve_net 'case "$2" in en0) echo 192.168.1.50 ;; esac' 'printf "   interface: en0\n"'
ucheck "serve: macOS discovery falls back to the default-route LAN addr" \
  "source '$UI' || exit 1; source '$FN' || exit 1; out=\$(_serve_advertise 8000); [[ \$out == *'(lan)'* && \$out == *'192.168.1.50'* ]]" \
  PATH="$SRVBIN"
# 3) tunnel up but NO default route → must NOT reprint the tunnel addr as (lan)
#    (guards the stale-$ip reuse the Copilot review flagged).
_serve_net 'case "$2" in tun0) echo 10.8.0.2 ;; esac' ':'
ucheck "serve: a failed default route does not reprint the tunnel addr as (lan)" \
  "source '$UI' || exit 1; source '$FN' || exit 1; out=\$(_serve_advertise 8000); [[ \$out == *'(tun0)'* && \$out != *'(lan)'* ]]" \
  PATH="$SRVBIN"

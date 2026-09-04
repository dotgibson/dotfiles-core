# scripts/test/55-capabilities.sh
# os.capabilities schema validator (scripts/check-capabilities.sh)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── os.capabilities schema validator (scripts/check-capabilities.sh) ─────────
# The strict half of #663. The reader (band 02) is asserted in scripts/test/62-loader-contract.sh, which is
# zsh-gated; this is NOT, and deliberately sits ABOVE that gate so it runs on every box
# — a bare container, a docs-scoped CI leg — where the reader itself cannot be exercised.
#
# It was written below the gate first, and never ran here at all: `have zsh` guards an
# early `exit 0`, so a bash assertion placed after it is silently absent rather than
# skipped. That is the green-because-absent result, and it is worth a comment because the
# file gives no other hint that its second half is conditional.
hdr "os.capabilities schema validator"
CAPCHK="$HERE/scripts/check-capabilities.sh"
CAPEX="$HERE/examples/os.capabilities.example"
if [[ ! -x "$CAPCHK" || ! -r "$CAPEX" ]]; then
  fail "check-capabilities.sh or the example declaration is missing"
else
  CAPV="$SANDBOX/capval"
  mkdir -p "$CAPV"
  # _cap_rejects <label> <sed-or-append expression applied to the example>
  _cap_rejects() { # <label> <file>
    if "$CAPCHK" "$2" >/dev/null 2>&1; then
      fail "validator: accepted $1 (it must not)"
    else
      pass "validator: rejects $1"
    fi
  }
  if "$CAPCHK" "$CAPEX" >/dev/null 2>&1; then
    pass "validator: the shipped example passes its own schema"
  else
    fail "validator: examples/os.capabilities.example does NOT satisfy the schema it documents"
  fi
  # An unknown key is the case that matters most: the reader ignores it in silence, so the
  # validator is the ONLY thing standing between a typo and a capability nothing dispatches.
  { cat "$CAPEX"; printf 'CLIPBOARD=wl-copy\n'; } >"$CAPV/unknown"
  _cap_rejects "an unknown key" "$CAPV/unknown"
  grep -v '^PKG_OWNS=' "$CAPEX" >"$CAPV/missing"
  _cap_rejects "a missing required key" "$CAPV/missing"
  sed 's/^PKG_SEARCH=.*/PKG_SEARCH=/' "$CAPEX" >"$CAPV/blank"
  _cap_rejects "a required key declared empty" "$CAPV/blank"
  sed 's/^SCHEDULER=.*/SCHEDULER=bsdinit/' "$CAPEX" >"$CAPV/sched"
  _cap_rejects "a SCHEDULER outside the enum" "$CAPV/sched"
  # `cron` IS in the enum as of #665, and this assertion used to say the opposite. Core's
  # own _maint_scheduler has always had a cron arm — it is what an OpenRC box (Alpine,
  # Gentoo) gets, having crontab and no systemd — so the schema was rejecting a value Core
  # itself produces, and Alpine's only honest declaration was `none`: "this box cannot hold
  # a timer", on a box that can. cron keeps no unit file of its own, so it takes no
  # SCHEDULER_UNIT_DIR.
  { grep -vE '^(SCHEDULER|SCHEDULER_UNIT_DIR)=' "$CAPEX"; printf 'SCHEDULER=cron\n'; } >"$CAPV/sched-cron"
  if "$CAPCHK" "$CAPV/sched-cron" >/dev/null 2>&1; then
    pass "validator: SCHEDULER=cron is accepted (OpenRC boxes — Alpine, Gentoo)"
  else
    fail "validator: SCHEDULER=cron was rejected — Core's own _maint_scheduler returns it"
  fi
  # systemd/launchd keep the unit in a file, and only the OS knows where. Core carries no
  # default any more, so a declaration that names the scheduler and not the directory is
  # incomplete — and the gate is the only place that can say so.
  grep -v '^SCHEDULER_UNIT_DIR=' "$CAPEX" >"$CAPV/nounitdir"
  _cap_rejects "SCHEDULER=systemd with no SCHEDULER_UNIT_DIR" "$CAPV/nounitdir"
  # ...and the reverse: cron has no unit file, so a directory there is a misunderstanding.
  { grep -vE '^(SCHEDULER|SCHEDULER_UNIT_DIR)=' "$CAPEX"
    printf 'SCHEDULER=cron\nSCHEDULER_UNIT_DIR=~/.config/systemd/user\n'
  } >"$CAPV/cron-unitdir"
  _cap_rejects "SCHEDULER=cron with a SCHEDULER_UNIT_DIR" "$CAPV/cron-unitdir"
  # A DIRECTORY, not a path. Core appends its own unit name, so a full path here would
  # produce .../dotfiles-maint.service/dotfiles-maint.service — and the reason the split
  # exists is that the unit NAME is what `systemctl enable` and `launchctl` use, so letting
  # a declaration rename it would decouple the unit Core writes from the one it enables.
  { grep -v '^SCHEDULER_UNIT_DIR=' "$CAPEX"
    printf 'SCHEDULER_UNIT_DIR=~/.config/systemd/user/dotfiles-maint.service\n'
  } >"$CAPV/unitdir-path"
  _cap_rejects "a SCHEDULER_UNIT_DIR that names a unit FILE" "$CAPV/unitdir-path"
  # MAINT_UNATTENDED_UPGRADE=0 must be REFUSED for the same reason PKG_COUNT_EXIT_TRUSTED=0
  # is, and with more at stake: `=0` reads as DECLARED, so an author writing it to mean "do
  # not upgrade this box unattended" would permit exactly what they meant to forbid — on an
  # engagement box, on a schedule, unwatched. Omission is how a repo refuses.
  { cat "$CAPEX"; printf 'MAINT_UNATTENDED_UPGRADE=0\n'; } >"$CAPV/unatt-zero"
  _cap_rejects "MAINT_UNATTENDED_UPGRADE=0 (omit it to refuse)" "$CAPV/unatt-zero"
  { cat "$CAPEX"; printf 'PKG_SEARCH=dnf search\n'; } >"$CAPV/dupe"
  _cap_rejects "a duplicate key" "$CAPV/dupe"
  { cat "$CAPEX"; printf 'this is not an assignment\n'; } >"$CAPV/junk"
  _cap_rejects "a line that is not KEY=value" "$CAPV/junk"
  # Trailing whitespace: the reader TRIMS it, so a value carrying it would validate one way
  # and behave another. Rejecting it keeps the two halves of #663 telling the same story.
  { grep -v '^PKG_REMOVE=' "$CAPEX"; printf 'PKG_REMOVE=sudo dnf remove -y \n'; } >"$CAPV/ws"
  _cap_rejects "a value with trailing whitespace" "$CAPV/ws"
  _cap_rejects "an unreadable file" "$CAPV/nope-does-not-exist"
  # `none` is a REAL scheduler answer (a container, a box with neither init), not a
  # placeholder — asserting it keeps someone from "tightening" the enum to systemd|launchd.
  # Drops SCHEDULER_UNIT_DIR along with the scheduler: `none` installs nothing, so a unit
  # directory there is a contradiction the gate now refuses (#665). The fixture has to say
  # what a real `none` declaration says.
  { grep -vE '^(SCHEDULER|SCHEDULER_UNIT_DIR)=' "$CAPEX"; printf 'SCHEDULER=none\n'; } >"$CAPV/sched-none"
  if "$CAPCHK" "$CAPV/sched-none" >/dev/null 2>&1; then
    pass "validator: SCHEDULER=none is accepted (containers, boxes with neither init)"
  else
    fail "validator: SCHEDULER=none was rejected — it is a real answer, not a placeholder"
  fi
  # TOOLS_OPTIN is OPTIONAL: absent means "Core's built-in default applies".
  grep -v '^TOOLS_OPTIN=' "$CAPEX" >"$CAPV/no-optin"
  if "$CAPCHK" "$CAPV/no-optin" >/dev/null 2>&1; then
    pass "validator: TOOLS_OPTIN is optional (absent ⇒ Core's default)"
  else
    fail "validator: TOOLS_OPTIN was treated as required — it is not"
  fi
  # An inline `#` is NOT a comment inside a value (#715). This file looks like an env file
  # and its own header is dense with `#`, so this is the natural thing to author — and every
  # other rule waved it through, leaving the declared verb as the whole string, comment and
  # all, for a shell to run.
  { grep -v '^PKG_OWNS=' "$CAPEX"; printf 'PKG_OWNS=dnf provides   # which package owns this\n'; } >"$CAPV/inline-hash"
  _cap_rejects "an inline '#' inside a value" "$CAPV/inline-hash"
  # ...while a genuinely indented COMMENT must still be skipped. These two travel together:
  # the comment arm used to be spelled `[[:space:]]*'#'*`, a glob that matches one space then
  # anything then '#', which conflated the two cases in both directions.
  { cat "$CAPEX"; printf '   # an indented comment, itself containing a # character\n'; } >"$CAPV/indented-comment"
  if "$CAPCHK" "$CAPV/indented-comment" >/dev/null 2>&1; then
    pass "validator: an indented comment is still skipped"
  else
    fail "validator: rejected an indented comment — the comment arm is too strict"
  fi
  # A dangling `--packages` used to spin forever: `shift 2` with one positional left returns
  # non-zero AND does not shift, so `|| true` produced an infinite loop. Nine OS repos call
  # this from `make lint`, where that is a job burning to the runner timeout. `timeout` is
  # the assertion here — without it a regression HANGS THE SUITE instead of failing it.
  if have timeout; then
    timeout 10 "$CAPCHK" "$CAPEX" --packages >/dev/null 2>&1
    _cap_dangle_rc=$?
    if [[ "$_cap_dangle_rc" -eq 2 ]]; then
      pass "validator: a dangling --packages exits 2 (does not loop forever)"
    elif [[ "$_cap_dangle_rc" -eq 124 ]]; then
      fail "validator: a dangling --packages HUNG — the arity guard on shift 2 is gone (#715)"
    else
      fail "validator: a dangling --packages should exit 2, got $_cap_dangle_rc"
    fi
  else
    skip "validator: dangling --packages (no timeout(1) to bound a possible hang)"
  fi

  # ── the keys #664 added ─────────────────────────────────────────────────────
  # All OPTIONAL, so the assertion that matters is that dropping every one of them still
  # validates: an OS repo that needs none must not be forced to declare them, and a
  # declaration written against the v5 schema must keep passing.
  grep -vE '^(PKG_ASSUME_YES|PKG_UPGRADE_PARTIAL|PKG_PENDING_MATCH|PKG_PENDING_FIELD|PKG_PENDING_FS|PKG_UPGRADE_PRE|PKG_CLEANUP|PKG_COUNT_REFRESH|PKG_COUNT_EXIT_TRUSTED)=' "$CAPEX" >"$CAPV/no-664"
  if "$CAPCHK" "$CAPV/no-664" >/dev/null 2>&1; then
    pass "validator: every #664 key is optional (absent ⇒ Core's default)"
  else
    fail "validator: a #664 key was treated as required — all of them are optional"
  fi
  # ...and that each one is actually IN the schema. Without this, adding a key to the
  # dispatcher but not to CAP_OPTIONAL would leave `up` reading a value the gate rejects —
  # the two halves disagreeing is the exact failure #663 put the schema here to prevent.
  # A VALID value per key, not a blanket `x`: PKG_PENDING_FIELD indexes an awk field and is
  # gated as a positive integer below, so `x` would fail here for the right reason and
  # report the wrong one ("not in the schema").
  _cap_664_ok=1
  for _cap_kv in PKG_ASSUME_YES=-y 'PKG_UPGRADE_PRE=sudo dnf makecache' \
    'PKG_CLEANUP=sudo dnf autoremove' 'PKG_UPGRADE_PARTIAL=sudo dnf upgrade' \
    'PKG_COUNT_REFRESH=dnf makecache' PKG_COUNT_EXIT_TRUSTED=1 \
    'PKG_PENDING_MATCH=^v[[:space:]]' PKG_PENDING_FIELD=3 'PKG_PENDING_FS=|' \
    MAINT_UNATTENDED_UPGRADE=1; do
    _cap_k="${_cap_kv%%=*}"
    { grep -v "^${_cap_k}=" "$CAPV/no-664"; printf '%s\n' "$_cap_kv"; } >"$CAPV/k-$_cap_k"
    "$CAPCHK" "$CAPV/k-$_cap_k" >/dev/null 2>&1 || {
      fail "validator: $_cap_k is not in the schema, but the dispatcher reads it"
      _cap_664_ok=0
    }
  done
  ((_cap_664_ok)) && pass "validator: all nine #664 keys are accepted by the schema"
  # PKG_PENDING_FIELD indexes an awk field. A typo does not fail at runtime — awk reads a
  # different column and `up` reports confident nonsense — so the gate is the only place
  # this can be caught.
  { grep -v '^PKG_PENDING_FIELD=' "$CAPEX"; printf 'PKG_PENDING_FIELD=two\n'; } >"$CAPV/field-word"
  _cap_rejects "a non-numeric PKG_PENDING_FIELD" "$CAPV/field-word"
  { grep -v '^PKG_PENDING_FIELD=' "$CAPEX"; printf 'PKG_PENDING_FIELD=0\n'; } >"$CAPV/field-zero"
  _cap_rejects "PKG_PENDING_FIELD=0 (awk fields are 1-based)" "$CAPV/field-zero"
  # `PKG_COUNT_EXIT_TRUSTED=0` reads as DECLARED, so an author writing it to mean "off"
  # would switch it firmly on — the worst direction for a key that decides whether a broken
  # resolve reads as "nothing to do". Omission is how you turn it off.
  { cat "$CAPEX"; printf 'PKG_COUNT_EXIT_TRUSTED=0\n'; } >"$CAPV/trust-zero"
  _cap_rejects "PKG_COUNT_EXIT_TRUSTED=0 (omit it to mean off)" "$CAPV/trust-zero"
  # --packages cross-checks the leading BINARY of each command-valued verb. The
  # PKG_PENDING_* keys are awk data (`^Inst[[:space:]]`, `3`, `|`), so running them through
  # that check would warn that `^Inst[[:space:]]` "is not in packages.txt" — nonsense
  # advice, and the kind that trains people to ignore the gate.
  printf 'dnf\nawk\n' >"$CAPV/pkgs.txt"
  { grep -v '^PKG_PENDING_' "$CAPEX"
    printf 'PKG_PENDING_MATCH=^Inst[[:space:]]\nPKG_PENDING_FIELD=2\nPKG_PENDING_FS=|\n'
  } >"$CAPV/pending-pkgs"
  _cap_pkgwarn="$("$CAPCHK" "$CAPV/pending-pkgs" --packages "$CAPV/pkgs.txt" 2>&1 >/dev/null)"
  case "$_cap_pkgwarn" in
  *PKG_PENDING_*)
    fail "validator: --packages checked a PKG_PENDING_* value as if it were a binary" ;;
  *)
    pass "validator: --packages skips the PKG_PENDING_* keys (they are awk data, not verbs)" ;;
  esac
fi

# F12 sits ABOVE the zsh gate below on purpose: it is pure bash and drives the register
# scripts against a fake fleet root, so `--scope none` and a box without zsh must still run
# it — the gate exits before anything after it.

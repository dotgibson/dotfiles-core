# scripts/test/62-loader-contract.sh
# loader glob + sort contract, os.capabilities reader (band 02)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── loader glob + sort contract (what is a fragment, and in what order) ───────
# The consumer-integration arm in scripts/test/60-loader.sh proves the real chain loads;
# this proves the RULES the loader uses to decide what a
# fragment IS and what order it runs in — which is now the WHOLE of its filtering logic,
# because v5 deleted CORE_PROFILE (#677). That deletion did not shrink this section, it
# promoted it: the glob used to be one of two filters with zero assertions against it while
# the ceiling had twelve, and it is now the only one. Both remaining rules fail SILENTLY — a
# fragment that never matches the glob simply does not run, and a mis-sorted pair still
# produces a perfectly working shell right up until one of them needed the other first.
#
# Lightweight STUB fragments (each echoes its NN) rather than the real modules, so this is
# fast and asserts the EXACT loaded set, independent of any module's side effects. The NN
# list mirrors the real band layout on purpose, outer bands included: "every fragment, in
# order" is a claim about the whole fan-out shape, not about Core alone.
hdr "loader glob + sort contract (zsh/loader.zsh)"
FRAG="$SANDBOX/frag"
mkdir -p "$FRAG"
ln -s "$HERE/zsh/loader.zsh" "$FRAG/loader.zsh"
for nn in 00 02 05 10 15 20 25 30 35 40 45 50 55 60 80 85 99; do
  printf 'print -r -- "F%s"\n' "$nn" >"$FRAG/$nn-stub.zsh"
done
# _frag_load <pre-source snippet> → what actually loaded, space-joined IN LOAD ORDER — the
# join IS the order assertion. The snippet runs before `source loader.zsh`, so a case can set
# an option on the CALLER that the loader must not be at the mercy of.
_frag_load() { zsh -f -c "ZSH_CFG='$FRAG'; $1; source '$FRAG/loader.zsh'" 2>/dev/null | tr '\n' ' ' | sed 's/F//g; s/ *$//'; }
_frag_is() { if [[ "$2" == "$3" ]]; then pass "loader: $1"; else fail "loader: $1 — got [$2] want [$3]"; fi; }
_ALL="00 02 05 10 15 20 25 30 35 40 45 50 55 60 80 85 99"
# (1) THE contract, replacing the CORE_PROFILE ceiling matrix this section used to be: every
# NN-*.zsh present is sourced, in NN order, with nothing skipped for any reason. A band is a
# reservation convention between the layers now — something an author respects so a later
# Core release cannot collide with a number an OS repo took — not something the loader
# enforces, which is why a squatted number is merely unconventional instead of destructive.
_frag_is "every NN-*.zsh loads, in NN order — nothing gated (#677 deleted the profile ceiling)" \
  "$(_frag_load 'true')" "$_ALL"
# (2) …and since the glob is now the ONLY filter, its shape is load-bearing on its own and
# was never asserted while the ceiling was there to share the blame. `[0-9][0-9]-` is exactly
# two digits and a dash: a one-digit `1-`, a three-digit `100-`, and a name with no NN prefix
# at all must be IGNORED — not mis-banded, not loaded at some improvised position. The
# un-prefixed case is the one that earns this test: loader.zsh's own symlink sits in the very
# directory it globs, and a glob widened to catch it would source the loader from inside
# itself. Name that symptom, because it is not a clean failure — the shell dies on recursion
# rather than reporting anything this harness could read.
printf 'print -r -- "X1"\n' >"$FRAG/1-toofew.zsh"
printf 'print -r -- "X100"\n' >"$FRAG/100-toomany.zsh"
printf 'print -r -- "Xnone"\n' >"$FRAG/noprefix.zsh"
_frag_is "malformed names (1-, 100-, no NN prefix) are ignored, not mis-banded" \
  "$(_frag_load 'true')" "$_ALL"
rm -f "$FRAG/1-toofew.zsh" "$FRAG/100-toomany.zsh" "$FRAG/noprefix.zsh"
# (3) a DANGLING fragment symlink must be skipped SILENTLY. The glob matches names, not
# contents, so a fragment whose repo file moved — the ordinary state mid-`git pull` or
# mid-vendor-sync in a dir that is nothing but symlinks — is still a match, and `source` on
# it writes to stderr, which the load-order smoke test (scripts/test/60-loader.sh) reads
# as a broken load-order chain. The loader's
# `[[ -r ]]` guard is what prevents that; before #677 it sat next to the profile gate and
# was easy to mistake for part of it, so pin it now that it stands alone.
ln -s "$FRAG/no-such-target" "$FRAG/65-dangling.zsh"
_frag_is "a dangling fragment symlink is skipped, not sourced" "$(_frag_load 'true')" "$_ALL"
_dang="$(zsh -f -c "ZSH_CFG='$FRAG'; source '$FRAG/loader.zsh'" 2>&1 >/dev/null)"
if [[ -z "$_dang" ]]; then pass "loader: a dangling fragment symlink is silent on stderr"; else fail "loader: dangling symlink wrote to stderr — [$_dang]"; fi
rm -f "$FRAG/65-dangling.zsh"
# (4) same-NN tiebreak: two 85- fragments must load in LEXICAL order (85-r10 BEFORE 85-r2),
# not numeric/natural order, and must do so even when the CALLER has set NUMERIC_GLOB_SORT —
# which is the entire reason the loader sorts with the `(@o)` parameter flag instead of the
# glob's own `n` qualifier. A same-NN pair is a misconfiguration the bands exist to prevent;
# being DETERMINISTIC about it is the point, so a host that hits one gets the same answer on
# every machine. Asserted through _frag_load rather than in isolation so the expectation also
# pins WHERE the tied pair lands in the full chain, and a got/want of the whole list says so.
printf 'print -r -- r2\n' >"$FRAG/85-r2.zsh"
printf 'print -r -- r10\n' >"$FRAG/85-r10.zsh"
_frag_is "a same-NN tie breaks lexically (85-r10 before 85-r2), even under NUMERIC_GLOB_SORT" \
  "$(_frag_load 'setopt numericglobsort')" \
  "00 02 05 10 15 20 25 30 35 40 45 50 55 60 80 r10 r2 85 99"
rm -f "$FRAG/85-r2.zsh" "$FRAG/85-r10.zsh"

# ── os.capabilities reader (zsh/02-capabilities.zsh) ─────────────────────────
# The reader is deliberately the PERMISSIVE half of #663: it skips anything it does not
# understand rather than breaking a login shell over a typo, and strictness lives in
# scripts/check-capabilities.sh (exercised further down, in bash, so it is covered even
# on a box with no zsh). What must be asserted here is that "permissive" does not mean
# "vague" — a value survives byte-for-byte, junk never lands in the table, and a box with
# NO declaration still gets a working shell.
#
# Every probe runs under `zsh -f`, which is the point: EXTENDED_GLOB is 10-options.zsh's,
# eight bands after this fragment, so the reader must parse with plain globbing. An earlier
# draft trimmed trailing space with ${v%%[[:space:]]##} and would have matched NOTHING here
# — silently, which is the failure mode this section exists to catch.
hdr "os.capabilities reader (band 02)"
if ! have zsh; then
  skip "os.capabilities reader (no zsh)"
else
  CAPD="$SANDBOX/caps"
  mkdir -p "$CAPD"
  # _cap_probe <capabilities-file-or-empty> <zsh snippet> → stdout of the snippet, run with
  # the fragment sourced exactly as the loader would source it (at top level, not in a
  # function — which is why the fragment cannot use `local`).
  _cap_probe() {
    local _f="$1" _snip="$2"
    zsh -f -c "CORE_CAPABILITIES_FILE='$_f'; source '$HERE/zsh/02-capabilities.zsh'; $_snip" 2>/dev/null
  }
  _cap_is() { if [[ "$2" == "$3" ]]; then pass "capabilities: $1"; else fail "capabilities: $1 — got [$2] want [$3]"; fi; }

  # A well-formed declaration, plus every shape the reader must IGNORE.
  cat >"$CAPD/good" <<'CAPS'
# a comment
   # an indented comment

PKG_INSTALL=sudo dnf install -y
PKG_SEARCH=dnf search
lowercase_key=ignored
Mixed_Case=ignored
not an assignment at all
PKG_EMPTY=
SCHEDULER=systemd
CAPS
  # Appended by printf rather than written in the heredoc above, because each of these
  # carries something a quoted heredoc would make invisible or a reader would "tidy":
  # trailing spaces, a deliberate duplicate, and a lone metacharacter.
  #
  # THE LONE METACHARACTER IS NOT HYPOTHETICAL: since #667 dotfiles-openSUSE declares
  # `PKG_PENDING_FS=|` — zypper's list-updates prints a pipe-delimited table and is the
  # only archive in the fleet whose count output is not whitespace-separated. The reader
  # must store it as DATA; a `|` that reached a shell as syntax would be a parse error at
  # login, on a box you are very likely SSH'd into to fix something else. Nothing else in
  # this fixture has a value that is pure punctuation.
  #
  # Grouped into one redirect: three consecutive `>>` to the same file is SC2129, and this
  # suite is held to the same shellcheck run as the rest of the repo.
  {
    printf 'PKG_TRAILING=dnf provides   \n'
    printf 'PKG_SEARCH=dnf whatprovides\n'   # duplicate: LAST wins
    printf 'PKG_PENDING_FS=|\n'
  } >>"$CAPD/good"

  # A multi-word value is the whole reason this is not blib_read_pkgs (which strips ALL
  # whitespace); interior spacing must survive verbatim.
  _cap_is "multi-word value survives verbatim" \
    "$(_cap_probe "$CAPD/good" 'print -r -- "[$_CORE_CAP[PKG_INSTALL]]"')" "[sudo dnf install -y]"
  _cap_is "trailing whitespace is trimmed" \
    "$(_cap_probe "$CAPD/good" 'print -r -- "[$_CORE_CAP[PKG_TRAILING]]"')" "[dnf provides]"
  _cap_is "duplicate key: the last one wins" \
    "$(_cap_probe "$CAPD/good" 'print -r -- "[$_CORE_CAP[PKG_SEARCH]]"')" "[dnf whatprovides]"
  _cap_is "a lone metacharacter value is data, not syntax (zypper's PKG_PENDING_FS)" \
    "$(_cap_probe "$CAPD/good" 'print -r -- "[$_CORE_CAP[PKG_PENDING_FS]]"')" "[|]"
  # Junk must not merely be tolerated — it must be ABSENT. A lowercase or mixed-case key
  # half-parsed into the table would be a capability nothing ever reads and nothing reports.
  #
  # zsh emits the keys UNSORTED, one per line, and bash sorts them. The obvious spelling —
  # `print -r -- "${(ko)_CORE_CAP}"` — silently does NOT sort: inside double quotes the
  # expansion is joined into a single word before the `o` flag applies, so `o` has one word
  # to order and returns hash order. It read as sorted and was not, which is precisely the
  # kind of assertion that passes for the wrong reason later. Sorting outside zsh depends on
  # no expansion-flag subtlety at all; LC_ALL=C pins collation across the four CI legs.
  _cap_keys="$(_cap_probe "$CAPD/good" 'print -rl -- ${(k)_CORE_CAP}' | LC_ALL=C sort | tr '\n' ' ')"
  _cap_is "only well-formed KEYS land in the table" "${_cap_keys% }" \
    "PKG_EMPTY PKG_INSTALL PKG_PENDING_FS PKG_SEARCH PKG_TRAILING SCHEDULER"
  # The parser's scratch variables must not leak into the interactive shell. They cannot be
  # `local` (the fragment is sourced at top level), so the explicit unset is load-bearing.
  _cap_is "parser scratch vars do not leak" \
    "$(_cap_probe "$CAPD/good" 'print -r -- "[${_cap_line-unset}${_cap_k-unset}${_cap_v-unset}]"')" \
    "[unsetunsetunset]"

  # _core_cap is THE accessor, and its contract is that "declared empty" and "never
  # declared" behave identically — otherwise every consumer needs both checks.
  _cap_is "_core_cap returns a declared value" \
    "$(_cap_probe "$CAPD/good" '_core_cap PKG_SEARCH')" "dnf whatprovides"
  _cap_is "_core_cap falls back for an ABSENT key" \
    "$(_cap_probe "$CAPD/good" '_core_cap PKG_NOPE "the fallback"')" "the fallback"
  _cap_is "_core_cap falls back for a DECLARED-EMPTY key" \
    "$(_cap_probe "$CAPD/good" '_core_cap PKG_EMPTY "the fallback"')" "the fallback"
  _cap_is "_core_cap with no fallback is the empty string" \
    "$(_cap_probe "$CAPD/good" 'print -r -- "[$(_core_cap PKG_NOPE)]"')" "[]"

  # THE ABSENCE CONTRACT, which is the one this issue argued about: a box with no
  # declaration must get a WORKING shell and a warning, never a hard failure. The whole
  # point is that you can still fix the box you are SSH'd into.
  _cap_is "missing file still yields a usable shell" \
    "$(_cap_probe "$CAPD/does-not-exist" 'print -r -- "[${#_CORE_CAP}][$(_core_cap PKG_INSTALL fallback)]"')" \
    "[0][fallback]"
  _cap_absent_rc="$(zsh -f -c "CORE_CAPABILITIES_FILE='$CAPD/does-not-exist'; source '$HERE/zsh/02-capabilities.zsh'" 2>/dev/null; printf '%s' "$?")"
  _cap_is "missing file exits 0 (a warning, not a failure)" "$_cap_absent_rc" "0"
  # ...and the warning goes to STDERR, so it never pollutes a $(...) capture from a login
  # shell — the way a warning on stdout silently corrupts every script that captures one.
  _cap_warn_out="$(zsh -f -c "CORE_CAPABILITIES_FILE='$CAPD/does-not-exist'; CORE_CAP_LOUD=1; source '$HERE/zsh/02-capabilities.zsh'" 2>/dev/null)"
  _cap_is "the missing-file warning is NOT on stdout" "[$_cap_warn_out]" "[]"
  _cap_warn_err="$(zsh -f -c "CORE_CAPABILITIES_FILE='$CAPD/does-not-exist'; CORE_CAP_LOUD=1; source '$HERE/zsh/02-capabilities.zsh'" 2>&1 >/dev/null | head -n1)"
  case "$_cap_warn_err" in
    *"no OS capability declaration"*) pass "capabilities: the missing-file warning is on stderr" ;;
    *) fail "capabilities: expected a stderr warning for a missing declaration — got [$_cap_warn_err]" ;;
  esac
  # THE REGRESSION GUARD FOR #715. Silence on a missing declaration is the DEFAULT, and
  # this is the assertion that keeps it that way: absence is the normal state for every
  # box in the fleet until an OS repo authors its declaration, so a default-on warning
  # here is two lines of stderr on every shell, every tmux split and every `zsh -i -c`
  # everywhere. It shipped that way once. Asserting the SILENCE, not just that the opt-in
  # works, is what makes flipping the default back a red test rather than a fleet-wide
  # regression nobody notices until it is vendored out.
  _cap_quiet_err="$(zsh -f -c "CORE_CAPABILITIES_FILE='$CAPD/does-not-exist'; source '$HERE/zsh/02-capabilities.zsh'" 2>&1 >/dev/null)"
  _cap_is "a missing declaration is SILENT by default (no CORE_CAP_LOUD)" "[$_cap_quiet_err]" "[]"
  # The hint must name a remedy that can actually work. It once said `--links-only` ALONE,
  # which re-ran the same `[[ -f ]]` guard that skipped the link — advice that could not
  # work while no repo had authored a declaration. Since #667 every OS repo has one, so
  # `--links-only` IS the remedy for a box that has not re-bootstrapped; the example is
  # still named for the case where the repo genuinely has no declaration. Both must appear,
  # because from inside the shell the two cases are indistinguishable.
  _cap_hint="$(zsh -f -c "CORE_CAPABILITIES_FILE='$CAPD/does-not-exist'; CORE_CAP_LOUD=1; source '$HERE/zsh/02-capabilities.zsh'" 2>&1 >/dev/null)"
  case "$_cap_hint" in
    *"os.capabilities.example"*)
      case "$_cap_hint" in
        *"--links-only"*) pass "capabilities: the warning names both remedies (relink, and authoring)" ;;
        *) fail "capabilities: the warning names the example but not --links-only — got [$_cap_hint]" ;;
      esac
      ;;
    *) fail "capabilities: the warning should name the example file — got [$_cap_hint]" ;;
  esac

  # A file with no trailing newline: the `|| [[ -n "$line" ]]` arm. Without it the last
  # assignment in a hand-edited declaration is dropped, silently.
  printf 'PKG_INSTALL=apk add' >"$CAPD/no-newline"
  _cap_is "a final line with no trailing newline is still read" \
    "$(_cap_probe "$CAPD/no-newline" 'print -r -- "[$_CORE_CAP[PKG_INSTALL]]"')" "[apk add]"

  # An EMPTY declaration is well-formed input, not an error: the audit is what says a
  # required key is missing.
  : >"$CAPD/empty"
  _cap_is "an empty declaration yields an empty table, not an error" \
    "$(_cap_probe "$CAPD/empty" 'print -r -- "[${#_CORE_CAP}]"')" "[0]"
fi

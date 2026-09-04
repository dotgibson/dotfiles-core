# scripts/test/33-bootstrap-matrix.sh
# the real-bootstrap matrix (scripts/fleet-bootstrap-matrix.py)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── the real-bootstrap matrix (scripts/fleet-bootstrap-matrix.py) ────────────
# THE FIRST TESTS THIS SCRIPT HAS EVER HAD, and the reason is #750. It is the static
# reader that turns each OS repo's own bootstrap-test.yml caller into the weekly sweep's
# matrix, so a defect here does not fail loudly — it silently drops a per-leg knob and the
# sweep runs on defaults that look exactly like a healthy run.
#
# The `postcheck` key is the sharp case. real-bootstrap.yml interpolates
# ${{ matrix.leg.postcheck }} into an env var and skips the assertion when it is empty, so
# a key this script never emits — a rename, a typo, a merge that drops the line — produces
# a hook that is a PERMANENT SILENT NO-OP. Every leg would report "NO postcheck declared",
# which is a sentence the workflow legitimately prints, and nothing anywhere would be red.
# That is the "advisory gate that never runs reads as coverage" failure both files warn
# about, and it is why the parity assertion below is worth more than the extraction ones.
_fbm="$HERE/scripts/fleet-bootstrap-matrix.py"
_fbm_wf="$HERE/.github/workflows/real-bootstrap.yml"
if [[ ! -r "$_fbm" || ! -r "$_fbm_wf" ]]; then
  skip "real-bootstrap matrix: script or workflow not readable (partial checkout?)"
elif ! have python3; then
  skip "real-bootstrap matrix (python3 not installed)"
elif ! python3 -c 'import yaml' 2>/dev/null; then
  # Same gate audit-core.sh section 6 uses, and CI installs PyYAML on every leg for it.
  skip "real-bootstrap matrix (python3 has no yaml module — pip install pyyaml)"
else
  hdr "real-bootstrap matrix (fleet-bootstrap-matrix.py)"

  # A scratch FLEET, not the real siblings: the assertions below are about what the parser
  # does with a given caller, and pinning them to whatever eight repos happen to be cloned
  # next to this one would make them fail for reasons that are not defects.
  _fbm_root="$SANDBOX/fleetmatrix"
  rm -rf "$_fbm_root"
  mkdir -p "$_fbm_root/dotfiles-core/scripts" "$_fbm_root/dotfiles-Probe/.github/workflows"
  printf '# scratch fleet\ndotfiles-Probe\n' >"$_fbm_root/dotfiles-core/scripts/os-repos.txt"

  # _fbm_caller <with-block-lines...> — write a synthetic caller and emit its one leg as JSON
  _fbm_caller() {
    {
      printf 'name: bootstrap\non: [pull_request]\njobs:\n  test:\n'
      printf '    uses: dotgibson/dotfiles-core/.github/workflows/bootstrap-test.yml@v5\n'
      printf '    with:\n      image: alpine:3.20\n      prep: apk add --no-cache bash zsh\n'
      local _l
      for _l in "$@"; do printf '      %s\n' "$_l"; done
    } >"$_fbm_root/dotfiles-Probe/.github/workflows/bootstrap.yml"
    python3 "$_fbm" "$_fbm_root" 2>"$_fbm_root/stderr"
  }
  # _fbm_key <json> <key> — the value of <key> on the first (only) leg
  _fbm_key() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0][sys.argv[1]])' "$2" 2>/dev/null; }

  # --- a declared postcheck arrives verbatim ----------------------------------
  _fbm_json="$(_fbm_caller 'bootstrap_postcheck: ./scripts/assert-provisioned.sh')"
  if [[ "$(_fbm_key "$_fbm_json" postcheck)" == "./scripts/assert-provisioned.sh" ]]; then
    pass "matrix: a declared bootstrap_postcheck reaches the leg verbatim"
  else
    fail "matrix: bootstrap_postcheck was not extracted from the caller — got '$(_fbm_key "$_fbm_json" postcheck)'"
  fi

  # --- absent is empty, and that is the whole opt-in property -----------------
  # If this ever yields anything but the empty string, every repo in the fleet starts
  # running something it never asked for on the far side of a real provision.
  _fbm_json="$(_fbm_caller 'bootstrap_timeout: 240')"
  if [[ -z "$(_fbm_key "$_fbm_json" postcheck)" ]]; then
    pass "matrix: a caller declaring no postcheck gets an empty one (the hook stays opt-in)"
  else
    fail "matrix: a caller with no bootstrap_postcheck produced '$(_fbm_key "$_fbm_json" postcheck)' — the hook is not opt-in"
  fi
  # The same fixture proves the timeout still rides through; these two share one reader.
  if [[ "$(_fbm_key "$_fbm_json" timeout)" == "240" ]]; then
    pass "matrix: bootstrap_timeout still rides through beside it"
  else
    fail "matrix: bootstrap_timeout regressed — got '$(_fbm_key "$_fbm_json" timeout)', want 240"
  fi

  # --- a non-string is a caller typo: warn, and run with NO assertion ---------
  # `bootstrap_postcheck: true` parses as a bool. Running `True` as a command would red the
  # leg for a reason that has nothing to do with provisioning, which is the false-accusation
  # this advisory lane must not make. Degrade like bootstrap_timeout does, but say so.
  _fbm_json="$(_fbm_caller 'bootstrap_postcheck: true')"
  if [[ -n "$(_fbm_key "$_fbm_json" postcheck)" ]]; then
    fail "matrix: a non-string bootstrap_postcheck was passed through as '$(_fbm_key "$_fbm_json" postcheck)' — that would run as a command"
  elif ! grep -q '::warning::.*bootstrap_postcheck is not a string' "$_fbm_root/stderr"; then
    fail "matrix: a non-string bootstrap_postcheck was dropped SILENTLY — the coverage loss must be announced"
  else
    pass "matrix: a non-string bootstrap_postcheck warns and yields no assertion"
  fi

  # --- every key the workflow reads is a key the script emits -----------------
  # The parity assertion. One-directional on purpose: an emitted key nothing consumes is
  # harmless, a CONSUMED key nothing emits expands to the empty string and fails open.
  # This retro-covers image/prep/name/repo/timeout/offensive as well as postcheck.
  _fbm_json="$(_fbm_caller 'bootstrap_postcheck: ./x.sh')"
  _fbm_emits="$(printf '%s' "$_fbm_json" | python3 -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin)[0])))' 2>/dev/null)"
  _fbm_missing=""
  # Herestring rather than a pipe: the accumulator below must survive the loop, and a
  # `... | while read` runs the body in a subshell where every append is discarded — the
  # assertion would then pass unconditionally, which is the one outcome it must not have.
  while read -r _fbm_k; do
    [[ -n "$_fbm_k" ]] || continue
    [[ " $_fbm_emits " == *" $_fbm_k "* ]] || _fbm_missing="$_fbm_missing $_fbm_k"
  done <<<"$(grep -oE 'matrix\.leg\.[A-Za-z_][A-Za-z0-9_]*' "$_fbm_wf" | sed 's/.*\.//' | sort -u)"
  if [[ -z "$_fbm_emits" ]]; then
    fail "matrix: could not read the emitted keys — the script did not produce a usable leg"
  elif [[ -n "$_fbm_missing" ]]; then
    fail "matrix: real-bootstrap.yml reads matrix.leg key(s)$_fbm_missing that fleet-bootstrap-matrix.py never emits — they expand to empty and the check they gate silently never runs"
  else
    pass "matrix: every matrix.leg.<key> the sweep reads is emitted by the script ($_fbm_emits)"
  fi

  # --- the postcheck must run INSIDE the docker run ---------------------------
  # #742 IN ONE ASSERTION. The wiring check used to sit in a step of its own, one level out,
  # where `docker run --rm` had already destroyed the filesystem it claimed to inspect — a
  # step NAMED for an assertion it could not perform. A postcheck placed there would be the
  # identical bug wearing a new name, and it would still look green. So: the reference has
  # to sit between the `sh -euc ...` opener and the line that closes it.
  # EXTRACT THE BLOCK ONCE, AND PROVE IT IS NON-EMPTY BEFORE ASSERTING ANYTHING ABOUT IT.
  # Both assertions below used to re-run the same inline
  #     awk "/sh -euc '$/{f=1;next} f&&/^ *'$/{f=0} f"
  # and neither checked that it had matched. That is two bugs, one of them the exact
  # failure this file exists to prevent:
  #
  #   * the POSTCHECK assertion fails with a message that names the WRONG CAUSE. It says
  #     "$POSTCHECK is referenced OUTSIDE the sh -euc block", which is a specific,
  #     alarming, actionable claim — and it is what you get when the extraction simply
  #     returned nothing, whatever the reason. Observed for real: green on Ubuntu, Arch
  #     and macOS, red on Alpine, with the workflow byte-identical and the postcheck
  #     correctly inside the block. Hours went into looking for a misplaced reference
  #     that was never misplaced.
  #   * the apostrophe assertion PASSES VACUOUSLY. It is a negative check — `if ... |
  #     grep -q "'"` — so an empty extraction means no apostrophe found means green. The
  #     one assertion guarding a quote-injection hazard reports success precisely when it
  #     has read nothing at all. That is "a gate that never runs reads as coverage", in a
  #     test written to stop that.
  #
  # So: locate the block with grep/sed line numbers rather than a multi-rule awk program
  # (fewer dialect corners — `next`, a boolean-guarded pattern and a bare `f` action all
  # vary between awks, and the Alpine leg runs busybox), keep the result in a variable,
  # and make "could not read the block" its own loud failure that can never be mistaken
  # for either of the two real findings.
  #
  # The content checks are bash pattern matches, NOT `printf ... | grep -q`. That spelling
  # is the SIGPIPE hazard scripts/audit-core.sh gates for, and it fails in the worst
  # direction: `grep -q` exits the instant it matches, the producer takes SIGPIPE, and
  # under `set -o pipefail` the pipeline reports non-zero BECAUSE the pattern was found.
  #
  # It is a RACE, not a certainty, which is exactly why it must not be left in. Measured:
  # at this block's real size (59 lines) the producer finishes first and the pipeline
  # returns 0, so it would not bite today; at 20k lines with the match on line 1 it
  # returns 141. A latent failure that switches on when the file grows — and it would
  # switch on as the POSTCHECK assertion failing precisely when the postcheck is
  # correctly placed, i.e. the same wrong-cause report this commit exists to remove,
  # reintroduced one line below it. Written that way first; the audit caught it.
  _rb_open="$(grep -n "sh -euc '\$" "$_fbm_wf" | head -1 | cut -d: -f1)"
  _rb_close=""
  _rb_block=""
  if [[ -n "$_rb_open" ]]; then
    # First line at or after the opener that is nothing but a closing quote.
    _rb_close="$(tail -n +"$((_rb_open + 1))" "$_fbm_wf" | grep -n "^[[:space:]]*'[[:space:]]*\$" | head -1 | cut -d: -f1)"
    [[ -n "$_rb_close" ]] && _rb_close="$((_rb_open + _rb_close))"
    [[ -n "$_rb_close" ]] && _rb_block="$(sed -n "$((_rb_open + 1)),$((_rb_close - 1))p" "$_fbm_wf")"
  fi

  if ! grep -q 'docker run .*-e POSTCHECK' "$_fbm_wf"; then
    fail "real-bootstrap: the docker run does not pass -e POSTCHECK — the value never reaches the container"
  elif [[ -z "$_rb_block" ]]; then
    # NOT a claim about where POSTCHECK sits. This is the harness failing to read the
    # file, and saying so plainly beats accusing the workflow of a defect it does not have.
    fail "real-bootstrap: could not extract the sh -euc block (opener line: ${_rb_open:-none}, closing line: ${_rb_close:-none}) — the extraction in test-core.sh has drifted from the workflow's shape; fix the harness, not real-bootstrap.yml"
  elif [[ "$_rb_block" != *POSTCHECK* ]]; then
    fail "real-bootstrap: \$POSTCHECK is referenced OUTSIDE the sh -euc block — docker run --rm has destroyed that filesystem by then (#742)"
  else
    pass "real-bootstrap: the postcheck runs inside the container, where the box it asserts still exists"
  fi

  # --- and that block still contains no apostrophe ----------------------------
  # The whole script is one single-quoted `sh -euc '...'` argument; a single apostrophe
  # closes it early and the rest is reinterpreted by the outer shell. The existing block
  # says so twice in comments, which is not a gate.
  #
  # Guarded on a non-empty block for the reason above: unguarded, this is a negative
  # assertion over possibly-nothing, and it goes green when it has read nothing.
  if [[ -z "$_rb_block" ]]; then
    fail "real-bootstrap: cannot check the sh -euc block for apostrophes — the block could not be extracted (see the failure above); refusing to report this as clean"
  elif [[ "$_rb_block" == *"'"* ]]; then
    fail "real-bootstrap: an apostrophe has appeared inside the single-quoted sh -euc block — it closes the quote early"
  else
    pass "real-bootstrap: the sh -euc block is still apostrophe-free ($(wc -l <<<"$_rb_block" | tr -d ' ') lines read)"
  fi
  unset _rb_open _rb_close _rb_block

  unset -f _fbm_caller _fbm_key
  unset _fbm_root _fbm_json _fbm_emits _fbm_missing _fbm_k
fi
unset _fbm _fbm_wf


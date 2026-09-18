# scripts/test/43-gen-region.sh
# the shared marker-region library (scripts/lib/gen-region.sh)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# ── the grammar and the walker, tested ONCE ───────────────────────────────────
# Until #1129 these properties were re-asserted per generator, because the walker was
# re-implemented per generator: scripts/test/40-gen-theme-aliases.sh and
# scripts/test/41-gen-matrix-parity.sh each carry their own crossed-pairs, stray-`end`
# and unterminated-region cases. Those stay — they prove each generator still WIRES the
# library up, with its own namespace in its own messages, which is the part that can
# regress per script. What moves here is everything that is a property of the GRAMMAR
# rather than of any one consumer: the three comment syntaxes, the indent capture, the
# subset pass-through, and the fact that the preflight and the walker cannot disagree.
#
# DRIVEN DIRECTLY, not through a generator. Every case below sources the library and
# calls it, so a fault is attributed to the library rather than to whichever generator
# happened to surface it — and so the cases that no current generator exercises (the
# `html` syntax alongside `hash` in one namespace, say) can be written at all.
#
# ── SCOPE GATE: cross-cutting tooling ─────────────────────────────────────────
# SCOPE_TOOLING is DERIVED by scripts/lib/common.sh :: _set_scope — on for ANY area, off
# only for the explicit `--scope none`. This fragment tests scripts/lib/ itself, which
# belongs to no single area, the same reasoning scripts/test/40-gen-theme-aliases.sh
# carries.
if ! ((SCOPE_TOOLING)); then
  hdr "marker-region library"
  skip "marker-region library (out of scope)"
  return 0
fi

hdr "marker-region library (scripts/lib/gen-region.sh)"

GRD="$SANDBOX/region"
rm -rf "$GRD"
mkdir -p "$GRD"

# File mode, portably. `stat -c` is GNU and `stat -f` is BSD, and PORTABILITY.md lists the
# pair as inverted between them — so try one, fall back to the other. The idiom
# scripts/test/34-link-run.sh:54 and scripts/test/41-gen-matrix-parity.sh:1036 already use.
_gr_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# The driver every case runs: source the library fresh, init a namespace, and expose a
# renderer that stamps the id and the indent it was handed. A SUBSHELL per case, because
# region_init sets module state and a case that changed the namespace would otherwise
# leak it into the next one.
_gr() { # _gr <syntaxes> <script>
  (
    set -uo pipefail
    # shellcheck source=scripts/lib/common.sh
    source "$HERE/scripts/lib/common.sh"
    # shellcheck source=scripts/lib/gen-region.sh
    source "$HERE/scripts/lib/gen-region.sh"
    region_init demo gen-demo "$1" "BLOCKS in scripts/gen-demo.sh"
    # shellcheck disable=SC2317,SC2329  # invoked by name through region_build_file
    _r() { printf '%sBODY(%s)\n' "$2" "$1"; }
    eval "$2"
  ) 2>&1
}

# 1. THE THREE SYNTAXES. Each is a separate arm in the matcher, and a generator enables
#    only the ones its consumers speak — so each needs its own row. `#` is every shell
#    and config language, `<!-- -->` is markdown, `/* */` is CSS (#926).
printf 'a\n# core:demo:gen one\nstale\n# core:demo:end one\nz\n' >"$GRD/hash.conf"
_gr_hash="$(_gr hash 'region_build_file "'"$GRD"'/hash.conf" _r')"
if [[ "$_gr_hash" == $'a\n# core:demo:gen one\nBODY(one)\n# core:demo:end one\nz' ]]; then
  pass "gen-region: the # form renders, and both markers survive verbatim"
else
  fail "gen-region: # form — got '${_gr_hash//$'\n'/ | }'"
fi

printf 'a\n<!-- core:demo:gen one -->\nstale\n<!-- core:demo:end one -->\nz\n' >"$GRD/html.md"
_gr_html="$(_gr html 'region_build_file "'"$GRD"'/html.md" _r')"
if [[ "$_gr_html" == $'a\n<!-- core:demo:gen one -->\nBODY(one)\n<!-- core:demo:end one -->\nz' ]]; then
  pass "gen-region: the <!-- --> form renders, and both markers survive verbatim"
else
  fail "gen-region: <!-- --> form — got '${_gr_html//$'\n'/ | }'"
fi

printf ':root {\n  /* core:demo:gen one */\n  stale\n  /* core:demo:end one */\n}\n' >"$GRD/css.css"
_gr_css="$(_gr css 'region_build_file "'"$GRD"'/css.css" _r')"
if [[ "$_gr_css" == $':root {\n  /* core:demo:gen one */\n  BODY(one)\n  /* core:demo:end one */\n}' ]]; then
  pass "gen-region: the /* */ form renders, and the marker is not rewritten as another syntax"
else
  fail "gen-region: /* */ form — got '${_gr_css//$'\n'/ | }'"
fi

# 2. A SYNTAX THE NAMESPACE DID NOT ENABLE IS NOT A MARKER. Accepting a form no consumer
#    uses widens what a stray line can be mistaken for — and a `#` line inside a CSS file
#    is an id selector, not a comment.
_gr_off="$(_gr css 'region_build_file "'"$GRD"'/hash.conf" _r')"
if [[ "$_gr_off" == $'a\n# core:demo:gen one\nstale\n# core:demo:end one\nz' ]]; then
  pass "gen-region: a marker in a syntax the generator did not enable is passed through as content"
else
  fail "gen-region: a disabled syntax was still parsed as a marker — got '${_gr_off//$'\n'/ | }'"
fi

# 3. AN UNTERMINATED `/*` IS NOT A MARKER. A line that opens a comment it does not close
#    would swallow the generated block into it, and the file would still parse while
#    rendering nothing (#926).
printf '/* core:demo:gen one\nbody\n' >"$GRD/open.css"
_gr_open="$(_gr css 'region_markers "'"$GRD"'/open.css"')"
if [[ -z "$_gr_open" ]]; then
  pass "gen-region: an unterminated /* is not parsed as a marker"
else
  fail "gen-region: an unterminated /* was accepted — got '${_gr_open//$'\n'/ | }'"
fi

# 4. THE INDENT IS CAPTURED AND RE-APPLIED. This is what lets lazygit/config.yml carry a
#    block inside its 4-space gui.theme map; getting it wrong flattens every emitted line
#    to column 0, which only a nested consumer would ever show.
printf 'top:\n    # core:demo:gen one\n    stale\n    # core:demo:end one\n' >"$GRD/ind.yml"
_gr_ind="$(_gr hash 'region_build_file "'"$GRD"'/ind.yml" _r')"
if [[ "$_gr_ind" == *$'\n    BODY(one)\n'* ]]; then
  pass "gen-region: the opening marker's indentation is re-applied to the rendered body"
else
  fail "gen-region: indent was not re-applied — got '${_gr_ind//$'\n'/ | }'"
fi

# 5. THE THREE STRUCTURAL FAULTS, from the WALKER. Each returns 2 and names itself; the
#    generator's own prefix and namespace are interpolated, which is what lets four
#    generators share one implementation without any of them rewording its diagnostics.
printf '# core:demo:gen one\n# core:demo:gen two\n# core:demo:end one\n# core:demo:end two\n' >"$GRD/cross.conf"
_gr_x="$(_gr hash 'region_build_file "'"$GRD"'/cross.conf" _r >/dev/null; echo "rc=$?"')"
if [[ "$_gr_x" == *"gen-demo: 'core:demo:gen two' opens inside the 'one' region"* && "$_gr_x" == *rc=2* ]]; then
  pass "gen-region: crossed pairs are refused (2) and named, by the walker"
else
  fail "gen-region: crossed pairs — got '${_gr_x//$'\n'/ | }'"
fi

printf '# core:demo:gen one\nbody\n' >"$GRD/unterm.conf"
_gr_u="$(_gr hash 'region_build_file "'"$GRD"'/unterm.conf" _r >/dev/null; echo "rc=$?"')"
if [[ "$_gr_u" == *"gen-demo: unterminated 'core:demo:gen one' region"* && "$_gr_u" == *rc=2* ]]; then
  pass "gen-region: an unterminated region is refused (2) and named, by the walker"
else
  fail "gen-region: unterminated — got '${_gr_u//$'\n'/ | }'"
fi

printf '# core:demo:gen one\n# core:demo:end two\n' >"$GRD/mismatch.conf"
_gr_m="$(_gr hash 'region_build_file "'"$GRD"'/mismatch.conf" _r >/dev/null; echo "rc=$?"')"
if [[ "$_gr_m" == *"gen-demo: marker mismatch in"*"'gen one' closed by 'end two'"* && "$_gr_m" == *rc=2* ]]; then
  pass "gen-region: a mismatched end id is refused (2) and both ids are named"
else
  fail "gen-region: mismatch — got '${_gr_m//$'\n'/ | }'"
fi

# 6. THE SAME THREE FAULTS, from the PREFLIGHT, with byte-identical wording. The two
#    paths exist because the preflight runs BEFORE any expensive input is touched — a
#    fleet read, a palette resolve — so a broken document is reported without paying for
#    them. If the two ever disagreed, one of them would be lying about the same file.
_gr_px="$(_gr hash 'region_preflight_file "'"$GRD"'/cross.conf" "one two"; echo "rc=$?"')"
if [[ "$_gr_px" == *"gen-demo: 'core:demo:gen two' opens inside the 'one' region"* && "$_gr_px" == *rc=2* ]]; then
  pass "gen-region: the preflight replays the sequence and reports a crossed pair in the walker's own words"
else
  fail "gen-region: preflight crossed — got '${_gr_px//$'\n'/ | }'"
fi

_gr_pu="$(_gr hash 'region_preflight_file "'"$GRD"'/unterm.conf" "one"; echo "rc=$?"')"
if [[ "$_gr_pu" == *"gen-demo: unterminated 'core:demo:gen one' region"* && "$_gr_pu" == *rc=2* ]]; then
  pass "gen-region: the preflight reports an unterminated region in the walker's own words"
else
  fail "gen-region: preflight unterminated — got '${_gr_pu//$'\n'/ | }'"
fi

# 7. A STRAY OR DUPLICATED `end`. The walker only ever pairs an `end` with the `gen`
#    above it, so this one is INVISIBLE to it and is the preflight's alone — which is
#    exactly the check gen-theme.sh lacked, because its preflight counted `gen` markers
#    and nothing else.
printf '# core:demo:gen one\nx\n# core:demo:end one\n# core:demo:end one\n' >"$GRD/stray.conf"
_gr_s="$(_gr hash 'region_preflight_file "'"$GRD"'/stray.conf" "one"; echo "rc=$?"')"
if [[ "$_gr_s" == *'block one has 1 gen marker(s) but 2 end marker(s)'* && "$_gr_s" == *rc=2* ]]; then
  pass "gen-region: a stray duplicate end marker is caught by the preflight, which the walker cannot see"
else
  fail "gen-region: stray end — got '${_gr_s//$'\n'/ | }'"
fi

# 8. A REGISTERED BLOCK WHOSE REGION WAS DELETED. Without this, removing two comment
#    lines is an undetectable way to opt a file out of the gate forever — the block
#    simply stops being rendered and --check stays green about a file it no longer
#    covers.
_gr_d="$(_gr hash 'region_preflight_file "'"$GRD"'/hash.conf" "one two"; echo "rc=$?"')"
if [[ "$_gr_d" == *'registered block is missing: two'* && "$_gr_d" == *rc=2* ]]; then
  pass "gen-region: a registered block with no region in the file is caught by name"
else
  fail "gen-region: missing block — got '${_gr_d//$'\n'/ | }'"
fi

# 9. AN UNREGISTERED MARKER, and the remediation names WHERE to register it — which
#    differs per generator (BLOCKS, BLOCK_IDS, …), so it is a region_init parameter
#    rather than a string in the library.
_gr_ur="$(_gr hash 'region_unregistered_in_file "'"$GRD"'/hash.conf" "other"; echo "rc=$?"')"
if [[ "$_gr_ur" == *'carries an unregistered gen marker: one — add the block to BLOCKS in scripts/gen-demo.sh'* && "$_gr_ur" == *rc=2* ]]; then
  pass "gen-region: an unregistered marker is named, and so is the registry to add it to"
else
  fail "gen-region: unregistered marker — got '${_gr_ur//$'\n'/ | }'"
fi

# 10. THE SUBSET RENDER. `gen-porting-matrix.sh --local` re-renders only the blocks whose
#     inputs are in-repo and must leave every OTHER block's body exactly as it found it —
#     so the region is a no-op in the byte comparison rather than an empty one. A library
#     that dropped this would make --local report drift on every fleet-fed block.
printf '# core:demo:gen one\nKEEP-ME\n# core:demo:end one\n# core:demo:gen two\nstale\n# core:demo:end two\n' >"$GRD/sub.conf"
_gr_sub="$(_gr hash 'region_build_file "'"$GRD"'/sub.conf" _r "two"')"
if [[ "$_gr_sub" == *KEEP-ME* && "$_gr_sub" == *'BODY(two)'* && "$_gr_sub" != *'BODY(one)'* ]]; then
  pass "gen-region: a block outside the subset keeps its existing body; only the named one is re-rendered"
else
  fail "gen-region: subset render — got '${_gr_sub//$'\n'/ | }'"
fi

# 11. AN UNSELECTED BLOCK IS STILL STRUCTURALLY POLICED. --local narrows what is
#     RENDERED, never what is CHECKED: a broken pair in a fleet-fed block must not become
#     invisible just because this run could not answer its content.
_gr_subx="$(_gr hash 'region_build_file "'"$GRD"'/cross.conf" _r "one" >/dev/null; echo "rc=$?"')"
if [[ "$_gr_subx" == *rc=2* ]]; then
  pass "gen-region: a crossed pair is refused even when neither block is in the render subset"
else
  fail "gen-region: subset skipped a structural fault — got '${_gr_subx//$'\n'/ | }'"
fi

# 12. THE INSTALL'S TWO MODE POLICIES. `preserve` is what gen-theme.sh needs — its
#     targets include tmux/scripts/*.sh at 0755 and audit-core.sh §2 asserts those exec
#     bits, so an atomic rename would land 0644 over them and the gate would only notice
#     afterwards. `0644` is what the document generators need, and it is a FORCED mode:
#     mktemp creates 0600 and mv preserves it, so without the chmod every regeneration
#     would turn a tracked, world-readable file owner-only.
printf 'new\n' >"$GRD/src"
printf 'old\n' >"$GRD/exec-target"
chmod 0755 "$GRD/exec-target"
_gr_ip="$(_gr hash 'region_install "'"$GRD"'/src" "'"$GRD"'/exec-target" preserve; echo "rc=$?"')"
if [[ "$_gr_ip" == *rc=0* ]] && [[ "$(cat "$GRD/exec-target")" == new ]] && [[ -x "$GRD/exec-target" ]]; then
  pass "gen-region: install preserve writes through the inode and keeps the 0755 mode"
else
  fail "gen-region: install preserve — rc/content/mode wrong ($(_gr_mode "$GRD/exec-target"))"
fi

printf 'old\n' >"$GRD/doc-target"
chmod 0600 "$GRD/doc-target"
_gr_id="$(_gr hash 'region_install "'"$GRD"'/src" "'"$GRD"'/doc-target" 0644; echo "rc=$?"')"
if [[ "$_gr_id" == *rc=0* ]] && [[ "$(cat "$GRD/doc-target")" == new ]] && [[ "$(_gr_mode "$GRD/doc-target")" == 644 ]]; then
  pass "gen-region: install 0644 renames atomically and forces the tracked-file mode"
else
  fail "gen-region: install 0644 — rc/content/mode wrong ($(_gr_mode "$GRD/doc-target"))"
fi

rm -rf "$GRD"
unset -f _gr _gr_mode
unset GRD _gr_hash _gr_html _gr_css _gr_off _gr_open _gr_ind _gr_x _gr_u _gr_m
unset _gr_px _gr_pu _gr_s _gr_d _gr_ur _gr_sub _gr_subx _gr_ip _gr_id

# scripts/audit/05-shape.sh
# the audit's own layout contract: every fragment is numbered, sourced, tracked, and no two share a gate id
#
# A SOURCED FRAGMENT of scripts/audit-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: the PASS/SKIP/FAIL counters, $HERE (already cd'd
# to), the SCOPE_* flags, and the pass/skip/fail/hdr/have helpers from
# scripts/lib/common.sh. NO EXIT TRAP HERE: the dispatcher installs the one that reaps the
# backgrounded behavioral suite, and `trap … EXIT` REPLACES rather than appends. See the
# header of scripts/audit-core.sh for the contract.

# ── 0. the audit's own layout (scripts/audit/) ────────────────────────────────
# The dispatcher globs `scripts/audit/[0-9][0-9]-*.sh`. That is the right shape — it has no
# registry to forget — but it buys that at the price of a NEW way to write a gate that never
# runs: drop `scripts/audit/helpers.sh` in beside the others, and the glob skips it in
# silence while the audit reports `audit OK`. That failure looks exactly like success, which
# is the class of defect the whole audit exists to catch elsewhere. So the layout is
# asserted, not assumed — the mirror of scripts/test/05-suite-shape.sh, for the same
# reasons, plus one this file has that the suite never did: the sections carry STABLE
# `§`-ids (`# ── 5f. … ──`) that the docs cite, and when they lived in one file two unrelated
# gates ended up wearing `1c` for a month (#676, #700). Uniqueness is a gate now.
# Pure bash, and numbered 05 so it runs before anything it describes.
hdr "the audit's own layout (scripts/audit/)"

_as_dir="$HERE/scripts/audit"
_as_all=0 _as_numbered=0 _as_stray="" _as_exec="" _as_untracked="" _as_unbannered=""
for _as_f in "$_as_dir"/*.sh; do
  [[ -e "$_as_f" ]] || break
  _as_all=$((_as_all + 1))
  _as_b="${_as_f##*/}"
  case "$_as_b" in
  [0-9][0-9]-*.sh) _as_numbered=$((_as_numbered + 1)) ;;
  *) _as_stray="${_as_stray:+$_as_stray }$_as_b" ;;
  esac
  # Sourced libraries, so 100644 — §2 owns the git-index view of this; here we check the
  # working tree, which is what actually gets sourced and what a fresh `chmod +x` would
  # break first.
  [[ -x "$_as_f" ]] && _as_exec="${_as_exec:+$_as_exec }$_as_b"
  # Every fragment is a gate, and a gate announces itself with at least one `# ── <id>. `
  # banner. A file with none is a slice that lost its banner in a cut — its hdr/pass/fail
  # lines still run, but nothing names the section they belong to.
  grep -qE '^# ── [0-9][0-9a-z-]*\. ' "$_as_f" || _as_unbannered="${_as_unbannered:+$_as_unbannered }$_as_b"
done

if ((_as_all == 0)); then
  fail "audit layout: no fragments under scripts/audit/ — the dispatcher should have refused to run at all"
elif [[ -n "$_as_stray" ]]; then
  fail "audit layout: not matched by the dispatcher's [0-9][0-9]-*.sh glob, so never sourced: $_as_stray — rename it with an NN- prefix, or it is a gate that reads as coverage"
else
  pass "audit layout: all $_as_all fragments carry the NN- prefix the dispatcher globs (none silently unsourced)"
fi

# A floor, not an exact count: the point is that the glob found THE AUDIT and not two
# leftovers. An exact number would be a second registry to update on every split.
if ((_as_numbered >= 12)); then
  pass "audit layout: the glob resolves the whole audit ($_as_numbered fragments)"
else
  fail "audit layout: only $_as_numbered fragments matched — the audit is 16-odd files; a glob this short means most of it is not running"
fi

if [[ -z "$_as_exec" ]]; then
  pass "audit layout: no fragment is executable (they are sourced libraries, like scripts/lib/)"
else
  fail "audit layout: executable fragment(s): $_as_exec — they are sourced, never run, and +x invites someone to run one standalone and read the empty result as a pass"
fi

if [[ -z "$_as_unbannered" ]]; then
  pass "audit layout: every fragment carries at least one \`# ── <id>. \` section banner"
else
  fail "audit layout: fragment(s) with no section banner: $_as_unbannered — a gate with no id is one the docs cannot cite and the next split cannot place"
fi

# THE ID GATE. `# ── <id>. title ──` is the section's name; `# ── <id> (cont.) …` is a
# continuation of one (the four §5h registers). Ids are collected across EVERY fragment,
# because the collision that motivated this — two `1c`s — was invisible inside one file and
# is exactly as invisible across two. The `\. ` anchor keeps the continuation form and the
# dispatcher's prose banners (`--changed:`, `summary`) out of the primary set.
_as_ids="$(grep -hE '^# ── [0-9][0-9a-z-]*\. ' "$_as_dir"/[0-9][0-9]-*.sh 2>/dev/null | sed -E 's/^# ── ([0-9][0-9a-z-]*)\. .*/\1/')"
_as_dups="$(printf '%s\n' "$_as_ids" | sort | uniq -d | tr '\n' ' ')"
_as_n="$(printf '%s\n' "$_as_ids" | grep -c .)"
if [[ -n "$_as_dups" ]]; then
  fail "audit layout: section id worn by two gates: ${_as_dups% }— rename one; the docs cite these ids and a duplicate makes every citation ambiguous (this is how 1c named two gates until #NNN)"
elif ((_as_n >= 45)); then
  pass "audit layout: $_as_n section ids across the fragments, no two alike"
else
  fail "audit layout: only $_as_n section banners found across scripts/audit/ — the audit has 48-odd; a count this low means a cut dropped banners with the gates under them"
fi
# Every continuation names a primary that exists.
_as_orphans=""
while IFS= read -r _as_c; do
  [[ -z "$_as_c" ]] && continue
  printf '%s\n' "$_as_ids" | grep -qx "$_as_c" || _as_orphans="${_as_orphans:+$_as_orphans }$_as_c"
done < <(grep -hE '^# ── [0-9][0-9a-z-]* \(cont\.\)' "$_as_dir"/[0-9][0-9]-*.sh 2>/dev/null | sed -E 's/^# ── ([0-9][0-9a-z-]*) \(cont\.\).*/\1/' | sort -u)
if [[ -z "$_as_orphans" ]]; then
  pass "audit layout: every \`(cont.)\` banner continues a section that exists"
else
  fail "audit layout: \`(cont.)\` banner(s) with no primary section: $_as_orphans — a continuation left behind by a cut"
fi

# Tracked matters for a reason that is not tidiness: `_audit_ls` deliberately picks up
# untracked files, so the linters DO see one; and `scripts/` is repo-meta, so these fragments
# ship to no OS repo either way. The failure mode is simpler and worse than both — an
# untracked fragment never reaches the remote, so CI and every fresh clone run the audit
# WITHOUT it. Its gates vanish everywhere except the box that wrote them, and the run still
# says `audit OK`.
if have git && git -C "$HERE" rev-parse --git-dir >/dev/null 2>&1; then
  for _as_f in "$_as_dir"/[0-9][0-9]-*.sh; do
    [[ -e "$_as_f" ]] || break
    git -C "$HERE" ls-files --error-unmatch "${_as_f#"$HERE/"}" >/dev/null 2>&1 ||
      _as_untracked="${_as_untracked:+$_as_untracked }${_as_f##*/}"
  done
  if [[ -z "$_as_untracked" ]]; then
    pass "audit layout: every fragment is tracked (so CI and a fresh clone run the same audit this box does)"
  else
    fail "audit layout: untracked fragment(s): $_as_untracked — they never reach the remote, so CI and every fresh clone run the audit without them and still report OK"
  fi
else
  skip "audit layout: tracked-fragment check (not a git checkout)"
fi

# The empty-glob refusal (the dispatcher's exit 2 over zero fragments) is DRIVEN from the
# behavioral suite — scripts/test/23-audit-shape.sh — not from here: the audit has no
# sandbox of its own to stage a throwaway tree in, and staging one would need a second
# EXIT trap, which is the one thing a fragment must never install.

unset _as_dir _as_all _as_numbered _as_stray _as_exec _as_untracked _as_unbannered _as_f _as_b _as_ids _as_dups _as_n _as_orphans _as_c

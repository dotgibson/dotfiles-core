# scripts/audit/10-manifest.sh
# what this repo ships, and whether it reaches a clone: core.manifest ↔ core.vendor ↔ the tree
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
# §1f WAS §1c until the split. Two unrelated gates wore one id — the core.vendor existence
# check (#676) and the unreferenced-.claude/-files scanner (#700, #905) — and the second is
# now 1f, the next free letter in a family whose letters are ADDITION order, not run order
# (that is why §1b runs fifth). scripts/audit/05-shape.sh fails the run on a duplicate id
# now, so the class cannot recur. Shipped release notes for #700 and #905 still say §1c;
# they are history and were left alone.

# ── 1. manifest <-> filesystem drift ─────────────────────────────────────────
hdr "manifest ↔ filesystem"
# Parse manifest: strip comments/blank lines, take the first whitespace token.
# Use a read loop (not `mapfile`) — mapfile is bash 4+, and this gate must also
# run on macOS's stock bash 3.2 (the dotfiles-MacBook target / the macOS CI leg).
MANIFEST_PATHS=()
while IFS= read -r p; do
  MANIFEST_PATHS+=("$p")
done < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' core.manifest | awk 'NF {print $1}')
# core.vendor is parsed with the SAME parser, deliberately: it shares core.manifest's format
# so there is one thing to learn and one thing to get wrong (#676).
VENDOR_PATHS=()
while IFS= read -r p; do
  VENDOR_PATHS+=("$p")
done < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' core.vendor 2>/dev/null | awk 'NF {print $1}')
for p in "${MANIFEST_PATHS[@]}"; do
  if [[ "$p" == */ ]]; then
    if [[ -d "$p" ]]; then pass "dir  $p"; else fail "manifest lists missing dir:  $p"; fi
  else
    if [[ -e "$p" ]]; then pass "file $p"; else fail "manifest lists missing file: $p"; fi
  fi
done

# Reverse direction: tracked Core files not covered by the manifest or allowlist.
is_listed() { # $1 = path
  local f="$1" m pre
  for m in "${MANIFEST_PATHS[@]}"; do
    [[ "$f" == "$m" ]] && return 0                # exact file match
    [[ "$m" == */ && "$f" == "$m"* ]] && return 0 # under a listed dir
  done
  for m in "${VENDOR_PATHS[@]}"; do
    [[ "$f" == "$m" ]] && return 0                # exact file match
    [[ "$m" == */ && "$f" == "$m"* ]] && return 0 # under a listed dir
  done
  for m in "${META_ALLOWLIST[@]}"; do [[ "$f" == "$m" ]] && return 0; done
  for pre in "${META_PREFIXES[@]}"; do [[ "$f" == "$pre"* ]] && return 0; done
  return 1
}
if have git && git rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    is_listed "$f" || fail "tracked file not in manifest/allowlist: $f"
  done < <(git ls-files)
  pass "reverse-drift scan complete (tracked files all accounted for)"
else
  skip "reverse-drift scan (not a git checkout)"
fi

# ── 1c. vendor allowlist ↔ filesystem ────────────────────────────────────────
# The manifest direction of §1, for the second list. A core.vendor entry naming a path that
# does not exist would silently shrink the vendored set: core_vendor_tree keeps what the
# filter matches, and a typo matches nothing. The consumer that needed it then fails at
# runtime, in ITS repo's CI, one fan-out later.
hdr "vendor allowlist ↔ filesystem"
if [[ ! -r core.vendor ]]; then
  fail "core.vendor is missing or unreadable — sync-core.sh would silently fall back to vendoring the WHOLE tree (core_vendor_effective_tree's version switch keys on this file's presence at a commit)"
elif ((${#VENDOR_PATHS[@]} == 0)); then
  fail "core.vendor parses to zero paths — every OS repo would vendor an empty core/"
else
  for p in "${VENDOR_PATHS[@]}"; do
    if [[ "$p" == */ ]]; then
      if [[ -d "$p" ]]; then pass "vendor dir  $p"; else fail "core.vendor lists missing dir:  $p"; fi
    else
      if [[ -e "$p" ]]; then pass "vendor file $p"; else fail "core.vendor lists missing file: $p"; fi
    fi
  done
fi

# ── 1d. the two lists must not disagree about a path ─────────────────────────
# core.manifest answers "is this SHIPPED Core — symlinked into $HOME?"; core.vendor answers
# "does this RIDE ALONG in core/ so vendored tooling resolves?". A path in both means nobody
# decided which it is, and the two lists are read by different code for different purposes.
#
# A FAIL, not a warning: the duplicate is harmless to the tree today (the filter unions
# them), which is exactly why it would sit there accumulating until someone removed the
# manifest line and silently unshipped a Core file that "was still listed".
hdr "core.manifest ↔ core.vendor"
_dupes=0
for p in "${VENDOR_PATHS[@]}"; do
  for m in "${MANIFEST_PATHS[@]}"; do
    if [[ "$p" == "$m" ]] || [[ "$m" == */ && "$p" == "$m"* ]]; then
      fail "listed in BOTH core.manifest and core.vendor: $p (decide which — shipped Core, or rides along for a consumer)"
      _dupes=1
    fi
  done
  for m in "${META_ALLOWLIST[@]}"; do
    if [[ "$p" == "$m" ]]; then
      fail "listed in BOTH core.vendor and audit-core.sh's META_ALLOWLIST: $p (META_ALLOWLIST is the NOT-vendored list — drop the entry there)"
      _dupes=1
    fi
  done
done
((_dupes)) || pass "no path claimed by two lists"
# The two contract files must vendor themselves. Vendored tooling parses core.manifest from
# its OWN root (a filtered core/ that omitted it breaks the moment anything in it reads the
# manifest), and core.vendor is what lets a checkout with no Core objects answer "why are
# these files here?" from core/ alone.
for _self in core.manifest core.vendor; do
  _found=0
  for p in "${VENDOR_PATHS[@]}"; do [[ "$p" == "$_self" ]] && _found=1; done
  if ((_found)); then pass "core.vendor lists $_self (self-describing)"
  else fail "core.vendor does not list $_self — a vendored core/ could not explain or parse itself"; fi
done

# ── 1e. vendored closure: does a shipped script reach a file nobody ships? ───
# The gate #676 needs and nothing else provides. Before it, a script that shipped could
# `source` any sibling, because every sibling shipped. Now core/ carries ~180 of 285 files,
# so a vendored entry point can reach a path that stayed behind — and NOTHING else catches
# it: §1's reverse drift sees a tracked, accounted-for file either way, and core-integrity
# compares tree hashes, where a consistently-wrong subset hashes consistently. It surfaces on
# a box, at runtime, as "no such file or directory".
#
# BFS FROM DECLARED ENTRY POINTS, not a sweep of every vendored script. Entry points are the
# files a consumer EXECUTES or SOURCES, marked `# entry` in core.vendor. Sweeping everything
# instead would immediately demand that release-only tooling's references be vendored —
# scripts/release.sh reaches CHANGELOG.md, gen-release-notes.sh reaches cliff.toml — and the
# only ways out are to hand back 687 KB or to start a suppression list. A gate whose first
# act is to demand a suppression is a gate someone turns off (the _core_pipefail_hits
# argument). Walking from entry points puts that tooling out of scope by construction.
#
# See _core_vendor_ref_hits for what the scanner deliberately cannot see (computed paths,
# Lua requires, YAML). Those paths are hand-listed in core.vendor with their consumer named.
hdr "vendored closure (core.vendor '# entry' roots)"
_is_vendored() { # _is_vendored <path>
  local f="$1" m
  for m in "${MANIFEST_PATHS[@]}"; do
    [[ "$f" == "$m" ]] && return 0
    [[ "$m" == */ && "$f" == "$m"* ]] && return 0
  done
  for m in "${VENDOR_PATHS[@]}"; do
    [[ "$f" == "$m" ]] && return 0
    [[ "$m" == */ && "$f" == "$m"* ]] && return 0
  done
  return 1
}
_ENTRIES=()
while IFS= read -r p; do
  [[ -n "$p" ]] && _ENTRIES+=("$p")
done < <(grep -E '^[^#[:space:]]+[[:space:]]+#[[:space:]]*entry([[:space:]]|$)' core.vendor 2>/dev/null | awk '{print $1}')
if ((${#_ENTRIES[@]} == 0)); then
  fail "core.vendor declares no '# entry' roots — the closure check has nothing to walk from, so a vendored script could reach an unvendored file unnoticed"
else
  # bash 3.2: no associative arrays (this gate runs on macOS's stock 3.2), so `seen` is a
  # newline-delimited string and membership is a case glob. The frontier is bounded by the
  # vendored set, so this terminates in a handful of rounds.
  _seen=$'\n'
  _queue=("${_ENTRIES[@]}")
  _closure_bad=0
  while ((${#_queue[@]})); do
    _cur="${_queue[0]}"
    _queue=("${_queue[@]:1}")
    case "$_seen" in *$'\n'"$_cur"$'\n'*) continue ;; esac
    _seen="${_seen}${_cur}"$'\n'
    [[ -f "$_cur" ]] || continue
    while IFS= read -r _hit; do
      [[ -n "$_hit" ]] || continue
      _ln="${_hit%%:*}"; _ref="${_hit#*:}"
      if _is_vendored "$_ref"; then
        _queue+=("$_ref")
      else
        fail "vendored $_cur:$_ln reaches $_ref, which is NOT vendored — add it to core.vendor (with its consumer named) or stop reaching for it"
        _closure_bad=1
      fi
    # One line per REFERENCED PATH, not per reference. This tree puts a
    # `# shellcheck source=` directive above every `source` line, so an unvendored sibling
    # is named twice by construction and the gate would report each break twice — noise that
    # reads like two problems.
    done < <(_core_vendor_ref_hits "$_cur" | sort -t: -k2,2 -u)
  done
  ((_closure_bad)) || pass "closure clean from ${#_ENTRIES[@]} entry root(s) — every path they reach is vendored"
fi

# ── 1b. routine reference integrity (the inverse of §1's reverse drift) ──────
# §1 above asks, in both directions, whether every TRACKED file is accounted for. This
# asks the mirror question: is every file the maintenance routines say they READ actually
# there, and actually shipped? Those are different failures and §1 structurally cannot see
# the second one — its reverse walk is fed by `git ls-files`, so a file that was never
# tracked is not in the stream and `is_listed` is never called on it. The manifest
# direction never looks either: .claude/ is repo-meta, allowlisted wholesale by
# META_PREFIXES, which is correct and is also why nothing was watching.
#
# WHY IT EXISTS. #661 taught /tool-scout to consult a decided-and-rejected ledger at
# .claude/tool-decisions.md, shipped the three files that reference it, and did not ship
# the ledger: .gitignore's `.claude/*` negations are per-DIRECTORY, so commands/ and
# agents/ vendored out while the file they point at stayed untracked (#700). The routine's
# own instruction is to say "none" when a candidate has no prior decision — so with no
# file every candidate resolves to "none", in the exact voice that means CHECKED. The
# report then asserts the ledger was consulted while consulting nothing, which is worse
# than the ambiguity #634 was filed to remove, because the absence is no longer visible.
# It is the same shape as core.manifest naming a verify-core backstop that never existed
# (#454): an assertion pointing at a file nobody created.
#
# TWO VERDICTS, NOT ONE. "absent" and "present but untracked" are different bugs with
# different fixes — author the file, versus negate it in .gitignore — and this defect was
# the second, which every report of it so far has called the first. Collapsing them into
# one message would hand the reader the wrong repair.
#
# PLAIN `git ls-files`, NOT _audit_ls. The rule is in common.sh: a gate asking "what does
# GIT RECORD?" takes the tracked list, and _audit_ls deliberately adds
# untracked-but-not-ignored files. Here that inclusion would be fatal rather than noisy —
# an ignored file is exactly what this gate exists to catch, and _audit_ls would wave the
# one on the author's disk straight through while every clone stayed broken.
#
# WHY IT BLOCKS ON ARRIVAL, the §5i argument: the tree is green the moment this lands (the
# four references all resolve), so every future hit is a regression introduced by the
# commit under test, not inherited fleet drift.
hdr "routine reference integrity"
if ! have git || ! git rev-parse --git-dir >/dev/null 2>&1; then
  skip "routine reference integrity (not a git checkout)"
else
  cref_fail=0
  # Newline-DELIMITED, not merely newline-separated: the leading and trailing newlines let
  # the membership test below match a whole line without a subprocess, and without
  # `.claude/tool-decisions.md` being satisfied by a hypothetical `x.claude/tool-decisions.md`.
  # A `grep -qxF` per reference would be the obvious spelling and is exactly what §5d
  # forbids — a shell string piped into a reader that exits early.
  cref_tracked=$'\n'"$(git ls-files)"$'\n'
  while IFS= read -r cref_src; do
    [[ -z "$cref_src" ]] && continue
    while IFS= read -r cref_hit; do
      [[ -z "$cref_hit" ]] && continue
      cref_line="${cref_hit%%:*}"
      cref_path="${cref_hit#*:}"
      if [[ ! -e "$cref_path" ]]; then
        fail "$cref_src:$cref_line names $cref_path, which does not exist — a routine instructed to read a missing file reports 'none' rather than failing, so the absence reads as a clean check"
        cref_fail=1
      elif [[ "$cref_tracked" != *$'\n'"$cref_path"$'\n'* ]]; then
        fail "$cref_src:$cref_line names $cref_path, which exists here but is NOT TRACKED — it reaches no clone, no CI run and none of the nine vendored repos. Negate it in .gitignore (#700)"
        cref_fail=1
      fi
    done <<EOF
$(_core_claude_ref_hits "$cref_src")
EOF
  done <<EOF
$(git ls-files '.claude/commands/*.md' '.claude/agents/*.md')
EOF
  ((cref_fail)) || pass "routine reference integrity (every .claude/ path the routines name resolves and is tracked)"
  unset cref_fail cref_tracked cref_src cref_hit cref_line cref_path
fi

# ── 1f. unreferenced .claude/ files (the half §1b structurally cannot reach) ──
# §1b asks whether every .claude/ path a routine NAMES is shipped. That only fires because
# something pointed at the file. This asks the question with no reference to lean on: is any
# file under .claude/ sitting on this disk and going nowhere?
#
# WHY BOTH ARE NEEDED. #700 was caught only because three routine files named the ledger. A
# .claude/ file nothing references — a new subagent, a convention-named config a hook reads,
# a second ledger — has no such witness, and `.gitignore`'s blanket `.claude/*` means git
# prints nothing about it: not in `git status`, not added by `git add -A`, not in any content
# gate here (they all read the working tree, where it is present and correct). The audit was
# answering "is this tree consistent" — it was — while nobody asked "will this reach a clone".
#
# THE RULE THAT WINS IS THE VERDICT. The scanner asks `git check-ignore -v` which line hid the
# file. The blanket `.claude/*` means nobody decided anything about it; any more specific rule
# means somebody wrote a line naming it, which is a decision and stays quiet. So
# settings.local.json is exempt because .gitignore names it, not because this gate lists it,
# and the next per-machine file becomes exempt the moment its rule is written.
#
# The two verdicts §1b separates do not arise here: a file this gate sees always EXISTS (it
# was found on disk), so "author it" is never the repair. The repair is always one .gitignore
# line — a negation if it should ship, a specific rule if it should not.
#
# WHY IT BLOCKS ON ARRIVAL, the §5i/§1b argument: the tree is green the moment this lands —
# settings.local.json is the only untracked file under .claude/, and it carries its own rule —
# so every future hit is a regression introduced by the commit under test.
hdr "unreferenced .claude/ files"
if ! have git || ! git rev-parse --git-dir >/dev/null 2>&1; then
  skip "unreferenced .claude/ files (not a git checkout)"
elif [[ ! -d .claude ]]; then
  skip "unreferenced .claude/ files (no .claude/ directory)"
else
  cunt_fail=0
  while IFS= read -r cunt_path; do
    [[ -z "$cunt_path" ]] && continue
    fail "$cunt_path exists here but git will never ship it — it is hidden by the blanket \`.claude/*\` rule, so it reaches no clone, no CI run and none of the nine vendored repos, and nothing else reports it. Negate it in .gitignore if it is shared; give it its own ignore rule if it is per-machine (#700)"
    cunt_fail=1
  done <<EOF
$(_core_claude_untracked_hits "$HERE")
EOF
  ((cunt_fail)) || pass "unreferenced .claude/ files (every file under .claude/ either ships or is deliberately ignored)"
  unset cunt_fail cunt_path
fi

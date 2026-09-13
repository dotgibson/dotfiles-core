# scripts/audit/45-have-api.sh
# the HAVE_* contract: PORTABILITY.md §5 ↔ 00-tools.zsh ↔ the fleet's reads, and the vendored have-api.txt surface
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

# ── 5j. the HAVE_* contract (PORTABILITY.md §5 ↔ 00-tools.zsh ↔ the fleet) ────
# zsh/00-tools.zsh sets HAVE_<TOOL> flags into every interactive shell, three OS repos read
# one of them from their os/*.zsh, and until #694 nothing declared any of that: PORTABILITY.md
# — the file that documents the Core→OS API, with a shim table naming _cache_eval and
# _core_is_wsl — did not contain the string HAVE_. So there was no basis for saying which
# flags were safe downstream, and none for saying which were removable; a rename here would
# have surfaced downstream as a shell function quietly not firing.
#
# PORTABILITY.md §5 is the declaration. This is the gate, and it runs in three directions —
# the both-ways shape §1 already gives core.manifest, plus a third that keeps the pruning
# from undoing itself:
#
#   1. DECLARED ⊆ SET.      A flag the doc offers downstream that 00-tools.zsh does not set
#                           is a lie in the contract — exactly what a Core rename leaves
#                           behind, and the failure mode the doc exists to prevent.
#   2. FLEET READS ⊆ DECLARED. An OS or role repo reading a Core-namespace flag it does not
#                           itself set is coupled to Core's internals. Declare it (a one-line
#                           table row) or stop reading it.
#   3. SET ⇒ HAS A READER.  A flag nothing reads is a global in every interactive shell that
#                           can only go stale, and nothing notices when it does. #694 dropped
#                           fourteen of those; this is what stops them coming back.
#
# WHAT "READS" MEANS, and why it is a sigil match rather than a bare name. A read is
# `$HAVE_X` or `${HAVE_X…}`; a comment mentioning the flag writes the bare name. That
# distinction is the whole reason this needs no comment-stripping — the trap PORTABILITY.md
# §3 documents at length, where five grammars each hide a `#` somewhere. Measured across the
# fleet when this was written: bare-name matching found HAVE_ASTGREP/HAVE_JNV/HAVE_SHELLCHECK
# in one dotfiles-Offense COMMENT and HAVE_DIFFT/HAVE_UV/HAVE_VIDDY in five more, none of them
# reads; sigil matching found exactly the three real ones. The cost is one wording rule, in
# the doc: do not put a `$` in front of a flag name in prose.
#
# A repo that SETS a flag owns it — dotfiles-Offense and dotfiles-Defense define ~20 apiece in
# the same namespace, legitimately, and dotfiles-Defense re-probes jq into HAVE_JQ. Subtracting
# each repo's own assignments before comparing is what keeps those out of direction 2; the
# contract is only ever about reading a name you did not set.
#
# NO --exclude-dir AND NO -I anywhere below. Both are GNU extensions that busybox grep
# REJECTS, and the Alpine leg runs busybox — the same trap that made _core_make_gate_hits
# report Core as the repo missing its own rule. The vendored core/ subtree (which would
# otherwise answer for Core in every OS repo and make direction 2 vacuous) is pruned with
# `find` instead, which is portable.
#
# Direction 2 reads sibling clones, so it takes the skip_env posture of §5f and §5h: CI checks
# out this repo alone, and a gate that only passes on a laptop with the fleet beside it is a
# gate nobody trusts.
#
# WHICH MEANS DIRECTION 2 IS ADVISORY IN PRACTICE TODAY, and saying so is better than letting
# the next reader assume otherwise. It fires where the fleet sits beside Core — a maintainer's
# `make audit`, the scheduled fleet jobs — and records a skip on every default CI run. The
# reusable lint workflow the OS repos call does not run it, so an OS-repo PR adding an
# undeclared read can merge without a red. The fix is a caller-side leg in lint-call.yml
# beside the _core_return_trap_hits and _core_owned_block_hits legs, which already share
# rules with this file for exactly this reason — but that leg needs the DECLARED table from a
# vendored checkout, and PORTABILITY.md is not in core.vendor. Vendoring it is a change to
# the allowlist with its own nine-repo blast radius, so it is #866 rather than this PR.
#
# Directions 1 and 3 read this repo's own files and are unconditional.
hdr "HAVE_* contract (PORTABILITY.md §5 ↔ 00-tools.zsh ↔ fleet)"
hv_tools="$HERE/zsh/00-tools.zsh"
hv_doc="$HERE/PORTABILITY.md"
hv_fail=0
if [ ! -f "$hv_tools" ] || [ ! -f "$hv_doc" ]; then
  fail "HAVE_* contract: zsh/00-tools.zsh or PORTABILITY.md is missing — the contract gate checked NOTHING this run"
  hv_fail=1
else
  # The declared surface: the table under PORTABILITY.md §5's "What downstream may use".
  # Range-anchored to that heading so an unrelated table elsewhere in the doc can never
  # widen the surface by accident.
  hv_declared=" $(awk '
    /^### What downstream may use/ { inb = 1; next }
    inb && /^### / { inb = 0 }
    inb && /^\|[ \t]*`HAVE_[A-Z0-9_]+`/ {
      if (match($0, /HAVE_[A-Z0-9_]+/)) print substr($0, RSTART, RLENGTH)
    }
  ' "$hv_doc" | sort -u | tr '\n' ' ') "
  # What Core actually sets. Comment lines are dropped first: this file's own prose spells
  # the idiom as `_have x && HAVE_X=1`, which would otherwise register as a flag named
  # HAVE_X that nothing sets and nothing reads — a finding invented by the gate's own docs.
  hv_set=" $(grep -v '^[[:space:]]*#' "$hv_tools" | grep -oE 'HAVE_[A-Z0-9_]+=1' | sed 's/=1$//' | sort -u | tr '\n' ' ') "
  # Every sigil read in Core's own zsh modules — and ONLY those, which is the whole
  # precision of direction 3. A HAVE_* flag is a shell parameter that is never exported, so
  # the only code that can read one is code SOURCED INTO THE SAME SHELL: zsh/*.zsh here, and
  # the OS/role layers downstream that direction 2 covers. bin/, scripts/, maint/ and
  # tmux/scripts/ run as CHILD processes where the flag does not exist, and nvim's lua cannot
  # see a zsh parameter at all — every HAVE_* mention in those trees is prose about Core, not
  # a read of it.
  #
  # SCANNING THEM ANYWAY IS WHAT MADE AN EARLIER DRAFT WRONG (#694 review): including
  # scripts/ let scripts/test-core.sh count as a reader, and HAVE_GRON — whose only
  # `${HAVE_GRON:-}` in the tree is one negative fixture — passed direction 3 while being
  # exactly the dead global this section exists to find. A test is not a consumer. Its flag
  # is pruned and that fixture now asserts against the ledger, which is what it meant.
  #
  # Whole-line comments are dropped for the reason _core_have_read_hits states: the sigil
  # rule alone still reads `# gated on $HAVE_X` as a read.
  # Both read shapes, kept in step with _core_have_read_hits: the sigil forms, and the
  # no-sigil ARITHMETIC form `(( HAVE_X ))`, which needs no `$` and which the sigil pattern
  # cannot see. Out of step, direction 3 would report a flag as unread that a Core module
  # reads perfectly well, and the fix would be to delete a live flag.
  hv_read=" $( { grep -rhv '^[[:space:]]*#' "$HERE/zsh" 2>/dev/null \
      | grep -oE '[$][{]?([(][^)]*[)])?[+]?HAVE_[A-Z0-9_]+' 2>/dev/null
    grep -rhv '^[[:space:]]*#' "$HERE/zsh" 2>/dev/null | grep -F '((' 2>/dev/null \
      | grep -oE 'HAVE_[A-Z0-9_]+' 2>/dev/null
  } | grep -oE 'HAVE_[A-Z0-9_]+' | sort -u | tr '\n' ' ') "

  # PARSING NOTHING IS A FAILURE, NOT A PASS. Rename or delete §5's heading and hv_declared
  # comes back empty — at which point direction 1 is vacuous, direction 2 skips on any box
  # without the fleet beside it (which is every CI runner), and direction 3 still passes
  # because HAVE_ATUIN has an internal reader in 00-tools.zsh too. The whole section would
  # report green over NO declared surface at all, which is the failure mode #682 named: a
  # drift gate that checked nothing must never report green.
  hv_ndecl=0
  for hv_f in $hv_declared; do hv_ndecl=$((hv_ndecl + 1)); done
  if ((hv_ndecl == 0)); then
    fail "HAVE_* contract: parsed NO declared flags out of PORTABILITY.md §5 — its '### What downstream may use' heading or table is missing or renamed. The contract gate checked nothing this run"
    hv_fail=1
  fi

  # ── direction 1: every declared flag is one Core sets ──
  for hv_f in $hv_declared; do
    case "$hv_set" in
    *" $hv_f "*) ;;
    *)
      fail "HAVE_* contract: PORTABILITY.md §5 declares $hv_f for downstream use, but zsh/00-tools.zsh does not set it — the declaration is stale. Restore the assignment, or drop the table row (and migrate whoever reads it)"
      hv_fail=1
      ;;
    esac
  done

  # ── direction 3: every flag Core sets has a reader ──
  for hv_f in $hv_set; do
    case "$hv_read$hv_declared" in
    *" $hv_f "*) ;;
    *)
      fail "HAVE_* contract: zsh/00-tools.zsh sets $hv_f and nothing reads it — not a Core module, not PORTABILITY.md §5's table. Drop the \`&& $hv_f=1\` and keep the bare \`_have\` probe (the _CORE_PROBED ledger is what core-doctor reads), or declare it"
      hv_fail=1
      ;;
    esac
  done

  # ── direction 2: no OS or role repo reads an undeclared Core-namespace flag ──
  hv_root="$(cd "$HERE/.." && pwd)"
  hv_checked=0
  hv_absent=0
  hv_fleet=1
  if ! load_os_repos; then
    hv_fleet=0
    skip_env "HAVE_* contract: fleet half ($CORE_OS_REPOS_ERR — cannot enumerate the fleet)"
  else
    for hv_repo in "${CORE_OS_REPOS[@]}"; do
      hv_dir="$(resolve_repo_dir "$hv_root" "$hv_repo")" || hv_dir="$hv_root/$hv_repo"
      if [ ! -d "$hv_dir" ]; then
        hv_absent=$((hv_absent + 1))
        continue
      fi
      # The matcher lives in scripts/lib/common.sh so it can be driven by fixtures rather
      # than only by hand (#694 review): it returns the names this repo READS and does not
      # itself SET, with vendored core/ pruned and whole-line comments dropped on both sides.
      # A layer that assigns a name owns it — both role repos legitimately carry ~20 of their
      # own — so subtracting the repo's own assignments is what keeps those out of here.
      [ -d "$hv_dir" ] || continue
      hv_checked=$((hv_checked + 1))
      hv_uses="$(_core_have_read_hits "$hv_dir")"
      for hv_f in $hv_uses; do
        case "$hv_declared" in *" $hv_f "*) continue ;; esac
        # Two different defects, and the remedy differs, so they are reported apart: a flag
        # Core no longer sets is already broken on every box, while an undeclared one that
        # Core does set works today and is merely uncontracted.
        case "$hv_set" in
        *" $hv_f "*)
          fail "HAVE_* contract: $hv_repo reads Core's $hv_f, which PORTABILITY.md §5 does not declare for downstream use. Add the table row in the same change (declaring is the ask, not a workaround), or probe the tool with \`command -v\` instead"
          ;;
        *)
          fail "HAVE_* contract: $hv_repo reads $hv_f, which it does not set and Core does not set either — a flag Core has removed or renamed, so the read is already dead on every box. Fix the read, or restore the flag in zsh/00-tools.zsh and declare it in PORTABILITY.md §5"
          ;;
        esac
        hv_fail=1
      done
    done
    [ "$hv_checked" = 0 ] && skip_env "HAVE_* contract: fleet half (no sibling OS repo checked out — nothing to read here)"
    ((hv_absent)) && skip_env "HAVE_* contract: $hv_absent repo(s) not checked out — fleet half not covered by this run"
  fi
  if ((hv_fail == 0)); then
    if ((hv_fleet)) && [ "$hv_checked" != 0 ]; then
      pass "HAVE_* contract (declared ⊆ set, set ⇒ read, and $hv_checked checked-out repo(s) read only declared flags)"
    else
      pass "HAVE_* contract (declared ⊆ set, set ⇒ read; the fleet half did not run — see the skip above)"
    fi
  fi
fi
unset hv_tools hv_doc hv_declared hv_ndecl hv_set hv_read hv_f hv_root hv_repo hv_dir hv_uses hv_checked hv_absent hv_fleet hv_fail

# ── 5m. the vendored HAVE_* surface (PORTABILITY.md §5 ↔ zsh/have-api.txt) ───
# §5l is free; this is 5m so the letter matches the file's own reference in core.vendor.
#
# WHY THE DECLARED TABLE NEEDED A MACHINE-READABLE TWIN (#866). §5j direction 2 — no OS
# or role repo reads a Core HAVE_* flag §5 does not declare — never fires in any CI.
# Core's own CI checks out this repo alone, so direction 2 records an environment skip on
# every run (right posture, same as §5f and §5h), and the reusable lint workflow the nine
# OS repos call cannot run it either: it needs the declared table, and PORTABILITY.md is
# not vendored. So an OS-repo PR can add `${HAVE_LNAV:-}` — a flag Core no longer sets —
# and merge green, the break surfacing later as a shell function quietly not firing.
#
# zsh/have-api.txt is that twin: the machine-readable half, vendored, so lint-call.yml's
# contract leg can enforce direction 2 from inside a repo that has never seen the doc.
# This section is what stops the twin from drifting away from the table it is derived
# from — the defect one level up from the one it closes.
#
# ALWAYS ON and NOT SCOPE-GUARDED, for §9g's reasons: pure bash + awk, so it can never
# SKIP; and both inputs are files ci-classify.sh treats as inert, so the very push that
# edits §5's table arrives here as --scope none and must still be gated.
hdr "HAVE_* vendored surface (gen-have-api.sh --check)"
_hva_out="$("$HERE/scripts/gen-have-api.sh" --check 2>&1)" && _hva_rc=0 || _hva_rc=$?
if ((_hva_rc == 0)); then
  pass "gen-have-api (zsh/have-api.txt matches PORTABILITY.md §5's declared table)"
elif ((_hva_rc == 1)); then
  fail "zsh/have-api.txt drift — the vendored HAVE_* surface no longer matches PORTABILITY.md §5; run: make gen-have-api"
  fail_detail "$_hva_out"
else
  fail "gen-have-api.sh --check could not run (exit $_hva_rc) — §5's heading or table is missing, renamed, or parsed empty; the vendored contract went UNCHECKED this run"
  fail_detail "$_hva_out"
fi
unset _hva_out _hva_rc

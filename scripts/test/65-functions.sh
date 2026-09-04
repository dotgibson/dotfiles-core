# scripts/test/65-functions.sh
# function unit tests (zsh/30-functions.zsh) + core-status
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── function unit tests ───────────────────────────────────────────────────────
hdr "function unit tests (functions.zsh)"
FN="$HERE/zsh/30-functions.zsh"
# functions.zsh now routes its errors through ui.zsh's _core_* helpers, so the
# unit shell must source ui.zsh FIRST — the same ordering the real loader uses
# (tools → ui → … → functions). It loads before functions in every assertion below.
UI="$HERE/zsh/05-ui.zsh"

# Run an assertion under zsh; $1 = label, $2 = zsh body that must exit 0.
# On FAILURE we capture the child's combined stdout+stderr and print it INDENTED
# (mirroring the nvim/smoke sections above) — a red unit test must say WHY, not just
# its label, or a CI failure that fans out to nine repos forces a local re-reproduction.
# On PASS the output is discarded, so the expected _core_err/usage noise stays silent.
check() { # check <label> <zsh-body>
  local out
  if out="$(HOME="$SANDBOX" zsh -fc "source '$UI' || exit 1; source '$FN' || exit 1; $2" 2>&1)"; then
    pass "$1"
  else
    fail "$1"
    [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/    /' >&2
  fi
}

# Like check, but SKIP (not fail) when a required external tool is absent — so the
# archive round-trip tests degrade gracefully on a bare box, mirroring the linter
# skips above. extract's own first branch is `ouch` when HAVE_OUCH is set; under
# `zsh -fc` that var is unset, so these exercise the hand-rolled case fallback.
check_dep() { # check_dep <label> <dep> <zsh-body>
  if ! have "$2"; then
    skip "$1 ($2 not installed)"
    return
  fi
  local out
  if out="$(HOME="$SANDBOX" zsh -fc "source '$UI' || exit 1; source '$FN' || exit 1; $3" 2>&1)"; then
    pass "$1"
  else
    fail "$1"
    [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/    /' >&2
  fi
}

check "mkcd creates and enters a nested dir" \
  'd=$(mktemp -d); cd "$d"; mkcd a/b/c; [[ ${PWD:t} == c && -d "$d/a/b/c" ]]'
check "cdup climbs N directories" \
  'd=$(mktemp -d); mkdir -p "$d/a/b/c"; cd "$d/a/b/c"; cdup 2; [[ ${PWD:t} == a ]]'
# Defensive input guards (U1): a bad count / missing file / bad port must be REJECTED
# in Core's voice (non-zero), not silently no-op or handed to cp/python to fail raw.
check "cdup rejects a non-numeric count" \
  'cdup abc 2>/dev/null; (( $? != 0 ))'
check "cdup rejects a zero count" \
  'cdup 0 2>/dev/null; (( $? != 0 ))'
check "mkbak writes a timestamped .bak copy" \
  'd=$(mktemp -d); cd "$d"; print hi > f; mkbak f; set -- f.*.bak; [[ -f $1 ]]'
check "mkbak's .bak is byte-identical to the original" \
  'd=$(mktemp -d); cd "$d"; print -r -- payload > f; mkbak f; set -- f.*.bak; [[ -f $1 && "$(cat -- $1)" == payload ]]'
check "mkbak rejects a missing file" \
  'mkbak /no/such/file 2>/dev/null; (( $? != 0 ))'
check "mkbak with no argument is rejected" \
  'mkbak 2>/dev/null; (( $? != 0 ))'
# U6: a second backup must NOT clobber an existing .bak and must NOT prompt. Pre-create
# the timestamped target, then run mkbak with stdin closed: collision-safe means a SECOND
# .bak appears (≥2 total); had `cp -i` bled in, the closed stdin would abort the copy (1).
# Robust to the same-second/next-second race either way (distinct name OR distinct suffix).
check "mkbak never clobbers an existing .bak (collision-safe, non-interactive)" \
  'd=$(mktemp -d); cd "$d"; print hi > f; ts=$(date +%Y%m%d-%H%M%S); : > "f.$ts.bak"; mkbak f </dev/null >/dev/null 2>&1; n=$(print -l -- f.*.bak(N) | wc -l); (( n >= 2 ))'
check "serve rejects a non-numeric port" \
  'serve abc 2>/dev/null; (( $? != 0 ))'
check "serve rejects an out-of-range port" \
  'serve 99999 2>/dev/null; (( $? != 0 ))'
# serve -l/--local (#10): the loopback flag must be ACCEPTED as a flag (not mis-read as
# the port) while the port is still validated, and an unknown flag must be rejected — all
# before python ever binds, so these stay non-blocking.
check "serve rejects an unknown flag (-l/--local is the only flag)" \
  'serve --nope 2>/dev/null; (( $? != 0 ))'
check "serve -l is parsed as a flag and still validates the port" \
  'serve -l abc 2>/dev/null; (( $? != 0 ))'
# Uniform -h/--help contract (U6): every user-facing verb answers --help on STDOUT
# and returns 0 (a help REQUEST is success, not misuse). This also guards the bugs
# where --help used to be mis-read as an operand — serve as a bad port, extract as a
# missing file (both returned non-zero); the guard must short-circuit before that.
check "mkcd --help prints usage to stdout and returns 0" \
  'out=$(mkcd --help); (( $? == 0 )) && [[ $out == *"usage: mkcd"* ]]'
check "serve --help returns 0 (not mis-read as a bad port)" \
  'out=$(serve --help); (( $? == 0 )) && [[ $out == *"usage: serve"* ]]'
check "extract -h returns 0 (not mis-read as a missing file)" \
  'out=$(extract -h); (( $? == 0 )) && [[ $out == *"usage: extract"* ]]'
# pullall (#git): the parent dir is configurable, so input is validated in Core's
# voice — a non-directory and a bad PULLALL_JOBS are both REJECTED before any find/
# xargs runs. --help is the usual STDOUT-and-return-0 contract. The repo-less-dir
# case exercises the full find→xargs→summary pipeline hermetically (no network, no
# .git, so the workers exit early) and asserts the summary card + a clean exit.
check "pullall --help prints usage to stdout and returns 0" \
  'out=$(pullall --help); (( $? == 0 )) && [[ $out == *"usage: pullall"* ]]'
check "pullall rejects a non-directory parent" \
  'pullall /no/such/dir 2>/dev/null; (( $? != 0 ))'
check "pullall rejects a non-numeric PULLALL_JOBS" \
  'PULLALL_JOBS=x pullall "$(mktemp -d)" 2>/dev/null; (( $? != 0 ))'
check "pullall on a repo-less dir prints the summary and returns 0" \
  'd=$(mktemp -d); mkdir "$d/a" "$d/b"; out=$(pullall "$d" 2>&1); (( $? == 0 )) && [[ $out == *"pullall summary"* && $out == *"updated:  0"* ]]'
# Integration (the bulk of the logic the validation tests above don't reach): build a
# bare remote + a behind clone hermetically (mirrors the gcheck git_* tests below — a
# throwaway $GIT_AUTHOR_* identity and git init in mktemp), advance the remote, then run
# pullall and assert it fast-forwarded the clone (tally "updated: 1", a real new file on
# disk, zero failures). This exercises trunk auto-detection, the --ff-only pull, and the
# ✅ tally — the per-repo path that fans out to all nine OS repos.
check_dep "pullall fast-forwards a behind repo and tallies it (hermetic bare remote)" git \
  'export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e
   w=$(mktemp -d)
   git -c init.defaultBranch=main init -q --bare "$w/remote.git"
   git -c init.defaultBranch=main clone -q "$w/remote.git" "$w/seed"
   ( cd "$w/seed" && print -r -- one > a.txt && git add a.txt && git commit -q -m one && git push -q -u origin main )
   mkdir -p "$w/parent"
   git clone -q "$w/remote.git" "$w/parent/repoA"
   ( cd "$w/seed" && print -r -- two > b.txt && git add b.txt && git commit -q -m two && git push -q origin main )
   out=$(pullall "$w/parent" 2>&1)
   [[ $out == *"updated:  1"* && $out == *"failed:   0"* && -f "$w/parent/repoA/b.txt" ]]'
# The riskier path this PR added: a NON-fast-forward pull ($pull != 0) that ALSO hits a
# stash-pop conflict must report ❌ "pull failed AND a conflict …" and count as a failure,
# NOT a ⚠️ that claims the trunk was updated. Construct it hermetically: diverge the clone
# (local main commit) and the remote (a different commit) so --ff-only fails, then sit on a
# feature branch (forked from before the divergence) with a conflicting uncommitted change
# so the auto-stash pop conflicts after checkout. Asserts the gate + the failure tally.
check_dep "pullall reports a combined pull-failure + stash-pop conflict as a ❌" git \
  'export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e
   w=$(mktemp -d)
   git -c init.defaultBranch=main init -q --bare "$w/remote.git"
   git -c init.defaultBranch=main clone -q "$w/remote.git" "$w/seed"
   ( cd "$w/seed" && print -r -- base > x.txt && git add x.txt && git commit -q -m base && git push -q -u origin main )
   mkdir -p "$w/parent"
   git clone -q "$w/remote.git" "$w/parent/repoA"
   ( cd "$w/seed" && print -r -- remotemain > x.txt && git commit -q -am remotemain && git push -q origin main )
   ( cd "$w/parent/repoA" && print -r -- localmain > x.txt && git commit -q -am localmain && git checkout -q -b feature main~1 && print -r -- dirty > x.txt )
   out=$(pullall "$w/parent" 2>&1)
   [[ $out == *"failed:   1"* && $out == *"pull failed AND a conflict"* ]]'
# core-version (#4): reports the vendored Core stamp so an OS repo can tell WHICH Core
# it carries. $_CORE_VERSION_FILE resolves (via %x) to this repo's core.version here.
check "core-version prints the vendored SemVer stamp" \
  'out=$(core-version); (( $? == 0 )) && [[ $out == "dotfiles-core "[0-9]* ]]'
check "core-version --help returns 0 (not mis-read)" \
  'out=$(core-version --help); (( $? == 0 )) && [[ $out == *"usage: core-version"* ]]'
# ── core-status (#681) ────────────────────────────────────────────────────────
# The provenance panel, and the first runtime consumer core.lock has ever had. What these
# assertions are really defending is the DEGRADATION contract: a status verb that errors on
# the box it is describing is useless exactly when you need it, so a missing core.lock, an
# absent git, a non-git deploy and an undeclared OS layer must each render a stated
# "unknown" and still return 0. Every one of those is a NORMAL state, not a fault.
#
# Hermetic throughout: the module captures its paths at SOURCE time, so each body repoints
# $_CORE_VERSION_FILE / $_CORE_LOCK_FILE after sourcing (the same technique the whatsnew
# block below uses) and no test hook is needed in the product code.
_st="$SANDBOX/status"
mkdir -p "$_st/consumer/core" "$_st/cfg-os" "$_st/cfg-role" "$_st/cfg-bare" "$_st/consumer/os" "$_st/consumer/offensive"
printf '5.5.0\n' >"$_st/consumer/core/core.version"
# A well-formed lock, byte-shaped like the real thing sync-core.sh writes (comment header
# included, so the reader is proven to skip it rather than parse it as a key).
# The header below is a VERBATIM copy of what scripts/sync-core.sh:625 writes, `(B1)` and
# all. It is product output, not a reference to this suite's old section lettering — do not
# "clean it up" here without changing the generator, or the fixture stops matching reality.
cat >"$_st/consumer/core.lock" <<'LOCK'
# GENERATED by dotfiles-core sync-core.sh — vendored Core provenance (B1).
core_version=5.5.0
core_sha=6a81418ed7e0a045b0d5fe9a7cd4dd67d7556f50
core_ref=main
core_tag=v5.5.0
LOCK
# The OS/role layers are read from SYMLINK TARGETS, so the fixture must be real symlinks.
: >"$_st/consumer/os/fedora.zsh"
: >"$_st/consumer/offensive/offensive.zsh"
ln -sf "$_st/consumer/os/fedora.zsh" "$_st/cfg-os/80-os.zsh"
ln -sf "$_st/consumer/os/fedora.zsh" "$_st/cfg-role/80-os.zsh"
ln -sf "$_st/consumer/offensive/offensive.zsh" "$_st/cfg-role/85-offensive.zsh"
# A lock value carrying BOTH characters JSON must escape. These are authored by an OS
# repo, not drawn from Core's fixed literal tool list the way core-doctor's names are, so
# the emitter cannot assume they are safe. Written here rather than inside a test body:
# a quote and a backslash surviving bash -> zsh -c -> a single-quoted body intact is its
# own puzzle, and getting it wrong would silently weaken the assertion.
printf '%s\n' 'core_version=5.5.0' 'core_tag=v"5.5\0' >"$_st/quote.lock"
_st_env="_CORE_VERSION_FILE='$_st/consumer/core/core.version'; _CORE_LOCK_FILE='$_st/consumer/core.lock'; export CORE_NO_PAGER=1 NO_COLOR=1;"

check "core-status renders every row of the panel" \
  "$_st_env out=\$(core-status 2>&1); (( \$? == 0 )) &&
   [[ \$out == *'dotfiles-core 5.5.0'* && \$out == *'OS layer'* && \$out == *'Role layer'* &&
      \$out == *'Tools'* && \$out == *'Integrity'* ]]"
# The provenance line renders core_tag AND the short sha — the same display fallback
# fleet-drift.sh / core-integrity.sh use for their RECORDED column. The sha is truncated to
# 8, so the assertion pins the prefix and the absence of the full 40.
check "core-status renders core.lock's tag and short sha" \
  "$_st_env out=\$(core-status 2>&1); (( \$? == 0 )) &&
   [[ \$out == *'v5.5.0'* && \$out == *'6a81418e'* && \$out != *'6a81418ed7e0a045'* ]]"
# DEGRADATION 1 — no core.lock. This is BOTH the dotfiles-core source tree (which has no
# lock because it is not a consumer) and a consumer whose lock went missing. Neither may
# error, and neither may leak a shell's raw "no such file" at the reader.
check "core-status degrades to a stated unknown when core.lock is absent" \
  "$_st_env _CORE_LOCK_FILE='$_st/nope/core.lock'; out=\$(core-status 2>&1); (( \$? == 0 )) &&
   [[ \$out == *'provenance unknown'* && \${(L)out} != *'no such file'* ]]"
# DEGRADATION 2 — a lock that exists but says nothing. The reader must not half-answer: a
# comment-only file yields no keys, so the row says the file is empty rather than printing
# an empty tag and an empty sha as though they were values.
check "core-status reports an empty core.lock as such, not as blank values" \
  "$_st_env _CORE_LOCK_FILE='$_st/empty.lock'; print -r -- '# only a comment' >| '$_st/empty.lock'
   out=\$(core-status 2>&1); (( \$? == 0 )) && [[ \$out == *'present but empty'* ]]"
# core.version and core.lock's core_version are stamped by the SAME sync and always agree.
# Disagreement is a TAMPER signal (a hand-edit, or a bare `git subtree pull` that moved
# core/ and left the lock behind), so it earns the ⚠ MODIFIER — never a row state.
check "core-status flags a core.version/core.lock disagreement" \
  "$_st_env _CORE_LOCK_FILE='$_st/skew.lock'; print -rl -- 'core_version=4.0.0' 'core_tag=v4.0.0' >| '$_st/skew.lock'
   out=\$(core-status 2>&1); (( \$? == 0 )) && [[ \$out == *'disagree'* && \$out == *'4.0.0'* && \$out == *'5.5.0'* ]]"
# DEGRADATION 3 — no git at all. PATH is emptied rather than git stubbed, because the
# question is what the verb does on a box where the binary genuinely is not there.
check "core-status degrades when git is absent, and still returns 0" \
  "$_st_env PATH=/nonexistent; out=\$(core-status 2>&1); (( \$? == 0 )) &&
   [[ \$out == *'unknown (git not available)'* ]]"
# DEGRADATION 4 — a real directory that is not a git checkout (a tarball deploy, an
# rsync'd box). Distinct message from "no git", because the remedy is different.
check "core-status degrades on a non-git deploy" \
  "$_st_env out=\$(core-status 2>&1); (( \$? == 0 )) && [[ \$out == *'unknown (not a git checkout)'* ]]"
# The OS layer's NAME comes from the 80-os.zsh symlink target, not from \$_CORE_CAP: the
# capability schema deliberately has no OS-name key. Role likewise, from the 85-94 band.
check "core-status names the OS layer from its 80-os.zsh symlink" \
  "$_st_env ZSH_CFG='$_st/cfg-os'; out=\$(core-status 2>&1); (( \$? == 0 )) && [[ \$out == *'fedora'* ]]"
check "core-status reports 'none' when no role layer is wired" \
  "$_st_env ZSH_CFG='$_st/cfg-os'; out=\$(core-status 2>&1); (( \$? == 0 )) &&
   [[ \$out == *'Role layer'*'none'* ]]"
check "core-status names the role layer from the 85-94 band" \
  "$_st_env ZSH_CFG='$_st/cfg-role'; out=\$(core-status 2>&1); (( \$? == 0 )) && [[ \$out == *'offensive'* ]]"
# Since #763 an undeclared box has no fallback to name, so this row stopped being a note
# about WHICH source answered and became the reason `up`, the doctor's install hint and
# maint-install have nothing to work with. It must therefore carry the REMEDY, not just the
# fact — this panel is where an operator looks when those start failing.
check "core-status names the missing declaration AND the remedy when nothing is linked" \
  "$_st_env ZSH_CFG='$_st/cfg-bare'; out=\$(core-status 2>&1); (( \$? == 0 )) &&
   [[ \$out == *'no os.capabilities linked'* && \$out == *'--links-only'* ]]"
check "core-status --help returns 0 (not mis-read as a flag)" \
  "$_st_env out=\$(core-status --help); (( \$? == 0 )) && [[ \$out == *'usage: core-status'* ]]"
check "core-status rejects an unknown flag with a did-you-mean" \
  "$_st_env out=\$(core-status --jsonn 2>&1); (( \$? != 0 )) && [[ \$out == *'did you mean --json'* ]]"
check "core status routes to core-status" \
  "$_st_env out=\$(core status 2>&1); (( \$? == 0 )) && [[ \$out == *'dotfiles-core 5.5.0'* ]]"
check "status is registered in \$_CORE_SUBCMDS (the completion + did-you-mean read it)" \
  '[[ " ${_CORE_SUBCMDS[*]} " == *" status "* ]]'
# The `local`-in-a-loop hazard that shipped literal `_v=` lines into core-doctor -v. The
# panel builds several arrays in loops, so pin it here too — NO_COLOR keeps the match on
# plain text and would not hide an escape-wrapped leak.
check "core-status leaks no name=value lines into the panel" \
  "$_st_env out=\$(core-status 2>&1); (( \$? == 0 )) &&
   [[ \$out != *'_cs_'*=* && \$out != *'REPLY='* && \$out != *'kw='* ]]"
check "core-status renders plain text under NO_COLOR" \
  "$_st_env out=\$(core-status 2>&1); (( \$? == 0 )) && [[ \$out != *\$'\\e['* ]]"

# The integrity row's real subject: a hand-edit under core/, which the next sync silently
# clobbers. Needs a genuine git checkout, so build one — bare-config pinning copied from
# gcheck below so the host's git identity/defaultBranch cannot skew it.
if ! have git; then
  skip "core-status integrity rows (git not installed)"
else
  _stg="$_st/gitrepo"
  mkdir -p "$_stg/core/zsh"
  printf '5.5.0\n' >"$_stg/core/core.version"
  # A second vendored file, so "edit something under core/" does not also change the
  # version stamp and set off the core.version/core.lock disagreement warning — the row
  # under test would still pass, but the panel would carry an unrelated warning and the
  # fixture would be exercising two behaviours at once.
  printf '# vendored\n' >"$_stg/core/zsh/30-functions.zsh"
  cp "$_st/consumer/core.lock" "$_stg/core.lock"
  (
    cd "$_stg" || exit 1
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e
    git init -q . && git add -A && git commit -qm 'vendor core'
  ) >/dev/null 2>&1
  _stg_env="_CORE_VERSION_FILE='$_stg/core/core.version'; _CORE_LOCK_FILE='$_stg/core.lock'; export CORE_NO_PAGER=1 NO_COLOR=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null;"
  check "core-status reports a pristine core/ as matching its commit" \
    "$_stg_env out=\$(core-status 2>&1); (( \$? == 0 )) && [[ \$out == *'core/ matches its commit'* ]]"
  # The sync age is read from core.lock's own COMMIT date, never the file's mtime — a
  # checkout or a rebase rewrites mtimes without the vendored Core having moved.
  # The age reads "just now" under an hour and "N hours/days ago" past it, so the
  # assertion pins the LABEL rather than a duration this fixture can never produce.
  check "core-status reports when core.lock was last committed" \
    "$_stg_env out=\$(core-status 2>&1); (( \$? == 0 )) && [[ \$out == *'synced '* ]]"
  check "core-status counts an edited vendored file" \
    "$_stg_env print -r -- 'tampered' >>| '$_stg/core/zsh/30-functions.zsh'
     out=\$(core-status 2>&1); (( \$? == 0 )) && [[ \$out == *'1 file(s) edited since commit'* ]]"
  # Scoped to core/ on purpose: unrelated work in the OS repo's own os/ or install/ is not
  # a Core integrity problem and must not read as one.
  check "core-status ignores changes outside core/" \
    "$_stg_env git -C '$_stg' checkout -q -- core
     print -r -- 'x' >| '$_stg/unrelated.txt'
     out=\$(core-status 2>&1); (( \$? == 0 )) && [[ \$out == *'core/ matches its commit'* ]]"
fi

# --json (#681): the same facts as one object, for a statusline or a gate. Must PARSE, and
# its tool counts must equal what core-doctor reports — the two walk the same inventories
# through the same predicates (_core_doctor_tally), and this is what keeps them from
# drifting apart the day a predicate changes.
check_dep "core-status --json emits a parseable object with the documented keys" python3 \
  "$_st_env out=\$(core-status --json); (( \$? == 0 )) && print -r -- \"\$out\" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d[\"lock\"][\"core_tag\"]==\"v5.5.0\", d[\"lock\"]
assert d[\"lock\"][\"present\"] is True
assert d[\"integrity\"][\"status\"] in (\"clean\",\"dirty\",\"unknown\",\"na\"), d[\"integrity\"]
assert isinstance(d[\"tools\"][\"present\"],int) and isinstance(d[\"tools\"][\"total\"],int)
'"
check_dep "core-status --json tool counts agree with core-doctor --json (no second implementation)" python3 \
  "$_st_env s=\$(core-status --json); d=\$(core-doctor --json); print -r -- \"\$s\" >| '$_st/s.json'; print -r -- \"\$d\" >| '$_st/d.json'
   python3 -c '
import json
s=json.load(open(\"$_st/s.json\")); d=json.load(open(\"$_st/d.json\"))
assert s[\"tools\"][\"total\"]==len(d[\"tools\"]), (s[\"tools\"][\"total\"], len(d[\"tools\"]))
assert s[\"tools\"][\"present\"]==sum(1 for v in d[\"tools\"].values() if v), (s[\"tools\"][\"present\"],)
assert s[\"tools\"][\"wirable\"]==len(d[\"wired\"]), (s[\"tools\"][\"wirable\"], len(d[\"wired\"]))
assert s[\"tools\"][\"wired\"]==sum(1 for v in d[\"wired\"].values() if v), (s[\"tools\"][\"wired\"],)
'"
# A lock value is authored by an OS repo, not drawn from Core's fixed literal list the way
# core-doctor's tool names are — so a quote or a backslash in one must escape rather than
# produce an object no parser will accept.
check_dep "core-status --json escapes a quote and a backslash in a core.lock value" python3 \
  "$_st_env _CORE_LOCK_FILE='$_st/quote.lock'
   out=\$(core-status --json); (( \$? == 0 )) && print -r -- \"\$out\" | python3 -c '
import json,sys
got=json.load(sys.stdin)[\"lock\"][\"core_tag\"]
want=\"v\"+chr(34)+\"5.5\"+chr(92)+\"0\"
assert got==want, (got, want)
'"

# core-doctor (#9): the shell-side health report. Must render and return 0 even on a
# bare box (every tool ✗) — it's read-only diagnostics, never a hard failure.
# Every group label must render, and a tool must land under the group it was filed in. The
# parity check below compares tool NAMES between the two inventories, so deleting a whole
# group — label and members, from both — slips past it; and the render test underneath only
# greps for "modern CLI", which predates the `data / net` and `dev / repo` groups. Assert all
# four labels, then that watchexec renders AFTER the `dev / repo` heading rather than merely
# somewhere in the report. (Parity then carries this to --json: render set == tools keys.)
check "core-doctor renders every group label and files watchexec under dev / repo" \
  '_core_have() { return 1; }
   _core_doctor_present() { return 1; }
   out=$(NO_COLOR=1 core-doctor 2>&1); (( $? == 0 )) \
     && [[ $out == *"modern CLI"* && $out == *"integrations"* ]] \
     && [[ $out == *"data / net"* && $out == *"dev / repo"* ]] \
     && [[ ${out#*"dev / repo"} == *watchexec* ]]'
check "core-doctor renders a health report and returns 0" \
  'out=$(NO_COLOR=1 core-doctor 2>&1); (( $? == 0 )) && [[ $out == *dotfiles-core* && $out == *"modern CLI"* ]]'
# core-doctor -v (#9): the version readout. Regression guard for a leak that made the whole
# flag useless — `local _v` sat INSIDE the per-tool loop, and zsh prints `name=value` when
# `local` re-declares a parameter that already holds one (TYPESET_SILENT is off under
# `emulate -L zsh`), so every tool after the first emitted a bare `_v=0.26.1` line into the
# report instead of annotating the ✓. Nothing drove -v, so it shipped broken. Hermetic: stub
# _core_have to admit specific tools and shadow those tools with functions (zsh resolves them
# for the `"$tool" --version` probe), so this asserts real rendering rather than whatever is
# on PATH. TWO tools, deliberately: the leak only fires on the SECOND re-declaration, so a
# single-tool version of this test passes against the unfixed code and guards nothing.
check "core-doctor -v annotates versions and leaks no _v= lines" \
  '_core_have() { [[ "$1" == (eza|bat) ]]; }
   _core_doctor_present() { [[ "$1" == (eza|bat) ]]; }
   eza() { print -r -- "eza 9.9.9"; }
   bat() { print -r -- "bat 8.8.8"; }
   out=$(NO_COLOR=1 core-doctor -v 2>&1); (( $? == 0 )) \
     && [[ $out == *"✓ eza 9.9.9"* ]] && [[ $out == *"✓ bat 8.8.8"* ]] && [[ $out != *"_v="* ]]'
check "core-doctor --help returns 0 (not mis-read)" \
  'out=$(core-doctor --help); (( $? == 0 )) && [[ $out == *"usage: core-doctor"* ]]'
# core-doctor --json: a machine-readable object on stdout that actually parses and
# carries the tools/wired/atuin_daemon/resolved keys — so a statusline/editor/CI can consume
# health. atuin_daemon's shape is asserted exactly (not just present): it is the one field here
# describing state that can change under a LIVE shell, so a consumer polling it needs both
# booleans to keep meaning what they say.
check "core-doctor --json emits parseable JSON with tools/wired/atuin_daemon/resolved" \
  'out=$(core-doctor --json); print -r -- "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert set([\"version\",\"tools\",\"expected\",\"wired\",\"detection\",\"atuin_daemon\",\"resolved\"]) <= set(d); assert set(d[\"atuin_daemon\"]) == set([\"degraded\",\"was_up\"]); assert set(d[\"detection\"]) == set([\"ran\",\"missed\",\"stale\"]); assert isinstance(d[\"detection\"][\"ran\"], bool) and isinstance(d[\"detection\"][\"missed\"], list) and isinstance(d[\"detection\"][\"stale\"], list)"'
# The human report and --json now BOTH derive from _CORE_DOCTOR_GROUPS, so they agree by
# construction and this assertion should be tautological. It is kept precisely for that
# reason: it is the guard that stays red if someone reintroduces a second literal — which is
# how these two lived before, and they did silently desync. Treat a failure here as "the
# single source was forked", not as a missing tool. Assert the two NAME SETS are equal.
# _core_have is stubbed false so the render is deterministic:
# every tool prints as a plain ✗ (no --version forks), the "integrations wired" block skips
# every entry, and "resolved" carries no ✓/✗ markers — leaving the group lists as the only
# thing the regex can match. Skips rather than fails without python3, like the linters above.
check_dep "core-doctor's rendered tool set == --json tools (the two inventories can't drift)" python3 \
  '_core_have() { return 1; }
   _core_doctor_present() { return 1; }
   _r=$(NO_COLOR=1 core-doctor 2>&1); _j=$(core-doctor --json)
   _CD_R="$_r" _CD_J="$_j" python3 -c "
import json, os, re
body  = os.environ[\"_CD_R\"].split(chr(10), 1)[1]   # drop line 1: the header legend, not tools
body  = body.split(chr(10) + \"opt-in\")[0]           # and the trailing opt-in recap, which re-lists names
shown = set(re.findall(r\"[✓✗·] ([A-Za-z0-9_.-]+)\", body))
keys  = set(json.loads(os.environ[\"_CD_J\"])[\"tools\"])
assert shown, \"parsed no tools out of the rendered report\"
assert shown == keys, \"render-only: %s | json-only: %s\" % (sorted(shown - keys), sorted(keys - shown))
"'
# ── the third state (#513) ────────────────────────────────────────────────────────────
# `✗` is the doctor's only alarm channel, and PORTING-MATRIX.md's footnote ²¹ names a subset
# of the inventory that NO Linux repo's packages.txt and NO bootstrap.sh installs, on purpose.
# Rendering both as ✗ meant a correctly-provisioned box showed a wall of them, so a REAL
# regression — a tool that was installed and broke — landed in the same visual bucket as the
# ones that were never coming.
check "core-doctor renders opt-in absence as · and expected absence as ✗" \
  '_core_have() { return 1; }
   _core_doctor_present() { return 1; }
   out=$(NO_COLOR=1 core-doctor 2>&1)
   [[ $out == *"· lnav"* ]] && [[ $out == *"· git-absorb"* ]] \
     && [[ $out == *"✗ eza"* ]] && [[ $out == *"✗ jq"* ]] \
     && [[ $out != *"✗ lnav"* ]] && [[ $out != *"· eza"* ]]'
# The legend has to name all three or the third glyph is a mystery mark. Asserted because the
# glyph set and the legend are two literals in one function and drifted once already.
check "core-doctor's legend names all three states" \
  'out=$(NO_COLOR=1 core-doctor 2>&1 | head -n1)
   [[ $out == *"✓ present"* ]] && [[ $out == *"✗ expected but missing"* ]] \
     && [[ $out == *"· opt-in"* ]]'
# `·` and not `○`: the wired block below the tools uses ○ for "installed but IDLE". Two
# meanings for one glyph on one screen is the legibility problem this change is about, so the
# separation is pinned rather than left to whoever edits next.
# ── the opt-in split is PER REPO now (#666) ──────────────────────────────────
# The bug: one Core-side list cannot say "opt-in over there, expected here", so `jj` and
# `ast-grep` — 21 in the Gentoo and Kali cells ONLY — were reported as expected on every
# box, showing a degraded integration where nothing was wrong. That is the failure mode
# most likely to train an operator to ignore the report.
#
# `check` sources ui + 30-functions only, so these need 02-capabilities and a seeded
# declaration; hence a local runner rather than reusing it.
CAPD_DOC="$SANDBOX/capdoc"
rm -rf "$CAPD_DOC"
mkdir -p "$CAPD_DOC"
_doccheck() { # _doccheck <label> <decl> <zsh-body>
  local label="$1" decl="$2" body="$3" out
  printf '%s\n' "$decl" >"$CAPD_DOC/os.capabilities"
  if out="$(HOME="$SANDBOX" CORE_CAPABILITIES_FILE="$CAPD_DOC/os.capabilities" \
      zsh -fc "source '$UI' || exit 1; source '$HERE/zsh/02-capabilities.zsh' || exit 1; source '$FN' || exit 1; $body" 2>&1)"; then
    pass "$label"
  else
    fail "$label"
    [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/    /' >&2
  fi
}
# THE FIX, stated as the bug it closes: a repo that declares jj opt-in gets a dot, and the
# same tool stays a cross on a repo that does not — the sentence the old list could not
# express in both directions at once.
_doccheck "core-doctor: a declared TOOLS_OPTIN reclassifies jj as opt-in" \
  'TOOLS_OPTIN=jj ast-grep' \
  '_core_doctor_optin jj && _core_doctor_optin ast-grep'
_doccheck "core-doctor: a tool absent from a declared TOOLS_OPTIN is EXPECTED" \
  'TOOLS_OPTIN=jj ast-grep' \
  '! _core_doctor_optin lnav'
# ...and the JSON contract moves with the render, because a gate asserting `expected` must
# not disagree with the glyph a human reads two lines above it.
_doccheck "core-doctor --json: expected follows the declared split, not Core's list" \
  'TOOLS_OPTIN=jj ast-grep' \
  '_core_have() { return 1 }
   _core_doctor_present() { return 1 }
   out=$(core-doctor --json 2>&1)
   q=$(printf \\42)
   exp=${out#*expected}
   [[ $exp == *${q}jj${q}:false* ]] && [[ $exp == *${q}lnav${q}:true* ]]'
# PER-KEY FALLBACK, and deliberately unlike `up` and the maint runner. A declaration is
# authoritative there because an OMISSION IS A SAFETY STATEMENT (no assume-yes token means
# never auto-confirm). TOOLS_OPTIN carries no such claim — omitting it says the repo has not
# curated a list, not that nothing is optional — and reading it as "nothing is opt-in" would
# mark every uninstalled optional tool degraded, manufacturing the alarm fatigue the state
# exists to prevent.
_doccheck "core-doctor: a declaration with no TOOLS_OPTIN falls back to Core's default" \
  'PKG_UPGRADE=sudo dnf upgrade --refresh' \
  '_core_doctor_optin lnav && ! _core_doctor_optin jj'
# An EMPTY declared value is the same as absent — _core_cap's own contract, and the thing
# that stops `TOOLS_OPTIN=` from silently meaning "everything is expected".
_doccheck "core-doctor: an empty TOOLS_OPTIN is 'not declared', not 'nothing is opt-in'" \
  'TOOLS_OPTIN=' \
  '_core_doctor_optin lnav'
# #666 warned these two could disagree: #697 added stale-flag reporting, and this changes
# what "expected" means underneath it. They are independent by construction —
# _core_doctor_stale runs on BOTH the opt-in and the missing branch — and this pins that, so
# a future edit cannot quietly make a reclassified tool stop being checked for a stale flag.
# _CORE_PROBED is band 00's ledger and these tests source three fragments, so it is seeded
# here: without it _core_doctor_stale returns early ("detection never ran") and the
# assertion would pass for the wrong reason on a run that proved nothing.
_doccheck "core-doctor: reclassifying a tool opt-in does not stop stale-flag reporting (#697)" \
  'TOOLS_OPTIN=jq' \
  '_core_have() { return 1 }
   _core_doctor_present() { return 1 }
   HAVE_JQ=1
   typeset -gA _CORE_PROBED=(jq 1)
   out=$(NO_COLOR=1 core-doctor 2>&1)
   [[ $out == *"· jq"* ]] && [[ $out == *stale* ]]'

check "core-doctor does not reuse the wired block's ○ for opt-in tools" \
  '_core_have() { return 1; }
   _core_doctor_present() { return 1; }
   out=$(NO_COLOR=1 core-doctor 2>&1)
   [[ $out != *"○ lnav"* ]] && [[ $out != *"○ ouch"* ]]'
# An opt-in tool must NOT join the "install missing" list. That block exists to tell the
# operator what to fix; listing something nothing was ever going to install is the same alarm
# fatigue one layer down.
check "core-doctor keeps opt-in tools out of the install-missing list" \
  '_core_have() { return 1; }
   _core_doctor_present() { return 1; }
   _core_cap() { [[ $1 == PKG_INSTALL ]] && print -r -- "sudo apt install"; }
   out=$(NO_COLOR=1 core-doctor 2>&1)
   inst=${out#*"install missing"}; inst=${inst%%"opt-in"*}
   [[ $out == *"install missing"* ]] && [[ $inst == *"eza"* ]] && [[ $inst != *"lnav"* ]]'
# THE POINT OF THE WHOLE CHANGE, in the machine-readable half: "no expected tool is missing"
# had no expressible form. `tools` alone can only answer "is every tool present", which is
# false on every correctly-provisioned box, so a provisioning gate could not be written at all.
check_dep "core-doctor --json exposes 'expected', so a gate can assert what actually matters" python3 \
  '_core_have() { return 1; }
   _core_doctor_present() { return 1; }
   _CD_J="$(core-doctor --json)" python3 -c "
import json, os
d = json.loads(os.environ[\"_CD_J\"])
t, e = d[\"tools\"], d[\"expected\"]
assert list(e) == list(t), \"expected and tools must share key set AND order\"
assert all(v is False for v in t.values()), \"the stub makes every tool absent\"
# with everything absent, the gate must flag exactly the EXPECTED ones — not all of them
gate = sorted(k for k, v in e.items() if v and not t[k])
optin = sorted(k for k, v in e.items() if not v)
assert \"lnav\" in optin and \"git-absorb\" in optin, optin
assert \"eza\" in gate and \"jq\" in gate, gate
assert not (set(gate) & set(optin)), \"a tool cannot be both\"
"'
# MAKE THE PROSE MECHANICALLY CHECKABLE. _CORE_DOCTOR_OPTIN is seeded from PORTING-MATRIX.md
# footnote ²¹, and a hand-copied list is how the matrix and the inventory drift apart — which
# is exactly what happened in the other direction when a probed tool shipped with no matrix
# row at all (#514). Re-derive the list from the matrix and require the two to agree.
#
# The rule, stated once here and in the array's comment: a tool is opt-in iff its Tool cell
# carries a ROW-level ²¹, or one of the two footnotes ²¹ itself calls "the same shape" (¹⁷
# jnv, ¹⁹ gping). Cell-level ²¹ (jj, ast-grep — Gentoo and Kali only) is still deliberately
# NOT included, but the REASON changed in #666. It used to be that a Core-side list could not
# say "opt-in there, expected here" at all, so muting them globally would have hidden a real
# ✗ on the repos that do install them. Now it can — the OS repo says so in TOOLS_OPTIN — and
# this array is only the DEFAULT for a box that has not. A cell-level case belongs to the
# repo whose cell it is, so it must still stay out of here.
check_dep "core-doctor's opt-in list is derivable from PORTING-MATRIX footnote 21" python3 \
  '_MATRIX="'"$HERE"'/PORTING-MATRIX.md" _OPTIN="${_CORE_DOCTOR_OPTIN[*]}" python3 -c "
import os, re
lines = open(os.environ[\"_MATRIX\"]).read().split(chr(10))
# Only the AUTHORITATIVE package-names table, bounded to its own CONTIGUOUS rows. Footnote 21
# carries a coverage table of its own whose first column is backticked tool names, and it sits
# between this table and the next \"## \" heading — so slicing on headings swept it in. A
# derivation that reads the wrong table is worse than none, because it looks rigorous.
i = next(n for n, l in enumerate(lines) if l.startswith(\"## Package names (modern CLI stack)\"))
i = next(n for n in range(i, len(lines)) if lines[n].startswith(\"| Tool\"))
rows = []
while i < len(lines) and lines[i].startswith(\"|\"):
    rows.append(lines[i]); i += 1
want = set()
for cell in re.findall(r\"(?m)^\\| *([^|]+?) *\\|\", chr(10).join(rows)):
    name = re.split(r\"[ ⁰¹²³⁴⁵⁶⁷⁸⁹]\", cell, maxsplit=1)[0]
    if set(re.findall(r\"[⁰¹²³⁴⁵⁶⁷⁸⁹]+\", cell)) & set([\"²¹\", \"¹⁷\", \"¹⁹\"]):
        want.add(name)
have = set(os.environ[\"_OPTIN\"].split())
assert want, \"parsed no footnote-21 rows out of PORTING-MATRIX.md\"
assert want == have, \"matrix-only: %s | list-only: %s\" % (sorted(want - have), sorted(have - want))
"'
# ── detection divergence: `✓` must stop meaning "Core wired this" (#545) ─────
# HAVE_* is decided at band 00 against a PATH that keeps changing afterwards (mise's chpwd
# hook, 80-os.zsh, an 85-* role fragment, 99-local.zsh). core-doctor probes LIVE against the
# finished PATH, so a tool contributed by any of those rendered a clean ✓ while Core had
# wired nothing — no alias, no init, no flag. These drive the _CORE_PROBED ledger directly:
# `check` sources ui+functions ONLY, so band 00 never runs and the ledger is whatever the
# body sets, which is exactly the control this needs.
check "core-doctor marks a present-but-unwired tool with ⚠ and names it" \
  '_core_have() { return 0 }
   _core_doctor_present() { return 0 }
   typeset -gA _CORE_PROBED=(eza 1 procs 0)
   out=$(_CORE_FORCE_COLOR= core-doctor)
   [[ $out == *"procs⚠"* ]] || { print -r -- "no ⚠ on procs"; exit 1 }
   [[ $out != *"eza⚠"* ]]   || { print -r -- "⚠ on eza, which WAS probed"; exit 1 }
   [[ $out == *"not wired"* ]] || { print -r -- "no not-wired block"; exit 1 }
   [[ $out != *"mark="* ]]  || { print -r -- "local re-declaration leaked mark= into the report"; exit 1 }'
# The sentinel. Without a ledger, 00-tools.zsh never ran in this shell — a script, `zsh -c`,
# or this very harness — and the honest answer is to make NO claim. Reporting 41 unwired
# tools there would be worse than silence, and would red every unit harness in the suite.
check "core-doctor makes no wiring claim when detection never ran" \
  '_core_have() { return 0 }
   _core_doctor_present() { return 0 }
   out=$(_CORE_FORCE_COLOR= core-doctor)
   [[ $out != *"⚠"* ]]        || { print -r -- "⚠ rendered with no ledger"; exit 1 }
   [[ $out != *"not wired"* ]] || { print -r -- "not-wired block rendered with no ledger"; exit 1 }'
check_dep "core-doctor --json reports detection.ran=false when band 00 never loaded" python3 \
  '_core_have() { return 0 }
   _core_doctor_present() { return 0 }
   core-doctor --json | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"detection\"][\"ran\"] is False, d[\"detection\"]; assert d[\"detection\"][\"missed\"] == [], d[\"detection\"]"'
# Second gate: a row Core does not probe AT ALL must draw no claim either. Without this,
# every doctor row with no 00-tools.zsh probe behind it would false-positive as unwired.
check "core-doctor makes no wiring claim for a row Core never probes" \
  '_core_have() { return 0 }
   _core_doctor_present() { return 0 }
   typeset -gA _CORE_PROBED=(eza 1)
   out=$(_CORE_FORCE_COLOR= core-doctor)
   [[ $out != *"op⚠"* ]] || { print -r -- "⚠ on a row with no ledger entry"; exit 1 }'
# The parity test above stubs _core_have FALSE and never populates the ledger, so it cannot
# fire this axis at all — which makes "the ⚠ is invisible to it by construction" an untested
# claim. Re-run the same comparison with the axis ACTIVELY firing.
check_dep "the render⇄json tool sets still match with the ⚠ axis firing" python3 \
  '_core_have() { return 0 }
   _core_doctor_present() { return 0 }
   typeset -gA _CORE_PROBED=(procs 0 jnv 0)
   _CD_R="$(NO_COLOR=1 core-doctor 2>&1)" _CD_J="$(core-doctor --json)" python3 -c "
import json, os, re
# Same two trims as the parity test this mirrors: line 1 is the legend (it contains the
# glyphs), and everything from the opt-in recap on re-lists names. The not-wired block sits
# AFTER opt-in precisely so this second trim covers it structurally.
body = os.environ[\"_CD_R\"].split(chr(10), 1)[1]
body = body.split(chr(10) + \"opt-in\")[0]
shown = set(re.findall(r\"[✓✗·] ([A-Za-z0-9_.-]+)\", body))
keys  = set(json.loads(os.environ[\"_CD_J\"])[\"tools\"])
assert shown, \"parsed no tools out of the rendered report\"
assert shown == keys, \"render-only: %s | json-only: %s\" % (sorted(shown - keys), sorted(keys - shown))
"'

# ── #631: the MIRROR of #545 — a flag set at band 00 for a binary that is now GONE ───────
# #545's case is present-but-unprobed. This is probed-but-absent: HAVE_* is still set, so
# 20-aliases.zsh's guard passed and defined an alias against a binary that no longer resolves.
# Deliberately NO fifth glyph — the row keeps its honest ✗ and the remedy lives in a `stale`
# block, so the legend and the render⇄json parity regex are both untouched.
check "core-doctor reports a stale flag in a 'stale' block, with no new glyph" \
  '_core_have() { return 1 }
   _core_doctor_present() { return 1 }
   typeset -gA _CORE_PROBED=(procs 1)
   out=$(NO_COLOR=1 core-doctor 2>&1)
   [[ $out == *"stale"* ]]  || { print -r -- "no stale block for a probed-then-absent tool"; exit 1 }
   [[ $out == *"procs"* ]]  || { print -r -- "stale block does not name the tool"; exit 1 }
   [[ $out == *"✗ procs"* ]] || { print -r -- "the row should still render an honest ✗"; exit 1 }'
# The point of the block is the ALIAS, not the tool: `ps` is the command that breaks, `procs`
# is trivia the user never typed. Read from the live `aliases` table, so it cannot drift from
# 20-aliases.zsh.
check "core-doctor names the ALIAS a stale flag left pointing at nothing" \
  '_core_have() { return 1 }
   _core_doctor_present() { return 1 }
   typeset -gA _CORE_PROBED=(procs 1)
   alias ps=procs
   out=$(NO_COLOR=1 core-doctor 2>&1)
   [[ $out == *"ps → procs"* ]] || { print -r -- "did not name the broken alias; got: ${out##*stale}"; exit 1 }'
# THE REGRESSION GUARD FOR #715, and the reason _core_doctor_present exists at all. This one
# does NOT stub the presence probe: it drives the REAL one, because the bug was IN the real
# one. `_core_have` is `command -v` and zsh's `command -v` resolves aliases, so a tool that
# had left $PATH still answered yes off the alias 20-aliases.zsh defines for it — the row
# rendered ✓, the else-branch never ran, and the tool never joined `stale`. `rg` was blind
# this way on every distro. Stubbing presence here would test the stub; shadowing a tool with
# an alias and asserting the row is still honest tests the thing that broke.
check "_core_doctor_present is blind to aliases (where _core_have was not)" \
  '_cdp_name=__core_alias_only_probe__
   alias $_cdp_name="true --pretend"
   _core_have "$_cdp_name" || { print -r -- "precondition gone: command -v no longer resolves aliases"; exit 1 }
   ! _core_doctor_present "$_cdp_name" || { print -r -- "presence probe still reads an alias as a tool"; exit 1 }
   _core_doctor_present sh || { print -r -- "presence probe lost a real PATH binary"; exit 1 }
   _core_doctor_present "$(command -v sh)" || { print -r -- "presence probe lost an absolute path"; exit 1 }
   ! _core_doctor_present /nope/not/a/binary || { print -r -- "presence probe accepted a bogus path"; exit 1 }'
# Both ledger gates apply here exactly as they do to the unwired axis — a doctor that claims
# staleness with no ledger would flag every absent tool on a bare box, which is most of them.
check "core-doctor makes no staleness claim when detection never ran" \
  '_core_have() { return 1 }
   _core_doctor_present() { return 1 }
   out=$(NO_COLOR=1 core-doctor 2>&1)
   [[ $out != *"stale"* ]] || { print -r -- "stale block rendered with no ledger"; exit 1 }'
# With _core_have stubbed FALSE every row is absent, so the second gate here is not "no block
# at all" (as it is for #545's ⚠, which fires on the present branch) but "only ledger rows
# appear in it". Asserted on the NAMES line alone — the prose underneath contains "open a new
# shell", and a substring match for a tool called `op` finds the "op" in "open".
check "core-doctor's stale block lists only rows Core actually probes" \
  '_core_have() { return 1 }
   _core_doctor_present() { return 1 }
   typeset -gA _CORE_PROBED=(eza 1)
   names=$(NO_COLOR=1 core-doctor 2>&1 | awk "/^stale\$/{getline; print; exit}")
   [[ ${names// /} == eza ]] \
     || { print -r -- "stale names line should be exactly \"eza\", got: [$names]"; exit 1 }'
# …and the false-positive mirror: a tool the ledger says was ABSENT at band 00 and is still
# absent is simply missing, not stale. Nothing was wired, so no alias can be dangling.
check "core-doctor does not call a never-detected tool stale" \
  '_core_have() { return 1 }
   _core_doctor_present() { return 1 }
   typeset -gA _CORE_PROBED=(procs 0)
   out=$(NO_COLOR=1 core-doctor 2>&1)
   [[ $out != *"stale"* ]] || { print -r -- "an absent-at-band-00 tool was reported stale"; exit 1 }'
check_dep "core-doctor --json exposes detection.stale, disjoint from detection.missed" python3 \
  '_core_have() { return 1 }
   _core_doctor_present() { return 1 }
   typeset -gA _CORE_PROBED=(procs 1 jnv 0)
   core-doctor --json | python3 -c "
import json, sys
d = json.load(sys.stdin)[\"detection\"]
assert d[\"ran\"] is True, d
assert \"procs\" in d[\"stale\"], d
assert \"jnv\" not in d[\"stale\"], d
assert set(d[\"stale\"]) & set(d[\"missed\"]) == set(), d
"'
# The parity test stubs _core_have FALSE, which is exactly the branch this axis fires on — so
# unlike #545's ⚠ it CAN perturb that comparison. Re-run it with the stale axis active to show
# the `stale` block is invisible to it (it sits past the opt-in trim, like `not wired`).
check_dep "the render⇄json tool sets still match with the stale axis firing" python3 \
  '_core_have() { return 1 }
   _core_doctor_present() { return 1 }
   typeset -gA _CORE_PROBED=(procs 1 btop 1)
   alias ps=procs
   _CD_R="$(NO_COLOR=1 core-doctor 2>&1)" _CD_J="$(core-doctor --json)" python3 -c "
import json, os, re
body = os.environ[\"_CD_R\"].split(chr(10), 1)[1]
body = body.split(chr(10) + \"opt-in\")[0]
shown = set(re.findall(r\"[✓✗·] ([A-Za-z0-9_.-]+)\", body))
keys  = set(json.loads(os.environ[\"_CD_J\"])[\"tools\"])
assert shown, \"parsed no tools out of the rendered report\"
assert shown == keys, \"render-only: %s | json-only: %s\" % (sorted(shown - keys), sorted(keys - shown))
"'

# Orphan guard: a name here that is not in _CORE_DOCTOR_GROUPS mutes nothing and reads as if
# it does — the failure mode of every list maintained beside another list.
check "every _CORE_DOCTOR_OPTIN entry is actually in the doctor inventory" \
  'local -a all=(); local gi
   for ((gi = 2; gi <= ${#_CORE_DOCTOR_GROUPS}; gi += 2)); do all+=(${=_CORE_DOCTOR_GROUPS[gi]}); done
   local o orphan=""
   for o in $_CORE_DOCTOR_OPTIN; do (( ${all[(I)$o]} )) || orphan="$orphan $o"; done
   [[ -z $orphan ]] || { print -r -- "orphaned opt-in entries:$orphan"; false }'

# The invariant that would have caught the drift this backfill fixed: every binary
# 00-tools.zsh probes must be REPORTED by the doctor. Twelve were not — ast-grep, difft,
# gping, hyperfine, jj, jnv, ouch, shellcheck, shfmt, tldr, uv, viddy were detected into
# HAVE_* flags and appeared in neither renderer, silently, for releases. Parity (above) only
# compares the doctor against itself, so it can never see this; the two lists agreed
# perfectly about a tool neither of them mentioned. Read the probe list straight out of the
# source file and require the inventory to cover it.
# Direction is deliberately one-way: probed ⊆ reported. The reverse would fail on `op` (no
# HAVE_OP — the doctor probes it live) and on `fd`/`bat`, which 00-tools.zsh sets from
# FD_BIN/BAT_BIN after resolving fdfind/batcat rather than with a bare `_have` line.
# `^_have +` and not `^_have `: 00-tools.zsh aligns a couple of trailing comments with two
# spaces (tldr is one), and the single-space form silently dropped those rows from the set —
# a coverage guard that read stronger than it was. The quantifier takes it 37 → 38.
check_dep "core-doctor reports every tool 00-tools.zsh probes (no silently undetected tools)" python3 \
  '_TOOLS_SRC="'"$HERE"'/zsh/00-tools.zsh" _CD_J="$(core-doctor --json)" python3 -c "
import json, os, re
probed   = set(re.findall(r\"(?m)^_have +([A-Za-z0-9_.-]+)\", open(os.environ[\"_TOOLS_SRC\"]).read()))
reported = set(json.loads(os.environ[\"_CD_J\"])[\"tools\"])
missing  = sorted(probed - reported)
assert probed, \"parsed no _have lines out of 00-tools.zsh\"
assert not missing, \"detected by 00-tools.zsh but absent from core-doctor: %s\" % missing
"'
# ...and now the REVERSE direction, which the note above declined to assert because three
# rows legitimately have no `_have` line. Declining it entirely left a hole: the check above
# derives its tool -> flag mapping from the very line that sets the flag, so DELETING
# `_have jq && HAVE_JQ=1` does not make it fail — it just removes jq from both sides and the
# suite goes quiet. That is the #447 failure mode itself (the doctor promising a tool Core
# never wired), so assert it directly, with the three exceptions named rather than waived.
#
# THE EXEMPTION LIST IS NOW EMPTY, and that is the point (#545). It used to read
# `exempt=(op fd bat)` with this rationale:
#
#     op is deliberate: the doctor probes it live and no alias or function is gated on it.
#
# which was simply false. 50-op.zsh:7 gates FOUR verbs — opsecret, openv, optoken, opssh —
# behind its own `command -v op`, at band 50, which still runs before 80-os.zsh, an 85-* role
# fragment and 99-local.zsh. So `op` had the exact divergence this test was meant to police,
# sitting inside the doctor's own inventory behind a comment asserting it could not.
#
# fd and bat were excused because their flags are set from FD_BIN/BAT_BIN (after resolving
# fdfind/batcat), so the assignments do not match `^_have`. Both now record into the
# _CORE_PROBED ledger under their CANONICAL names, which is what the doctor keys on — so the
# excuse is gone rather than merely tolerated.
#
# Two shapes are parsed, because detection is now recorded in two places: the classic
# `_have <tool> && HAVE_<X>=1` line, and an explicit `_CORE_PROBED[<tool>]=1`. Note `$` is
# outside the character class in the second pattern, so the generic `_CORE_PROBED[$1]=1`
# inside `_have` itself cannot match and be mistaken for a tool named `$1` — load-bearing.
#
# A NEW name showing up here is not an exception to add — it means a doctor row has no
# detection behind it, which is the bug.
# Pure zsh so it runs everywhere; _CORE_DOCTOR_GROUPS is the inventory the parity test above
# already proves equal to both renderers' output.
check "every core-doctor row has detection behind it (the exemption list is empty)" \
  'paired=(); missing=()
   for f in '"$HERE"'/zsh/00-tools.zsh '"$HERE"'/zsh/50-op.zsh; do
     for line in ${(f)"$(<$f)"}; do
       [[ $line =~ "^_have +([A-Za-z0-9_.-]+) +&& +HAVE_[A-Z0-9_]+=1" ]] && paired+=($match[1])
       [[ $line =~ "_CORE_PROBED\[([A-Za-z0-9_.-]+)\]=1" ]] && paired+=($match[1])
     done
   done
   (( ${#paired} >= 30 )) || { print -r -- "parsed only ${#paired} detection lines"; exit 1; }
   for ((gi = 2; gi <= ${#_CORE_DOCTOR_GROUPS}; gi += 2)); do
     for t in ${=_CORE_DOCTOR_GROUPS[gi]}; do
       (( ${paired[(I)$t]} )) || missing+=($t)
     done
   done
   (( ${#missing} == 0 )) || { print -r -- "doctor rows with no detection behind them: $missing"; exit 1; }'
# git-absorb is the first --json tools key that is NOT a bare identifier, and the JSON is
# hand-rolled by _core_doctor_json rather than produced by a serialiser — so the hyphen has
# to survive quoting on its own merit. The set-equality check above cannot see this: it
# compares the render against the JSON, so dropping the tool from BOTH literals still passes,
# and it never exercises a `true` value. Pin the key by name AND by value, with _core_have
# stubbed to match only git-absorb so one tool is true and the rest false — that also proves
# the emitter tracks detection per tool instead of painting the whole object one way.
check_dep "core-doctor --json emits the hyphenated git-absorb key and tracks its detection" python3 \
  '_core_have() { [[ "$1" == git-absorb ]]; }
   _core_doctor_present() { [[ "$1" == git-absorb ]]; }
   _CD_J="$(core-doctor --json)" python3 -c "
import json, os
tools = json.loads(os.environ[\"_CD_J\"])[\"tools\"]
assert \"git-absorb\" in tools, sorted(tools)
assert tools[\"git-absorb\"] is True, tools[\"git-absorb\"]
assert tools[\"eza\"] is False, tools[\"eza\"]
"'
# core-doctor "install missing" hint: since #763 the block renders from the DECLARED
# PKG_INSTALL and nothing else, so the seam is _core_cap (band 02, absent in this
# ui+functions harness) rather than _pkgup_mgr. Stub it + force every tool ✗ (missing),
# then assert the copy-paste line renders AND the caveat points at PORTING-MATRIX.md rather
# than promising the package manager (or a single installer) can fetch everything — the
# regression guard for the unpackaged-tool guidance.
check "core-doctor 'install missing' hint points to PORTING-MATRIX.md for unpackaged tools" \
  '_core_cap() { [[ $1 == PKG_INSTALL ]] && print -r -- "sudo apt install"; }
   _core_have() { return 1; }
   _core_doctor_present() { return 1; }
   out=$(NO_COLOR=1 core-doctor 2>&1); (( $? == 0 )) \
     && [[ $out == *"install missing"* && $out == *"sudo apt install"* && $out == *"PORTING-MATRIX.md"* ]]'
# ...and the hint must NOT concatenate the manager verb with the tool list. That form read as
# paste-ready but never was: apt/dnf/zypper/pacman abort the whole transaction on one
# unresolvable name, and most of the inventory carries a package name that differs from the
# command (rg=ripgrep) or is unpackaged on some target. With _core_have false every tool is
# missing, so the old shape would render `sudo apt install eza bat …` — assert the verb is
# only ever followed by the <pkg> placeholder, and that the first tool name never trails it.
check "core-doctor's install hint offers a per-tool template, not a paste-ready batch command" \
  '_core_cap() { [[ $1 == PKG_INSTALL ]] && print -r -- "sudo apt install"; }
   _core_have() { return 1; }
   _core_doctor_present() { return 1; }
   out=$(NO_COLOR=1 core-doctor 2>&1); (( $? == 0 )) \
     && [[ $out == *"sudo apt install <pkg>"* ]] \
     && [[ $out != *"sudo apt install eza"* ]] \
     && [[ $out == *"command names"* ]]'
# _core_wired (U1): presence != wired. The probe is true ONLY when the integration's hook
# function is actually defined in this shell, and false for an idle/unknown one — that gap
# is exactly what the doctor's "integrations wired" line surfaces.
check "_core_wired detects an integration once its hook function exists" \
  'starship_precmd() { :; }; _core_wired starship'
check "_core_wired is false for an idle integration and an unknown name" \
  '_core_wired starship 2>/dev/null; (( $? != 0 )); _core_wired bogustool 2>/dev/null; (( $? != 0 ))'
# Upstream RENAMES the function its `init` emits, and Core sources that init verbatim — so a
# probe pinned to one spelling silently goes stale and reports a FALSE `○ (idle)` for a live
# integration (seen on starship 1.24.2 → prompt_starship_precmd, carapace-bin 1.5.7 →
# _carapace_completer; neither emits the historical name at all). Pin BOTH spellings per tool
# so dropping either fallback fails the audit instead of quietly recreating that bug.
check "_core_wired accepts starship's current hook name (prompt_starship_precmd)" \
  'prompt_starship_precmd() { :; }; _core_wired starship'
check "_core_wired accepts carapace's historical hook name (_carapace)" \
  '_carapace() { :; }; _core_wired carapace'
check "_core_wired accepts carapace's current hook name (_carapace_completer)" \
  '_carapace_completer() { :; }; _core_wired carapace'
check "_core_wired is false for an idle carapace" \
  '_core_wired carapace 2>/dev/null; (( $? != 0 ))'
# ── The wired list must not drift from the arms that implement it (#447) ──────────────
# _CORE_DOCTOR_WIRED is what BOTH renderers iterate; the `case` arms of _core_wired are what
# actually probe. Those were three hand-synced literals until this change, and — unlike the
# tool axis — nothing could see a drift: the render⇄json parity test above stubs _core_have
# false, which makes the "integrations wired" block skip every entry by construction. So the
# guard has to be built here, in both directions, because the two drifts are different bugs.
#
# The sentinel first, because the next assertion is vacuous without it: an unknown name must
# return exactly 2, not merely non-zero. Reverting that arm to `return 1` makes "no arm for
# this name" indistinguishable from "installed but idle" and silently disarms the check below.
check "_core_wired returns the distinct exit 2 for a name it has no arm for" \
  '_core_wired bogustool 2>/dev/null; (( $? == 2 ))'
# Direction 1 — every listed name has an arm. This is the drift that renders a WRONG report:
# a name in the array with no arm falls to `*)` and prints `○ (idle)` forever, on every box,
# no matter what the user installs or configures. Runtime, so it needs no source parsing.
# `_core_wired` is called with the hooks undefined, so a correctly-armed tool returns 1 here;
# only 2 is a failure.
check "every _CORE_DOCTOR_WIRED entry has a matching _core_wired arm" \
  'for t in $_CORE_DOCTOR_WIRED; do
     _core_wired "$t" 2>/dev/null
     (( $? == 2 )) && { print -r -- "no _core_wired arm for: $t"; exit 1; }
   done
   (( ${#_CORE_DOCTOR_WIRED} > 0 ))'
# Direction 2 — every arm is listed. This is the drift that renders a MISSING report: a tool
# gains a probe nobody iterates, so its wiredness is never shown and the omission is silent
# (exactly how twelve tools went unreported on the tool axis for releases). Not observable at
# runtime — an unlisted arm is unreachable by definition — so read the arms out of the source,
# the same technique as the "probed ⊆ reported" test above. Skips without python3, like its
# neighbours.
check_dep "every _core_wired arm appears in _CORE_DOCTOR_WIRED (no unreachable probes)" python3 \
  '_FN_SRC="'"$HERE"'/zsh/30-functions.zsh" _CD_W="$_CORE_DOCTOR_WIRED" python3 -c "
import os, re
src  = open(os.environ[\"_FN_SRC\"]).read()
body = re.search(r\"(?s)^_core_wired\\(\\) \\{.*?^\\}\", src, re.M).group(0)
arms = set(re.findall(r\"(?m)^  ([a-z][a-z0-9-]*)\\)\", body))
listed = set(os.environ[\"_CD_W\"].split())
assert arms, \"parsed no case arms out of _core_wired\"
assert not arms - listed, \"probed by _core_wired but never rendered: %s\" % sorted(arms - listed)
"'
# core-help (U5): the width-aware renderer must emit every verb and never crash on its
# kw arithmetic — including a pathologically narrow terminal where the key column clamps.
check "core-help renders all verbs (wide terminal)" \
  'out=$(COLUMNS=120 core-help 2>&1); (( $? == 0 )) && [[ $out == *mkcd* && $out == *"maint-install"* && $out == *serve* ]]'
check "core-help renders cleanly on a pathologically narrow terminal" \
  'out=$(COLUMNS=12 core-help 2>&1); (( $? == 0 )) && [[ $out == *mkcd* ]]'
# core-help <filter> (U4): a term shows ONLY matching rows (and drops the section
# scaffolding); an unmatched term reports it instead of printing an empty sheet.
check "core-help <term> filters to matching rows only" \
  'out=$(COLUMNS=120 core-help serve 2>&1); (( $? == 0 )) && [[ $out == *serve* && $out != *"maint-install"* ]]'
check "core-help reports when a filter matches nothing" \
  'out=$(COLUMNS=120 core-help zzzznope 2>&1); (( $? == 0 )) && [[ $out == *"no entries match"* ]]'
# U8: the git alias set (git.zsh) is now discoverable from the cheat sheet — the full
# view carries the git section, and a filter still narrows to a specific git row.
check "core-help surfaces the git alias section in the full sheet" \
  'out=$(COLUMNS=120 NO_COLOR=1 core-help 2>&1); (( $? == 0 )) && [[ $out == *"git (most-used"* && $out == *gpf* ]]'
check "core-help can filter to a git alias row" \
  'out=$(COLUMNS=120 NO_COLOR=1 core-help gpf 2>&1); (( $? == 0 )) && [[ $out == *gpf* && $out != *"maint-install"* ]]'
# Section-aware filter: a SECTION name (the completion offers these) surfaces its whole
# group even though the word appears in no row key/desc — e.g. `core-help keybindings`.
check "core-help filters by section name (keybindings → its rows, not others)" \
  'out=$(COLUMNS=120 NO_COLOR=1 core-help keybindings 2>&1); (( $? == 0 )) && [[ $out == *Ctrl-T* && $out != *"maint-install"* ]]'
check "core-help --help returns 0 (not mis-read as a filter)" \
  'out=$(core-help --help); (( $? == 0 )) && [[ $out == *"usage: core-help"* ]]'
# core umbrella dispatcher: bare `core` is the cheat sheet (U6 — help, not an
# error), subcommands route to the core-* family, and an unknown subcommand fails in
# Core's voice with a did-you-mean against $_CORE_SUBCMDS.
check "core (no args) prints the cheat sheet (U6: bare core is help, not an error)" \
  'out=$(COLUMNS=120 core 2>&1); (( $? == 0 )) && [[ $out == *mkcd* && $out == *serve* ]]'
check "core help <term> routes to core-help and filters" \
  'out=$(COLUMNS=120 core help serve 2>&1); (( $? == 0 )) && [[ $out == *serve* && $out != *"maint-install"* ]]'
check "core version routes to core-version" \
  'out=$(core version); (( $? == 0 )) && [[ $out == "dotfiles-core "[0-9]* ]]'
check "core doctor routes to core-doctor" \
  'out=$(NO_COLOR=1 core doctor 2>&1); (( $? == 0 )) && [[ $out == *"modern CLI"* ]]'
check "core rejects an unknown subcommand with a did-you-mean" \
  'out=$(core verzion 2>&1); (( $? != 0 )) && [[ $out == *"did you mean core version"* ]]'
# Availability awareness: `up` is band 60 and `core` is band 30, so the dispatcher is
# reachable in a shell the updater never loaded — including this harness, which sources
# 05-ui and 30-functions and nothing else. It must fail cleanly and NAME THE FRAGMENT that
# would supply it, the only thing the reader can act on. The literal pins the message to
# 60-update.zsh, which core.manifest also pins: rename that file and this fails, correctly.
check "core update reports cleanly, naming 60-update.zsh, when up is not loaded" \
  '( unfunction up 2>/dev/null; out=$(core update 2>&1); (( $? != 0 )) && [[ $out == *60-update* ]] )'
# The second family (#684): `core maint <verb>`, `core sync` and `core update check` reach
# the front door. The twins are STUBBED per body — 55-maint, 60-update and 20-aliases are
# not sourced here, which is exactly what makes the "reports cleanly when not loaded"
# assertions honest rather than staged.
check "maint and sync are registered in \$_CORE_SUBCMDS (the completion + did-you-mean read it)" \
  '[[ " ${_CORE_SUBCMDS[*]} " == *" maint "* && " ${_CORE_SUBCMDS[*]} " == *" sync "* ]]'
check "\$_CORE_MAINT_SUBCMDS carries exactly the five maint verbs" \
  '[[ "${_CORE_MAINT_SUBCMDS[*]}" == "install run log status uninstall" ]]'
check "core maint run routes to maint-run" \
  'maint-run() { print STUB-RUN "$@"; }; out=$(core maint run); (( $? == 0 )) && [[ $out == "STUB-RUN" ]]'
check "core maint install 09:00 forwards the time to maint-install" \
  'maint-install() { print STUB-INSTALL "$@"; }; out=$(core maint install 09:00); [[ $out == "STUB-INSTALL 09:00" ]]'
check "core maint log -f forwards -f to maint-log" \
  'maint-log() { print STUB-LOG "$@"; }; out=$(core maint log -f); [[ $out == "STUB-LOG -f" ]]'
check "core maint log 200 forwards a line count to maint-log" \
  'maint-log() { print STUB-LOG "$@"; }; out=$(core maint log 200); [[ $out == "STUB-LOG 200" ]]'
check "core maint status routes to maint-status, not core-status" \
  'maint-status() { print STUB-MS; }; out=$(core maint status 2>&1); (( $? == 0 )) && [[ $out == "STUB-MS" ]]'
check "core maint uninstall routes to maint-uninstall" \
  'maint-uninstall() { print STUB-MU; }; out=$(core maint uninstall); [[ $out == "STUB-MU" ]]'
check "core maint (bare) lists the sub-verbs on stdout and returns 0 (a namespace is help, not an error)" \
  'out=$(core maint 2>/dev/null); (( $? == 0 )) && [[ $out == *"usage: core maint <install|run|log|status|uninstall>"* && $out == *"uninstall "* ]]'
check "core maint --help returns 0 (not mis-read as a sub-verb)" \
  'out=$(core maint --help); (( $? == 0 )) && [[ $out == *"usage: core maint"* ]]'
check "core maint help is the same usage (the top-level help alias)" \
  'out=$(core maint help); (( $? == 0 )) && [[ $out == *"usage: core maint <"* ]]'
check "core maint rejects an unknown sub-verb with a did-you-mean and does not dispatch" \
  'maint-status() { print STUB-MS; }; out=$(core maint stauts 2>&1); (( $? != 0 )) && [[ $out == *"did you mean core maint status"* && $out == *"usage: core maint <"* && $out != *STUB-MS* ]]'
check "core maint run reports cleanly, naming 55-maint.zsh, when maint-run is not loaded" \
  '( unfunction maint-run 2>/dev/null; out=$(core maint run 2>&1); (( $? != 0 )) && [[ $out == *55-maint* ]] )'
check "core mant suggests core maint" \
  'out=$(core mant 2>&1); (( $? != 0 )) && [[ $out == *"did you mean core maint"* ]]'
check "core update check routes to update-check, not up" \
  'update-check() { print STUB-UC "$@"; }; up() { print STUB-UP "$@"; }; out=$(core update check); (( $? == 0 )) && [[ $out == "STUB-UC" ]]'
check "core update -y still routes to up (only the word check is intercepted)" \
  'up() { print STUB-UP "$@"; }; out=$(core update -y); [[ $out == "STUB-UP -y" ]]'
check "core update check reports cleanly, naming 60-update.zsh, when update-check is not loaded" \
  '( unfunction update-check 2>/dev/null; out=$(core update check 2>&1); (( $? != 0 )) && [[ $out == *60-update* ]] )'
check "core sync routes to gsync and forwards args" \
  'gsync() { print STUB-SYNC "$@"; }; out=$(core sync --dry-run); (( $? == 0 )) && [[ $out == "STUB-SYNC --dry-run" ]]'
check "core sync reports cleanly, naming 20-aliases.zsh, when gsync is not loaded" \
  '( unfunction gsync 2>/dev/null; out=$(core sync 2>&1); (( $? != 0 )) && [[ $out == *20-aliases* ]] )'
check "core-help's front-door footer names maint and sync" \
  'out=$(COLUMNS=200 NO_COLOR=1 core-help 2>&1); [[ $out == *"front door: core <"*maint*sync*">"* ]]'

# core whatsnew (#680): the digest is CHANGELOG.recent.md — the last 8 RELEASED sections,
# vendored via core.vendor because CHANGELOG.md is not (~707 KB, 36% of the vendored tree).
# Driven against a FIXTURE digest and a fixture state file so these assert the SLICING and
# the degradation modes, not whatever this repo happens to have released. The module
# captures $_CORE_WHATSNEW_FILE at source time (the _CORE_VERSION_FILE pattern), so each
# body repoints the globals AFTER sourcing — no product-code test hook is needed.
_ws="$SANDBOX/whatsnew"
mkdir -p "$_ws/state/dotfiles-core"
printf '# Changelog — recent releases\n\n## [v2.0.0] - 2026-02-03\n\n### Added\n\n- **newest thing (#1).** prose\n\n## [v1.9.0] - 2026-02-02\n\n### Fixed\n\n- **middle thing (#2).** prose\n\n## [v1.8.0] - 2026-02-01\n\n### Added\n\n- **oldest thing (#3).** prose\n' >"$_ws/CHANGELOG.recent.md"
printf '2.0.0\n' >"$_ws/core.version"
# Repointed globals + a deterministic render environment, prefixed to every body below.
_ws_env="_CORE_WHATSNEW_FILE='$_ws/CHANGELOG.recent.md'; _CORE_VERSION_FILE='$_ws/core.version'; _CORE_WHATSNEW_STATE='$_ws/state/dotfiles-core/whatsnew'; export CORE_NO_PAGER=1 NO_COLOR=1;"
_ws_state="$_ws/state/dotfiles-core/whatsnew"

# (1) THE SLICE — the issue's headline assertion. State names the OLDEST of three headings;
# the render must carry the two NEWER ones and must NOT re-show the one already read.
check "core-whatsnew renders only the sections newer than the last-seen version" \
  "$_ws_env print -r -- 'seen=1.8.0' >| '$_ws_state'
   out=\$(core-whatsnew 2>&1); (( \$? == 0 )) &&
   [[ \$out == *'2.0.0'* && \$out == *'1.9.0'* && \$out != *'1.8.0 2026'* && \$out != *'oldest thing'* ]]"

# (2) FIRST RUN, NO STATE FILE — the issue's "degrades cleanly rather than dumping 8,000
# lines". Asserted STRUCTURALLY (the older sections are absent), not with a line count that
# would drift: a first run shows the CURRENT release only, and seeds the mark so the next
# run is quiet. Same once-per-machine shape as _core_welcome's sentinel.
check "core-whatsnew's first run is bounded to the current release and seeds the state file" \
  "$_ws_env rm -f '$_ws_state'
   out=\$(core-whatsnew 2>&1); (( \$? == 0 )) &&
   [[ \$out == *'2.0.0'* && \$out != *'middle thing'* && \$out != *'oldest thing'* && \$out == *'first look'* ]] &&
   [[ \$(<'$_ws_state') == *'seen=2.0.0'* ]]"

# (3) THE DIGEST IS ABSENT — the state #676 created for CHANGELOG.md, and the state every OS
# repo pinning a pre-#680 Core is in right now. Must fail in CORE'S VOICE, naming the file,
# never as a raw zsh "no such file or directory".
check "core-whatsnew degrades honestly when the digest is absent (Core's voice, not a raw error)" \
  "$_ws_env _CORE_WHATSNEW_FILE='$_ws/absent-core/CHANGELOG.recent.md'
   out=\$(core-whatsnew 2>&1); (( \$? != 0 )) &&
   [[ \$out == *'CHANGELOG.recent.md'* && \$out == *'core.vendor'* && \${(L)out} != *'no such file or directory'* ]]"

# (4) ALREADY CURRENT. Without this, the common post-sync case (nothing new) is
# indistinguishable from a broken slice.
check "core-whatsnew says nothing is new when the last-seen version is current" \
  "$_ws_env print -r -- 'seen=2.0.0' >| '$_ws_state'
   out=\$(core-whatsnew 2>&1); (( \$? == 0 )) &&
   [[ \$out == *'nothing new'* && \$out != *'newest thing'* ]]"

# (5) THE WINDOW WAS EXCEEDED — last-seen predates every section the digest carries. The
# digest is 8 RELEASES deep, not a calendar window, so at a fast cadence this is a routine
# path: it must render what there is AND admit the truncation, pointing at the full log.
check "core-whatsnew admits when the last-seen version predates the whole digest" \
  "$_ws_env print -r -- 'seen=0.9.0' >| '$_ws_state'
   out=\$(core-whatsnew 2>&1); (( \$? == 0 )) &&
   [[ \$out == *'oldest thing'* && \$out == *'only reach back to 1.8.0'* && \$out == *CHANGELOG* ]]"

# (6) ROLLBACK — this box runs OLDER than what was already read. Show nothing, and leave the
# mark ALONE so a roll-forward does not replay notes the user has seen.
check "core-whatsnew reports a rollback and does NOT move the read mark" \
  "$_ws_env print -r -- 'seen=2.0.0' >| '$_ws_state'; print -r -- '1.9.0' >| '$_ws/core.version'
   out=\$(core-whatsnew 2>&1); (( \$? == 0 )) && [[ \$out == *'already read 2.0.0'* ]] &&
   [[ \$(<'$_ws_state') == *'seen=2.0.0'* ]]
   print -r -- '2.0.0' >| '$_ws/core.version'"

# (7) NO ANCHOR — core.version unreadable. Not fatal (the newest section is still worth
# showing), but the mark must NOT advance: there is nothing trustworthy to record.
check "core-whatsnew with an unreadable core.version shows the newest and does not move the mark" \
  "$_ws_env _CORE_VERSION_FILE='$_ws/gone'; print -r -- 'seen=1.8.0' >| '$_ws_state'
   out=\$(core-whatsnew 2>&1); (( \$? == 0 )) && [[ \$out == *'no anchor'* ]] &&
   [[ \$(<'$_ws_state') == *'seen=1.8.0'* ]]"

# (8) --full is the escape hatch to the prose the default render summarises to leads — and
# the leads footer SUGGESTS it by name, so it must work as the immediate next command. It
# did not: the first render advanced the mark, so the very command the footer recommended
# answered "nothing new". The `from` key makes the follow-up re-show that same slice. This
# asserts the two-command sequence a user actually types, not each verb in isolation.
check "core-whatsnew --full, run right after the leads its footer suggests it from, shows the prose" \
  "$_ws_env print -r -- 'seen=1.8.0' >| '$_ws_state'
   lead=\$(core-whatsnew 2>&1); full=\$(core-whatsnew --full 2>&1)
   [[ \$lead != *'### Added'* && \$lead == *'--full'* ]] &&
   [[ \$full == *'### Added'* && \$full == *'prose'* && \$full == *'already read'* ]]"
# A re-show is not new reading: re-running must not re-stamp the mark, or a third run would
# lose the anchor and fall back to "nothing new" — the defect, one step later.
check "core-whatsnew's re-show leaves the state file untouched" \
  "$_ws_env print -r -- 'seen=1.8.0' >| '$_ws_state'
   core-whatsnew >/dev/null 2>&1; before=\$(<'$_ws_state')
   core-whatsnew >/dev/null 2>&1; core-whatsnew --full >/dev/null 2>&1
   [[ \$(<'$_ws_state') == \$before && \$before == *'from=1.8.0'* ]]"
# The genuine caught-up state still exists: no anchor recorded (a box that has been on this
# version since before it ever ran the verb) really has nothing to re-show.
check "core-whatsnew still reports a true caught-up state when there is no anchor to re-show" \
  "$_ws_env printf 'seen=2.0.0\\nannounced=2.0.0\\n' >| '$_ws_state'
   out=\$(core-whatsnew 2>&1); (( \$? == 0 )) && [[ \$out == *'nothing new'* ]]"

# (9) --all ignores the read mark entirely.
check "core-whatsnew --all renders every section the digest carries" \
  "$_ws_env print -r -- 'seen=2.0.0' >| '$_ws_state'
   out=\$(core-whatsnew --all 2>&1); (( \$? == 0 )) &&
   [[ \$out == *'2.0.0'* && \$out == *'1.9.0'* && \$out == *'1.8.0'* ]]"

# (10) The uniform -h/--help contract (U6): stdout, return 0, never mis-read as an operand.
check "core-whatsnew --help returns 0 and prints usage (U6)" \
  'out=$(core-whatsnew --help); (( $? == 0 )) && [[ $out == *"usage: core-whatsnew"* ]]'

# (11) An unknown flag is REJECTED with a did-you-mean, never silently ignored.
check "core-whatsnew rejects an unknown flag with a did-you-mean" \
  "$_ws_env out=\$(core-whatsnew --fll 2>&1); (( \$? != 0 )) && [[ \$out == *'did you mean --full'* ]]"

# (12) The dispatcher route, and the single _CORE_SUBCMDS source that the completion and the
# did-you-mean both read.
check "core whatsnew routes to core-whatsnew" \
  "$_ws_env print -r -- 'seen=1.8.0' >| '$_ws_state'
   out=\$(core whatsnew 2>&1); (( \$? == 0 )) && [[ \$out == *'2.0.0'* ]]"
check "whatsnew is registered in \$_CORE_SUBCMDS (the completion + did-you-mean read it)" \
  '[[ " ${_CORE_SUBCMDS[*]} " == *" whatsnew "* ]]'

# (13) A junk or truncated state file must degrade to "no mark", never propagate garbage
# into the render or (via the nudge) into a `print -P` prompt string.
check "core-whatsnew ignores a junk state file rather than trusting it" \
  "$_ws_env print -r -- 'garbage' >| '$_ws_state'; print -r -- 'seen=not-a-version' >> '$_ws_state'
   out=\$(core-whatsnew 2>&1); (( \$? == 0 )) && [[ \$out == *'first look'* ]]"

# U5: a usage error points back at the discoverability surface — `see: core-help <verb>`,
# the verb derived from the synopsis's first token, so every verb gets it for free.
check "usage errors carry a 'see: core-help <verb>' footer (U5)" \
  'out=$(serve 99999 2>&1); (( $? != 0 )) && [[ $out == *"see: core-help serve"* ]]'
check "the U5 usage footer is suppressible via CORE_USAGE_HINT=0" \
  'out=$(CORE_USAGE_HINT=0 serve 99999 2>&1); (( $? != 0 )) && [[ $out != *"see: core-help"* ]]'
# _core_suggest did-you-mean (U3/U1): nearest candidate on a near typo; SILENT when
# nothing is close or the input is too short to be a confident match.
check "_core_suggest returns the nearest flag for a near typo" \
  'out=$(_core_suggest --locl -l --local); [[ $out == "--local" ]]'
check "_core_suggest stays silent when nothing is close" \
  'out=$(_core_suggest zzzzzz -l --local); [[ -z $out ]]'
# Damerau/OSA (U12): an adjacent transposition scores 1, NOT 2 as plain Levenshtein would —
# guards the transposition path so a regression can't silently fall back to plain edit
# distance (which would drop near-miss suggestions like gts→gst back below the cutoff).
check "_core_lev scores an adjacent transposition as 1 (Damerau, not plain Levenshtein 2)" \
  '[[ $(_core_lev gts gst) == 1 ]]'
check "_core_suggest catches a transposition typo (gts → gst)" \
  'out=$(_core_suggest gts gst gco gaa); [[ $out == gst ]]'
# _core_errbox (U8): a ✗ headline line plus dim INDENTED body lines (plain when piped).
check "_core_errbox renders a headline and indented body lines" \
  'out=$(_core_errbox head why fix 2>&1); L=("${(@f)out}"); (( ${#L} == 3 )) && [[ ${L[1]} == *head* && ${L[2]} == "    why" && ${L[3]} == "    fix" ]]'
# _core_hint width-aware wrapping (U9): a known narrow width wraps with the
# continuation aligned under the text; an UNKNOWN width (non-tty, COLUMNS=0 here) must
# NOT wrap, so captured/logged hints stay one line (no regression for the other tests).
check "_core_hint stays one line when the terminal width is unknown" \
  'out=$(_core_hint install fzf, then retry 2>&1); L=("${(@f)out}"); (( ${#L} == 1 )) && [[ $out == *"hint: install"* ]]'
check "_core_hint wraps a long hint at a narrow COLUMNS with aligned continuation" \
  'out=$(COLUMNS=40 _core_hint alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima 2>&1); L=("${(@f)out}"); (( ${#L} >= 2 )) && [[ ${L[1]} == "  hint: "* && ${L[2]} == "        "* ]]'
check "extract rejects a non-existent file" \
  'extract /no/such/archive.tar.gz; (( $? != 0 ))'
check "extract rejects a known file of unknown format" \
  'd=$(mktemp -d); cd "$d"; : > mystery.qqq; extract mystery.qqq; (( $? != 0 ))'
check_dep "extract round-trips a .tar.gz" tar \
  'd=$(mktemp -d); cd "$d"; mkdir src; print -r -- hi > src/a.txt; tar czf a.tgz src; rm -rf src; extract a.tgz; [[ -f src/a.txt && "$(cat -- src/a.txt)" == hi ]]'
check_dep "extract round-trips a .gz" gzip \
  'd=$(mktemp -d); cd "$d"; print -r -- hi > f.txt; gzip f.txt; extract f.txt.gz; [[ -f f.txt && "$(cat -- f.txt)" == hi ]]'
# Defensive guards (U4): a multi-entry "tarbomb" must be flagged (with no TTY the
# contain-prompt declines and it extracts in place — both files land, we warned), and
# an extract that WOULD clobber an existing entry must abort untouched rather than
# silently overwrite. _core_confirm declining on no-TTY is what makes both deterministic.
check_dep "extract warns on a tarbomb but still unpacks (no TTY)" tar \
  'd=$(mktemp -d); cd "$d"; print x > one; print y > two; tar czf bomb.tgz one two; rm one two; extract bomb.tgz </dev/null; [[ -f one && -f two ]]'
check_dep "extract refuses to clobber an existing entry (no TTY)" tar \
  'd=$(mktemp -d); cd "$d"; mkdir src; print new > src/a.txt; tar czf a.tgz src; print OLD > src/a.txt; extract a.tgz </dev/null; rc=$?; [[ "$(cat -- src/a.txt)" == OLD && $rc -ne 0 ]]'
# gz/bz2 write NEXT TO the archive path, not into $PWD: `extract /dir/f.gz` must guard
# /dir/f, not ./f. Run it from a DIFFERENT cwd so a basename-only check would miss the
# clobber and overwrite (the bug this asserts against).
check_dep "extract guards the gz output at the archive's path, not \$PWD" gzip \
  'd=$(mktemp -d); sub="$d/sub"; mkdir -p "$sub"; print new > "$sub/f.txt"; gzip "$sub/f.txt"; print OLD > "$sub/f.txt"; cd "$d"; extract "$sub/f.txt.gz" </dev/null; rc=$?; [[ "$(cat -- "$sub/f.txt")" == OLD && $rc -ne 0 ]]'

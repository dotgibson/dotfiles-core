#!/usr/bin/env bash
# scripts/check-modern.sh
# ──────────────────────────────────────────────────────────────────────────────
# Enforce scripts/modern-baseline.yml against this repo's GitHub Actions workflows
# and composite actions. This is the "ensure" half of the modernization floor: the
# baseline DECLARES what modern means, this script CHECKS it, and audit-core.sh runs
# it as a gate (section 8c) so CI can't silently regress below the floor.
#
# Exit 0 = meets the floor. Exit 1 = one or more violations (printed to stderr).
# Run standalone (`./scripts/check-modern.sh` / `make check-modern`) or via the audit.
# Pure bash + awk/grep (busybox-safe); the flat baseline schema is parsed without a
# YAML library — the same "no dependency" discipline as tool-versions.env.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
# For _audit_ls — this gate inventories files whose CONTENT it then checks, so it must
# see untracked ones (see the rule in common.sh). Sourced for that alone; this script
# keeps its own `note`/output style. The lib is idempotent and defines no name this
# script also defines.
#
# Via the ALREADY-ABSOLUTE $HERE, not ${BASH_SOURCE[0]%/*}: we have just cd'd, and
# BASH_SOURCE stays relative to the caller's original directory. Invoking this script
# by a relative path from elsewhere — `bash ../../repo/scripts/check-modern.sh` — then
# resolves the lib against the wrong base and, under `set -e`, exits before the gate
# runs at all. Verified: that invocation reported "lib/common.sh: No such file or
# directory" until this line used $HERE.
# shellcheck source=scripts/lib/common.sh
source "$HERE/scripts/lib/common.sh"
BASELINE="scripts/modern-baseline.yml"
[ -r "$BASELINE" ] || { echo "check-modern: $BASELINE missing" >&2; exit 1; }

# ── minimal greppable-YAML readers (flat schema only: scalars + `- ` lists) ──────
_yaml_list() { # $1 = key → each list item, dequoted
  awk -v k="$1" '
    $0 ~ "^"k":[[:space:]]*$" { f=1; next }
    /^[A-Za-z_]/ { f=0 }
    f && /^[[:space:]]*-[[:space:]]*/ {
      sub(/^[[:space:]]*-[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); gsub(/^"|"$/, ""); print
    }
  ' "$BASELINE"
}
_yaml_bool() { grep -qE "^$1:[[:space:]]*true([[:space:]]|\$)" "$BASELINE"; }
_yaml_val()  { sed -nE "s/^$1:[[:space:]]*//p" "$BASELINE" | head -n1 | tr -d '"'; }

# ── the files we gate: workflows + composite actions ─────────────────────────
# Plain read loop, not `mapfile` — macOS ships bash 3.2 (no mapfile), which the audit
# runs this under, same bash-3.2 discipline as the rest of Core.
FILES=()
while IFS= read -r _f; do [ -n "$_f" ] && FILES+=("$_f"); done < <(_audit_ls \
  '.github/workflows/*.yml' '.github/workflows/*.yaml' \
  '.github/actions/*/action.yml' '.github/actions/*/action.yaml')
# `--job-census` is exempt from this early exit: its consumer has to tell "counted zero"
# apart from "could not count", and an exit here would hand that reader a prose sentence
# where it expects a census line. It reports workflows=0 instead and lets the gate skip.
if [ "${#FILES[@]}" -eq 0 ] && [ "${1:-}" != "--job-census" ]; then
  echo "check-modern: no workflow/action files to check"
  exit 0
fi

# Workflows alone — rule 5 gates a key that only exists at workflow scope, so it must
# not see the composite action.yml files above.
WORKFLOWS=()
while IFS= read -r _f; do [ -n "$_f" ] && WORKFLOWS+=("$_f"); done < <(_audit_ls \
  '.github/workflows/*.yml' '.github/workflows/*.yaml')

violations=0
note() { printf '  ✗ %s\n' "$*" >&2; violations=$((violations + 1)); }

# ── the job census: ONE walk, two readers ────────────────────────────────────
# `jobs:` opens the section; any column-0 key closes it; a 2-space key opens a job.
# Structurally the same job-block walk as rule 6's checkout walk, awk-only and bash-3.2
# safe, and scoped to WORKFLOWS, not FILES: a composite action has no jobs.
#
# ONE definition, because these counts are CLAIMED IN PROSE and prose drifts. Rule 8
# reads this to find runner jobs missing a timeout; `--job-census` reads it so
# scripts/test/90-policy-gates.sh can hold rule 8's rationale in modern-baseline.yml to
# the number the walk actually produces. That rationale had drifted from 47 to 58
# unnoticed (#1083) — eleven jobs added, nothing comparing the sentence to the tree. A
# SECOND walk written for the gate would be a second definition of "runner job", which
# is the drift class the gate exists to close, so the gate does not get its own.
#
# One record per job, machine fields tab-separated ahead of rule 8's human string:
#   KIND<TAB>HAS_TIMEOUT<TAB>FILE:LINE: JOB      KIND ∈ runner | call | plain
_job_records() {
  [ "${#WORKFLOWS[@]}" -gt 0 ] || return 0
  for _jr_wf in "${WORKFLOWS[@]}"; do
    awk '
      function emit() {
        printf "%s\t%d\t%s:%d: %s\n",
               (runner ? "runner" : (call ? "call" : "plain")), t, FILENAME, ln, job
      }
      /^jobs:[[:space:]]*$/ { injobs = 1; next }
      /^[A-Za-z_]/          { injobs = 0 }
      injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
        if (job != "") emit()
        job = $1; sub(/:$/, "", job); ln = NR; runner = 0; call = 0; t = 0; next
      }
      injobs && /^    runs-on:/         { runner = 1 }
      injobs && /^    uses:/            { call = 1 }
      injobs && /^    timeout-minutes:/ { t = 1 }
      END { if (job != "") emit() }
    ' "$_jr_wf" 2>/dev/null || true
  done
}

# `--job-census` prints the counts and nothing else, for the gate above. It is a READER of
# the floor, not part of it: it runs no rule and returns no verdict.
#
# `workflows=` LEADS, and is not decoration. The inventory goes through git (_audit_ls, so
# untracked files count), which can legitimately answer nothing — a container whose
# safe.directory the caller has hidden, a tarball with no .git. The counts are then 0/0,
# which is indistinguishable from a real answer unless the size is reported beside them,
# and a consumer that cannot tell reports "the prose claims 58, the tree holds 0".
case "${1:-}" in
"") : ;;
--job-census)
  _job_records | awk -F'\t' -v w="${#WORKFLOWS[@]}" '
    $1 == "runner" { r++ } $1 == "call" { c++ }
    END { printf "workflows=%d runner=%d call=%d\n", w, r + 0, c + 0 }'
  exit 0
  ;;
*)
  echo "check-modern: unknown argument: $1 (the only one is --job-census)" >&2
  exit 2
  ;;
esac

# ── 1) banned deprecated workflow-command patterns ───────────────────────────
while IFS= read -r pat; do
  [ -n "$pat" ] || continue
  while IFS= read -r hit; do note "banned pattern ($pat): $hit"; done \
    < <(grep -HnF -- "$pat" "${FILES[@]}" 2>/dev/null || true)
done < <(_yaml_list banned_patterns)

# ── 2) banned EOL runner labels (in runs-on: or a matrix os: list) ───────────
# The `(-(arm|large|xlarge))?` group is load-bearing. The label class that terminates the
# match has no hyphen in it, so without the group a ban on `ubuntu-22.04` did NOT match
# `runs-on: ubuntu-22.04-arm` — the `-` fails every alternative. GitHub names those exact
# variants in the same deprecation notices as the base labels (runner-images#14254 lists
# `ubuntu-22.04` AND `ubuntu-22.04-arm`; #13518 lists `macos-14`, `macos-14-large`,
# `macos-14-xlarge`), so the list was right and the matcher was leaky.
# Matching the suffix here rather than adding six more entries keeps `banned_runners`
# reading as ONE label per image, and covers every present and future variant of every
# label already on it — including ones added later.
#
# `labels:` is the mapping form — `runs-on:` alone on its line, the label on a nested
# `labels:` child (the runner-group syntax). The matcher wants the label on the SAME line
# as its key, so that shape escaped it; the alternation closes it. A matrix key named
# anything other than `os:` (`runner:`, `platform:`) still escapes, deliberately: catching
# it means dropping the key prefix, which would then fire on every comment in the tree
# that names a label. Latent, not live — the fleet uses no runner groups.
while IFS= read -r rn; do
  [ -n "$rn" ] || continue
  while IFS= read -r hit; do note "EOL runner ($rn): $hit"; done \
    < <(grep -HnE "(runs-on|os|labels):.*(^|[[:space:],\"'[])${rn}(-(arm|large|xlarge))?([[:space:],\"'*]|\]|\$)" "${FILES[@]}" 2>/dev/null || true)
done < <(_yaml_list banned_runners)

# ── 3) external action `uses:` must pin a 40-hex SHA (fleet's own owner exempt) ─
if _yaml_bool require_action_sha_pin; then
  exempt="$(_yaml_val sha_pin_exempt_owner)"
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    ref="${m##*@}"
    spec="${m#*uses:}"; spec="${spec#"${spec%%[![:space:]]*}"}"  # text after `uses:`, ltrimmed
    owner="${spec%%/*}"
    # THE FIRST-PARTY EXEMPTION IS NARROW, and it has to be. This was a bare `continue` on an
    # owner-string match, so `uses: dotgibson/anything@main` passed the gate outright — and
    # nothing else in the tree asserted the `@vN` policy that JUSTIFIES the exemption, so the
    # policy was documented in RELEASE-STRATEGY.md and enforced nowhere.
    #
    # What the policy actually says is narrower than "this owner is trusted": it is the moving
    # MAJOR tag, on the fleet's own REUSABLE WORKFLOWS. So require that exact shape —
    # dotgibson/<repo>/.github/workflows/<name>.yml@v<N> — and let anything else from the same
    # owner fall through to the 40-hex requirement, which is the right default for a ref whose
    # contract is not governed by the release process.
    why="unpinned action (need a 40-hex SHA)"
    if [ -n "$exempt" ] && [ "$owner" = "$exempt" ]; then
      if grep -qE "^${exempt}/[A-Za-z0-9_.-]+/\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml@v[0-9]+$" <<<"$spec"; then
        continue                                                     # @vN reusable workflow: the policy's own shape
      fi
      # Not the policy's shape — so it FALLS THROUGH to the same 40-hex requirement everything
      # else faces, rather than being rejected outright. A first-party caller that chose to
      # SHA-pin is stricter than @vN, not weaker, and must not be told off for it.
      why="first-party ref outside the @vN reusable-workflow policy (use @vN, or pin a 40-hex SHA)"
    fi
    grep -qE '^[0-9a-f]{40}$' <<<"$ref" || note "$why: $m"
  done < <(grep -HnoE "uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[^[:space:]\"']+" "${FILES[@]}" 2>/dev/null || true)
fi

# ── 4) container images must pin an @sha256: digest ──────────────────────────
# A pinned reference ends in @sha256:<hex>; anything else — a bare `alpine` (implicit
# `latest`), an `alpine:3.21` tag — is mutable and moves under you. The surfaces an image
# reaches CI by fall into two groups:
#   (a) single-token surfaces — `image: <ref>`, the `container: <ref>` SHORTHAND (the
#       block form's `image:` child is caught by the same `image:` rule), and a
#       `uses: docker://<ref>` container action. Extract the one reference token and check
#       it directly, so a bare `alpine`/`node:20` is caught (a name:tag-only regex misses
#       it) and a digest-only `alpine@sha256:…` is accepted (that same regex would mis-read
#       it as unpinned). The shorthand and docker:// forms also slip sha-pin rule (3) — not
#       owner/repo form — so rule 4 is the only thing that can catch them.
#   (b) COMMAND surfaces — a `docker|podman run|build|pull|create` line, and a Containerfile
#       `FROM`. THIS RULE WAS KEYED ON A TOOL NAME, NOT ON THE HAZARD, and read one physical
#       line at a time: research-nonmutable-vm.yml drives containers with PODMAN and builds
#       one from a heredoc Containerfile, so three external images walked past the pinning
#       contract while this gate reported zero violations — a fedora-bootc `FROM`, a
#       registry:2 run, and bootc-image-builder:LATEST run --privileged with the ref parked
#       behind three `\` continuations (#1055). All three surfaces are covered below.
# This keeps the pinning contract airtight for the OS/role repos too, which inherit the
# *-call.yml@vN workflows.
if _yaml_bool require_container_digest_pin; then
  # (a) clean single-token surfaces
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    content="${line#*:*:}"                          # strip grep's file:linenum: prefix
    case "$content" in
    *docker://*) ref="${content##*docker://}" ;;    # uses: docker://<ref>
    *) ref="${content#*:}" ;;                        # image:/container: → value after the key
    esac
    ref="${ref#"${ref%%[![:space:]]*}"}"            # ltrim
    ref="${ref%%[[:space:]]*}"                       # first whitespace-delimited token only
    ref="${ref#[\"\']}"; ref="${ref%[\"\']}"         # strip one wrapping quote
    [ -n "$ref" ] || continue                        # value-less key (e.g. a workflow input) → skip
    case "$ref" in *@sha256:*) continue ;; esac      # digest-pinned (name:tag@sha256 or name@sha256)
    note "container image not digest-pinned ($ref): $line"
  done < <(grep -HnE '(^[[:space:]]*image:[[:space:]]*[^[:space:]#]|^[[:space:]]*container:[[:space:]]*[^[:space:]#]|uses:[[:space:]]*docker://)' "${FILES[@]}" 2>/dev/null || true)
  # (b) command surfaces. One awk over every file: it joins trailing-`\` continuations into
  # a LOGICAL line (reported at the chain HEAD — where a reader starts reading the command),
  # then tests each whitespace TOKEN against img_re ANCHORED. Anchoring is what lets a
  # tolerant scan survive a real command line: `-p 5000:5000` matches img_re as a substring
  # but not as a whole token. The scrub below is not defensive padding — every entry answers
  # a literal token in this tree's own workflows, and without it the rule reds on the very
  # file it was widened for. A token is skipped when it is:
  #   · the VALUE of `-t`/`--tag` on a BUILD (the image being produced — flagging it would be
  #     a violation with no remedy), or of `--name`/`--label`/`-l` (never an image). NOT
  #     generalisable to "the previous token began with -": that eats the image after --rm.
  #   · interpolated (`$`, backtick) — `docker pull "$IMAGE"` cannot be pinned here;
  #   · a flag, an absolute mount, or the build context (leading `-` `/` `.` `~`);
  #   · a `--flag=value` (no OCI reference contains `=`);
  #   · a port mapping (`5000:5000`, `127.0.0.1:8080:80`);
  #   · a local registry — `localhost:5000/x`, `10.0.2.2:5000/x` — or a `localhost/x` image
  #     built in this same job, for which no digest can exist;
  #   · already digest-pinned.
  # Three gaps are left open deliberately, in rule 2's sense above. A BARE `docker run alpine`
  # or `FROM alpine` (no tag) is still missed — group (b) has always been name:tag-only, so
  # the anchor narrows nothing, and that same tag requirement is what stops a multi-stage
  # `FROM builder` stage reference from ever false-firing. And `FROM` is anchored to the line
  # start, so one buried mid-line (a `printf 'FROM …'` writing a Containerfile) is not a
  # surface.
  #
  # A THIRD surface used to be missed here and is now covered by assign() above, because it
  # was THIS RULE'S OWN LESSON RECURRING: #1055 found rule 4 keyed on a TOOL NAME, so podman
  # walked past it; keying on a COMMAND SURFACE has the same shape, because an ASSIGNMENT
  # hides the literal just as well as a different runtime did. research-nonmutable.yml picks
  # its image in a `case` (`img='nixos/nix:latest'`), feeds it through the matrix, and runs
  # `docker run … "$IMAGE"` — so the literal never reached a command line, and `"$IMAGE"` is
  # a shape the scrub above must exempt. Two MUTABLE `:latest` tags rode through that file
  # until #1099. What assign() cannot see is the narrower gap named in its own comment: an
  # UNQUALIFIED `img=alpine:3.21`, which no evidence in the token distinguishes from `t=12:30`.
  # All three gaps are latent MISSES, not latent reds — the failure mode a gate can afford.
  img_re='([a-z0-9]+([._-][a-z0-9]+)*/)*[a-z0-9]+([._-][a-z0-9]+)*:[a-z0-9][a-z0-9._-]*(@sha256:[0-9a-f]+)?'
  while IFS= read -r hit; do
    [ -n "$hit" ] && note "container image not digest-pinned: $hit"
  done < <(awk -v img="$img_re" '
    # a shell-assignment VALUE: the surface a command-line scan structurally cannot see,
    # because the literal is bound to a variable here and only "$IMAGE" ever reaches a
    # `docker run`. Strictly narrower than the command scan, and it has to be: a command
    # line supplies the context that says "this argument is an image", an assignment supplies
    # none, so the VALUE must carry that evidence itself. Hence the `/` requirement — a
    # registry- or namespace-qualified ref (`quay.io/fedora/x:44`, `nixos/nix:latest`), never
    # a bare `img=alpine:3.21`, which is indistinguishable from `t=12:30` to a regex. That is
    # the same bare-name gap group (b) already documents, arrived at from the other side.
    function assign(t, fname, ln,   eq, v, c, L) {
      if ((eq = index(t, "=")) < 2) return
      if (substr(t, 1, eq - 1) !~ /^[A-Za-z_][A-Za-z0-9_]*$/) return  # not a shell name: a --flag=value
      v = substr(t, eq + 1)
      c = substr(v, 1, 1); if (c == q || c == dq) v = substr(v, 2)
      sub(/[);,]+$/, "", v)                                            # `img='x:1';` in a case arm
      L = length(v); if (L == 0) return
      c = substr(v, L, 1); if (c == q || c == dq) v = substr(v, 1, L - 1)
      if (v == "") return
      if (index(v, "$") > 0 || index(v, bt) > 0) return
      if (index(v, "/") == 0) return                                   # unqualified: see above
      if (v ~ /^(localhost|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)(:[0-9]+)?\//) return
      if (index(v, "@sha256:") > 0) return
      if (v ~ ("^" img "$")) printf "%s:%d: %s\n", fname, ln, v
    }
    function emit(s, fname, ln,   n, i, t, c, L, prev, isbuild, iscmd, arr) {
      iscmd = (s ~ /(docker|podman)[[:space:]]+(run|build|pull|create)/ ||
               s ~ /^[[:space:]]*FROM[[:space:]]+/)
      if (!iscmd && index(s, "=") == 0) return
      isbuild = (s ~ /(docker|podman)[[:space:]]+build/)
      n = split(s, arr, " ")           # single-space FS = default splitting, so the leading
      prev = ""                        # indentation never becomes an empty first field
      for (i = 1; i <= n; i++) {
        t = arr[i]
        assign(t, fname, ln)           # every line, command or not
        if (!iscmd) continue
        if (prev == "--name" || prev == "--label" || prev == "-l" ||
            (isbuild && (prev == "-t" || prev == "--tag"))) { prev = t; continue }
        prev = t
        c = substr(t, 1, 1); if (c == q || c == dq) t = substr(t, 2)
        sub(/^[(]+/, "", t); sub(/[);,]+$/, "", t)   # `(cd x && docker build …)`, `pull a:b;`
        L = length(t); if (L == 0) continue
        c = substr(t, L, 1); if (c == q || c == dq) t = substr(t, 1, L - 1)
        if (t == "") continue
        if (index(t, "$") > 0 || index(t, bt) > 0) continue
        c = substr(t, 1, 1)
        if (c == "-" || c == "/" || c == "." || c == "~") continue
        if (index(t, "=") > 0) continue
        if (t ~ /^[0-9.:]+(\/(tcp|udp|sctp))?$/) continue
        if (t ~ /^(localhost|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)(:[0-9]+)?\//) continue
        if (index(t, "@sha256:") > 0) continue
        if (t ~ ("^" img "$")) printf "%s:%d: %s\n", fname, ln, t
      }
    }
    BEGIN { q = sprintf("%c", 39); dq = sprintf("%c", 34); bt = sprintf("%c", 96) }
    FNR == 1 { if (pend) { emit(acc, fn, first); pend = 0; acc = "" } }  # no bleed across files
    {
      if (!pend) { first = FNR; fn = FILENAME; acc = "" }
      cur = $0
      if (cur ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", cur); acc = acc cur " "; pend = 1; next }
      acc = acc cur; pend = 0; emit(acc, fn, first); acc = ""
    }
    END { if (pend) emit(acc, fn, first) }                               # a chain at EOF
  ' "${FILES[@]}" 2>/dev/null || true)
fi

# ── 5) every workflow declares a top-level permissions: block ────────────────
# Anchored at column 0 so a job-level `  permissions:` doesn't satisfy the rule —
# a job grant narrows the workflow default, it doesn't establish one.
if _yaml_bool require_workflow_permissions && [ "${#WORKFLOWS[@]}" -gt 0 ]; then
  for wf in "${WORKFLOWS[@]}"; do
    grep -qE '^permissions:[[:space:]]*$|^permissions:[[:space:]]+' "$wf" \
      || note "no top-level permissions: block (least-privilege): $wf"
  done
fi

# ── 5b) a permissions: block must not be a blanket grant ─────────────────────
# Rule 5 checks that the block EXISTS and never what it says — so `permissions: write-all`,
# the maximal token grant, satisfied a rule named for least privilege. Read the value:
# at ANY indent (a job-level grant that widens to everything is the same hole, one level
# down), bare or quoted, and with a trailing `# comment` tolerated — a rationale beside
# the grant must not be the way past the gate. Anchored to the key and the line end, so
# the word in a comment or in prose does not fire; that is why this is a dimension of its
# own and not a `banned_patterns` entry (rule 1 is a blind `grep -F`).
# Scoped to WORKFLOWS like rule 5: `permissions:` is not a key a composite action has.
if [ "${#WORKFLOWS[@]}" -gt 0 ]; then
  while IFS= read -r pv; do
    [ -n "$pv" ] || continue
    while IFS= read -r hit; do note "blanket permissions grant ($pv): $hit"; done \
      < <(grep -HnE "^[[:space:]]*permissions:[[:space:]]*[\"']?${pv}[\"']?[[:space:]]*(#.*)?\$" "${WORKFLOWS[@]}" 2>/dev/null || true)
  done < <(_yaml_list banned_permission_values)
fi

# ── 6) every actions/checkout states persist-credentials: explicitly ─────────
# Needs the step's `with:` block associated with its `uses:`, which a line-at-a-time
# grep can't do — so walk each checkout back to the `- ` that opens its step, forward to
# the next sibling `- ` (or any dedent past it), and look for the key inside that window.
# Both orderings work: the key is found whether `with:` precedes or follows `uses:`.
if _yaml_bool require_explicit_persist_credentials && [ "${#WORKFLOWS[@]}" -gt 0 ]; then
  for wf in "${WORKFLOWS[@]}"; do
    while IFS= read -r hit; do
      [ -n "$hit" ] && note "checkout without an explicit persist-credentials: $hit"
    done < <(awk '
      { l[NR] = $0 }
      END {
        for (i = 1; i <= NR; i++) {
          if (l[i] !~ /uses:[[:space:]]*actions\/checkout@/) continue
          s = i
          while (s > 1 && l[s] !~ /^[[:space:]]*-[[:space:]]/) s--
          match(l[s], /^[[:space:]]*/); ind = RLENGTH
          e = s + 1
          while (e <= NR) {
            if (l[e] ~ /^[[:space:]]*$/) { e++; continue }
            match(l[e], /^[[:space:]]*/); ii = RLENGTH
            if (ii < ind) break
            if (ii == ind && l[e] ~ /^[[:space:]]*-[[:space:]]/) break
            e++
          }
          ok = 0
          for (j = s; j < e; j++)
            if (l[j] ~ /^[[:space:]]*persist-credentials:[[:space:]]*(true|false)([[:space:]]|$)/) ok = 1
          if (!ok) printf "%s:%d\n", FILENAME, i
        }
      }
    ' "$wf" 2>/dev/null || true)
  done
fi

# ── 7) no attacker-controlled expression spliced into a `run:` body ──────────
# A `${{ }}` expression is substituted by the RUNNER, textually, before the shell ever
# sees the script — so an attacker-controlled value (a PR title, a branch name) is not
# data, it is source code. The fleet already routes those through `env:` and reads `$VAR`,
# and says so at the call sites (auto-tag-call.yml, notify-web-call.yml) — but a comment
# is not a gate, and `actionlint`, which the audit already runs, has no equivalent rule.
#
# Scoped to FILES, not WORKFLOWS: a composite action's `run:` is the same hazard, and
# rule 3 already treats composite refs as in-scope.
#
# The context list deliberately excludes `inputs.*`. setup-core-tools/action.yml
# interpolates `${{ inputs.bindir }}` inline in ~8 run: steps; that is a FIRST-PARTY
# composite input, and banning it is a fix-first migration for no security gain.
#
# Structurally the same block-scalar walk as rule 6: find the `run:` key, take its
# column, and treat every more-indented line as body until the first non-blank dedent.
# Checking happens INSIDE each `${{ … }}` span rather than against the raw line, so a
# context name appearing in prose or in a comment beside the step is not a false fire.
if [ -n "$(_yaml_list banned_run_interpolation_contexts)" ]; then
  _ctx_list="$(_yaml_list banned_run_interpolation_contexts | tr '\n' ' ')"
  for f in "${FILES[@]}"; do
    while IFS= read -r hit; do
      [ -n "$hit" ] && note "untrusted expression interpolated into a run: body (route it through env: and read \$VAR): $hit"
    done < <(awk -v ctxs="$_ctx_list" '
      function flag(line, ln,   rest, p, q, expr, k) {
        rest = line
        while ((p = index(rest, "${{")) > 0) {
          rest = substr(rest, p + 3)
          q = index(rest, "}}")
          if (q == 0) { expr = rest; rest = "" }
          else        { expr = substr(rest, 1, q - 1); rest = substr(rest, q + 2) }
          for (k = 1; k <= nctx; k++)
            if (index(expr, ctx[k]) > 0) {
              gsub(/^[[:space:]]+|[[:space:]]+$/, "", expr)
              printf "%s:%d: ${{ %s }}\n", FILENAME, ln, expr
              return
            }
        }
      }
      BEGIN { nctx = split(ctxs, ctx, " ") }
      { l[NR] = $0 }
      END {
        for (i = 1; i <= NR; i++) {
          if (l[i] !~ /^[[:space:]]*(-[[:space:]]+)?run:/) continue
          # block scalar (`run: |`, `run: >-`, `run: |2`) vs a one-line `run: cmd`
          if (l[i] !~ /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*[|>][0-9]*[-+]?[[:space:]]*$/) {
            flag(l[i], i)
            continue
          }
          ind = index(l[i], "run:") - 1
          for (e = i + 1; e <= NR; e++) {
            if (l[e] ~ /^[[:space:]]*$/) continue          # blanks belong to the block
            match(l[e], /^[[:space:]]*/)
            if (RLENGTH <= ind) break                      # first real dedent ends it
            flag(l[e], e)
          }
        }
      }
    ' "$f" 2>/dev/null || true)
  done
  unset _ctx_list
fi

# ── 8) every runner job declares timeout-minutes ─────────────────────────────
# Left unset, GitHub's default is 360 minutes — six hours of a held runner and a live
# GITHUB_TOKEN for a job that hung on a prompt, a network stall, or a step that was
# tampered with. Core owns all six *-call.yml@vN reusable workflows the fleet consumes,
# so the jobs the OS repos actually execute are defined HERE; a floor rule locks in a
# property currently held only by convention.
#
# KEYED ON `runs-on:`, NOT on "every job". A job that calls a reusable workflow (`uses:`
# at job level) cannot legally carry timeout-minutes, so requiring it there would be a
# guaranteed false fire. Scoped to WORKFLOWS, not FILES: a composite action has no jobs.
#
# The walk itself is _job_records (above), shared with --job-census so the counts this
# rule's rationale quotes have one definition. This rule is the filter over it: a job
# that sits on a runner and declares no timeout.
if _yaml_bool require_job_timeout; then
  while IFS="$(printf '\t')" read -r _r8_kind _r8_timeout _r8_at; do
    # An `if`, not a `&&` chain: under `set -e` a false test as the body's LAST command
    # takes the whole script down mid-gate.
    if [ "$_r8_kind" = runner ] && [ "$_r8_timeout" = 0 ]; then
      note "job without timeout-minutes (GitHub's default is 360m): $_r8_at"
    fi
  done <<EOF
$(_job_records)
EOF
fi

if [ "$violations" -eq 0 ]; then
  echo "check-modern: CI meets the modern baseline (${#FILES[@]} workflow/action files)"
  exit 0
fi
printf 'check-modern: %d violation(s) below the floor (scripts/modern-baseline.yml)\n' "$violations" >&2
exit 1

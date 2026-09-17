#!/usr/bin/env bash
# scripts/fleet-app-scope.sh — the App-installation register (#1071)
# ──────────────────────────────────────────────────────────────────────────────
# CAN THE FAN-OUT'S CREDENTIAL ACTUALLY REACH THE REPOS IT PUSHES TO? Every other fleet
# register asks a question about a repo's CONTENTS. This one asks about the GitHub App
# installation that `sync-fanout.yml` mints from — the one piece of the release path that
# lives entirely outside every checkout, and was therefore checked by nothing.
#
# It bit on v7.9.0: the fan-out synced all ten targets and failed to push to one.
# `dotfiles-NixOS` had been registered in scripts/os-repos.txt (#1064) but never added to
# the `dotgibson-fleet-sync` installation, which is `repository_selection=selected`, so
# the minted token answered 403 on the tenth push — at the END of a release, after nine
# PRs had already opened. Adding a repo to the fleet is TWO facts in two systems (the git
# list, and the App's repository access); only the first of them had a gate.
#
# TWO HALVES, READABLE FROM OPPOSITE ENVIRONMENTS. This is the awkward, load-bearing shape
# of the check, and it is why each half reports its own coverage instead of one implying
# the other:
#
#   grant  GET /orgs/<org>/installations — is the installation there, un-suspended, and
#          holding EXACTLY the verbs GITHUB-APP-AUTH.md grants it? Needs an ORG-ADMIN user
#          token (`read:org`). CI's GITHUB_TOKEN cannot read it, and neither can an App
#          installation token — so this half runs only when a human types
#          `make fleet-app-scope`. That blind spot is documented, not papered over
#          (GITHUB-APP-AUTH.md, "Where the App is installed").
#
#   reach  GET /installation/repositories — WHICH repos does the installation cover? Needs
#          an INSTALLATION token, which no local environment can hold: the private key
#          lives in Actions secrets, so this half runs only in CI
#          (.github/workflows/fleet-app-scope.yml, and as a preflight inside
#          sync-fanout.yml itself). A maintainer's `gh` token is rejected outright by the
#          /user/installations/<id>/repositories route, so there is no local substitute.
#
# CANNOT READ IS NEVER A PASS — fleet-protection.sh's doctrine, for the same reason: a
# half that could not be read must stay distinguishable from a half that was read and was
# clean, or the register reports "checked and fine" about something it never saw. An unread
# half prints `–` and, under --check, exits 3 (the fleet's environment-skip code). A real
# finding OUTRANKS it: rc only becomes 3 when nothing worse was found.
#
# WHAT THE INSTALLATION MUST COVER: scripts/os-repos.txt through load_os_repos (the ONE
# reader, #669 — this register keeps no second copy of the fleet list), plus `dotfiles-core`,
# `dotfiles-web` and `dotfiles-Windows`, the three exceptions GITHUB-APP-AUTH.md names. Core
# and Windows are there for their own self-PRs (freshness.yml; the three sync bots), web for
# the notify dispatch plus its own refresh PR. That is thirteen repos; `htpx` is deliberately
# NOT in it. Windows was not in it either until dotgibson/dotfiles-Windows#268 gave its bots
# an App-authored PR to open — before that its install was surplus, and this register said so.
#
# Requires an authenticated `gh` plus `jq`; needs no local checkout beyond this repo's own
# scripts/os-repos.txt.
#
# Usage:
#   ./scripts/fleet-app-scope.sh                  report (default; writes nothing, exit 0)
#   ./scripts/fleet-app-scope.sh --check          exit 1 on a finding, 3 if a half was unread
#   ./scripts/fleet-app-scope.sh --reach-only     skip the grant half (for CI, which cannot
#                                                 read it — mirrors fleet-protection.sh's
#                                                 --rulesets-only)
#   ./scripts/fleet-app-scope.sh --require "a b"  the repos whose ABSENCE is fatal (default:
#                                                 all thirteen). sync-fanout.yml passes the
#                                                 targets of the run in hand, so a subset
#                                                 backfill is not failed by an unrelated repo.
# Env: GITHUB_REPOSITORY_OWNER (default: dotgibson)
set -uo pipefail

# A heredoc, NOT `sed -n '2,Np'` over this file's own header: the fixed-range idiom
# truncates silently the moment the banner grows (fleet-release-triggers.sh's header
# records the time it did).
usage() {
  cat <<'EOF'
usage: fleet-app-scope.sh [--check] [--reach-only] [--require "repo repo …"]

The App-installation register: can the fan-out's GitHub App credential reach every repo
the fan-out pushes to, and does it hold exactly the verbs it is documented to hold?

  (no args)     report both halves on stdout and exit 0 (the register family's posture:
                the report is the product; --check is what enforces)
  --check       exit 1 on a finding, 3 if a half could not be read at all
  --reach-only  skip the grant half — for CI, whose token cannot read /orgs/…/installations
  --require R   space-separated repos whose ABSENCE from the installation is fatal
                (default: every expected repo). Passing it also downgrades an EXTRA
                installed repo to a warning: a consumer checking its own targets must not
                be blocked by scope hygiene it did not cause.
  -h, --help    show this and exit

Row glyphs:  ✓ clean   ✗ finding   ! warning (non-fatal)   – not read / skipped

NOTE ON EXIT 3, AND WHY `make fleet-app-scope` OMITS --check: the reach half needs a
GitHub App installation token, which only CI can mint, so a bare `--check` on a maintainer
box is EXPECTED to exit 3 — the half genuinely did not run. The Makefile target runs the
reporter for that reason; .github/workflows/fleet-app-scope.yml is what covers reach.
EOF
}

HERE="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
# Sourced for ONE thing: load_os_repos, the single reader of scripts/os-repos.txt (#669).
# This register prints its own rows rather than going through the lib's pass/fail helpers,
# so the only other effect is defining them; fail() is used on the fleet-list error alone.
# shellcheck source=scripts/lib/common.sh
source "$HERE/scripts/lib/common.sh"

ORG="${GITHUB_REPOSITORY_OWNER:-dotgibson}"
APP_SLUG=dotgibson-fleet-sync
# The verbs GITHUB-APP-AUTH.md grants, rendered as `key=value` pairs sorted by key —
# which is the order `jq 'to_entries | sort'` produces, so the two are string-comparable
# without an associative array (the bash 3.2 floor, §5k).
#
# `metadata=read` IS PART OF THE CONTRACT and is not an oversight in the doc's three
# bullets: GitHub grants Metadata: read mandatorily to any App holding a repository
# permission and offers no way to turn it off, so the API always answers with four keys.
# It is also the one the reach half spends — GET /installation/repositories needs it.
WANT_PERMS="contents=write metadata=read pull_requests=write workflows=write"

CHECK=0
REACH_ONLY=0
REQUIRE=""
REQUIRE_GIVEN=0
while [ $# -gt 0 ]; do
  case "$1" in
  --check) CHECK=1; shift ;;
  --reach-only) REACH_ONLY=1; shift ;;
  --require)
    REQUIRE="${2:?--require needs a space-separated repo list}"
    REQUIRE_GIVEN=1
    shift 2
    ;;
  --require=*)
    REQUIRE="${1#--require=}"
    REQUIRE_GIVEN=1
    shift
    ;;
  -h | --help) usage; exit 0 ;;
  *)
    echo "unknown argument: $1 (try --help)" >&2
    exit 2
    ;;
  esac
done

command -v gh >/dev/null || { echo "gh not installed" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not installed" >&2; exit 1; }

# The fleet, through the ONE reader. An unreadable list stops the register rather than
# degrading it: "the installation covers everything it should" computed against an empty
# expected set is the most dangerous green this script could print.
load_os_repos || {
  fail "$CORE_OS_REPOS_ERR — cannot enumerate the fleet to compare the installation against"
  exit 2
}
# The three exceptions GITHUB-APP-AUTH.md names, beside the fan-out targets. Spelled out
# here and asserted against that doc by scripts/test/90-policy-gates.sh — ONE direction: every
# entry here must be documented there. The reverse is caught at runtime by the EXTRA finding
# below, against the live installation, rather than by parsing English prose.
EXTRA_REPOS=(dotfiles-core dotfiles-web dotfiles-Windows)
EXPECTED="$(printf '%s\n' "${CORE_OS_REPOS[@]}" "${EXTRA_REPOS[@]}" | sort -u)"
[ "$REQUIRE_GIVEN" -eq 1 ] || REQUIRE="$(tr '\n' ' ' <<<"$EXPECTED")"

fin=0     # a real finding (rc 1)
unread=0  # a half nobody could read (rc 3, unless a finding outranks it)
SELECTION=''

# ── grant half: the installation itself, and the verbs it holds ───────────────
if [ "$REACH_ONLY" -eq 1 ]; then
  echo "– grant: skipped (--reach-only)"
elif ! inst_body="$(gh api "/orgs/$ORG/installations" 2>/dev/null)"; then
  echo "– grant: NOT READ — /orgs/$ORG/installations needs an org-admin token with read:org."
  echo "      UNPROVEN, not clean. No CI token can read it (GITHUB-APP-AUTH.md forbids a PAT),"
  echo "      so run \`make fleet-app-scope\` on a maintainer box with \`gh auth status\` green."
  unread=1
else
  # The org endpoint answers {total_count, installations:[…]} — `.installations[]`, never
  # `.[]`, which yields nothing and would read as "no such App".
  inst="$(jq --arg s "$APP_SLUG" '.installations[] | select(.app_slug == $s)' <<<"$inst_body" 2>/dev/null)"
  if [ -z "$inst" ]; then
    echo "✗ grant: no \`$APP_SLUG\` installation on $ORG — the fan-out has no credential at all."
    echo "      Install it (GITHUB-APP-AUTH.md) before the next release."
    fin=1
  else
    SELECTION="$(jq -r '.repository_selection // empty' <<<"$inst")"
    inst_id="$(jq -r '.id // empty' <<<"$inst")"
    susp="$(jq -r '.suspended_at // empty' <<<"$inst")"
    have_perms="$(jq -r '.permissions | to_entries | map("\(.key)=\(.value)") | sort | join(" ")' <<<"$inst")"

    if [ -n "$susp" ]; then
      echo "✗ grant: installation $inst_id is SUSPENDED (since $susp) — every mint fails until it is resumed"
      fin=1
    fi

    if [ "$have_perms" = "$WANT_PERMS" ] && [ -n "$susp" ]; then
      # Don't crown a suspended installation with a ✓ on the next line: the verbs being
      # right is a detail of a half that already has its finding.
      echo "      (the verbs themselves are correct: [$have_perms], selection=$SELECTION)"
    elif [ "$have_perms" = "$WANT_PERMS" ]; then
      echo "✓ grant: installation=$inst_id selection=$SELECTION perms=[$have_perms]"
    else
      echo "✗ grant: installation $inst_id holds [$have_perms]"
      echo "      documented (GITHUB-APP-AUTH.md, \"The permissions the App must hold\"): [$WANT_PERMS]"
      # Name both directions: a MISSING verb breaks the fan-out now, an EXTRA one is reach
      # the fleet never granted. Newline lists + comm, not an associative array (§5k).
      _p_miss="$(comm -13 <(tr ' ' '\n' <<<"$have_perms" | sort) <(tr ' ' '\n' <<<"$WANT_PERMS" | sort) | paste -sd' ' -)"
      _p_extra="$(comm -23 <(tr ' ' '\n' <<<"$have_perms" | sort) <(tr ' ' '\n' <<<"$WANT_PERMS" | sort) | paste -sd' ' -)"
      [ -n "$_p_miss" ] && echo "      MISSING: $_p_miss — a fan-out that needs this verb fails outright"
      [ -n "$_p_extra" ] && echo "      EXTRA:   $_p_extra — \"Everything else: No access\"; revoke it or document it"
      unset _p_miss _p_extra
      fin=1
    fi
  fi
  unset inst inst_body
fi

# ── reach half: which repos the installation actually covers ─────────────────
if [ "$SELECTION" = all ]; then
  # Answered by the grant half alone, and conclusively: no target can be missing from an
  # installation that covers the whole account. (Both endpoints carry this field.)
  echo "✓ reach: repository_selection=all — every repo in $ORG is covered, so no target can 403"
elif ! reach_raw="$(gh api --paginate "/installation/repositories" \
  --jq '"SEL " + .repository_selection, (.repositories[] | "REPO " + .name)' 2>/dev/null)"; then
  echo "– reach: NOT READ — /installation/repositories needs a GitHub App INSTALLATION token."
  echo "      UNPROVEN, not clean. No local environment can mint one (the private key is an"
  echo "      Actions secret); .github/workflows/fleet-app-scope.yml is what covers this half."
  unread=1
else
  # --paginate + --jq streams per page, so the selection line repeats identically once per
  # page: take the first. Paginated deliberately — the default 30/page fits thirteen today,
  # and a silent truncation at 31 would invent MISSING repos and block releases.
  SELECTION="$(awk '/^SEL /{print $2; exit}' <<<"$reach_raw")"
  installed="$(awk '/^REPO /{print $2}' <<<"$reach_raw" | sort -u)"
  n_installed=$(printf '%s\n' "$installed" | grep -c . || true)

  if [ "$SELECTION" = all ]; then
    echo "✓ reach: repository_selection=all — every repo in $ORG is covered, so no target can 403"
  elif [ -z "$installed" ]; then
    echo "✗ reach: the installation covers NO repositories — every fan-out push will 403"
    fin=1
  else
    _missing="$(comm -13 <(printf '%s\n' "$installed") <(printf '%s\n' "$EXPECTED"))"
    _extra="$(comm -23 <(printf '%s\n' "$installed") <(printf '%s\n' "$EXPECTED"))"

    # CLASSIFY BEFORE PRINTING THE HEADER, so the header's glyph means what the rest of
    # the fleet's glyphs mean. A `✗` over rows that are all warnings, on a run that then
    # exits 0, teaches a reader to discount the glyph — which is how a real ✗ gets skimmed
    # past later.
    _detail=''
    _fatal=0
    _warn=0

    # A missing repo is FATAL when the caller requires it. sync-fanout.yml passes the
    # targets of the run in hand precisely so a one-repo backfill is not failed over a
    # repo it will never touch — and so a release is never denied for a reason nobody
    # can act on mid-fan-out.
    #
    # WHICH KIND of install is missing decides the CONSEQUENCE, and the two are not the
    # same failure, so the row names its own rather than asserting the fan-out's. A
    # fan-out target 403s on a PUSH, at the end of a release. A self-PR exception
    # (EXTRA_REPOS) never reaches a push at all: the mint INSIDE that repo 404s on
    # /repos/<owner>/<repo>/installation, its bots fall back to GITHUB_TOKEN, and the
    # jobs stay green while degrading. Until #1116 this loop printed the fan-out sentence
    # over both — `dotfiles-Windows` went missing and the register sent its reader looking
    # for a release that was never going to break, while three sync bots quietly lost
    # their App authorship. Membership by ` x ` inside ` ${arr[*]} `, not an associative
    # array (the bash 3.2 floor, §5k).
    for _r in $_missing; do
      case " ${CORE_OS_REPOS[*]} " in
      *" $_r "*)
        _class='fan-out target'
        _harm="the next release 403s on its push, at the END of the fan-out (v7.9.0, #1071)"
        ;;
      *)
        _class='self-PR install'
        _harm="every mint in that repo 404s and falls back to GITHUB_TOKEN, so its own
           bots' PRs open unauthored and sit BLOCKED — and stay GREEN while doing it"
        ;;
      esac
      case " $REQUIRE " in
      *" $_r "*)
        _detail="$_detail
✗   MISSING: $_r is a $_class the App cannot reach —
           $_harm
      Fix: Organization settings → GitHub Apps → $APP_SLUG → Configure →
           Repository access → add $_r. Needs an Organization Owner.
      REST: gh api -X PUT /user/installations/<installation id>/repositories/<repo id>
           ids: gh api /orgs/$ORG/installations --jq '.installations[]|select(.app_slug==\"$APP_SLUG\")|.id'
                gh api /repos/$ORG/$_r --jq .id"
        _fatal=1
        ;;
      *)
        _detail="$_detail
!   MISSING: $_r ($_class) is expected in the installation but is not a target of this run"
        _warn=1
        ;;
      esac
    done

    # EXTRA is scope the fleet never granted. Red in the register (nobody else asks this
    # question), a warning for a consumer that named its own targets.
    for _r in $_extra; do
      if [ "$REQUIRE_GIVEN" -eq 1 ]; then
        _detail="$_detail
!   EXTRA:   $_r is installed but is not in the expected set"
        _warn=1
      else
        _detail="$_detail
✗   EXTRA:   $_r is installed but nothing in the fleet writes to it — remove it,
      or add it to GITHUB-APP-AUTH.md's install list. Its token carries
      contents+workflows:write, so excess reach is excess blast radius."
        _fatal=1
      fi
    done

    if [ "$_fatal" -eq 1 ]; then
      echo "✗ reach: selection=$SELECTION — $n_installed repo(s) installed; the installed set does not match the fleet"
      fin=1
    elif [ "$_warn" -eq 1 ]; then
      echo "! reach: selection=$SELECTION — $n_installed repo(s) installed; every required target is reachable"
    else
      echo "✓ reach: selection=$SELECTION — all $n_installed expected repo(s) installed"
    fi
    [ -n "$_detail" ] && printf '%s\n' "${_detail#
}"
    unset _missing _extra _r _class _harm _detail _fatal _warn
  fi
  unset reach_raw installed n_installed
fi

# THE BARE REPORTER ALWAYS EXITS 0 — the register family's contract (the report IS the
# product; every `make fleet-*` target runs it without --check for that reason). Enforcement
# is opt-in, and it has to be: the reach half is structurally unprovable on a maintainer box,
# so a --check-by-default target would sit permanently non-zero and be learned as noise.
[ "$CHECK" -eq 1 ] || exit 0

rc=0
[ "$fin" -eq 1 ] && rc=1
# A real finding OUTRANKS an unread half (gen-theme.sh's rule, verbatim): a run that found
# a missing push target AND could not read the other half must report the finding, not an
# environment skip.
if [ "$unread" -eq 1 ] && [ "$rc" -eq 0 ]; then rc=3; fi
exit "$rc"

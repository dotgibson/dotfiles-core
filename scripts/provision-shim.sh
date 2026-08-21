#!/usr/bin/env sh
# scripts/provision-shim.sh — build a PATH shim that neuters provisioning side effects.
# ──────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS: `--links-only` returns before provision() is entered, so package
# installation, retries, upstream installers, repo/key setup and every failure path around
# them are executed by NO CI job anywhere in the fleet (#575, and #461/#512 before it). One
# bug class has already shipped green twice on the back of that: a RETURN trap leaked from
# verified_install into provision()'s frame and aborted every fresh-box run AFTER installing
# everything and BEFORE wire_links (dotgibson/dotfiles-Debian#2).
#
# WHAT IT BUYS, AND WHAT IT DOES NOT. Most of that bug class is CONTROL FLOW, not I/O — a
# leaked trap, a bare `refresh` aborting under `set -e`, an unchecked GPG import, a tool
# assumed present on a minimal image. Running provision() with the package managers and
# downloaders replaced by logging no-ops executes those paths without installing anything or
# touching the network. It asserts that provision() RUNS AND RETURNS, not that provisioning
# WORKS: no package is really installed, so nothing here can tell you a package name is
# wrong or a repo key is bad. That remains the job of a real (periodic) bootstrap.
#
# HONEST LIMITS, so a green run is not over-read:
#   * a stub returns 0, so a code path that only executes on package-manager FAILURE is
#     still unexercised — the shim proves the happy path returns, not the sad one
#   * the download stubs (curl/wget/gpg) DO create their -o target, but with placeholder
#     bytes — so a checksum-verifying step correctly rejects it and skips. That is the real
#     refusal path being exercised, not a bug; a step that instead requires a VALID asset is
#     not shim-clean yet
#   * a stub that returned 0 while writing nothing would manufacture a state the real tool
#     cannot produce, and fail a correctly-guarded caller. That is why the output-flag
#     handling above exists rather than a blanket no-op
#   * anything invoked by absolute path (/usr/bin/apt-get) bypasses the shim entirely
#
# It prints the shim directory on stdout and nothing else, so a caller can do:
#     PATH="$(sh core/scripts/provision-shim.sh):$PATH"
#
# POSIX sh, not bash: it runs inside whatever the distro image ships before any prep has
# necessarily installed bash (alpine's default shell is ash).
# ──────────────────────────────────────────────────────────────────────────────
set -eu

BIN="${PROVISION_SHIM_DIR:-${TMPDIR:-/tmp}/provision-shim}"
LOG="${PROVISION_SHIM_LOG:-$BIN/../provision-shim.log}"
mkdir -p "$BIN"
: >"$LOG"

# OUTPUT-PRODUCING TOOLS GET A SEPARATE STUB, and the distinction is load-bearing. A stub
# that exits 0 while writing nothing manufactures a state the real tool CANNOT produce —
# `gpg --dearmor -o FILE` returning success with no FILE — and the script under test then
# fails on a correctly-guarded line. That happened on the first real run: dotfiles-Debian's
# _add_vendor_repo guards its `chmod` behind the curl|gpg pipeline, exactly as it should,
# and still died because the pipeline lied about succeeding (dotgibson/dotfiles-Debian#11).
# A red run must mean the repo has a bug, not that the harness invented one — so these
# honour -o/--output and create the file they claim to have written.
for cmd in curl wget gpg gpg2; do
  cat >"$BIN/$cmd" <<STUB
#!/usr/bin/env sh
# provision-shim: logged no-op that HONOURS its output flag. See core/scripts/provision-shim.sh.
printf '%s %s\n' "$cmd" "\$*" >>"$LOG"
out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o | --output) out="\$2"; shift 2 ;;
    -o*) out="\${1#-o}"; shift ;;
    --output=*) out="\${1#--output=}"; shift ;;
    *) shift ;;
  esac
done
# The content is deliberately not a valid asset: a checksum-verifying caller MUST still
# reject it. verified_install refusing a mismatched download is correct behaviour and the
# run should show it, rather than the shim faking a passing checksum.
if [ -n "\$out" ]; then
  mkdir -p "\$(dirname "\$out")" 2>/dev/null || true
  printf 'provision-shim placeholder\n' >"\$out" 2>/dev/null || true
fi
exit 0
STUB
  chmod +x "$BIN/$cmd"
done

# The commands a provision() reaches for. Package managers, privilege escalation, and the
# rest. `git` is deliberately ABSENT: bootstraps clone real things (tpm) that the caller
# pre-seeds instead, and stubbing git would mask wiring bugs this job should still catch.
for cmd in \
  apt-get apt apt-key add-apt-repository dpkg debconf-set-selections \
  dnf yum rpm \
  pacman paru yay \
  zypper \
  apk \
  emerge eselect layman \
  brew \
  snap flatpak \
  gpgconf \
  systemctl update-alternatives unattended-upgrade \
  pipx go cargo npm; do
  cat >"$BIN/$cmd" <<STUB
#!/usr/bin/env sh
# provision-shim: logged no-op. See core/scripts/provision-shim.sh.
printf '%s %s\n' "$cmd" "\$*" >>"$LOG"
exit 0
STUB
  chmod +x "$BIN/$cmd"
done

# sudo/doas are special: swallowing them would skip the command they wrap, hiding whatever
# provision() actually meant to run. Re-exec the tail instead, so `sudo apt-get install x`
# still reaches the apt-get stub above and still gets logged.
for cmd in sudo doas; do
  cat >"$BIN/$cmd" <<'STUB'
#!/usr/bin/env sh
# provision-shim: drop the escalation, run the command. See core/scripts/provision-shim.sh.
while [ $# -gt 0 ]; do
  case "$1" in
    -n | -E | -H | -k) shift ;;
    -u) shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
[ $# -eq 0 ] && exit 0
exec "$@"
STUB
  chmod +x "$BIN/$cmd"
done

printf '%s\n' "$BIN"

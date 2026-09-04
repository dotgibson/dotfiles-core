# scripts/test/57-check-links.sh
# the hermetic links gate (scripts/check-links.sh)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── the hermetic links gate (scripts/check-links.sh) ──────────────────────────
# The second half of `make check` in the four repos that run a links-only leg — Fedora,
# Debian, Gentoo, openSUSE — lifted out of their four copied Makefile recipes (#852). It is
# Core-owned precisely BECAUSE it was copied: the same defect turned up in three of the four
# at once — `HOME=` alone is not hermetic, since bootstrap.sh and
# lib/bootstrap-lib.sh honour a pre-set XDG_CONFIG_HOME / XDG_STATE_HOME / XDG_CACHE_HOME /
# XDG_DATA_HOME / ZDOTDIR — while a fourth repo had already fixed it and could not tell the
# others. These drive the real script against a FAKE repo whose bootstrap is a stub, so the
# assertions are about the gate rather than about any distro.
hdr "hermetic links gate (check-links.sh)"
_cl_root="$SANDBOX/check-links"
_cl_sh="$HERE/scripts/check-links.sh"

# A stub installer that builds the graph Core's loader expects, in whatever HOME it is
# handed. `env_seen` records the environment the child ACTUALLY got, which is how the XDG
# scrub is asserted rather than assumed.
_cl_repo() { # _cl_repo [extra-lines-for-the-stub]
  # The payload lives under core/ at the paths the gate now VERIFIES each link resolves to,
  # so the fake repo is shaped like a real vendored one rather than merely link-complete.
  rm -rf "$_cl_root"
  mkdir -p "$_cl_root/core/zsh" "$_cl_root/core/nvim" "$_cl_root/core/starship" \
    "$_cl_root/core/lazygit" "$_cl_root/core/tmux" "$_cl_root/core/vim" "$_cl_root/core/git"
  : >"$_cl_root/core/zsh/loader.zsh"; : >"$_cl_root/core/starship/starship.toml"
  : >"$_cl_root/core/lazygit/config.yml"; : >"$_cl_root/core/tmux/tmux.conf"
  : >"$_cl_root/core/vim/vimrc"; : >"$_cl_root/core/git/gitconfig"
  : >"$_cl_root/core/tmux/role.conf"
  cat >"$_cl_root/bootstrap.sh" <<STUB
#!/usr/bin/env bash
# A stand-in for an OS repo's installer: same links, none of the distro.
set -u
env | grep -E '^(XDG_CONFIG_HOME|XDG_DATA_HOME|XDG_STATE_HOME|XDG_CACHE_HOME|ZDOTDIR)=' | sort >"\$HOME/.env_seen" || true
P="$_cl_root/core"
mkdir -p "\$HOME/.config/zsh" "\$HOME/.config/lazygit" "\$HOME/.config/tmux" "\$HOME/.config/sesh"
ln -sf "\$P/zsh/loader.zsh"        "\$HOME/.config/zsh/loader.zsh"
ln -sf "\$P/starship/starship.toml" "\$HOME/.config/starship.toml"
ln -sf "\$P/lazygit/config.yml"    "\$HOME/.config/lazygit/config.yml"
ln -sf "\$P/nvim"                  "\$HOME/.config/nvim"
ln -sf "\$P/tmux/tmux.conf"        "\$HOME/.config/tmux/tmux.conf"
ln -sf "\$P/vim/vimrc"             "\$HOME/.vimrc"
ln -sf "\$P/git/gitconfig"         "\$HOME/.gitconfig"
cp "\$P/starship/starship.toml" "\$HOME/.config/sesh/sesh.toml"
printf '# dotfiles-managed v4\nsource "\$HOME/.config/zsh/loader.zsh"\n' >"\$HOME/.zshrc"
${1:-}
STUB
  chmod +x "$_cl_root/bootstrap.sh"
}

_cl_repo
if _cl_out="$(cd "$_cl_root" && "$_cl_sh" 2>&1)"; then
  pass "links: a correct graph passes"
else
  fail "links: the correct graph did not pass: $_cl_out"
fi

# THE #852 REGRESSION, and the reason this script exists. Export all five; the child must
# see NONE of them, or a developer's real config tree is what gets wired.
_cl_repo 'cp "$HOME/.env_seen" '"$_cl_root/env_seen"
if (cd "$_cl_root" && XDG_CONFIG_HOME=/tmp/decoy-cfg XDG_DATA_HOME=/tmp/decoy-data \
  XDG_STATE_HOME=/tmp/decoy-state XDG_CACHE_HOME=/tmp/decoy-cache ZDOTDIR=/tmp/decoy-zsh \
  "$_cl_sh" >/dev/null 2>&1) && [[ ! -s "$_cl_root/env_seen" ]]; then
  pass "links: XDG_CONFIG_HOME/DATA/STATE/CACHE and ZDOTDIR are scrubbed from bootstrap's environment"
else
  fail "links: the XDG scrub leaked: $(cat "$_cl_root/env_seen" 2>/dev/null)"
fi
# The unrelated environment must survive the scrub — callers pass BLIB_SU=true through it.
_cl_repo 'printf "%s" "${BLIB_SU:-unset}" >'"$_cl_root/su_seen"
(cd "$_cl_root" && BLIB_SU=true "$_cl_sh" >/dev/null 2>&1)
if [[ "$(cat "$_cl_root/su_seen" 2>/dev/null)" == true ]]; then
  pass "links: the scrub removes the five and nothing else (BLIB_SU still reaches bootstrap)"
else
  fail "links: the scrub ate an unrelated variable"
fi

# A MISSING LINK IS 2, NOT 1: the caller can tell "the graph is wrong" from "it would not run".
_cl_repo
(cd "$_cl_root" && "$_cl_sh" --require .config/nope >/dev/null 2>&1); rc=$?
if ((rc == 2)); then pass "links: a required path that is not linked exits 2"; else fail "links: missing --require path exited $rc, want 2"; fi

# THE TARGET IS THE POINT. Every link present and resolvable, one of them wired to the
# WRONG Core file — the shape `-L` plus `-e` cannot see, and a shell configured wrongly.
_cl_repo 'ln -sfn "$P/tmux/tmux.conf" "$HOME/.config/starship.toml"'
(cd "$_cl_root" && "$_cl_sh" >/dev/null 2>&1); rc=$?
if ((rc == 2)); then pass "links: a link resolving to the WRONG Core file is caught"; else fail "links: starship.toml wired to tmux.conf passed (rc=$rc)"; fi
# …while a caller's --require path keeps existence-only semantics: Core does not know what
# a Role layer's paths should point at, and must not invent an expectation for them.
_cl_repo 'ln -sfn "$P/tmux/role.conf" "$HOME/.config/role.conf"'
if (cd "$_cl_root" && "$_cl_sh" --require .config/role.conf >/dev/null 2>&1); then
  pass "links: a --require path is checked for existence, not against a Core target"
else
  fail "links: a caller-supplied --require path was held to a Core target"
fi

# AN OPTION MUST NOT EAT THE NEXT OPTION. `--require --keep` used to take `--keep` as a
# required path and report graph drift (exit 2) for what is a typo.
_cl_repo
(cd "$_cl_root" && "$_cl_sh" --require --keep >/dev/null 2>&1); rc=$?
if ((rc == 1)); then pass "links: --require --keep is a usage error, not a graph failure"; else fail "links: --require swallowed --keep (rc=$rc)"; fi
(cd "$_cl_root" && "$_cl_sh" --repo --help >/dev/null 2>&1); rc=$?
if ((rc == 1)); then pass "links: --repo --help is a usage error, not a cd into '--help'"; else fail "links: --repo swallowed --help (rc=$rc)"; fi

# THE SEED IS A COPY. A symlinked sesh.toml means an edit lands in the vendored tree.
_cl_repo 'ln -sfn "$P/starship/starship.toml" "$HOME/.config/sesh/sesh.toml"'
(cd "$_cl_root" && "$_cl_sh" >/dev/null 2>&1); rc=$?
if ((rc == 2)); then pass "links: a SYMLINKED seed file is caught (it must be a copy)"; else fail "links: a symlinked seed exited $rc, want 2"; fi

# THE GREP REGRESSION the old recipes carried: a commented-out source line passed.
_cl_repo 'printf "# dotfiles-managed v4\n# source \"$HOME/.config/zsh/loader.zsh\"\n" >"$HOME/.zshrc"'
(cd "$_cl_root" && "$_cl_sh" >/dev/null 2>&1); rc=$?
if ((rc == 2)); then pass "links: a COMMENTED-OUT loader line does not satisfy the .zshrc assertion"; else fail "links: the commented-out loader line passed (rc=$rc)"; fi
# …and its unescaped dot: loaderXzsh must not match loader.zsh.
_cl_repo 'printf "# dotfiles-managed v4\nsource \"$HOME/.config/zsh/loaderXzsh\"\n" >"$HOME/.zshrc"'
(cd "$_cl_root" && "$_cl_sh" >/dev/null 2>&1); rc=$?
if ((rc == 2)); then pass "links: loaderXzsh does not match loader.zsh (the dot is escaped)"; else fail "links: an unescaped dot still matches (rc=$rc)"; fi

# THE OPERAND MUST BE THE LOADER, not merely end in its name. An undelimited
# `.*loader\.zsh` accepted both of these while the real loader was never sourced.
_cl_repo 'printf "# dotfiles-managed v4\nsource \"$HOME/.config/zsh/notloader.zsh\"\n" >"$HOME/.zshrc"'
(cd "$_cl_root" && "$_cl_sh" >/dev/null 2>&1); rc=$?
if ((rc == 2)); then pass "links: sourcing notloader.zsh does not satisfy the loader assertion"; else fail "links: notloader.zsh passed (rc=$rc)"; fi
_cl_repo 'printf "# dotfiles-managed v4\nsource \"$HOME/.config/zsh/loader.zsh.bak\"\n" >"$HOME/.zshrc"'
(cd "$_cl_root" && "$_cl_sh" >/dev/null 2>&1); rc=$?
if ((rc == 2)); then pass "links: sourcing loader.zsh.bak does not satisfy it either"; else fail "links: loader.zsh.bak passed (rc=$rc)"; fi
# The `.` synonym and a trailing comment are both legitimate, and must still pass.
_cl_repo 'printf "# dotfiles-managed v4\n. \"$HOME/.config/zsh/loader.zsh\"  # the Core chain\n" >"$HOME/.zshrc"'
if (cd "$_cl_root" && "$_cl_sh" >/dev/null 2>&1); then
  pass "links: the \`.\` synonym with a trailing comment is accepted"
else
  fail "links: a legitimate \`.\` source line was rejected"
fi

# A DANGLING loader.zsh is the rename-upstream shape: the link exists, the target does not.
_cl_repo 'rm -f "$P/zsh/loader.zsh"'
(cd "$_cl_root" && "$_cl_sh" >/dev/null 2>&1); rc=$?
if ((rc == 2)); then pass "links: a dangling loader.zsh symlink is caught"; else fail "links: dangling loader.zsh exited $rc, want 2"; fi

# COULD-NOT-RUN IS 1, and bootstrap's own output is what diagnoses it.
_cl_repo
printf '#!/usr/bin/env bash\necho "provisioner exploded" >&2\nexit 7\n' >"$_cl_root/bootstrap.sh"
chmod +x "$_cl_root/bootstrap.sh"
_cl_out="$( (cd "$_cl_root" && "$_cl_sh" 2>&1) )"; rc=$?
if ((rc == 1)) && [[ "$_cl_out" == *"provisioner exploded"* ]]; then
  pass "links: a failing bootstrap exits 1 and prints its output"
else
  fail "links: failing bootstrap (rc=$rc): $_cl_out"
fi
_cl_repo
(cd "$_cl_root" && "$_cl_sh" --require >/dev/null 2>&1); rc=$?
if ((rc == 1)); then pass "links: --require with no value is a usage error, not an empty requirement"; else fail "links: --require with no value exited $rc, want 1"; fi
(cd /tmp && "$_cl_sh" --repo /nonexistent-repo-dir >/dev/null 2>&1); rc=$?
if ((rc == 1)); then pass "links: a --repo that is not a directory exits 1"; else fail "links: bad --repo exited $rc, want 1"; fi

# THE THROWAWAY HOME IS REMOVED — including on the failure paths, via the trap. Given its
# OWN TMPDIR under the sandbox and asserted EMPTY: counting `tmp.*` entries in the shared
# system temp dir would race with every other process on the box (a false failure or a
# masked leak, depending on the timing) and would write outside the suite sandbox, which
# this file's hermetic invariant forbids.
_cl_repo
_cl_tmpdir="$SANDBOX/check-links-tmp"; rm -rf "$_cl_tmpdir"; mkdir -p "$_cl_tmpdir"
(cd "$_cl_root" && TMPDIR="$_cl_tmpdir" "$_cl_sh" --require .config/nope >/dev/null 2>&1)
if [[ -z "$(ls -A "$_cl_tmpdir" 2>/dev/null)" ]]; then
  pass "links: the throwaway HOME is cleaned up even when the assertions fail"
else
  fail "links: a failing run leaked its throwaway HOME: $(ls -A "$_cl_tmpdir")"
fi
# …and the temp dir is made with a TEMPLATE, or the macOS lane never gets past it: BSD
# mktemp requires one (PORTABILITY.md). A run under a TMPDIR that exists proves the
# template resolves there rather than asserting the string.
_cl_repo
rm -rf "$_cl_tmpdir"; mkdir -p "$_cl_tmpdir"
if (cd "$_cl_root" && TMPDIR="$_cl_tmpdir" "$_cl_sh" >/dev/null 2>&1); then
  pass "links: the throwaway HOME honours TMPDIR (portable mktemp template)"
else
  fail "links: the run under a custom TMPDIR failed"
fi
if grep -qE 'mktemp -d "\$\{TMPDIR:-/tmp\}/[^"]*X{6}"' "$_cl_sh"; then
  pass "links: mktemp is called with a template (BSD requires one)"
else
  fail "links: mktemp lost its template — the macOS lane would exit 1 before bootstrap"
fi
# THE DEFAULT INVOCATION ON BASH 3.2. `set -u` there treats an empty array as unset, so
# `${#REQUIRE[@]}` with neither option passed aborts before any check runs — the macOS
# lane, and not reproducible here (this box's bash is 5.x, and the runner's `env bash` is
# not 3.2 either). Pinned at the source, the way the mktemp template above is.
# Matched on the GUARDED IDIOM rather than one exact line: the first version of this pin
# spelled the whole assignment and went red the moment the append was restructured, which
# is a test asserting its own phrasing instead of the property.
if grep -q '${REQUIRE\[@\]+"${REQUIRE\[@\]}"}' "$_cl_sh" &&
  grep -q '${SEED\[@\]+"${SEED\[@\]}"}' "$_cl_sh" &&
  ! grep -qE '\(\(\$\{#(REQUIRE|SEED)\[@\]\}\)\)' "$_cl_sh"; then
  pass "links: the optional arrays use the guarded + expansion (bash 3.2 aborts on an empty one)"
else
  fail "links: an empty-array length expansion is back — the default invocation dies on macOS bash 3.2"
fi

# A DANGLING link that is NOT loader.zsh: the copied recipes only ever resolved that one,
# so a renamed Core file behind any other link read as a healthy graph.
_cl_repo 'rm -f "$P/starship/starship.toml"'
(cd "$_cl_root" && "$_cl_sh" >/dev/null 2>&1); rc=$?
if ((rc == 2)); then pass "links: a dangling link other than loader.zsh is caught too"; else fail "links: dangling starship.toml exited $rc, want 2"; fi

# --help IS A HEREDOC, not a line range over this file: the range form had already started
# printing `set -uo pipefail` as documentation, and drifts on any header edit.
_cl_out="$("$_cl_sh" --help 2>&1)"
if [[ "$_cl_out" == *"--require PATH"* && "$_cl_out" == *"Exit codes:"* && "$_cl_out" != *"set -uo pipefail"* && "$_cl_out" != *"#!/usr/bin/env"* ]]; then
  pass "links: --help prints the usage block and no implementation lines"
else
  fail "links: --help leaked implementation or lost its options: $_cl_out"
fi

# `--bootstrap` IS RELATIVE TO THE REPO, as documented: a bare name must not be looked up
# on PATH. Proven by shadowing it — a `bootstrap.sh` earlier in PATH that writes a marker
# and builds nothing. If PATH won, the run would fail AND drop the marker.
_cl_repo
mkdir -p "$_cl_root/pathbin"
printf '#!/usr/bin/env bash\ntouch "%s/PATH_WON"\nexit 0\n' "$_cl_root" >"$_cl_root/pathbin/bootstrap.sh"
chmod +x "$_cl_root/pathbin/bootstrap.sh"
if (cd "$_cl_root" && PATH="$_cl_root/pathbin:$PATH" "$_cl_sh" --bootstrap bootstrap.sh >/dev/null 2>&1) &&
  [[ ! -e "$_cl_root/PATH_WON" ]]; then
  pass "links: a slash-free --bootstrap resolves in the repo, not through PATH"
else
  fail "links: --bootstrap bootstrap.sh was resolved through PATH"
fi

# `source` MUST BE THE COMMAND. `echo source …/loader.zsh` mentions it and sources nothing;
# the earlier `^[^#]*source` form accepted exactly that.
_cl_repo 'printf "# dotfiles-managed v4\necho source \"$HOME/.config/zsh/loader.zsh\"\n" >"$HOME/.zshrc"'
(cd "$_cl_root" && "$_cl_sh" >/dev/null 2>&1); rc=$?
if ((rc == 2)); then pass "links: \`echo source …loader.zsh\` does not satisfy the assertion"; else fail "links: a mentioned-but-not-run source passed (rc=$rc)"; fi
# …and the real managed file, whose source line is INDENTED inside blib_write_zshrc_loader's
# `if [[ -r … ]]` guard, must still pass.
_cl_repo 'printf "# dotfiles-managed v4\nif [[ -r \"$HOME/.config/zsh/loader.zsh\" ]]; then\n  source \"$HOME/.config/zsh/loader.zsh\"\nfi\n" >"$HOME/.zshrc"'
if (cd "$_cl_root" && "$_cl_sh" >/dev/null 2>&1); then
  pass "links: the real managed .zshrc shape (indented source inside an if) still passes"
else
  fail "links: the indented source line in the managed .zshrc was rejected"
fi

# THE SIGNAL HANDLERS EXIT, rather than cleaning up and letting the script run on against a
# directory it just removed (audit-core.sh makes the same distinction).
if grep -q "trap _cl_cleanup EXIT$" "$_cl_sh" && grep -q "trap 'exit 130' INT" "$_cl_sh" && grep -q "trap 'exit 143' TERM" "$_cl_sh"; then
  pass "links: INT/TERM exit 130/143 and EXIT does the cleanup"
else
  fail "links: the signal handlers are cleanup-only again"
fi

# IT IS VENDORED, or the six repos that will call it as core/scripts/check-links.sh get
# nothing on the next sync — the whole point of moving it here.
if grep -qE '^scripts/check-links\.sh([[:space:]]|$)' "$HERE/core.vendor"; then
  pass "links: scripts/check-links.sh is in core.vendor"
else
  fail "links: scripts/check-links.sh is missing from core.vendor — it would not reach any OS repo"
fi
rm -rf "$_cl_root"
unset _fv_root _fv_all _fv_mk _fv_out rc row tbl want have
unset -f _fv_reset _fv_repo _fv_run _fv_ci _fv_wf _fv_wf_raw _fv_suite _fv_floor

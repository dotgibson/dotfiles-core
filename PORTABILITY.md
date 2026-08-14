# PORTABILITY.md — what "portable" means in Core, concretely

Core is authored once here and vendored into eight OS repos. A file in `core.manifest`
runs on **macOS (bash 3.2, BSD userland), glibc Linux, musl/busybox Alpine, and rolling
Arch** — so "portable" is not a style preference here, it is the contract that keeps one
tree correct on every machine.

`CONTRIBUTING.md` answers _is it Core?_ This answers _how do I write Core that survives
the fan-out?_ Both were previously only in scattered code comments, which is exactly how
`maint/dotfiles-maint.sh` and `tmux/scripts/tmux-cheat.sh` ended up carrying
`/opt/homebrew` paths into eight repos where seven of them do not exist.

When a rule here drifts from `README.md` or `CONTRIBUTING.md`, those win — fix this.

## 1. The floor is bash 3.2

macOS still ships **bash 3.2** (2007), and `make audit` runs there. Every bash script in
this repo — including the dev tooling in `scripts/` — must parse and run on it.

**Banned outright:**

| Feature | Version | Use instead |
| --- | --- | --- |
| `declare -A` / associative arrays | bash 4.0 | parallel arrays, or a `case` |
| `mapfile` / `readarray` | bash 4.0 | `while IFS= read -r … do … done < <(…)` |
| `${var^^}` / `${var,,}` | bash 4.0 | `tr '[:lower:]' '[:upper:]'` |
| `wait -n` | bash 4.3 | batched `wait` over collected PIDs |
| `&>>`, `\|&` | bash 4.0 | `>>file 2>&1`, `2>&1 \|` |

Live examples of the workaround, all load-bearing: `scripts/audit-core.sh` uses a read
loop rather than `mapfile` for the manifest scan; `scripts/sync-core.sh` uses batched
waits (not `wait -n`) for its parallel prefetch; `lib/bootstrap-lib.sh` and `lib/ux.sh`
both state the constraint at the top.

`set -u` on bash 3.2 also treats an **empty array expansion as unset**, which is why you
will see `"${arr[@]+"${arr[@]}"}"` rather than a bare `"${arr[@]}"`.

## 2. Coreutils are not GNU coreutils

macOS ships BSD tools; Alpine ships busybox. A flag that works on your machine is not
evidence.

**Banned, with the portable form:**

| Non-portable | Why | Portable form |
| --- | --- | --- |
| `sed -i` | BSD requires an arg to `-i` | write to `$(mktemp …)` then `mv` |
| `readlink -f` | not on BSD | a `cd`/`pwd -P` helper |
| `stat -c` / `stat -f` | inverted between GNU and BSD | avoid; use `[[ -nt ]]`, `wc -c` |
| `date -r`, `date -d` | different meanings | `${EPOCHSECONDS:-$(date +%s)}` |
| `grep -P` | not in busybox | `grep -E` |
| `sort -V` | not in busybox | `sort` on zero-padded fields |
| `mktemp` with no template | BSD requires one | `mktemp "prefix.XXXXXX"` |
| `xargs -P` | busybox may reject it | offer a serial fallback knob |

`grep -q`, `grep -E`, `sort -u`, `cut -c`, `tr -d` are safe everywhere and used freely.

Two shipped examples worth copying: `zsh/20-aliases.zsh` probes `diff --color=auto` once
and caches the answer rather than assuming GNU diff (busybox and BSD diff lack it);
`maint/dotfiles-maint.sh` defines `_to()` to use GNU `timeout`, else macOS `gtimeout`,
else run unbounded, and separately treats **both** rc 124 (GNU) and rc ≥128 (busybox
signals its SIGTERM as 143) as "the probe never answered".

## 3. Reach OS capability through a shim, never a path

**This is the rule the boundary gate enforces.** `scripts/audit-core.sh` §5c rejects
`/opt/homebrew`, `/home/linuxbrew`, `/usr/local/Cellar`, `/Library/` and `/mnt/c/` in any
manifested Core file. Its scope is derived from `core.manifest`, so adding a file to the
manifest puts it under the gate automatically.

The pattern: **one verb, N backends, chosen by probing for a capability — not by
branching on an OS name.**

| Capability | Shim | Selects by |
| --- | --- | --- |
| clipboard | `bin/clip`, `bin/clip-paste` | `$WSL_DISTRO_NAME` → `pbcopy` → `wl-copy` → `xclip` → `xsel` |
| scheduler | `_maint_scheduler` (`zsh/55-maint.zsh`) | launchd / `/run/systemd/system` / `crontab` |
| package manager | `_pkgup_mgr` (`zsh/60-update.zsh`) | `command -v` over seven managers |
| privilege | `_pkgup_priv`, `_blib_priv` | `sudo` → `doas` → bare |
| timeout | `_to` (`maint/dotfiles-maint.sh`) | `timeout` → `gtimeout` → unbounded |
| binary-name drift | `$FD_BIN`, `$BAT_BIN` (`zsh/00-tools.zsh`) | `fd`/`fdfind`, `bat`/`batcat` |
| layer seam | numbered bands (`zsh/loader.zsh`) | file number, see `VENDORING.md` |

`command -v` is the workhorse. Prefer it to `uname`/`$OSTYPE`: probing for the tool you
are about to run is both more precise and correct on machines the OS test never
anticipated.

**When the capability genuinely cannot be probed**, push the knowledge outward rather
than hardcoding it:

- to the **OS layer** — `os/<os>.zsh` (band 70–84) is where a real OS path belongs;
- to **install time** — `maint-install` captures the live `$PATH` and writes it into the
  scheduler unit, so the runner needs no prefix of its own;
- to an **env var the environment already provides** — `tmux-cheat.sh` reads
  `$HOMEBREW_PREFIX` (exported by `brew shellenv`) and falls back to `brew --prefix`.

If none of those work, degrade **visibly**: add nothing and let the feature fall back, as
`tmux-cheat.sh` does to its pager. A wrong absolute path is a silent lie on seven
machines; a missing optional tool is a visible, local degradation.

### The two documented exceptions

Both are excepted **in writing**, at the gate, so they cannot be mistaken for drift:

1. **`zsh/55-maint.zsh`** — the scheduler _control surface_. Its launchd arm legitimately
   writes `~/Library/LaunchAgents` and embeds a plist; its systemd arm embeds a unit. It
   switches on `_maint_scheduler`, which is the correct cross-OS shape, so the OS-specific
   text is the payload rather than an assumption. Skipped explicitly in §5c.
2. **`zsh/60-update.zsh`** — a seven-package-manager driver, i.e. the canonical example of
   an _OS-layer_ concern, living in Core on purpose. See `ARCHITECTURE.md`.

`*.example` files are also skipped: they are user-edited illustrations, not live config.

## 4. `have()` is defined four times, deliberately

`_have` (`zsh/00-tools.zsh`), `ux_have` (`lib/ux.sh`), `have`
(`maint/dotfiles-maint.sh`), and `have` (`.claude/hooks/session-start.sh`) are the same
one-liner under four names. That is **intentional, not drift**: a zsh module, a sourced
bash library, a standalone runner, and a repo-meta hook have no shared ancestor to source
from, and giving them one would create a load-order dependency where none exists today.

If you add a fifth context, define it locally too. Do not invent a shared `lib/have.sh`.

## 5. Before you push

```bash
make audit
```

That is the whole gate. Two things worth knowing about it:

- A missing linter **skips** rather than fails, and the summary then labels the run
  `PARTIAL`. A local green with skips is not the same as CI green — read the summary.
- The boundary gate (§5c) is the one that catches layering mistakes. It is cheap and
  unconditional, so a narrowed `--scope` cannot skip it.

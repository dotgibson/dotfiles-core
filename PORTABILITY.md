# PORTABILITY.md — what "portable" means in Core, concretely

Core is authored once here and vendored into nine OS repos. A file in `core.manifest`
runs on **macOS (bash 3.2, BSD userland), glibc Linux, musl/busybox Alpine, and rolling
Arch** — so "portable" is not a style preference here, it is the contract that keeps one
tree correct on every machine.

`CONTRIBUTING.md` answers _is it Core?_ This answers _how do I write Core that survives
the fan-out?_ Both were previously only in scattered code comments, which is exactly how
`maint/dotfiles-maint.sh` and `tmux/scripts/tmux-cheat.sh` ended up carrying
`/opt/homebrew` paths into nine repos where eight of them do not exist.

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
| `date -r`, `date -d` | different meanings | for _now_: `${EPOCHSECONDS:-$(date +%s)}` |
| `grep -P` | not in busybox | `grep -E` |
| `sort -V` | not in busybox | `sort` on zero-padded fields |
| `mktemp` with no template | BSD requires one | `mktemp "prefix.XXXXXX"` |
| `xargs -P` | busybox may reject it | branch to plain `xargs` when serial |

`${EPOCHSECONDS:-$(date +%s)}` only covers **now** — it is not a general `date`
replacement. Reading a file's mtime or parsing a supplied date has no portable one-liner:
compare files with `[[ -nt ]]` instead of reading timestamps, and keep any date arithmetic
in epoch seconds you produced yourself.

`grep -q`, `grep -E`, `sort -u`, `cut -c`, `tr -d` are safe everywhere and used freely.

A knob is only a fallback if the code actually takes a different path: `pullall`
documents `PULLALL_JOBS=1` as the busybox escape hatch but still passes `-P "$jobs"`
either way (`zsh/30-functions.zsh:766-768`), so on the one platform it exists for it
fails exactly as before. Branch around the flag, do not just change its value.

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

Nothing is exempt by syntax — **not even comments**. Comment-stripping was tried and
removed: `#` is a comment in shell and TOML but the _length operator_ in Lua; a delimiter
inside a string is code; a line inside a heredoc or a Lua long-bracket string is runtime
data however it starts. Every fix uncovered the next, because doing it correctly needs a
parser for all five grammars the gate now scans.

So the rule is flat: **a manifested Core file must not contain an OS-absolute path
anywhere, prose included.** Name the prefix instead of spelling it — write "the Homebrew
prefix", not the literal. That costs one wording choice in a comment and buys a gate with
no hiding places.

The pattern: **one verb, N backends, chosen by probing for a capability — not by
branching on an OS name.**

| Capability | Shim | Selects by |
| --- | --- | --- |
| clipboard | `bin/clip`, `bin/clip-paste` | `$WSL_DISTRO_NAME` → `pbcopy` → `wl-copy` → `xclip` → `xsel` |
| scheduler | `_maint_scheduler` (`zsh/55-maint.zsh`) | the OS layer's declared `SCHEDULER`, else launchd / `/run/systemd/system` / `crontab` |
| scheduler **unit dir** | `_maint_unit_file` (`zsh/55-maint.zsh`) | the OS layer's declared `SCHEDULER_UNIT_DIR`, and nothing else |
| package manager | `_pkgup_mgr` (`zsh/60-update.zsh`) | `command -v` over seven managers |
| package-manager **verbs** | `_pkgup_verb` (`zsh/60-update.zsh`) | the OS layer's `os.capabilities` declaration, and nothing else |
| privilege | `_pkgup_priv`, `_blib_priv` | `sudo` → `doas` → bare |
| timeout | `_to` (`maint/dotfiles-maint.sh`) | `timeout` → `gtimeout` → unbounded |
| binary-name drift | `$FD_BIN`, `$BAT_BIN` (`zsh/00-tools.zsh`) | `fd`/`fdfind`, `bat`/`batcat` |
| layer seam | numbered bands (`zsh/loader.zsh`) | file number, see `VENDORING.md` |
| WSL host | `_core_is_wsl` (`zsh/00-tools.zsh`), `blib_is_wsl` (`lib/bootstrap-lib.sh`) | `$WSL_DISTRO_NAME` → the `microsoft`/`wsl` marker in the kernel version file |

`command -v` is the workhorse. Prefer it to `uname`/`$OSTYPE`: probing for the tool you
are about to run is both more precise and correct on machines the OS test never
anticipated.

### The env-fact exception

`command -v` answers _can I run X?_. It cannot answer _what am I running inside?_, and two
shims need exactly that: `bin/clip` (under WSL the clipboard routes to the Windows binary —
a host fact, not a tool fact) and `_core_is_wsl` (the interop reach-arounds an OS layer gates
on). Both are legitimate, and the exception is narrow and named:

- read an **env var the environment already sets** — `$WSL_DISTRO_NAME`, set by WSL itself;
- fall back to a **file the kernel wrote** — the `microsoft`/`wsl` marker in `/proc/version`,
  for a login that never inherited the env (`su -`, a systemd unit, `ssh host cmd`);
- **never** branch on `uname` or `$OSTYPE`.

Both carry a `*_PROC_VERSION` test seam (`CORE_PROC_VERSION`, `CLIP_PROC_VERSION`), and that
is not decoration: without it the "this box is not WSL" case cannot be asserted on a WSL
development host, and "this box is WSL" cannot be asserted on a CI runner — the suite would
prove one direction on each machine and both on neither.

`_core_is_wsl` is also the **only** WSL predicate a zsh layer should use. Six OS repos each
re-derived it before #449; an OS layer that needs the answer calls Core's, and the reusable
`lint` workflow fails one that grows its own back.

**When the capability genuinely cannot be probed**, push the knowledge outward rather
than hardcoding it:

- to the **OS layer's declaration** — `os/<os>.capabilities` is the first thing to reach
  for when what differs is a _verb_ rather than a path. It is `KEY=value` data, read and
  never sourced, and Core reads it back through `_core_cap`. `up` resolves every package
  -manager command this way (#664);
- to the **OS layer** — `os/<os>.zsh` (band 70–84) is where a real OS path belongs;
- to **install time** — `maint-install` captures the live `$PATH` and writes it into the
  scheduler unit, so the runner needs no prefix of its own;
- to an **env var the environment already provides** — `tmux-cheat.sh` reads
  `$HOMEBREW_PREFIX` (exported by `brew shellenv`) and falls back to `brew --prefix`.

If none of those work, degrade **visibly**: add nothing and let the feature fall back, as
`tmux-cheat.sh` does to its pager. A wrong absolute path is a silent lie on seven
machines; a missing optional tool is a visible, local degradation.

### The exceptions, and why there are none left

**§5c has no per-file exception.** It had one, for `zsh/55-maint.zsh`: the scheduler's
built-in unit directory named macOS's LaunchAgents path, the last OS-absolute path in Core,
and only those lines were exempt. #665 cut that from six call sites down to one block by
making the scheduler and its directory **declared** values (`SCHEDULER`,
`SCHEDULER_UNIT_DIR`); #763 deleted the block once the fleet had re-bootstrapped onto those
declarations, and the exemption went with it. Do not add another — an exception at this gate
is a standing invitation for a second literal to ride along beside the sanctioned one.

The plist and unit **templates** stay in that file and were never the exception: they are
portable text parameterised by paths, selected by `_maint_scheduler`, and duplicating a
systemd unit across seven repos is the #449 drift this document exists to prevent.

**`zsh/60-update.zsh` used to be listed here as a second exception**, and the distinction
mattered: it was excepted _architecturally, not at the gate_. It never needed a §5c
exclusion — it names no OS-absolute path, and would have failed §5c like anything else if
it did — but it was a seven-package-manager driver, which is the canonical OS-layer
concern, kept in Core so `up` is one verb everywhere.

Since #664 it is a **dispatcher**: the verb stays, and what it runs is resolved through
`_pkgup_verb` from the OS layer's `os.capabilities` declaration. That is the pattern this
document already asks for — one verb, N backends — with the backends pushed outward rather
than branched on inline. Since #763 there is nothing behind the dispatcher: an undeclared
box resolves no verb and every caller says so in its own voice, rather than running a row
Core kept for whichever manager happened to be on `PATH`. See `ARCHITECTURE.md` for why the
authoring and the deletion had to be two separate changes.

`*.example` files are skipped: they are user-edited illustrations, not live config.

## 4. The `have()` probe is redefined per context, deliberately

`command -v "$1" >/dev/null 2>&1` appears under several names — `_have`
(`zsh/00-tools.zsh`), `_core_have` (`zsh/05-ui.zsh`), `ux_have` (`lib/ux.sh`), `have`
(`scripts/lib/common.sh`), `have` (`maint/dotfiles-maint.sh`), `have`
(`.claude/hooks/session-start.sh`).

That is **intentional, not drift**. Each lives in a different loading context — an
interactive zsh module, a sourced bash library, a gate-script library, a standalone
unattended runner, a repo-meta hook — and they have no shared ancestor to source from.
Giving them one would create a load-order dependency where none exists today, in a tree
whose whole load story is ordering.

Define it locally in a new context too. Do not invent a shared `lib/have.sh`.

## 5. `HAVE_*` is a declared surface, not a convention

`zsh/00-tools.zsh` probes the modern-CLI stack at band 00. Every probe records a ledger
row; only some also set a flag.

- **`_CORE_PROBED`** — the authoritative ledger, and the one that is **always** written. A
  zsh associative array, one row per `_have` call, `1` seen / `0` looked-and-absent.
  `core-doctor` reads this and nothing else; so do `_core_doctor_stale` and
  `_core_doctor_unwired` (`zsh/30-functions.zsh`). The `0` rows matter: without them "Core
  probed this and said no" is indistinguishable from "Core does not probe this tool".

  Rows come in two kinds. The **canonical** rows are the ones the doctor keys on and the
  ones you should read — `fd`, `bat`, `git-absorb`. Alongside them sit **auxiliary** rows
  left by the alternate-name ladders: probing `fd` and then `fdfind` writes both, and
  `00-tools.zsh` afterwards forces `_CORE_PROBED[fd]=1` from `$FD_BIN` so the canonical row
  carries the real answer rather than the first ladder rung's `0`. Read the canonical name;
  treat `fdfind`/`batcat` rows as the implementation detail they are.
- **`HAVE_<TOOL>`** — a convenience flag, and a **conditional** one: it exists only where
  something actually gates on it. Fourteen probes deliberately set no flag at all (#694),
  so the presence of a ledger row implies nothing about a flag. The name is `HAVE_` plus
  the canonical tool name uppercased with `-` → `_` (`git-absorb` → `HAVE_GIT_ABSORB`).
  Set, never `export`ed: these are shell parameters visible to the layers sourced after
  band 00, not environment variables, so they never reach a child process — which is why
  only code **sourced into the same shell** can read one.

**A flag only exists where band-00 detection ran.** An interactive zsh through
`zsh/loader.zsh` has them; a script, a non-interactive shell, and anything sourced before
band 00 do not.

Write `${HAVE_X:-}` rather than a bare `$HAVE_X`, but be clear about what that buys: it is
**`set -u` safety only**. It does not let you tell the two absences apart, because both
produce the empty string — "Core probed and did not find the tool" and "band 00 never ran
here" read identically. For an OS or role fragment at band 70–94 that distinction is moot:
the loader guarantees band 00 ran first, so empty means absent and the guard is exact. Read
a flag anywhere else and you cannot rely on it. If you genuinely need to distinguish, the
ledger is the only thing that can: `(( ${+_CORE_PROBED} ))` is false when detection never
ran, and `$_CORE_PROBED[<tool>]` is `0` when it ran and found nothing.

### What downstream may use

| Flag | Tool | Read by |
| --- | --- | --- |
| `HAVE_ATUIN` | atuin | `dotfiles-Alpine`, `dotfiles-Debian`, `dotfiles-Fedora` — `os/*.zsh`, to enable the daemon only where Core wired atuin |

**That is the whole supported surface, and the short list is the point.** It starts at
exactly what the fleet reads today rather than at "all of them", because widening a
declared surface is a one-line PR and narrowing one is a breaking change. An OS or role
layer that needs another flag adds its row here in the same change that reads it — that is
the ask, not a workaround for it.

Every other flag `00-tools.zsh` sets is **internal to Core**: it gates an alias, a
function, or an init in bands 00–69, and Core may rename or drop it in any release.

### Role and OS layers own their own `HAVE_*` names

`dotfiles-Offense` and `dotfiles-Defense` each define ~20 flags of their own
(`HAVE_NXC`, `HAVE_ZEEK`, …) in the same namespace, and that is fine: a layer that
**sets** a flag before reading it owns it outright. The contract is only about **reading a
flag you did not set** — that is the one case where a Core rename breaks you silently, and
the only case the gate looks at.

Keep re-probing to a minimum, though. `dotfiles-Defense` sets `HAVE_JQ` with its own
`_have jq`, which is legal and self-contained, but it means two layers assign one name;
prefer a distinct name when the tool is not genuinely yours.

### The gate

`scripts/audit-core.sh` **§5j** enforces the table above in three directions, the same
both-ways shape `core.manifest` has in §1:

1. every flag declared here is one `zsh/00-tools.zsh` actually sets — so a Core rename or
   removal cannot leave the declaration lying;
2. every Core-namespace flag an OS or role repo **reads without setting** is declared here
   — so an OS-repo author finds out at the gate, not at a broken prompt six months later;
3. every flag `00-tools.zsh` sets has a reader — a `zsh/*.zsh` module, or this table. #694
   removed fourteen that had neither, and this is what stops them accumulating again.
   "Reader" means a **zsh module**, not any file mentioning the name: a flag is never
   exported, so `bin/`, `scripts/`, `maint/` and nvim's lua run where it does not exist.
   A **test** is not a reader either — `HAVE_GRON` survived an earlier draft of this gate
   on the strength of one negative fixture, which is exactly the dead global the direction
   exists to find.

A flag with no reader is not free. It is a global in every interactive shell that can only
go stale, and — because nothing consumes it — nothing ever notices when it does.

Direction 2 reads the sibling clones, so it takes the `skip_env` posture §5f and §5h take:
a repo that is not checked out is an **environment skip**, never a red, and the skip line
names which repos went uncovered.

**Know what that costs today.** Core's CI checks out this repo alone, so direction 2 records
a skip on every CI run and fires only where the fleet sits beside Core — a maintainer's
`make audit`, or the scheduled fleet jobs. The reusable `lint` workflow the OS repos call
does not yet run it, so an OS-repo PR adding an undeclared read can merge without a red.
Closing that needs a caller-side leg in `lint-call.yml`, which in turn needs the declared
table reachable from a vendored checkout — and this file is **not** in `core.vendor`. That
is [#866](https://github.com/dotgibson/dotfiles-core/issues/866), deliberately separate:
changing the vendoring allowlist is its own blast radius across nine repos. It matches reads by their **sigil** (`$HAVE_X`,
`${HAVE_X}`) rather than by the bare name, which is what lets it ignore the many prose
mentions in comments without needing a parser for five grammars — the trap §3 documents.
Whole-line comments are dropped on top of that, on both the read and the assignment side —
the second matters more, since a `# HAVE_X=1` read as an assignment would mark the flag
owned and **suppress** a real undeclared read of it. What survives both filters is an
inline trailing comment, so one wording rule remains: **do not write a `$` in front of a
flag name in a trailing comment.** Write `HAVE_ATUIN`, not `$HAVE_ATUIN`.

## 6. Before you push

```bash
make audit
```

That is the whole gate. Two things worth knowing about it:

- A missing linter **skips** rather than fails, and the summary then labels the run
  `PARTIAL`. A local green with skips is not the same as CI green — read the summary.
- The boundary gate (§5c) is the one that catches layering mistakes. It is cheap and
  unconditional, so a narrowed `--scope` cannot skip it.

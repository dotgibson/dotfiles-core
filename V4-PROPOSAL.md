# v4 proposal — the loader & layout overhaul

> **Status: IMPLEMENTED (under `[Unreleased]`), pending the v4.0.0 release cut.**
> The Core-side implementation of this design has landed on the
> `claude/dotfiles-core-v4-breaking` branch — the numbered fragments, the glob
> loader, the XDG split, and `CORE_PROFILE` are live, with the breaking changes
> recorded under `## [Unreleased]` in `CHANGELOG.md`. What has **not** happened is
> the deliberate release ceremony: bumping `core.version` to `4.0.0`, tagging, and
> the canary-first fan-out to the OS/Role repos (each re-vendors Core and updates
> its `bootstrap.sh`) per `RELEASE-RUNBOOK.md`. The open questions in [§9](#9-non-goals-and-open-questions)
> are now **resolved** (see there). When a claim here drifts from
> `RELEASE-STRATEGY.md` or `CONTRIBUTING.md`, those win.

## 1. Summary

Core is at `3.9.0`. This proposes the first **major** — `v4.0.0` — as a single
coordinated change to the two things every OS repo depends on: the **zsh module
loader** (`zsh/loader.zsh`) and the **bootstrap symlink contract**
(`lib/bootstrap-lib.sh`). It bundles three improvements that all ride on that
same seam:

1. **Numbered load-order with drop-in fragment slots** — modules gain `NN-`
   prefixes and the loader globs-and-sorts fragments across layers, so OS/Role
   repos can inject *between* stages instead of only appending. Also closes a
   documented zsh↔pwsh divergence.
2. **XDG state/cache/data split** — mutable runtime state (history → state,
   compdump → cache, plugins → data) moves out of the symlinked *config* tree into
   `$XDG_STATE_HOME` / `$XDG_CACHE_HOME` / `$XDG_DATA_HOME`, finishing a migration
   the codebase had already started unevenly. (Byte-compiled `.zwc` wordcode stays
   beside its fragment — zsh's auto-pickup requires it; see §4.3.)
3. **Opt-in module profiles** — a `CORE_PROFILE` (`minimal` / `standard` /
   `full`) derives which Core-band fragments load, so a headless box can skip the
   interactive-heavy stages `minimal` omits: fzf, vi-mode bindings, the plugin
   stack, the 1Password helpers, and the maintenance + update surface (atuin and
   aliases live in `00`–`30`, so they still load).

They are bundled because they touch the **same two contracts**. Shipping them as
three separate majors would hammer every OS repo with three consecutive
re-bootstraps for one architectural idea. One `v4.0.0` pays the fan-out cost
once — the batching discipline `RELEASE-STRATEGY.md §2` is built around.

## 2. Why these earn a major (and the nvim churn does not)

Per `RELEASE-STRATEGY.md §2`, a **MAJOR** is chosen by *blast radius on a host*:
a change a host must adapt to — reordering the load chain, changing the
`bootstrap.sh` symlink contract, or dropping/renaming a manifest path. All three
changes below do exactly that.

For contrast: the ~2,600 lines of Neovim work in v3.7–v3.9 (NvChad UI, `nvim-dap`,
the expanded LSP registry) re-vendor into every OS repo with **zero migration** —
no bootstrap change, no muscle-memory break — which is why they were correctly
cut as *minors*. v4 has to come from the loader/bootstrap/manifest contracts,
because that is the only surface where a host on `v3.x` cannot simply re-sync and
re-source.

## 3. Change 1 — numbered load-order with fragment slots

### 3.1 Current

The load order is a flat, unnumbered array declared by each OS repo's `.zshrc`
and driven by the shared loader:

```zsh
_CORE_MODULES=(tools ui options history aliases git functions fzf bindings \
               plugins op maint update os local)
source "$ZSH_CFG/loader.zsh"
```

`zsh/loader.zsh:38-44` iterates that list and sources `$ZSH_CFG/$_m.zsh`. OS and
Role repos extend the chain **only by appending** stages (`… os offensive local`
on Kali, `… os defense local` on Defense). There is no way to insert a fragment
*between*, say, `aliases` and `git` — anything order-sensitive has to be
smuggled into an existing module.

### 3.2 Proposed

Rename Core modules to `NN-` prefixes and have the loader **glob `NN-*.zsh`
across a set of layer directories, merge, sort numerically, and source** (still
inline at caller scope, still byte-compiling each fragment to `.zwc` first —
`loader.zsh`'s mechanics are preserved, only its input changes).

Each layer has a **recommended default band**, but the numeric prefix — not the
band — is what orders a fragment, so any layer *may* use a Core gap when it
genuinely needs to insert mid-chain (an OS repo dropping `22-foo.zsh` between
`20-aliases` and `25-git` — the §3.1 use case). Bands are a convention for where
fragments usually live, not a hard partition:

| Band | Default owner | Example |
| --- | --- | --- |
| `00`–`69` | Core | `25-git` |
| `70`–`84` | OS-native layer | `80-os-fedora` |
| `85`–`94` | Role layer | `85-offensive` |
| `95`–`99` | Host-local | `99-local` |

Ordering is a pure numeric sort on the `NN` prefix; a same-`NN` tie (two fragments
claiming the same number — a misconfiguration) breaks lexically by filename, so
the merged stream is deterministic. Note the loader carries **no owner metadata** —
everything flattens into one `$ZSH_CFG` — so the *band number* is what determines
both order and profile-gating (see §5). A fragment a layer places in a Core gap is
therefore gated as Core; always-load OS/role/host setup belongs at `>=70`.

Concrete Core numbering (gaps of 5 leave room to inject; every ordering
constraint in the current `core.manifest` header is preserved):

```text
00-tools  05-ui  10-options  15-history  20-aliases  25-git  30-functions
35-fzf  40-bindings  45-plugins  50-op  55-maint  60-update
```

`tools`(00) still inits atuin before `plugins`(45); `options`(10) still runs
`compinit` before `plugins`; `git`(25) still loads after `aliases`(20); `fzf`(35)
still defines its widgets before `plugins` loads zsh-vi-mode.

### 3.3 Cross-shell parity bonus

`PARITY.md` documents the PowerShell host layer already using this exact
convention — `00-aliases.ps1`, `10-tools.ps1`, `20-functions.ps1`. Today the two
shells structure their module load differently; this change makes them
**structurally aligned**, moving a `deliberate`/`gap` row to `aligned`.

### 3.4 What breaks

- Every `zsh/*.zsh` **manifest path is renamed** → `core.manifest` rewrite.
- The `_CORE_MODULES` name-list contract in `loader.zsh` is replaced by a
  layer-directory + glob contract.
- `blib_write_zshrc_loader` in `lib/bootstrap-lib.sh` emits a different `.zshrc`
  stanza (points the loader at directories, no longer a hand-listed module set).
- Each OS/Role repo's appended-stage file is renamed into its band.

## 4. Change 2 — XDG state/cache/data split

### 4.1 Current (an inconsistency already half-fixed)

Parts of Core already place mutable state correctly under XDG:

- `zsh/maint.zsh:24` → `$XDG_STATE_HOME/dotfiles-maint/maint.log`
- `zsh/update.zsh:28` → `$XDG_CACHE_HOME/zsh/pkg-updates`
- `zsh/tools.zsh:49` → `$XDG_CACHE_HOME/zsh`
- `zsh/options.zsh:86` → `$XDG_CACHE_HOME/zsh/zcompcache`

But the **shell-core runtime state still lands in the symlinked config tree**:

- History → `${ZDOTDIR:-$HOME/.config/zsh}/.zsh_history` (`zsh/history.zsh:14`)
- Compdump → `${ZDOTDIR:-$HOME/.config/zsh}/.zcompdump` (`zsh/options.zsh:65`)
- Byte-compiled wordcode `.zwc` → `$ZSH_CFG` (`zsh/loader.zsh:36`, i.e. the
  config dir)
- Plugins → `${ZDOTDIR:-$HOME/.config/zsh}/plugins` (`zsh/plugins.zsh:30`)

So four categories of regenerable-or-stateful data are written into a directory
that is otherwise a **symlinked, read-only-friendly** config tree — while the
rest of the codebase already knows better. `loader.zsh:27-28` even carries a
"read-only `$ZSH_CFG`" fallback, treating as an edge case what should be the norm.

### 4.2 Proposed

Finish the split — config stays symlinked and immutable; everything mutable moves
to its XDG home:

| Data | From | To |
| --- | --- | --- |
| History (+ atuin flat file) | `$ZDOTDIR/.zsh_history` | `$XDG_STATE_HOME/zsh/history` |
| Compdump | `$ZDOTDIR/.zcompdump` | `$XDG_CACHE_HOME/zsh/zcompdump` |
| `.zwc` wordcode | `$ZSH_CFG/*.zwc` | **stays in `$ZSH_CFG`** (see §4.3) |
| Plugins | `$ZDOTDIR/plugins` | `$XDG_DATA_HOME/zsh/plugins` |

History, compdump, and plugins move; **byte-compiled `.zwc` wordcode does not**.
zsh's automatic wordcode pickup fires only when `file.zwc` sits *beside* the
sourced `file` (`source file` loads `file.zwc` when it is current), so relocating
it to `$XDG_CACHE_HOME` would break the fast path or force sourcing digests (which
`source` can't use as wordcode). `$ZSH_CFG` is a real, writable directory of
symlinks — not an immutable tree — so wordcode-beside-source is fine and stays
there. That is the one implementation deviation from the original four-item list.

### 4.3 What breaks

- The **symlink/provisioning contract** changes: `bootstrap.sh` must create the
  state/cache/data dirs, and existing hosts' `.zsh_history` **moves location** —
  so a host must **re-bootstrap**, not just re-source. This is the textbook
  symlink-contract MAJOR.
- Migration must relocate the existing history file (see §7) so no history is
  lost.

## 5. Change 3 — opt-in module profiles

### 5.1 Current

Every module always loads. The only knob is `DOTFILES_OFFLINE`. A headless
server or minimal container pays for the `plugins.zsh` stack (carapace/fzf-tab/
autosuggestions/syntax-highlighting), the `fzf` widgets + vi-mode bindings, the
1Password helpers, and the maintenance + `update.zsh` nudge — whether it wants
them or not. (Neovim is deliberately out of scope: it is provisioned by
`blib_link_core` at bootstrap and loaded by nvim itself, not by any zsh stage, so
a zsh-fragment profile cannot govern it — see §9 for extending profiles to
bootstrap wiring.)

### 5.2 Proposed

A `CORE_PROFILE` (env var, or a `$XDG_CONFIG_HOME/zsh/profile` one-liner) that the
loader reads to **filter which Core-band fragments (`00`–`69`) load** — gating is by
band number, not authorship. It never filters the outer bands — fragments numbered
`70`–`99` (OS, Role, host-local) always load, so essential OS setup and `99-local.zsh`
are never skipped by a profile (which is why always-load setup must live at `>=70`):

| Profile | Includes (Core bands) | Use |
| --- | --- | --- |
| `minimal` | `00`–`30` (tools, ui, options, history, aliases, git, functions) | fast headless / container shell |
| `standard` | `minimal` + `35`–`50` (fzf, bindings, plugins, op) | interactive workstation without the maintenance surface |
| `full` (default) | `standard` + `55`–`60` (maint, update) | the current everything-loads behaviour |

`full` stays the default so an un-migrated host behaves as it does today during
the deprecation window.

### 5.3 What breaks

- `_CORE_MODULES` stops being a caller-declared literal and becomes
  loader-derived from the profile — every OS `.zshrc` loader stanza changes
  shape (the same stanza already changing for Change 1, so the cost is shared).

## 6. Combined blast radius

All three land in one `v4.0.0`. A host reaches it only through the three
independent opt-in gates from `RELEASE-STRATEGY.md §4` — nothing is pushed:

1. Merged, audited green, and **tagged** `v4.0.0` in `dotfiles-core`.
2. The OS repo **pulls** the tag (`git subtree pull … v4.0.0 --squash`) and
   commits the new `core.lock`.
3. The host **re-bootstraps** to pick up the renamed fragments and the relocated
   state dirs.

Skip any gate and the host stays on `v3.x`. Roll back per OS by **reverting** the
v4-adoption commit in that repo (its `core.lock` + `bootstrap.sh` changes) and
re-bootstrapping — a `git subtree pull` of the older tag does *not* reverse an
already-merged newer subtree (it reports the tree as up to date), so revert is
the correct mechanism. This refines the "re-pull the previous tag" shorthand in
`RELEASE-STRATEGY.md §4`, which holds for a repo still *ahead* of a tag but not
for undoing an adopted newer one.

## 7. Per-OS-repo migration runbook

For each repo in `scripts/os-repos.txt` (which already includes the Role repos
`dotfiles-Kali` and `dotfiles-Defense`), after `v4.0.0` is tagged:

1. **Adopt the tag:**
   `git subtree pull --prefix=core <core-remote> v4.0.0 --squash`
2. **Update `bootstrap.sh`:** call the vendored `blib_write_zshrc_loader` (now
   param-less — it no longer takes a module list). It emits the managed
   `dotfiles-managed v4` `.zshrc`, which sets `CORE_PROFILE` and sources the loader;
   the loader globs the numbered fragments from **one flat `$ZSH_CFG`** (all layers
   symlink into it), so there is no `_CORE_LAYER_DIRS` list to pass:

   ```zsh
   : "${CORE_PROFILE:=full}"
   source "$ZSH_CFG/loader.zsh"
   ```

3. **Symlink the OS/Role layer fragment** into its band: `blib_link_os_layer` links
   `os/<name>.zsh` → `$ZSH_CFG/80-os.zsh`; a role repo links its stage into the 85
   band (Kali `85-offensive.zsh`, Defense `85-defense.zsh`) — the loader picks it up
   by glob, no module-list entry needed.
4. **Migration is automatic:** `blib_migrate_v4` (called from `blib_link_core`) moves
   an existing `~/.config/zsh/.zsh_history` → `$XDG_STATE_HOME/zsh/history`, renames a
   host `local.zsh` → `99-local.zsh`, and drops the stale pre-v4 unnumbered symlinks +
   compdump — all idempotent. The XDG state/cache/data subdirs are created on first
   shell start by the fragments themselves.
5. **Verify:** OS-repo bootstrap dry-run is clean; `make fleet-drift` in Core
   confirms the repo converged on `v4.0.0`; commit the new `core.lock`.

**Windows** (`dotfiles-Windows`) vendors no `core/` subtree — it only needs its
`PARITY.md` row updated to reflect that the module-load structure is now aligned
(no host change required).

Roll out **canary-first** (one OS repo, bake, then fan out) per
`RELEASE-STRATEGY.md §4`.

## 8. CHANGELOG entry

The breaking-change entries below have **landed** under `## [Unreleased]` in
`CHANGELOG.md` (they move under a `## [v4.0.0]` heading when the release is cut).
Kept here for reference:

```markdown
### Changed

- **BREAKING — loader & layout overhaul.** Core's zsh modules are renamed to
  numbered fragments (`00-tools` … `60-update`) and the loader now globs-and-sorts
  `NN-*.zsh` across the Core, OS, and local layer directories instead of sourcing a
  hand-declared `_CORE_MODULES` name list. OS/Role repos gain default bands
  (`70`–`84` OS, `85`–`94` role, `95`–`99` local) and can inject a fragment at any
  point in the chain rather than only appending — and the zsh module structure now
  matches the PowerShell host layer's `NN-name` convention (PARITY.md). Every OS
  repo must re-vendor and update its `bootstrap.sh` loader stanza; see V4-PROPOSAL.md.
- **BREAKING — mutable state moves to XDG dirs.** History
  (`$XDG_STATE_HOME/zsh/history`), the compdump and byte-compiled `.zwc`
  (`$XDG_CACHE_HOME/zsh/…`), and plugins (`$XDG_DATA_HOME/zsh/plugins`) leave the
  symlinked config tree, which is now immutable. `bootstrap.sh` relocates an
  existing history file on re-bootstrap so nothing is lost. Hosts must
  re-bootstrap, not just re-source.

### Added

- **`CORE_PROFILE` (`minimal` / `standard` / `full`).** Selects which Core-band
  fragments (`00`–`69`) load, so a headless box can skip the interactive-heavy
  stages `minimal` omits — fzf, vi-mode bindings, the plugin stack, the 1Password
  helpers, and the maintenance + update surface (atuin/history + aliases in
  `00`–`30` still load); it never filters the OS/Role/local layers. Resolved from
  the environment or a `$ZSH_CFG/profile` one-liner; defaults to `full`.
```

## 9. Non-goals and open questions

**Non-goals (deliberately out of this major):**

- The `core` CLI dispatcher (consolidating `up` / `maint-*` / `update-check`)
  and offline-first vendored plugins — separate candidates, not bundled here.
- Any change to keybindings, aliases, or the tmux prefix. Public muscle-memory
  surface is untouched.

**Resolved decisions (as implemented):**

1. **Default `CORE_PROFILE` = `full`.** Chosen so an un-migrated or unspecified
   host behaves exactly as it does today; a lean shell is opt-in, never a surprise
   default. The loader treats any unknown value as `full` (safest) too.
2. **Hard-cut — no compat shim.** A shim can't help once the module *files* are
   renamed: `_CORE_MODULES=(tools …)` would resolve to `$ZSH_CFG/tools.zsh`, which
   no longer exists, so keeping it working would require carrying both filenames.
   Since a coordinated major re-vendors and updates every OS `bootstrap.sh` in the
   same rollout, the honest move is to cut cleanly. `blib_write_zshrc_loader` still
   *accepts and ignores* legacy args so a not-yet-updated caller doesn't error.
3. **Bands are conventions, so width is not a hard constraint.** Core keeps
   `00`–`69` and the outer bands stay `70`–`99`; because any layer may use a Core
   gap when it genuinely needs mid-chain insertion (numeric-sort + layer-precedence
   tiebreak), the 15-slot OS band is a default home, not a ceiling. No compression
   needed.
4. **`CORE_PROFILE` stays a pure loader concern — it does NOT gate bootstrap
   provisioning.** Install-time selection (which groups get symlinked — zsh, nvim,
   tmux) is already owned by `bootstrap.sh`'s `--only`/`--skip` (`blib_want`), a
   purpose-built, audit-tested mechanism. Overloading the runtime `CORE_PROFILE`
   onto it would duplicate that and introduce a footgun (bootstrap runs once; the
   env var is per-shell and mutable, so a profile that skipped the nvim symlink
   would leave nvim broken after switching to `full` until re-bootstrap). The two
   compose orthogonally: `bootstrap.sh --only zsh` (persistent, on-disk) +
   `CORE_PROFILE=minimal` (per-shell, cheap to change).

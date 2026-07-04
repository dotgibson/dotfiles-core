# 🧬 dotfiles-core

**One Core. Every machine. Zero drift.** The shared heart of a cross-platform
dotfiles system — authored once, vendored into every OS layer via `git subtree`.

`zsh` · `nvim` · `tmux` · `starship`

<!-- Row 1 — Repo status & automation (CI/CD) -->
[![ci](https://img.shields.io/github/actions/workflow/status/dotgibson/dotfiles-core/ci.yml?branch=main&style=flat-square&logo=githubactions&logoColor=white&label=ci)](https://github.com/dotgibson/dotfiles-core/actions/workflows/ci.yml)
[![core-integrity](https://img.shields.io/github/actions/workflow/status/dotgibson/dotfiles-core/core-integrity.yml?branch=main&style=flat-square&logo=githubactions&logoColor=white&label=core-integrity)](https://github.com/dotgibson/dotfiles-core/actions/workflows/core-integrity.yml)
[![open issues](https://img.shields.io/github/issues/dotgibson/dotfiles-core?style=flat-square&logo=github)](https://github.com/dotgibson/dotfiles-core/issues)
[![open PRs](https://img.shields.io/github/issues-pr/dotgibson/dotfiles-core?style=flat-square&logo=github)](https://github.com/dotgibson/dotfiles-core/pulls)
![repo size](https://img.shields.io/github/repo-size/dotgibson/dotfiles-core?style=flat-square&logo=github)
[![latest release](https://img.shields.io/github/v/release/dotgibson/dotfiles-core?style=flat-square&logo=github&label=release)](https://github.com/dotgibson/dotfiles-core/releases/latest)
[![showcase](https://img.shields.io/badge/showcase-live-7aa2f7?style=flat-square)](https://dotgibson.github.io/dotfiles-web/)

<!-- Row 2 — License & project info -->
[![license](https://img.shields.io/github/license/dotgibson/dotfiles-core?style=flat-square&color=blue)](LICENSE)
![last commit](https://img.shields.io/github/last-commit/dotgibson/dotfiles-core?branch=main&style=flat-square&logo=git&logoColor=white)
![commit activity](https://img.shields.io/github/commit-activity/m/dotgibson/dotfiles-core?style=flat-square&logo=git&logoColor=white)

<!-- Row 3 — Languages (simpleicons brand colors) -->
![Zsh](https://img.shields.io/badge/Zsh-F15A24?style=flat-square&logo=zsh&logoColor=white)
![Bash](https://img.shields.io/badge/Bash-4EAA25?style=flat-square&logo=gnubash&logoColor=white)
![Lua](https://img.shields.io/badge/Lua-2C2D72?style=flat-square&logo=lua&logoColor=white)
![TOML](https://img.shields.io/badge/TOML-9C4121?style=flat-square&logo=toml&logoColor=white)

<!-- Row 4 — Tooling (simpleicons brand colors) -->
![Neovim](https://img.shields.io/badge/Neovim-57A143?style=flat-square&logo=neovim&logoColor=white)
![tmux](https://img.shields.io/badge/tmux-1BB91F?style=flat-square&logo=tmux&logoColor=white)
![Starship](https://img.shields.io/badge/Starship-DD0B78?style=flat-square&logo=starship&logoColor=white)
![Git](https://img.shields.io/badge/Git-F05032?style=flat-square&logo=git&logoColor=white)

---

**Single source of truth for the Core layer** shared across every machine repo.
This is the keystone of a ten-repo dotfiles system. It holds the config that is
identical everywhere — shell modules, tmux base, Neovim, git — and nothing that
is OS-specific or offensive.

> If it changes when the _operating system_ changes, it does **not** belong here.
> If it changes when _you as an operator_ change, it does **not** belong here.
> Everything left over is Core, and it lives here.

---

## The three-layer model (unchanged, now centralized)

| Layer         | Lives in                                                        | Examples                                                                                 |
| ------------- | --------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| **Core**      | **this repo**, vendored into each OS repo via `git subtree`     | zsh modules, tmux base, nvim, git/delta                                                  |
| **OS-native** | `dotfiles-{MacBook,Windows,Fedora,Arch,openSUSE,Alpine,Gentoo}` | package manager, clipboard shim, paths                                                   |
| **Role**      | `dotfiles-Kali` (offensive) · `dotfiles-Defense` (defensive)    | offensive: engagement scaffolding, C2, Impacket; defensive: detections, hunt/triage, lab |

Previously each repo carried its **own copy** of Core, and drift was caught
after the fact with `core-diff.sh`. That works at 4 repos. At 10 it doesn't.
This repo flips it: Core is authored **once, here**, then pulled into each OS
repo as a vendored `core/` subtree. No more N-way reconciliation.

---

## How an OS repo consumes Core

Each machine repo (e.g. `dotfiles-Fedora`) vendors this repo under `core/`:

```bash
# one-time, inside the OS repo:
git subtree add --prefix=core https://github.com/<you>/dotfiles-core main --squash
```

That physically copies Core into `core/` and commits it. The repo now clones
and works with **no submodule flags** — important, since these are public
showcase repos people will browse.

To update every OS repo after a Core change, run the loop helper from this repo:

```bash
./scripts/sync-core.sh          # subtree-pulls main into all 8 OS repos
./scripts/sync-core.sh --dry-run
```

> Run `make` (no target) for a discoverable list of every entry point —
> `make setup` / `doctor` / `audit` / `test` / `bench` / `sync` / `hooks` all shell out
> to the `scripts/*.sh` dev tooling, which stays the single source of truth. (`make doctor`
> is the read-only triage half of `setup`; `bin/` holds only what ships — `clip`/`clip-paste`;
> the gate scripts live in `scripts/`.)

The OS repo's `bootstrap.sh` then symlinks `core/zsh/*.zsh`, `core/tmux/`,
`core/nvim/`, `core/git/`, `core/vim/`, `core/starship/`, `core/mise/`, and `core/bin/` into
place alongside its own OS-native files. (`core/bin/` is just `clip`/`clip-paste`
now — the dev scripts in `core/scripts/` are repo tooling and aren't symlinked.)

---

## Why subtree (not submodule, not chezmoi)

- **vs submodule** — submodules store a _pointer_, so a fresh clone is empty
  until `git submodule update --init`. Subtree vendors the actual files, so
  every repo is self-contained and clone-and-go. Better for portfolio repos.
- **vs chezmoi** — chezmoi (one repo + per-OS templates) is the most DRY answer
  and is the right move if you ever want to collapse ten repos into one. It
  trades the ten-repo breadth-portfolio for minimalism. This system keeps the
  portfolio; switching to chezmoi later is a content migration, not a rewrite,
  because the Core files here are already plain and OS-agnostic.

---

## Layout

Core is fully populated — every layer below is authored here and synced out to
each OS repo's vendored `core/`. The canonical inventory is `core.manifest`;
this tree is the human-readable version of it.

```text
bin/                      SHIPPED — vendored into every OS repo (in core.manifest):
  clip                    cross-OS "copy to clipboard"   (WSL/macOS/Wayland/X11)
  clip-paste              cross-OS "paste from clipboard"
lib/                      SHIPPED — vendored bash libraries (sourced, not run):
  ux.sh                   shared palette/glyphs/spinner — each OS repo's bootstrap.sh
                          sources this (the pre-shell installer can't load the zsh ui.zsh)
scripts/                  DEV TOOLING — runs the gate HERE, never vendored out:
  audit-core.sh           THE gate: manifest/exec-bit/syntax/lint/behavioral (CI + pre-commit run this)
  test-core.sh            behavioral suite: clip ladder + load-order smoke + functions + nvim load
  bench-core.sh           hermetic hyperfine benchmark of the canonical zsh load chain
  sync-core.sh            loop git-subtree pull across all OS repos (the maintain button)
  update-plugins.sh       roll the pinned zsh-plugin SHAs (zsh/plugins.zsh) to upstream HEAD
zsh/                      sourced by each OS repo's .zshrc loader, IN THIS ORDER:
  loader.zsh              canonical byte-compile + source loop (vendored so each OS .zshrc can source THIS instead of duplicating it)
  tools.zsh               detection + single init point (zoxide/starship/atuin/mise) — load FIRST
  ui.zsh                  terminal-UX primitives (_core_err/warn/ok/hint/confirm/spin) — gum-aware
  options.zsh             setopts + completion system (compinit, cached) + zstyles
  history.zsh             HISTFILE/HISTSIZE/SAVEHIST + history setopts + secret-ignore
  aliases.zsh             modern-CLI aliases, each guarded by tools.zsh detection
  git.zsh                 curated OMZ-style git aliases + git_main_branch helper
  functions.zsh           cross-OS shell functions (mkcd, extract, up, ...)
  fzf.zsh                 fzf env + zle widgets (Ctrl-T/R, Alt-Z, Ctrl-G) + fif/fbr
  bindings.zsh            vi-mode keybindings (zvm_after_init hook)
  plugins.zsh             lightweight plugin loader + plugin list
  op.zsh                  1Password CLI helpers
  maint.zsh               daily-maintenance control surface (maint-install/run/log)
  update.zsh              `up` updater + once/day "updates available" nudge
  completions/            autoloaded completions for Core's verbs (up/extract/mkcd/…) — fpath-added by options.zsh
starship/
  starship.toml           prompt theme -> symlinked to ~/.config/starship.toml
mise/
  config.toml             global runtime versions (node/python/ruby/go/rust/java/lua)
sesh/
  sesh.toml.example       portable session-manager config (seeded, not symlinked)
tmux/
  tmux.conf               portable base config (OS bits -> os/<os>.conf)
  tmux.reset.conf         the keybinding layer (prefix C-a lives here)
  scripts/                popup scripts: tmux-battery / tmux-cheat / tmux-menu / tmux-netinfo / tmux-scratch / tmux-sesh
maint/
  dotfiles-maint.sh       the daily "update everything (that's safe)" runner
git/
  gitconfig               portable git config (OS + identity layered via [include])
  local.gitconfig.example identity template — seeded by bootstrap, never tracked
lazygit/
  config.yml              tokyonight theme -> symlinked to ~/.config/lazygit/config.yml
vim/
  vimrc                   plugin-free fallback for boxes with only stock vim -> symlinked to ~/.vimrc
nvim/                     entire lazy.nvim tree: lua/gerrrt/{config,plugins,servers,utils}
core.manifest             the canonical list of Core files (drives sync + audits)
core.version              human-readable Core version stamp (read by `core-version`)
```

> Load order is load-bearing: `tools` inits atuin (registers its widget), `options`
> runs `compinit` (fzf-tab + carapace need it), and `fzf` defines its zle widgets
> BEFORE `plugins` loads zsh-vi-mode, whose init fires the keybinding hook in
> `bindings`. `ui` loads right after `tools` (it only defines the `_core_*` UX
> helpers every later module may call). Each OS repo's `.zshrc` sources them as
> `tools → ui → options → history → aliases → git → functions → fzf → bindings →
plugins → op → maint → update → os → local` (the canonical order in
> `core.manifest`).

---

## Adding a new file to Core

Core is already complete (zsh, tmux, nvim, git, starship, mise, and the clip
scripts are all here). The promotion from the old per-repo copies is done — so
this is now just the procedure for the occasional **new** Core file:

1. Confirm it's actually Core: identical on every machine, **not** OS-specific,
   **not** offensive. (OS-specific → the OS repo; offensive → `dotfiles-Kali`.)
2. Drop it into the matching path here.
3. Strip anything OS-specific out into the OS repo (clipboard, paths, pkg mgr).
4. Add the path to `core.manifest` — that's the contract the audits read.
5. Wire the symlink into each OS repo's `bootstrap.sh` if the file needs one.
6. `./scripts/sync-core.sh` to push it into every OS repo's vendored `core/`.

## Maintaining Core (the automated workflow)

Day-to-day this is the whole loop — author, gate, fan out:

1. **Pick the layer.** Core only if identical everywhere **and** not OS-specific
   **and** not offensive. Otherwise it belongs in the OS repo (or `dotfiles-Kali`).
2. **Edit here**, add a `[Unreleased]` `CHANGELOG.md` bullet in the _same_ commit
   (Conventional Commits message).
3. **`make audit-changed`** (fast loop) → **`make audit`** (the full gate).
4. **`make sync`** — fan Core out to every OS repo (only after a green audit).

Scheduled bots now cover the chores you used to have to _remember to check_. They
**report first** (PR or deduped issue) and never vendor anything out on their own —
your job is to glance at what they open and merge or act:

| Bot (workflow)                                       | Repo    | Cadence            | Opens                                         |
| ---------------------------------------------------- | ------- | ------------------ | --------------------------------------------- |
| `/doc-audit` + `/tool-scout` (`claude-routines.yml`) | core    | weekly + on demand | findings **issue**                            |
| pin freshness (`freshness.yml`)                      | core    | weekly             | **PR** (rolls zsh-plugin + nvim pins forward) |
| `fleet-sync.yml`                                     | web     | weekly             | **PR** (regenerated site data)                |
| `nvim-sync.yml`                                      | Windows | weekly             | **PR** when `nvim/` drifts                    |
| `package-freshness.yml`                              | Windows | weekly             | scoop/winget **issue**                        |

A quiet week (no bot PR/issue) means nothing needs doing. Every bot is
`workflow_dispatch`-able to run on demand.

> **One wiring step:** `claude-routines.yml` is inert until the
> `CLAUDE_CODE_OAUTH_TOKEN` secret is set on this repo (`claude setup-token`) — until
> then the doc-audit / tool-scout issues won't appear.

### Cutting a release

1. `make release VERSION=X.Y.Z` — promotes `CHANGELOG.md`'s hand-written
   `[Unreleased]` to a dated `## [vX.Y.Z]` heading, bumps `core.version`, runs the
   audit.
2. Commit it, then — if you publish a GitHub Release — `make release-notes` drafts
   the release body from Conventional Commits (it does **not** touch `CHANGELOG.md`).

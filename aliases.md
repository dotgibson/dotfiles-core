# Core Aliases Cheat Sheet

Most aliases sourced from `zsh/20-aliases.zsh` and `zsh/25-git.zsh`; exception: `cheat` is
defined in `zsh/30-functions.zsh` (alias for `core-help`). Tool aliases are guarded
by detection flags — if the tool is not installed, the classic command is used instead.
Load order: `00-tools.zsh` sets `HAVE_*` flags first, then `20-aliases.zsh` reads them.

The user-facing **shell functions** from `zsh/30-functions.zsh` are listed too (see
[Shell Functions](#shell-functions)) — you type them like any other command, so they
belong on the same cheat sheet.

**The tables are generated, not typed.** Every table between a
`<!-- core:aliases:gen … -->` / `<!-- core:aliases:end … -->` marker pair is rendered by
`scripts/gen-aliases.sh` straight from those zsh files: the _Expands To_ cell is the alias
value verbatim, _Requires_ is the `HAVE_*` flag guarding it, and _Note_ is the trailing
comment on the alias line. Edit the zsh source, then run `make gen-aliases`; `make audit`
fails if a table and its source disagree, or if an alias exists that no table lists. The
prose around the tables is hand-written. A `$VAR` in a value (`$BAT_BIN`, `$FD_BIN`,
`$BROWSER_BIN`) is the tool's resolved binary from `00-tools.zsh` — `batcat` / `fdfind` on
the Debian family, the canonical name elsewhere.

## Modern CLI Replacements

<!-- core:aliases:gen modern-cli -->

| Alias | Expands To | Requires | Note |
| ----- | ---------- | -------- | ---- |
| `ls` | `eza --group-directories-first --icons=auto` | eza | |
| `ll` | `eza -lah --group-directories-first --icons=auto --git` | eza | |
| `la` | `eza -a  --group-directories-first --icons=auto` | eza | |
| `lt` | `eza --tree --level=2 --icons=auto` | eza | |
| `llt` | `eza --tree --level=3 -l --icons=auto` | eza | |
| `tree` | `eza --tree --icons=auto` | eza | |
| `cat` | `$BAT_BIN --paging=never` | bat | |
| `catp` | `$BAT_BIN` | bat | paged, full bat |
| `bat` | `$BAT_BIN` | bat | batcat on the Debian family, bat elsewhere |
| `fd` | `$FD_BIN` | fd-find / fd | fdfind on the Debian family, fd elsewhere |
| `rg` | `rg --smart-case` | ripgrep | |
| `cd` | `z` | zoxide | zoxide: frecency-ranked directory jump |
| `cdi` | `zi` | zoxide | interactive jump (pick from matches) |
| `du` | `dust` | dust | |
| `ps` | `procs` | procs | |
| `top` | `btop` | btop | |
| `htop` | `btop` | btop | |
| `watch` | `viddy` | viddy | |
| `df` | `duf` | duf | |
| `fm` | `yazi` | yazi | |
| `y` | `yazi` | yazi | |
| `http` | `xh` | xh | |
| `https` | `xh --https` | xh | |
| `md` | `glow --pager` | glow | |
| `dns` | `doggo` | doggo | |
| `ping` | `gping` | gping | |
| `help` | `tldr` | tldr | |

<!-- core:aliases:end modern-cli -->

## Editors & Launchers

<!-- core:aliases:gen editors -->

| Alias | Expands To | Requires | Note |
| ----- | ---------- | -------- | ---- |
| `vim` | `nvim` | | |
| `lg` | `lazygit` | | |
| `web` | `$BROWSER_BIN` | w3m / lynx / links2 / links / elinks | the terminal web browser (see the note under the table) |
| `notes` | `cd "$NOTES_DIR" && nvim .` | | |
| `cheat` | `core-help` | | the built-in command index (core help) |

<!-- core:aliases:end editors -->

`web <url>` resolves to the first text browser on the box — `w3m` (the one Core packages
fleet-wide), else `lynx`, `links2`, `links`, `elinks`. With none installed the alias is
never defined. On a **headless** box (no `$DISPLAY`/`$WAYLAND_DISPLAY`, not macOS) Core
also exports `$BROWSER` to the same binary, so tools that shell out to "open a URL" stay in
the terminal; on a desktop it deliberately leaves `$BROWSER` alone rather than hijacking
your GUI browser.

## Navigation & Safety

<!-- core:aliases:gen nav-safety -->

| Alias | Expands To | Note |
| ----- | ---------- | ---- |
| `-` | `cd -` | previous directory |
| `diff` | `diff --color=auto` | |
| `rm` | `rm -i` | interactive |
| `cp` | `cp -i` | interactive |
| `mv` | `mv -i` | interactive |
| `mkdir` | `mkdir -p` | create parents |

<!-- core:aliases:end nav-safety -->

## Named Directories

Zsh named directories (from `zsh/20-aliases.zsh` via `hash -d`) — type them anywhere a
path is expected, e.g. `cd ~dots` or `nvim ~proj/foo`:

<!-- core:aliases:gen named-dirs -->

| Shortcut | Expands To |
| -------- | ---------- |
| `~dots` | `$HOME/.config` |
| `~proj` | `$HOME/Projects` |

<!-- core:aliases:end named-dirs -->

## Network

<!-- core:aliases:gen network -->

| Alias | Expands To | Note |
| ----- | ---------- | ---- |
| `myip` | `curl -fsS https://ifconfig.me 2>/dev/null && echo` | your public IP |
| `ports` | `ss -tulpn 2>/dev/null \|\| netstat -tulpn` | listening sockets (netstat fallback) |

<!-- core:aliases:end network -->

## Jujutsu

Active when `jj` is installed — `00-tools.zsh` detects the binary and sets `HAVE_JJ`
automatically. No manual config required; install `jj` and these aliases appear.

<!-- core:aliases:gen jj -->

| Alias | Expands To | Requires |
| ----- | ---------- | -------- |
| `jjs` | `jj status` | jj |
| `jjl` | `jj log` | jj |
| `jjd` | `jj diff` | jj |

<!-- core:aliases:end jj -->

## uv (Python)

Active when `uv` is installed — `00-tools.zsh` detects the binary and sets `HAVE_UV`
automatically. `uv run` resolves the project's `.venv` itself, so neither of these needs a
manual activation step. `uvx` already ships as a first-class uv command, so it is
deliberately **not** aliased.

<!-- core:aliases:gen uv -->

| Alias | Expands To | Requires | Note |
| ----- | ---------- | -------- | ---- |
| `uvr` | `uv run` | uv | uv run pytest · uv run python -m app · uv run ruff check . |
| `uvs` | `uv sync` | uv | reconcile the project env with uv.lock |

<!-- core:aliases:end uv -->

## Shell Functions

Sourced from `zsh/30-functions.zsh`. These are functions rather than aliases because
they take arguments, validate them, or need real control flow — but you invoke them
exactly like any other command. Every one accepts `--help` and ships a completion; the
_Does_ column below **is** that `--help` one-liner, extracted from the source, so the two
cannot disagree. `core help` (aliased to `cheat` above) lists most of them with shorter
blurbs alongside the keybindings and maintenance verbs.

`core [verb]` is the front door — `core help` / `doctor` / `version` / `status` /
`update [check]` / `maint <install|run|log|status|uninstall>` / `sync` / `whatsnew`
dispatch to the `core-*` functions below and to the `maint-*` / `up` / `gsync` verbs
(bare `core maint` lists its sub-verbs). `core --help` opens the full index rather than a
one-liner, which is why the front door itself is not a row in the table.

<!-- core:aliases:gen functions -->

| Command | Does |
| ------- | ---- |
| `mkcd <dir>` | make a directory (and parents) and cd into it |
| `cdup [n]` | climb n directories (default 1); cdup 3 == cd ../../.. |
| `fcd` | fuzzy-cd into any subdirectory (fzf + fd, degrades to find) |
| `extract <archive>` | unpack any archive (tar/zip/7z/rar/…); guards tarbombs + clobbers |
| `mkbak <file>` | timestamped .bak copy of a file before you edit it |
| `serve [-l\|--local] [port]` | HTTP server in the CWD (default 8000); all interfaces, or loopback with -l |
| `genpw [length]` | random alphanumeric password (default 16) via openssl, /dev/urandom fallback |
| `please` | re-run the last command with sudo (previews + confirms first) |
| `pullall [dir]` | pull every git repo under a dir in parallel (prunes, stashes, fast-forwards trunk) |
| `core-doctor [-v\|--versions] [--json]` | report Core's detected tools + which integrations are actually wired (-v adds versions; --json for machines) |
| `core-version` | print the vendored Core layer's version |
| `core-status [--json]` | is this box current: Core version + provenance, the live OS/role layers, tool health, and whether core/ has been edited |
| `core-whatsnew [--full] [--all]` | release notes since you last looked (--full for the prose, --all for every release the notes carry) |
| `core-help [filter]` | scannable cheat sheet of Core's functions, keys & maintenance; pass a word to filter |

<!-- core:aliases:end functions -->

Note `cdup`, not `up` — `up` is the package-updater in `zsh/60-update.zsh`.

`extract` and `please` confirm before doing something destructive or privileged — an
overwrite/tarbomb scatter, and running your last command as root. That confirmation
_declines_ when there is no TTY, so a scripted or piped run fails safe rather than
proceeding unattended. `serve` binds all interfaces on purpose (it's an ad-hoc
file-transfer server); pass `-l` to keep it on loopback.

## Upstream Sync

`gsync` runs `.bin/sync-upstream.sh`, which pushes an OS repo's vendored `core/` subtree
back upstream to dotfiles-core (also reachable as `core sync`). It is a function, not an
alias, so it works from inside any OS repo's vendored `core/` subtree without needing
`.bin` on `PATH` — and, having no `--help` one-liner to extract, it is described here in
prose rather than in a generated table.

---

## Git Aliases

Sourced from `zsh/25-git.zsh` (OMZ-compatible). Three interactive fuzzy helpers
(`gaf`, `grf`, `grsf`) are functions, not aliases — see `zsh/25-git.zsh` for details.
One row below, `gdft`, is defined in `zsh/20-aliases.zsh` instead: it is gated on
`HAVE_DIFFT` tool detection rather than being part of the git workflow set. Values that
call `git_main_branch` / `git_current_branch` resolve the repo's trunk (main, master,
trunk, …) or the checked-out branch at run time.

### Core

<!-- core:aliases:gen git-core -->

| Alias | Expands To |
| ----- | ---------- |
| `g` | `git` |

<!-- core:aliases:end git-core -->

### Status

<!-- core:aliases:gen git-status -->

| Alias | Expands To |
| ----- | ---------- |
| `gst` | `git status` |
| `gss` | `git status --short` |
| `gsb` | `git status --short --branch` |

<!-- core:aliases:end git-status -->

### Staging

<!-- core:aliases:gen git-staging -->

| Alias | Expands To |
| ----- | ---------- |
| `ga` | `git add` |
| `gaa` | `git add --all` |
| `gap` | `git add --patch` |

<!-- core:aliases:end git-staging -->

### Commit

<!-- core:aliases:gen git-commit -->

| Alias | Expands To | Note |
| ----- | ---------- | ---- |
| `gc` | `git commit --verbose` | |
| `gcm` | `git commit --message` | NOTE: OMZ uses gcm for "checkout main" |
| `gca` | `git commit --verbose --all` | |
| `gcam` | `git commit --all --message` | |
| `gc!` | `git commit --verbose --amend` | |
| `gcn!` | `git commit --verbose --no-edit --amend` | amend, keep message |

<!-- core:aliases:end git-commit -->

### Branch

<!-- core:aliases:gen git-branch -->

| Alias | Expands To |
| ----- | ---------- |
| `gb` | `git branch` |
| `gba` | `git branch --all` |
| `gbd` | `git branch --delete` |
| `gbD` | `git branch --delete --force` |
| `gbm` | `git branch --move` |

<!-- core:aliases:end git-branch -->

### Checkout / Switch

<!-- core:aliases:gen git-checkout -->

| Alias | Expands To |
| ----- | ---------- |
| `gco` | `git checkout` |
| `gcb` | `git checkout -b` |
| `gcom` | `git checkout "$(git_main_branch)"` |
| `gsw` | `git switch` |
| `gswc` | `git switch --create` |
| `gswm` | `git switch "$(git_main_branch)"` |

<!-- core:aliases:end git-checkout -->

### Diff

<!-- core:aliases:gen git-diff -->

| Alias | Expands To | Requires | Note |
| ----- | ---------- | -------- | ---- |
| `gd` | `git diff` | | |
| `gds` | `git diff --staged` | | |
| `gdw` | `git diff --word-diff` | | |
| `gdft` | `git difftool --tool=difftastic` | difft | opt-in structural (AST) diff |

<!-- core:aliases:end git-diff -->

### Log

<!-- core:aliases:gen git-log -->

| Alias | Expands To | Note |
| ----- | ---------- | ---- |
| `glog` | `git log --oneline --decorate --graph` | |
| `gloga` | `git log --oneline --decorate --graph --all` | |
| `glol` | `git log --graph --pretty='%Cred%h%Creset -%C(auto)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset'` | compact pretty log: hash, refs, subject, age, author |
| `glola` | `git log --graph --pretty='%Cred%h%Creset -%C(auto)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --all` | the same, every branch |

<!-- core:aliases:end git-log -->

### Fetch / Pull / Push

<!-- core:aliases:gen git-fetch-pull-push -->

| Alias | Expands To | Note |
| ----- | ---------- | ---- |
| `gf` | `git fetch` | |
| `gfa` | `git fetch --all --prune --tags` | |
| `gl` | `git pull` | |
| `gpr` | `git pull --rebase` | |
| `gp` | `git push` | |
| `gpu` | `git push --set-upstream origin "$(git_current_branch)"` | |
| `gpf` | `git push --force-with-lease` | safe force (upgrade vs OMZ) |
| `gpf!` | `git push --force` | raw force, explicit |

<!-- core:aliases:end git-fetch-pull-push -->

### Stash

<!-- core:aliases:gen git-stash -->

| Alias | Expands To |
| ----- | ---------- |
| `gsta` | `git stash push` |
| `gstaa` | `git stash push --include-untracked` |
| `gstp` | `git stash pop` |
| `gstl` | `git stash list` |
| `gstd` | `git stash drop` |

<!-- core:aliases:end git-stash -->

### Rebase

<!-- core:aliases:gen git-rebase -->

| Alias | Expands To |
| ----- | ---------- |
| `grb` | `git rebase` |
| `grbi` | `git rebase --interactive` |
| `grbm` | `git rebase "$(git_main_branch)"` |
| `grbc` | `git rebase --continue` |
| `grba` | `git rebase --abort` |

<!-- core:aliases:end git-rebase -->

### Reset / Restore

<!-- core:aliases:gen git-reset-restore -->

| Alias | Expands To | Note |
| ----- | ---------- | ---- |
| `grh` | `git reset` | unstage / soft-ish (no --hard) |
| `grhh` | `git reset --hard` | |
| `grs` | `git restore` | |
| `grss` | `git restore --staged` | |

<!-- core:aliases:end git-reset-restore -->

### Remote / Merge

<!-- core:aliases:gen git-remote-merge -->

| Alias | Expands To |
| ----- | ---------- |
| `gr` | `git remote` |
| `grv` | `git remote --verbose` |
| `gm` | `git merge` |
| `gma` | `git merge --abort` |

<!-- core:aliases:end git-remote-merge -->

# Cross-shell parity contract

The fleet drives two interactive shells: **zsh** (Core, vendored into every Unix
repo) and **PowerShell** (the `dotfiles-Windows` host layer, reimplemented natively
— it does *not* vendor Core). A cross-platform operator moving between WSL-zsh and
Windows-pwsh in the same day should find the same muscle memory on both.

This file is the **source of truth** for what "the same" means. Each capability is
one of:

- **`aligned`** — same behaviour + same trigger on both shells. Changing one side
  without the other is a regression; keep them in step.
- **`deliberate`** — intentionally different because the platforms differ (a tool
  is Windows-only, or the host has no tmux). Documented so it's a *decision*, not
  drift.
- **`gap`** — a capability one shell has and the other could, but doesn't yet.
  An open item, not a promise.

> Sources: zsh in `zsh/{00-tools,20-aliases,25-git,30-functions,35-fzf,40-bindings}.zsh`;
> pwsh in `dotfiles-Windows/powershell/core/{00-aliases,10-tools,20-functions}.ps1` and
> `powershell/os/48-core.ps1` (the `core` front door).
>
> **Colour values are not authored in either file.** Core's come from
> `theme/palette.toml` and are rendered by `scripts/gen-theme.sh` (#679); the pwsh
> side is still hand-maintained, so a style change is a **two-repo change**.
> `parity-check.sh` compares the two fzf palettes by value and names the hex pwsh is
> missing — it no longer pins a hex, because a pinned hex fails on the shell that
> correctly regenerated.

## Prompt & tool init

| Capability | zsh | pwsh | Status |
| --- | --- | --- | --- |
| Prompt | starship (`starship.toml`) | starship (same `starship.toml`) | `aligned` |
| Theme | tokyonight-storm | tokyonight-storm | `aligned` |
| Smart `cd` | zoxide (`cd`→`z`, `cdi`/`zi`) | zoxide (`cd` hijacked, `zi`) | `aligned` |
| History sync | atuin | atuin | `aligned` (engine) |
| Completion | carapace + fzf-tab | carapace + PSFzf + CompletionPredictor | `deliberate` |

## Aliases

The alias surface is broadly `aligned`: `ll`/`la`, `cat`→bat, `http`→xh,
`dns`→doggo, `du`→dust, `df`→duf, `top`/`htop`→btop, `watch`→viddy, `fm`/`y`→yazi,
`md`→glow (pwsh `gmd`, since `md` is a builtin), `ping`→gping, `lg`→lazygit.
`grep` is the one `deliberate` divergence in that list: pwsh defines `grep`→rg
(`00-aliases.ps1`), zsh does **not** — shadowing `grep` on a Unix box would change
what every script in `$PATH` gets, so Core keeps it POSIX and ships `rg` as its own
smart-case command (`zsh/20-aliases.zsh`). Windows has no POSIX `grep` to shadow, so
the same alias is safe there. The git
shorthands are the **full curated OMZ-style set** from `zsh/25-git.zsh` on both shells —
`g`, the `gst`/`gss` status family, `ga`/`gaa`/`gap`, the `gc`/`gcm`/`gca`/`gcam`/`gc!`
commit family, `gco`/`gcb`/`gsw` checkout/switch, `gd`/`gds`/`gdw`, the `glog` graph
logs, `gf`/`gl`/`gp`/`gpu`/`gpf` (force-with-lease), the `gsta*` stash and `grb*`
rebase families, and `grh`/`grs`/`gm` — resolving to the same intent on both. On pwsh
the git shorthands that collide with a built-in alias (`gc`→Get-Content, `gl`→Get-Location,
…) are removed at load so the functions win, and `gbD` is dropped (pwsh is
case-insensitive, so it can't coexist with `gbd`).

The **aligned tool-swap aliases** (the classic-command → modern-tool re-points) are
pinned as a flat manifest — [`scripts/parity-aliases.txt`](scripts/parity-aliases.txt)
— so `parity-check.sh` enforces each one **bidirectionally**: the zsh alias must be
defined in `zsh/20-aliases.zsh` **and** the pwsh name must be in `00-aliases.ps1`'s
`provides:` contract. Where the two shells must use different names (e.g. `ps`→procs is
`pss` on pwsh, since `ps` is a core cmdlet) the manifest records the exception, so a
rename on one side without the other is caught. Adding an aligned tool-swap is one
manifest row, not a code change.

## Keybindings

| Capability | zsh | pwsh | Status |
| --- | --- | --- | --- |
| History search | `Ctrl+R` (fzf widget) | `Ctrl+R` (PSFzf) | `aligned` |
| FZF palette | tokyonight-storm `--color` | tokyonight-storm `--color` | `aligned` |
| FZF source cmd | `fd` (`FZF_DEFAULT_COMMAND`) | `fd` (`FZF_DEFAULT_COMMAND`) | `aligned` |
| File picker | `Ctrl+T` (`_fzf_file_no_hidden`) | `Ctrl+T` (PSFzf) | `aligned` |
| atuin TUI | `Ctrl+E` (`_atuin_search_widget`) | `Ctrl+E` (`Invoke-AtuinSearch`) | `aligned` |
| Dir jump | `Alt+Z` (`_fzf_zoxide_jump`) | `Alt+Z` (zoxide `zi`) | `aligned` |
| Session picker | `Ctrl+G` (sesh) | `Ctrl+G` (psmux sessionizer) | `aligned` — jump-to-session both |
| Cheatsheet | `cheat` / `core-help` | `navi` / `cheat` | `deliberate` — command, not a keybind |
| Autosuggest toggle | `Ctrl+\` (`autosuggest-toggle`) | `Ctrl+\` (flips `PredictionSource`) | `aligned` |
| Word nav | `Ctrl+←/→` | `Ctrl+←/→` (PSReadLine) | `aligned` |

## Functions

| Capability | zsh | pwsh | Status |
| --- | --- | --- | --- |
| Utility functions | `extract` `mkbak` `serve` `fif` `fbr` | `extract` `mkbak` `serve` `fif` `fbr` | `aligned` |
| Fuzzy git stage/restore | `gaf` `grf` `grsf` | `gaf` `grf` `grsf` | `aligned` |
| `cheat` | `cheat` → `core-help` (Core's own command index) | `cheat` → cht.sh (`Invoke-RestMethod`) | `deliberate` — same trigger, different source |

## Fleet front door (`core`)

The umbrella `core` verb + its standalone twins, so a cross-platform operator
reaches for the same command on both shells. On pwsh these are thin dispatchers
over the host's native verbs (`dotfiles-doctor` / `dothelp` / `up`), which stay
canonical. Enforced by `scripts/parity-check.sh` (the `core *` rows).

| Capability | zsh | pwsh | Status |
| --- | --- | --- | --- |
| Front door | `core` (`help`/`doctor`/`version`/`update`) | `core` (same verbs) | `aligned` |
| Health | `core doctor` / `core-doctor` | `core doctor` / `core-doctor` (→ `dotfiles-doctor`) | `aligned` |
| Command index | `core help` / `core-help` | `core help` / `core-help` (→ `dothelp`) | `aligned` (name) |
| Version | `core version` / `core-version` | `core version` / `core-version` | `aligned` |
| Update | `core update` / `up` | `core update` / `up` | `aligned` |

## Enforcement

`scripts/parity-check.sh` (`make parity-check`, and §9f of `make audit`) mechanises the
`aligned` rows: it asserts a distinctive needle for each is present in BOTH a zsh source
and the pwsh source, and exits non-zero when one side drifts. It reads pwsh from a sibling
`dotfiles-Windows` checkout (skipped with a notice if absent, unless `--strict`), exactly
like `scripts/fleet-drift.sh`. The weekly `.github/workflows/parity-check.yml` clones
`dotfiles-Windows` and runs it `--strict`, failing red on drift.

**The one-to-one claim is proven, not promised.** Every check in `parity-check.sh` names
the table row it enforces, and the script parses *this file* to assert the mapping both
ways: every `aligned` row here has at least one check, and every check names a row that
exists. Adding an `aligned` row without a needle fails the gate; so does leaving a needle
behind after its row is **renamed or deleted**, or wording two Capability cells so they
collide, which would let one row's check certify the other. Reclassifying a row does *not*
fail — a `deliberate` or `gap` row is allowed to keep its check, as `cheat` does; it is
only `aligned` rows that must have one. A row may carry several checks, which is how the
five utility functions, the three fuzzy-git verbs and the two word-nav directions are each
covered individually rather than by one needle standing in for the set.

The coverage this proves is **row-level, not claim-level**: a row whose cells name two
triggers is not mechanically forced to carry two needles. That is exactly how `Alt+C` hid
behind `Alt+Z`'s needle for years, so every multi-trigger row here now spends a needle per
trigger — but adding a trigger to a row still means remembering to add its needle. Saying
so is the point; a gate that overstated its reach a second time would be the same bug.

This used to be a discipline ("add a check in the same change"), and disciplines do not
hold. **Theme**, **History search**, **Word nav** and the five-function row were all
marked `aligned` for years with nothing behind them while this section claimed otherwise,
and `Alt+C` was listed as an aligned dir-jump binding that **neither** shell has ever
had — zsh never binds `^[c` and never sources fzf's own key-bindings, and
`dotfiles-Windows` sets only PSFzf's provider and reverse-history chords. #679 added
Theme's check; #682 added the rest, removed the `Alt+C` fiction, and made the claim
mechanical. Whether an `Alt+C` subdirectory picker is wanted on both shells for real is
tracked as #808 — a feature, not a contract repair.

Two rows are deliberately honest about proving less than they look like they prove:

- **Theme** shares its pwsh evidence with **FZF palette** — the fzf `--color` block is the
  only place `dotfiles-Windows` carries tokyonight colours at all, since it has no
  `_CORE_ACCENT_SPEC` equivalent. That accent half remains a genuine `gap`.
- **Word nav**'s pwsh half is a *PSReadLine default*, not configuration: nothing in
  `dotfiles-Windows` binds Ctrl+Arrow, so there is no string to grep. Its check asserts
  Core's half and reports the pwsh half as a skip carrying that reason, rather than
  inventing a needle that would go green without proving anything — and the closing summary
  says how many halves were reported rather than asserted, instead of certifying them.
  dotgibson/dotfiles-Windows#231 tracks binding it explicitly.

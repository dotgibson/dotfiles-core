# assets

Media for the project README.

## `demo.gif` — the hero terminal demo

Rendered from [`demo.tape`](demo.tape) with [VHS](https://github.com/charmbracelet/vhs),
so it's reproducible: re-run the command after any prompt or tooling change and the
hero updates — no manual re-recording.

```sh
brew install vhs        # one-time (pulls ttyd + ffmpeg)
vhs assets/demo.tape    # writes assets/demo.gif
```

Requires a Nerd Font installed locally — the icons in `eza` and `starship` render as
boxes without one. Always optimize afterwards — the raw VHS output is not what ships:

```sh
gifsicle -O3 --lossy=80 --colors 64 assets/demo.gif -o assets/demo.gif
```

`--colors 64` matters more here than it looks. The palette is 20 theme colours plus font
antialiasing, so quantising to 64 is visually free and removes a large chunk of the file.

The README hero (`[product-screenshot]` in `README.md`) points at `assets/demo.gif`.
Re-render and re-commit it after any prompt or tooling change to keep the hero current.

## `demo.tape` is generated — edit `hero.tape.in`

`demo.tape` carries a DO-NOT-EDIT banner and means it. The tape is rendered by
[`scripts/gen-hero-tape.sh`](../scripts/gen-hero-tape.sh) from three sources:

| source                  | holds                                                             |
| ----------------------- | ----------------------------------------------------------------- |
| `hero.tape.in`          | the shared body — every command, every `Sleep`, the whole tour    |
| `hero-repos.txt`        | what varies per repo: the `cd` path and the one signature command |
| `../theme/palette.toml` | the colours, rendered into `Set Theme { … }`                      |

```sh
make gen-hero-tape      # rewrite the tape from those three
make check-hero-tape    # exit 1 if it has drifted (audit-core.sh §9j runs this)
```

Hand-editing `demo.tape` is a gate failure, for the reason the fleet's other generated
surfaces have one: the tape used to say `cd ~/code/dotfiles/dotfiles-MacBook` while
sitting in `dotfiles-core`, and nothing could catch it because nothing derived it from
anything (#698). `Set Theme` was the same defect in the other direction — a fourth
place the theme was typed by hand, and the only one naming an upstream preset rather
than the palette every other consumer is generated from.

### The nine other heroes

Ten public repos open with the same shields template and no visual, and the repo that
*has* a hero is the one nobody installs directly. `hero-repos.txt` registers **ten rows** —
this repo plus the nine Core-vendoring OS and role repos — and `make gen-hero-tape-fleet`
renders those nine into their own checkouts. Their
signature command is deliberately the same three characters everywhere —

```tape
Type "up -n"    # one verb → sudo zypper dup
```

— because the point is what it *resolves* to: `dnf` on Fedora, `pacman` on Arch, `apk`
on Alpine, `emerge` on Gentoo, `zypper dup` (not `up`, the distinction that half-updates
a box) on Tumbleweed.

That resolution has to be **visible**, and two things that look like they show it don't.
The trailing `# one verb → …` is a *tape* comment — VHS never renders it. And `up -n`
prints `via zypper`, the **manager**, not the verb (`zsh/60-update.zsh`'s dry-run branch),
so it cannot distinguish `up` from `dup` either. So each OS row carries a `proof` command
that prints the resolved verb on screen:

```tape
Type "up -n" ...                                          # the one verb, every box
Type "echo up resolves to $(_core_cap PKG_UPGRADE)" ...   # → sudo zypper dup
```

It reads the capability; it never applies it.

**The rendering host has to be the right one, and that is now checked.** Core loads the
capability declaration once at shell startup, from the *host's* linked
`~/.config/zsh/os.capabilities` — `cd`-ing into a repo does not switch it, and `up -n`
probes `$PATH`. So an OS hero filmed on the wrong box records that box's package manager
under a comment naming the row's: render the Fedora tape on a MacBook and the gif says
`brew upgrade` while the tape says `dnf`. Each OS tape therefore opens with a hidden guard:

```tape
Type "[[ $(_core_cap PKG_UPGRADE) == 'sudo zypper dup' ]] || exit 1" Enter
```

It sits inside the `Hide` block, so it costs the clip nothing, and a mismatched host fails
the render instead of publishing a hero that contradicts itself. Rows with no declaration
(this repo, the two role repos) get `true`. The registry's `proof` value is substituted
*inside* the template's `Type "…"`, so it must contain no double quote (it would close the
string early) and no `>` or `<` (a redirection in the shell VHS is driving). Those rules are
**enforced**, not just written here — `validate_registry` rejects them, along with a `.` row
that films any other registered repo, which is #698's original defect stated as a check.

The `# one verb → …` comment stays as the maintainer-facing half: it is derived from each
repo's own `os/*.capabilities` `PKG_UPGRADE`, so a tape can never *claim* a verb the repo
does not declare, even though only the `proof` line reaches the viewer.

Rendering and committing those nine gifs, and adding the hero block to each repo's
README, is #698's follow-up — sequenced after `os.capabilities` (#667).

**`dotfiles-Windows` is deliberately not registered**, which means those ten rows are not
the ten repos #698 counted: that list included Windows, and this covers nine of it. The
reason is the same one that keeps Windows out of `scripts/os-repos.txt` — its host layer is
replicated from scratch in PowerShell and it vendors no `core/`, so there is no `zsh` to
`Set Shell`, no `~/.config/zsh/.zshrc` to source, and no `up`, `ll` or `_core_cap` for the
shared body to type. A Windows hero needs its own tape and its own recorder, and that is
that repo's call, not this generator's. It remains the one public repo this change does
nothing for.

### What the tour dropped, and why

The old tape ran nine visible commands with a pager quit after two of them and came in
around 25 s. `CORE_NO_PAGER` and `GIT_PAGER=cat` in the hidden setup remove the `q`
keystrokes; `cd -` and the trailing `clear` showed nothing; and `z dotfiles` went with
them, which is the one real loss — zoxide is a signature tool of this stack, but a
frecency *jump* reads as nothing much when the tape has already `cd`-ed to the repo it
is filming. If the clip ever gets a fifth slot, that is what should fill it.

## Keep it short — the ceiling is enforced

`make check-hero-size` (audit-core.sh §9k) weighs the file each tape's `Output` line
names and fails over **2 MiB**. A **missing** hero fails too where this repo is concerned —
`README.md`'s `[product-screenshot]` points at `assets/demo.gif`, so an absent file is a
broken front page, and a size gate that weighs nothing and reports green is the failure the
section exists to prevent. A *sibling's* absent gif is only a note: those nine are
deliberately un-rendered until the follow-up, and making that state red would leave
`make gen-hero-tape-fleet` permanently failing until nine gifs exist on nine boxes.

So that a skip is never mistaken for a pass, the summary line counts what it actually put
on the scale:

```text
✓ README hero size — 1 weighed, under the 2097152-byte ceiling; 9 not rendered yet (not covered by this run)
```

It is a **ceiling, not a target**, and it counts bytes rather than seconds — which are only
loosely related. The first shortened cut ran ~13 s against the old ~25 s and came out
**bigger** (2.46 MB vs 1.84 MB): GIF pays per changed pixel, and this tour has four
full-screen colour redraws where the old one had pager quits and a `clear`. Sleeps on a
static screen are nearly free.

So the levers, in order of effect per unit of ugliness:

| lever | where | cost to the viewer |
| ----- | ----- | ------------------ |
| `Set Framerate 24` | `hero.tape.in` | none — 50fps is twice what a terminal needs |
| `--colors 64` | the gifsicle pass | none — the palette is 20 colours plus antialiasing |
| fewer tour steps | `hero.tape.in` | real — each step is a marquee moment |
| smaller `Width`/`Height` | `hero.tape.in` | real — text gets smaller or wraps |

Reach for the first two before the last two.

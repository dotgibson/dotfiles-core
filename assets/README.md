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
boxes without one. If the GIF is heavy, optimize it:

```sh
gifsicle -O3 --lossy=80 assets/demo.gif -o assets/demo.gif
```

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
*has* a hero is the one nobody installs directly. `hero-repos.txt` already registers all
ten; `make gen-hero-tape-fleet` renders the other nine into their own checkouts. Their
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

It reads the capability; it never applies it. The registry's `proof` value is substituted
*inside* the template's `Type "…"`, so it must contain no double quote (it would close the
string early) and no `>` or `<` (a redirection in the shell VHS is driving). Those rules are
**enforced**, not just written here — `validate_registry` rejects them, along with a `.` row
that films any other registered repo, which is #698's original defect stated as a check.

The `# one verb → …` comment stays as the maintainer-facing half: it is derived from each
repo's own `os/*.capabilities` `PKG_UPGRADE`, so a tape can never *claim* a verb the repo
does not declare, even though only the `proof` line reaches the viewer.

Rendering and committing those nine gifs, and adding the hero block to each repo's
README, is #698's follow-up — sequenced after `os.capabilities` (#667).

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

2 MiB is a **ceiling, not a target**: the budget the tape header asks for is ~15 s, and one
heavy gif is a preference where ten is a policy. Every `Sleep` in `hero.tape.in` is paid for
in those bytes.

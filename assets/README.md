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
a box) on Tumbleweed. That is v5's thesis in three seconds, on the page a visitor
actually lands on. The trailing note is read from each repo's own
`os/*.capabilities` `PKG_UPGRADE`, so it can never claim a verb the repo does not declare.

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
names and fails over **2 MiB**. That is a ceiling, not a target: the budget the tape
header asks for is ~15 s, and one heavy gif is a preference where ten is a policy.
Every `Sleep` in `hero.tape.in` is paid for in those bytes.

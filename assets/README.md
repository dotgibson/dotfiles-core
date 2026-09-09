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

That last sentence is an instruction, and instructions get missed — #862 rewrote the tape
to film a `dotfiles-core` checkout and left the gif as the 2026-07-06 render of a
`dotfiles-MacBook` tree, so the front page kept showing the very thing #698 was filed
about. Nothing noticed, because §9j checks the tape against its template and §9k weighs
the gif's bytes, and neither ties one to the other:

```sh
make check-hero-render  # exit 1 if a committed gif predates the tape that renders it (audit-core.sh §9l runs this)
```

It dates the gif by **git history**, not mtime — mtime does not survive a clone — so a
tree without usable history skips loudly rather than passing green. An uncommitted gif
counts as freshly rendered; a modified tape beside an untouched gif is the defect.

It was a script and not a gate for one release on purpose: #870 landed it red, and greening
it needs `vhs` on a host matching the row, which CI is not. #877 re-rendered the gif and wired
the check in as §9l in the same change, so a rewritten tape can no longer ship over a stale hero.

## The render must not land in tmux

The hidden setup sources `~/.config/zsh/.zshrc` from inside vhs, which is an interactive TTY —
so an OS layer that auto-attaches tmux for interactive shells attaches **inside the recording**.
The `source` never returns, every later keystroke lands in the pane, the `cd` never happens,
and the gif films a tmux status bar over whatever directory the pane had. The first #877 render
came out exactly like that.

Every OS layer auto-attaches, so the tape exports the fleet's one opt-out **before** the source:

```sh
export CORE_NO_PAGER=1 GIT_PAGER=cat DOTFILES_NO_AUTOTMUX=1
```

`DOTFILES_NO_AUTOTMUX` was already honoured by MacBook, openSUSE and Gentoo; #877 made it all
seven (Debian keeps `DEBIAN_NO_TMUX` working alongside). And because a knob only helps on a
layer that reads it, `gen-hero-tape.sh` **refuses to render a row whose shell layer auto-attaches
without honouring it** (exit 2, the cannot-run leg) — scanning that repo's own `os/` and `zsh/`,
never the vendored `core/`, with comment lines dropped in both directions. The `.` row scans this
repo's `zsh/` the same way, so the check is never vacuous.

There is deliberately **no** `[[ -z $TMUX ]] || exit 1` after the source: if the knob were
ignored, that line would be typed into the attached pane, where `$TMUX` *is* set, and `exit 1`
there closes a shell in a real session. The generation-time check has no such failure mode.

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
README, was #698's follow-up — sequenced after `os.capabilities` (#667) and done as #948:
seven of the nine are filmed and committed in their repos. `dotfiles-openSUSE` waits on
#950 reaching its vendored `core/` (starship drew the openSUSE symbol as a lizard emoji,
which is tofu wherever no colour-emoji font is installed), and `dotfiles-MacBook` needs a
Mac — its guard asserts `brew upgrade`, and `up -n` probes `$PATH`, so no Linux box can
film it honestly.

**`dotfiles-Windows` is deliberately not registered**, which means those ten rows are not
the ten repos #698 counted: that list included Windows, and this covers nine of it. The
reason is the same one that keeps Windows out of `scripts/os-repos.txt` — its host layer is
replicated from scratch in PowerShell and it vendors no `core/`, so there is no `zsh` to
`Set Shell`, no `~/.config/zsh/.zshrc` to source, and no `up`, `ll` or `_core_cap` for the
shared body to type. A Windows hero needs its own tape and its own recorder, and that is
that repo's call, not this generator's. It remains the one public repo this change does
nothing for.

### Filming a sibling hero without its box

`@@HOSTGUARD@@` wants the distro, not the hardware. #948 filmed seven rows from one Fedora
box by giving each row a **rootless chroot** of its distro: the OCI base image's layers
pulled straight from Docker Hub with a 40-line registry client (no container runtime), unpacked
and entered under `unshare --user --map-user=0 --map-group=0 --map-auto` (root → you, 1…65535
→ your `/etc/subuid` block, so package managers can `chown`) plus `bwrap` for the mount
plumbing (`--proc`, a minimal `--dev`, `--perms 1777 --tmpfs /tmp` — apt's `_apt` user needs
the sticky bit — and `--unshare-uts --hostname <distro>`, which is what puts `@archlinux` in
the prompt). Inside: the distro's own `chromium` behind a `chromium` shim on `$PATH` that adds
`--no-sandbox` (the mount is `nosuid`, so neither Chromium's SUID helper nor `sudo` can work —
run the repo's `bootstrap.sh` as root with `HOME=/home/<user>`, then `chown -R`), the static
`vhs`/`ttyd`/`ffmpeg` release binaries (they run on musl too), and the Nerd Font under
`/usr/share/fonts`. Then film as the unprivileged user via `su`.

Five things the first renders got wrong, in the order they will bite again:

1. **The first interactive shell must not be the recording.** Core clones its zsh plugins on
   first run; that `installing zsh-transient-prompt@…` line lands in frame one. Warm up with
   `zsh -ic exit` as the user first.
2. **`❖` is not a Nerd Font glyph.** starship's prompt character (U+2756) falls back to a
   system font; a bare chroot has none and draws tofu. Ship the same fallback face the
   `dotfiles-core` hero used (Adwaita Sans on this box) plus an `/etc/fonts/conf.d` alias that
   prefers it, so every repo's `❖` is the same `❖`.
3. **`up -n` must finish inside the row's `sigwait`.** Fedora's `dnf --refresh check-update`
   re-validates every enabled repo's metadata against its mirror — 2–3 s warm, 7 s cold — so
   run `up -n` twice as the user immediately before filming; Portage resolves `emerge --pretend`
   in ~10 s however warm, which is why Gentoo's row carries `15s` and the default stays 4s.
   `checkupdates` on Arch exits 2 when nothing is pending, which Core (before #950) painted as
   a red ✗; three packages installed from the Arch Linux Archive gave the box real pending
   updates and a real list.
4. **Debian needs the atuin daemon running.** `os/debian.zsh` flips atuin's daemon on for the
   machine; with no `$XDG_RUNTIME_DIR` and no daemon, every prompt waits 4 s on the socket
   and the tour types over itself. Set `XDG_RUNTIME_DIR`, start `atuin daemon start` in the
   render session, and clear a stale `atuin-daemon.pid` first.
5. **Nothing in the render may edit the vendored `core/`.** A Core fix the hero needs but the
   repo has not synced yet (#951's `ZVM_INIT_MODE=sourcing` for Debian) goes in as an
   environment variable of the recording shell, and the PR says so.

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
section exists to prevent. A *sibling's* absent gif is only a note: a sibling's hero is
committed in *that* repo (its own §9l-equivalent is the same script run `--fleet`), and
making an absent one red here would leave `make gen-hero-tape-fleet` failing on any box
that has not rendered every row — which, by design, is every box.

So that a skip is never mistaken for a pass, the summary line counts what it actually put
on the scale:

```text
✓ README hero size — 8 weighed, under the 2097152-byte ceiling; 2 not rendered yet (not covered by this run)
```

It is a **ceiling, not a target**, and it counts bytes rather than seconds — which are only
loosely related. The first shortened cut ran ~13 s against the old ~25 s and came out
**bigger** (2.46 MB vs 1.84 MB): GIF pays per changed pixel, and this tour has four
full-screen colour redraws where the old one had pager quits and a `clear`. Sleeps on a
static screen are nearly free.

The first render of the current tape (#877, `Set Framerate 24`, ~16 s) measured **2.77 MB raw
and 1.19 MB after the gifsicle pass** — over the ceiling before optimization, comfortably under
it after. The pass is not a nicety; it is the difference between red and green.

So the levers, in order of effect per unit of ugliness:

| lever | where | cost to the viewer |
| ----- | ----- | ------------------ |
| `Set Framerate 24` | `hero.tape.in` | none — 50fps is twice what a terminal needs |
| the wait after the signature command | `hero-repos.txt` (`sigwait`, 4s default) | none — a static screen is nearly free; dnf needs ~3 s to answer, Portage ~10 s |
| `--colors 64` | the gifsicle pass | none — the palette is 20 colours plus antialiasing |
| fewer tour steps | `hero.tape.in` | real — each step is a marquee moment |
| smaller `Width`/`Height` | `hero.tape.in` | real — text gets smaller or wraps |

Reach for the first two before the last two.

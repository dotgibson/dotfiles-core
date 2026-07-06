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
boxes without one. Keep the clip short (~15s). If the GIF is heavy, optimize it:

```sh
gifsicle -O3 --lossy=80 assets/demo.gif -o assets/demo.gif
```

The README hero currently uses the `dotfiles-web` `og.svg` banner (which renders as-is).
Once you render `demo.gif` and commit it, swap the hero to it — point the
`[product-screenshot]` reference at the bottom of `README.md` at `assets/demo.gif`.

# Tool decisions — considered and declined

The register of tools Core **evaluated and did not adopt**, and why.

`/tool-scout`'s baseline (`PORTING-MATRIX.md`, `zsh/00-tools.zsh`, `zsh/20-aliases.zsh`,
`mise/config.toml`, `zsh/45-plugins.zsh`, `nvim/lazy-lock.json`) describes what Core **has**.
None of it records what Core **considered and declined**, so a rejected tool was
indistinguishable from one never evaluated — and a weekly scan re-proposed it on the next pass.

That is not a tidiness problem. A re-proposal arrives with a fresh case-for and **no
counter-argument attached**, so the decision gets re-made on half the evidence. `hexyl` was
ranked #3 "adopt" on 2026-08-18, six days after #395 closed it `NOT_PLANNED`; it would have been
adopted on that pass if the report had been actioned without someone happening to remember.

**This file is a required read for `/tool-scout`, and the routine must state, per candidate,
whether a prior decision exists.** Filing a decision is not enough if nothing reads it.

## How to use it

- **Scouting.** A candidate appearing below is not automatically dead — but it may only be
  re-proposed against the recorded reasoning, naming what changed. "It is good" is not what
  changed. A new maintainer, a new scan, or a new release note is not what changed either.
- **Deciding.** When an issue closes `NOT_PLANNED` on a tool, add a row here in the same pass.
  The GitHub issue holds the argument; this file is the index that makes it findable by the one
  process that would otherwise re-litigate it.
- **Reversing.** Adopting something listed here is fine. Move the row to "Reversed" with the
  issue that reversed it, so the trail survives.

## Declined

| tool | verdict | where | why, in one line |
| --- | --- | --- | --- |
| `hexyl` | role layer, not Core | [#395](https://github.com/dotgibson/dotfiles-core/issues/395) → [dotfiles-Kali#182](https://github.com/dotgibson/dotfiles-Kali/issues/182) | "Inspect a binary" leans engagement-flavoured and is low-frequency; fails `CONTRIBUTING.md`'s Core test |
| `fastgron` | skip | [#518](https://github.com/dotgibson/dotfiles-core/issues/518) | `gron` is dormant-but-**complete** and universally packaged; speed is not the binding constraint |

### `hexyl` — the long form

`CONTRIBUTING.md`'s test settles it: a thing is Core only if it is identical on every machine
**and** not OS-specific **and** not offensive/engagement tooling. If it changes when *the
operator* changes, it belongs in the role layer.

The case *for* was real and cheap — no binary-inspection verb exists anywhere in the stack,
0.17.0 is packaged everywhere (no `cargo` path on any target), zero config, no alias, inert
without the binary. It was declined anyway on frequency and flavour: the [#376] scan ranked it
*adopt-if-you-want* rather than a clear win, which is itself the signal that it is not
fleet-wide. If it only ever gets used on Kali, that is where the row goes.

**What would change the decision:** evidence of routine use outside an engagement context — not
a better `hexyl`.

[#376]: https://github.com/dotgibson/dotfiles-core/issues/376

### `fastgron` — the long form

Correctly skipped by the [#518] scan on its own initiative; recorded here because the scan
itself noted the reasoning should be written down "so a future scout doesn't re-litigate it".
`gron` has not shipped in a while, and that is not a defect: it is a *finished* tool with a
stable job and universal packaging. `fastgron` is faster, but nothing in this stack is bottlenecked
on `gron`'s throughput, and adopting it trades universal availability for a benchmark.

**What would change the decision:** `gron` actually breaking (a distro dropping it, or a bug
upstream declines to fix), not `fastgron` getting faster.

[#518]: https://github.com/dotgibson/dotfiles-core/issues/518

## Reversed

*None yet.*

## Scope — why only `/tool-scout` reads this

`/os-package-availability` and `/modernize` have the same weekly-scan-with-no-memory shape, but
both already carry a working in-band equivalent and do **not** need this file:

- `/os-package-availability` — the "intentionally excluded" convention: tools deliberately absent
  from `packages.txt` because they are not reliably packaged (starship, atuin, yazi — installed by
  bootstrap instead) are documented in comments **in the list itself**, and the routine is
  instructed not to flag them.
- `/modernize` — the floor it scouts against is declared in `scripts/modern-baseline.yml` and
  enforced by `scripts/check-modern.sh`. A rule already in force is machine-readable, so the
  routine cannot rediscover it.

`/tool-scout` was the outlier: its baseline is five files that all describe the shipped stack,
with nowhere for a negative decision to live. If either sibling later grows a decision that has
no in-band home, add it here rather than inventing a third mechanism.

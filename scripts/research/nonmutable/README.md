# scripts/research/nonmutable/ — R2 of the non-mutable host proposal (#1004)

Three **prototype** `os.capabilities` declarations, one per target family, written after
R1 measured what each host actually does (`NON-MUTABLE-HOST-PROPOSAL.md` §5). They are
**not** fleet declarations: no repo links them, the fleet's own files are untouched, and
the four keys they introduce are read by no consumer. They exist to answer R2's question
with files that validate rather than with prose.

| File | Family | Extends | What it settles |
| ---- | ------ | ------- | --------------- |
| `bootc.capabilities` | atomic (bootc, Silverblue) | `dotfiles-Fedora/os/fedora.capabilities` | the install and upgrade verbs stage; the count is a user-runnable exit status |
| `microos.capabilities` | transactional (MicroOS, Aeon) | `dotfiles-openSUSE/os/opensuse.capabilities` | `zypper in` is refused; `transactional-update` fits the existing keys once `PKG_APPLY` exists |
| `nixos.capabilities` | declarative (NixOS) | nothing yet — the repo does not exist | one required key has no truthful value and is made conditional |

Validate them exactly as a repo would:

```bash
for f in scripts/research/nonmutable/*.capabilities; do scripts/check-capabilities.sh "$f"; done
```

## The R2 question, and the verdict

**Does any required key end up a lie on any of the three hosts?** — with `PROVISIONER`
prototyped as an *optional* key and each declaration filled honestly.

- **`PKG_INSTALL` and `PKG_UPGRADE`** — on both atomic and transactional hosts the
  *mutable* verbs are refusals (measured: *"this bootc system is configured to be
  read-only"* after resolving 317 packages; *"Transactional system detected"* on every
  `zypper in`). The *honest* verbs — `rpm-ostree install --idempotent`,
  `transactional-update -n pkg in`, `rpm-ostree upgrade`, `transactional-update dup` —
  fit the existing keys and are non-interactive / interactive exactly as the schema asks.
  What they do not say is that the change is **staged**. So they are true only with a
  verb beside them that names the next step: **`PKG_APPLY`** (a reboot on both). One new
  optional key, and every consumer that runs an install or upgrade prints it afterwards.
  No required key changes meaning.
- **`PKG_COUNT_PENDING`** — on the atomic host the honest answer is an **exit status**
  (`rpm-ostree status --pending-exit-77`: 77 = a deployment is staged), which the
  schema's line-counting model and its `PKG_COUNT_EXIT_TRUSTED` rule both misread. Two
  new optional keys, **`PKG_PENDING_EXIT_SOME`** / **`PKG_PENDING_EXIT_NONE`**, say which
  status means what; the count becomes 0 or 1. On the declarative host there is **no
  truthful unprivileged verb at all** — "packages pending" is not a thing NixOS knows —
  so the key is **absent**, which the validator now permits under
  `PROVISIONER=declarative` and which `up` already handles (the silent `-1` sentinel).
  That is a validator rule, not a re-author for the nine.
- **Everything else** filled in truthfully on all three: `nix-env -i`/`-e` are the
  imperative install and remove a NixOS box does have (the documented anti-pattern, and
  persistent per user); `nix-locate` answers `PKG_OWNS` with the same "needs its
  metadata" caveat `dnf provides` has; `SCHEDULER=systemd` and a user unit directory
  work unchanged on all three (measured).

**Verdict: additive.** Four optional keys (`PROVISIONER`, `PKG_APPLY`,
`PKG_PENDING_EXIT_SOME`, `PKG_PENDING_EXIT_NONE`), one conditional relaxation
(`PKG_COUNT_PENDING` may be absent when `PROVISIONER=declarative`), and consumer changes
that branch on them. No required key changes meaning; every existing declaration
validates unchanged; the schema does not version and the nine repos do not re-author.
The major this proposal was written to plan does not come from the schema.

## What is still marked "to verify" inside the files

- bootc: `dnf search` on a booted host (only `dnf install` was probed); `rpm-ostree
  upgrade --check` against a registry-backed image (the research disk's origin is local).
  `rpm-ostree install --dry-run` as root is measured (exit 0, run 34852611338).
- MicroOS: `zypper -q list-updates` is measured on the guest (exit 0, run 34852611338);
  what remains is whether an `/etc` edit survives `transactional-update dup`.
- NixOS: whether `chsh` survives `nixos-rebuild switch`; `nix-locate` needs `nix-index`.

## What R2 hands to the next items

- **R3** (the Nix answer) — answered: **coexist**. `home.nix` beside this README is the
  measured module; the proposal's §5 R3 findings carry the verdict (home-manager owns
  packages, the login-shell declaration, tpm and PATH; the driver owns every link and the
  zsh entry, because home-manager tolerates the driver's links but cannot activate over
  its entry). `nixos.capabilities` keeps `nix-env` for the imperative verbs; on a
  home-manager box `core-doctor`'s hint says "add it to `home.packages`".
- **R4** (repo shape) — the bootstrap half is now a pair of real patches under `r4/`
  (`dotfiles-Fedora.patch`: 98 code lines in `bootstrap.sh` + the 18-line declaration
  delta; `dotfiles-openSUSE.patch`: 55 + 10), applied and run on the booted guests by
  `../nonmutable-variant.sh`; the proposal's §5 R4 findings carry the verdict. The
  declaration half was measured here first: against the fleet's own files (comment-stripped, sorted,
  `comm -3`): `bootc.capabilities` touches **12 keys** of `os/fedora.capabilities` (six
  verbs change, `PROVISIONER` / `PKG_APPLY` / `PKG_PENDING_EXIT_SOME` are added, the
  auto-confirm, partial-upgrade and pending-match keys go — 18 changed lines) and
  `microos.capabilities` touches **7 keys** of `os/opensuse.capabilities` (three verbs,
  two added, two gone — 10 lines). Small, but not "a line or two": the variant shape
  (one repo, a second declaration selected by `VARIANT_ID`/`ID`) is where this points,
  and R4 still diffs the bootstrap hooks before it decides.
- **The consumer change list** (R5/R6, and the proposal's §4 rewrite): `up` prints
  `PKG_APPLY` after a staged upgrade and counts by exit status when
  `PKG_PENDING_EXIT_*` is declared; `core-doctor`'s install hint says "layered — reboot to
  use" / "or declare it"; the driver's provision hook runs, then says the same; the maint
  runner never runs `PKG_APPLY`.

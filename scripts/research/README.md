# scripts/research/ — research apparatus: the atuin daemon guard (archived, #687) and the non-mutable host (archived, R1–R6, #1004)

These scripts answered a question once, and the answer is recorded. They are kept so the
question can be **re-asked on purpose**, not so it is re-asked on a clock.

- **`verify-atuin-guard.sh`** — the two upstream premises `_core_atuin_daemon_guard`
  (`zsh/00-tools.zsh`) rests on: silent discard over an unreachable socket, and autostart
  self-healing. Three-way verdict, `0` holds / `1` moved / `3` unmeasurable. Run it with
  `make verify-atuin-guard` or `make verify-atuin-guard-autostart`; `gh workflow run
  atuin-guard-verify` is the live-upstream, checksum-verified form.
- **`bench-atuin-daemon.sh`** — atuin write latency under contention, daemon off vs on,
  optionally through a transient systemd user unit. `make bench-atuin`,
  `make bench-atuin-systemd`.
- **`lib/atuin-db.sh`** — the one row-count SQL and WAL checkpoint both scripts read atuin's
  history DB with. Sourced, mode 100644, never run.

## The non-mutable host (archived, R1–R6, `NON-MUTABLE-HOST-PROPOSAL.md` §5, #1004)

**The phase is closed.** Every item R1–R6 asked is measured, R1's last three cells closed
on 2026-09-16 (#1052), the §4.6 runbook landed, and the proposal is now a SHIPPED record.
These scripts stay for the same reason `verify-atuin-guard.sh` does — so the question can
be **re-asked on purpose**. Nothing schedules them: both `research-nonmutable.yml` and
`research-nonmutable-vm.yml` are `workflow_dispatch` only, and neither is a gate.

- **`nonmutable-host.sh <bootc|microos|nixos>`** — runs a fleet repo's bootstrap
  **unchanged** on a non-mutable target and writes a Markdown report: what the host is
  (os-release, update tooling, which of `/usr` `/etc` `/var` is writable, escalator and
  login-shell machinery, the update verbs' exit codes), the probe-only paths against a
  throwaway `HOME`, the real run, and a table to fill in against the proposal's §3. Every
  probe is tolerant — a failing probe *is* the measurement. `gh workflow run
  research-nonmutable` runs it inside the three container images and uploads the reports;
  the VM legs (a booted bootc disk, an Aeon qcow2, `nixos-rebuild build-vm`) reuse the
  same script over ssh and are R1's real deliverable. Not scheduled, not a gate; the
  findings are read by a person and recorded in the proposal.

- **`nonmutable/*.capabilities`** — R2's three prototype declarations (bootc, MicroOS,
  NixOS), each validated by `scripts/check-capabilities.sh` with the six optional keys it
  accepts; `nonmutable/README.md` carries the R2 verdict (additive) and what each file
  still marks "to verify". Not fleet declarations; nothing links them — the three that
  ship are `dotfiles-Fedora/os/fedora.atomic.capabilities`,
  `dotfiles-openSUSE/os/opensuse.microos.capabilities` and
  `dotfiles-NixOS/os/nixos.capabilities`.

- **`nonmutable/home.nix`** + **`nonmutable-home-manager.sh`** — R3's probe: a
  home-manager module that tries to own what a fleet bootstrap wires (out-of-store links
  into the vendored `core/`, the packages, the zsh entry), and a script that applies it,
  inventories the home, runs the repo's `bootstrap.sh --links-only` OVER it and records
  the fight. `research-nonmutable.yml`'s `homemanager` leg runs it standalone on a
  mutable Fedora; the VM leg's NixOS guest gets it as a NixOS module. Adopt / coexist /
  reject is read off the reports — and was: coexist, `NON-MUTABLE-HOST-PROPOSAL.md` §5
  "R3 findings".

- **`nonmutable/r4/dotfiles-{Fedora,openSUSE}.patch`** + **`nonmutable-variant.sh`** — R4's
  probe: the "existing repo grows a variant" shape as two real patches against the
  siblings (a host marker, a second declaration relinked by `bootstrap_wire_pre_loader`,
  a staging path in the provision hook, a closing "reboot to apply" line), and a script the
  VM legs run on the booted guest with `r4=true`: apply, validate, dry-run, real run,
  reboot, re-run. The diff counts are the R4 measurement; the reports say whether the
  shape WORKS.

- **`nonmutable-r5.sh`** — R5's probe, on all three guests with `r5=true`: the AVAILABLE
  verbs (is something newer upstream — `rpm-ostree upgrade --check`, `bootc upgrade
  --check`, `zypper lu`, `transactional-update --dry-run`, a channel/flake check) and the
  STAGED verbs (is a change waiting for a reboot — `rpm-ostree status --pending-exit-77`,
  `/run/reboot-needed`, booted-vs-current on NixOS), each as the user and as root with its
  exit status, output shape and cost; then it stages something small and asks again, and
  runs Core's own `_pkgup_count` / nudge / `up -n` against the variant declaration to
  record what a user sees TODAY. The bootc leg first switches the guest to a registry-
  backed origin (a registry on the runner) so the upgrade checks have a real remote, and
  asks again after a v2 image is pushed under the same tag.

- **`nonmutable-r6.sh`** — R6's probe, inside each container image with `r6=true` on
  `research-nonmutable.yml`: the reusable `bootstrap-test.yml` legs' own recipes (lint,
  links-only with its assertions, the provision-stub shim set, `packages_check`'s
  resolver loop) run against the sibling with the R4 variant applied — plus the same
  stubbed run with `BOOTSTRAP_PROVISIONER=<atomic|transactional>` forced and the staging
  verbs shimmed, the seam a container needs to reach the staging path at all. The report
  is the CI matrix a target is born with and the list of what only a VM can test.

- **`nonmutable-r1-cells.sh`** — the three cells R1 left unmeasured (#1052), on the VM legs
  with `r1cells=true`: `PKG_SEARCH=dnf search` asked of a booted bootc host *before* any
  bootstrap has touched `/etc/yum.repos.d` (R1 probed only `dnf install`, a refusal, and
  only `dnf -q provides` in a container); `chsh` across a **second NixOS generation** built
  on the runner and activated over the shared `/nix/store`, because a `build-vm` guest
  carries no `configuration.nix` and that is why the cell was open; and an `/etc` edit
  across a real `transactional-update dup`, where the collision transactional-update(8)
  documents is forced by hand — a snapshot opened first, both halves written, then closed
  by the `dup` — so a no-op `dup` cannot empty the experiment. Two-phase on MicroOS (the
  reboot is the measurement); phase 2 fills in its own verdict table, including the guard
  that says **this round measured nothing** when the booted snapshot did not move.

## The rules

- **Never vendored.** None of this is in `core.manifest` or `core.vendor`, so no OS repo
  receives it (#676). The runtime guard itself stays in `zsh/00-tools.zsh` — that is the
  part with a job.
- **Never scheduled.** `.github/workflows/atuin-guard-verify.yml` is `workflow_dispatch`
  only. It ran weekly for months and the answer never moved; five checkouts a week were
  re-asking a settled question.
- **Re-measure when there is a reason.** An atuin release past the
  `CORE_ATUIN_GUARD_VERIFIED_AGAINST` / `CORE_ATUIN_AUTOSTART_VERIFIED_AGAINST` anchors in
  `zsh/00-tools.zsh`, or `/tool-scout` flagging one, is the cue. Editing an anchor is a
  claim that the premise was re-measured at that version — not a version bump.
- **Still gated.** `scripts/test-core.sh`'s `atuin` scope drives `verify-atuin-guard.sh`
  hermetically against stub binaries, and the workflow runs that self-test beside every
  measurement. It does not block the report jobs — a red self-test sits next to the
  verdict and says which of the two to believe, so a regressed detector is visible rather
  than trusted. The classifier treats `scripts/research/` as infra, so a change here pays
  for that self-test on push.

## Where the answers live

The measured numbers are in `atuin/config.toml`'s comments (the systemd-path latency
tables, #352) and the premise rationale in `zsh/00-tools.zsh` (#389, #402); the history is
in `CHANGELOG.md`.

# scripts/research/ — research apparatus: the atuin daemon guard (archived, #687) and the non-mutable host (R1, #1004)

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

## The non-mutable host (R1, `NON-MUTABLE-HOST-PROPOSAL.md` §5, #1004)

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
  NixOS), each validated by `scripts/check-capabilities.sh` with the four prototype keys
  it now accepts; `nonmutable/README.md` carries the R2 verdict (additive) and what each
  file still marks "to verify". Not fleet declarations; nothing links them.

- **`nonmutable/home.nix`** + **`nonmutable-home-manager.sh`** — R3's probe: a
  home-manager module that tries to own what a fleet bootstrap wires (out-of-store links
  into the vendored `core/`, the packages, the zsh entry), and a script that applies it,
  inventories the home, runs the repo's `bootstrap.sh --links-only` OVER it and records
  the fight. `research-nonmutable.yml`'s `homemanager` leg runs it standalone on a
  mutable Fedora; the VM leg's NixOS guest gets it as a NixOS module. Adopt / coexist /
  reject is read off the reports — and was: coexist, `NON-MUTABLE-HOST-PROPOSAL.md` §5
  "R3 findings".

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

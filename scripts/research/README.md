# scripts/research/ — the atuin daemon-guard research apparatus (archived, #687)

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

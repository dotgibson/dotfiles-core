# Makefile — a discoverable façade over the existing entry points.
# ──────────────────────────────────────────────────────────────────────────────
# This adds NO logic: every target shells out to the real script (scripts/*.sh,
# pre-commit), which stay the single source of truth. It exists so a newcomer can
# type `make` and see how to lint, test, audit, and sync — instead of grepping the
# README for scripts/ paths. The audit (`make audit`) is the one gate; CI and
# pre-commit call the same scripts/audit-core.sh, so `make audit` == green CI.
# ──────────────────────────────────────────────────────────────────────────────
.DEFAULT_GOAL := help
.PHONY: help setup doctor audit audit-changed test bench profile bench-gate bench-atuin bench-atuin-systemd verify-atuin-guard verify-atuin-guard-autostart lint sync sync-dry fleet-vocabulary fleet-release-triggers fleet-drift core-integrity parity-check freshness-dashboard hooks update-hooks update-plugins update-nvim-plugins update-tool-checksums check-pins check-modern gen-theme check-theme gen-aliases check-aliases gen-porting-matrix check-porting-matrix gen-desktop-parity check-desktop-parity gen-hero-tape gen-hero-tape-fleet check-hero-tape check-hero-size changelog-recent release tag publish release-notes

help: ## Show this help
	@echo "dotfiles-core — make targets:"
	@grep -E '^[a-z][a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) \
		| sed -E 's/:.*## /\t/' | sort | awk -F'\t' '{printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2}'

setup: ## One-command dev bootstrap (pre-commit hooks + version doctor + audit) — start here
	@./scripts/setup.sh

doctor: ## Read-only triage: are the dev tools present and matching the pins? (no install, no audit)
	@./scripts/setup.sh --doctor

audit: ## Run the full Core audit (manifest, exec-bits, syntax, lint, behavioral) — the one gate
	@./scripts/audit-core.sh

audit-changed: ## Audit only what your git diff touches (fast dev loop; same classifier as CI)
	@./scripts/audit-core.sh --changed

test: ## Run only the behavioral tests (scripts/test-core.sh, suite in scripts/test/)
	@./scripts/test-core.sh

bench: ## Benchmark Core's contribution to zsh startup (needs hyperfine; skips if absent)
	@./scripts/bench-core.sh

profile: ## Per-module zsh startup breakdown (attributes the total cost; slowest first)
	@./scripts/bench-core.sh --profile

bench-gate: ## Enforce the committed startup budget (scripts/bench-baseline.env) — exactly what CI's bench job runs
	@./scripts/bench-core.sh --gate

bench-atuin: ## [research] Measure atuin write latency, daemon off vs on, under contention (needs atuin; skips if absent)
	@./scripts/research/bench-atuin-daemon.sh

bench-atuin-systemd: ## [research] Same, but through a transient systemd user unit (skips without a user bus)
	@./scripts/research/bench-atuin-daemon.sh --systemd

verify-atuin-guard: ## [research] Re-measure the silent-discard premise _core_atuin_daemon_guard rests on (0 holds / 1 moved / 3 unmeasurable)
	@./scripts/research/verify-atuin-guard.sh

verify-atuin-guard-autostart: ## [research] Same three verdicts for the OTHER premise: does atuin self-heal its daemon under ATUIN_DAEMON__AUTOSTART? (SPAWNS a real daemon)
	@./scripts/research/verify-atuin-guard.sh --premise autostart

lint: audit ## Alias for `audit` (the audit IS the lint+test gate)

sync: ## Vendor Core into every OS repo (THE maintain button) — writes to sibling repos
	@./scripts/sync-core.sh

sync-dry: ## Show what `sync` would do, touching nothing
	@./scripts/sync-core.sh --dry-run

fleet-coverage: ## Which repo satisfies which reusable gate, and how (the coverage register)
	@./scripts/fleet-coverage.sh

fleet-vocabulary: ## Does every OS repo define the canonical `make` verbs and meet the test floor? (the vocabulary register)
	@./scripts/fleet-vocabulary.sh

fleet-release-triggers: ## Does every OS repo release its OWN work, and can it cut a non-patch? (the release-trigger register)
	@./scripts/fleet-release-triggers.sh

fleet-drift: ## Report which OS repos (+ Windows) lag the latest RELEASED Core tag — the vendoring-drift dashboard
	@./scripts/fleet-drift.sh

fleet-protection: ## Does a RULESET actually bind main in every repo? (--migrate/--retire to fix)
	@./scripts/fleet-protection.sh

core-integrity: ## Verify every OS repo's vendored core/ is pristine (not hand-edited) vs its core.lock
	@./scripts/core-integrity.sh

parity-check: ## Verify PARITY.md's aligned rows hold across zsh + pwsh (needs sibling dotfiles-Windows)
	@./scripts/parity-check.sh

freshness-dashboard: ## Compose the weekly fleet-health board (drift + integrity + pins) as markdown
	@./scripts/freshness-dashboard.sh

hooks: ## Install the pre-commit hooks into this clone
	@command -v pre-commit >/dev/null 2>&1 || { echo "pre-commit not found: pip install pre-commit"; exit 1; }
	@pre-commit install

update-hooks: ## Bump pinned pre-commit hook revisions to upstream latest (pre-commit autoupdate)
	@command -v pre-commit >/dev/null 2>&1 || { echo "pre-commit not found: pip install pre-commit"; exit 1; }
	@pre-commit autoupdate

update-plugins: ## Roll the pinned zsh-plugin SHAs in zsh/45-plugins.zsh to upstream HEAD (deliberate bump)
	@./scripts/update-plugins.sh

update-nvim-plugins: ## Roll the pinned nvim plugin commits in nvim/lazy-lock.json forward (deliberate bump)
	@./scripts/update-nvim-plugins.sh

update-tool-checksums: ## Recompute the pinned CI tool SHA-256s in tool-versions.env after a version bump
	@./scripts/update-tool-checksums.sh

check-pins: ## Report whether the zsh-plugin, nvim and theme pins are behind upstream (the weekly freshness gate)
	@./scripts/update-plugins.sh --check && ./scripts/update-nvim-plugins.sh --check && ./scripts/gen-theme.sh --refresh --check

check-modern: ## Check CI meets the modern floor (scripts/modern-baseline.yml) — also run inside `make audit`
	@./scripts/check-modern.sh

gen-theme: ## Regenerate every themed config from theme/palette.toml (the ONE place a colour is edited)
	@./scripts/gen-theme.sh

check-theme: ## Report whether any generated config has drifted from theme/palette.toml — also run inside `make audit`
	@./scripts/gen-theme.sh --check

gen-aliases: ## Regenerate aliases.md's tables from the zsh alias sources (edit the alias, not the table)
	@./scripts/gen-aliases.sh

check-aliases: ## Report whether aliases.md's tables have drifted from the zsh sources — also run inside `make audit`
	@./scripts/gen-aliases.sh --check

gen-porting-matrix: ## Regenerate PORTING-MATRIX.md's two tables from the sibling OS repos (edit the repo, not the table)
	@./scripts/gen-porting-matrix.sh

check-porting-matrix: ## Report whether PORTING-MATRIX.md's tables have drifted from the OS repos — also run inside `make audit`
	@./scripts/gen-porting-matrix.sh --check

gen-desktop-parity: ## Render desktop/PARITY.shared.md into both desktop repos' PARITY.md (edit the source, not the copies)
	@./scripts/gen-desktop-parity.sh

check-desktop-parity: ## Report whether either desktop repo's PARITY.md has drifted from desktop/PARITY.shared.md — also run inside `make audit` (exits 3, non-zero, if a desktop repo is not checked out beside this one)
	@./scripts/gen-desktop-parity.sh --check

gen-hero-tape: ## Regenerate this repo's README hero tape from assets/hero.tape.in (edit the template, not the tape)
	@./scripts/gen-hero-tape.sh

gen-hero-tape-fleet: ## Also render the nine OS/role repos' hero tapes into their checkouts (#698's follow-up; needs the fleet beside this repo)
	@./scripts/gen-hero-tape.sh --fleet

check-hero-tape: ## Report whether assets/demo.tape has drifted from its template — also run inside `make audit`
	@./scripts/gen-hero-tape.sh --check

check-hero-size: ## Report whether a rendered README hero is over the byte ceiling — also run inside `make audit`
	@./scripts/gen-hero-tape.sh --check-size

changelog-recent: ## Regenerate the vendored 8-release CHANGELOG digest (`make release` runs this too)
	@./scripts/gen-changelog-recent.sh

release: ## Cut a release: bump core.version + CHANGELOG, run the audit (usage: make release VERSION=X.Y.Z)
	@./scripts/release.sh $(VERSION)

tag: ## Release phase 1: commit core.version + CHANGELOG (creates NO tag — see publish)
	@./scripts/tag-release.sh

publish: ## Release phase 2: tag origin/main + push, AFTER the release PR has merged
	@./scripts/tag-release.sh --publish

release-notes: ## Draft a GitHub Release body from Conventional Commits since the last release (needs git-cliff)
	@command -v git-cliff >/dev/null 2>&1 || { echo "git-cliff not found: cargo install git-cliff (or scoop/pkg). Config: cliff.toml"; exit 1; }
	@_from=$$(git log --grep='^release v' --format=%H -1); \
	  if [ -n "$$_from" ]; then git-cliff "$$_from..HEAD"; else git-cliff; fi

# scripts/audit/50-config-docs.sh
# toml / yaml / json parse, and markdownlint over the docs
#
# A SOURCED FRAGMENT of scripts/audit-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: the PASS/SKIP/FAIL counters, $HERE (already cd'd
# to), the SCOPE_* flags, META_ALLOWLIST/META_PREFIXES, MANIFEST_PATHS/VENDOR_PATHS (parsed
# by 10-manifest.sh, §1), and the pass/skip/skip_env/fail/fail_detail/hdr/have helpers from
# scripts/lib/common.sh. NO EXIT TRAP HERE: the dispatcher installs the one that reaps the
# backgrounded behavioral suite, and `trap … EXIT` REPLACES rather than appends. The §-ids
# below are the STABLE gate ids — CLAUDE.md, CONTRIBUTING.md, VENDORING.md, PORTABILITY.md
# and the CHANGELOG all cite them — and the split did not renumber one; the NN- in this
# file's name carries run order only. See the header of scripts/audit-core.sh for the
# contract.

# ── 6. config files (toml / yaml parse) ──────────────────────────────────────
# A malformed starship.toml / mise config.toml / ci.yml is still valid *text* —
# so zsh -n and shellcheck never look at it — yet it breaks every one of the 9
# consumers at runtime (dead prompt, dead runtime manager, dead CI). Assert that
# every tracked TOML and YAML file actually PARSES. Best-effort + graceful skip,
# exactly like the linters above: TOML via python3 `tomllib` (stdlib since 3.11),
# YAML via python3 PyYAML when importable. pre-commit's check-toml/check-yaml are
# the hermetic author-time mirror of this same gate.
hdr "config files (toml / yaml)"
if have python3 && python3 -c 'import tomllib' 2>/dev/null; then
  while IFS= read -r f; do
    if python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' "$f" 2>/dev/null; then
      pass "toml $f"
    else fail "toml parse error: $f"; fi
  done < <(_audit_ls '*.toml' '*.toml.example')
else
  skip "toml parse (python3 tomllib unavailable — needs python ≥3.11)"
fi
if have python3 && python3 -c 'import yaml' 2>/dev/null; then
  while IFS= read -r f; do
    # safe_load_all: workflow/compose YAML can be multi-document (--- separators).
    if python3 -c 'import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))' "$f" 2>/dev/null; then
      pass "yaml $f"
    else fail "yaml parse error: $f"; fi
  done < <(_audit_ls '*.yml' '*.yaml')
else
  skip "yaml parse (python3 PyYAML not importable)"
fi
# JSON: nvim/lazy-lock.json pins every Neovim plugin's commit for a reproducible
# editor across the nine Core-vendoring repos — a truncated/corrupt lock breaks
# `:Lazy restore` for all of them, and like the toml/yaml above it's valid *text*
# the other gates skip.
# `*.json` (not `*.jsonc`) so the JSONC config files keep their comments. json is in
# the stdlib, so this only needs python3 — no extra import gate like PyYAML.
if have python3; then
  while IFS= read -r f; do
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null; then
      pass "json $f"
    else fail "json parse error: $f"; fi
  done < <(_audit_ls '*.json')
else
  skip "json parse (python3 unavailable)"
fi

# ── 7. markdown (markdownlint) ────────────────────────────────────────────────
# The docs ARE the deliverable on a public showcase repo, and they're the one file
# class shellcheck/zsh -n/toml-yaml never look at — so a leaked template tag or a
# broken heading ships unnoticed (it did: see CHANGELOG.md's history). markdownlint
# is the gate; .markdownlint.jsonc is the shared rule config (line-length off for
# the wide tables, everything structural on). Graceful skip when absent, exactly
# like the linters above; pre-commit's markdownlint-cli2 hook is the author-time
# mirror, and CI installs it so the gate actually runs there.
hdr "markdown (markdownlint)"
# Resolve a RUNNABLE markdownlint WITHOUT requiring it on PATH — the npm global bin
# frequently lands off PATH, making this the most-skipped gate in remote sessions even
# when the tool IS installed. Prefer a PATH binary; else `npx --no-install` (resolves a
# global/local install with NO network fetch); else a repo-local node_modules bin. Only a
# genuinely-absent tool still skips — which --strict (a fully-provisioned CI leg) then catches.
_mdl=()
if have markdownlint-cli2; then
  _mdl=(markdownlint-cli2)
elif have npx && npx --no-install markdownlint-cli2 --version >/dev/null 2>&1; then
  _mdl=(npx --no-install markdownlint-cli2)
elif [[ -x node_modules/.bin/markdownlint-cli2 ]]; then
  _mdl=(node_modules/.bin/markdownlint-cli2)
fi
if ((${#_mdl[@]})); then
  if md_out="$("${_mdl[@]}" "**/*.md" 2>&1)"; then
    pass "markdownlint (all tracked markdown clean)"
  else
    fail "markdownlint reported issues — run: markdownlint-cli2 '**/*.md'"
    fail_detail "$md_out"
  fi
else
  skip "markdownlint (markdownlint-cli2 not installed — npm i -g markdownlint-cli2)"
fi

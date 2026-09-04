# scripts/test/41-gen-matrix-parity.sh
# porting-matrix + desktop-bar parity generation (gen-porting-matrix.sh, gen-desktop-parity.sh)
#
# A SOURCED FRAGMENT of scripts/test-core.sh — not a standalone script. It runs in the
# dispatcher's shell and uses its state: PASS/SKIP/FAIL, $SANDBOX, $HERE, the SCOPE_*
# flags, and the pass/skip/fail/hdr/have helpers from scripts/lib/common.sh. See the
# header of scripts/test-core.sh for the contract.

# Fragments embed zsh code as single-quoted literals on purpose: the `$…` inside them
# must be expanded by the zsh CHILD, not by this bash parent. SC2016 is therefore a
# false positive file-wide, exactly as it is in the dispatcher.
# shellcheck disable=SC2016

# ── porting-matrix generation (scripts/gen-porting-matrix.sh) ────────────────
# PORTING-MATRIX.md's two data tables are rendered from the sibling OS repos and
# audit-core.sh §9h gates the result — as an ENVIRONMENT skip when the siblings are not
# checked out, which is what CI's lone checkout looks like, so nothing in the real gate
# ever exercises a red. Everything worth pinning therefore lives here: the drift
# direction (1), the cannot-answer direction (2), and the uncovered direction (3), told
# apart on purpose because the audit maps each to a different verdict.
#
# The fixture is a stub Core tree (the two marker pairs, hand-authored lines either
# side) and a fake FLEET: seven sibling directories, each with a .git so it resolves
# like a checkout, minimal os/*.capabilities, and install/packages.txt files
# SYNTHESISED FROM THE SCRIPT'S OWN PKG_ROWS — the first candidate of every derived cell,
# so the registry is the thing under test (the aliases generator's argument, in
# scripts/test/40-gen-theme-aliases.sh, for using the real zsh
# sources). Debian's file carries the tiers and floors the real one does, and the fixture
# ships a copy of pkg_filter_lines because the generator sources the repo's own filter.
#
# The REPOSITORY SCRIPT is run with --root AND --fleet from a third directory, so the
# documented fixture mechanism is what is exercised (the same rule the aliases generator
# in scripts/test/40-gen-theme-aliases.sh follows).
if have git; then
  hdr "porting-matrix generation (scripts/gen-porting-matrix.sh)"
  GPR="$SANDBOX/matrixrepo"
  GPF="$SANDBOX/matrixfleet"
  _gp_ids="$(awk -F'"' '/^BLOCK_IDS=/ { print $2 }' "$HERE/scripts/gen-porting-matrix.sh")"
  # The closing quote is the terminator: test for it BEFORE stripping it, or the read runs
  # on into the rest of the generator and any later tab-separated line becomes a row.
  _gp_rows="$(awk '/^PKG_ROWS="/ { f = 1; sub(/^PKG_ROWS="/, "") } f { if (/"$/) { sub(/"$/, ""); print; f = 0 } else print }' "$HERE/scripts/gen-porting-matrix.sh")"

  _gp_caps() { # _gp_caps <file> <prefix> — a minimal declaration whose verbs all start with <prefix>
    printf 'PKG_REFRESH=%s refresh\nPKG_UPGRADE=%s upgrade\nPKG_INSTALL=%s install\nPKG_REMOVE=%s remove\nPKG_SEARCH=%s search\nPKG_OWNS=%s owns\nPKG_COUNT_PENDING=%s pending\nSCHEDULER=none\n' \
      "$2" "$2" "$2" "$2" "$2" "$2" "$2" >"$1"
  }
  _gp_fixture() {
    local r
    rm -rf "$GPR" "$GPF"
    mkdir -p "$GPR"
    {
      printf '# fixture matrix\n\nhand-authored above the first block\n\n'
      for _id in $_gp_ids; do
        printf '<!-- core:porting-matrix:gen %s -->\n<!-- core:porting-matrix:end %s -->\n\n' "$_id" "$_id"
      done
      printf 'hand-authored below the last block\n'
    } >"$GPR/PORTING-MATRIX.md"
    for r in MacBook Fedora Arch openSUSE Alpine Gentoo Debian; do
      mkdir -p "$GPF/dotfiles-$r/.git" "$GPF/dotfiles-$r/os" "$GPF/dotfiles-$r/install" "$GPF/dotfiles-$r/scripts"
    done
    _gp_caps "$GPF/dotfiles-MacBook/os/macos.capabilities" brew
    _gp_caps "$GPF/dotfiles-Fedora/os/fedora.capabilities" dnf
    _gp_caps "$GPF/dotfiles-Arch/os/arch.capabilities" pacman
    _gp_caps "$GPF/dotfiles-openSUSE/os/opensuse.capabilities" zypper
    _gp_caps "$GPF/dotfiles-openSUSE/os/opensuse.leap.capabilities" zypper
    _gp_caps "$GPF/dotfiles-Alpine/os/alpine.capabilities" apk
    _gp_caps "$GPF/dotfiles-Gentoo/os/gentoo.capabilities" emerge
    _gp_caps "$GPF/dotfiles-Debian/os/debian.capabilities" apt
    _gp_caps "$GPF/dotfiles-Debian/os/debian.kali.capabilities" apt
    # The Leap/Tumbleweed pair disagrees on exactly one verb; one value carries a pipe.
    sed -i.bak 's/^PKG_UPGRADE=zypper upgrade$/PKG_UPGRADE=zypper dup/' "$GPF/dotfiles-openSUSE/os/opensuse.capabilities" && rm -f "$GPF/dotfiles-openSUSE/os/opensuse.capabilities.bak"
    sed -i.bak 's/^PKG_SEARCH=apk search$/PKG_SEARCH=apk search -v|cat/' "$GPF/dotfiles-Alpine/os/alpine.capabilities" && rm -f "$GPF/dotfiles-Alpine/os/alpine.capabilities.bak"
    # The tier filter the generator sources: the same function dotfiles-Debian ships.
    cat >"$GPF/dotfiles-Debian/scripts/pkg-filter.sh" <<'PF'
pkg_filter_lines() {
  local file="$1" id="$2" line list
  [[ -f "$file" && -r "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ \#[[:space:]]*only:([A-Za-z0-9_,-]+) ]]; then
      list=",${BASH_REMATCH[1]},"
      [[ "$list" == *",$id,"* ]] || continue
    fi
    if [[ "$line" =~ \#[[:space:]]*skip:([A-Za-z0-9_,-]+) ]]; then
      list=",${BASH_REMATCH[1]},"
      [[ "$list" == *",$id,"* ]] && continue
    fi
    printf '%s\n' "$line"
  done <"$file"
}
PF
    # packages.txt per column, from the registry: header prose, a commented-out entry
    # and a continuation line first (the parser must skip all three), then one line per
    # derived cell. Gentoo names are atoms; Debian's one file serves Kali AND Debian.
    for r in Arch openSUSE Alpine Gentoo Debian; do
      printf '# fixture list\n# ── section ──\n# rust-analyzer  # commented out on purpose\nfixture-only-pkg  # continuation follows\n                  # …continued\n\n' >"$GPF/dotfiles-$r/install/packages.txt"
    done
    # A skip:ubuntu line on a package NO row claims: the Debian/Ubuntu column is read
    # under both IDs, and a split the table does not render must be harmless.
    printf 'fixture-debian-only  # skip:ubuntu — not a matrix row\n' >>"$GPF/dotfiles-Debian/install/packages.txt"
    awk -F'\t' -v fleet="$GPF" '
      function tool(l) { sub(/[^A-Za-z0-9._+-].*/, "", l); return l }
      function dname(cell, cand,  n) {
        if (substr(cell, 1, 1) != "=") return ""
        n = substr(cell, 2); sub(/[^A-Za-z0-9._+\/-].*/, "", n)
        return (n != "") ? n : cand
      }
      NF == 8 {
        c = ($2 == "-") ? tool($1) : $2; sub(/ .*/, "", c); t = tool($1)
        floor = (t == "neovim") ? " min:0.12.0" : ""
        a = dname($3, c); o = dname($4, c); al = dname($5, c); g = dname($6, c); k = dname($7, c); d = dname($8, c)
        # Output targets PARENTHESISED: gawk reads `>> fleet "/x"` as one file name, but
        # BSD awk (the macOS leg) and mawk (the Ubuntu leg) stop at `fleet` — the
        # fixture lists came out empty there and every derived cell failed as unmatched.
        if (a != "") print a "  # " t >> (fleet "/dotfiles-Arch/install/packages.txt")
        if (o != "") print o "  # " t >> (fleet "/dotfiles-openSUSE/install/packages.txt")
        if (al != "") print al "  # " t >> (fleet "/dotfiles-Alpine/install/packages.txt")
        if (g != "") print "fx-cat/" g "  # bin:" t floor >> (fleet "/dotfiles-Gentoo/install/packages.txt")
        deb = fleet "/dotfiles-Debian/install/packages.txt"
        if (k != "" && k == d) print k "  # " t >> deb
        else {
          if (k != "") print k "  # only:kali" floor " " t >> deb
          if (d != "") print d "  # skip:kali " t >> deb
        }
      }' <<EOF
$_gp_rows
EOF
  }
  # Run from $SANDBOX, not from $GPR or the repo: proves --root/--fleet, not the cwd, pick the trees.
  _gp_run() { (cd "$SANDBOX" && env -u CORE_JSON bash "$HERE/scripts/gen-porting-matrix.sh" --root "$GPR" --fleet "$GPF" "$@" >/dev/null 2>&1; echo $?); }
  _gp_out() { (cd "$SANDBOX" && env -u CORE_JSON bash "$HERE/scripts/gen-porting-matrix.sh" --root "$GPR" --fleet "$GPF" "$@" 2>&1); }
  _gp_row() { grep -qF -- "$1" "$GPR/PORTING-MATRIX.md"; }

  _gp_fixture
  _gp_gen_rc="$(_gp_run)"
  if [[ "$_gp_gen_rc" == 0 ]]; then
    pass "gen-porting-matrix: renders a fixture tree + fleet clean"
  else
    fail "gen-porting-matrix: bare run failed on a clean fixture (rc=$_gp_gen_rc): $(_gp_out | head -n 3)"
  fi
  if [[ "$(_gp_run --check)" == 0 ]]; then
    pass "gen-porting-matrix: --check is 0 on a freshly generated tree"
  else
    fail "gen-porting-matrix: --check reported drift on its own output"
  fi

  # The RENDERED BYTES, one row per rule.
  if _gp_row '`neovim` ≥ 0.12.0' && _gp_row '`fx-cat/neovim` ≥ 0.12.0'; then
    pass "gen-porting-matrix: a # min: floor renders as ≥ on the derived cell (Debian and Gentoo grammars)"
  else
    fail "gen-porting-matrix: the neovim floor did not render"
  fi
  if grep -E '^\| neovim³³ .*\| asset²⁸ +\|$' "$GPR/PORTING-MATRIX.md" >/dev/null; then
    pass "gen-porting-matrix: an only:kali line reaches the Kali column and not Debian/Ubuntu"
  else
    fail "gen-porting-matrix: the neovim row's Debian cell is not the registry's asserted asset²⁸"
  fi
  if _gp_row 'Leap: `zypper upgrade` · Tumbleweed: `zypper dup`'; then
    pass "gen-porting-matrix: a two-declaration column renders both values, labelled"
  else
    fail "gen-porting-matrix: the openSUSE upgrade cell did not render both declarations"
  fi
  if _gp_row '`zypper refresh`' && ! _gp_row 'Leap: `zypper refresh`'; then
    pass "gen-porting-matrix: a two-declaration column renders an agreed value once, unlabelled"
  else
    fail "gen-porting-matrix: an agreed value was rendered twice or labelled"
  fi
  if _gp_row '`emerge install <atom>`' && _gp_row '`apt install <pkg>`' && _gp_row '`brew owns <path>`³⁸'; then
    pass "gen-porting-matrix: placeholders follow the column's unit and the footnote marks follow the cell"
  else
    fail "gen-porting-matrix: a placeholder or a cell mark is missing from the commands table"
  fi
  if _gp_row '`apk search -v\|cat <term>`'; then
    pass "gen-porting-matrix: escapes | inside a cell as \\|"
  else
    fail "gen-porting-matrix: a pipe inside a declared value was not escaped — the table would break"
  fi
  if grep -E '^\| Tool +\| Arch +\| openSUSE +\| Alpine +\| Gentoo \(atom\) +\| Kali \(apt\)²¹ᵃ +\| Debian/Ubuntu +\|$' "$GPR/PORTING-MATRIX.md" >/dev/null &&
    grep -E '^\| -+ \| -+ \| -+ \| -+ \| -+ \| -+ \| -+ \|$' "$GPR/PORTING-MATRIX.md" >/dev/null; then
    pass "gen-porting-matrix: the table is emitted in prettier's aligned form"
  else
    fail "gen-porting-matrix: the header or delimiter row is not aligned"
  fi
  _gp_list_out="$(_gp_out --list)"
  if grep -q "^packages	neovim	kali	derived	dotfiles-Debian/install/packages.txt:[0-9]" <<<"$_gp_list_out" &&
    grep -q '^packages	neovim	debian	asserted	' <<<"$_gp_list_out" && grep -q '^commands	install	gentoo	derived	' <<<"$_gp_list_out" &&
    grep -q '^commands	upgrade	opensuse	derived	dotfiles-openSUSE/os/opensuse.leap.capabilities dotfiles-openSUSE/os/opensuse.capabilities$' <<<"$_gp_list_out"; then
    pass "gen-porting-matrix: --list names each cell's provenance, derived cells by file:line, both declarations of a two-file column"
  else
    fail "gen-porting-matrix: --list is missing a derived, an asserted or a commands row"
  fi

  # NEGATIVE — drift INSIDE a block exits 1, names the file and the fix, and writes nothing.
  _gp_fixture && _gp_run >/dev/null
  sed -i.bak 's/| `eza`             |/| `exa`             |/' "$GPR/PORTING-MATRIX.md" && rm -f "$GPR/PORTING-MATRIX.md.bak"
  _gp_drift_rc="$(_gp_run --check)"
  _gp_drift_out="$(_gp_out --check)"
  if [[ "$_gp_drift_rc" == 1 ]] && grep -q 'PORTING-MATRIX.md' <<<"$_gp_drift_out" && grep -q 'make gen-porting-matrix' <<<"$_gp_drift_out"; then
    pass "gen-porting-matrix: --check exits 1 on drift inside a block and names the file and the fix"
  else
    fail "gen-porting-matrix: drift inside a block was not reported as 1 with the fix (rc=$_gp_drift_rc)"
  fi
  _gp_before="$(git hash-object "$GPR/PORTING-MATRIX.md")"
  _gp_run --check >/dev/null
  if [[ "$(git hash-object "$GPR/PORTING-MATRIX.md")" == "$_gp_before" ]]; then
    pass "gen-porting-matrix: --check writes nothing, even to a drifted file"
  else
    fail "gen-porting-matrix: --check REPAIRED a drifted file — the gate can never be red"
  fi

  # THE ISSUE'S OWN VERIFICATION (#686): a package renamed in one repo, nothing regenerated.
  _gp_fixture && _gp_run >/dev/null
  sed -i.bak 's/^yq  # yq$/go-yq  # yq/' "$GPF/dotfiles-Arch/install/packages.txt" && rm -f "$GPF/dotfiles-Arch/install/packages.txt.bak"
  if [[ "$(_gp_run --check)" == 1 ]]; then
    pass "gen-porting-matrix: a package renamed to another candidate in one repo is drift (1)"
  else
    fail "gen-porting-matrix: renaming yq → go-yq in the Arch fixture was not reported as drift"
  fi
  sed -i.bak 's/^go-yq  # yq$/nonsense  # yq/' "$GPF/dotfiles-Arch/install/packages.txt" && rm -f "$GPF/dotfiles-Arch/install/packages.txt.bak"
  _gp_gone_out="$(_gp_out --check)"
  if [[ "$(_gp_run --check)" == 2 ]] && grep -q 'yq / arch: no line in dotfiles-Arch/install/packages.txt installs it' <<<"$_gp_gone_out"; then
    pass "gen-porting-matrix: a package renamed to an unknown name fails --check with 2 and is named"
  else
    fail "gen-porting-matrix: a derived cell with no package behind it was not caught as 2 by name"
  fi
  # A bumped floor is drift, not structure.
  _gp_fixture && _gp_run >/dev/null
  sed -i.bak 's/min:0.12.0/min:0.13.0/' "$GPF/dotfiles-Debian/install/packages.txt" && rm -f "$GPF/dotfiles-Debian/install/packages.txt.bak"
  if [[ "$(_gp_run --check)" == 1 ]]; then
    pass "gen-porting-matrix: a bumped # min: floor without regeneration is drift (1)"
  else
    fail "gen-porting-matrix: a floor bump in the Debian fixture was not reported as drift"
  fi
  # The OTHER half of the table: a repo starts installing an ASSERTED tool.
  _gp_fixture && _gp_run >/dev/null
  printf 'lnav  # now packaged\n' >>"$GPF/dotfiles-Arch/install/packages.txt"
  _gp_flip_out="$(_gp_out --check)"
  if [[ "$(_gp_run --check)" == 2 ]] && grep -q 'lnav / arch is asserted as' <<<"$_gp_flip_out" && grep -q 'change the cell to =' <<<"$_gp_flip_out"; then
    pass "gen-porting-matrix: a repo installing an asserted tool fails --check with 2 and names the cell to flip"
  else
    fail "gen-porting-matrix: an asserted cell the repo now installs went unreported"
  fi
  # A tiered line that reaches the WRONG column is a registry mismatch, not silence.
  _gp_fixture && _gp_run >/dev/null
  sed -i.bak 's/^neovim  # only:kali/neovim  # /' "$GPF/dotfiles-Debian/install/packages.txt" && rm -f "$GPF/dotfiles-Debian/install/packages.txt.bak"
  _gp_tier_out="$(_gp_out --check)"
  if [[ "$(_gp_run --check)" == 2 ]] && grep -q 'neovim / debian is asserted as' <<<"$_gp_tier_out"; then
    pass "gen-porting-matrix: dropping only:kali makes the line reach Debian, where the cell is asserted — caught (2)"
  else
    fail "gen-porting-matrix: a tier change that contradicts an asserted cell went unreported"
  fi
  # The Debian/Ubuntu column is ONE cell for two IDs: a skip:ubuntu on a claimed package
  # is a split the cell cannot show, so it is a refusal naming the tier — never a cell that
  # reads as shared because the debian pass saw the line.
  _gp_fixture && _gp_run >/dev/null
  sed -i.bak 's/^eza  # eza$/eza  # skip:ubuntu eza/' "$GPF/dotfiles-Debian/install/packages.txt" && rm -f "$GPF/dotfiles-Debian/install/packages.txt.bak"
  _gp_split_out="$(_gp_out --check)"
  if [[ "$(_gp_run --check)" == 2 ]] && grep -q 'eza / debian: the ubuntu tier does not install it but another tier of the same column does' <<<"$_gp_split_out"; then
    pass "gen-porting-matrix: a skip:ubuntu on a claimed package is a refusal (2) naming the tier, not a shared-looking cell"
  else
    fail "gen-porting-matrix: a Debian/Ubuntu tier split rendered or went unnamed (out: $(head -n 1 <<<"$_gp_split_out"))"
  fi
  # A declaration missing a required verb cannot render.
  _gp_fixture && _gp_run >/dev/null
  sed -i.bak '/^PKG_OWNS=/d' "$GPF/dotfiles-Arch/os/arch.capabilities" && rm -f "$GPF/dotfiles-Arch/os/arch.capabilities.bak"
  _gp_key_out="$(_gp_out --check)"
  if [[ "$(_gp_run --check)" == 2 ]] && grep -q 'arch declares no PKG_OWNS' <<<"$_gp_key_out"; then
    pass "gen-porting-matrix: a declaration missing a verb is a structural failure (2), named"
  else
    fail "gen-porting-matrix: a missing PKG_* key was not caught as 2"
  fi

  # UNCOVERED — a sibling not checked out is 3, names the repo, and writes nothing.
  _gp_fixture && _gp_run >/dev/null
  rm -rf "$GPF/dotfiles-Gentoo"
  _gp_before="$(git hash-object "$GPR/PORTING-MATRIX.md")"
  _gp_miss_out="$(_gp_out --check)"
  if [[ "$(_gp_run --check)" == 3 && "$(_gp_run)" == 3 ]] && grep -q 'not checked out under .*: dotfiles-Gentoo' <<<"$_gp_miss_out" &&
    [[ "$(git hash-object "$GPR/PORTING-MATRIX.md")" == "$_gp_before" ]]; then
    pass "gen-porting-matrix: an absent sibling is 3 (uncovered) in both modes, named, and nothing is written"
  else
    fail "gen-porting-matrix: an absent sibling was not reported as 3 — or the doc was touched"
  fi
  if [[ "$(cd "$SANDBOX" && env -u CORE_JSON bash "$HERE/scripts/gen-porting-matrix.sh" --root "$GPR" --fleet "$SANDBOX/nowhere" --check >/dev/null 2>&1; echo $?)" == 3 ]]; then
    pass "gen-porting-matrix: a fleet root with no siblings at all is 3, not 2 and not clean"
  else
    fail "gen-porting-matrix: an empty fleet root did not exit 3"
  fi
  # …but a BROKEN DOCUMENT on that same lone checkout is still the structural 2: the
  # markers are this repo's own, so they are validated before any sibling is looked for,
  # and audit-core.sh §9h must never file a deleted marker under "not covered".
  _gp_fixture && _gp_run >/dev/null
  sed -i.bak '/^<!-- core:porting-matrix:end packages -->$/d' "$GPR/PORTING-MATRIX.md" && rm -f "$GPR/PORTING-MATRIX.md.bak"
  _gp_lone_out="$(cd "$SANDBOX" && env -u CORE_JSON bash "$HERE/scripts/gen-porting-matrix.sh" --root "$GPR" --fleet "$SANDBOX/nowhere" --check 2>&1)"
  if [[ "$(cd "$SANDBOX" && env -u CORE_JSON bash "$HERE/scripts/gen-porting-matrix.sh" --root "$GPR" --fleet "$SANDBOX/nowhere" --check >/dev/null 2>&1; echo $?)" == 2 ]] &&
    grep -q 'packages has 1 gen marker(s) but 0 end marker(s)' <<<"$_gp_lone_out"; then
    pass "gen-porting-matrix: a broken marker is 2 even with no siblings — structure is checked before coverage"
  else
    fail "gen-porting-matrix: a broken marker on a lone checkout was filed as uncovered (3) instead of structural (2)"
  fi

  # An edit OUTSIDE the markers is not drift and survives regeneration.
  _gp_fixture && _gp_run >/dev/null
  printf 'a hand-authored line added after generation\n' >>"$GPR/PORTING-MATRIX.md"
  if [[ "$(_gp_run --check)" == 0 ]]; then
    pass "gen-porting-matrix: an edit OUTSIDE a block is not drift"
  else
    fail "gen-porting-matrix: --check fired on a hand-authored line outside the markers"
  fi
  _gp_run >/dev/null
  if grep -q 'a hand-authored line added after generation' "$GPR/PORTING-MATRIX.md" &&
    grep -q 'hand-authored above the first block' "$GPR/PORTING-MATRIX.md"; then
    pass "gen-porting-matrix: regeneration preserves hand-authored content outside blocks"
  else
    fail "gen-porting-matrix: regeneration ate a hand-authored line"
  fi
  # …including a blank line at the very end of the file: `$(…)` strips trailing newlines,
  # so without the sentinel this read as drift and regeneration deleted it.
  _gp_fixture && _gp_run >/dev/null
  printf '\n' >>"$GPR/PORTING-MATRIX.md"
  _gp_before="$(git hash-object "$GPR/PORTING-MATRIX.md")"
  _gp_run >/dev/null
  if [[ "$(_gp_run --check)" == 0 && "$(git hash-object "$GPR/PORTING-MATRIX.md")" == "$_gp_before" ]]; then
    pass "gen-porting-matrix: a trailing blank line outside the markers is neither drift nor eaten"
  else
    fail "gen-porting-matrix: a trailing blank line at EOF was reported as drift or removed by regeneration"
  fi

  # Markers are the mechanism.
  _gp_fixture && _gp_run >/dev/null
  sed -i.bak '/^<!-- core:porting-matrix:end packages -->$/d' "$GPR/PORTING-MATRIX.md" && rm -f "$GPR/PORTING-MATRIX.md.bak"
  if [[ "$(_gp_run --check)" == 2 ]]; then
    pass "gen-porting-matrix: a deleted end marker is a structural failure (2), not drift"
  else
    fail "gen-porting-matrix: an unterminated block was not reported as 2"
  fi
  _gp_fixture && _gp_run >/dev/null
  sed -i.bak -e '/core:porting-matrix:gen packages/d' -e '/core:porting-matrix:end packages/d' "$GPR/PORTING-MATRIX.md" && rm -f "$GPR/PORTING-MATRIX.md.bak"
  _gp_gone_out="$(_gp_out --check)"
  if [[ "$(_gp_run --check)" == 2 ]] && grep -q 'registered block is missing: packages' <<<"$_gp_gone_out"; then
    pass "gen-porting-matrix: a registered block whose region was deleted is caught by name"
  else
    fail "gen-porting-matrix: deleting a block's marker pair went unreported"
  fi
  _gp_fixture && _gp_run >/dev/null
  printf '<!-- core:porting-matrix:end commands -->\n' >>"$GPR/PORTING-MATRIX.md"
  _gp_stray_out="$(_gp_out --check)"
  if [[ "$(_gp_run --check)" == 2 ]] && grep -q 'commands has 1 gen marker(s) but 2 end marker(s)' <<<"$_gp_stray_out"; then
    pass "gen-porting-matrix: a stray duplicate end marker is a structural failure (2), named"
  else
    fail "gen-porting-matrix: a duplicated end marker was accepted as prose"
  fi
  _gp_fixture && _gp_run >/dev/null
  printf '<!-- core:porting-matrix:gen nope -->\n<!-- core:porting-matrix:end nope -->\n' >>"$GPR/PORTING-MATRIX.md"
  _gp_unreg_out="$(_gp_out --check)"
  if [[ "$(_gp_run --check)" == 2 ]] && grep -q 'unregistered gen marker: nope' <<<"$_gp_unreg_out"; then
    pass "gen-porting-matrix: an unregistered marker pair is caught by name"
  else
    fail "gen-porting-matrix: an unregistered marker pair was accepted"
  fi
  _gp_fixture && _gp_run >/dev/null
  sed -i.bak -e '/core:porting-matrix:gen /d' -e '/core:porting-matrix:end /d' "$GPR/PORTING-MATRIX.md" && rm -f "$GPR/PORTING-MATRIX.md.bak"
  printf '<!-- core:porting-matrix:gen commands -->\n<!-- core:porting-matrix:gen packages -->\n<!-- core:porting-matrix:end commands -->\n<!-- core:porting-matrix:end packages -->\n' >>"$GPR/PORTING-MATRIX.md"
  _gp_cross_out="$(_gp_out --check)"
  _gp_before="$(git hash-object "$GPR/PORTING-MATRIX.md")"
  if [[ "$(_gp_run --check)" == 2 && "$(_gp_run)" == 2 ]] && grep -q "opens inside the 'commands' region" <<<"$_gp_cross_out" &&
    [[ "$(git hash-object "$GPR/PORTING-MATRIX.md")" == "$_gp_before" ]]; then
    pass "gen-porting-matrix: crossed marker pairs are a structural failure (2) in both modes, and nothing is written"
  else
    fail "gen-porting-matrix: crossed marker pairs were accepted"
  fi
  # …and still 2 with NO siblings: the counts pass on a crossed pair, so only a walk before
  # fleet resolution keeps it out of the environment-skip bucket on a lone checkout.
  _gp_cross_lone_out="$(cd "$SANDBOX" && env -u CORE_JSON bash "$HERE/scripts/gen-porting-matrix.sh" --root "$GPR" --fleet "$SANDBOX/nowhere" --check 2>&1)"
  if [[ "$(cd "$SANDBOX" && env -u CORE_JSON bash "$HERE/scripts/gen-porting-matrix.sh" --root "$GPR" --fleet "$SANDBOX/nowhere" --check >/dev/null 2>&1; echo $?)" == 2 ]] &&
    grep -q "opens inside the 'commands' region" <<<"$_gp_cross_lone_out"; then
    pass "gen-porting-matrix: crossed marker pairs are 2 even with no siblings — order is walked before coverage"
  else
    fail "gen-porting-matrix: crossed marker pairs on a lone checkout were filed as uncovered (3) instead of structural (2)"
  fi

  # IDEMPOTENCE.
  _gp_fixture && _gp_run >/dev/null
  cp "$GPR/PORTING-MATRIX.md" "$GPR/PORTING-MATRIX.first.md"
  _gp_run >/dev/null
  if core_files_identical "$GPR/PORTING-MATRIX.first.md" "$GPR/PORTING-MATRIX.md"; then
    pass "gen-porting-matrix: generation is idempotent (second run is byte-identical)"
  else
    fail "gen-porting-matrix: a second run changed PORTING-MATRIX.md — --check can never be stably green"
  fi

  rm -rf "$GPR" "$GPF"
  unset GPR GPF _gp_ids _gp_rows _gp_gen_rc _gp_drift_rc _gp_drift_out _gp_before _gp_gone_out _gp_flip_out _gp_tier_out _gp_key_out _gp_miss_out _gp_stray_out _gp_unreg_out _gp_cross_out _gp_list_out _gp_lone_out _gp_split_out _gp_cross_lone_out
fi

# ── desktop-bar parity generation (scripts/gen-desktop-parity.sh) ─────────────
# The Zebar ↔ sketchybar contract is authored once in desktop/PARITY.shared.md and rendered
# between markers into two targets that sit OUTSIDE any vendored core/ — dotfiles-MacBook does
# vendor Core, but sketchybar/PARITY.md is its own OS-layer file; dotfiles-Windows vendors no
# core/ at all. Either way this repo cannot reach them, so the only place the behaviour can be
# pinned hermetically is here: the weekly cross-repo job is the wrong feedback loop for
# "does exit 3 still mean an absent sibling".
#
# The fixture fleet gives dotfiles-Windows a `.git` DIRECTORY and dotfiles-MacBook a `.git`
# FILE on purpose — the presence test is `-e`, so a worktree/submodule checkout (where .git
# is a file) must be accepted exactly like a normal clone.
#
# SRC is always the repository's real desktop/PARITY.shared.md (the script resolves it from
# its own location, and there is no --src override), so these tests exercise the shipped
# source against fixture TARGETS rather than a synthetic pair.
hdr "desktop-bar parity generation (scripts/gen-desktop-parity.sh)"
DPF="$SANDBOX/desktopfleet"
DPW="$DPF/dotfiles-Windows/desktop/PARITY.md"
DPM="$DPF/dotfiles-MacBook/sketchybar/PARITY.md"
_dp_addendum="hand-authored below the block, never generated"

_dp_fixture() { # _dp_fixture [--no-macbook|--macbook-not-a-repo]
  rm -rf "$DPF"
  mkdir -p "$DPF/dotfiles-Windows/desktop" "$DPF/dotfiles-Windows/.git"
  {
    printf '<!-- desktop-parity:gen -->\n<!-- desktop-parity:end -->\n'
    printf '\n## Host-specific addenda (Windows) — `deliberate`\n\n%s\n' "$_dp_addendum"
  } >"$DPW"
  case "${1:-}" in
  --no-macbook) return 0 ;;
  --macbook-not-a-repo) # a plain directory that merely SHARES the repo name
    mkdir -p "$DPF/dotfiles-MacBook/sketchybar"
    return 0
    ;;
  esac
  mkdir -p "$DPF/dotfiles-MacBook/sketchybar"
  printf 'gitdir: /nowhere\n' >"$DPF/dotfiles-MacBook/.git" # a worktree's .git is a FILE
  printf '<!-- desktop-parity:gen -->\n<!-- desktop-parity:end -->\n' >"$DPM"
}
_dp_run() { (cd "$SANDBOX" && env -u CORE_JSON bash "$HERE/scripts/gen-desktop-parity.sh" --root "$DPF" "$@" >/dev/null 2>&1; echo $?); }
_dp_run_root() { local r="$1"; shift; (cd "$SANDBOX" && env -u CORE_JSON bash "$HERE/scripts/gen-desktop-parity.sh" --root "$r" "$@" >/dev/null 2>&1; echo $?); }
_dp_out() { (cd "$SANDBOX" && env -u CORE_JSON bash "$HERE/scripts/gen-desktop-parity.sh" --root "$DPF" "$@" 2>&1); }

# POSITIVE — a clean render, and --check green on its own output.
_dp_fixture
if [[ "$(_dp_run)" == 0 ]] && grep -q 'Bar parity contract' "$DPW" && grep -q 'Bar parity contract' "$DPM"; then
  pass "gen-desktop-parity: renders the shared block into both fixture repos"
else
  fail "gen-desktop-parity: bare run did not render both copies: $(_dp_out | head -n 3)"
fi
if [[ "$(_dp_run --check)" == 0 ]]; then
  pass "gen-desktop-parity: --check is 0 on a freshly generated tree"
else
  fail "gen-desktop-parity: --check reported drift on its own output"
fi

# The two rendered blocks must be BYTE-IDENTICAL — that is the entire contract.
_dp_blk() { sed -n '/^<!-- desktop-parity:gen -->$/,/^<!-- desktop-parity:end -->$/p' "$1"; }
if [[ "$(_dp_blk "$DPW")" == "$(_dp_blk "$DPM")" ]]; then
  pass "gen-desktop-parity: the block is byte-identical in both repos"
else
  fail "gen-desktop-parity: the two rendered blocks differ — the pair is not actually in sync"
fi

# Hand-authored text OUTSIDE the markers is never touched: it is where a host puts an
# addendum with no counterpart on the other bar (Windows' psmux note).
if grep -qF "$_dp_addendum" "$DPW"; then
  pass "gen-desktop-parity: content outside the markers survives a render"
else
  fail "gen-desktop-parity: the hand-authored addendum was clobbered — deliberate divergences cannot live outside the block"
fi

# NEGATIVE — drift INSIDE a block exits 1, names the file and the fix.
_dp_fixture && _dp_run >/dev/null
sed -i.bak 's/| cpu  *| 0–49/| cpu | 0–99/' "$DPM" && rm -f "$DPM.bak"
_dp_drift_out="$(_dp_out --check)"
if [[ "$(_dp_run --check)" == 1 ]] && grep -q 'sketchybar/PARITY.md' <<<"$_dp_drift_out" && grep -q 'make gen-desktop-parity' <<<"$_dp_drift_out"; then
  pass "gen-desktop-parity: --check exits 1 on a one-sided edit and names the file and the fix"
else
  fail "gen-desktop-parity: a one-sided edit did not red — this is the #693 failure mode"
fi

# Editing OUTSIDE the markers is not drift.
_dp_fixture && _dp_run >/dev/null
printf '\n- another hand-authored Windows-only line.\n' >>"$DPW"
if [[ "$(_dp_run --check)" == 0 ]]; then
  pass "gen-desktop-parity: --check ignores edits outside the markers"
else
  fail "gen-desktop-parity: an edit to the hand-authored region was reported as drift"
fi

# An ABSENT sibling is an environment skip (3), never a green 0 over an un-inspected copy.
# Render FIRST, so the copy that IS present is clean: otherwise its empty markers drift and
# the sticky severity correctly returns 1, which would test the wrong thing.
_dp_fixture --no-macbook && _dp_run >/dev/null
if [[ "$(_dp_run --check)" == 3 ]] && grep -q 'not checked out under' <<<"$(_dp_out --check)"; then
  pass "gen-desktop-parity: an absent sibling exits 3 (environment skip), not 0"
else
  fail "gen-desktop-parity: an absent sibling did not report the uncovered-copy exit 3"
fi
# ...and --strict turns that skip into a real failure, which is what CI relies on.
if [[ "$(_dp_run --check --strict)" == 1 ]]; then
  pass "gen-desktop-parity: --strict makes an absent sibling a failure"
else
  fail "gen-desktop-parity: --strict did not red on an absent sibling — CI would pass over a repo it never read"
fi

# A plain directory that merely SHARES the repo name is NOT a checkout: skip it, do not red
# on the PARITY.md it does not have. This is why the presence test is `-e <dir>/.git`.
_dp_fixture --macbook-not-a-repo && _dp_run >/dev/null
if [[ "$(_dp_run --check)" == 3 ]]; then
  pass "gen-desktop-parity: a same-named directory with no .git is skipped, not a false red"
else
  fail "gen-desktop-parity: a directory without .git was treated as a checkout (rc=$(_dp_run --check))"
fi

# Severity is STICKY: real drift outranks an absent sibling, so a half-checked-out fleet
# still reds instead of reporting the softer environment skip.
_dp_fixture --no-macbook && _dp_run >/dev/null
sed -i.bak 's/Bar parity contract/Bar parity CONTRACT/' "$DPW" && rm -f "$DPW.bak"
if [[ "$(_dp_run --check)" == 1 ]]; then
  pass "gen-desktop-parity: drift (1) outranks an absent sibling (3)"
else
  fail "gen-desktop-parity: drift was masked by the absent-sibling exit code"
fi

# MALFORMED MARKERS in a checked-out repo FAIL rather than skip — an unmarked copy is the
# drift being gated, not an absence. (gen-views.sh skips one; its target list is opt-in.)
_dp_fixture && grep -v 'desktop-parity:end' "$DPM" >"$DPM.tmp" && mv "$DPM.tmp" "$DPM"
if [[ "$(_dp_run --check)" == 1 ]] && grep -q 'exactly one' <<<"$(_dp_out --check)"; then
  pass "gen-desktop-parity: a missing end marker fails and says so"
else
  fail "gen-desktop-parity: a copy with no end marker was skipped instead of failing"
fi
_dp_fixture && printf '<!-- desktop-parity:end -->\n<!-- desktop-parity:gen -->\n' >"$DPM"
if [[ "$(_dp_run --check)" == 1 ]] && grep -q 'before' <<<"$(_dp_out --check)"; then
  pass "gen-desktop-parity: markers in the wrong order fail"
else
  fail "gen-desktop-parity: an end-before-gen marker pair was accepted"
fi

# IDEMPOTENCE — a second render must be byte-identical, or --check can never be stably green.
_dp_fixture && _dp_run >/dev/null
cp "$DPW" "$DPF/win.first.md"
_dp_run >/dev/null
if core_files_identical "$DPF/win.first.md" "$DPW"; then
  pass "gen-desktop-parity: generation is idempotent (second run is byte-identical)"
else
  fail "gen-desktop-parity: a second run changed the file — --check can never be stably green"
fi

# THE CI STEP MUST RUN THE READ-ONLY MODE. Without --check the generator writes into the
# throwaway clones and exits 0 — a gate that can never fail, which is precisely the
# "reported green having checked nothing" shape this change exists to remove. The flag was
# in fact missing on first review, so it is pinned here rather than trusted.
if grep -qE '^[[:space:]]*\./scripts/gen-desktop-parity\.sh .*--check' "$HERE/.github/workflows/parity-check.yml"; then
  pass "gen-desktop-parity: parity-check.yml invokes the generator with --check"
else
  fail "gen-desktop-parity: parity-check.yml runs the generator WITHOUT --check — the weekly gate would rewrite the clones and always pass"
fi

# THE VERDICT MUST NOT DEPEND ON DIFFUTILS. `cmp`/`diff` ship in diffutils, which is not
# guaranteed present — a Tumbleweed box in this fleet had neither — and a missing binary
# exits non-zero, which is indistinguishable from "the files differ". That is how a
# lockfile that never moved was reported as drift (#572). Shadow both with always-failing
# stubs: identical files must still verify as identical.
_dp_shim="$SANDBOX/nodiffutils"
mkdir -p "$_dp_shim"
for _b in diff cmp; do printf '#!/bin/sh\nexit 127\n' >"$_dp_shim/$_b"; chmod +x "$_dp_shim/$_b"; done
_dp_fixture && _dp_run >/dev/null
_dp_nodiff_rc="$( (cd "$SANDBOX" && PATH="$_dp_shim:$PATH" env -u CORE_JSON bash "$HERE/scripts/gen-desktop-parity.sh" --root "$DPF" --check >/dev/null 2>&1; echo $?) )"
if [[ "$_dp_nodiff_rc" == 0 ]]; then
  pass "gen-desktop-parity: --check verdict survives a host with no working diff/cmp"
else
  fail "gen-desktop-parity: a broken diff/cmp turned matching files into drift (rc=$_dp_nodiff_rc) — the verdict must use core_files_identical"
fi

# A WRITE THAT CANNOT HAPPEN MUST NOT REPORT SUCCESS. Nothing here runs under `set -e`, so
# an unchecked render or install prints "rewritten" and exits 0 over a stale file.
# Skipped as root, where the mode bits below do not bite.
if [[ "${EUID:-$(id -u)}" != 0 ]]; then
  _dp_fixture
  chmod a-w "$DPF/dotfiles-Windows/desktop"
  _dp_ro_rc="$(_dp_run)"
  _dp_ro_out="$(_dp_out)"
  chmod u+w "$DPF/dotfiles-Windows/desktop"
  if [[ "$_dp_ro_rc" == 1 ]] && ! grep -q 'rewritten' <<<"$_dp_ro_out"; then
    pass "gen-desktop-parity: an unwritable target fails instead of claiming it was rewritten"
  else
    fail "gen-desktop-parity: a write that could not happen was reported as success (rc=$_dp_ro_rc)"
  fi
  unset _dp_ro_rc _dp_ro_out
else
  skip "gen-desktop-parity: unwritable-target check (running as root)"
fi

# The render temp is a sibling of the target, so it must never be left behind — a stray
# PARITY.md.gen.XXXXXX in someone's clone is litter the gate itself would then read.
# TMPDIR is pointed INTO the fixture and BOTH names are searched, because the two modes put
# their temp in different places: --check under ${TMPDIR:-/tmp}/gen-desktop-parity.XXXXXX,
# write mode beside the target as PARITY.md.gen.XXXXXX. The first version of this assertion
# scanned only $DPF for the write-mode name while exercising --check, so it could not see the
# file it claimed to guard — deleting every `rm -f "$tmp"` in the generator left it green.
# A cleanup test that cannot fail is the same defect as the gate this PR was filed to fix.
_dp_fixture && _dp_run >/dev/null
sed -i.bak 's/Bar parity contract/Bar parity CONTRACT/' "$DPM" && rm -f "$DPM.bak"
(cd "$SANDBOX" && TMPDIR="$DPF" env -u CORE_JSON bash "$HERE/scripts/gen-desktop-parity.sh" --root "$DPF" --check >/dev/null 2>&1)
_dp_litter="$(find "$DPF" \( -name '*.gen.??????' -o -name 'gen-desktop-parity.??????' \) 2>/dev/null)"
if [[ -z "$_dp_litter" ]]; then
  pass "gen-desktop-parity: leaves no temp file behind, on the drift path or in TMPDIR"
else
  fail "gen-desktop-parity: left a temp file behind: $_dp_litter"
fi
unset _dp_litter

# A REGENERATION MUST NOT CHANGE THE FILE MODE. mktemp creates 0600 and `mv` preserves it,
# so the atomic install would quietly turn a tracked, world-readable PARITY.md into an
# owner-only file on every run. git stores 100644; match it.
_dp_fixture && chmod 0644 "$DPW" "$DPM" && _dp_run >/dev/null
_dp_mode="$(( $(stat -c '%a' "$DPW" 2>/dev/null || stat -f '%Lp' "$DPW" 2>/dev/null) ))"
if [[ "$_dp_mode" == 644 ]]; then
  pass "gen-desktop-parity: a regenerated copy keeps mode 0644"
else
  fail "gen-desktop-parity: regeneration left the target as $_dp_mode — mktemp's 0600 survived the rename"
fi
unset _dp_mode

# An explicitly EMPTY --root is a usage error, not a silent resolve under /dotfiles-*.
if [[ "$(_dp_run_root '' --check)" == 2 ]]; then
  pass "gen-desktop-parity: --root '' is a usage error, not a silent gate over /dotfiles-*"
else
  fail "gen-desktop-parity: --root '' was accepted and resolved targets outside the fleet"
fi

# NO GIT MUST FAIL CLOSED. core_files_identical compares `git hash-object` outputs, so with
# git absent BOTH sides are empty and compare EQUAL — a drifted copy would read as clean and
# --check would pass having compared nothing. The guard must exit 2 instead.
_dp_nogit="$SANDBOX/nogitbin"
mkdir -p "$_dp_nogit"
for _b in bash sh env sed awk grep mktemp mv rm cat cut tr printf chmod stat find sort comm diff dirname basename head tail wc uname id; do
  _p="$(command -v "$_b" 2>/dev/null)" && ln -sf "$_p" "$_dp_nogit/$_b"
done
if [[ -x "$_dp_nogit/bash" ]] && ! PATH="$_dp_nogit" command -v git >/dev/null 2>&1; then
  _dp_fixture && _dp_run >/dev/null
  _dp_nogit_rc="$( (cd "$SANDBOX" && PATH="$_dp_nogit" env -u CORE_JSON "$_dp_nogit/bash" "$HERE/scripts/gen-desktop-parity.sh" --root "$DPF" --check >/dev/null 2>&1; echo $?) )"
  if [[ "$_dp_nogit_rc" == 2 ]]; then
    pass "gen-desktop-parity: with no git the gate fails closed (2) instead of comparing nothing"
  else
    fail "gen-desktop-parity: with no git the gate returned $_dp_nogit_rc — core_files_identical compares two empty hashes and FAILS OPEN"
  fi
  unset _dp_nogit_rc
else
  skip "gen-desktop-parity: no-git guard (could not build a git-free PATH on this box)"
fi

# AN UNREADABLE SOURCE MUST NOT DESTROY THE TARGETS. awk's `getline` returns -1 on a read
# error, which `> 0` cannot distinguish from EOF — so an unguarded loop renders an EMPTY
# block and exits 0, and write mode installs that over a valid PARITY.md while reporting
# success. Reproduced against a COPY of the script in its own fake repo root (HERE is derived
# from the script's location), so no tracked file is ever chmod-ed. Skipped as root, where
# mode 000 does not bite.
if [[ "${EUID:-$(id -u)}" != 0 ]]; then
  _dp_fake="$SANDBOX/fakecore"
  mkdir -p "$_dp_fake/scripts" "$_dp_fake/desktop"
  cp "$HERE/scripts/gen-desktop-parity.sh" "$_dp_fake/scripts/"
  ln -sf "$HERE/scripts/lib" "$_dp_fake/scripts/lib"
  cp "$HERE/desktop/PARITY.shared.md" "$_dp_fake/desktop/PARITY.shared.md"
  chmod 000 "$_dp_fake/desktop/PARITY.shared.md"
  _dp_fixture && _dp_run >/dev/null # both copies valid and up to date first
  _dp_before="$(cat "$DPW")"
  _dp_unread_rc="$( (cd "$SANDBOX" && env -u CORE_JSON bash "$_dp_fake/scripts/gen-desktop-parity.sh" --root "$DPF" >/dev/null 2>&1; echo $?) )"
  chmod 644 "$_dp_fake/desktop/PARITY.shared.md"
  if [[ "$_dp_unread_rc" != 0 ]] && [[ "$(cat "$DPW")" == "$_dp_before" ]]; then
    pass "gen-desktop-parity: an unreadable source fails and leaves the target untouched"
  else
    fail "gen-desktop-parity: an unreadable source returned $_dp_unread_rc and/or rewrote the target with an empty block"
  fi
  unset _dp_fake _dp_before _dp_unread_rc
else
  skip "gen-desktop-parity: unreadable-source check (running as root)"
fi

rm -rf "$DPF"
unset DPF DPW DPM _dp_addendum _dp_drift_out _dp_shim _dp_nodiff_rc _dp_nogit

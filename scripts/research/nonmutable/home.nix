# scripts/research/nonmutable/home.nix — R3 of NON-MUTABLE-HOST-PROPOSAL.md (#1004):
# the home-manager module that tries to own what a fleet bootstrap wires. NOT a shipped
# config: it exists to be applied on a real NixOS and on a mutable host, and to have the
# driver run over the result, so the proposal can say "adopt / coexist / reject" from a
# measurement rather than a preference.
#
# WHAT IT REPRODUCES (blib_link_core + blib_link_os_layer + blib_write_zshrc_loader, by
# the same destinations):
#   · every Core zsh fragment  → $XDG_CONFIG_HOME/zsh/<name>.zsh   (out-of-store symlinks
#     into the VENDORED core/, so the fleet's provenance model — core/ is the source, the
#     lock is the record — is untouched; home-manager owns the link, not the bytes)
#   · the OS layer             → zsh/80-os.zsh, zsh/os.capabilities
#   · nvim, tmux, starship, gitconfig, lazygit, atuin, jujutsu, tealdeer
#   · mise/config.toml SEEDED as a copy (a store symlink would be read-only under
#     `mise use -g`, which rewrites it — the same reason blib_adopt copies it)
#   · tpm — a rev-pinned fetch, not an unpinned git clone at bootstrap time
#   · the packages the OS repo would install, as nixpkgs attributes
#   · PATH: ~/.local/bin, ~/.cargo/bin
#   · the zsh ENTRY — and this is the contested item. Core's driver writes a managed
#     ~/.zshrc (the v4 numbered-fragment glob) and seeds $ZDOTDIR/.zshrc → ~/.zshrc.
#     home-manager's zsh module wants to own the same files. Here it is told to write
#     $ZDOTDIR/.zshrc itself with the same loader line — so the two definitions of "the
#     entry" meet on disk, and the probe records who wins.
#
# WHAT IT CANNOT OWN, by construction (the measurement is expected to confirm):
#   · the login shell — NixOS: users.users.<name>.shell (system config); mutable hosts:
#     chsh. home-manager has no hook for either.
#   · the core/ pre-commit guard — an activation script could, but it is a git hook in a
#     checkout, not a home file.
#   · core-doctor, the capability contract, `up` — those are Core zsh; nothing to own.
#
# PARAMETERS come from the environment at evaluation (impure, deliberately — this is a
# probe, not a flake):
#   DOTFILES_REPO   the OS repo checkout the GUEST sees (link targets)       default ~/dotfiles
#   DOTFILES_BUILD  the same checkout where this file is EVALUATED (readDir) default = DOTFILES_REPO
#   DOTFILES_OS     the os/<os>.zsh basename                                 default fedora
{ config, pkgs, lib, ... }:
let
  env = name: default: let v = builtins.getEnv name; in if v == "" then default else v;
  home = config.home.homeDirectory;
  repo = env "DOTFILES_REPO" "${home}/dotfiles";
  build = env "DOTFILES_BUILD" repo;
  os = env "DOTFILES_OS" "fedora";
  core = "${repo}/core";
  coreBuild = "${build}/core";
  link = path: config.lib.file.mkOutOfStoreSymlink path;
  # Every Core zsh fragment (and the loader) — read at eval from the build-side checkout,
  # linked to the guest-side path.
  zshFragments = lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".zsh" n)
    (builtins.readDir "${coreBuild}/zsh");
  zshLinks = lib.mapAttrs' (n: _: lib.nameValuePair "zsh/${n}" { source = link "${core}/zsh/${n}"; }) zshFragments;
  optionalLink = dest: rel: lib.optionalAttrs (builtins.pathExists "${coreBuild}/${rel}") {
    "${dest}" = { source = link "${core}/${rel}"; };
  };
in
{
  home.stateVersion = "25.05";
  # Standalone: the first `switch` replaces the user profile with home-manager-path, and the
  # `home-manager` the installer put there is gone unless this module carries it (measured:
  # the second switch was "home-manager: command not found", run 34863339069).
  programs.home-manager.enable = true;
  # Standalone home-manager needs these; the NixOS module sets them itself (and wins:
  # these are mkDefault).
  home.username = lib.mkDefault (env "HM_USER" "research");
  home.homeDirectory = lib.mkDefault (env "HM_HOME" "/home/research");

  # ── the packages the OS repo's install/packages.txt would provision ─────────
  home.packages = with pkgs; [
    zsh tmux neovim git starship atuin fzf ripgrep fd bat eza zoxide delta btop jq yq
    glow gum du-dust duf procs tealdeer mise lazygit yazi direnv tree-sitter
  ];

  # ── the Core surface, by the driver's destinations ──────────────────────────
  xdg.configFile = zshLinks
    // optionalLink "nvim" "nvim"
    // optionalLink "tmux/tmux.conf" "tmux/tmux.conf"
    // optionalLink "tmux/tmux.reset.conf" "tmux/tmux.reset.conf"
    // optionalLink "tmux/scripts" "tmux/scripts"
    // optionalLink "starship.toml" "starship/starship.toml"
    // optionalLink "lazygit/config.yml" "lazygit/config.yml"
    // optionalLink "atuin/config.toml" "atuin/config.toml"
    // optionalLink "jj/config.toml" "jujutsu/config.toml"
    // optionalLink "tealdeer/config.toml" "tealdeer/config.toml"
    // {
      # the OS layer (blib_link_os_layer)
      "zsh/80-os.zsh".source = link "${repo}/os/${os}.zsh";
      "zsh/os.capabilities".source = link "${repo}/os/${os}.capabilities";
      # tpm pinned by revision — the one thing here home-manager does BETTER than the
      # bootstrap's unpinned `git clone` at bootstrap time. nixpkgs 25.05 carries no
      # tmuxPlugins.tpm (measured: "Did you mean one of cpu or fpp?" — run 34859573589),
      # so the pin is a rev-locked fetch rather than a package.
      "tmux/plugins/tpm".source = builtins.fetchGit {
        url = "https://github.com/tmux-plugins/tpm";
        ref = "refs/tags/v3.1.0";
        rev = "7bdb7ca33c9cc6440a600202b50142f401b6fe21";
      };
    };

  home.file.".gitconfig".source = link "${core}/git/gitconfig";

  # mise rewrites its config (`mise use -g`), so it must be a real file the user owns —
  # exactly blib_adopt's reasoning. An activation script seeds it once; a store symlink
  # would make every `mise use` fail on a read-only target.
  home.activation.seedMiseConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -f "${core}/mise/config.toml" ] && [ ! -e "${config.xdg.configHome}/mise/config.toml" ]; then
      mkdir -p "${config.xdg.configHome}/mise"
      cp "${core}/mise/config.toml" "${config.xdg.configHome}/mise/config.toml"
    fi
  '';

  home.sessionPath = [ "${home}/.local/bin" "${home}/.cargo/bin" ];

  # ── the zsh entry: the contested item ───────────────────────────────────────
  # home-manager writes $ZDOTDIR/.zshrc (dotDir) and ~/.zshenv pointing ZDOTDIR at it.
  # Core's driver writes ~/.zshrc and seeds $ZDOTDIR/.zshrc → ~/.zshrc. Same loader,
  # two owners. The probe runs the driver over this and records what each one does.
  programs.zsh = {
    enable = true;
    dotDir = ".config/zsh";
    initContent = ''
      # home-manager-managed entry (R3 probe): the same v4 loader the driver would write
      : "''${XDG_CONFIG_HOME:=$HOME/.config}"
      : "''${XDG_STATE_HOME:=$HOME/.local/state}"
      : "''${XDG_CACHE_HOME:=$HOME/.cache}"
      : "''${XDG_DATA_HOME:=$HOME/.local/share}"
      export EDITOR=nvim VISUAL=nvim
      ZSH_CFG="$XDG_CONFIG_HOME/zsh"
      [[ -r "$ZSH_CFG/loader.zsh" ]] && source "$ZSH_CFG/loader.zsh"
    '';
  };
}

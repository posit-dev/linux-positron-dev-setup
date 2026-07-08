#!/usr/bin/env bash
#
# setup-debian.sh — Configure a Debian-family (Debian/Ubuntu/...) machine for
# Positron development.
#
# Run interactively by a developer on a fresh VM. Asks before doing anything
# slow or impactful, and is idempotent so it's safe to re-run.
#
# Usage:
#   ./setup-debian.sh          run the setup steps
#
set -euo pipefail

# Keep apt itself from popping debconf dialogs mid-run. (This is about apt's
# own prompts, not our interactive prompts below.)
export DEBIAN_FRONTEND=noninteractive

# Where to clone Positron from. Cloned over SSH (into a developer-chosen folder
# under ~/), so it relies on configure_ssh_key having registered a key first.
POSITRON_URL="${SETUP_POSITRON_URL:-git@github.com:posit-dev/positron.git}"

# Repos that Positron core developers work on. clone_positron offers to clone
# each — over SSH, sharing POSITRON_URL's host/owner — into a folder under ~/.
CORE_REPOS=(
  positron
  positron-codicons
  positron-builds
  positron-website
  positron-wiki
)

# Package dependencies installed via apt. Maintain this list as Positron's build
# requirements change — one package per line for easy diffs.
PACKAGES=(
  build-essential
  g++
  git
  git-lfs
  libcairo-dev
  libgif-dev
  libjpeg-dev
  libkrb5-dev
  libsdl-pango-dev
  libsecret-1-dev
  libx11-dev
  libxkbfile-dev
  python-is-python3
  python3-pip
)

# Node.js version installed via fnm (see install_node). Pinned here so it's easy
# to bump in one place as Positron's supported Node moves.
NODE_VERSION="22.22.1"

# Python version installed via pyenv (see install_python). Pinned here so it's
# easy to bump in one place as Positron's supported Python moves.
PYTHON_VERSION="3.12.12"

# Login shell wiring. configure_shell sets these from the developer's choice;
# defaults assume bash. Later steps (e.g. install_python) write their shell init
# into $SHELL_RC and use $LOGIN_SHELL to pick the right init syntax.
LOGIN_SHELL="bash"
SHELL_RC="$HOME/.bashrc"

# --- helpers ----------------------------------------------------------------

# ACCENT/CYAN/RESET: ANSI codes used to color banners and prompts (yellow, to
# signal "action needed"; cyan to make URLs stand out). Only populated when
# stderr is a terminal, so piped/logged output stays free of escape codes.
if [ -t 2 ]; then
  ACCENT=$'\033[33m'
  CYAN=$'\033[36m'
  RESET=$'\033[0m'
else
  ACCENT=""
  CYAN=""
  RESET=""
fi

# log <message>: progress line on stderr, prefixed with [setup].
log() {
  printf '[setup] %s\n' "$*" >&2
}

# banner <title>: blank line + full-width rule + title, on stderr, in the accent
# color. Used to set off each interactive prompt so it's easy to spot. The rule
# uses the box-drawing character U+2500 and spans the terminal width (falling
# back to 40).
banner() {
  local width line
  width=$(tput cols 2>/dev/null) || width=40
  [ -n "$width" ] || width=40
  line=$(printf '─%.0s' $(seq 1 "$width"))
  printf '\n' >&2
  printf '%s%s%s\n' "$ACCENT" "$line" "$RESET" >&2
  printf '%s%s%s\n' "$ACCENT" "$1" "$RESET" >&2
}

# boxed_notice <line>...: print the given lines inside a bold box (box-drawing
# characters) on stderr, in the accent color, sized to the longest line. Used for
# the final "log out and back in" reminder so it can't be missed in the scroll.
boxed_notice() {
  local bold="" line width=0 rule pad
  if [ -t 2 ]; then bold=$'\033[1m'; fi
  for line in "$@"; do
    [ "${#line}" -gt "$width" ] && width=${#line}
  done
  rule=$(printf '═%.0s' $(seq 1 $((width + 2))))
  printf '\n' >&2
  printf '%s%s╔%s╗%s\n' "$bold" "$ACCENT" "$rule" "$RESET" >&2
  for line in "$@"; do
    pad=$((width - ${#line}))
    printf '%s%s║ %s%*s ║%s\n' "$bold" "$ACCENT" "$line" "$pad" "" "$RESET" >&2
  done
  printf '%s%s╚%s╝%s\n' "$bold" "$ACCENT" "$rule" "$RESET" >&2
  printf '\n' >&2
}

# have <command>: true if <command> is on PATH.
have() {
  command -v "$1" >/dev/null 2>&1
}

# pkg_installed <pkg>: true if the dpkg package is currently installed.
pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'
}

# confirm <prompt>: ask a yes/no question, defaulting to Yes so the developer can
# hit ENTER to proceed through the steps. Reads from the terminal (/dev/tty)
# rather than stdin, so the prompt still works when the script is piped in via
# `curl ... | bash` (where stdin is the script itself).
confirm() {
  local prompt="$1" reply=""
  printf '%s%s [Y/n] %s' "$ACCENT" "$prompt" "$RESET" >&2
  read -r reply </dev/tty 2>/dev/null || reply=""
  case "$reply" in
    [Nn] | [Nn][Oo]) return 1 ;;
    *) return 0 ;;
  esac
}

# ask <prompt> <varname>: read a line from the terminal into the named variable,
# re-asking until it's non-empty. Like confirm(), reads /dev/tty so it works
# when the script is piped in via `curl ... | bash`.
ask() {
  local prompt="$1" __var="$2" reply=""
  while [ -z "$reply" ]; do
    printf '%s%s: %s' "$ACCENT" "$prompt" "$RESET" >&2
    read -r reply </dev/tty 2>/dev/null || reply=""
  done
  printf -v "$__var" '%s' "$reply"
}

# ask_default <prompt> <varname> <default>: like ask(), but shows <default> in
# brackets and accepts it when the developer just hits ENTER. If <default> is
# empty this behaves like ask() (re-asks until non-empty), so it works both for
# confirming an existing value and for filling in a missing one.
ask_default() {
  local prompt="$1" __var="$2" default="$3" reply=""
  while :; do
    if [ -n "$default" ]; then
      printf '%s%s [%s]: %s' "$ACCENT" "$prompt" "$default" "$RESET" >&2
    else
      printf '%s%s: %s' "$ACCENT" "$prompt" "$RESET" >&2
    fi
    read -r reply </dev/tty 2>/dev/null || reply=""
    [ -z "$reply" ] && reply="$default"
    [ -n "$reply" ] && break
  done
  printf -v "$__var" '%s' "$reply"
}

# clip_copy <text>: copy <text> to the system clipboard if a clipboard tool is
# available (Wayland's wl-copy, or X11's xclip/xsel). Returns non-zero if none
# is present so callers can fall back gracefully.
clip_copy() {
  if have wl-copy; then
    printf '%s' "$1" | wl-copy
  elif have xclip; then
    printf '%s' "$1" | xclip -selection clipboard
  elif have xsel; then
    printf '%s' "$1" | xsel --clipboard --input
  else
    return 1
  fi
}

# add_shell_init <tag> <line>...: append a marker-delimited block of shell-init
# lines to $SHELL_RC so a tool (pyenv, fnm, ...) loads in future interactive
# shells. Idempotent by <tag>. <tag> names the tool so blocks are individually
# identifiable.
add_shell_init() {
  local tag="$1"; shift
  local rc="$SHELL_RC"
  if [ -f "$rc" ] && grep -q "linux-positron-dev-setup: $tag" "$rc"; then
    log "$tag shell init already present in $rc; skipping."
    return 0
  fi
  log "adding $tag shell init to $rc ..."
  {
    printf '\n# >>> linux-positron-dev-setup: %s >>>\n' "$tag"
    printf '%s\n' "$@"
    printf '# <<< linux-positron-dev-setup: %s <<<\n' "$tag"
  } >>"$rc"
}

# set_shell_vars <shell-path>: derive LOGIN_SHELL and SHELL_RC from a login shell
# path (e.g. /usr/bin/zsh) so shell-init steps target the right file with the
# right syntax. Falls back to bash/~/.bashrc for anything we don't specifically
# handle, since that's what pyenv init we emit expects.
set_shell_vars() {
  case "$(basename "$1")" in
    zsh)  LOGIN_SHELL="zsh";  SHELL_RC="$HOME/.zshrc" ;;
    bash) LOGIN_SHELL="bash"; SHELL_RC="$HOME/.bashrc" ;;
    *)
      log "unrecognized login shell '$1'; wiring shell init into ~/.bashrc as a fallback."
      LOGIN_SHELL="bash"; SHELL_RC="$HOME/.bashrc"
      ;;
  esac
}

# install_oh_my_zsh: optionally install the oh-my-zsh framework on top of zsh.
# Only reached from configure_shell's zsh path, so zsh is guaranteed present.
# Idempotent — skips if ~/.oh-my-zsh already exists. Runs the official installer
# unattended so it doesn't try to chsh (we already did) or exec a login zsh
# (which would hijack this script). The installer creates ~/.zshrc from its
# template, backing up any existing one to ~/.zshrc.pre-oh-my-zsh; because this
# runs before the tool-init steps, their shell init is appended afterwards.
install_oh_my_zsh() {
  if [ -d "$HOME/.oh-my-zsh" ]; then
    log "oh-my-zsh already installed ($HOME/.oh-my-zsh); skipping."
    return 0
  fi

  if ! confirm "Install oh-my-zsh?"; then
    log "skipping oh-my-zsh install."
    return 0
  fi

  # The installer fetches over HTTPS; make sure curl is present.
  if ! pkg_installed curl; then
    log "installing curl..."
    sudo apt-get install -y curl
  fi

  log "installing oh-my-zsh ..."
  # --unattended sets CHSH=no and RUNZSH=no: don't change the login shell (we
  # already did) and don't drop into a new zsh at the end.
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
  log "oh-my-zsh installed."
}

# positron_parent_dir: prompt for a folder under ~/ (e.g. "Work" or "Code"),
# create it if missing, and echo it. Shared by the clone and fork paths, which
# put each repo checkout directly inside it.
positron_parent_dir() {
  local folder parent
  ask "Which folder under ~/ should the repos go in? (e.g. Work, Code)" folder
  parent="$HOME/$folder"
  if [ ! -d "$parent" ]; then
    log "creating $parent ..."
    mkdir -p "$parent"
  fi
  printf '%s\n' "$parent"
}

# clone_repo <url> <dest>: clone <url> into <dest> over SSH, unless a checkout is
# already there. Idempotent.
clone_repo() {
  local url="$1" dest="$2"
  if [ -d "$dest/.git" ]; then
    log "already cloned at $dest; skipping."
    return 0
  fi
  if [ -e "$dest" ]; then
    log "WARNING: $dest exists but isn't a git checkout; skipping."
    return 0
  fi
  log "cloning $url into $dest ..."
  git clone "$url" "$dest"
}

# --- steps ------------------------------------------------------------------

# apt_update: refresh the package index so installs resolve to the versions
# available for the release the developer chose.
apt_update() {
  banner "Refresh Package Index"
  log "refreshing apt package index..."
  sudo apt-get update
}

# maybe_upgrade: offer to upgrade installed packages. Like every prompt this
# defaults to Yes (hit ENTER to proceed); answer No to keep the box at the exact
# package versions of the chosen ISO (useful for reproducing release-specific
# bugs). This stays WITHIN the current release — it does not change the
# Ubuntu/Debian (LTS) version.
maybe_upgrade() {
  banner "Upgrade Packages"
  if confirm "Upgrade installed packages to the latest within the current release?"; then
    log "upgrading packages (apt-get full-upgrade)..."
    sudo apt-get full-upgrade -y
  else
    log "skipping upgrade; keeping the release's current package versions."
  fi
}

# install_deps: install the build/runtime package dependencies from PACKAGES.
# Assumes apt_update has already run, so the index is current. apt-get is
# idempotent — already-installed packages are left as-is.
install_deps() {
  banner "Install Dependencies"

  if ! confirm "Do you want to install package dependencies?"; then
    log "skipping package dependency install."
    return 0
  fi

  log "installing package dependencies (${#PACKAGES[@]} packages)..."
  sudo apt-get install -y "${PACKAGES[@]}"
  log "package dependencies installed."
}

# configure_shell: optionally switch the developer's login shell to Zsh. Our
# developers work on macOS (where Zsh is the default), so offer it here. Installs
# zsh, makes it the login shell via chsh, and points $SHELL_RC/$LOGIN_SHELL at
# zsh so later steps wire their shell init into ~/.zshrc. Declining detects the
# current login shell and targets that instead. Must run before install_python,
# which relies on these variables.
configure_shell() {
  banner "Choose Shell"

  local user old_shell zsh_path
  user="$(id -un)"
  old_shell="$(getent passwd "$user" | cut -d: -f7)"

  if ! confirm "Would you like to use Zsh? (the default shell on macOS)"; then
    log "keeping your current login shell ($old_shell)."
    set_shell_vars "$old_shell"
    return 0
  fi

  if ! pkg_installed zsh; then
    log "installing zsh..."
    sudo apt-get install -y zsh
  fi

  # Switch the login shell with sudo chsh so it doesn't prompt for a password.
  zsh_path="$(command -v zsh)"
  if [ "$old_shell" != "$zsh_path" ]; then
    log "setting your login shell to $zsh_path ..."
    sudo chsh -s "$zsh_path" "$user"
  else
    log "login shell is already $zsh_path; skipping."
  fi

  set_shell_vars "$zsh_path"

  # zsh is now present (we installed it or it was already there), so offer
  # oh-my-zsh on top of it.
  install_oh_my_zsh
}

# configure_zsh_prompt: if zsh is the login shell and oh-my-zsh is installed,
# append a custom PROMPT as a shell-init block of ~/.zshrc. Runs right after
# configure_shell so the block lands after oh-my-zsh's own config (which sets the
# theme's prompt), letting our PROMPT win. The later tool-init blocks (fnm,
# pyenv) are appended below it but don't touch PROMPT, so it stays the effective
# prompt. The prompt uses oh-my-zsh helpers ($fg, git_prompt_info), so we only
# add it when oh-my-zsh is present; otherwise the developer manages their own
# prompt. Idempotent via add_shell_init.
configure_zsh_prompt() {
  [ "$LOGIN_SHELL" = zsh ] || return 0
  [ -d "$HOME/.oh-my-zsh" ] || return 0
  banner "Configure Zsh Prompt"
  if ! confirm "Configure a custom Zsh prompt?"; then
    log "skipping zsh prompt configuration."
    return 0
  fi
  add_shell_init "zsh-prompt" \
    'PROMPT='\''[%m]%{$fg_bold[green]%}%p %{$fg[cyan]%}[%~]%{$reset_color%} $(git_prompt_info)%{$fg_bold[blue]%}% %{$reset_color%}'\'''
  log "custom zsh prompt written to $SHELL_RC."
}

# install_node: install fnm (Fast Node Manager) and the pinned Node.js
# ($NODE_VERSION), then set it as the default. fnm is the current recommendation
# for managing Node versions. Idempotent — skips the fnm install and the version
# install if they're already present. Runs before install_python and, like it,
# relies on configure_shell having set $SHELL_RC/$LOGIN_SHELL.
install_node() {
  banner "Install Node.js"

  if ! confirm "Install Node.js $NODE_VERSION via fnm?"; then
    log "skipping Node.js install."
    return 0
  fi

  # fnm's installer fetches and unpacks a release zip over HTTPS, so make sure
  # curl and unzip exist. Install only what's missing.
  local dep
  for dep in curl unzip; do
    if ! pkg_installed "$dep"; then
      log "installing $dep..."
      sudo apt-get install -y "$dep"
    fi
  done

  # fnm itself, into ~/.fnm (both the binary and, via $FNM_DIR, the installed
  # Node versions, all under one directory). --skip-shell so we control the
  # shell wiring ourselves (via add_shell_init), consistent with pyenv.
  local fnm_dir="$HOME/.fnm"
  if [ -x "$fnm_dir/fnm" ]; then
    log "fnm already installed ($fnm_dir); skipping."
  else
    log "installing fnm into $fnm_dir ..."
    curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$fnm_dir" --skip-shell
  fi

  # Make fnm usable for the rest of this script.
  export PATH="$fnm_dir:$PATH"
  export FNM_DIR="$fnm_dir"

  # Wire fnm into future interactive shells now, before the (network-dependent)
  # version install below. Under `set -e` a failed `fnm install` would abort the
  # script, and if the wiring came afterward we'd leave the binary on disk but
  # off PATH — fnm unusable in new shells. The `[ -d "$FNM_DIR" ]` guard mirrors
  # fnm's own installer so the block is a no-op if the dir is ever removed.
  add_shell_init fnm \
    'export FNM_DIR="$HOME/.fnm"' \
    'if [ -d "$FNM_DIR" ]; then' \
    '  export PATH="$FNM_DIR:$PATH"' \
    "  eval \"\$(fnm env --use-on-cd --shell $LOGIN_SHELL)\"" \
    'fi'

  # Install the pinned Node version (idempotent).
  if fnm list 2>/dev/null | grep -q "v$NODE_VERSION"; then
    log "Node.js $NODE_VERSION already installed via fnm; skipping."
  else
    log "installing Node.js $NODE_VERSION with fnm..."
    fnm install "$NODE_VERSION"
  fi
  fnm default "$NODE_VERSION"
  log "fnm default Node.js set to $NODE_VERSION."
}

# install_python: install pyenv and build the pinned CPython ($PYTHON_VERSION),
# then set it as the global version. Positron needs Python both to build against
# and to run against, and pyenv lets the developer manage/switch versions
# cleanly. Idempotent — skips the pyenv clone and the version build if they're
# already present.
install_python() {
  banner "Install Python"

  if ! confirm "Install Python $PYTHON_VERSION via pyenv?"; then
    log "skipping Python install."
    return 0
  fi

  # Packages needed to compile CPython from source (the pyenv "suggested build
  # environment"). Install them only when some are missing.
  local build_deps=(
    make build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev
    libsqlite3-dev wget curl llvm libncursesw5-dev xz-utils tk-dev
    libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev
  )
  local pkg new=()
  for pkg in "${build_deps[@]}"; do
    pkg_installed "$pkg" || new+=("$pkg")
  done
  if [ "${#new[@]}" -gt 0 ]; then
    log "installing ${#new[@]} pyenv build dependencies..."
    sudo apt-get install -y "${build_deps[@]}"
  fi

  # pyenv itself, into ~/.pyenv.
  local pyenv_root="$HOME/.pyenv"
  if [ -d "$pyenv_root/.git" ]; then
    log "pyenv already installed ($pyenv_root); skipping clone."
  else
    log "installing pyenv into $pyenv_root ..."
    git clone --depth 1 https://github.com/pyenv/pyenv.git "$pyenv_root"
  fi

  # Make pyenv usable for the rest of this script.
  export PYENV_ROOT="$pyenv_root"
  export PATH="$PYENV_ROOT/bin:$PATH"

  # Build the pinned version. pyenv would skip an existing build itself, but the
  # explicit check keeps the log clean and avoids a needless rebuild.
  if pyenv versions --bare 2>/dev/null | grep -qx "$PYTHON_VERSION"; then
    log "Python $PYTHON_VERSION already installed via pyenv; skipping build."
  else
    log "building Python $PYTHON_VERSION with pyenv (this can take a few minutes)..."
    pyenv install "$PYTHON_VERSION"
  fi
  pyenv global "$PYTHON_VERSION"
  log "pyenv global Python set to $PYTHON_VERSION."

  # Wire pyenv into future interactive shells.
  add_shell_init pyenv \
    'export PYENV_ROOT="$HOME/.pyenv"' \
    '[ -d "$PYENV_ROOT/bin" ] && export PATH="$PYENV_ROOT/bin:$PATH"' \
    "eval \"\$(pyenv init - $LOGIN_SHELL)\""
}

# configure_git_identity: ensure git knows who's authoring commits. Always walks
# the developer through both fields, pre-filling any value that's already set so
# ENTER keeps it. This is the one place we ask the developer for personal info.
configure_git_identity() {
  local cur_name cur_email name email
  cur_name="$(git config --global user.name || true)"
  cur_email="$(git config --global user.email || true)"

  banner "Setup Git Identity"
  log "setting your git identity (used to author your commits)..."

  # Prompt for both, showing any existing value as the default. Only set fields
  # that actually change, so we never clobber an identity the developer already
  # had, and re-running is a no-op.
  ask_default "Your Git user.name" name "$cur_name"
  if [ "$name" != "$cur_name" ]; then
    git config --global user.name "$name"
  fi
  ask_default "Your Git user.email" email "$cur_email"
  if [ "$email" != "$cur_email" ]; then
    git config --global user.email "$email"
  fi
  log "git identity set to $name <$email>."
}

# configure_ssh_key: ensure an ed25519 SSH key pair exists. Idempotent — if
# ~/.ssh/id_ed25519 is already there, leaves it alone. Otherwise generates one
# non-interactively (no passphrase), labelled with the git email if set. Then
# shows the public key and points the developer at GitHub to register it.
configure_ssh_key() {
  local key="$HOME/.ssh/id_ed25519" comment pub

  banner "Setup SSH Keys"
  if [ -f "$key" ]; then
    log "SSH key already exists ($key); skipping generation."
  else
    log "generating an ed25519 SSH key ($key)..."
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    comment="$(git config --global user.email || true)"
    ssh-keygen -t ed25519 -f "$key" -N "" -C "$comment"
    log "SSH key created."
  fi

  pub="$(cat "${key}.pub")"
  printf '\n' >&2
  printf 'Your public SSH key (%s.pub):\n\n' "$key" >&2
  printf '%s\n\n' "$pub" >&2
  if clip_copy "$pub"; then
    printf 'It has been copied to your clipboard.\n' >&2
  fi
  printf '%sAdd it to GitHub here: %s%shttps://github.com/settings/ssh/new%s\n\n' "$ACCENT" "$RESET" "$CYAN" "$RESET" >&2
  while ! confirm "Have you added your SSH key to GitHub?"; do
    printf '%sWell, do it! Add your SSH key to GitHub, then confirm.%s\n' "$ACCENT" "$RESET" >&2
  done
}

# install_vscode: optionally download and install the latest stable VS Code for
# arm64 from Microsoft. Downloads the .deb into ~/Downloads, then installs it with
# apt-get (which resolves any dependencies). Idempotent — skips if `code` is
# already installed.
install_vscode() {
  banner "Install Visual Studio Code"

  if ! confirm "Install Visual Studio Code?"; then
    log "skipping Visual Studio Code install."
    return 0
  fi

  # Check the dpkg package, not `code` on PATH: in a VS Code remote/SSH session
  # the server ships its own `code` CLI shim, so `have code` gives a false
  # positive even when the .deb isn't installed.
  if pkg_installed code; then
    log "Visual Studio Code already installed (code package present); skipping."
    return 0
  fi

  # curl fetches the .deb over HTTPS; make sure it's present.
  if ! pkg_installed curl; then
    log "installing curl..."
    sudo apt-get install -y curl
  fi

  # Download the latest stable arm64 build into ~/Downloads. The URL redirects to
  # a versioned .deb (e.g. code_1.126.0-..._arm64.deb); -L follows the redirect
  # and -OJ saves it under the server-provided filename.
  local dl="$HOME/Downloads"
  mkdir -p "$dl"
  log "downloading the latest VS Code (arm64) into $dl ..."
  ( cd "$dl" && curl -fSL -OJ "https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-arm64" )

  # Pick the VS Code .deb to install. Normally there's exactly one, but if older
  # downloads linger, sort -V takes the highest version. The directory prefix is
  # identical across matches, so the sort keys on the version in the filename.
  local deb
  deb="$(ls "$dl"/code_*.deb 2>/dev/null | sort -V | tail -n1)"
  if [ -z "$deb" ]; then
    log "WARNING: no VS Code .deb found in $dl after download; skipping install."
    return 0
  fi

  log "installing $(basename "$deb") ..."
  sudo apt-get install -y "$deb"
  log "Visual Studio Code installed."
}

# install_ssh_server: optionally install and enable the OpenSSH server so the
# machine accepts incoming SSH connections (e.g. for VS Code Remote - SSH).
# Idempotent — the apt-get install is a no-op if openssh-server is already
# present, and `systemctl enable --now` is safe to re-run.
install_ssh_server() {
  banner "Enable SSH server"

  if ! confirm "Install and enable the OpenSSH server?"; then
    log "skipping OpenSSH server setup."
    return 0
  fi

  if ! pkg_installed openssh-server; then
    log "installing openssh-server..."
    sudo apt-get install -y openssh-server
  else
    log "openssh-server already installed."
  fi

  # Enable the service and start it now. On Debian/Ubuntu the unit is named ssh.
  log "enabling and starting the ssh service..."
  sudo systemctl enable --now ssh
  log "OpenSSH server is enabled and running."
}

# clone_or_fork_positron: Positron core developers clone the repos directly;
# community contributors fork first. Hands off to the matching step below.
clone_or_fork_positron() {
  banner "Clone or Fork Positron"
  log "Positron core developers can clone the repos directly; the community should fork."
  if confirm "Are you a Positron core developer? (No forks Positron to your account instead)"; then
    clone_positron
  else
    fork_positron
  fi
}

# clone_positron: for Positron core developers. Offers (one Y/n per repo) to clone
# each of the repos core developers work on ($CORE_REPOS) into a chosen folder
# under ~/. Repo URLs share POSITRON_URL's host/owner, so SETUP_POSITRON_URL
# overrides them all. Runs after configure_ssh_key so the SSH clones authenticate.
clone_positron() {
  banner "Clone Positron repos"

  local parent base name
  parent="$(positron_parent_dir)"
  base="${POSITRON_URL%/*}"   # e.g. git@github.com:posit-dev

  for name in "${CORE_REPOS[@]}"; do
    if confirm "Clone $name?"; then
      clone_repo "$base/$name.git" "$parent/$name"
    else
      log "skipping $name."
    fi
  done
  log "done. Your Positron repos are under $parent."
}

# fork_positron: for community contributors without push access. Points the
# developer at GitHub to create their own fork in the browser, then clones that
# fork over SSH (as origin) and adds the canonical repo as an `upstream` remote so
# they can pull updates.
fork_positron() {
  banner "Fork Positron"

  local slug repo user fork_page fork_url parent dest

  # Derive owner/repo and the browser "create fork" URL from POSITRON_URL, e.g.
  # git@github.com:posit-dev/positron.git -> posit-dev/positron.
  slug="${POSITRON_URL#*:}"; slug="${slug%.git}"
  repo="${slug##*/}"
  fork_page="https://github.com/$slug/fork"

  printf '\n' >&2
  printf '%sFork Positron on GitHub first: %s%s%s%s\n\n' "$ACCENT" "$RESET" "$CYAN" "$fork_page" "$RESET" >&2
  if clip_copy "$fork_page"; then
    printf 'That URL has been copied to your clipboard.\n' >&2
  fi
  while ! confirm "Have you created your fork on GitHub?"; do
    printf '%sGo create your fork at the URL above, then confirm.%s\n' "$ACCENT" "$RESET" >&2
  done

  ask "Your GitHub username (the owner of the fork)" user
  fork_url="git@github.com:$user/$repo.git"

  parent="$(positron_parent_dir)"
  dest="$parent/$repo"
  clone_repo "$fork_url" "$dest"

  # Wire up the canonical repo as `upstream` so the developer can pull updates
  # (idempotent; only when we have a checkout that doesn't already have it).
  if [ -d "$dest/.git" ] && ! git -C "$dest" remote | grep -qx upstream; then
    log "adding '$POSITRON_URL' as the 'upstream' remote ..."
    git -C "$dest" remote add upstream "$POSITRON_URL"
  fi
  log "forked. Your checkout is at $dest (origin = your fork, upstream = $slug)."

  # Point community contributors at where to go next.
  printf '\n' >&2
  printf '%sGetting started as a community contributor:%s\n' "$ACCENT" "$RESET" >&2
  printf '  Positron:     %s%s%s\n' "$CYAN" "https://github.com/$slug" "$RESET" >&2
  printf '  Contributing: %s%s%s\n\n' "$CYAN" "https://github.com/$slug/blob/main/CONTRIBUTING.md" "$RESET" >&2
}

# final_notice: the last thing main() does — a prominent boxed reminder to log out
# and back in, so the new login shell (chsh) and the shell-init/PATH changes take
# effect in a fresh session.
final_notice() {
  boxed_notice \
    "Setup complete!" \
    "" \
    "Log out and log back in (or reboot) so that" \
    "your new login shell and PATH take effect."
}

# --- main -------------------------------------------------------------------

main() {
  banner "Linux Positron Dev Setup"
  apt_update
  maybe_upgrade
  install_deps
  configure_shell
  configure_zsh_prompt
  install_node
  install_python
  # Identity before the SSH key, so the key is labelled with the git email.
  configure_git_identity
  configure_ssh_key
  install_vscode
  install_ssh_server
  clone_or_fork_positron
  final_notice
}

case "${1:-}" in
  ""|--setup) main ;;
  -h|--help) printf 'usage: %s\n' "$0" ;;
  *) printf 'unknown option: %s\nusage: %s\n' "$1" "$0" >&2; exit 2 ;;
esac

#!/usr/bin/env bash
set -Eeuo pipefail

readonly OMZ_DIR="$HOME/.oh-my-zsh"
readonly OMZ_CUSTOM_DIR="$OMZ_DIR/custom"
readonly LOCAL_BIN="$HOME/.local/bin"
readonly BLOCK_START="# >>> ai-shell installer >>>"
readonly BLOCK_END="# <<< ai-shell installer <<<"

TEMP_FILES=()
DOWNLOADED_INSTALLER=""

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if ((${#TEMP_FILES[@]})); then
    rm -f -- "${TEMP_FILES[@]}"
  fi
}
trap cleanup EXIT

if ((EUID == 0)) && [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
  die "Run this script as your normal user, not with sudo. It invokes sudo only when needed."
fi

[[ "$HOME" == /* ]] || die "HOME must be an absolute path."

run_as_root() {
  if ((EUID == 0)); then
    "$@"
  else
    command -v sudo >/dev/null 2>&1 || die "sudo is required to install system packages."
    sudo "$@"
  fi
}

command_works() {
  case "$1" in
    tmux) tmux -V >/dev/null 2>&1 ;;
    zsh) zsh --version >/dev/null 2>&1 ;;
    git) git --version >/dev/null 2>&1 ;;
    curl) curl --version >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

install_system_packages() {
  local missing=()
  local command_name

  for command_name in tmux zsh git curl; do
    if ! command -v "$command_name" >/dev/null 2>&1 ||
      ! command_works "$command_name"; then
      missing+=("$command_name")
    fi
  done

  if ((${#missing[@]} == 0)); then
    log "tmux, Zsh, Git, and curl are already installed"
    return
  fi

  log "Installing tmux, Zsh, Git, curl, and certificate support"

  if [[ "$(uname -s)" == "Darwin" ]]; then
    local brew_command=""
    local packages=()

    if command -v brew >/dev/null 2>&1; then
      brew_command="$(command -v brew)"
    elif [[ -x /opt/homebrew/bin/brew ]]; then
      brew_command="/opt/homebrew/bin/brew"
    elif [[ -x /usr/local/bin/brew ]]; then
      brew_command="/usr/local/bin/brew"
    else
      die "Homebrew is required on macOS: https://brew.sh"
    fi

    export PATH="$(dirname "$brew_command"):$PATH"
    for command_name in "${missing[@]}"; do
      packages+=("$command_name")
    done
    "$brew_command" install "${packages[@]}"
  elif command -v apt-get >/dev/null 2>&1; then
    run_as_root apt-get update
    run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
      tmux zsh git curl ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    run_as_root dnf install -y \
      tmux zsh git curl ca-certificates util-linux-user
  elif command -v yum >/dev/null 2>&1; then
    run_as_root yum install -y \
      tmux zsh git curl ca-certificates util-linux-user
  elif command -v pacman >/dev/null 2>&1; then
    run_as_root pacman -Sy --needed --noconfirm \
      tmux zsh git curl ca-certificates
  elif command -v apk >/dev/null 2>&1; then
    run_as_root apk add \
      tmux zsh git curl ca-certificates bash shadow libgcc libstdc++ ripgrep
  elif command -v zypper >/dev/null 2>&1; then
    run_as_root zypper --non-interactive install \
      tmux zsh git curl ca-certificates util-linux
  else
    die "Unsupported package manager. Install these commands first: ${missing[*]}"
  fi

  for command_name in tmux zsh git curl; do
    if ! command -v "$command_name" >/dev/null 2>&1 ||
      ! command_works "$command_name"; then
      die "$command_name was not found after package installation."
    fi
  done
}

clone_if_missing() {
  local repository="$1"
  local destination="$2"
  local expected_file="$3"
  local name="$4"

  if [[ -e "$destination" ]]; then
    [[ -e "$destination/$expected_file" ]] ||
      die "$destination exists but is not a valid $name installation."
    log "$name is already installed"
    return
  fi

  log "Installing $name"
  git clone --depth 1 "$repository" "$destination"
}

download_installer() {
  local name="$1"
  local url="$2"
  local installer

  installer="$(mktemp "${TMPDIR:-/tmp}/ai-shell-installer.XXXXXX")"
  TEMP_FILES+=("$installer")

  log "Downloading the official $name installer"
  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 3 \
    --proto '=https' \
    --proto-redir '=https' \
    --tlsv1.2 \
    "$url" \
    --output "$installer"

  DOWNLOADED_INSTALLER="$installer"
}

install_ai_clis() {
  mkdir -p "$LOCAL_BIN"
  export PATH="$LOCAL_BIN:$PATH"

  download_installer "GitHub Copilot CLI" "https://gh.io/copilot-install"
  PREFIX="$HOME/.local" bash "$DOWNLOADED_INSTALLER"

  download_installer "OpenAI Codex CLI" "https://chatgpt.com/codex/install.sh"
  CODEX_INSTALL_DIR="$LOCAL_BIN" CODEX_NON_INTERACTIVE=1 \
    sh "$DOWNLOADED_INSTALLER"

  download_installer "Anthropic Claude Code" "https://claude.ai/install.sh"
  bash "$DOWNLOADED_INSTALLER" stable
}

configure_zsh() {
  local zshrc="$HOME/.zshrc"
  local backup="$HOME/.zshrc.pre-ai-shell"
  local temporary_zshrc

  temporary_zshrc="$(mktemp "${TMPDIR:-/tmp}/ai-shell-zshrc.XXXXXX")"
  TEMP_FILES+=("$temporary_zshrc")

  if [[ -f "$zshrc" ]]; then
    if [[ ! -e "$backup" ]]; then
      cp -p "$zshrc" "$backup"
      log "Saved the original Zsh configuration to $backup"
    fi

    awk -v start="$BLOCK_START" -v end="$BLOCK_END" '
      $0 == start { in_block = 1; next }
      $0 == end { in_block = 0; next }
      !in_block { print }
    ' "$zshrc" >"$temporary_zshrc"
  fi

  if [[ -s "$temporary_zshrc" ]]; then
    printf '\n' >>"$temporary_zshrc"
  fi

  cat >>"$temporary_zshrc" <<'ZSH_CONFIG'
# >>> ai-shell installer >>>
export PATH="$HOME/.local/bin:$PATH"

if (( ! $+functions[omz] )); then
  export ZSH="$HOME/.oh-my-zsh"
  ZSH_THEME="${ZSH_THEME:-robbyrussell}"
  plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
  source "$ZSH/oh-my-zsh.sh"
else
  source "$HOME/.oh-my-zsh/plugins/git/git.plugin.zsh"

  if (( ! $+functions[_zsh_autosuggest_start] )); then
    source "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
  fi

  if (( ! $+functions[_zsh_highlight] )); then
    source "$HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
  fi
fi
# <<< ai-shell installer <<<
ZSH_CONFIG

  if [[ -e "$zshrc" || -L "$zshrc" ]]; then
    cat "$temporary_zshrc" >"$zshrc"
  else
    mv "$temporary_zshrc" "$zshrc"
  fi
  log "Configured Oh My Zsh and plugins in $zshrc"
}

account_shell() {
  local user_name="$1"

  if [[ "$(uname -s)" == "Darwin" ]]; then
    dscl . -read "/Users/$user_name" UserShell 2>/dev/null |
      awk '{print $2}'
  elif command -v getent >/dev/null 2>&1; then
    getent passwd "$user_name" | awk -F: '{print $7}'
  else
    awk -F: -v user="$user_name" '$1 == user {print $7}' /etc/passwd
  fi
}

make_zsh_default() {
  local user_name
  local zsh_path
  local current_shell

  user_name="$(id -un)"
  zsh_path="$(command -v zsh)"
  current_shell="$(account_shell "$user_name")"

  if [[ "${current_shell##*/}" == "zsh" ]]; then
    log "Zsh is already the default login shell"
    return
  fi

  if [[ -f /etc/shells ]] && ! grep -Fqx "$zsh_path" /etc/shells; then
    log "Adding $zsh_path to /etc/shells"
    if ((EUID == 0)); then
      printf '%s\n' "$zsh_path" >>/etc/shells
    else
      printf '%s\n' "$zsh_path" | run_as_root tee -a /etc/shells >/dev/null
    fi
  fi

  log "Setting Zsh as the default login shell for $user_name"
  if ! run_as_root chsh -s "$zsh_path" "$user_name"; then
    die "Could not change the login shell. Run: chsh -s '$zsh_path'"
  fi

  current_shell="$(account_shell "$user_name")"
  [[ "${current_shell##*/}" == "zsh" ]] ||
    die "The account login shell is still '$current_shell', not Zsh."
}

verify_installation() {
  local zsh_path
  local command_name

  zsh_path="$(command -v zsh)"
  log "Verifying commands from a fresh Zsh login shell"

  for command_name in tmux git copilot codex claude; do
    "$zsh_path" -lic "command -v '$command_name' >/dev/null" ||
      die "$command_name is not available from a Zsh login shell."
  done

  "$zsh_path" -lic '
    (( $+functions[omz] ))
    (( $+functions[_zsh_autosuggest_start] ))
    (( $+functions[_zsh_highlight] ))
  ' || die "One or more Oh My Zsh plugins failed to load."

  "$zsh_path" -lic '
    printf "tmux:   "; tmux -V
    printf "zsh:    "; zsh --version
    printf "copilot: "; copilot --version
    printf "codex:   "; codex --version
    printf "claude:  "; claude --version
  '
}

main() {
  install_system_packages

  clone_if_missing \
    "https://github.com/ohmyzsh/ohmyzsh.git" \
    "$OMZ_DIR" \
    "oh-my-zsh.sh" \
    "Oh My Zsh"
  mkdir -p "$OMZ_CUSTOM_DIR/plugins"
  clone_if_missing \
    "https://github.com/zsh-users/zsh-autosuggestions.git" \
    "$OMZ_CUSTOM_DIR/plugins/zsh-autosuggestions" \
    "zsh-autosuggestions.zsh" \
    "zsh-autosuggestions"
  clone_if_missing \
    "https://github.com/zsh-users/zsh-syntax-highlighting.git" \
    "$OMZ_CUSTOM_DIR/plugins/zsh-syntax-highlighting" \
    "zsh-syntax-highlighting.zsh" \
    "zsh-syntax-highlighting"

  install_ai_clis
  configure_zsh
  make_zsh_default
  verify_installation

  printf '\nInstallation complete. Open a new terminal, then run:\n'
  printf '  copilot   # Use /login if prompted\n'
  printf '  codex     # Sign in with ChatGPT or an API key\n'
  printf '  claude    # Sign in with Anthropic or configure an API provider\n'
}

main "$@"

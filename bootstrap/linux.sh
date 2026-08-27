#!/usr/bin/env bash
# bootstrap/linux.sh - set up dotfiles on Linux (Arch/Omarchy or Debian/Ubuntu)
# Usage: ./bootstrap/linux.sh              (full setup)
#        ./bootstrap/linux.sh --symlinks-only  (re-apply symlinks only)

set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYMLINKS_ONLY="${1:-}"

link() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  ln -sf "$src" "$dst"
  echo "  linked: $dst -> $src"
}

# ── Symlinks ────────────────────────────────────────────────────────────────

echo "Creating symlinks..."

# WezTerm
link "$DOTFILES/.config/wezterm" "$HOME/.config/wezterm"

# Tmux
link "$DOTFILES/.config/tmux/tmux.conf" "$HOME/.config/tmux/tmux.conf"

# Neovim
link "$DOTFILES/.config/nvim" "$HOME/.config/nvim"

# AGENTS.md → Claude global config
mkdir -p "$HOME/.claude"
link "$DOTFILES/AGENTS.md" "$HOME/.claude/CLAUDE.md"

# AGENTS.md symlink in repo (CLAUDE.md → AGENTS.md)
ln -sf "$DOTFILES/AGENTS.md" "$DOTFILES/CLAUDE.md"
echo "  linked: $DOTFILES/CLAUDE.md -> AGENTS.md"

# tdev script
mkdir -p "$HOME/.local/bin"
link "$DOTFILES/scripts/tdev.sh" "$HOME/.local/bin/tdev"
chmod +x "$HOME/.local/bin/tdev"
link "$DOTFILES/scripts/sync.sh" "$HOME/.local/bin/dotfiles-sync"
chmod +x "$HOME/.local/bin/dotfiles-sync"

[[ "$SYMLINKS_ONLY" == "--symlinks-only" ]] && echo "Done (symlinks only)." && exit 0

# ── Packages ─────────────────────────────────────────────────────────────────

echo ""
echo "Installing packages..."

if command -v pacman &>/dev/null; then
  # Arch / Omarchy
  sudo pacman -Syu --noconfirm
  sudo pacman -S --needed --noconfirm \
    neovim tmux git curl wget unzip \
    ripgrep fd fzf zoxide bat eza lazygit \
    mosh openssh \
    nodejs npm python python-pip go rust \
    wezterm

  # AUR extras (requires yay)
  if command -v yay &>/dev/null; then
    yay -S --needed --noconfirm \
      iosevka-term-nerd-font
  fi

elif command -v apt &>/dev/null; then
  # Debian / Ubuntu
  sudo apt update
  sudo apt install -y \
    neovim tmux git curl wget unzip \
    ripgrep fd-find fzf bat eza lazygit \
    mosh openssh-client \
    nodejs npm python3 python3-pip golang-go \
    build-essential

  # Install zoxide manually (apt version often outdated)
  curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash

  # WezTerm (flatpak or AppImage)
  echo "Install WezTerm manually from https://wezfurlong.org/wezterm/installation"
fi

# ── Claude Code ───────────────────────────────────────────────────────────────

if ! command -v claude &>/dev/null; then
  echo ""
  echo "Installing Claude Code..."
  npm install -g @anthropic-ai/claude-code
fi

# ── Shell config ─────────────────────────────────────────────────────────────

SHELL_RC="$HOME/.zshrc"
[[ ! -f "$SHELL_RC" ]] && SHELL_RC="$HOME/.bashrc"

if ! grep -q 'dotfiles' "$SHELL_RC" 2>/dev/null; then
  cat >> "$SHELL_RC" << 'EOF'

# dotfiles
export PATH="$HOME/.local/bin:$PATH"
eval "$(zoxide init zsh)"
EOF
  echo "Updated $SHELL_RC"
fi

echo ""
echo "Bootstrap complete."
echo "Restart your shell or run: source $SHELL_RC"

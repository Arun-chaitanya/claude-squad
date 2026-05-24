#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════╗
# ║  Claude Squad Installer                                      ║
# ║  Adds 'squad' to PATH and validates dependencies             ║
# ╚══════════════════════════════════════════════════════════════╝

SQUAD_DIR="$(cd "$(dirname "$0")" && pwd)"
SQUAD_BIN="${SQUAD_DIR}/bin/squad"

echo "Claude Squad Installer"
echo "======================"
echo ""

# ─── Check dependencies ─────────────────────────────────────────

check_dep() {
  local name="$1"
  local install_hint="$2"
  if command -v "$name" &>/dev/null; then
    local version
    version=$("$name" -V 2>&1 || "$name" --version 2>&1 | head -1 || echo "installed")
    printf "  %-12s %s\n" "$name" "$version"
    return 0
  else
    printf "  %-12s MISSING — %s\n" "$name" "$install_hint"
    return 1
  fi
}

echo "Checking dependencies..."
echo ""

missing=0

check_dep "tmux"       "brew install tmux" || missing=$((missing + 1))
check_dep "claude"     "npm install -g @anthropic-ai/claude-code" || missing=$((missing + 1))
check_dep "jq"         "brew install jq" || missing=$((missing + 1))
check_dep "git"        "xcode-select --install" || missing=$((missing + 1))

echo ""

# Optional dependencies
echo "Optional dependencies (for tester role):"
if command -v npx &>/dev/null; then
  printf "  %-12s %s\n" "npx" "$(npx --version 2>&1 || echo "installed")"
  if npx playwright --version &>/dev/null 2>&1; then
    printf "  %-12s %s\n" "playwright" "$(npx playwright --version 2>&1)"
  else
    printf "  %-12s MISSING — npx playwright install\n" "playwright"
  fi
else
  printf "  %-12s MISSING — install Node.js\n" "npx"
fi
echo ""

if [[ $missing -gt 0 ]]; then
  echo "ERROR: $missing required dependencies missing. Install them and re-run."
  exit 1
fi

# ─── Make executable ─────────────────────────────────────────────

chmod +x "$SQUAD_BIN"

# ─── Add to PATH ────────────────────────────────────────────────

SHELL_RC=""
if [[ -f "${HOME}/.zshrc" ]]; then
  SHELL_RC="${HOME}/.zshrc"
elif [[ -f "${HOME}/.bashrc" ]]; then
  SHELL_RC="${HOME}/.bashrc"
elif [[ -f "${HOME}/.bash_profile" ]]; then
  SHELL_RC="${HOME}/.bash_profile"
fi

PATH_LINE="export PATH=\"${SQUAD_DIR}/bin:\$PATH\""

if [[ -n "$SHELL_RC" ]]; then
  if grep -qF "claude-squad/bin" "$SHELL_RC" 2>/dev/null; then
    echo "PATH already configured in $SHELL_RC"
  else
    echo "" >> "$SHELL_RC"
    echo "# Claude Squad" >> "$SHELL_RC"
    echo "$PATH_LINE" >> "$SHELL_RC"
    echo "Added to PATH in $SHELL_RC"
  fi
else
  echo "Could not find shell rc file. Add this to your shell profile:"
  echo "  $PATH_LINE"
fi

# ─── Create global config directory ─────────────────────────────

mkdir -p "${HOME}/.claude-squad"

echo ""
echo "Installation complete!"
echo ""
echo "Reload your shell:  source ${SHELL_RC}"
echo "Then run:           squad --help"
echo ""
echo "Quick start:"
echo "  cd /your/project"
echo "  squad start                              # coder + tester"
echo "  squad start --roles planner,coder,tester # full harness"
echo "  squad harness \"Build a todo app\"         # headless mode"
echo ""

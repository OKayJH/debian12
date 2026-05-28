#!/usr/bin/env bash
set -euo pipefail

install_uv() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://astral.sh/uv/install.sh | sh
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- https://astral.sh/uv/install.sh | sh
  else
    echo "Error: curl or wget is required to install uv." >&2
    exit 1
  fi

  # Fix: uv installer modifies shell rcfiles (.bashrc/.zshrc/.profile)
  # but does NOT update the current shell PATH.
  # Source the env script so uv is available immediately in this shell.
  if [ -f "$HOME/.local/bin/env" ]; then
    . "$HOME/.local/bin/env"
  fi
}

if command -v uv >/dev/null 2>&1; then
  UV_BIN="uv"
else
  install_uv
  UV_BIN="uv"
fi

if ! command -v "$UV_BIN" >/dev/null 2>&1; then
  echo "Error: uv not found after installation." >&2
  exit 1
fi

"$UV_BIN" tool install --python 3.13 kimi-cli

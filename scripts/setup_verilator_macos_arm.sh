#!/usr/bin/env bash
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
  echo "[setup_verilator_macos_arm] Homebrew is required. Install it from https://brew.sh/ and re-run this script." >&2
  exit 1
fi

echo "[setup_verilator_macos_arm] Updating Homebrew formulas"
brew update

echo "[setup_verilator_macos_arm] Installing Verilator"
brew install verilator

echo "[setup_verilator_macos_arm] Verilator installation complete."

#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "[setup_verilator_ubuntu] This script installs packages via apt. Re-run with sudo or as root." >&2
  exit 1
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential \
  verilator \
  pkg-config \
  python3 \
  python3-pip

echo "[setup_verilator_ubuntu] Verilator installation complete."

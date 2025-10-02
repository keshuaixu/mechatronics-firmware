#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_ROOT="${REPO_ROOT}/espm_essj/sim/build"
mkdir -p "${BUILD_ROOT}"

RTL_SOURCES=(
  "${REPO_ROOT}/espm_essj/rtl/Crc16.v"
  "${REPO_ROOT}/espm_essj/rtl/ESPMComm.v"
  "${REPO_ROOT}/espm_essj/rtl/ESSJ_top.v"
  "${REPO_ROOT}/espm_essj/rtl/test_constants.v"
)

TESTS=(
  "espm_to_fpga_direct"
  "fpga_to_espm_direct"
  "espm_to_fpga_through_essj"
  "fpga_to_espm_through_essj"
)

for test in "${TESTS[@]}"; do
  TB_MODULE="tb_${test}"
  TB_FILE="${REPO_ROOT}/espm_essj/sim/${TB_MODULE}.v"
  CPP_MAIN="${REPO_ROOT}/espm_essj/sim/sim_main_${test}.cpp"
  BUILD_DIR="${BUILD_ROOT}/${test}"
  mkdir -p "${BUILD_DIR}"
  echo "[run_simulations] Building ${TB_MODULE}"
  verilator --timing -Wall --cc "${RTL_SOURCES[@]}" "${TB_FILE}" \
    --top-module "${TB_MODULE}" \
    --exe "${CPP_MAIN}" \
    --build \
    -Mdir "${BUILD_DIR}" \
    -o "${BUILD_DIR}/${test}_sim"
  echo "[run_simulations] Running ${TB_MODULE}"
  "${BUILD_DIR}/${test}_sim"
  echo "[run_simulations] ${TB_MODULE} completed"
  echo
done

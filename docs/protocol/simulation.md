# Simulation and Test Instructions

## Prerequisites

Install Verilator and the standard build toolchain.

- **Ubuntu**
  ```bash
  sudo ./scripts/setup_verilator_ubuntu.sh
  ```
- **macOS (Apple Silicon)**
  ```bash
  ./scripts/setup_verilator_macos_arm.sh
  ```
  > The macOS script assumes Homebrew is installed. If it is not, install
  > Homebrew from [brew.sh](https://brew.sh/) first.

## Running the Test Benches

Use the helper script to build and execute all Verilator simulations:

```bash
./scripts/run_simulations.sh
```

The script compiles the following scenarios under `espm_essj/sim/build/` and
runs them sequentially:

1. `tb_espm_to_fpga_direct` – baseline ESPM → FPGA1394 link without ESSJ.
2. `tb_fpga_to_espm_direct` – baseline FPGA1394 → ESPM link without ESSJ.
3. `tb_espm_to_fpga_through_essj` – ESPM → ESSJ → FPGA1394 bridge including ADC
   injection and CRC override.
4. `tb_fpga_to_espm_through_essj` – FPGA1394 → ESSJ → ESPM pass-through.

Each binary prints a PASS message upon success and the script stops on the first
failure.

## Artefact Locations

- Executables: `espm_essj/sim/build/<test>/<test>_sim`
- Generated C++ model: `espm_essj/sim/build/<test>/Vtb_<test>.cpp`
- Waveforms (enable via `--trace` edits): `espm_essj/sim/build/<test>/`

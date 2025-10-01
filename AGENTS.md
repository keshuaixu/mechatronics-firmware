# AGENTS.md — FPGA FPGA1394–ESSJ–ESPM Link (Bridge on ESSJ)

## Goal
Implement Board **ESSJ** communication so existing FPGA1394↔ESPM traffic runs through **FPGA1394–ESSJ–ESPM** with no protocol changes visible to FPGA1394 or ESPM. FPGA1394’s Verilog lives in this repo; we’ve added the ESPM‑side interface shim here as well. 

### Definition of Done
- ESSJ provides a **transparent** bridge for the FPGA1394–>ESPM link.
- ESSJ injects data into the ESPM–>FPGA1394 link:
  - Preserves framing, ordering, CRC.
  - ESSJ injects ADC readings into quadlets address 0x38-0x3F. The ADC readings come from a different clock domain.
  - Recompute the CRC of the modified packet so that FPGA1394 receives valid packets
  - ESSJ is allowed to add up to one quadlet latency to the link. If ESPM ended up providing a packet with bad CRC, ESSJ should invalid the packet by sending a bad CRC (0xDEAD).
- RTL code should be written in Verilog (not systemverilog). Should be synthesizable.
- Write test benches in Verilator. Validate 64-quadlet data transfers:
  - ESPM-FPGA1394
  - FPGA1394-ESPM
  - ESPM–ESSJ–FPGA1394
  - FPGA1394–ESSJ–ESPM
- Write instruction to run the test benches
- Write instruction to setup the toolchain/environment for the test benches. Both in Ubuntu and OSX (ARM).
- Simulation tests pass (see commands below) and code style/lint is clean.
- No changes to shipped FPGA1394 or ESPM RTL are required.

## Repo map
- `FPGA1394_QLA/Verilog` — FPGA1394‑side complete code. The communication protocol is defined in `ESPMComm.v`.
- `espm_essj/rtl` —  **Create/modify here.** ESPM‑side interface snippet we can share publicly. 
  - Target: `ESSJ_top.v` for top level on ESSJ.
  - Target: `ESPM_top.v` for top level on ESPM, for test purpose.
  - Target: `ESPMComm.v` add an `ESSJBridge` module for ESPM–>FPGA1394 link.
  - Target: `test_constants.v` to provide test definitions for undefined constants so that testbenches can run.
- `espm_essj/sim` — **Create/modify here.** Testbenches for FPGA1394–ESSJ–ESPM path, loopback, and error cases.
- `docs/protocol/` — **Create/modify here.** Add/keep protocol notes here (frame format, signals, CRC).
- `scripts/` — **Create/modify here.** Setup scripts for tools and lint/sim (Codex will run these).

## Wiring and clocks
Between adjacent boards are four differential pairs. clock and data in each direction. 
Each board has its own clock source.
The clock line is driven by the originating board (ESPM or FPGA1394). ESSJ should relay that clock.

## Dev environment & setup
Codex will run commands in a sandbox. Keep setup light-weight and deterministic.

- Install HDL toolchain (sim only):
  - Ubuntu: `./scripts/setup_verilator_ubuntu.sh`
  - macOS (ARM): `./scripts/setup_verilator_macos_arm.sh`

### Commands Codex should run
- `./scripts/run_simulations.sh`

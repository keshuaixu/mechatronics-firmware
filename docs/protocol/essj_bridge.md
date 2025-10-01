# ESSJ Bridge Architecture

The ESSJ board sits between the existing FPGA1394 and ESPM link partners and
provides two unidirectional data paths:

- **FPGA1394 → ESSJ → ESPM** is a transparent repeater. ESSJ forwards the clock
  and the serialized data stream without modification.
- **ESPM → ESSJ → FPGA1394** terminates the ESPM stream, injects ESSJ ADC data
  into the payload, recomputes the CRC, and re-transmits the packet to the
  FPGA1394 board.

## Module Overview

| Module | Purpose |
| --- | --- |
| `ESPMRX` | Deserializes the incoming quadlet stream and validates CRC.
| `ESSJBridge` | Buffers quadlets, merges ADC readings, requests CRC override
| `ESPMTX` | Serializes the quadlet payload, regenerating the link framing. |
| `ESSJ_top` | Connects the bridge to the board-level ports and handles the
clock forwarding on both directions. |

### ESPM → FPGA1394 path

1. `ESPMRX` captures each quadlet from the ESPM stream into a ping-pong buffer.
2. When a packet ends with a valid CRC, `ESSJBridge` updates quadlets 0x38–0x3F
   (56–63) with the most recent ADC samples and hands the buffer off to the
   transmitter.
3. `ESPMTX` serializes the updated packet and recomputes the CRC. When ESSJ has
   detected a CRC error on the inbound packet it requests the transmitter to
   send the fixed CRC value `0xDEAD` instead of the recomputed value, ensuring
   the downstream board treats the frame as invalid.
4. The ESPM-provided clock is forwarded to the FPGA1394 board so the serialized
   stream stays phase-aligned.

The bridge guarantees at most one quadlet of additional latency by swapping
between two payload buffers once a valid packet is observed.

### ADC Domain Crossing

External ADC readings are provided on a free-running `adc_clk`. Each update is
qualified with `adc_valid`, `adc_channel` (0–7) and `adc_value` (32-bit). ESSJ
uses a toggle-based CDC synchronizer so values cross safely into the ESPM link
clock domain. ADC values remain stable until the link clock domain acknowledges
receipt, preventing torn samples.

### CRC Override

`ESPMTX` exposes two new inputs:

- `crc_override_enable`
- `crc_override_value`

When asserted during the start of a frame, the transmitter substitutes the CRC
word with the override value. `ESSJBridge` raises the override request only when
an inbound packet failed its CRC check, making the downstream FPGA1394 aware of
upstream corruption while still streaming data.

## Transparent FPGA1394 → ESPM Path

`ESSJ_top` wires the FPGA1394-originated clock and data directly to the ESPM.
This keeps the outbound latency minimal and avoids re-timing in the bridge when
no data transformation is required.

## File Map

- RTL implementation: `espm_essj/rtl/ESSJ_top.v`
- Bridge logic: `espm_essj/rtl/ESPMComm.v` (`ESSJBridge` and `ESPMTX` updates)
- ADC constants for simulation: `espm_essj/rtl/test_constants.v`
- Simulation test benches: `espm_essj/sim/`

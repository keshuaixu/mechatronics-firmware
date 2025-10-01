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
| `ESPMRX` | Deserializes the incoming quadlet stream and validates CRC. |
| `ESSJBridge` | Streams quadlets through a FIFO, merges ADC readings, and
  requests CRC override |
| `ESPMTX` | Serializes the quadlet payload, regenerating the link framing. |
| `ESSJ_top` | Connects the bridge to the board-level ports and handles the
clock forwarding on both directions. |

### ESPM → FPGA1394 path

1. `ESPMRX` presents each quadlet from the ESPM stream to `ESSJBridge` as soon as
   it is received.
2. `ESSJBridge` immediately decides whether that quadlet belongs to the ADC
   window (addresses 0x38–0x3F). If so, it substitutes the most recent ADC
   readings captured from the asynchronous domain; otherwise it forwards the
   ESPM quadlet unchanged.
3. The selected quadlet is written into a **single streaming FIFO**. Once the
   leading quadlet for the frame is available the bridge can start feeding data
   to the serializer while the rest of the packet is still arriving, keeping the
   end-to-end latency to one quadlet.
4. `ESPMTX` serializes the updated packet and recomputes the CRC. When ESSJ has
   detected a CRC error on the inbound packet it requests the transmitter to
   send the fixed CRC value `0xDEAD` instead of the recomputed value, ensuring
   the downstream board treats the frame as invalid.
5. The ESPM-provided clock is forwarded to the FPGA1394 board so the serialized
   stream stays phase-aligned.

### Streaming FIFO operation

`ESSJBridge` maintains a circular FIFO (`payload_fifo`) that stores only the
payload quadlets (up to 64 entries). A pair of six-bit write/read pointers and a
seven-bit occupancy counter tracks the in-flight quadlets. The key behaviors are:

- **Frame detection:** When `rx_index` returns to zero the bridge latches the new
  frame length and page, resets its launch bookkeeping, and begins filling the
  FIFO from the current write pointer.
- **Prime quadlet staging:** The first quadlet of the frame is captured in a
  dedicated `prime_quadlet_reg` alongside a valid flag. This quadlet will be the
  first word emitted once the serializer begins the frame.
- **Launch conditions:** The bridge waits until the FIFO holds at least one
  queued quadlet beyond the prime word (or the frame is only one quadlet long).
  At that point it deasserts `hold_frame`, loads the prime quadlet into
  `ESPMTX`, and allows reads to start draining from the FIFO.
- **Concurrent read/write:** Because the serializer drains quadlets while the
  receiver is still populating the FIFO, the bridge uses `launch_pending` to
  ensure the FIFO never underflows at the start of a frame. Writes continue to
  advance the write pointer even while reads are occurring.
- **Frame completion:** When `ESPMTX` signals `frame_done`, the bridge reasserts
  `hold_frame` so the serializer waits for the next prime quadlet before
  restarting.

With this streaming structure the bridge does not wait for the full packet to
arrive; it only buffers enough data to cover the serializer’s one-quadlet head
start, meeting the latency requirement.

### ADC Domain Crossing

External ADC readings are provided on a free-running `adc_clk`. Each update is
qualified with `adc_valid`, `adc_channel` (0–7) and `adc_value` (32-bit). ESSJ
uses a toggle-based CDC synchronizer so values cross safely into the ESPM link
clock domain. ADC values remain stable until the link clock domain acknowledges
receipt, preventing torn samples.

### CRC Override

`ESPMTX` exposes two inputs:

- `crc_override_enable`
- `crc_override_value`

When asserted during the start of a frame, the transmitter substitutes the CRC
word with the override value. `ESSJBridge` raises the override request only when
an inbound packet failed its CRC check (or when the Verilator testbench forces
one), making the downstream FPGA1394 aware of upstream corruption while still
streaming data.

## Transparent FPGA1394 → ESPM Path

`ESSJ_top` wires the FPGA1394-originated clock and data directly to the ESPM.
This keeps the outbound latency minimal and avoids re-timing in the bridge when
no data transformation is required.

## File Map

- RTL implementation: `espm_essj/rtl/ESSJ_top.v`
- Bridge logic: `espm_essj/rtl/ESPMComm.v` (`ESSJBridge` and `ESPMTX` updates)
- ADC constants for simulation: `espm_essj/rtl/test_constants.v`
- Simulation test benches: `espm_essj/sim/`

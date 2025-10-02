`timescale 1ns / 1ps

// -----------------------------------------------------------------------------
// Example DRAC (FPGA1394) top level integrating the ESPM link blocks.
// -----------------------------------------------------------------------------
// This lightweight wrapper demonstrates how the legacy FPGA1394 "DRAC" design
// can source and sink the ESPM serial link without relying on the historical
// repository under `FPGA1394_QLA/Verilog`.  It instantiates the shared
// `ESPMTX`/`ESPMRX` blocks, exposes a simple payload memory interface, and keeps
// the streaming handshake explicit so new projects can start from a compact,
// self-contained example.
//
// The transmit side is clocked from `tx_clk` (forwarded to ESSJ/ESPM) and reads
// the quadlet payload out of a small BRAM-style array.  A host can update the
// payload one quadlet at a time before pulsing `tx_start` to launch a frame.
//
// The receive side captures quadlets presented by `ESPMRX` and mirrors them
// into another array.  A toggle-based CDC bridges the "frame complete" flag and
// the most recent metadata (page/length) into the transmit/host domain so the
// example stays fully synthesizable while still illustrating the multi-clock
// integration.
//
// This module purposely omits the thousands of board-specific lines that lived
// in the original DRAC source tree—the goal is simply to show the ESPM link
// glue without dragging the entire historical design into this repository.
// -----------------------------------------------------------------------------
module DRAC_top #(
    parameter integer PAYLOAD_WORDS = 64
) (
    input  wire        reset,

    // Clock domain that originates on the DRAC/FPGA board and is forwarded to
    // ESSJ for the DRAC→ESPM direction.
    input  wire        tx_clk,
    output wire        essj_tx_clk,
    output wire        essj_tx_dat,

    // Clock/data forwarded back from ESSJ when ESPM is transmitting towards the
    // DRAC/FPGA board.
    input  wire        rx_clk,
    input  wire        essj_rx_dat,

    // Host-side payload interface (tx_clk domain).
    input  wire        tx_payload_we,
    input  wire [5:0]  tx_payload_addr,
    input  wire [31:0] tx_payload_wdata,
    input  wire        tx_start,
    input  wire [15:0] tx_page,
    input  wire [9:0]  tx_length,
    input  wire        tx_crc_override_enable,
    input  wire [15:0] tx_crc_override_value,
    output wire        tx_busy,

    // Host-side access to the most recently received frame (tx_clk domain).
    input  wire [5:0]  rx_payload_addr,
    input  wire        rx_payload_re,
    output reg  [31:0] rx_payload_rdata,
    input  wire        rx_frame_clear,
    input  wire        rx_error_clear,
    output reg         rx_frame_ready,
    output reg         rx_crc_error,
    output reg  [15:0] rx_page_meta,
    output reg  [9:0]  rx_length_meta
);

    localparam integer PAYLOAD_BITS = (PAYLOAD_WORDS <= 1) ? 1 : $clog2(PAYLOAD_WORDS);
    localparam integer PAYLOAD_WORDS_CLAMP = (PAYLOAD_WORDS > 1024) ? 1024 : PAYLOAD_WORDS;

    assign essj_tx_clk = tx_clk;

    // ---------------------------------------------------------------------
    // Transmit payload storage and framing control (tx_clk domain)
    // ---------------------------------------------------------------------
    reg [31:0] tx_payload_mem [0:PAYLOAD_WORDS-1];
    integer i;

    always @(posedge tx_clk or posedge reset) begin
        if (reset) begin
            for (i = 0; i < PAYLOAD_WORDS; i = i + 1) begin
                tx_payload_mem[i] <= 32'd0;
            end
        end else if (tx_payload_we) begin
            tx_payload_mem[tx_payload_addr] <= tx_payload_wdata;
        end
    end

    reg        hold_frame_reg;
    reg        start_pending;
    reg [31:0] prime_quadlet_reg;
    reg        prime_valid_reg;

    wire [31:0] tx_mux_data;
    wire [9:0]  tx_sel;
    wire        frame_done;
    /* verilator lint_off UNUSED */
    wire        load_tdata;
    /* verilator lint_on UNUSED */

    assign tx_busy = start_pending || !hold_frame_reg;

    assign tx_mux_data = (tx_sel < PAYLOAD_WORDS_CLAMP) ?
                         tx_payload_mem[tx_sel[PAYLOAD_BITS-1:0]] : 32'd0;

    always @(posedge tx_clk or posedge reset) begin
        if (reset) begin
            hold_frame_reg   <= 1'b1;
            start_pending    <= 1'b0;
            prime_quadlet_reg<= 32'd0;
            prime_valid_reg  <= 1'b0;
        end else begin
            if (tx_start && !start_pending && hold_frame_reg) begin
                start_pending     <= 1'b1;
                prime_quadlet_reg <= tx_payload_mem[0];
                prime_valid_reg   <= 1'b1;
            end

            if (start_pending && hold_frame_reg) begin
                hold_frame_reg <= 1'b0;
            end

            if (frame_done) begin
                hold_frame_reg  <= 1'b1;
                start_pending   <= 1'b0;
                prime_valid_reg <= 1'b0;
            end
        end
    end

    wire [9:0] tx_length_effective = (tx_length == 10'd0) ? 10'd64 : tx_length;

    /* verilator lint_off UNUSED */
    wire [1:0] tx_cfsm_unused;
    wire       tx_pkt_start_unused;
    /* verilator lint_on UNUSED */

    ESPMTX tx_inst (
        .clock               (tx_clk),
        .tdata               (tx_mux_data),
        .page                (tx_page),
        .length              (tx_length_effective),
        .crc_override_enable (tx_crc_override_enable),
        .crc_override_value  (tx_crc_override_value),
        .hold_frame          (hold_frame_reg),
        .prime_quadlet       (prime_quadlet_reg),
        .prime_valid         (prime_valid_reg),
        .cfsm                (tx_cfsm_unused),
        .tdata_sel           (tx_sel),
        .pkt_start           (tx_pkt_start_unused),
        .load_tdata          (load_tdata),
        .tdat                (essj_tx_dat),
        .frame_done          (frame_done)
    );

    // ---------------------------------------------------------------------
    // Receive path (rx_clk domain)
    // ---------------------------------------------------------------------
    reg [31:0] rx_payload_mem [0:PAYLOAD_WORDS-1];
    reg        frame_toggle_rx;
    reg        error_toggle_rx;
    reg [15:0] page_meta_rx;
    reg [9:0]  length_meta_rx;

    wire [31:0] rx_data;
    wire        rx_load;
    wire [9:0]  rx_index;
    wire        rx_crc_good;
    wire        rx_eof;
    wire [15:0] rx_page;
    wire [9:0]  rx_length;

    /* verilator lint_off UNUSED */
    wire [1:0] rx_cfsm_unused;
    wire       rx_framed_unused;
    /* verilator lint_on UNUSED */

    ESPMRX rx_inst (
        .clock      (rx_clk),
        .rdat       (essj_rx_dat),
        .cfsm       (rx_cfsm_unused),
        .rdata      (rx_data),
        .load_rdata (rx_load),
        .rdata_sel  (rx_index),
        .framed     (rx_framed_unused),
        .crc_good   (rx_crc_good),
        .eof        (rx_eof),
        .page       (rx_page),
        .length     (rx_length)
    );

    always @(posedge rx_clk or posedge reset) begin
        if (reset) begin
            for (i = 0; i < PAYLOAD_WORDS; i = i + 1) begin
                rx_payload_mem[i] <= 32'd0;
            end
            frame_toggle_rx <= 1'b0;
            error_toggle_rx <= 1'b0;
            page_meta_rx    <= 16'd0;
            length_meta_rx  <= 10'd0;
        end else begin
            if (rx_load && (rx_index < PAYLOAD_WORDS_CLAMP)) begin
                rx_payload_mem[rx_index[PAYLOAD_BITS-1:0]] <= rx_data;
            end
            if (rx_crc_good) begin
                page_meta_rx    <= rx_page;
                length_meta_rx  <= rx_length;
                frame_toggle_rx <= ~frame_toggle_rx;
            end
            if (rx_eof && !rx_crc_good) begin
                error_toggle_rx <= ~error_toggle_rx;
            end
        end
    end

    // ---------------------------------------------------------------------
    // CDC of receive status into tx_clk / host domain
    // ---------------------------------------------------------------------
    reg frame_toggle_sync1;
    reg frame_toggle_sync2;
    reg error_toggle_sync1;
    reg error_toggle_sync2;

    always @(posedge tx_clk or posedge reset) begin
        if (reset) begin
            frame_toggle_sync1 <= 1'b0;
            frame_toggle_sync2 <= 1'b0;
            error_toggle_sync1 <= 1'b0;
            error_toggle_sync2 <= 1'b0;
            rx_frame_ready     <= 1'b0;
            rx_crc_error       <= 1'b0;
            rx_page_meta       <= 16'd0;
            rx_length_meta     <= 10'd0;
        end else begin
            frame_toggle_sync1 <= frame_toggle_rx;
            frame_toggle_sync2 <= frame_toggle_sync1;
            error_toggle_sync1 <= error_toggle_rx;
            error_toggle_sync2 <= error_toggle_sync1;

            if (frame_toggle_sync1 != frame_toggle_sync2) begin
                rx_frame_ready <= 1'b1;
                rx_page_meta   <= page_meta_rx;
                rx_length_meta <= length_meta_rx;
            end else if (rx_frame_clear) begin
                rx_frame_ready <= 1'b0;
            end

            if (error_toggle_sync1 != error_toggle_sync2) begin
                rx_crc_error <= 1'b1;
            end else if (rx_error_clear) begin
                rx_crc_error <= 1'b0;
            end
        end
    end

    // ---------------------------------------------------------------------
    // Host-side read of captured payload (tx_clk domain)
    // ---------------------------------------------------------------------
    always @(posedge tx_clk) begin
        if (rx_payload_re) begin
            rx_payload_rdata <= rx_payload_mem[rx_payload_addr];
        end
    end

endmodule

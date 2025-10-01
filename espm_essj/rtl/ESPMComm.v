/*******************************************************************************
 *
 * Copyright(C) 2017-2024 ERC CISST, Johns Hopkins University
 *
 * Module: ESPMComm
 *
 * Purpose: This file contains the receiving module (ESPMRX) and transmitting
 *          module (ESPMTX) of the duplex communication between the dVRK board
 *          and the ESPM board on the da Vinci Si PSM.
 *          The communication is in three stages.
 *          FRAME:  Looks for 32-bit frame, 32'hAC450F28
 *          R_DATA: Expects 25 32-bit words
 *          R_CRC:  Checks against a 16-bit CRC
 *
 * Revision history
 *     07/14/17    Jie Ying Wu    Initial revision
 */

`timescale 1ns / 1ps

/* verilator lint_off DECLFILENAME */

`define ESPMCOMM_MAGIC 32'hAC450F28

module ESPMRX (input wire clock,                 // bit clock for ESPM chain
               input wire rdat,                  // serial data in
               output reg [1:0] cfsm,
               output wire [31:0] rdata,          // UNREGISTERED receive data - load when load_rdata asserts
               output wire load_rdata,            // time to load rdata
               output wire [9:0] rdata_sel,       //
               output reg framed,         // we saw a valid framing sequence for the current packet
               output reg crc_good,              // received a pkt with good CRC
               output reg eof,                   // end of packet
               output reg [15:0] page,
               output reg [9:0] length);

    // internal variables
    wire [15:0] crc_data;

    reg [14:0] bit_ctr = 15'd0;
    assign rdata_sel   = bit_ctr[14:5] - 10'd2;
    wire [4:0] bit_sel = bit_ctr[4:0];
    wire load_crc = bit_sel[2:0] == 'b111 && cfsm != R_CRC;
    assign load_rdata = bit_sel == 'd31 && cfsm == R_DATA;

    reg [31:0] rdata_shift;
    assign rdata = rdata_shift;

    reg [5:0] recovery_extra_delay = 6'd0;
    reg recovery_extra_delay_en = 1'b0;


    localparam FRAME = 2'h0,
    R_HEADER = 2'h1,
    R_DATA = 2'h2,
    R_CRC = 2'h3;

    initial begin
        cfsm = FRAME;
    end

    //----------------------------------------------------------------------------------------------
    always @(posedge clock)
    begin
        bit_ctr <= (cfsm == FRAME) ? 15'd32 : bit_ctr + 15'b1;

        case (cfsm)
            FRAME: begin
                eof       <= 'b0;
                crc_good  <= 'b0;
                if (rdata_shift == `ESPMCOMM_MAGIC) begin
                    framed    <= 'b1;
                    cfsm      <= R_HEADER;
                end
            end

            R_HEADER: begin
                if (bit_sel == 'd31) begin
                    cfsm <= R_DATA;
                    length <= rdata_shift[9:0] + (recovery_extra_delay_en ? {4'd0, recovery_extra_delay} : 10'd0);
                    page <= rdata_shift[31:16];
                end
            end

            R_DATA: begin
                if ((bit_sel == 'd31) && (rdata_sel == length - 'd1)) begin
                    cfsm <= R_CRC;
                end
            end

            R_CRC: begin
                if (bit_sel == 'd31) begin
                    framed  <= 'b0;
                    eof     <= 'b1;
                    cfsm    <= FRAME;
                    if (crc_data == rdata_shift[15:0]) begin
                        crc_good       <= 'b1;
                        recovery_extra_delay_en <= 1'b0;
                        recovery_extra_delay <= 'd0;
                    end else begin
                        recovery_extra_delay_en <= (recovery_extra_delay > 6'd3) ? ~recovery_extra_delay_en : 1'b0;
                        recovery_extra_delay <= recovery_extra_delay + 6'd1;
                    end
                end
            end
        endcase
    end

    always @ (negedge clock) begin
        rdata_shift <= {rdat, rdata_shift[31:1]};  // always right shift in data
    end

    wire [7:0] crc_input = rdata_shift[31:24];

    crc16 CRC (
    .clock   (clock),
    .init    (cfsm == FRAME),
    .ena     (load_crc), 
    .data    (crc_input),
    .q       (crc_data)
    );

endmodule

/* verilator lint_on DECLFILENAME */


module ESSJBridge #(
    parameter integer PAYLOAD_WORDS    = 64,
    parameter integer ADC_WORD_COUNT   = 8,
    parameter integer ADC_BASE_QUADLET = 56
)(
    input  wire        clock,
    input  wire        reset,

    // ESPMRX interface
    input  wire [31:0] rx_data,
    input  wire        rx_load,
    input  wire [9:0]  rx_index,
    input  wire        rx_crc_good,
    input  wire        rx_eof,
    input  wire [15:0] rx_page,
    input  wire [9:0]  rx_length,

    // ADC domain interface
    input  wire        adc_clk,
    input  wire        adc_valid,
    input  wire [2:0]  adc_channel,
    input  wire [31:0] adc_value,

    // Serial output towards FPGA1394
    output wire        tdat,
    output wire [1:0]  tx_cfsm,
    output wire        pkt_start,
    output wire [9:0]  tdata_sel,
    output wire        load_tdata
`ifdef VERILATOR
    , input  wire       debug_force_bad_crc
    , output wire       debug_crc_override_request
    , output wire [15:0] debug_crc_override_value
`endif
    );

    localparam [9:0] PAYLOAD_WORDS_10B = PAYLOAD_WORDS[9:0];

    // Ping-pong payload storage
    reg [31:0] payload_mem [0:1][0:PAYLOAD_WORDS-1];
    reg [15:0] page_mem [0:1];
    reg [9:0]  length_mem [0:1];
    reg        active_bank;
    reg        write_bank;

    // ADC synchronization registers
    reg [31:0] adc_shadow [0:ADC_WORD_COUNT-1];
    reg [31:0] adc_values [0:ADC_WORD_COUNT-1];
    reg [ADC_WORD_COUNT-1:0] adc_req_toggle;
    reg [ADC_WORD_COUNT-1:0] adc_ack_toggle;
    reg [ADC_WORD_COUNT-1:0] adc_ack_sync1;
    reg [ADC_WORD_COUNT-1:0] adc_ack_sync2;
    reg [ADC_WORD_COUNT-1:0] adc_req_sync1;
    reg [ADC_WORD_COUNT-1:0] adc_req_sync2;

    // CRC management
    reg force_bad_crc;
    reg crc_override_request;

    integer idx;
    integer adc_slot;

    wire debug_force_bad_crc_active;
`ifdef VERILATOR
    assign debug_force_bad_crc_active = debug_force_bad_crc;
`else
    assign debug_force_bad_crc_active = 1'b0;
`endif

    // ---------------------------------------------------------------------
    // ADC clock domain logic
    // ---------------------------------------------------------------------
    always @(posedge adc_clk or posedge reset) begin
        if (reset) begin
            for (idx = 0; idx < ADC_WORD_COUNT; idx = idx + 1) begin
                adc_shadow[idx]    <= 32'd0;
                adc_req_toggle[idx]<= 1'b0;
            end
            adc_ack_sync1 <= {ADC_WORD_COUNT{1'b0}};
            adc_ack_sync2 <= {ADC_WORD_COUNT{1'b0}};
        end else begin
            adc_ack_sync1 <= adc_ack_toggle;
            adc_ack_sync2 <= adc_ack_sync1;

            if (adc_valid && {{29{1'b0}}, adc_channel} < ADC_WORD_COUNT) begin
                if (adc_ack_sync2[adc_channel] == adc_req_toggle[adc_channel]) begin
                    adc_shadow[adc_channel]     <= adc_value;
                    adc_req_toggle[adc_channel] <= ~adc_req_toggle[adc_channel];
                end
            end
        end
    end

    // ---------------------------------------------------------------------
    // ESSJ clock domain logic
    // ---------------------------------------------------------------------
    reg [9:0] sanitized_length_temp;

    always @(posedge clock or posedge reset) begin
        if (reset) begin
            active_bank          <= 1'b0;
            write_bank           <= 1'b1;
            force_bad_crc        <= 1'b0;
            crc_override_request <= 1'b0;
            adc_req_sync1        <= {ADC_WORD_COUNT{1'b0}};
            adc_req_sync2        <= {ADC_WORD_COUNT{1'b0}};
            adc_ack_toggle       <= {ADC_WORD_COUNT{1'b0}};
            for (idx = 0; idx < ADC_WORD_COUNT; idx = idx + 1) begin
                adc_values[idx] <= 32'd0;
            end
            for (idx = 0; idx < PAYLOAD_WORDS; idx = idx + 1) begin
                payload_mem[0][idx] <= 32'd0;
                payload_mem[1][idx] <= 32'd0;
            end
            page_mem[0]   <= 16'd0;
            page_mem[1]   <= 16'd0;
            length_mem[0] <= PAYLOAD_WORDS_10B;
            length_mem[1] <= PAYLOAD_WORDS_10B;
        end else begin
            adc_req_sync1 <= adc_req_toggle;
            adc_req_sync2 <= adc_req_sync1;

            for (idx = 0; idx < ADC_WORD_COUNT; idx = idx + 1) begin
                if (adc_req_sync2[idx] != adc_ack_toggle[idx]) begin
                    adc_values[idx]   <= adc_shadow[idx];
                    adc_ack_toggle[idx]<= adc_req_sync2[idx];
                end
            end

            if (rx_load && rx_index < PAYLOAD_WORDS_10B) begin
                payload_mem[write_bank][rx_index[5:0]] <= rx_data;
            end

            if (rx_eof) begin
                if (rx_crc_good) begin
                    /* verilator lint_off BLKSEQ */
                    sanitized_length_temp = (rx_length > PAYLOAD_WORDS_10B) ? PAYLOAD_WORDS_10B : rx_length;
                    if (sanitized_length_temp == 10'd0) begin
                        sanitized_length_temp = PAYLOAD_WORDS_10B;
                    end
                    /* verilator lint_on BLKSEQ */

                    page_mem[write_bank]   <= rx_page;
                    length_mem[write_bank] <= sanitized_length_temp;

                    for (idx = 0; idx < ADC_WORD_COUNT; idx = idx + 1) begin
                        /* verilator lint_off BLKSEQ */
                        adc_slot = ADC_BASE_QUADLET + idx;
                        /* verilator lint_on BLKSEQ */
                        if (adc_slot < PAYLOAD_WORDS &&
                            adc_slot < {{22{1'b0}}, sanitized_length_temp}) begin
                            payload_mem[write_bank][adc_slot] <= adc_values[idx];
                        end
                    end

                    active_bank   <= write_bank;
                    write_bank    <= ~write_bank;
                    force_bad_crc <= 1'b0;
                end else begin
                    force_bad_crc <= 1'b1;
                end
            end

            if (debug_force_bad_crc_active) begin
                force_bad_crc <= 1'b1;
            end

            if (pkt_start) begin
                crc_override_request <= force_bad_crc | debug_force_bad_crc_active;
                if (force_bad_crc | debug_force_bad_crc_active) begin
                    force_bad_crc <= 1'b0;
                end
            end else begin
                crc_override_request <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------
    // Transmit data selection
    // ------------------------------------------------------------------
    reg [31:0] tx_data_mux;
    wire [9:0] tx_length_active;
    assign tx_length_active = (length_mem[active_bank] == 10'd0) ? PAYLOAD_WORDS_10B : length_mem[active_bank];

    always @(*) begin
        if (tdata_sel < PAYLOAD_WORDS_10B) begin
            tx_data_mux = payload_mem[active_bank][tdata_sel[5:0]];
        end else begin
            tx_data_mux = 32'd0;
        end
    end

    ESPMTX tx (
        .clock              (clock),
        .tdata              (tx_data_mux),
        .page               (page_mem[active_bank]),
        .length             (tx_length_active),
        .crc_override_enable(crc_override_request),
        .crc_override_value (16'hDEAD),
        .cfsm               (tx_cfsm),
        .tdata_sel          (tdata_sel),
        .pkt_start          (pkt_start),
        .load_tdata         (load_tdata),
        .tdat               (tdat)
    );

`ifdef VERILATOR
    assign debug_crc_override_request = crc_override_request;
    assign debug_crc_override_value   = 16'hDEAD;
`endif

endmodule


module ESPMTX (
    input  wire        clock,      // received clock from ESM
    input  wire [31:0] tdata,      // parallel transmit data (output of mux selected by tdata_sel)
    input  [15:0]      page,
    input  [9:0]       length,
    input  wire        crc_override_enable,
    input  wire [15:0] crc_override_value,

    output reg   [1:0] cfsm,       // current state
    output wire  [9:0] tdata_sel,  // 6 bit counter that selects tdata multiplexor
    output reg         pkt_start,  // starting to xmit a new packet
    output reg         load_tdata, // loading serializer from parallel input
    output reg         tdat);      // serial data out

    // internal variables
    wire  [15:0]  crc_data;

    reg [14:0] bit_ctr = 'd0;

    // There are 2 quadlets before the payload, but here we advance the tdata_sel by 1
    // to give some timing margin for the data source.
    assign tdata_sel   = bit_ctr[14:5] - 10'd1;
    wire [4:0] bit_sel = bit_ctr[4:0];

    reg [15:0] page_latched;
    reg [9:0] length_latched;
    reg [31:0] current_quadlet;
    reg [31:0] payload_buffer;
    reg        crc_override_active;
    reg [15:0] crc_override_latched;

    localparam FRAME = 2'h0,  // transmit framing sequence
    T_HEADER = 2'h1,  // transmit header
    T_DATA = 2'h2,  // transmit data
    T_CRC = 2'h3; // transmit CRC

    initial
    begin
        pkt_start           = 'b0;
        load_tdata          = 'd0;
        cfsm                = FRAME;  // start by framing on the recv data
        crc_override_active = 1'b0;
        crc_override_latched= 16'd0;
    end

    //----------------------------------------------------------------------------------------------

    always @(*) begin
        case (cfsm)
            FRAME: current_quadlet = `ESPMCOMM_MAGIC;
            T_HEADER: current_quadlet = {page_latched, 6'b0, length_latched};
            T_DATA: current_quadlet = payload_buffer;
            T_CRC: current_quadlet = {16'b0, crc_override_active ? crc_override_latched : crc_data};
            default: current_quadlet = 32'hcccccccc;
        endcase
    end

    always @(posedge clock) begin
        bit_ctr <= bit_ctr + 1'b1;
        tdat <= current_quadlet[bit_sel];

        if (bit_ctr == 'd31) begin
            page_latched <= page;
            length_latched <= length;
        end
        if (load_tdata) begin
            payload_buffer <= tdata;
        end
        pkt_start <= bit_ctr == 'd0;
        load_tdata <= bit_sel == 'd30; // assert at 30 to load at 31 because of pipelining

        if (bit_ctr == 'd0) begin
            if (crc_override_enable) begin
                crc_override_active  <= 1'b1;
                crc_override_latched <= crc_override_value;
            end else begin
                crc_override_active  <= 1'b0;
            end
        end

        case (cfsm)
            FRAME: begin
                if (bit_sel == 'd31) cfsm <= T_HEADER;
            end

            T_HEADER: begin
                if (bit_sel == 'd31) cfsm <= T_DATA;
            end

            T_DATA: begin
                if ((bit_sel == 'd31) & (tdata_sel == length_latched)) begin
                    cfsm    <= T_CRC;
                end
            end

            T_CRC: begin
                if (bit_sel == 'd31) begin
                    cfsm    <= FRAME;
                    bit_ctr <= 'd0;
                    crc_override_active <= 1'b0;
                end
            end
        endcase
    end

    reg crc_en = 'b0;
    reg [7:0] crc_input = 'b0;
    always @(posedge clock) begin
        case (bit_sel[1:0])
            'b00: crc_input <= current_quadlet[7:0];
            'b01: crc_input <= current_quadlet[15:8];
            'b10: crc_input <= current_quadlet[23:16];
            'b11: crc_input <= current_quadlet[31:24];
            default: crc_input <= 'b0;
        endcase
        crc_en <= bit_sel[4:2] == 'b0 && cfsm != T_CRC;
    end


    crc16 CRC (
    .clock   (clock),
    .init    (cfsm == FRAME),
    .ena     (crc_en),
    .data    (crc_input),
    .q       (crc_data)
    );

endmodule

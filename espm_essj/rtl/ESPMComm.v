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

    // ADC synchronization registers
    reg [31:0] adc_shadow [0:ADC_WORD_COUNT-1];
    reg [31:0] adc_values [0:ADC_WORD_COUNT-1];
    reg [ADC_WORD_COUNT-1:0] adc_req_toggle;
    reg [ADC_WORD_COUNT-1:0] adc_ack_toggle;
    reg [ADC_WORD_COUNT-1:0] adc_ack_sync1;
    reg [ADC_WORD_COUNT-1:0] adc_ack_sync2;
    reg [ADC_WORD_COUNT-1:0] adc_req_sync1;
    reg [ADC_WORD_COUNT-1:0] adc_req_sync2;

    integer idx;

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
    // ESSJ clock domain logic (streaming payload forwarding)
    // ---------------------------------------------------------------------
    localparam [1:0] TX_STATE_DATA = 2'h2;
    localparam [1:0] TX_STATE_CRC  = 2'h3;

    reg [31:0] payload_fifo [0:PAYLOAD_WORDS-1];
    reg [5:0]  fifo_wr_ptr;
    reg [5:0]  fifo_rd_ptr;
    reg [6:0]  fifo_count;

    reg [9:0]  current_length;
    reg [15:0] current_page;
    reg [9:0]  tx_length_reg;
    reg [15:0] tx_page_reg;
    reg        frame_ready;
    reg        hold_frame;
    reg        override_pending;
    reg [31:0] prime_quadlet_reg;
    reg        prime_valid_reg;
    reg [31:0] tx_prime_quadlet;
    reg        tx_prime_valid;

    function [9:0] sanitize_length;
        input [9:0] raw_length;
        begin
            if (raw_length == 10'd0) begin
                sanitize_length = PAYLOAD_WORDS_10B;
            end else if (raw_length > PAYLOAD_WORDS_10B) begin
                sanitize_length = PAYLOAD_WORDS_10B;
            end else begin
                sanitize_length = raw_length;
            end
        end
    endfunction

    always @(posedge clock or posedge reset) begin
        if (reset) begin
            adc_req_sync1  <= {ADC_WORD_COUNT{1'b0}};
            adc_req_sync2  <= {ADC_WORD_COUNT{1'b0}};
            adc_ack_toggle <= {ADC_WORD_COUNT{1'b0}};
            for (idx = 0; idx < ADC_WORD_COUNT; idx = idx + 1) begin
                adc_values[idx] <= 32'd0;
            end
        end else begin
            adc_req_sync1 <= adc_req_toggle;
            adc_req_sync2 <= adc_req_sync1;

            for (idx = 0; idx < ADC_WORD_COUNT; idx = idx + 1) begin
                if (adc_req_sync2[idx] != adc_ack_toggle[idx]) begin
                    adc_values[idx]    <= adc_shadow[idx];
                    adc_ack_toggle[idx] <= adc_req_sync2[idx];
                end
            end
        end
    end

    wire frame_start_detect = rx_load && (rx_index == 10'd0);
    wire [9:0] sanitized_length_next = sanitize_length(rx_length);

    wire [9:0] active_length_for_write = (frame_ready || !hold_frame) ? current_length : sanitized_length_next;

    wire [9:0] rx_index_ext = rx_index;
    wire [9:0] adc_base_quadlet_10b = ADC_BASE_QUADLET[9:0];
    wire [9:0] adc_window_end_10b   = ADC_BASE_QUADLET[9:0] + ADC_WORD_COUNT[9:0];
    wire in_adc_window = (rx_index_ext >= adc_base_quadlet_10b) &&
                         (rx_index_ext < adc_window_end_10b);
    /* verilator lint_off UNUSEDSIGNAL */
    wire [9:0] adc_offset = rx_index_ext - adc_base_quadlet_10b;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [2:0] adc_lookup_index = adc_offset[2:0];

    reg [31:0] fifo_write_data;
    always @(*) begin
        if (in_adc_window) begin
            fifo_write_data = adc_values[adc_lookup_index];
        end else begin
            fifo_write_data = rx_data;
        end
    end

    wire fifo_write_candidate = rx_load && (rx_index_ext < PAYLOAD_WORDS_10B);
    wire first_word_write = fifo_write_candidate && (rx_index_ext == 10'd0);
    wire [6:0] payload_words_7b = PAYLOAD_WORDS[6:0];
    wire fifo_write_enable = fifo_write_candidate &&
                             (rx_index_ext < active_length_for_write) &&
                             (fifo_count < payload_words_7b);

    wire fifo_empty = fifo_count == 7'd0;
    wire frame_single_word = current_length <= 10'd1;
    reg  launch_pending;
    reg [5:0] frame_base_ptr;
    wire fifo_read_enable = (tx_cfsm == TX_STATE_DATA) && load_tdata && !fifo_empty;
    wire fifo_read_enable_effective = fifo_read_enable && !launch_pending;
    wire have_prime_entry = !fifo_empty || fifo_write_enable;
    wire have_two_entries = (fifo_count > 7'd1) || ((fifo_count == 7'd1) && fifo_write_enable);
    wire launch_ready = frame_single_word ? have_prime_entry : have_two_entries;

    always @(posedge clock or posedge reset) begin
        if (reset) begin
            fifo_wr_ptr      <= 6'd0;
            fifo_rd_ptr      <= 6'd0;
            fifo_count       <= 7'd0;
            current_length   <= PAYLOAD_WORDS_10B;
            current_page     <= 16'd0;
            tx_length_reg    <= PAYLOAD_WORDS_10B;
            tx_page_reg      <= 16'd0;
            frame_ready      <= 1'b0;
            hold_frame       <= 1'b1;
            prime_quadlet_reg<= 32'd0;
            prime_valid_reg  <= 1'b0;
            tx_prime_quadlet <= 32'd0;
            tx_prime_valid   <= 1'b0;
            launch_pending   <= 1'b0;
            frame_base_ptr   <= 6'd0;
        end else begin
            if (frame_start_detect) begin
                current_length    <= sanitized_length_next;
                current_page      <= rx_page;
                frame_ready       <= 1'b1;
                prime_valid_reg   <= 1'b0;
                launch_pending    <= 1'b0;
                frame_base_ptr    <= fifo_wr_ptr;
            end

            if (first_word_write && (rx_index_ext < active_length_for_write)) begin
                prime_quadlet_reg <= fifo_write_data;
                prime_valid_reg   <= 1'b1;
            end

            if (fifo_write_enable) begin
                payload_fifo[fifo_wr_ptr] <= fifo_write_data;
                fifo_wr_ptr <= fifo_wr_ptr + 6'd1;
            end

            if (fifo_read_enable_effective) begin
                fifo_rd_ptr <= fifo_rd_ptr + 6'd1;
            end

            case ({fifo_write_enable, fifo_read_enable_effective})
                2'b10: fifo_count <= fifo_count + 7'd1;
                2'b01: fifo_count <= fifo_count - 7'd1;
                default: fifo_count <= fifo_count;
            endcase

            if (hold_frame && frame_ready &&
                prime_valid_reg && launch_ready) begin
                launch_pending <= 1'b1;
            end

            if (launch_pending) begin
                tx_length_reg <= current_length;
                tx_page_reg   <= current_page;
                tx_prime_quadlet <= prime_quadlet_reg;
                tx_prime_valid   <= prime_valid_reg;
                hold_frame    <= 1'b0;
                frame_ready   <= 1'b0;
                prime_valid_reg <= 1'b0;
                fifo_rd_ptr <= frame_base_ptr + 6'd1;
                if (fifo_count != 7'd0) begin
                    fifo_count  <= fifo_count - 7'd1;
                end
                launch_pending <= 1'b0;
            end else if (frame_done) begin
                hold_frame <= 1'b1;
                tx_prime_valid <= 1'b0;
            end
        end
    end

    always @(posedge clock or posedge reset) begin
        if (reset) begin
            override_pending <= 1'b0;
        end else begin
            if (rx_eof && !rx_crc_good) begin
                override_pending <= 1'b1;
            end
            if (debug_force_bad_crc_active) begin
                override_pending <= 1'b1;
            end
            if (frame_done) begin
                override_pending <= 1'b0;
            end
        end
    end

    wire [31:0] tx_data_stream = payload_fifo[fifo_rd_ptr];
    wire [9:0] tx_length_active = (tx_length_reg == 10'd0) ? PAYLOAD_WORDS_10B : tx_length_reg;
    wire        frame_done;

    ESPMTX tx (
        .clock              (clock),
        .tdata              (tx_data_stream),
        .page               (tx_page_reg),
        .length             (tx_length_active),
        .crc_override_enable(override_pending),
        .crc_override_value (16'hDEAD),
        .hold_frame         (hold_frame),
        .prime_quadlet      (tx_prime_quadlet),
        .prime_valid        (tx_prime_valid),
        .frame_done         (frame_done),
        .cfsm               (tx_cfsm),
        .tdata_sel          (tdata_sel),
        .pkt_start          (pkt_start),
        .load_tdata         (load_tdata),
        .tdat               (tdat)
    );

`ifdef VERILATOR
    assign debug_crc_override_request = override_pending && (tx_cfsm == TX_STATE_CRC);
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
    input  wire        hold_frame,
    input  wire [31:0] prime_quadlet,
    input  wire        prime_valid,

    output reg   [1:0] cfsm,       // current state
    output wire  [9:0] tdata_sel,  // 6 bit counter that selects tdata multiplexor
    output reg         pkt_start,  // starting to xmit a new packet
    output reg         load_tdata, // loading serializer from parallel input
    output reg         tdat,       // serial data out
    output reg         frame_done  // pulses high for one cycle at end of CRC
    );

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
    reg        prime_active;
    wire       hold_active;

    assign hold_active = hold_frame && (cfsm == FRAME) && (bit_ctr == 15'd0);

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
        frame_done          = 1'b0;
        prime_active        = 1'b0;
    end

    //----------------------------------------------------------------------------------------------

    always @(*) begin
        case (cfsm)
            FRAME: current_quadlet = `ESPMCOMM_MAGIC;
            T_HEADER: current_quadlet = {page_latched, 6'b0, length_latched};
            T_DATA: current_quadlet = prime_active ? prime_quadlet : payload_buffer;
            T_CRC: current_quadlet = {16'b0, crc_override_active ? crc_override_latched : crc_data};
            default: current_quadlet = 32'hcccccccc;
        endcase
    end

    always @(posedge clock) begin
        if (hold_active) begin
            bit_ctr    <= 15'd0;
            pkt_start  <= 1'b0;
            load_tdata <= 1'b0;
            tdat       <= 1'b0;
            frame_done <= 1'b0;
            prime_active <= 1'b0;
        end else begin
            bit_ctr <= bit_ctr + 1'b1;
            tdat    <= current_quadlet[bit_sel];

            if (bit_ctr == 'd31) begin
                page_latched   <= page;
                length_latched <= length;
            end
            if (load_tdata) begin
                payload_buffer <= tdata;
            end
            pkt_start  <= bit_ctr == 'd0;
            load_tdata <= bit_sel == 'd30; // assert at 30 to load at 31 because of pipelining
            frame_done <= (cfsm == T_CRC) && (bit_sel == 'd31);

            if ((cfsm == T_DATA) && (bit_sel == 'd31) && (tdata_sel == length_latched)) begin
                if (crc_override_enable) begin
                    crc_override_active  <= 1'b1;
                    crc_override_latched <= crc_override_value;
                end else begin
                    crc_override_active <= 1'b0;
                end
            end else if ((cfsm == T_CRC) && (bit_sel == 'd31)) begin
                crc_override_active <= 1'b0;
            end

            case (cfsm)
                FRAME: begin
                    if (bit_sel == 'd31) cfsm <= T_HEADER;
                end

                T_HEADER: begin
                    if (bit_sel == 'd31) begin
                        cfsm        <= T_DATA;
                        prime_active<= prime_valid;
                    end
                end

                T_DATA: begin
                    if ((bit_sel == 'd31) & (tdata_sel == length_latched)) begin
                        cfsm    <= T_CRC;
                        prime_active <= 1'b0;
                    end else if (bit_sel == 'd31) begin
                        prime_active <= 1'b0;
                    end
                end

                T_CRC: begin
                    if (bit_sel == 'd31) begin
                        cfsm    <= FRAME;
                        bit_ctr <= 'd0;
                    end
                end
            endcase
        end
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

`timescale 1ns / 1ps

module ESSJ_top (
    input  wire        reset,

    // ESPM -> ESSJ -> FPGA1394 path
    input  wire        espm_tx_clk,
    input  wire        espm_tx_dat,
    output wire        fpga_rx_clk,
    output wire        fpga_rx_dat,

    // FPGA1394 -> ESSJ -> ESPM path
    input  wire        fpga_tx_clk,
    input  wire        fpga_tx_dat,
    output wire        espm_rx_clk,
    output wire        espm_rx_dat,

    // ADC update interface (asynchronous)
    input  wire        adc_clk,
    input  wire        adc_valid,
    input  wire [2:0]  adc_channel,
    input  wire [31:0] adc_value
`ifdef VERILATOR
    , input  wire       debug_force_bad_crc
    , output wire       debug_crc_override_request
    , output wire [15:0] debug_crc_override_value
`endif
);

    assign fpga_rx_clk = espm_tx_clk;
    assign espm_rx_clk = fpga_tx_clk;
    assign espm_rx_dat = fpga_tx_dat;

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

    ESPMRX inbound (
        .clock      (espm_tx_clk),
        .rdat       (espm_tx_dat),
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

    /* verilator lint_off UNUSED */
    wire [1:0] tx_cfsm;
    wire       pkt_start;
    wire [9:0] tdata_sel;
    wire       load_tdata;
    /* verilator lint_on UNUSED */

    ESSJBridge bridge (
        .clock       (espm_tx_clk),
        .reset       (reset),
        .rx_data     (rx_data),
        .rx_load     (rx_load),
        .rx_index    (rx_index),
        .rx_crc_good (rx_crc_good),
        .rx_eof      (rx_eof),
        .rx_page     (rx_page),
        .rx_length   (rx_length),
        .adc_clk     (adc_clk),
        .adc_valid   (adc_valid),
        .adc_channel (adc_channel),
        .adc_value   (adc_value),
        .tdat        (fpga_rx_dat),
        .tx_cfsm     (tx_cfsm),
        .pkt_start   (pkt_start),
        .tdata_sel   (tdata_sel),
        .load_tdata  (load_tdata)
`ifdef VERILATOR
        , .debug_force_bad_crc        (debug_force_bad_crc)
        , .debug_crc_override_request(debug_crc_override_request)
        , .debug_crc_override_value  (debug_crc_override_value)
`endif
    );

endmodule

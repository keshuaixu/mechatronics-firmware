`timescale 1ns / 1ps

module tb_fpga_to_espm_through_essj;
    reg clk = 1'b0;
    /* verilator lint_off BLKSEQ */
    always #6 clk = ~clk;
    /* verilator lint_on BLKSEQ */

    reg reset = 1'b1;
    initial begin
        #30;
        reset = 1'b0;
    end

    reg [31:0] payload [0:63];
    integer i;
    initial begin
        for (i = 0; i < 64; i = i + 1) begin
            payload[i] = 32'h5000_0000 + (i * 3);
        end
    end

    wire [9:0] tsel;
    reg  [31:0] tdata_mux;
    always @(*) begin
        if (tsel < 64) begin
            tdata_mux = payload[tsel[5:0]];
        end else begin
            tdata_mux = 32'h0;
        end
    end

    wire serial_from_fpga;
    /* verilator lint_off UNUSED */
    wire [1:0] tx_cfsm_unused;
    wire       tx_pkt_start_unused;
    wire       tx_load_tdata_unused;
    wire       tx_frame_done_unused;
    /* verilator lint_on UNUSED */

    ESPMTX fpga_src (
        .clock              (clk),
        .tdata              (tdata_mux),
        .page               (16'h0F0F),
        .length             (10'd64),
        .crc_override_enable(1'b0),
        .crc_override_value (16'h0000),
        .hold_frame         (1'b0),
        .prime_quadlet      (32'd0),
        .prime_valid        (1'b0),
        .cfsm               (tx_cfsm_unused),
        .tdata_sel          (tsel),
        .pkt_start          (tx_pkt_start_unused),
        .load_tdata         (tx_load_tdata_unused),
        .tdat               (serial_from_fpga),
        .frame_done         (tx_frame_done_unused)
    );

    wire espm_rx_clk;
    wire espm_rx_dat;
    /* verilator lint_off UNUSED */
    wire fpga_rx_clk_unused;
    wire fpga_rx_dat_unused;
    wire debug_crc_override_request_unused;
    wire [15:0] debug_crc_override_value_unused;
    /* verilator lint_on UNUSED */

    ESSJ_top dut (
        .reset       (reset),
        .espm_tx_clk (clk),
        .espm_tx_dat (1'b0),
        .fpga_rx_clk (fpga_rx_clk_unused),
        .fpga_rx_dat (fpga_rx_dat_unused),
        .fpga_tx_clk (clk),
        .fpga_tx_dat (serial_from_fpga),
        .espm_rx_clk (espm_rx_clk),
        .espm_rx_dat (espm_rx_dat),
        .adc_clk     (1'b0),
        .adc_valid   (1'b0),
        .adc_channel (3'd0),
        .adc_value   (32'd0),
        .debug_force_bad_crc(1'b0),
        .debug_crc_override_request(debug_crc_override_request_unused),
        .debug_crc_override_value  (debug_crc_override_value_unused)
    );

    wire [31:0] rdata;
    wire        load_rdata;
    wire [9:0]  rsel;
    wire        crc_good;
    /* verilator lint_off UNUSED */
    wire [1:0]  rx_cfsm_unused;
    wire        rx_framed_unused;
    wire        rx_eof_unused;
    wire [15:0] rx_page_unused;
    wire [9:0]  rx_length_unused;
    /* verilator lint_on UNUSED */

    ESPMRX espm_sink (
        .clock     (espm_rx_clk),
        .rdat      (espm_rx_dat),
        .cfsm      (rx_cfsm_unused),
        .rdata     (rdata),
        .load_rdata(load_rdata),
        .rdata_sel (rsel),
        .framed    (rx_framed_unused),
        .crc_good  (crc_good),
        .eof       (rx_eof_unused),
        .page      (rx_page_unused),
        .length    (rx_length_unused)
    );

    reg [31:0] received [0:63];
    always @(posedge espm_rx_clk) begin
        if (load_rdata && rsel < 64) begin
            received[rsel[5:0]] <= rdata;
        end
    end

    initial begin
        wait(crc_good === 1'b1);
        #12;
        for (i = 0; i < 64; i = i + 1) begin
            if (received[i] !== payload[i]) begin
                $fatal(1, "Pass-through mismatch at %0d expected %h got %h", i, payload[i], received[i]);
            end
        end
        $display("ESSJ pass-through path preserved payload");
        $finish;
    end
endmodule

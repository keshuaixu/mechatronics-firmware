`timescale 1ns / 1ps

module tb_espm_to_fpga_through_essj;
    reg clk = 1'b0;
    /* verilator lint_off BLKSEQ */
    always #5 clk = ~clk;
    /* verilator lint_on BLKSEQ */

    reg reset = 1'b1;
    initial begin
        #40;
        reset = 1'b0;
    end

    reg [31:0] payload [0:63];
    reg [31:0] expected [0:63];
    integer i;
    initial begin
        for (i = 0; i < 64; i = i + 1) begin
            payload[i]  = 32'h3000_0000 + i;
            expected[i] = payload[i];
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

    wire serial_source;
    /* verilator lint_off UNUSED */
    wire [1:0] tx_cfsm_unused;
    wire       tx_pkt_start_unused;
    wire       tx_load_tdata_unused;
    /* verilator lint_on UNUSED */

    ESPMTX espm_src (
        .clock              (clk),
        .tdata              (tdata_mux),
        .page               (16'h55AA),
        .length             (10'd64),
        .crc_override_enable(1'b0),
        .crc_override_value (16'h0000),
        .hold_frame         (1'b0),
        .cfsm               (tx_cfsm_unused),
        .tdata_sel          (tsel),
        .pkt_start          (tx_pkt_start_unused),
        .load_tdata         (tx_load_tdata_unused),
        .tdat               (serial_source),
        .frame_done         ()
    );

    reg adc_clk = 1'b0;
    /* verilator lint_off BLKSEQ */
    always #7 adc_clk = ~adc_clk;
    /* verilator lint_on BLKSEQ */

    reg adc_valid = 1'b0;
    reg [2:0] adc_channel = 3'd0;
    reg [31:0] adc_value = 32'd0;

    reg debug_force_bad_crc = 1'b0;

    /* verilator lint_off UNUSED */
    wire fpga_rx_clk;
    /* verilator lint_on UNUSED */
    wire fpga_rx_dat;

    wire serial_to_fpga = fpga_rx_dat;
    wire debug_crc_override_request;
    wire [15:0] debug_crc_override_value;

    /* verilator lint_off UNUSED */
    wire espm_rx_clk_unused;
    wire espm_rx_dat_unused;
    /* verilator lint_on UNUSED */

    ESSJ_top dut (
        .reset       (reset),
        .espm_tx_clk (clk),
        .espm_tx_dat (serial_source),
        .fpga_rx_clk (fpga_rx_clk),
        .fpga_rx_dat (fpga_rx_dat),
        .fpga_tx_clk (clk),
        .fpga_tx_dat (1'b0),
        .espm_rx_clk (espm_rx_clk_unused),
        .espm_rx_dat (espm_rx_dat_unused),
        .adc_clk     (adc_clk),
        .adc_valid   (adc_valid),
        .adc_channel (adc_channel),
        .adc_value   (adc_value),
        .debug_force_bad_crc(debug_force_bad_crc),
        .debug_crc_override_request(debug_crc_override_request),
        .debug_crc_override_value  (debug_crc_override_value)
    );

    wire [31:0] rdata;
    wire        load_rdata;
    wire [9:0]  rsel;
    wire        crc_good;
    /* verilator lint_off UNUSED */
    wire        eof;
    wire [1:0]  rx_state;
    wire        rx_framed_unused;
    wire [15:0] rx_page_unused;
    wire [9:0]  rx_length_unused;
    /* verilator lint_on UNUSED */

    ESPMRX fpga_sink (
        .clock     (clk),
        .rdat      (serial_to_fpga),
        .cfsm      (rx_state),
        .rdata     (rdata),
        .load_rdata(load_rdata),
        .rdata_sel (rsel),
        .framed    (rx_framed_unused),
        .crc_good  (crc_good),
        .eof       (eof),
        .page      (rx_page_unused),
        .length    (rx_length_unused)
    );

    always @(posedge clk) begin
        if (eof && !crc_good) begin
            $display("Receiver reported CRC failure");
        end
    end

    reg [31:0] received [0:63];
    always @(posedge clk) begin
        if (load_rdata && rsel < 64) begin
            received[rsel[5:0]] <= rdata;
        end
    end

    integer frame_counter = 0;
    always @(posedge clk) begin
        if (crc_good) begin
            frame_counter <= frame_counter + 1;
        end
    end

    reg [31:0] adc_expected [0:7];
    initial begin
        for (i = 0; i < 8; i = i + 1) begin
            adc_expected[i] = 32'h4000_0000 + (i * 32'h10);
        end
    end

    initial begin
        @(negedge reset);
        #20;
        for (i = 0; i < 8; i = i + 1) begin
            @(posedge adc_clk);
            adc_channel = i[2:0];
            adc_value   = adc_expected[i];
            adc_valid   = 1'b1;
            @(posedge adc_clk);
            adc_valid   = 1'b0;
            @(posedge adc_clk);
        end
    end

    integer wait_cycles;

    initial begin
        wait(frame_counter == 2);
        #10;
        for (i = 0; i < 64; i = i + 1) begin
            if (i >= 56 && i < 64) begin
                expected[i] = adc_expected[i - 56];
            end
            if (received[i] !== expected[i]) begin
                $fatal(1, "Bridge mismatch at %0d expected %h got %h", i, expected[i], received[i]);
            end
        end
        $display("ESSJ bridge forwarded ADC data correctly");

        // Force a CRC override via the simulation-only debug input
        @(posedge clk);
        debug_force_bad_crc = 1'b1;
        wait_cycles = 0;
        while (!debug_crc_override_request && wait_cycles < 100000) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
        end
        debug_force_bad_crc = 1'b0;
        if (!debug_crc_override_request) begin
            $fatal(1, "Timed out waiting for CRC override request");
        end
        if (debug_crc_override_value !== 16'hDEAD) begin
            $fatal(1, "Expected CRC override 0xDEAD but saw %h", debug_crc_override_value);
        end
        $display("ESSJ bridge forced CRC override to 0xDEAD on bad input");
        $finish;
    end
endmodule

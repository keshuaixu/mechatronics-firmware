`timescale 1ns / 1ps

module tb_espm_to_fpga_direct;
    reg clk = 1'b0;
    /* verilator lint_off BLKSEQ */
    always #5 clk = ~clk;
    /* verilator lint_on BLKSEQ */

    reg [31:0] payload [0:63];
    integer i;
    initial begin
        for (i = 0; i < 64; i = i + 1) begin
            payload[i] = 32'h1000_0000 + i;
        end
    end

    wire [9:0] tsel;
    /* verilator lint_off UNUSED */
    wire       load_tdata;
    wire       pkt_start;
    /* verilator lint_on UNUSED */
    wire       serial_out;
    reg  [31:0] tdata_mux;

    always @(*) begin
        if (tsel < 64) begin
            tdata_mux = payload[tsel[5:0]];
        end else begin
            tdata_mux = 32'h0;
        end
    end

    /* verilator lint_off UNUSED */
    wire [1:0] tx_cfsm_unused;
    wire [1:0] rx_cfsm_unused;
    wire [15:0] rx_page_unused;
    wire [9:0]  rx_length_unused;
    /* verilator lint_on UNUSED */

    ESPMTX tx (
        .clock              (clk),
        .tdata              (tdata_mux),
        .page               (16'h0001),
        .length             (10'd64),
        .crc_override_enable(1'b0),
        .crc_override_value (16'h0000),
        .cfsm               (tx_cfsm_unused),
        .tdata_sel          (tsel),
        .pkt_start          (pkt_start),
        .load_tdata         (load_tdata),
        .tdat               (serial_out)
    );

    wire [31:0] rdata;
    wire        load_rdata;
    wire [9:0]  rsel;
    /* verilator lint_off UNUSED */
    wire        framed;
    wire        eof;
    /* verilator lint_on UNUSED */
    wire        crc_good;

    ESPMRX rx (
        .clock     (clk),
        .rdat      (serial_out),
        .cfsm      (rx_cfsm_unused),
        .rdata     (rdata),
        .load_rdata(load_rdata),
        .rdata_sel (rsel),
        .framed    (framed),
        .crc_good  (crc_good),
        .eof       (eof),
        .page      (rx_page_unused),
        .length    (rx_length_unused)
    );

    reg [31:0] received [0:63];
    always @(posedge clk) begin
        if (load_rdata && rsel < 64) begin
            received[rsel[5:0]] <= rdata;
        end
    end

    initial begin
        wait(crc_good === 1'b1);
        #10;
        for (i = 0; i < 64; i = i + 1) begin
            if (received[i] !== payload[i]) begin
                $fatal(1, "Mismatch at %0d expected %h got %h", i, payload[i], received[i]);
            end
        end
        $display("tb_espm_to_fpga_direct PASS");
        $finish;
    end
endmodule

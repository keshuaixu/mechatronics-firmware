// --------------------------------------------------------------------------
// ESPM-FPGA1394
// --------------------------------------------------------------------------
assign tclk_dvrk = clk80; // internal 80MHz clock
wire [2:0] flash_cfsm;
reg [31:0] flash_rdata_latched;

reg [31:0] timestamp;
reg [31:0] debug_counter;
always @(posedge sysclk) begin
  timestamp <= timestamp + 'b1;
end
reg dvrk_preload_valid = 'b0;

always @(*) begin
  case (tdata_sel_dvrk)
    `ADDR_SWITCH: tdata_dvrk = reg_switch;
    `ADDR_ESII:   tdata_dvrk = esii_status;
    `ADDR_INST_MODEL: tdata_dvrk = inst_id[31:0];
    `ADDR_INST_ID:    tdata_dvrk = inst_id[63:32];
    `ADDR_TIMESTAMP: tdata_dvrk = timestamp;
    `ADDR_FLASH_RDATA: tdata_dvrk = flash_rdata_latched;
    `ADDR_VERSION: tdata_dvrk = `ESPM_FIRMWARE_VERSION;
    `ADDR_ESPMCOMM_CRCGOOD: tdata_dvrk = crc_good_count_dvrk;
    `ADDR_ESPMCOMM_CRCERR: tdata_dvrk = crc_err_count_dvrk;
    `ADDR_PRELOAD: tdata_dvrk = {31'b0, dvrk_preload_valid};
    default: tdata_dvrk = (tdata_sel_dvrk[5:3]==`OFF_POT_DATA) ? reg_pot : reg_enc;
  endcase
end

ESPMTX tx(
  .clock(tclk_dvrk), // internal 80MHz clock
  .tdata(tdata_dvrk), // data to send
  .page(16'b0),
  .length(10'd64),
  .crc_override_enable(1'b0),
  .crc_override_value(16'h0000),
  .hold_frame(1'b0),
  .tdat(tdat_dvrk),
  .tdata_sel(tdata_sel_dvrk),
  .frame_done()
);
    
// --------------------------------------------------------------------------
// FPGA1394-ESPM
// --------------------------------------------------------------------------
assign no_comm = 'b0;
wire [31:0] rdata_espm;
wire load_rdata_espm;
wire  [9:0] rdata_sel_espm;
wire framed_espm;
wire crc_good_espm;
wire eof_espm;

ESPMRX espm_rx(
    // Input
    .clock(rclk_dvrk), // from off-board clock line @ 100 MHz
    .rdat(rdat_dvrk), // from off-board data line
    // Output
    .rdata(rdata_espm),
    .load_rdata(load_rdata_espm),
    .rdata_sel(rdata_sel_espm),
    .framed(framed_espm),
    .crc_good(crc_good_espm),
    .eof(eof_espm)
);

reg [5:0] espm_bram_raddr;
reg [31:0] espm_bram_rdata;

localparam ESPM_BRAM_SIZE = 'd64;
reg [31:0] espm_bram_pre_crc [0:ESPM_BRAM_SIZE - 1];
reg [31:0] espm_bram_pre_crc_wdata;
reg [5:0] espm_bram_pre_crc_waddr;
reg espm_bram_pre_crc_we;

always @(posedge rclk_dvrk) begin
    if (espm_bram_pre_crc_we) espm_bram_pre_crc[espm_bram_pre_crc_waddr] <= espm_bram_pre_crc_wdata;
    if (load_rdata_espm) begin
        espm_bram_pre_crc_wdata <= rdata_espm;
        espm_bram_pre_crc_waddr <= rdata_sel_espm;
        espm_bram_pre_crc_we <= 'b1;
    end else begin
        espm_bram_pre_crc_we <= 'b0;
    end
end

reg [31:0] espm_bram [0:ESPM_BRAM_SIZE - 1];
reg [5:0] espm_bram_waddr;
reg [31:0] espm_bram_wdata;
reg [5:0] espm_bram_pre_crc_raddr;
reg espm_bram_we;
wire crc_good_espm_sysclk;
cdc_pulse crc_good_espm_cdc (rclk_dvrk, crc_good_espm, sysclk, crc_good_espm_sysclk);
reg copy_state;
reg [31:0] last_flash_command;

always @(posedge sysclk) begin
    if (espm_bram_we) espm_bram[espm_bram_waddr] <= espm_bram_wdata;
    espm_bram_wdata <= espm_bram_pre_crc[espm_bram_pre_crc_raddr];
    espm_bram_rdata <= espm_bram[espm_bram_raddr];
    espm_bram_waddr <= espm_bram_pre_crc_raddr;
    case (copy_state)
        0: begin
            if (crc_good_espm_sysclk) begin
                copy_state <= 'b1;
                espm_bram_we <= 'b1;
            end
        end
        1: begin
            espm_bram_pre_crc_raddr <= espm_bram_pre_crc_raddr + 'b1;
            if (espm_bram_waddr == ESPM_BRAM_SIZE - 'b1) begin
                espm_bram_we <= 'b0;
                copy_state <= 'b0;
                espm_bram_pre_crc_raddr <= 'b0;
            end
        end
    endcase
end



reg  [9:0] crc_good_count_dvrk_prev = 'b1;


reg espm_comm_wdt_fault;
reg [18:0] espm_comm_wdt_clkdiv;
always @(posedge sysclk) begin
    espm_comm_wdt_clkdiv = espm_comm_wdt_clkdiv + 'd1;
    if (espm_comm_wdt_clkdiv == 'd0) begin
        crc_good_count_dvrk_prev <= crc_good_count_dvrk[9:0];
        espm_comm_wdt_fault <= crc_good_count_dvrk[9:0] == crc_good_count_dvrk_prev;
    end
end

always @(posedge rclk_dvrk) begin
    if (crc_good_espm) begin
        crc_good_count_dvrk <= crc_good_count_dvrk + 'd1;
    end
    if (eof_espm && !crc_good_espm) begin
        crc_err_count_dvrk <= crc_err_count_dvrk + 'd1;
    end
end


/* -*- Mode: Verilog; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*-   */
/* ex: set filetype=v softtabstop=4 shiftwidth=4 tabstop=4 cindent expandtab:      */

/*******************************************************************************    
 *
 * Copyright(C) 2011-2022 ERC CISST, Johns Hopkins University.
 *
 * This is the top level module for the FPGA1394-QLA motor controller interface.
 *
 * Revision history
 *     07/15/10                        Initial revision - MfgTest
 *     10/27/11    Paul Thienphrapa    Initial revision (pault at cs.jhu.edu)
 *     02/29/12    Zihan Chen
 *     08/29/18    Peter Kazanzides    Added DS2505 module
 *     01/22/20    Peter Kazanzides    Removed global reset
 *     04/28/22    Peter Kazanzides    Adapted for FPGA V3
 */

`timescale 1ns / 1ps

// Define DIAGNOSTIC for diagnostic build, where DAC output is determined by
// rotary switch setting (0-15).
// `define DIAGNOSTIC

// clock information
// clk1394: 49.152 MHz 
// sysclk: same as clk1394 49.152 MHz

`include "Constants.v"

module FPGA1394V3QLA
(
    // ieee 1394 phy-link interface
    input            clk1394,   // 49.152 MHz
    inout [7:0]      data,
    inout [1:0]      ctl,
    output wire      lreq,
    output wire      reset_phy,

    // misc board I/Os
    input [3:0]      wenid,     // rotary switch
    inout [1:32]     IO1,
    inout [1:38]     IO2,
    output wire      LED,

    // Ethernet PHYs (RTL8211F)
    output wire      E1_MDIO_C,   // eth1 MDIO clock
    output wire      E2_MDIO_C,   // eth2 MDIO clock
    //Following is directly connected via constraint file
    //inout wire     E1_MDIO_D,   // eth1 MDIO data
    inout wire       E2_MDIO_D,   // eth2 MDIO data
    output wire      E1_RSTn,     // eth1 PHY reset
    output wire      E2_RSTn,     // eth2 PHY reset

    input wire       E1_RxCLK,    // eth1 receive clock (from PHY)
    input wire       E1_RxVAL,    // eth1 receive valid
    input wire[3:0]  E1_RxD,      // eth1 data bits
    output wire      E1_TxCLK,    // eth1 transmit clock
    output wire      E1_TxEN,     // eth1 transmit enable
    output wire[3:0] E1_TxD,      // eth1 transmit data

`ifdef ETHERNET_DUAL
    input wire       E2_RxCLK,    // eth2 receive clock (from PHY)
    input wire       E2_RxVAL,    // eth2 receive valid
    input wire[3:0]  E2_RxD,      // eth2 data bits
    output wire      E2_TxCLK,    // eth2 transmit clock
    output wire      E2_TxEN,     // eth2 transmit enable
    output wire[3:0] E2_TxD,      // eth2 transmit data
`endif

    // PS7 interface
    inout[53:0]      MIO,
    input            PS_SRSTB,
    input            PS_CLK,
    input            PS_PORB
);

    // -------------------------------------------------------------------------
    // local wires to tie the instantiated modules and I/Os
    //

    wire lreq_trig;             // phy request trigger
    wire[2:0] lreq_type;        // phy request type
    reg reg_wen;                // register write signal
    wire fw_reg_wen;            // register write signal from FireWire
    wire bw_reg_wen;            // register write signal from WriteRtData
    reg blk_wen;                // block write enable
    wire fw_blk_wen;            // block write enable from FireWire
    wire bw_blk_wen;            // block write enable from WriteRtData
    reg blk_wstart;             // block write start
    wire fw_blk_wstart;         // block write start from FireWire
    wire bw_blk_wstart;         // block write start from WriteRtData
    wire[15:0] reg_raddr;       // 16-bit reg read address
    wire[15:0] fw_reg_raddr;    // 16-bit reg read address from FireWire
    reg[15:0] reg_waddr;        // 16-bit reg write address
    wire[15:0] fw_reg_waddr;    // 16-bit reg write address from FireWire
    wire[7:0] bw_reg_waddr;     // 16-bit reg write address from WriteRtData
    wire[31:0] reg_rdata;       // reg read data
    reg[31:0] reg_wdata;        // reg write data
    wire[31:0] fw_reg_wdata;    // reg write data from FireWire
    wire[31:0] bw_reg_wdata;    // reg write data from WriteRtData
    wire[31:0] reg_rd[0:15];
    // Following wire indicates which module is driving the write bus
    // (reg_waddr, reg_wdata, reg_wen, blk_wen, blk_wstart).
    // If bw_write_en is 0, then Firewire is driving the write bus.
    wire bw_write_en;           // 1 -> WriteRtData (real-time block write) is driving write bus
    wire[3:0] board_id;         // 4-bit board id
    assign board_id = ~wenid;

    // SPI interface to QLA PROM and I/O Expander
    // IO1[1] is MISO (input to FPGA), so can be shared between QLA PROM and I/O Expander
    wire qla_prom_mosi;
    wire io_exp_mosi;
    wire qla_prom_sclk;
    wire io_exp_sclk;
    wire qla_prom_busy;         // 1 -> QLA PROM using SPI
    wire io_exp_busy;           // 1 -> I/O Expander using SPI

    // Multiplex MOSI (output from FPGA) and SCLK (SPI clock)
    assign IO1[2] = qla_prom_busy ? qla_prom_mosi :
                    io_exp_busy   ? io_exp_mosi : 1'bz;
    assign IO1[3] = qla_prom_busy ? qla_prom_sclk :
                    io_exp_busy   ? io_exp_sclk : 1'bz;

//------------------------------------------------------------------------------
// hardware description
//

BUFG clksysclk(.I(clk1394), .O(sysclk));

// Wires for sampling block read data
wire sample_start;        // Start sampling read data
wire sample_busy;         // 1 -> data sampler has control of bus
wire[3:0] sample_chan;    // Channel for sampling
wire[5:0] sample_raddr;   // Address in sample_data buffer
wire[31:0] sample_rdata;  // Output from sample_data buffer
wire[31:0] timestamp;     // Timestamp used when sampling

// For real-time write
wire       rt_wen;
wire[3:0]  rt_waddr;
wire[31:0] rt_wdata;

// For data sampling
wire fw_sample_start;
assign sample_start = fw_sample_start & ~sample_busy;

assign reg_raddr = sample_busy ? {`ADDR_MAIN, 4'd0, sample_chan, 4'd0} : fw_reg_raddr;

// Multiplexing of write bus between WriteRtData (bw = real-time block write module)
// and Firewire.
always @(*)
begin
   if (bw_write_en) begin
      reg_wen = bw_reg_wen;
      blk_wen = bw_blk_wen;
      blk_wstart = bw_blk_wstart;
      reg_waddr = {8'd0, bw_reg_waddr};
      reg_wdata = bw_reg_wdata;
   end
   else begin
      reg_wen = fw_reg_wen;
      blk_wen = fw_blk_wen;
      blk_wstart = fw_blk_wstart;
      reg_waddr = fw_reg_waddr;
      reg_wdata = fw_reg_wdata;
   end
end

wire[31:0] reg_rdata_hub;      // reg_rdata_hub is for hub memory
wire[31:0] reg_rdata_prom;     // reg_rdata_prom is for block reads from PROM
wire[31:0] reg_rdata_prom_qla; // reads from QLA prom
wire[31:0] reg_rdata_eth;      // for eth memory access
wire[31:0] reg_rdata_ds;       // for DS2505 memory access
wire[31:0] reg_rdata_chan0;    // 'channel 0' is a special axis that contains various board I/Os
wire[31:0] reg_rdata_ioexp;    // reads from MAX7317 I/O expander (QLA 1.5+)

// Mux routing read data based on read address
//   See Constants.v for details
//     addr[15:12]  main | hub | prom | prom_qla | eth | firewire | dallas | databuf | waveform
assign reg_rdata = (reg_raddr[15:12]==`ADDR_HUB) ? (reg_rdata_hub) :
                   (reg_raddr[15:12]==`ADDR_PROM) ? (reg_rdata_prom) :
                   (reg_raddr[15:12]==`ADDR_PROM_QLA) ? (reg_rdata_prom_qla) :
                   (reg_raddr[15:12]==`ADDR_ETH) ? (reg_rdata_eth) :
                   (reg_raddr[15:12]==`ADDR_DS) ? (reg_rdata_ds) :
                   (reg_raddr[15:12]==`ADDR_DATA_BUF) ? (reg_rdata_databuf) :
                   (reg_raddr[15:12]==`ADDR_WAVEFORM) ? (reg_rtable) :
                   (reg_raddr[7:4]!=4'd0) ? (reg_rd[reg_raddr[3:0]]) :
                   (reg_raddr[3:0]==`REG_IO_EXP) ? (reg_rdata_ioexp) : (reg_rdata_chan0);

// Unused channel offsets
assign reg_rd[`OFF_UNUSED_02] = 32'd0;
assign reg_rd[`OFF_UNUSED_03] = 32'd0;
assign reg_rd[`OFF_UNUSED_11] = 32'd0;
assign reg_rd[`OFF_UNUSED_13] = 32'd0;
assign reg_rd[`OFF_UNUSED_14] = 32'd0;
assign reg_rd[`OFF_UNUSED_15] = 32'd0;

// 1394 phy low reset, never reset
assign reset_phy = 1'b1; 

// --------------------------------------------------------------------------
// hub register module
// --------------------------------------------------------------------------

wire[15:0] bc_sequence;
wire       hub_write_trig;
wire       hub_write_trig_reset;
wire       fw_idle;

HubReg hub(
    .sysclk(sysclk),
    .reg_wen(reg_wen),
    .reg_raddr(reg_raddr),
    .reg_waddr(reg_waddr),
    .reg_rdata(reg_rdata_hub),
    .reg_wdata(reg_wdata),
    .sequence(bc_sequence),
    .board_id(board_id),
    .write_trig(hub_write_trig),
    .write_trig_reset(hub_write_trig_reset),
    .fw_idle(fw_idle)
);


// --------------------------------------------------------------------------
// firewire modules
// --------------------------------------------------------------------------

// phy-link interface
PhyLinkInterface phy(
    .sysclk(sysclk),         // in: global clk  
    .board_id(board_id),     // in: board id (rotary switch)

    .ctl_ext(ctl),           // bi: phy ctl lines
    .data_ext(data),         // bi: phy data lines
    
    .reg_wen(fw_reg_wen),       // out: reg write signal
    .blk_wen(fw_blk_wen),       // out: block write signal
    .blk_wstart(fw_blk_wstart), // out: block write is starting

    .reg_raddr(fw_reg_raddr),  // out: register address
    .reg_waddr(fw_reg_waddr),  // out: register address
    .reg_rdata(reg_rdata),     // in:  read data to external register
    .reg_wdata(fw_reg_wdata),  // out: write data to external register

    .lreq_trig(lreq_trig),   // out: phy request trigger
    .lreq_type(lreq_type),   // out: phy request type

    .rx_bc_sequence(bc_sequence),  // in: broadcast sequence num
    .write_trig(hub_write_trig),   // in: 1 -> broadcast write this board's hub data
    .write_trig_reset(hub_write_trig_reset),
    .fw_idle(fw_idle),

    // Interface for real-time block write
    .fw_rt_wen(rt_wen),
    .fw_rt_waddr(rt_waddr),
    .fw_rt_wdata(rt_wdata),

    // Interface for sampling data (for block read)
    .sample_start(fw_sample_start),   // 1 -> start sampling for block read
    .sample_busy(sample_busy),        // Sampling in process
    .sample_raddr(sample_raddr),      // Read address for sampled data
    .sample_rdata(sample_rdata)       // Sampled data (for block read)
);


// phy request module
PhyRequest phyreq(
    .sysclk(sysclk),          // in: global clock
    .lreq(lreq),              // out: phy request line
    .trigger(lreq_trig),      // in: phy request trigger
    .rtype(lreq_type),        // in: phy request type
    .data(fw_reg_wdata[11:0]) // in: phy request data
);

// --------------------------------------------------------------------------
// Ethernet module
// --------------------------------------------------------------------------
//
// When using the GMII to RGMII core, MDIO signals from the RTL8211F module
// are connected to the GMII to RGMII core, and then the MDIO and MDC signals
// from the core are connected to the RTL8211F PHY. If the GMII to RGMII core
// is not used, the MDIO signals from the RTL8211F module are connected directly
// to the RTL8211F PHY.
//
// Currently, E1 uses the GMII to RGMII core, whereas E2 does not. This is because
// it is not yet possible to instantiate a second GMII to RGMII core due to the
// duplicate IDELAYCTRL.

// GMII signals (generated by gmii_to_rgmii cores)
wire[7:0]  E1_gmii_txd;
wire       E1_gmii_tx_en;
wire       E1_gmii_tx_clk;
wire[7:0]  E1_gmii_rxd;
wire       E1_gmii_rx_dv;
wire       E1_gmii_rx_er;
wire       E1_gmii_rx_clk;
wire       E1_mdio_o;         // OUT from RTL8211F module, IN to GMII core (or PHY)
wire       E1_mdio_i;         // IN to RTL8211F module, OUT from GMII core (or PHY)
wire       E1_mdio_t;         // OUT from RTL8211F module (tristate control)
wire       E1_mdio_clk;       // OUT from RTL8211F module, IN to GMII core (or PHY)

`ifdef ETHERNET_DUAL
wire[7:0]  E2_gmii_txd;
wire       E2_gmii_tx_en;
wire       E2_gmii_tx_clk;
wire[7:0]  E2_gmii_rxd;
wire       E2_gmii_rx_dv;
wire       E2_gmii_rx_er;
wire       E2_gmii_rx_clk;
`endif
wire       E2_mdio_o;         // OUT from RTL8211F module, IN to GMII core (or PHY)
wire       E2_mdio_i;         // IN to RTL8211F module, OUT from GMII core (or PHY)
wire       E2_mdio_t;         // OUT from RTL8211F module (tristate control)
wire       E2_mdio_clk;       // OUT from RTL8211F module, IN to GMII core (or PHY)

wire[31:0] reg_rdata_e1;
wire[31:0] reg_rdata_e2;

assign reg_rdata_eth = (reg_raddr[11:8] == 4'd1) ? reg_rdata_e1 :
                       (reg_raddr[11:8] == 4'd2) ? reg_rdata_e2 :
                       32'd0;

wire reg_wen_e1;
assign reg_wen_e1 = (reg_waddr[15:7] == {`ADDR_ETH, 4'd1, 1'd1}) ? reg_wen : 1'b0;
wire reg_wen_e2;
assign reg_wen_e2 = (reg_waddr[15:7] == {`ADDR_ETH, 4'd2, 1'd1}) ? reg_wen : 1'b0;

RTL8211F #(.CHANNEL(4'd1)) EthPhy1(
    .clk(sysclk),             // in:  global clock

    .reg_raddr(reg_raddr),    // in:  read address
    .reg_waddr(reg_waddr),    // in:  write address
    .reg_rdata(reg_rdata_e1), // out: read data
    .reg_wdata(reg_wdata),    // in:  write data
    .reg_wen(reg_wen_e1),     // in:  write enable

    .RSTn(E1_RSTn),           // Reset to RTL8211F

    .MDC(E1_mdio_clk),        // Clock to GMII core (and RTL8211F PHY)
    .MDIO_I(E1_mdio_i),       // IN to RTL8211F module, OUT from GMII core
    .MDIO_O(E1_mdio_o),       // OUT from RTL8211F module, IN to GMII core
    .MDIO_T(E1_mdio_t),       // Tristate signal from RTL8211F module

    .RxClk(E1_gmii_rx_clk),   // Rx Clk
    .RxValid(E1_gmii_rx_dv),  // Rx Valid
    .RxD(E1_gmii_rxd),        // Rx Data
    .RxErr(E1_gmii_rx_er)     // Rx Error
);

RTL8211F #(.CHANNEL(4'd2)) EthPhy2(
    .clk(sysclk),             // in:  global clock

    .reg_raddr(reg_raddr),    // in:  read address
    .reg_waddr(reg_waddr),    // in:  write address
    .reg_rdata(reg_rdata_e2), // out: read data
    .reg_wdata(reg_wdata),    // in:  write data
    .reg_wen(reg_wen_e2),     // in:  write enable

    .RSTn(E2_RSTn),           // Reset to RTL8211F

    .MDC(E2_mdio_clk),        // Clock to GMII core (if present) and RTL8211F PHY
    .MDIO_I(E2_mdio_i),       // IN to RTL8211F module, OUT from GMII core or RTL8211F PHY
    .MDIO_O(E2_mdio_o),       // OUT from RTL8211F module, IN to GMII core or RTL8211F PHY
    .MDIO_T(E2_mdio_t),       // Tristate signal from RTL8211F module

`ifdef ETHERNET_DUAL
    .RxClk(E2_gmii_rx_clk),   // Rx Clk
    .RxValid(E2_gmii_rx_dv),  // Rx Valid
    .RxD(E2_gmii_rxd),        // Rx Data
    .RxErr(E2_gmii_rx_er)     // Rx Error
`else
    .RxClk(1'b0),
    .RxValid(1'b0),
    .RxD(4'd0),
    .RxErr(1'b0)
`endif
);

`ifndef ETHERNET_DUAL
assign E2_MDIO_C = E2_mdio_clk;
assign E2_MDIO_D = E2_mdio_t ? 1'bz : E2_mdio_o;
assign E2_mdio_i = E2_MDIO_D;
`endif

// --------------------------------------------------------------------------
// adcs: pot + current 
// --------------------------------------------------------------------------

// ~12 MHz clock for spi communication with the adcs
wire clkdiv2, clkadc;
ClkDiv div2clk(sysclk, clkdiv2);
defparam div2clk.width = 2;
BUFG adcclk(.I(clkdiv2), .O(clkadc));


// local wire for cur_fb(1-4) 
wire[15:0] cur_fb[1:4];
wire       cur_fb_wen;

// local wire for pot_fb(1-4)
wire[15:0] pot_fb[1:4];
wire       pot_fb_wen;

// adc controller routes conversion results according to address
CtrlAdc adc(
    .clkadc(clkadc),
    .sclk({IO1[10],IO1[28]}),
    .conv({IO1[11],IO1[27]}),
    .miso({IO1[12:15],IO1[26],IO1[25],IO1[24],IO1[23]}),
    .cur1(cur_fb[1]),
    .cur2(cur_fb[2]),
    .cur3(cur_fb[3]),
    .cur4(cur_fb[4]),
    .cur_ready(cur_fb_wen),
    .pot1(pot_fb[1]),
    .pot2(pot_fb[2]),
    .pot3(pot_fb[3]),
    .pot4(pot_fb[4]),
    .pot_ready(pot_fb_wen)
);

wire[31:0] reg_adc_data;
assign reg_adc_data = {pot_fb[reg_raddr[7:4]], cur_fb[reg_raddr[7:4]]};

assign reg_rd[`OFF_ADC_DATA] = reg_adc_data;

// ----------------------------------------------------------------------------
// Read/Write of commanded current (cur_cmd)
// This is now done outside CtrlDac to support digital control implementations.
// ----------------------------------------------------------------------------

reg[15:0] cur_cmd[1:`NUM_CHANNELS];

// Check for non-zero channel number (reg_waddr[7:4]) to ignore write to global register.
// It would be even better to check that channel number is 1-(`NUM_CHANNELS-1).
wire reg_waddr_dac;
assign reg_waddr_dac = ((reg_waddr[15:12]==`ADDR_MAIN) && (reg_waddr[7:4] != 4'd0) &&
                        (reg_waddr[3:0]==`OFF_DAC_CTRL)) ? 1'd1 : 1'd0;

wire dac_busy;
reg cur_cmd_updated;

`ifdef DIAGNOSTIC

always @(posedge(sysclk))
begin
    cur_cmd[1] <= { board_id, 12'h000 };
    cur_cmd[2] <= { board_id, 12'h000 };
    cur_cmd[3] <= { board_id, 12'h000 };
    cur_cmd[4] <= { board_id, 12'h000 };
    cur_cmd_updated <= ~dac_busy;
end

`else

reg cur_cmd_req;

always @(posedge(sysclk))
begin
    if (reg_waddr_dac) begin
        if (reg_wen) begin
            cur_cmd[reg_waddr[7:4]] <= reg_wdata[15:0];
        end
        cur_cmd_req <= blk_wen;
    end
    else if (cur_cmd_req&(~dac_busy)) begin
        cur_cmd_req <= 0;
    end
    cur_cmd_updated <= cur_cmd_req&(~dac_busy);
end

`endif

assign reg_rd[`OFF_DAC_CTRL] = cur_cmd[reg_raddr[7:4]];

// --------------------------------------------------------------------------
// dacs
// --------------------------------------------------------------------------

wire[31:0] reg_motor_status;

wire is_quad_dac;         // type of DAC: 0 = 4xLTC2601, 1 = 1xLTC2604
wire dac_test_reset;      // reset (repeat) detection of DAC type

wire amp_disable_vec[1:4];
assign amp_disable_vec[1] = IO2[32];
assign amp_disable_vec[2] = IO2[34];
assign amp_disable_vec[3] = IO2[36];
assign amp_disable_vec[4] = IO2[38];

assign reg_motor_status = { 3'b000, ~amp_disable_vec[reg_raddr[7:4]], 12'd0, cur_cmd[reg_raddr[7:4]] };
assign reg_rd[`OFF_MOTOR_STATUS] = reg_motor_status;

// the dac controller manages access to the dacs
CtrlDac dac(
    .sysclk(sysclk),
    .sclk(IO1[21]),
    .mosi(IO1[20]),
    .csel(IO1[22]),
    .dac1(cur_cmd[1]),
    .dac2(cur_cmd[2]),
    .dac3(cur_cmd[3]),
    .dac4(cur_cmd[4]),
    .busy(dac_busy),
    .data_ready(cur_cmd_updated),
    .mosi_read(IO1[20]),
    .isQuadDac(is_quad_dac),
    .dac_test_reset(dac_test_reset)
);


// --------------------------------------------------------------------------
// encoders
// --------------------------------------------------------------------------

wire[31:0] reg_preload;
wire[31:0] reg_quad_data;
wire[31:0] reg_perd_data;
wire[31:0] reg_qtr1_data;
wire[31:0] reg_qtr5_data;
wire[31:0] reg_run_data;

// encoder controller: the thing that manages encoder reads and preloads
CtrlEnc enc(
    .sysclk(sysclk),
    .enc_a({IO2[23],IO2[21],IO2[19],IO2[17]}),
    .enc_b({IO2[15],IO2[13],IO2[12],IO2[10]}),
    .reg_raddr_chan(reg_raddr[7:4]),
    .reg_waddr(reg_waddr),
    .reg_wdata(reg_wdata),
    .reg_wen(reg_wen),
    .reg_preload(reg_preload),
    .reg_quad_data(reg_quad_data),
    .reg_perd_data(reg_perd_data),
    .reg_qtr1_data(reg_qtr1_data),
    .reg_qtr5_data(reg_qtr5_data),
    .reg_run_data(reg_run_data)
);

assign reg_rd[`OFF_ENC_LOAD] = reg_preload;      // preload
assign reg_rd[`OFF_ENC_DATA] = reg_quad_data;    // quadrature
assign reg_rd[`OFF_PER_DATA] = reg_perd_data;    // period
assign reg_rd[`OFF_QTR1_DATA] = reg_qtr1_data;   // last quarter cycle 
assign reg_rd[`OFF_QTR5_DATA] = reg_qtr5_data;   // quarter cycle 5 edges ago
assign reg_rd[`OFF_RUN_DATA] = reg_run_data;     // running counter

// --------------------------------------------------------------------------
// digital output (DOUT) control
// --------------------------------------------------------------------------

wire[31:0] reg_rdout;
assign reg_rd[`OFF_DOUT_CTRL] = reg_rdout;
wire[31:0] reg_rtable;

// DOUT hardware configuration
wire dout_config_valid;
wire dout_config_bidir;
wire dout_config_reset;
wire[31:0] dout;
wire dir12_cd;
wire dir34_cd;

// Overrides from DS2505 module. When interfacing to the Dallas DS2505
// via 1-wire interface, the DS2505 module sets ds_enable and takes over
// control of DOUT3 and DIR34.
wire ds_enable;
wire dout3_ds;
wire dir34_ds;

// IO1[16]: DOUT 4
// IO1[17]: DOUT 3
// IO1[18]: DOUT 2
// IO1[19]: DOUT 1
// If dout_config_dir==1, then invert logic; note that this is accomplished using the XOR operator.
// Note that old version QLA IOs are not bi-directional, thus dout_config_bidir==0. In that case, dout3_ds logic needs to be inverted via XNOR.
// Meanwhile, new version QLA does have bi-dir driver for IOs, therefore dou3_ds doesn't need to be inverted, which is still achieved by XNOR.
assign IO1[16] = dout_config_bidir ^ dout[3];
assign IO1[17] = ds_enable ? (dir34_ds ?  (dout3_ds ^~ dout_config_bidir) : 1'bz) : (dout_config_bidir ^ dout[2]);
assign IO1[18] = dout_config_bidir ^ dout[1];
assign IO1[19] = dout_config_bidir ^ dout[0];

// IO1[6]: DIR 1+2
// IO1[5]: DIR 3+4
assign IO1[6] = (dout_config_valid && dout_config_bidir) ? dir12_cd : 1'bz;
assign IO1[5] = (dout_config_valid && dout_config_bidir) ? (ds_enable ? dir34_ds : dir34_cd) : 1'bz;

CtrlDout cdout(
    .sysclk(sysclk),
    .reg_raddr(reg_raddr),
    .reg_waddr(reg_waddr),
    .reg_rdata(reg_rdout),
    .table_rdata(reg_rtable),
    .reg_wdata(reg_wdata),
    .reg_wen(reg_wen),
    .dout(dout),
    .dir12_read(IO1[6]),
    .dir34_read(IO1[5]),
    .dir12_reg(dir12_cd),
    .dir34_reg(dir34_cd),
    .dout_cfg_valid(dout_config_valid),
    .dout_cfg_bidir(dout_config_bidir),
    .dout_cfg_reset(dout_config_reset)
);

// --------------------------------------------------------------------------
// temperature sensors 
// --------------------------------------------------------------------------

// divide 49.152 MHz clock down to 400 kHz for temperature sensor readings
ClkDivI divtemp(sysclk, clk400k_raw);
defparam divtemp.div = 122;

BUFG clktemp(.I(clk400k_raw), .O(clk400k));

// tempsense module instantiations
Max6576 T1(
    .clk400k(clk400k), 
    .In(IO1[29]), 
    .Out(tempsense[15:8])
);

Max6576 T2(
    .clk400k(clk400k), 
    .In(IO1[30]), 
    .Out(tempsense[7:0])
);


// --------------------------------------------------------------------------
// QLA prom 25AA128
//    - SPI pin connection see QLA schematics
//    - TEMP version, interface subject to future change
// --------------------------------------------------------------------------

QLA25AA128 prom_qla(
    .clk(sysclk),
    
    // address & wen
    .reg_raddr(reg_raddr),
    .reg_waddr(reg_waddr),
    .reg_rdata(reg_rdata_prom_qla),
    .reg_wdata(reg_wdata),
        
    .reg_wen(reg_wen),
    .blk_wen(blk_wen),
    .blk_wstart(blk_wstart),

    // spi interface
    .prom_mosi(qla_prom_mosi),
    .prom_miso(IO1[1]),
    .prom_sclk(qla_prom_sclk),
    .prom_cs(IO1[4]),
    .other_busy(io_exp_busy),
    .this_busy(qla_prom_busy)
);

// --------------------------------------------------------------------------
// MAX7317: I/O Expander
// --------------------------------------------------------------------------

wire ioexp_cfg_reset;       // 1 -> Check if I/O expander (MAX7317) present
wire ioexp_cfg_present;     // 1 -> I/O expander (MAX7317) detected

wire safety_fb_n;           // 0 -> voltage present on safety line
wire mv_fb;                 // Feedback from comparator between DAC4 and motor supply

wire cur_ctrl[1:4];
// PK TEMP
assign cur_ctrl[1] = 1;
assign cur_ctrl[2] = 1;
assign cur_ctrl[3] = 1;
assign cur_ctrl[4] = 1;

wire disable_f[1:4];
// PK TEMP
assign disable_f[1] = amp_disable_vec[1];
assign disable_f[2] = amp_disable_vec[2];
assign disable_f[3] = amp_disable_vec[3];
assign disable_f[4] = amp_disable_vec[4];

Max7317 IO_Exp(
    .clk(sysclk),

    // address & wen
    //.reg_raddr(reg_raddr),
    .reg_waddr(reg_waddr),
    .reg_rdata(reg_rdata_ioexp),
    .reg_wdata(reg_wdata),
    .reg_wen(reg_wen),

    // Configuration
    .ioexp_cfg_reset(ioexp_cfg_reset),
    .ioexp_cfg_present(ioexp_cfg_present),

    // spi interface
    .mosi(io_exp_mosi),
    .miso(IO1[1]),
    .sclk(io_exp_sclk),
    .CSn(IO1[8]),
    .other_busy(qla_prom_busy),
    .this_busy(io_exp_busy),

    // Signals
    .P30({cur_ctrl[1], cur_ctrl[2], cur_ctrl[3], cur_ctrl[4]}),
    .P74({disable_f[1], disable_f[2], disable_f[3], disable_f[4]}),
    .P98({mv_fb, safety_fb_n})
);

// --------------------------------------------------------------------------
// DS2505: Dallas 1-wire interface
// --------------------------------------------------------------------------
wire[31:0] ds_status;

DS2505 ds_instrument(
    .clk(sysclk),

    // address & wen
    .reg_raddr(reg_raddr),
    .reg_waddr(reg_waddr),
    .reg_wdata(reg_wdata),
    .reg_rdata(reg_rdata_ds),
    .ds_status(ds_status),
    .reg_wen(reg_wen),

    .rxd(IO2[29]),
    .dout_cfg_bidir(dout_config_bidir),

    .ds_data_in(IO1[17]),
    .ds_data_out(dout3_ds),
    .ds_dir(dir34_ds),
    .ds_enable(ds_enable)
);


// --------------------------------------------------------------------------
// miscellaneous board I/Os
// --------------------------------------------------------------------------

// safety_amp_enable from SafetyCheck module
wire[4:1] safety_amp_disable;

// pwr_enable_cmd and amp_enable_cmd from BoardRegs; used to clear safety_amp_disable
wire pwr_enable_cmd;
wire[4:1] amp_enable_cmd;

// The Ethernet result is used to distinguish between FPGA versions
//    Rev 1:  Eth_Result == 32'd0
//    Rev 2:  Eth_Result[31] == 1, other bits variable
//    Rev 3:  Eth_Result[31:30] == 01, other bits variable
wire[31:0] Eth_Result;
assign  Eth_Result = 32'h40000000;

wire[31:0] reg_status;    // Status register
wire[31:0] reg_digio;     // Digital I/O register
wire[15:0] tempsense;     // Temperature sensor
wire[15:0] reg_databuf;   // Data collection status

wire reboot;              // Reboot the FPGA

// used to check status of user defined watchdog period; used to control LED 
wire      wdog_period_led;
wire[2:0] wdog_period_status;
wire wdog_timeout;
wire[31:0] clk_test;

BoardRegs chan0(
    .sysclk(sysclk),
    .reboot(reboot),
    .amp_disable({IO2[38],IO2[36],IO2[34],IO2[32]}),
    .dout(dout),
    .dout_cfg_valid(dout_config_valid),
    .dout_cfg_bidir(dout_config_bidir),
    .dout_cfg_reset(dout_config_reset),
    .pwr_enable(IO1[32]),
    .relay_on(IO1[31]),
    .isQuadDac(is_quad_dac),
    .dac_test_reset(dac_test_reset),
    .ioexp_cfg_reset(ioexp_cfg_reset),
    .ioexp_present(ioexp_cfg_present),
    .enc_a({IO2[17], IO2[19], IO2[21], IO2[23]}),    // axis 4:1
    .enc_b({IO2[10], IO2[12], IO2[13], IO2[15]}),
    .enc_i({IO2[2], IO2[4], IO2[6], IO2[8]}),
    .neg_limit({IO2[26],IO2[24],IO2[25],IO2[22]}),
    .pos_limit({IO2[30],IO2[29],IO2[28],IO2[27]}),
    .home({IO2[20],IO2[18],IO2[16],IO2[14]}),
    .fault({IO2[37],IO2[35],IO2[33],IO2[31]}),
    .relay(IO2[9]),
    .mv_faultn(IO1[7]),
    .mv_good(IO2[11]),
    .v_fault(IO1[9]),
    .safety_fb(~safety_fb_n),
    .mv_fb(mv_fb),
    .board_id(board_id),
    .temp_sense(tempsense),
    .reg_raddr(reg_raddr),
    .reg_waddr(reg_waddr),
    .reg_rdata(reg_rdata_chan0),
    .reg_wdata(reg_wdata),
    .reg_wen(reg_wen),
    .prom_status(clk_test),       // Not supported in V3
    .prom_result(32'd0),          // Not supported in V3
    .ip_address(32'hffffffff),
    .eth_result(Eth_Result),
    .ds_status(ds_status),
`ifdef DISABLE_SAFETY_CHECK
    .safety_amp_disable(4'd0),
`else
    .safety_amp_disable(safety_amp_disable),
`endif
    .pwr_enable_cmd(pwr_enable_cmd),
    .amp_enable_cmd(amp_enable_cmd),
    .reg_status(reg_status),
    .reg_digin(reg_digio),
    .wdog_period_led(wdog_period_led),
    .wdog_period_status(wdog_period_status),
    .wdog_timeout(wdog_timeout)
);

// --------------------------------------------------------------------------
// Sample data for block read
// --------------------------------------------------------------------------

SampleData sampler(
    .clk(sysclk),
    .doSample(sample_start),
    .isBusy(sample_busy),
    .reg_status(reg_status),
    .reg_digio(reg_digio),
    .reg_temp({reg_databuf, tempsense}),
    .chan(sample_chan),
    .adc_in(reg_adc_data),
    .enc_pos(reg_quad_data),
    .enc_period(reg_perd_data),
    .enc_qtr1(reg_qtr1_data),
    .enc_qtr5(reg_qtr5_data),
    .enc_run(reg_run_data),
    .motor_status(reg_motor_status),
    .blk_addr(sample_raddr),
    .blk_data(sample_rdata),
    .timestamp(timestamp)
);

// --------------------------------------------------------------------------
// Write data for real-time block
// --------------------------------------------------------------------------

WriteRtData rt_write(
    .clk(sysclk),
    .rt_write_en(rt_wen),       // Write enable
    .rt_write_addr(rt_waddr),   // Write address
    .rt_write_data(rt_wdata),   // Write data
    .bw_write_en(bw_write_en),
    .bw_reg_wen(bw_reg_wen),
    .bw_block_wen(bw_blk_wen),
    .bw_block_wstart(bw_blk_wstart),
    .bw_reg_waddr(bw_reg_waddr),
    .bw_reg_wdata(bw_reg_wdata)
);

// ----------------------------------------------------------------------------
// safety check 
//    1. get adc feedback current & dac command current
//    2. check if cur_fb > 2 * cur_cmd
SafetyCheck safe1(
    .clk(sysclk),
    .cur_in(cur_fb[1]),
    .dac_in(cur_cmd[1]),
    .clear_disable(pwr_enable_cmd | amp_enable_cmd[1]),
    .amp_disable(safety_amp_disable[1])
);

SafetyCheck safe2(
    .clk(sysclk),
    .cur_in(cur_fb[2]),
    .dac_in(cur_cmd[2]),
    .clear_disable(pwr_enable_cmd | amp_enable_cmd[2]),
    .amp_disable(safety_amp_disable[2])
);

SafetyCheck safe3(
    .clk(sysclk),
    .cur_in(cur_fb[3]),
    .dac_in(cur_cmd[3]),
    .clear_disable(pwr_enable_cmd | amp_enable_cmd[3]),
    .amp_disable(safety_amp_disable[3])
);

SafetyCheck safe4(
    .clk(sysclk),
    .cur_in(cur_fb[4]),
    .dac_in(cur_cmd[4]),
    .clear_disable(pwr_enable_cmd | amp_enable_cmd[4]),
    .amp_disable(safety_amp_disable[4])
);

// --------------------------------------------------------------------------
// Data Buffer
// --------------------------------------------------------------------------
wire[3:0] data_channel;
wire[31:0] reg_rdata_databuf;

DataBuffer data_buffer(
    .clk(sysclk),
    // data collection interface
    .cur_fb_wen(cur_fb_wen),
    .cur_fb(cur_fb[data_channel]),
    .chan(data_channel),
    // cpu interface
    .reg_waddr(reg_waddr),          // write address
    .reg_wdata(reg_wdata),          // write data
    .reg_wen(reg_wen),              // write enable
    .reg_raddr(reg_raddr),          // read address
    .reg_rdata(reg_rdata_databuf),  // read data
    // status and timestamp
    .databuf_status(reg_databuf),   // status for SampleData
    .ts(timestamp)                  // timestamp from SampleData
);

// LED on FPGA
assign LED = IO1[32];     // NOTE: IO1[32] pwr_enable

//------------------------------------------------------------------------------
// LEDs on QLA 
wire clk_12hz;
ClkDiv divclk12(sysclk, clk_12hz); defparam divclk12.width = 22;  // 49.152 MHz / 2**22 ==> 11.71875 Hz

CtrlLED qla_led(
    .sysclk(sysclk),
    .clk_12hz(clk_12hz),
    .wdog_period_led(wdog_period_led),
    .wdog_period_status(wdog_period_status),
    .wdog_timeout(wdog_timeout),
    .led1_grn(IO2[1]),
    .led1_red(IO2[3]),
    .led2_grn(IO2[5]),
    .led2_red(IO2[7])
);

wire clk_200MHz;

fpgav3 zynq_ps7(
    .processing_system7_0_MIO(MIO),
    .processing_system7_0_PS_SRSTB_pin(PS_SRSTB),
    .processing_system7_0_PS_CLK_pin(PS_CLK),
    .processing_system7_0_PS_PORB_pin(PS_PORB),
    .processing_system7_0_GPIO_I_pin({60'd0, board_id}),
    .processing_system7_0_FCLK_CLK0_pin(clk_200MHz),

    .gmii_to_rgmii_1_rgmii_txd_pin(E1_TxD),
    .gmii_to_rgmii_1_rgmii_tx_ctl_pin(E1_TxEN),
    .gmii_to_rgmii_1_rgmii_txc_pin(E1_TxCLK),
    .gmii_to_rgmii_1_rgmii_rxd_pin(E1_RxD),
    .gmii_to_rgmii_1_rgmii_rx_ctl_pin(E1_RxVAL),
    .gmii_to_rgmii_1_rgmii_rxc_pin(E1_RxCLK),
    .gmii_to_rgmii_1_gmii_txd_pin(E1_gmii_txd),
    .gmii_to_rgmii_1_gmii_tx_en_pin(E1_gmii_tx_en),
    .gmii_to_rgmii_1_gmii_tx_clk_pin(E1_gmii_tx_clk),
    .gmii_to_rgmii_1_gmii_rxd_pin(E1_gmii_rxd),
    .gmii_to_rgmii_1_gmii_rx_dv_pin(E1_gmii_rx_dv),
    .gmii_to_rgmii_1_gmii_rx_er_pin(E1_gmii_rx_er),
    .gmii_to_rgmii_1_gmii_rx_clk_pin(E1_gmii_rx_clk),
    .gmii_to_rgmii_1_MDIO_MDC_pin(E1_mdio_clk),       // MDIO clock from RTL8211F module
    .gmii_to_rgmii_1_MDIO_I_pin(E1_mdio_i),           // OUT from GMII core, IN to RTL8211F module
    .gmii_to_rgmii_1_MDIO_O_pin(E1_mdio_o),           // IN to GMII core, OUT from RTL8211F module
    .gmii_to_rgmii_1_MDIO_T_pin(E1_mdio_t),           // Tristate control from RTL8211F module
    .gmii_to_rgmii_1_MDC_pin(E1_MDIO_C)               // MDIO clock from GMII core (derived from E1_mdio_clk)

`ifdef ETHERNET_DUAL
    ,
    .gmii_to_rgmii_2_rgmii_txd_pin(E2_TxD),
    .gmii_to_rgmii_2_rgmii_tx_ctl_pin(E2_TxEN),
    .gmii_to_rgmii_2_rgmii_txc_pin(E2_TxCLK),
    .gmii_to_rgmii_2_rgmii_rxd_pin(E2_RxD),
    .gmii_to_rgmii_2_rgmii_rx_ctl_pin(E2_RxVAL),
    .gmii_to_rgmii_2_rgmii_rxc_pin(E2_RxCLK),
    .gmii_to_rgmii_2_gmii_txd_pin(E2_gmii_txd),
    .gmii_to_rgmii_2_gmii_tx_en_pin(E2_gmii_tx_en),
    .gmii_to_rgmii_2_gmii_tx_clk_pin(E2_gmii_tx_clk),
    .gmii_to_rgmii_2_gmii_rxd_pin(E2_gmii_rxd),
    .gmii_to_rgmii_2_gmii_rx_dv_pin(E2_gmii_rx_dv),
    .gmii_to_rgmii_2_gmii_rx_er_pin(E2_gmii_rx_er),
    .gmii_to_rgmii_2_gmii_rx_clk_pin(E2_gmii_rx_clk),
    .gmii_to_rgmii_1_MDIO_MDC_pin(E2_mdio_clk),       // MDIO clock from RTL8211F module
    .gmii_to_rgmii_2_MDIO_I_pin(E2_mdio_i),           // OUT from GMII core, IN to RTL8211F module
    .gmii_to_rgmii_2_MDIO_O_pin(E2_mdio_o),           // IN to GMII core, OUT from RTL8211F module
    .gmii_to_rgmii_2_MDIO_T_pin(E2_mdio_t),           // Tristate control from RTL8211F module
    .gmii_to_rgmii_2_MDC(E2_MDIO_C)                   // MDIO clock from GMII core (derived from E2_mdio_clk)
`endif
);

// *** BEGIN: TEST code for PS clocks
reg[15:0] cnt_200;
assign clk_test = {16'd0, cnt_200};   // quadlet read from 8 (PROM Status)

always @(posedge clk_200MHz)
begin
    cnt_200 <= cnt_200 + 16'd1;
end

// *** END: TEST code for PS clocks

endmodule

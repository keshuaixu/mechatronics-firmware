/* -*- Mode: Verilog; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*-   */
/* ex: set filetype=v softtabstop=4 shiftwidth=4 tabstop=4 cindent expandtab:      */

/*******************************************************************************
 *
 * Copyright(C) 2013-2020 ERC CISST, Johns Hopkins University.
 *
 * Purpose: Global constants e.g. device address
 * 
 * Revision history
 *     10/26/13    Zihan Chen          Initial revision
 *     07/31/20    Stefan Kohlgrueber  Revised to support digital control
 */
 
 /**************************************************************
  * NOTE:
  *   - InterfaceSpec: 
  *      - https://github.com/jhu-cisst/mechatronics-software/wiki/InterfaceSpec
  *   - Global Constants should be defined here
  **/


`ifndef _fpgaqla_constants_v_
`define _fpgaqla_constants_v_

// uncomment for simulation mode
//`define USE_SIMULATION 
//`define USE_CHIPSCOPE

// firmware constants
`define VERSION 32'h514C4131       // hard-wired version number "QLA1" = 0x514C4131 
`define FW_VERSION 32'h07          // firmware version = 7

// define board components
`define NUM_CHANNELS 4             // number of channels on QLA
`define NUM_PER_CHN_FIELDS 6       // number of per-channel entries in block read
                                   // (4 in Firmware Rev 1-6, 6 in Firmware Rev 7+)

// address space  
`define ADDR_MAIN     4'h0         // board reg & device reg
`define ADDR_HUB      4'h1         // hub address space
`define ADDR_PROM     4'h2         // prom address space
`define ADDR_PROM_QLA 4'h3         // prom qla address space
`define ADDR_ETH      4'h4         // ethernet (firewire packet) address space
`define ADDR_FW       4'h5         // firewire packet address space
`define ADDR_DS       4'h6         // Dallas 1-wire memory (dV instrument)
`define ADDR_DATA_BUF 4'h7         // Data buffer address space
`define ADDR_CTRL     4'h8         // closed-loop control

// channel 0 (board) registers
`define REG_STATUS   4'd0          // board id (8), fault (8), enable/masks (16)
`define REG_PHYCTRL  4'd1          // phy request bitstream (to request reg r/w)
`define REG_PHYDATA  4'd2          // holder for phy register read contents
`define REG_TIMEOUT  4'd3          // watchdog timer period register
`define REG_VERSION  4'd4          // read-only version number address
`define REG_TEMPSNS  4'd5          // temperature sensors (2x 8 bits concatenated)
`define REG_DIGIOUT  4'd6          // programmable digital outputs
`define REG_FVERSION 4'd7          // firmware version
`define REG_PROMSTAT 4'd8          // PROM interface status
`define REG_PROMRES  4'd9          // PROM result (from M25P16)
`define REG_DIGIN    4'd10         // Digital inputs (home, neg lim, pos lim)
`define REG_IPADDR   4'd11         // IP address
`define REG_ETHRES   4'd12         // Ethernet register I/O result (from KSZ8851)
`define REG_DSSTAT   4'd13         // Dallas chip status
`define REG_DEBUG    4'd15         // Debug register for testing 

// device register file offsets from channel base
// For additional fields, please see dev_addr in FireWire.v to send back data in the correct slot
`define OFF_ADC_DATA  4'h0         // adc data register offset (pot + cur)
`define OFF_CMD_CUR   4'h1         // commanded current bits //SK- XXX: was OFF_DAC_CTRL before change
`define OFF_POT_CTRL  4'h2         // pot control register offset
`define OFF_POT_DATA  4'h3         // pot data register offset
`define OFF_ENC_LOAD  4'h4         // enc data preload offset
`define OFF_ENC_DATA  4'h5         // enc quadrature register offset
`define OFF_PER_DATA  4'h6         // enc period register offset
`define OFF_QTR1_DATA 4'h7         // enc previous quarter offset
`define OFF_DOUT_CTRL 4'h8         // dout hi/lo period (16-bits hi, 16-bits lo)
`define OFF_QTR5_DATA 4'h9         // enc most recent quarter offset
`define OFF_RUN_DATA  4'hA         // enc running counter offset
`define OFF_DAC_VOLT  4'hB         // dac bits actually sent //SK - XXX


// Controller register fields, as there is not a sufficient amount to include them in the main fields
`define OFF_CO_CMD_FB               4'h0  // conversion offsets bits to amps for cur_cmd (high 16 bits) and cur_fb (low 16 bits) //SK - XXX
`define OFF_CTRL_CURR_Kp_KiT        4'h1  // Kp and Ki*T both *2^N_shift for CL current PID controller //SK - XXX
`define OFF_CTRL_CURR_KdT           4'h2  // Kd/T *2^N_shift for CL current PID controller //SK - XXX

`define OFF_CTRL_POS_Kp_KiT         4'h3  // Kp and Ki*T both *2^N_shift for CL position PID controller //SK - XXX
`define OFF_CTRL_POS_KdT_CF_OUT     4'h4  // Kd/T *2^N_shift for CL position PID controller and output conversion factor //SK - XXX
`define OFF_OUT_POS_CMD             4'h5  // Commanded position value

`define OFF_OUT_POS_OUT             4'h6  // PID_Pos output, solely intended for debugging
`define OFF_CTRL_SHIFTS             4'h7  // [31] = POSITION CONTORL ENABLE, [23:0] reserved for the shifts of the controller gains
                                          // [23:20] N_shift_Cur_Kp, [19:16] N_shift_Cur_KiT, [15:12] N_shift_Cur_KdT,
                                          // [11: 8] N_shift_Pos_Kp, [ 7: 4] N_shift_Pos_KiT, [ 3: 0] N_shift_Pos_KdT,


`define ENC_MIDRANGE 24'h800000    // encoder mid-range value

// FireWire transaction and response codes
`define TC_QWRITE 4'd0            // quadlet write
`define TC_BWRITE 4'd1            // block write
`define TC_QREAD 4'd4             // quadlet read
`define TC_BREAD 4'd5             // block read
`define TC_QRESP 4'd6             // quadlet read response
`define TC_BRESP 4'd7             // block read response
`define TC_CSTART 4'd8            // cycle start packet
`define RC_DONE 4'd0              // complete response code

// FireWire phy request types (Ref: Book P230)
`define LREQ_TX_IMM 3'd0          // immediate transmit header
`define LREQ_TX_ISO 3'd1          // isochronous transmit header
`define LREQ_TX_PRI 3'd2          // priority transmit header
`define LREQ_TX_FAIR 3'd3         // fair transmit header
`define LREQ_REG_RD 3'd4          // register read header
`define LREQ_REG_WR 3'd5          // register write header
`define LREQ_ACCEL 3'd6           // async arbitration acceleration
`define LREQ_RES 3'd7             // reserved, presumably do nothing

`endif  // _fpgaqla_constants_v_

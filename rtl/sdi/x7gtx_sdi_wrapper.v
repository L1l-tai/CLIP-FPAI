// (c) Copyright 2011 - 2014 Xilinx, Inc. All rights reserved.
//
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
//
//------------------------------------------------------------------------------
//   ____  ____
//  /   /\/   /
// /___/  \  /    Vendor: Xilinx
// \   \   \/     Version: $Revision: #3 $
//  \   \
//  /   /         Filename: $File: //Groups/video_ip/demos/K7/xapp592_k7_sdi_demos_ver2/SDI_wrapper/x7gtx_sdi_wrapper.v $
// /___/   /\     Timestamp: $DateTime: 2014/07/24 08:10:17 $
// \   \  /  \
//  \___\/\___\
//
// Description:
//  This wrapper file implementes a full SDI interface including a single GTX
//  transceiver, a SMPTE SD/HD/3G-SDI core, and all necessary control logic.
//  A GTX common wrapper that includes the QPLL must be connected to this wrapper.
//------------------------------------------------------------------------------
// DISCLAIMER
// This disclaimer is not a license and does not grant any
// rights to the materials distributed herewith. Except as
// otherwise provided in a valid license issued to you by
// Xilinx, and to the maximum extent permitted by applicable
// law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
// WITH ALL FAULTS, AND XILINX HEREBY DISCLAIMS ALL WARRANTIES
// AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
// BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
// INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
// (2) Xilinx shall not be liable (whether in contract or tort,
// including negligence, or under any other theory of
// liability) for any loss or damage of any kind or nature
// related to, arising under or in connection with these
// materials, including for any direct, or any indirect,
// special, incidental, or consequential loss or damage
// (including loss of data, profits, goodwill, or any type of
// loss or damage suffered as a result of any action brought
// by a third party) even if such damage or loss was
// reasonably foreseeable or Xilinx had been advised of the
// possibility of the same.
//
// CRITICAL APPLICATIONS
// Xilinx products are not designed or intended to be fail-
// safe, or for use in any application requiring fail-safe
// performance, such as life-support or safety devices or
// systems, Class III medical devices, nuclear facilities,
// applications related to the deployment of airbags, or any
// other applications that could lead to death, personal
// injury, or severe property or environmental damage
// (individually and collectively, "Critical
// Applications"). Customer assumes the sole risk and
// liability of any use of Xilinx products in Critical
// Applications, subject only to applicable laws and
// regulations governing limitations on product liability.
//
// THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
// PART OF THIS FILE AT ALL TIMES.

`timescale 1ns / 1ps

module x7gtx_sdi_wrapper #(
    parameter FXDCLK_FREQ               = 27000000,     // Frequency, in hertz, of fixed frequency clock
    parameter DRPCLK_PERIOD             = 13,           // Period of drpclk in ns, always round down
    parameter PLLLOCK_TIMEOUT_PERIOD    = 2000000,      // Period of PLLLOCK timeout in ns, defaults to 2ms
    parameter RESET_TIMEOUT_PERIOD      = 500000,       // Period of GTH RESETDONE timeout in ns, defaults to 500us
    parameter TIMEOUT_CNTR_BITWIDTH     = 15,           // Width in bits of timeout counter
    parameter RETRY_CNTR_BITWIDTH       = 8,            // Width in bits of the retry counter
    parameter CPLL_REFCLK_PORT          = "REFCLK1",    // Options are REFCLK0, REFCLK1, GREFCLK, NORTH0, NORTH1, SOUTH0, SOUTH1
    parameter TX_CLK0_QPLL              = 1,            // Set to 1 if QPLL is TX serial clock source with tx_m = 0, else set to 0
    parameter TX_CLK1_QPLL              = 0,            // Set to 1 if QPLL is TX serial clock source with tx_m = 1, else set to 0
    parameter GT_SIM_GTRESET_SPEEDUP    = "FALSE")
(
    input   wire        clk,                    // fixed frequency clock for GTX control module
    input   wire        drpclk,                 // DRPCLK
    input   wire        qpllclk,                // connect to the GTXE2_COMMON qplloutclk
    input   wire        qpllrefclk,             // Connect to the GTXE2_COMMON qplloutrefclk
    output  wire        qpllreset,
    input   wire        qplllock,
    input   wire        cpllrefclk,
    output  wire        cplllock,
    input   wire        rxp,
    input   wire        rxn,
    output  wire        txp,
    output  wire        txn,
  
// RX ports
    (*keep = "true"*)input  wire         rx_rst,                 // sync reset for SDI RX pipeline
    (*keep = "true"*)output wire         rx_usrclk_out,          // rxusrclk input
    (*keep = "true"*)input  wire         rx_gtx_full_reset,      // 1 causes a full reset of GTX RX, including the QPLL                  (drpclk)
    (*keep = "true"*)input  wire         rx_gtx_reset,           // 1 causes a GTRXRESET cycle to occur                                  (drpclk)
    (*keep = "true"*)input  wire         rx_refclk_stable,       // input must be low until reference clock to QPLLis stable             (async)
    (*keep = "true"*)input  wire         rx_frame_en,            // 1 = enable framer position update
    (*keep = "true"*)input  wire [2:0]   rx_mode_en,             // unary enable bits for SDI mode search {3G, SD, HD} 1=enable, 0=disable
    (*keep = "true"*)output wire [1:0]   rx_mode,                // 00=HD, 01=SD, 10=3G
    (*keep = "true"*)output wire         rx_mode_hd,             // 1 = HD mode
    (*keep = "true"*)output wire         rx_mode_sd,             // 1 = SD mode
    (*keep = "true"*)output wire         rx_mode_3g,             // 1 = 3G mode
    (*keep = "true"*)output wire         rx_mode_locked,         // auto mode detection locked
    (*keep = "true"*)output wire         rx_bit_rate,            // 0 = 1000/1000, 1 = 1000/1001
    (*keep = "true"*)output wire         rx_t_locked,            // transport format detection locked
    (*keep = "true"*)output wire [3:0]   rx_t_family,            // transport format family
    (*keep = "true"*)output wire [3:0]   rx_t_rate,              // transport frame rate
    (*keep = "true"*)output wire         rx_t_scan,              // transport scan: 0=interlaced, 1=progressive
    (*keep = "true"*)output wire         rx_level_b_3g,          // 0 = level A, 1 = level B
    (*keep = "true"*)output wire         rx_ce_sd,               // clock enable for SD, always 1 for HD & 3G
    (*keep = "true"*)output wire         rx_nsp,                 // framer new start position
    (*keep = "true"*)output wire [10:0]  rx_line_a,              // line number for HD & 3G (link A for level B)
    (*keep = "true"*)output wire [31:0]  rx_a_vpid,              // payload ID packet ds1 for 3G or HD-SDI
    (*keep = "true"*)output wire         rx_a_vpid_valid,        // 1 = rx_a_vpid is valid
    (*keep = "true"*)output wire [31:0]  rx_b_vpid,              // video payload ID packet data from data stream 2
    (*keep = "true"*)output wire         rx_b_vpid_valid,        // 1 = rx_b_vpid is valid
    (*keep = "true"*)output wire         rx_crc_err_a,           // CRC error for HD & 3G
    (*keep = "true"*)output wire [9:0]   rx_ds1a,                // data stream 1A: SD=Y/C, HD=Y, 3GA=ds1, 3GB=Y link A
    (*keep = "true"*)output wire [9:0]   rx_ds2a,                // data stream 2A: HD=C, 3GA=ds2, 3GB=C link A
    (*keep = "true"*)output wire         rx_eav,                 // 1 during XYZ word of EAV
    (*keep = "true"*)output wire         rx_sav,                 // 1 during XYZ word of SAV
    (*keep = "true"*)output wire         rx_trs,                 // 1 during all 4 words of EAV and SAV
    (*keep = "true"*)output wire [10:0]  rx_line_b,              // line number of 3G level B link B
    (*keep = "true"*)output wire         rx_dout_rdy_3g,         // 3G data ready: 1 for level A, asserted every other clock for level B
    (*keep = "true"*)output wire         rx_crc_err_b,           // CRC error for link B (level B only)
    (*keep = "true"*)output wire [9:0]   rx_ds1b,                // data stream 1B: 3G level B only = Y link B
    (*keep = "true"*)output wire [9:0]   rx_ds2b,                // data stream 2B: 3G level B only = C link B
    (*keep = "true"*)input  wire [15:0]  rx_edh_errcnt_en,       // enables various errors to increment rx_edh_errcnt
    (*keep = "true"*)input  wire         rx_edh_clr_errcnt,      // clears rx_edh_errcnt
    (*keep = "true"*)output wire         rx_edh_ap,              // 1 = AP CRC error detected previous field
    (*keep = "true"*)output wire         rx_edh_ff,              // 1 = FF CRC error detected previous field
    (*keep = "true"*)output wire         rx_edh_anc,             // 1 = ANC checksum error detected
    (*keep = "true"*)output wire [4:0]   rx_edh_ap_flags,        // EDH AP flags received in last EDH packet
    (*keep = "true"*)output wire [4:0]   rx_edh_ff_flags,        // EDH FF flags received in last EDH packet
    (*keep = "true"*)output wire [4:0]   rx_edh_anc_flags,       // EDH ANC flags received in last EDH packet
    (*keep = "true"*)output wire [3:0]   rx_edh_packet_flags,    // EDH packet error condition flags
    (*keep = "true"*)output wire [15:0]  rx_edh_errcnt,          // EDH error counter
    (*keep = "true"*)output wire         rx_change_done,         // 1 indicates resets or dynamic SDI mode changes are complete              (drpclk)
    (*keep = "true"*)output wire         rx_change_fail,         // 1 indicates failure of a reset or dynamic SDI mode change                (drpclk)
    (*keep = "true"*)output wire [2:0]   rx_change_fail_code,    // if rx_change_fail is 1, this port indicates reason for failure           (drpclk)
    (*keep = "true"*)output wire         drpbusy,                // 1 when the SDI RX control logic is using the GTX DRP                     (drpclk)

// TX ports
    input  wire         tx_rst,                 // sync reset for SDI TX pipeline
    output wire         tx_usrclk_out,          // clock input
    input  wire         tx_gtx_full_reset,      // causes a full reset of the GTH TX including PLL                          (drpclk)
    input  wire         tx_gtx_reset,           // causes a reset of the GTH TX, not including the PLL                      (drpclk)
    input  wire         tx_refclk_stable,       // assert high when reference clock to the TX PLL is stable                 (async)
    input  wire [2:0]   tx_ce,                  // clock enable - 3 identical copies
    input  wire         tx_din_rdy,             // input data ready for level B, must be 1 for all other modes
    input  wire [1:0]   tx_mode,                // 00 = HD, 01 = SD, 10 = 3G
    input  wire         tx_level_b_3g,          // 0 = level A, 1 = level B
    input  wire         tx_m,                   // 0 = select 148.5 MHz refclk, 1 = select 148.35 MHz refclk
    input  wire         tx_insert_crc,          // 1 = insert CRC for HD and 3G
    input  wire         tx_insert_ln,           // 1 = insert LN for HD and 3G
    input  wire         tx_insert_edh,          // 1 = generate & insert EDH for SD
    input  wire         tx_insert_vpid,         // 1 = enable ST352 PID packet insert
    input  wire         tx_overwrite_vpid,      // 1 = overwrite existing ST352 packets
    input  wire [9:0]   tx_video_a_y_in,        // Data stream Y link A input: SD Y/C, HD & 3GA Y in, 3GB A Y in
    input  wire [9:0]   tx_video_a_c_in,        // Data stream C link A input: HD & 3GA C in, 3GB A C in
    input  wire [9:0]   tx_video_b_y_in,        // 3G level B only: Data stream Y link B input
    input  wire [9:0]   tx_video_b_c_in,        // 3G level B only: Data stream C link B input
    input  wire [10:0]  tx_line_a,              // current line number for link A
    input  wire [10:0]  tx_line_b,              // current line number for link B
    input  wire [7:0]   tx_vpid_byte1,          // ST352 user data word 1
    input  wire [7:0]   tx_vpid_byte2,          // ST352 user data word 2
    input  wire [7:0]   tx_vpid_byte3,          // ST352 user data word 3
    input  wire [7:0]   tx_vpid_byte4a,         // ST352 user data word 4 for link A
    input  wire [7:0]   tx_vpid_byte4b,         // ST352 user data word 4 for link B
    input  wire [10:0]  tx_vpid_line_f1,        // insert ST352 packet on this line in field 1
    input  wire [10:0]  tx_vpid_line_f2,        // insert ST352 packet on this line in field 2
    input  wire         tx_vpid_line_f2_en,     // enable ST352 packet insertion in field 2
    output wire [9:0]   tx_ds1a_out,            // data stream 1, link A out
    output wire [9:0]   tx_ds2a_out,            // data stream 2, link A out
    output wire [9:0]   tx_ds1b_out,            // data stream 1, link B out
    output wire [9:0]   tx_ds2b_out,            // data stream 2, link B out
    input  wire         tx_use_dsin,            // 0=use the internal data streams, 1=use the tx_dsxx_in data streams
    input  wire [9:0]   tx_ds1a_in,             // data stream 1 link A in: SD Y/C, HD Y, 3G Y, dual-link A Y
    input  wire [9:0]   tx_ds2a_in,             // data stream 2 link A in: HD C, 3G C, dual-link A C
    input  wire [9:0]   tx_ds1b_in,             // data stream 1 link B in: dual-link B Y
    input  wire [9:0]   tx_ds2b_in,             // data stream 2 link B in: dual-link B C
    output wire         tx_ce_align_err,        // 1 if ce 5/6/5/6 cadence is broken
    output wire         tx_slew,                // slew rate control signal for SDI cable driver
    output  wire        tx_change_done,         // 1 when txrate or txsysclksel changes complete successfully               (drpclk)
    output  wire        tx_change_fail,         // 1 when txrate or txsysclksel changes fail                                (drpclk)
    output  wire [2:0]  tx_change_fail_code     // failure code when tx_change_fail = 1                                     (drpclk)
);

//
// Internal signals
//
wire [9:0]      rx_sd_rxdata;
wire            rx_sd_data_strobe;
wire            rx_m;
reg  [4:0]      rx_userrdy_gen = 5'b11111;
reg  [4:0]      tx_userrdy_gen = 5'b11111;
wire [1:0]      rx_mode_int;
wire [2:0]      rx_rate;
wire            rx_userrdy;
wire            rx_cdrhold;
wire            rx_usrclk;
wire [19:0]     rx_rxdata;
wire            rx_outclk;
wire            rx_gtrxreset;
wire            rx_resetdone;
wire            rx_change_done_int;
(* shreg_extract = "no", ASYNC_REG = "TRUE" *)
reg  [2:0]      rx_change_done_sss;
wire            rx_change_done_s;

wire            cplllock_int;
wire            cpllreset;
wire            tx_plllock;
reg             tx_plllock_0;
reg             tx_plllock_1;
wire            tx_gttxreset;
wire            tx_userrdy;
wire            tx_usrclk;
wire            tx_outclk;
wire [2:0]      tx_rate;
wire [1:0]      tx_bufstatus;
wire [19:0]     tx_txdata;
wire            tx_ratedone;
wire            tx_resetdone;
reg             cpll_refclk0;
reg             cpll_refclk1;
reg             cpll_grefclk;
reg             cpll_north0;
reg             cpll_north1;
reg             cpll_south0;
reg             cpll_south1;
wire            drprdy;
wire            drpen;
wire            drpwe;
wire [8:0]      drpaddr;
wire [15:0]     drpdi;
wire [1:0]      tx_sysclksel;

//------------------------------------------------------------------------------
// Configure PLL signals based on parameters
//
always @ (*)
    if (TX_CLK0_QPLL == 1)
        tx_plllock_0 = qplllock;
    else
        tx_plllock_0 = cplllock_int;

always @ (*)
    if (TX_CLK1_QPLL == 1)
        tx_plllock_1 = qplllock;
    else
        tx_plllock_1 = cplllock_int;

//assign tx_plllock = tx_plllock_0 & tx_plllock_1;
assign tx_plllock = tx_plllock_0 | tx_plllock_1;

always @ (*)
begin
    cpll_refclk0 = 1'b0;
    cpll_refclk1 = 1'b0;
    cpll_grefclk = 1'b0;
    cpll_north0 = 1'b0;
    cpll_north1 = 1'b0;
    cpll_south0 = 1'b0;
    cpll_south1 = 1'b0;

    case(CPLL_REFCLK_PORT)
        "REFCLK0": cpll_refclk0 = cpllrefclk;
        "REFCLK1": cpll_refclk1 = cpllrefclk;
        "GREFCLK": cpll_grefclk = cpllrefclk;
        "NORTH0" : cpll_north0  = cpllrefclk;
        "NORTH1" : cpll_north1  = cpllrefclk;
        "SOUTH0" : cpll_south0  = cpllrefclk;
        "SOUTH1" : cpll_south1  = cpllrefclk;
        default  : cpll_refclk1 = cpllrefclk;
    endcase
end

//------------------------------------------------------------------------------
// SMPTE SDI core
//
always @ (posedge rx_usrclk)
    rx_change_done_sss <= {rx_change_done_sss[1:0], rx_change_done_int};

assign rx_change_done_s = rx_change_done_sss[2];

smpte_sdi SDIRXTX (     // Edit this line to instance the name of the core as generated by CORE Generator
    .rx_rst             (rx_rst | ~rx_change_done_s),
    .rx_usrclk          (rx_usrclk),
    .rx_data_in         (rx_rxdata),
    .rx_sd_data_in      (rx_sd_rxdata),
    .rx_sd_data_strobe  (rx_sd_data_strobe),
    .rx_frame_en        (rx_frame_en),
    .rx_mode_en         (rx_mode_en),
    .rx_mode            (rx_mode_int),
    .rx_mode_hd         (rx_mode_hd),
    .rx_mode_sd         (rx_mode_sd),
    .rx_mode_3g         (rx_mode_3g),
    .rx_mode_detect_en  (1'b1),
    .rx_mode_locked     (rx_mode_locked),
    .rx_forced_mode     (2'b00),
    .rx_bit_rate        (rx_m),
    .rx_t_locked        (rx_t_locked),
    .rx_t_family        (rx_t_family),
    .rx_t_rate          (rx_t_rate),
    .rx_t_scan          (rx_t_scan),
    .rx_level_b_3g      (rx_level_b_3g),
    .rx_ce_sd           (rx_ce_sd),
    .rx_nsp             (rx_nsp),
    .rx_line_a          (rx_line_a),
    .rx_a_vpid          (rx_a_vpid),
    .rx_a_vpid_valid    (rx_a_vpid_valid),
    .rx_b_vpid          (rx_b_vpid),
    .rx_b_vpid_valid    (rx_b_vpid_valid),
    .rx_crc_err_a       (rx_crc_err_a),
    .rx_ds1a            (rx_ds1a),
    .rx_ds2a            (rx_ds2a),
    .rx_eav             (rx_eav),
    .rx_sav             (rx_sav),
    .rx_trs             (rx_trs),
    .rx_line_b          (rx_line_b),
    .rx_dout_rdy_3g     (rx_dout_rdy_3g),
    .rx_crc_err_b       (rx_crc_err_b),
    .rx_ds1b            (rx_ds1b),
    .rx_ds2b            (rx_ds2b),
    .rx_edh_errcnt_en   (rx_edh_errcnt_en),
    .rx_edh_clr_errcnt  (rx_edh_clr_errcnt),
    .rx_edh_ap          (rx_edh_ap),
    .rx_edh_ff          (rx_edh_ff),
    .rx_edh_anc         (rx_edh_anc),
    .rx_edh_ap_flags    (rx_edh_ap_flags),
    .rx_edh_ff_flags    (rx_edh_ff_flags),
    .rx_edh_anc_flags   (rx_edh_anc_flags),
    .rx_edh_packet_flags(rx_edh_packet_flags),
    .rx_edh_errcnt      (rx_edh_errcnt),

    .tx_rst             (tx_rst),
    .tx_usrclk          (tx_usrclk),
    .tx_ce              (tx_ce),
    .tx_din_rdy         (tx_din_rdy),
    .tx_mode            (tx_mode),
    .tx_level_b_3g      (tx_level_b_3g),
    .tx_insert_crc      (tx_insert_crc),
    .tx_insert_ln       (tx_insert_ln),
    .tx_insert_edh      (tx_insert_edh),
    .tx_insert_vpid     (tx_insert_vpid),
    .tx_overwrite_vpid  (tx_overwrite_vpid),
    .tx_video_a_y_in    (tx_video_a_y_in),
    .tx_video_a_c_in    (tx_video_a_c_in),
    .tx_video_b_y_in    (tx_video_b_y_in),
    .tx_video_b_c_in    (tx_video_b_c_in),
    .tx_line_a          (tx_line_a),
    .tx_line_b          (tx_line_b),
    .tx_vpid_byte1      (tx_vpid_byte1),
    .tx_vpid_byte2      (tx_vpid_byte2),
    .tx_vpid_byte3      (tx_vpid_byte3),
    .tx_vpid_byte4a     (tx_vpid_byte4a),
    .tx_vpid_byte4b     (tx_vpid_byte4b),
    .tx_vpid_line_f1    (tx_vpid_line_f1),
    .tx_vpid_line_f2    (tx_vpid_line_f2),
    .tx_vpid_line_f2_en (tx_vpid_line_f2_en),
    .tx_ds1a_out        (tx_ds1a_out),
    .tx_ds2a_out        (tx_ds2a_out),
    .tx_ds1b_out        (tx_ds1b_out),
    .tx_ds2b_out        (tx_ds2b_out),
    .tx_use_dsin        (tx_use_dsin),
    .tx_ds1a_in         (tx_ds1a_in),
    .tx_ds2a_in         (tx_ds2a_in),
    .tx_ds1b_in         (tx_ds1b_in),
    .tx_ds2b_in         (tx_ds2b_in),
    .tx_sd_bitrep_bypass(1'b0),
    .tx_txdata          (tx_txdata),
    .tx_ce_align_err    (tx_ce_align_err));

assign rx_bit_rate = rx_m;
assign rx_mode = rx_mode_int;

//------------------------------------------------------------------------------
// SDI GTX control module
//
// This module generates the GTTXRESET and GTRXRESET signals to the GTX. It
// also controls the RXCDRHOLD to place the CDR into lock to reference mode
// during SD-SDI mode. It also generates the RXRATE and TXRATE signals appropriately
// based on which SDI mode the RX and TX are in. Finally, it has a RX bit rate
// detection module that determines which bit rate is being received by the RX.
//
x7gtx_sdi_control #(
    .FXDCLK_FREQ            (FXDCLK_FREQ),
    .DRPCLK_PERIOD          (DRPCLK_PERIOD),
    .PLLLOCK_TIMEOUT_PERIOD (PLLLOCK_TIMEOUT_PERIOD),
    .RESET_TIMEOUT_PERIOD   (RESET_TIMEOUT_PERIOD),
    .TIMEOUT_CNTR_BITWIDTH  (TIMEOUT_CNTR_BITWIDTH),
    .RETRY_CNTR_BITWIDTH    (RETRY_CNTR_BITWIDTH),
    .TX_CLK0_QPLL           (TX_CLK0_QPLL),
    .TX_CLK1_QPLL           (TX_CLK1_QPLL))
GTX_CTRL (
    .fxdclk             (clk),
    .txusrclk           (tx_usrclk),
    .txmode             (tx_mode),
    .tx_full_reset      (tx_gtx_full_reset),
    .gttxreset_in       (tx_gtx_reset),
    .tx_refclk_stable   (tx_refclk_stable),
    .tx_pll_lock        (tx_plllock),
    .tx_m               (tx_m),
    .txsysclksel_m_0    (TX_CLK0_QPLL ? 2'b11 : 2'b00),
    .txsysclksel_m_1    (TX_CLK1_QPLL ? 2'b11 : 2'b00),
    .txresetdone        (tx_resetdone),
    .txratedone         (tx_ratedone),
    .gttxreset_out      (tx_gttxreset),
    .tx_pll_reset       (cpllreset),
    .txrate             (tx_rate),
    .txsysclksel        (tx_sysclksel),
    .txslew             (tx_slew),
    .tx_change_done     (tx_change_done),
    .tx_change_fail     (tx_change_fail),
    .tx_change_fail_code(tx_change_fail_code),
    .rxusrclk           (rx_usrclk),
    .rxmode             (rx_mode_int),
    .rx_full_reset      (rx_gtx_full_reset),
    .gtrxreset_in       (rx_gtx_reset),
    .rx_refclk_stable   (rx_refclk_stable),
    .rx_pll_lock        (qplllock),
    .rxresetdone        (rx_resetdone),
    .gtrxreset_out      (rx_gtrxreset),
    .rx_pll_reset       (qpllreset),
    .rxrate             (rx_rate),
    .rxcdrhold          (rx_cdrhold),
    .rx_m               (rx_m),
    .rx_change_done     (rx_change_done_int),
    .rx_change_fail     (rx_change_fail),
    .rx_change_fail_code(rx_change_fail_code),
    .dru_rst            (rx_rst),
    .data_in            (rx_rxdata),
    .sd_data            (rx_sd_rxdata),
    .sd_data_strobe     (rx_sd_data_strobe),
    .recclk_txdata      (),
    .drpclk             (drpclk),
    .drprdy             (drprdy),
    .drpaddr            (drpaddr),
    .drpdi              (drpdi),
    .drpen              (drpen),
    .drpwe              (drpwe),
    .drpbusy            (drpbusy)
    );

assign rx_change_done = rx_change_done_int;

//------------------------------------------------------------------------------
// GTX transceiver
//
k7gtx_sdi_wrapper_GT #(
    .GT_SIM_GTRESET_SPEEDUP         ("FALSE"))
GTX_i (
    .cpllfbclklost_out              (),
    .cplllock_out                   (cplllock_int),
    .cplllockdetclk_in              (clk),
    .cpllrefclklost_out             (),
    .cpllreset_in                   (cpllreset),

   //wyl .gtgrefclk_in                   (cpll_grefclk),
    .gtgrefclk_in                   (cpll_grefclk),
    .gtnorthrefclk0_in              (cpll_north0),
    .gtnorthrefclk1_in              (cpll_north1),
    .gtrefclk0_in                   (cpll_refclk0),
    .gtrefclk1_in                   (cpll_refclk1),
    .gtsouthrefclk0_in              (cpll_south0),
    .gtsouthrefclk1_in              (cpll_south1),

    .drpaddr_in                     (drpaddr),
    .drpclk_in                      (drpclk),
    .drpdi_in                       (drpdi),
    .drpdo_out                      (),
    .drpen_in                       (drpen),
    .drprdy_out                     (drprdy),
    .drpwe_in                       (drpwe),
    .qpllclk_in                     (qpllclk),
    .qpllrefclk_in                  (qpllrefclk),
    .txsysclksel_in                 (tx_sysclksel),
    .dmonitorout_out                (),
    .loopback_in                    (3'b000),
    .rxrate_in                      (rx_rate),
    .eyescanreset_in                (1'b0),
    .rxuserrdy_in                   (rx_userrdy),
    .eyescandataerror_out           (),
    .eyescantrigger_in              (1'b0),
    .rxcdrhold_in                   (rx_cdrhold),
    .rxusrclk_in                    (rx_usrclk),
    .rxusrclk2_in                   (rx_usrclk),
    .rxdata_out                     (rx_rxdata),
    .gtxrxp_in                      (rxp),
    .gtxrxn_in                      (rxn),
    .rxbufreset_in                  (1'b0),
    .rxbufstatus_out                (),
    .rxlpmhfhold_in                 (1'b0),
    .rxlpmlfhold_in                 (1'b0),
    .rxdfelpmreset_in               (1'b0),
    .rxmonitorout_out               (),
    .rxmonitorsel_in                (2'b00),
    .rxratedone_out                 (),
    .rxoutclk_out                   (rx_outclk),

    .gtrxreset_in                   (rx_gtrxreset),
    .rxpmareset_in                  (1'b0),
    .rxresetdone_out                (rx_resetdone),
    .txpostcursor_in                (5'b00000),
    .txprecursor_in                 (5'b00000),
    .gttxreset_in                   (tx_gttxreset),
    .txuserrdy_in                   (tx_userrdy),
    .txusrclk_in                    (tx_usrclk),
    .txusrclk2_in                   (tx_usrclk),
    .txrate_in                      (tx_rate),
    .txbufstatus_out                (tx_bufstatus),
    .txdiffctrl_in                  (4'b1000),
    .txdata_in                      (tx_txdata),
    .gtxtxn_out                     (txn),
    .gtxtxp_out                     (txp),
    .txoutclk_out                   (tx_outclk),
    .txoutclkfabric_out             (),
    .txoutclkpcs_out                (),
    .txratedone_out                 (tx_ratedone),
    .txpcsreset_in                  (tx_bufstatus[1]),
    .txpmareset_in                  (1'b0),
    .txresetdone_out                (tx_resetdone)
);

BUFG BUFGTX (
    .I      (tx_outclk),
    .O      (tx_usrclk));

assign tx_usrclk_out = tx_usrclk;

BUFG BUFGRX (
    .I      (rx_outclk),
    .O      (rx_usrclk));

assign rx_usrclk_out = rx_usrclk;

assign cplllock = cplllock_int;

//------------------------------------------------------------------------------
// It is a requirement to assert the TXUSERRDY and RXUSERRDY signals at least
// 5 cycles of their respective USRCLK after their respective GTX reset is negated.
//
always @ (posedge tx_usrclk or posedge tx_gttxreset)
    if (tx_gttxreset)
        tx_userrdy_gen <= 5'b11111;
    else
        tx_userrdy_gen <= {tx_userrdy_gen[3:0], 1'b0};

assign tx_userrdy = ~tx_userrdy_gen[4];

always @ (posedge rx_usrclk or posedge rx_gtrxreset)
    if (rx_gtrxreset)
        rx_userrdy_gen <= 5'b11111;
    else
        rx_userrdy_gen <= {rx_userrdy_gen[3:0], 1'b0};

assign rx_userrdy = ~rx_userrdy_gen[4];

endmodule

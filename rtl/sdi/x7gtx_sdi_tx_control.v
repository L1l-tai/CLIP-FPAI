// (c) Copyright 2013-2014 Xilinx, Inc. All rights reserved.
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
// \   \   \/     Version: $Revision: #1 $
//  \   \         
//  /   /         Filename: $File: //Groups/video_ip/demos/K7/xapp592_k7_sdi_demos_ver2/SDI_wrapper/x7gtx_sdi_tx_control.v $
// /___/   /\     Timestamp: $DateTime: 2014/03/13 12:31:24 $
// \   \  /  \
//  \___\/\___\
//
// Description:
//  This module implements the control logic for the TX portion of the GTX
//  transceiver for SDI applications.
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

`timescale 1 ns / 1 ns

module x7gtx_sdi_tx_control #( 
    parameter CLK_PERIOD                = 13,       // Period of clk in ns, always round down
    parameter PLLLOCK_TIMEOUT_PERIOD    = 2000000,  // Period of PLLLOCK timeout in ns, defaults to 2ms
    parameter RESET_TIMEOUT_PERIOD      = 500000,   // Period of RESETDONE timeout in ns, defaults to 500us
    parameter TIMEOUT_CNTR_BITWIDTH     = 19,       // Width in bits of timeout counter
    parameter RETRY_CNTR_BITWIDTH       = 8,        // Width in bits of the retry counter
    parameter TX_INPUT_SETTLE_BITWIDTH  = 5,        // Width in bits of the TX input settle counter
    parameter CLK0_QPLL                 = 0,        // Serial clock selected by tx_m=0 is QPLL (1) or CPLL (0) -- Default to CPLL
    parameter CLK1_QPLL                 = 1)        // Serial clock selected by tx_m=1 is QPLL (1) or CPLL (0) -- Default to QPLL
(
    input   wire        clk,                        // Fixed frequency clock
    input   wire        txusrclk,                   // TXUSRCLK
    input   wire        refclk_stable,              // High indicates reference clock is stable                 (async)
    input   wire        pll_lock,                   // PLL lock input                                           (async)
    input   wire [1:0]  txmode,                     // TX SDI mode                                              (txusrclk)
    input   wire        tx_m,                       // TX bit rate select (0=1000/1000, 1=1000/1001)            (async)
    input   wire [1:0]  txsysclksel_m_0,            // Value to output on TXSYSCLKSEL when tx_m is 0            (drpclk)
    input   wire [1:0]  txsysclksel_m_1,            // Value to output on TXSYSCLKSEL when tx_m is 1            (drpclk)
    input   wire        txresetdone,                // TXRESETDONE from the GTX                                 (async)
    input   wire        txratedone,                 // TXRATEDONE from the GTX                                  (async)
    input   wire        gttxreset_in,               // Causes a GTTXRESET sequence without a PLL reset          (drpclk)
    input   wire        full_reset,                 // Causes a full PLL reset followed by GTTXRESET sequence   (drpclk)
    output  wire        gttxreset,                  // GTX reset output                                         (drpclk)
    output  wire        pll_reset,                  // PLL reset output                                         (drpclk)
    output  reg  [2:0]  txrate = 3'b010,            // Connect to TXRATE input of GTX                           (txusrclk)
    output  wire [1:0]  txsysclksel,                // Connect to TXSYSCLKSEL input of GTX                      (drpclk)
    output  wire        done,                       // Sequence done output                                     (drpclk)
    output  wire        fail,                       // Sequence failure output                                  (drpclk)
    output  wire [2:0]  fail_code                   // Sequence failure code                                    (drpclk)
);

localparam TXMODE_SD        = 2'b01;
localparam TXMODE_HD        = 2'b00;
localparam TXMODE_3G        = 2'b10;
localparam TXMODE_SD_UNARY  = 3'b001;
localparam TXMODE_HD_UNARY  = 3'b010;
localparam TXMODE_3G_UNARY  = 3'b100;
localparam RATE_DIV2_UNARY  = 3'b001;
localparam RATE_DIV4_UNARY  = 3'b010;
localparam RATE_DIV8_UNARY  = 3'b100;
localparam RATE_DIV2        = 3'b010;
localparam RATE_DIV4        = 3'b011;
localparam RATE_DIV8        = 3'b100;

reg     [1:0]       txmode_reg = TXMODE_HD;
reg     [2:0]       txmode_unary;
wire    [2:0]       txmode_unary_ds;
reg     [1:0]       txmode_ds = TXMODE_HD;
wire                tx_m_ts;
wire                done_i;
wire                done_int;
wire                fail_i;
wire                ld_txrate;
wire                ld_txsysclksel;
wire                refclk_stable_ds;
wire                pll_lock_ds;
wire                txrate_change_req;
wire                txsysclksel_change_req;
wire                txrate_priority;
wire    [2:0]       txrate_unary;
wire    [2:0]       txrate_unary_ts;
reg     [2:0]       txrate_valid;

//
// Input register & unary bit encoding for txmode
//
always @ (posedge txusrclk)
    txmode_reg <= txmode;

always @ (*)
    case(txmode_reg)
        TXMODE_SD:  txmode_unary = TXMODE_SD_UNARY;
        TXMODE_3G:  txmode_unary = TXMODE_3G_UNARY;
        default:    txmode_unary = TXMODE_HD_UNARY;
    endcase

//
// Sync signals to the drpclk domain
//
sdi_control_sync_block TXMODESD (
    .clk    (clk),
    .din    (txmode_unary[0]),
    .dout   (txmode_unary_ds[0]));

sdi_control_sync_block #(
    .INITIALIZE (2'b11))        // Set this as the default txmode on startup
TXMODEHD (
    .clk    (clk),
    .din    (txmode_unary[1]),
    .dout   (txmode_unary_ds[1]));

sdi_control_sync_block TXMODE3G (
    .clk    (clk),
    .din    (txmode_unary[2]),
    .dout   (txmode_unary_ds[2]));

sdi_control_sync_block TX_M_SYNC (
    .clk    (clk),
    .din    (tx_m),
    .dout   (tx_m_ds));

sdi_control_sync_block REFCLK_STABLE_SYNC (
    .clk    (clk),
    .din    (refclk_stable),
    .dout   (refclk_stable_ds));

sdi_control_sync_block PLL_LOCK_SYNC (
    .clk    (clk),
    .din    (pll_lock),
    .dout   (pll_lock_ds));

sdi_control_sync_block TXRESETDONE_SYNC (
    .clk    (clk),
    .din    (txresetdone),
    .dout   (txresetdone_ds));

//
// txmode_unary validation
//
always @ (posedge clk)
    if (txmode_unary_ds == TXMODE_SD_UNARY)
        txmode_ds <= TXMODE_SD;
    else if (txmode_unary_ds == TXMODE_HD_UNARY)
        txmode_ds <= TXMODE_HD;
    else if (txmode_unary_ds == TXMODE_3G_UNARY)
        txmode_ds <= TXMODE_3G;
    else
        txmode_ds <= txmode_ds;

//
// TX control change sequencer state machine
//
x7gtx_sdi_tx_sequence #(
    .TX_INPUT_SETTLE_BITWIDTH   (TX_INPUT_SETTLE_BITWIDTH),
    .CLK0_QPLL                  (CLK0_QPLL),
    .CLK1_QPLL                  (CLK1_QPLL))
SEQUENCE (
    .clk                        (clk),
    .tx_m                       (tx_m_ds),
    .txmode                     (txmode_ds),
    .txsysclksel_m_0            (txsysclksel_m_0),
    .txsysclksel_m_1            (txsysclksel_m_1),
    .ld_txrate                  (ld_txrate),
    .ld_txsysclksel             (ld_txsysclksel),
    .done_in                    (done_int),
    .fail                       (fail_i),
    .done_out                   (done_i),
    .txrate_change_req          (txrate_change_req),
    .txsysclksel_change_req     (txsysclksel_change_req),
    .txsysclksel                (txsysclksel),
    .txrate_unary               (txrate_unary));

//
// Move the unary encoded TXRATE signals over to the txusrclk domain and then 
// validate them and convert them to non-unary encoded TXRATE signals to send to
// the GTX.
//
sdi_control_sync_block TXRATE2_SYNC (
    .clk    (txusrclk),
    .din    (txrate_unary[0]),
    .dout   (txrate_unary_ts[0]));

sdi_control_sync_block TXRATE4_SYNC (
    .clk    (txusrclk),
    .din    (txrate_unary[1]),
    .dout   (txrate_unary_ts[1]));

sdi_control_sync_block TXRATE8_SYNC (
    .clk    (txusrclk),
    .din    (txrate_unary[2]),
    .dout   (txrate_unary_ts[2]));

always @ (posedge txusrclk)
    if (txrate_unary_ts == RATE_DIV2_UNARY)
        txrate <= RATE_DIV2;
    else if (txrate_unary_ts == RATE_DIV4_UNARY)
        txrate <= RATE_DIV4;
    else if (txrate_unary_ts == RATE_DIV8_UNARY)
        txrate <= RATE_DIV8;
    else
        txrate <= txrate;
//
// TX control master control FSM
//
x7gtx_sdi_tx_control_fsm #(
    .CLK_PERIOD                 (CLK_PERIOD),
    .PLLLOCK_TIMEOUT_PERIOD     (PLLLOCK_TIMEOUT_PERIOD),
    .RESET_TIMEOUT_PERIOD       (RESET_TIMEOUT_PERIOD),
    .TIMEOUT_CNTR_BITWIDTH      (TIMEOUT_CNTR_BITWIDTH),
    .RETRY_CNTR_BITWIDTH        (RETRY_CNTR_BITWIDTH))
MASTER (
    .clk                        (clk),
    .refclk_stable              (refclk_stable_ds),
    .pll_lock                   (pll_lock_ds),
    .txrate_change_req          (txrate_change_req),
    .txsysclksel_change_req     (txsysclksel_change_req),
    .txresetdone                (txresetdone_ds),
    .txratedone                 (txratedone),
    .gttxreset_in               (gttxreset_in),
    .full_reset                 (full_reset),
    .gttxreset                  (gttxreset),
    .pll_reset                  (pll_reset),
    .ld_txrate                  (ld_txrate),
    .ld_txsysclksel             (ld_txsysclksel),
    .done                       (done_int),
    .fail                       (fail_i),
    .fail_code                  (fail_code));

assign done = done_i;
assign fail = fail_i;

endmodule
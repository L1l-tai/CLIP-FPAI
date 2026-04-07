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
// \   \   \/     Version: $Revision: #1 $
//  \   \         
//  /   /         Filename: $File: //Groups/video_ip/demos/K7/xapp592_k7_sdi_demos_ver2/SDI_wrapper/x7gtx_sdi_control.v $
// /___/   /\     Timestamp: $DateTime: 2014/03/13 12:31:24 $
// \   \  /  \
//  \___\/\___\
//
// Description:
//  This module handles general control of SDI mode changes for the Xilinx 7-series
//  GTX transceiver. It also contains the RX input bit rate detection module.
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

module x7gtx_sdi_control #( 
    parameter FXDCLK_FREQ               = 27000000, // Frequency, in hertz, of fxdclk
    parameter DRPCLK_PERIOD             = 13,       // Period of drpclk in ns, always round down
    parameter PLLLOCK_TIMEOUT_PERIOD    = 2000000,  // Period of PLLLOCK timeout in ns, defaults to 2ms
    parameter RESET_TIMEOUT_PERIOD      = 500000,   // Period of GTH RESETDONE timeout in ns, defaults to 500us
    parameter TIMEOUT_CNTR_BITWIDTH     = 15,       // Width in bits of timeout counter
    parameter RETRY_CNTR_BITWIDTH       = 8,        // Width in bits of the retry counter
    parameter TX_CLK0_QPLL              = 1,        // Set to 1 if QPLL is TX clock source when tx_m = 0, 0 otherwise
    parameter TX_CLK1_QPLL              = 0)        // Set to 1 if QPLL is TX clock source when tx_m = 1, 0 otherwise
(
    input   wire        fxdclk,                        // Fixed clock

// TX related signals
    input   wire        txusrclk,                   // Connect to same clock as drives GTX TXUSRCLK2
    input   wire [1:0]  txmode,                     // TX mode select: 00=HD, 01=SD, 10=3G (synchronous to txusrclk)
    input   wire        tx_full_reset,
    input   wire        gttxreset_in,
    input   wire        tx_refclk_stable,
    input   wire        tx_pll_lock,                // Connect to {Q|C}PLLLOCK output of GTX
    input   wire        tx_m,                       // TX bit rate select (0=1000/1000, 1=1000/1001)
    input   wire [1:0]  txsysclksel_m_0,            // value to output on TXSYSCLKSEL when tx_m is 0
    input   wire [1:0]  txsysclksel_m_1,            // value to output on TXSYSCLKSEL when tx_m is 1
    input   wire        txresetdone,
    input   wire        txratedone,
    output  wire        gttxreset_out,              // Connect to GTTXRESET input of GTX
    output  wire        tx_pll_reset,
    output  wire [2:0]  txrate,                     // Connect to TXRATE input of GTX
    output  wire [1:0]  txsysclksel,                // Connect to TXSYSCLKSEL port of GTX when doing dynamic clock source switching
    output  reg         txslew = 1'b0,              // Slew rate control signal for SDI cable driver
    output  wire        tx_change_done,
    output  wire        tx_change_fail,
    output  wire [2:0]  tx_change_fail_code,

// RX related signals
    input   wire        rxusrclk,                   // Connect to same clock as drives GTX RXUSRCLK2
    input   wire [1:0]  rxmode,                     // RX mode select: 00=HD, 01=SD, 10=3G (sync with rxusrclk)
    input   wire        rx_full_reset,
    input   wire        gtrxreset_in,               // Causes GTRXRESET sequence
    input   wire        rx_refclk_stable,           // Assert High when PLL reference clock is stable
    input   wire        rx_pll_lock,                // Connect to PLL{0|1}LOCK output of GTP
    input   wire        rxresetdone,                // Connect to RXRESETDONE port of the GTP
    output  wire        gtrxreset_out,              // Connect to GTRXRESET input of GTP
    output  wire        rx_pll_reset,               // Connect to PLL{0|1}RESET port of GTP
    output  wire [2:0]  rxrate,                     // Connect to RXRATE port of GTX
    output  wire        rxcdrhold,                  // Connect to RXCDRHOLD port of GTX
    output  wire        rx_m,                       // Indicates received bit rate: 1=/1.001 rate, 0 = /1 rate
    output  wire        rx_change_done,             // Indicates successful completion of reset or dynamic SDI mode change sequence
    output  wire        rx_change_fail,             // Indicates failure of reset or dynamic mode change sequence
    output  reg  [2:0]  rx_change_fail_code = 3'b000,//If rx_change_fail = 1, indicates reason for failure

// SD-SDI DRU signals
    input   wire         dru_rst,                   // Sync reset input for DRU
    input   wire [19:0]  data_in,                   // 11X oversampled data input vector
    output  reg  [9:0]   sd_data = 0,               // Recovered SD-SDI data
    output  wire         sd_data_strobe,            // Asserted high when an output data word is ready
    output  wire [19:0]  recclk_txdata,             // Optional output data for recovering a clock using transitter

// DRP signals -- The DRP is used to change the RXCDR_CFG attribute depending
// on the RX SDI mode. Connect these signal to the DRP of the GTX associated
// with the SDI RX. If the SDI RX function is not used (TX-only) then these
// signals don't need to be connected to the GTX.
    input   wire        drpclk,                     // Connect to GTX DRP clock
    input   wire        drprdy,                     // Connect to GTX DRPRDY port
    output  wire [8:0]  drpaddr,                    // Connect to GTX DRPADDR port
    output  wire [15:0] drpdi,                      // Connect to GTX DRPDI port
    output  wire        drpen,                      // Connect to GTX DRPEN port
    output  wire        drpwe,                      // Connect to GTX DRPWE port

    output  wire        drpbusy                     // 1 when the DRP is being used by the SDI logic                (drpclk)
);

//
// These parameters define the encoding of the txmode and rxmode ports.
//
localparam MODE_HD = 2'b00;
localparam MODE_SD = 2'b01;
localparam MODE_3G = 2'b10;


wire [3:0]          samv;
wire [9:0]          sam;
wire [9:0]          dru_dout;
wire                dru_drdy;

wire                pll_gtrxreset;
wire                drp_gtrxreset;
wire                drp_full_reset;
wire                drpbusy_rst;
wire                drpbusy_drp;

wire                rx_change_done_rst;
wire                rx_change_fail_rst;
wire                rx_change_fail_code_rst;
wire                rx_change_done_drp;
wire                rx_change_fail_drp;
wire [2:0]          rx_change_fail_code_drp;
        
//------------------------------------------------------------------------------
// x7gtx_sdi_rx_reset_control
//
// This module controls resets of the GTX RX and the PLL in response to the
// assertion of the full_reset or gtrxreset_in signals.
//
x7gtx_sdi_rx_reset_control #(
    .DRPCLK_PERIOD      (DRPCLK_PERIOD))
RXRST (
    .drpclk             (drpclk),
    .refclk_stable      (rx_refclk_stable),
    .pll_lock           (rx_pll_lock),
    .rxresetdone        (rxresetdone),
    .drp_busy_in        (1'b0),
    .gtrxreset_in       (gtrxreset_in | drp_gtrxreset),
    .full_reset         (rx_full_reset | drp_full_reset),
    .drp_busy_out       (drpbusy_rst),
    .gtrxreset          (gtrxreset_out),
    .pll_reset          (rx_pll_reset),
    .done               (rx_change_done_rst),
    .fail               (rx_change_fail_rst),
    .fail_code          (rx_change_fail_code_rst),
    .drp_priority_req   ());

//------------------------------------------------------------------------------
// RX bit rate detection
//
sdi_rate_detect #(
    .REFCLK_FREQ     (FXDCLK_FREQ))
RATE0 (
    .refclk         (fxdclk),
    .recvclk        (rxusrclk),
    .std            (rxmode[1]),
    .rate_change    (),
    .enable         (rxresetdone),
    .drift          (),
    .rate           (rx_m));

//------------------------------------------------------------------------------
// 11X oversampling data recovery unit for SD-SDI
//
dru NIDRU (
    .DT_IN      (data_in),
    .CENTER_F   (37'b0000111010001101011111110100101111011),
    .G1         (5'b00110),
    .G1_P       (5'b10000),
    .G2         (5'b00111),
    .CLK        (rxusrclk),
    .RST        (~dru_rst),         // The NI-DRU reset is asserted low
    .RST_FREQ   (1'b1),
    .VER        (),
    .EN         (1'b1),
    .INTEG      (),
    .DIRECT     (),
    .CTRL       (),
    .PH_OUT     (),
    .RECCLK     (recclk_txdata),
    .SAMV       (samv),
    .SAM        (sam));

dru_bshift10to10 DRUBSHIFT (
    .CLK        (rxusrclk),
    .RST        (~dru_rst),
    .DIN        ({8'b0, sam[1:0]}),
    .DV         ({2'b0, samv[1:0]}),
    .DV10       (dru_drdy),
    .DOUT10     (dru_dout));

always @ (posedge rxusrclk)
    if (dru_drdy)
        sd_data <= dru_dout;

assign sd_data_strobe = dru_drdy;

//------------------------------------------------------------------------------
// DRP controller
//
// The DRP controller changes the RXCDR_CFG attribute dynamically depending on the
// SDI mode of the RX. It also controls the rxrate and rxcdrhold ports of the
// GTX and resets the GTX after SDI mode changes.
//

x7gtx_sdi_drp_control SDIDRPCTRL
(
    .drpclk             (drpclk),
    .rxusrclk           (rxusrclk),
    .rst                (rx_pll_reset),
    .init_done          (rx_change_done_rst),
    .rx_mode            (rxmode),
    .rx_rate            (rxrate),
    .drpbusy_out        (drpbusy_drp),
    .drprdy             (drprdy),
    .drpaddr            (drpaddr),
    .drpdi              (drpdi),
    .drpen              (drpen),
    .drpwe              (drpwe),
    .done               (rx_change_done_drp),
    .fail               (rx_change_fail_drp),
    .fail_code          (rx_change_fail_code_drp),
    .rxcdrhold          (rxcdrhold),
    .gtrxreset          (drp_gtrxreset),
    .full_reset         (drp_full_reset));
    
assign drpbusy = drpbusy_rst | drpbusy_drp;

assign rx_change_fail = rx_change_fail_drp | rx_change_fail_rst;
assign rx_change_done = rx_change_done_drp & rx_change_done_rst;

always @ (posedge drpclk)
    if (rx_change_fail_rst && rx_change_fail_code_rst == 1'b0)
        rx_change_fail_code <= 3'b000;
    else if (rx_change_fail_rst && rx_change_fail_code_rst == 1'b1)
        rx_change_fail_code <= 3'b001;
    else if (rx_change_fail_drp)
        rx_change_fail_code <= rx_change_fail_code_drp;
    else
        rx_change_fail_code <= 3'b000;

//------------------------------------------------------------------------------
// TX control logic
//
// This module controls the TXRATE, TXSYSCLKSEL, GTTXRESET, and PLLRESET signals
// in order to initialize the GTX TX and to change the SDI mode and the clock
// source of the GTX TX.
//
x7gtx_sdi_tx_control #(
    .CLK_PERIOD         (DRPCLK_PERIOD),
    .CLK0_QPLL          (TX_CLK0_QPLL),
    .CLK1_QPLL          (TX_CLK1_QPLL))
TXCTRL (
    .clk                (drpclk),
    .txusrclk           (txusrclk),
    .refclk_stable      (tx_refclk_stable),
    .pll_lock           (tx_pll_lock),
    .txmode             (txmode),
    .tx_m               (tx_m),
    .txsysclksel_m_0    (txsysclksel_m_0),
    .txsysclksel_m_1    (txsysclksel_m_1),
    .txresetdone        (txresetdone),
    .txratedone         (txratedone),
    .gttxreset_in       (gttxreset_in),
    .full_reset         (tx_full_reset),
    .gttxreset          (gttxreset_out),
    .pll_reset          (tx_pll_reset),
    .txrate             (txrate),
    .txsysclksel        (txsysclksel),
    .done               (tx_change_done),
    .fail               (tx_change_fail),
    .fail_code          (tx_change_fail_code));

always @ (posedge txusrclk)
    txslew <= txmode == MODE_SD;

endmodule
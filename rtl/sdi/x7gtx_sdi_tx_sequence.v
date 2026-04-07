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
//  /   /         Filename: $File: //Groups/video_ip/demos/K7/xapp592_k7_sdi_demos_ver2/SDI_wrapper/x7gtx_sdi_tx_sequence.v $
// /___/   /\     Timestamp: $DateTime: 2014/03/13 12:31:24 $
// \   \  /  \
//  \___\/\___\
//
// Description:
//  This module implements a finite state machine that sequences the TXRATE
//  and TXSYSCLKSEL change operations when they are both requested 
//  simultaneously.
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

module x7gtx_sdi_tx_sequence #(
    parameter TX_INPUT_SETTLE_BITWIDTH  = 5,
    parameter CLK0_QPLL                 = 0,
    parameter CLK1_QPLL                 = 1)
(                                                   // all inputs & outputs are synchronous with free running drpclk domain
    input   wire        clk,                        // free running clock
    input   wire        tx_m,                       // PLL select input
    input   wire [1:0]  txmode,                     // TX SDI mode select
    input   wire [1:0]  txsysclksel_m_0,
    input   wire [1:0]  txsysclksel_m_1,
    input   wire        ld_txrate,
    input   wire        ld_txsysclksel,
    input   wire        done_in,
    input   wire        fail,
    output  reg         done_out = 1'b0,
    output  wire        txrate_change_req,          // TXRATE change request output
    output  wire        txsysclksel_change_req,     // TXSYSCLKSEL change request output
    output  wire [1:0]  txsysclksel,                // TXSYSCLKSEL output
    output  wire [2:0]  txrate_unary                // TXRATE output
);

localparam TXMODE_SD        = 2'b01;
localparam TXMODE_HD        = 2'b00;
localparam TXMODE_3G        = 2'b10;
localparam RATE_DIV2_UNARY  = 3'b001;
localparam RATE_DIV4_UNARY  = 3'b010;
localparam RATE_DIV8_UNARY  = 3'b100;

//
// These parameters define the encoding of the FSM states
//
localparam STATE_WIDTH = 3;

localparam [STATE_WIDTH-1:0]
    READY_STATE             = 3'b000,
    SETTLE_STATE            = 3'b001,
    FREEZE_STATE            = 3'b010,
    PIPEDLY_STATE           = 3'b011,
    TXRATE1_STATE           = 3'b100,
    TXRATE2_STATE           = 3'b101,
    TXSYSCLKSEL1_STATE      = 3'b110,
    TXSYSCLKSEL2_STATE      = 3'b111;

reg     [STATE_WIDTH-1:0]               current_state = READY_STATE;
reg     [STATE_WIDTH-1:0]               next_state;
reg     [TX_INPUT_SETTLE_BITWIDTH-1:0]  settle_cntr = 0;
reg                                     clr_settle_cntr;
wire                                    settle_tc;
reg                                     tx_m_reg = 1'b0;
reg     [1:0]                           txmode_reg = TXMODE_HD;
reg     [2:0]                           new_txrate_unary = RATE_DIV4_UNARY;
wire    [1:0]                           new_txsysclksel;
wire                                    txsysclksel_diff;
wire                                    txrate_diff;
wire                                    txrate_priority;
reg                                     freeze_inputs = 1'b0;   
reg                                     set_freeze;
reg                                     clr_freeze; 
reg     [1:0]                           txsysclksel_reg = 2'b00;
reg     [2:0]                           txrate_unary_reg = RATE_DIV4_UNARY;
reg                                     pass_done;
reg                                     txrate_req;
reg                                     txsysclksel_req;
reg                                     qpll_selected;

//
// Input registers with a freeze control signal from the FSM
//
always @ (posedge clk)
    if (~freeze_inputs)
    begin
        tx_m_reg <= tx_m;
        txmode_reg <= txmode;
    end

//
// TXRATE and TXSYSCLKSEL generation
always @ (posedge clk)
    if (txmode_reg == TXMODE_HD)
        new_txrate_unary <= RATE_DIV4_UNARY;
    else
        new_txrate_unary <= RATE_DIV2_UNARY;

assign new_txsysclksel = tx_m_reg ? txsysclksel_m_1 : txsysclksel_m_0;

always @ (posedge clk)
    if (ld_txsysclksel)
        txsysclksel_reg <= new_txsysclksel;

assign txsysclksel = txsysclksel_reg;

always @ (posedge clk)
    if (ld_txrate)
        txrate_unary_reg <= new_txrate_unary;

assign txrate_unary = txrate_unary_reg;

//
// Change detectors
//
assign txsysclksel_diff = new_txsysclksel != txsysclksel_reg;
assign txrate_diff = new_txrate_unary != txrate_unary_reg;

always @ (*)
    if ((txsysclksel_reg == txsysclksel_m_0) && (CLK0_QPLL == 1))
        qpll_selected = 1'b1;
    else if ((txsysclksel_reg == txsysclksel_m_1) && (CLK1_QPLL == 1))
        qpll_selected = 1'b1;
    else
        qpll_selected = 1'b0;

assign txrate_priority = ~(qpll_selected & (new_txrate_unary == RATE_DIV2_UNARY));

//
// Settle counter
//
always @ (posedge clk)
    if (clr_settle_cntr)
        settle_cntr <= 0;
    else
        settle_cntr <= settle_cntr + 1;

assign settle_tc = &settle_cntr;

//
// Done output
//
// Block the done from the change FSM if there are pending requests. This prevents
// a short 4 clock cycle pulse on the done output in the middle of changing both
// TXRATE and TXSYSCLKSEL.
//
always @ (posedge clk)
    done_out <= done_in & pass_done;

//
// Input register freeze control FF
//
always @ (posedge clk)
    if (set_freeze)
        freeze_inputs <= 1'b1;
    else if (clr_freeze)
        freeze_inputs <= 1'b0;

//
// FSM current state register
// 
always @ (posedge clk)
    current_state <= next_state;

//
// FSM next state logic
//
always @ (*)
begin
    case(current_state)
        READY_STATE:
            if (fail)
                next_state = READY_STATE;
            else if (txrate_diff | txsysclksel_diff)
                next_state = SETTLE_STATE;
            else
                next_state = READY_STATE;

        SETTLE_STATE:
            if (~settle_tc)
                next_state = SETTLE_STATE;
            else
                next_state = FREEZE_STATE;

        FREEZE_STATE:
            next_state = PIPEDLY_STATE;

        PIPEDLY_STATE:
            if (txrate_diff & (~txsysclksel_diff | txrate_priority))
                next_state = TXRATE1_STATE;
            else if (~txsysclksel_diff)
                next_state = READY_STATE;
            else
                next_state = TXSYSCLKSEL1_STATE;

        TXRATE1_STATE:
            if (ld_txrate)
                next_state = TXRATE2_STATE;
            else if (fail)
                next_state = READY_STATE;
            else 
                next_state = TXRATE1_STATE;

        TXRATE2_STATE:
            if (fail)
                next_state = READY_STATE;
            else if (done_in)
            begin
                if (txsysclksel_diff)
                    next_state = TXSYSCLKSEL1_STATE;
                else
                    next_state = READY_STATE;
            end
            else
                next_state = TXRATE2_STATE;

        TXSYSCLKSEL1_STATE:
            if (ld_txsysclksel)
                next_state = TXSYSCLKSEL2_STATE;
            else if (fail)
                next_state = READY_STATE;
            else
                next_state = TXSYSCLKSEL1_STATE;

        TXSYSCLKSEL2_STATE:
            if (fail)
                next_state = READY_STATE;
            else if (done_in)
            begin
                if (txrate_diff)
                    next_state = TXRATE1_STATE;
                else
                    next_state = READY_STATE;
            end
            else
                next_state = TXSYSCLKSEL2_STATE;        

        default:
            next_state = READY_STATE;
    endcase
end

//
// FSM output logic
//
always @ (*)
begin
    clr_settle_cntr         = 1'b0;
    txrate_req              = 1'b0;
    txsysclksel_req         = 1'b0;
    pass_done               = 1'b0;
    set_freeze              = 1'b0;
    clr_freeze              = 1'b0;

    case(current_state)
        READY_STATE:
        begin
            clr_settle_cntr = 1'b1;
            pass_done = 1'b1;
            clr_freeze = 1'b1;
        end

        FREEZE_STATE:
            set_freeze = 1'b1;

        TXRATE1_STATE:
            txrate_req = 1'b1;

        TXSYSCLKSEL1_STATE:
            txsysclksel_req = 1'b1; 

        default:;
    endcase
end

assign txrate_change_req = txrate_req;
assign txsysclksel_change_req = txsysclksel_req;

endmodule
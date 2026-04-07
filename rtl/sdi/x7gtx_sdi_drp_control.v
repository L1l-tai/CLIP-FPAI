// (c) Copyright 2006 - 2014 Xilinx, Inc. All rights reserved.
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
//  /   /         Filename: $File: //Groups/video_ip/demos/K7/xapp592_k7_sdi_demos_ver2/SDI_wrapper/x7gtx_sdi_drp_control.v $
// /___/   /\     Timestamp: $DateTime: 2014/03/13 12:31:24 $
// \   \  /  \
//  \___\/\___\
//
// Description:
//  This module connects to the DRP of the 7series GTX and modifies attributes in 
//  the GTX transceiver in response to changes on its input control signals. This 
//  module is specifically designed to support triple-rate SDI interfaces 
//  implemented in the 7series GTX. It changes the RXCDR_CFG attribute when the 
//  rx_mode input changes. The module also controls the rxrate and rxcdrhold
//  ports of the GTX.
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

module x7gtx_sdi_drp_control 
#(
    parameter RXCDR_CFG_HD      = 72'h03800023ff20100020,   // HD-SDI CDR setting
    parameter RXCDR_CFG_3G      = 72'h03800023ff20200020,   // 3G-SDI CDR setting
    parameter DRP_TIMEOUT_MSB   = 9,                        // MSB of DRP timeout counter
    parameter RETRY_CNTR_MSB    = 8)                        // MSB of retry counter
(
    input   wire        drpclk,                 // DRP DCLK
    input   wire        rxusrclk,               // RXUSRCLK used for generation of rst output only
    input   wire        rst,                    // Connect to same reset that drives RST_IN of inner GTX wrapper_gt (usually RX PLLRESET)
    input   wire        init_done,              // GTX initialization is complete
    input   wire [1:0]  rx_mode,                // RX mode select
    output  wire [2:0]  rx_rate,                // Drives GTX RXRATE port
    output  reg         drpbusy_out = 1'b0,     // 1 indicates DRP cycle in progress
    input   wire        drprdy,                 // GTX DRPRDY
    output  reg  [8:0]  drpaddr   = 9'b0,       // GTX DRPADDR
    output  reg  [15:0] drpdi     = 16'b0,      // GTX DRPDI
    output  reg         drpen     = 1'b0,       // GTX DRPEN
    output  reg         drpwe     = 1'b0,       // GTX DRPWE
    output  reg         done      = 1'b0,       // 1 = sequence completed
    output  reg         fail      = 1'b0,       // 1 = sequence failure
    output  reg  [2:0]  fail_code = 3'b000,     // sequence failure code
    output  reg         rxcdrhold = 1'b0,       // GTX RXCDRHOLD
    output  reg         gtrxreset = 1'b0,       // GTRXRESET request
    output  reg         full_reset = 1'b0       // GTX full reset request
);
             
localparam RXCDR_CFG_DRPADDR = 9'h0A8;

//
// This group of constants defines the states of the master state machine.
// 
localparam MSTR_STATE_WIDTH = 4;
localparam MSTR_STATE_MSB   = MSTR_STATE_WIDTH - 1;

localparam [MSTR_STATE_MSB:0]
    MSTR_IDLE           = 4'b0000,
    MSTR_CHECK          = 4'b0001,
    MSTR_WRITE          = 4'b0010, 
    MSTR_WAIT           = 4'b0011,
    MSTR_NEXT           = 4'b0100,
    MSTR_DRP_ERR        = 4'b0101,
    MSTR_RATE           = 4'b0110,
    MSTR_FAIL           = 4'b0111,
    MSTR_DO_RESET       = 4'b1000,
    MSTR_DO_RESET_TO    = 4'b1001;

//
// This group of parameters defines the states of the DRP state machine.
//
localparam DRP_STATE_WIDTH = 3;
localparam DRP_STATE_MSB = DRP_STATE_WIDTH - 1;

localparam [DRP_STATE_MSB:0]
    DRP_START       = 3'b000,
    DRP_WRITE       = 3'b001,
    DRP_WAIT        = 3'b010,
    DRP_DONE        = 3'b101,
    DRP_TO          = 3'b100;

//
// These parameters define the encoding of the rxrate port
//
localparam RATE_DIV_1 = 3'b001;
localparam RATE_DIV_2 = 3'b010;
localparam RATE_DIV_4 = 3'b011;

//
// Local signal declarations
//
reg  [1:0]              rx_mode_in_reg = 2'b00;
reg  [1:0]              rx_mode_sync1_reg = 2'b00;
reg  [1:0]              rx_mode_sync2_reg = 2'b00;
reg  [1:0]              rx_mode_last_reg = 2'b00;
reg                     rx_change_req = 1'b1;
reg                     clr_rx_change_req;
reg  [2:0]              rx_rate_int = RATE_DIV_4;
reg                     rx_rate_changed = 1'b0;

reg  [MSTR_STATE_MSB:0] mstr_current_state = MSTR_IDLE;     // master FSM current state
reg  [MSTR_STATE_MSB:0] mstr_next_state;                    // master FSM next state
reg  [DRP_STATE_MSB:0]  drp_current_state = DRP_START;      // DRP FSM current state
reg  [DRP_STATE_MSB:0]  drp_next_state;                     // DRP FSM next state

reg                     drp_go;                             // Go signal from master FSM to DRP FSM
reg                     drp_done;                           // Done signal from DRP FSM to master FSM
reg                     drp_err;

reg  [2:0]              cycle = 3'b000;                     // cycle counter
reg                     clr_cycle;
reg                     inc_cycle;
wire                    complete;

reg  [8:0]              drp_addr;
reg  [15:0]             drp_data;
reg  [82:0]             rxcdr_cfg = RXCDR_CFG_HD;

reg [DRP_TIMEOUT_MSB:0] to_counter = 0;
reg                     m_clr_to;
reg                     clr_to;
wire                    timeout;
reg                     do_gt_reset;
reg                     do_ld_rxrate;
reg                     do_full_reset;
reg                     clr_retries;
reg                     inc_retries;
reg  [RETRY_CNTR_MSB:0] retry_counter;
reg                     clr_drpbusy_out;
reg                     assert_drpbusy_out;
reg                     clr_fail;
reg                     assert_fail;
wire                    max_retries;
reg                     set_fail_code_5;
reg                     set_fail_code_7;
reg                     set_done;
reg                     clr_done;

//------------------------------------------------------------------------------
// rx_mode change logic
//
// Synchronize the rx_mode signal to the clock
always @ (posedge drpclk)
begin
    rx_mode_in_reg <= rx_mode;
    rx_mode_sync1_reg <= rx_mode_in_reg;
    rx_mode_sync2_reg <= rx_mode_sync1_reg;
    rx_mode_last_reg <= rx_mode_sync2_reg;
end

//
// Detect a change in rx_mode
//
always @ (posedge drpclk)
    if (rst)
        rx_change_req <= 1'b1;
    else if (clr_rx_change_req)
        rx_change_req <= 1'b0;
    else if (rx_mode_sync2_reg != rx_mode_last_reg)
        rx_change_req <= 1'b1;

//
// If the rx_mode change is into or out of HD-SDI, then rxrate and the RXCDR_CFG
// attribute will also need to be changed. Signal this to the FSM using the
// rx_rate_changed signal.
//
always @ (posedge drpclk)
    if (rst)
        rx_rate_changed <= 1'b0;
    else if (rx_mode_sync2_reg != rx_mode_last_reg)
    begin
        if ((rx_mode_last_reg == 2'b00 && rx_mode_sync2_reg != 2'b00) || 
            (rx_mode_sync2_reg == 2'b00 && rx_mode_last_reg != 2'b00))
            rx_rate_changed <= 1'b1;
        else
            rx_rate_changed <= 1'b0;
    end
//
// Assert rxcdrhold if rx_mode changes to SD-SDI mode
//
always @ (posedge drpclk)
    if (do_ld_rxrate)
        rxcdrhold <= (rx_mode_sync1_reg == 2'b01);
        
//
// Create values used for the new RXCDR_CFG data word
//
always @ *
    case(rx_mode_sync1_reg)
        2'b10:   rxcdr_cfg = RXCDR_CFG_3G;
        default: rxcdr_cfg = RXCDR_CFG_HD;
    endcase

//
// RXRATE output
//
always @ (posedge drpclk or posedge rst)
    if (rst)
        rx_rate_int <= RATE_DIV_4;
    else if (do_ld_rxrate)    
        case(rx_mode_sync1_reg)
            2'b01:   rx_rate_int <= RATE_DIV_2; // SD-SDI RXOUT_DIV = /2
            2'b10:   rx_rate_int <= RATE_DIV_2; // 3G-SDI RXOUT_DIV = /2
            2'b11:   rx_rate_int <= RATE_DIV_1; // 6G-SDI RXOUT_DIV = /1
            default: rx_rate_int <= RATE_DIV_4; // HD-SDI RXOUT_DIV = /4
        endcase

assign rx_rate = rx_rate_int;

//------------------------------------------------------------------------------        
// Master state machine
//
// The master FSM examines the rx_change_req register and then initiates multiple
// DRP write cycles to modify the RXCDR_CFG attribute.
//
// The actual DRP write cycles are handled by a separate FSM, the DRP FSM. The
// master FSM provides a DRP address and new data word to the DRP FSM and 
// asserts a drp_go signal. The DRP FSM does the actual write cycle and responds
// with a drp_done signal when the cycle is complete.
//

//
// Current state register
// 
always @ (posedge drpclk)
    if (rst)
        mstr_current_state <= MSTR_IDLE;
    else
        mstr_current_state <= mstr_next_state;

//
// Next state logic
//
always @ (*)
begin
    case(mstr_current_state)
        MSTR_IDLE:
            if (init_done & rx_change_req)
                mstr_next_state = MSTR_CHECK;
            else
                mstr_next_state = MSTR_IDLE;

        MSTR_CHECK:
            if (rx_rate_changed)
                mstr_next_state = MSTR_WRITE;
            else
                mstr_next_state = MSTR_RATE;

        MSTR_WRITE:
            mstr_next_state = MSTR_WAIT;

        MSTR_WAIT:
            if (drp_done)
                mstr_next_state = MSTR_NEXT;
            else if (drp_err)
                mstr_next_state = MSTR_DRP_ERR;
            else
                mstr_next_state = MSTR_WAIT;

        MSTR_NEXT:
            if (complete)
                mstr_next_state = MSTR_RATE;
            else
                mstr_next_state = MSTR_WRITE;

        MSTR_RATE:
            mstr_next_state = MSTR_DO_RESET;

        MSTR_DRP_ERR:
            if (max_retries)
                mstr_next_state = MSTR_FAIL;
            else
                mstr_next_state = MSTR_WRITE;

        MSTR_DO_RESET:
            if (~init_done)
                mstr_next_state = MSTR_IDLE;
            else if (timeout)
                mstr_next_state = MSTR_DO_RESET_TO;
            else
                mstr_next_state = MSTR_DO_RESET;

        MSTR_DO_RESET_TO:
            if (max_retries)
                mstr_next_state = MSTR_FAIL;
            else
                mstr_next_state = MSTR_DO_RESET;

        MSTR_FAIL:
            if (init_done)
                mstr_next_state = MSTR_FAIL;
            else
                mstr_next_state = MSTR_IDLE;

        default:
            mstr_next_state = MSTR_FAIL;
    endcase
end

//
// Output logic
//
always @ (*)
begin
    clr_cycle = 1'b0;
    inc_cycle = 1'b0;
    clr_rx_change_req = 1'b0;
    drp_go = 1'b0;
    do_gt_reset = 1'b0;
    do_ld_rxrate = 1'b0;
    do_full_reset = 1'b0;
    m_clr_to = 1'b0;
    clr_retries = 1'b0;
    clr_drpbusy_out = 1'b0;
    clr_fail = 1'b0;
    assert_drpbusy_out = 1'b0;
    inc_retries = 1'b0;
    assert_fail = 1'b0;
    set_fail_code_5 = 1'b0;
    set_fail_code_7 = 1'b0;
    set_done = 1'b0;
    clr_done = 1'b0;

    case(mstr_current_state)
        MSTR_IDLE:
        begin
            clr_cycle = 1'b1;
            clr_fail = 1'b1;
            clr_drpbusy_out = 1'b1;
            m_clr_to = 1'b1;
            clr_retries = 1'b1;
            set_done = 1'b1;
        end

        MSTR_CHECK:
            clr_done = 1'b1;

        MSTR_WRITE:
        begin
            assert_drpbusy_out = 1'b1;
            drp_go = 1'b1;
        end

        MSTR_DRP_ERR:   
        begin
            inc_retries = 1'b1;
            m_clr_to = 1'b1;
            if (max_retries)
                set_fail_code_5 = 1'b1;
        end

        MSTR_NEXT:
            inc_cycle = 1'b1;

        MSTR_RATE:
        begin
            do_ld_rxrate = 1'b1;
            clr_rx_change_req = 1'b1;
            m_clr_to = 1'b1;
            clr_retries = 1'b1;
        end

        MSTR_DO_RESET:
        begin
            clr_drpbusy_out = 1'b1;
            do_gt_reset = 1'b1;
            clr_rx_change_req = 1'b1;
        end

        MSTR_DO_RESET_TO:
        begin
            inc_retries = 1'b1;
            m_clr_to = 1'b1;
            if (max_retries)
                set_fail_code_7 = 1'b1;
        end

        MSTR_FAIL:
        begin
            clr_drpbusy_out = 1'b1;
            do_full_reset = 1'b1;
            assert_fail = 1'b1;
        end

        default:;
    endcase
end

always @ (posedge drpclk)
    if (rst)
        gtrxreset <= 1'b0;
    else 
        gtrxreset <= do_gt_reset;
        
always @ (posedge drpclk)
    if (rst)
        full_reset <= 1'b0;
    else
        full_reset <= do_full_reset;

always @ (posedge drpclk)
    if (rst | clr_drpbusy_out)
        drpbusy_out <= 1'b0;
    else if (assert_drpbusy_out)
        drpbusy_out <= 1'b1;

always @ (posedge drpclk)
    if (rst | clr_fail)
        fail <= 1'b0;
    else if (assert_fail)
        fail <= 1'b1;

always @ (posedge drpclk)
    if (rst | clr_retries)
        retry_counter <= 0;
    else if (inc_retries)
        retry_counter <= retry_counter + 1;

assign max_retries = &retry_counter;

always @ (posedge drpclk)
    if (rst | clr_done)
        done <= 1'b0;
    else if (set_done)
        done <= 1'b1;
        
always @ (posedge drpclk)
    if (set_fail_code_5)
        fail_code <= 3'b101;
    else if (set_fail_code_7)
        fail_code <= 3'b111;
    else
        fail_code <= fail_code;

//
// This logic creates the correct DRP address and data values used when changing
// RXCDR_CFG.
//
always @ (*)
    case(cycle)
        3'b000:  
            begin
                drp_data = rxcdr_cfg[15:0];
                drp_addr = RXCDR_CFG_DRPADDR;
            end
        3'b001:
            begin  
                drp_data = rxcdr_cfg[31:16];
                drp_addr = RXCDR_CFG_DRPADDR + 1;
            end
        3'b010:  
            begin
                drp_data = rxcdr_cfg[47:32];
                drp_addr = RXCDR_CFG_DRPADDR + 2;
            end
        3'b011:
            begin  
                drp_data = rxcdr_cfg[63:48];
                drp_addr = RXCDR_CFG_DRPADDR + 3;
            end
        default: 
            begin
                drp_data = {8'b0, rxcdr_cfg[71:64]};
                drp_addr = RXCDR_CFG_DRPADDR + 4;
            end
    endcase

//
// cycle counter
//
// This counts the number of write cycles that have been executed to update the
// RXCDR_CFG attribute through the DRP. It takes 6 write cycles to consecutive
// DRP addresses to update the RXCDR_CFG value.
//
always @ (posedge drpclk)
    if (clr_cycle)
        cycle <= 0;
    else if (inc_cycle)
        cycle <= cycle + 1;

assign complete = cycle == 3'b100;

//------------------------------------------------------------------------------
// DRP state machine
//
// The DRP state machine performs the write cycle to the DRP at the request of
// the master FSM.
//
// A timeout timer is used to timeout a DRP access should the DRP fail to
// respond with a DRDY signal within a given amount of time controlled by the
// DRP_TIMEOUT_MSB parameter.
//

//
// Current state register
//
always @ (posedge drpclk)
    if (rst)
        drp_current_state <= DRP_START;
    else
        drp_current_state <= drp_next_state;

//
// Next state logic
//
always @ *
    case(drp_current_state)
        DRP_START:
            if (drp_go)
                drp_next_state = DRP_WRITE;
            else
                drp_next_state = DRP_START;

        DRP_WRITE:
            drp_next_state = DRP_WAIT;

        DRP_WAIT:
            if (drprdy)
                drp_next_state = DRP_DONE;
            else if (timeout)
                drp_next_state = DRP_TO;
            else
                drp_next_state = DRP_WAIT;

        DRP_DONE:
            drp_next_state = DRP_START;

        DRP_TO:
            drp_next_state = DRP_START;

        default: 
            drp_next_state = DRP_START;
    endcase

always @ (posedge drpclk)
    begin
        drpdi <= drp_data;
        drpaddr <= drp_addr;
    end

//
// Output logic
//
always @ *
begin
    drpen = 1'b0;
    drpwe = 1'b0;
    drp_done = 1'b0;
    drp_err = 1'b0;
    clr_to = 1'b0;
    
    case(drp_current_state)
        DRP_START:
            clr_to = 1'b1;

        DRP_WRITE:
            begin
                drpen = 1'b1;
                drpwe = 1'b1;
                clr_to = 1'b1;
            end

        DRP_DONE:
            drp_done = 1'b1;

        DRP_TO:
            drp_err = 1'b1;

        default:;
    endcase
end

//
// A timeout counter for DRP accesses. If the timeout counter reaches its
// terminal count, the DRP state machine aborts the transfer.
//
always @ (posedge drpclk)
    if (m_clr_to | clr_to)
        to_counter <= 0;
    else if (~timeout)
        to_counter <= to_counter + 1;

assign timeout = to_counter[DRP_TIMEOUT_MSB];

endmodule
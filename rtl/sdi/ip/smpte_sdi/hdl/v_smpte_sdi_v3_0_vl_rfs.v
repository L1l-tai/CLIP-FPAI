// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/* 
This module checks the parity bits and checksums of all ANC packets (except EDH
packets) on the video stream.. If any errors are detected in ANC packets during
a field, the module will assert the anc_edh_local signal. This signal is used 
by the edh_gen module to assert the edh flag in the ANC flag set of the next 
EDH packet it generates. The anc_edh_local signal remains asserted until the
EDH packet has been sent (as indicated the edh_packet input being asserted then
negated).

The module will not do any checking after reset until the video decoder's locked
signal is asserted for the first time.
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_anc_rx (
    input  wire         clk,                    // clock input
    input  wire         ce,                     // clock enable
    input  wire         rst,                    // sync reset input
    input  wire         locked,                 // video decoder locked signal
    input  wire         rx_anc_next,            // indicates the next word is the first word of a received ANC packet
    input  wire         rx_edh_next,            // indicates the next word is the first word of a received EDH packet
    input  wire         edh_packet,             // indicates an EDH packet is being generated
    input  wire [9:0]   vid_in,                 // video data
    output reg          anc_edh_local = 1'b0    // ANC edh flag
);


//-----------------------------------------------------------------------------
// Parameter definitions
//      

//
// This group of parameters defines the states of the EDH processor state
// machine.
//
localparam STATE_WIDTH   = 4;
localparam STATE_MSB     = STATE_WIDTH - 1;

localparam [STATE_WIDTH-1:0]
    S_WAIT   = 0,
    S_ADF1   = 1,
    S_ADF2   = 2,
    S_ADF3   = 3,
    S_DID    = 4,
    S_DBN    = 5,
    S_DC     = 6,
    S_UDW    = 7,
    S_CHK    = 8,
    S_EDH1   = 9,
    S_EDH2   = 10,
    S_EDH3   = 11;

//-----------------------------------------------------------------------------
// Signal definitions
//
reg     [STATE_MSB:0]   current_state = S_WAIT; // FSM current state
reg     [STATE_MSB:0]   next_state;             // FSM next state
wire                    parity;                 // used to generate parity_err signal
wire                    parity_err;             // asserted on parity error
reg                     check_parity;           // asserted when parity should be checked
reg     [8:0]           checksum = 9'b0;        // checksum generator for ANC packet
reg                     clr_checksum;           // asserted to clear the checksum
reg                     check_checksum;         // asserted when checksum is to be tested
reg                     clr_edh_flag;           // asserted to clear the edh flag
reg                     checksum_err;           // asserted when checksum error in EDH packet is detected
reg     [7:0]           udw_cntr = 8'b0;        // user data word counter
reg                     udwcntr_eq_0;           // asserted when output of UDW in MUX is zero
wire    [7:0]           udw_mux;                // UDW counter input MUX
reg                     ld_udw_cntr;            // loads the UDW counter when asserted
reg                     enable = 1'b0;          // generated from locked input

//
// enable signal
//
// This signal enables checking of the parity and checksum. It is negated on
// reset and remains negated until locked is asserted for the first time.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            enable <= 1'b0;
        else if (locked)
            enable <= 1'b1;
    end
                           
//
// FSM: current_state register
//
// This code implements the current state register. 
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            current_state <= S_WAIT;
        else
            current_state <= next_state;
    end

//
// FSM: next_state logic
//
// This case statement generates the next_state value for the FSM based on
// the current_state and the various FSM inputs.
//
always @ (*)
    case(current_state)
        S_WAIT:     if (~enable)
                        next_state = S_WAIT;
                    else if (rx_anc_next & ~rx_edh_next)
                        next_state = S_ADF1;
                    else if (edh_packet)
                        next_state = S_EDH1;
                    else
                        next_state = S_WAIT;
                
        S_ADF1:     next_state = S_ADF2;

        S_ADF2:     next_state = S_ADF3;

        S_ADF3:     next_state = S_DID;

        S_DID:      if (parity_err)
                        next_state = S_WAIT;
                    else
                        next_state = S_DBN;

        S_DBN:      if (parity_err)
                        next_state = S_WAIT;
                    else
                        next_state = S_DC;

        S_DC:       if (parity_err)
                        next_state = S_WAIT;
                    else if (udwcntr_eq_0)
                        next_state = S_CHK;
                    else
                        next_state = S_UDW;

        S_UDW:      if (udwcntr_eq_0)
                        next_state = S_CHK;
                    else
                        next_state = S_UDW;

        S_CHK:      next_state = S_WAIT;

        S_EDH1:     if (~edh_packet)
                        next_state = S_EDH1;
                    else
                        next_state = S_EDH2;

        S_EDH2:     if (edh_packet)
                        next_state = S_EDH2;
                    else
                        next_state = S_EDH3;

        S_EDH3:     next_state = S_WAIT;

        default:    next_state = S_WAIT;

    endcase
        
//
// FSM: outputs
//
// This block decodes the current state to generate the various outputs of the
// FSM.
//
always @ (*)
begin
    // Unless specifically assigned in the case statement, all FSM outputs
    // default to the values given here.
    clr_checksum    = 1'b0;
    clr_edh_flag    = 1'b0;
    check_parity    = 1'b0;
    ld_udw_cntr     = 1'b0;
    check_checksum  = 1'b0;
                            
    case(current_state)     
        S_EDH3:     clr_edh_flag = 1'b1;

        S_ADF3:     clr_checksum = 1'b1;

        S_DID:      check_parity = 1'b1;

        S_DBN:      check_parity = 1'b1;

        S_DC:       begin
                        ld_udw_cntr = 1'b1;
                        check_parity = 1'b1;
                    end

        S_CHK:      check_checksum = 1'b1;

    endcase
end

//
// parity error detection
//
// This code calculates the parity of bits 7:0 of the video word. The calculated
// parity bit is compared to bit 8 and the complement of bit 9 to determine if
// a parity error has occured. If a parity error is detected, the parity_err
// signal is asserted. Parity is only valid on the payload portion of the
// EDH packet (user data words).
//
assign parity = vid_in[7] ^ vid_in[6] ^ vid_in[5] ^ vid_in[4] ^
                vid_in[3] ^ vid_in[2] ^ vid_in[1] ^ vid_in[0];

assign parity_err = (parity ^ vid_in[8]) | (parity ^ ~vid_in[9]);


//
// checksum calculator
//
// This code generates a checksum for the EDH packet. The checksum is cleared
// to zero prior to beginning the checksum calculation by the FSM asserting the
// clr_checksum signal. The vid_in word is added to the current checksum when
// the FSM asserts the do_checksum signal. The checksum is a 9-bit value and
// is computed by summing all but the MSB of the vid_in word with the current
// checksum value and ignoring any carry bits.
//
always @ (posedge clk)
    if (ce)
        begin
            if (rst | clr_checksum)
                checksum <= 0;
            else
                checksum <= checksum + vid_in[8:0];
        end

//
// checksum tester
//
// This logic asserts the checksum_err signal if the calculated and received
// checksum are not the same.
//
always @ (*)
    if (checksum == vid_in[8:0] && checksum[8] == ~vid_in[9])
        checksum_err = 1'b0;
    else
        checksum_err = 1'b1;

//
// UDW counter, input MUX, and comparator
//
// The UDW counter is designed to count the number of user data words in the
// ANC packet so that the FSM knows when the payload portion of the ANC
// packet is over.
//
// The ld_udw_cntr signal controls a MUX. When this signal is asserted, the
// MUX outputs the vid_in data word. Otherwise, the MUX outputs the contents of
// the UDW counter. The output of the MUX is decremented by one and loaded into
// the UDW counter. The output of the MUX is also tested to see if it equals
// zero and the udwcntr_eq_0 signal is asserted if so.
//
assign udw_mux = ld_udw_cntr ? vid_in[7:0] : udw_cntr;

always @ (*)
    if (udw_mux == 8'b00000000)
        udwcntr_eq_0 = 1'b1;
    else
        udwcntr_eq_0 = 1'b0;
        
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            udw_cntr <= 0;
        else
            udw_cntr <= udw_mux - 1;
    end
        
//
// anc_edh_local flag
//
// This flag is reset whenever an EDH packet is generated. The flag is set
// if a parity error or checksum error is detected during a field.
//
always @ (posedge clk)
    if (ce)
        begin
            if (rst | clr_edh_flag)
                anc_edh_local <= 1'b0;
            else if (parity_err & check_parity)
                anc_edh_local <= 1'b1;
            else if (checksum_err & check_checksum)
                anc_edh_local <= 1'b1;
        end
                            
endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
This module examines a digital video stream and determines which of six
supported video standards matches the video stream. The supported video 
standards are:

Video Format                            Corresponding Standards
------------------------------------------------------------------------------
NTSC 4:2:2 component video              SMPTE 125M, ITU-R BT.601, ITU-R BT.656
NTSC 4:2:2 16x9 component video         SMPTE 267M
NTSC 4:4:4 component 13.5MHz sample     SMPTE RP 174
PAL 4:2:2 component video               ITU-R BT.656
PAL 4:2:2 16x9 component video          ITU-R BT.601
PAL 4:4:4 component 13.5MHz sample      ITU-R BT.799    

The autodetect module is a finite state machine (FSM) that looks for TRS
symbols and measures the number of samples per line of video based on the
positions of the TRS symbols.

The FSM executes two main loops, the ACQUIRE loop and the LOCKED loop. In the 
ACQUIRE loop, the FSM attempts to find eight consecutive lines with the same
number of samples. Once it does this, the FSM then compares the number of
samples per video line to that of each of the six known standards. If a
a matching standard is found, the FSM sets the locked output and also outputs
a 3-bit code representing the video standard on the std output port then
it advances to the LOCKED loop.

In the LOCKED loop, the FSM continuously compares the number of samples of each
received video line to the correct number for the current video standard. If
the number of consecutive lines with the incorrect number of samples exceeds
the MAX_ERR_CNT value, then the locked output is negated and the FSM returns
to the ACQUIRE loop.

The autodetect module has the following inputs:

clk: Input clock running at the video word rate.

ce: Clock enable input.

rst: Synchronous reset input.

reacquire: Forces the autodetect unit to redetect the video format when
asserted high. This is essentially a synchronous reset to the FSM. The FSM
will not start the reacquire loop until the reacquire input goes low.

vid_in: This is the video data input port. If eight bit video is being used, the
LS 2-bits of the vid_in input port should be grounded.

rx_trs: This input must be asserted on the first word of every TRS symbol
present in the input video stream.

rx_xyz: This input must be asserted during the XYZ word of every TRS symbol
present in the input video stream.

rx_xyz_err: This input must be asserted during when the XYZ word contains an
error according to the 4:2:2 format.

rx_xyz_err_4444: This input identifies errors in XYZ words for the 4:4:4:4 
formats.

The autodetect module has the following outputs.

std: A 3-bit output port that indicates which standard has been detected. This
code is not valid unless the locked output is asserted. The std code values
are:

000:    NTSC 4:2:2 component video
001:    invalid
010:    NTSC 4:2:2 16x9 component video
011:    NTSC 4:4:4 13.5MHz component video
100:    PAL 4:2:2 component video
101:    invalid
110:    PAL 4:2:2 16x9 component video
111:    PAL 4:4:4 13.5MHz component video

locked: Asserted high when the autodetect unit is locked to the incoming video
standard.

xyz_err: This signal indicates the detection of an XYZ word error. This output
is generated by multiplexing the rx_xyz_err and rx_xyz_err_4444 inputs
together and using the detected video standard as the control for the MUX.

s4444: For the 4444 component video standards, this signal reflects the S bits
in the TRS word. The S bit is 1 for YCbCr and 0 for RGB.
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_autodetect #(
    parameter HCNT_WIDTH        = 12,   // # of bits in horizontal counter
    parameter ERRCNT_WIDTH      = 4,    // # of bits in error counter -- must be enough to count to MAX_ERR_CNT
    parameter MAX_ERR_CNT       = 8)    // Max consectuive error allowed before FSM begins to reaquire format
(
    input  wire         clk,            // clock input
    input  wire         ce,             // clock enable
    input  wire         rst,            // sync reset input
    input  wire         reacquire,      // forces state machine to reacquire when asserted
    input  wire [9:0]   vid_in,         // video data input
    input  wire         rx_trs,         // must be high on first word of TRS (0x3ff)
    input  wire         rx_xyz,         // must be high during the TRS XYZ word
    input  wire         rx_xyz_err,     // XYZ word error input, for all standards except 4444
    input  wire         rx_xyz_err_4444,// XYZ word error input, for 4444 standards
    output reg  [2:0]   vid_std = 3'b0, // video standard code
    output reg          locked = 1'b0,  // output asserted when synced to input data
    output wire         xyz_err,        // asserted when the XYZ word contains an error
    output reg          s4444 = 1'b0    // reflects the status of the S bit in 4444 format
);

//-----------------------------------------------------------------------------
// Parameter definitions
//

localparam HCNT_MSB      = HCNT_WIDTH - 1;       // MS bit # of hcnt
localparam ERRCNT_MSB    = ERRCNT_WIDTH - 1;     // MS bit # of errcnt

//
// This group of parameters defines the total number of clocks per line 
// for the various supported video standards.
//
localparam CNT_NTSC_422          = 1716;
localparam CNT_NTSC_422_WIDE     = 2288;
localparam CNT_NTSC_4444         = 3432;
localparam CNT_PAL_422           = 1728;
localparam CNT_PAL_422_WIDE      = 2304;
localparam CNT_PAL_4444          = 3456;

//
// This group of parameters defines the encoding for the video standards output
// code.
//
localparam [2:0]
    NTSC_422        = 3'b000,
    NTSC_INVALID    = 3'b001,
    NTSC_422_WIDE   = 3'b010,
    NTSC_4444       = 3'b011,
    PAL_422         = 3'b100,
    PAL_INVALID     = 3'b101,
    PAL_422_WIDE    = 3'b110,
    PAL_4444        = 3'b111;

//
// This group of parameters defines the states of the FSM.
//                                              
localparam STATE_WIDTH   = 4;
localparam STATE_MSB     = STATE_WIDTH - 1;

localparam [STATE_WIDTH-1:0]
    ACQ0 = 0,
    ACQ1 = 1,
    ACQ2 = 2,
    ACQ3 = 3,
    ACQ4 = 4,
    ACQ5 = 5,
    ACQ6 = 6,
    ACQ7 = 7,
    LCK0 = 8,
    LCK1 = 9,
    LCK2 = 10,
    LCK3 = 11,
    ERR0 = 12,
    ERR1 = 13,
    ERR2 = 14;
     
//-----------------------------------------------------------------------------
// Signal definitions
//

// counters and registers
reg     [HCNT_MSB:0]    hcnt = 1;               // horizontal counter
reg     [HCNT_MSB:0]    saved_hcnt = 0;         // saves the hcnt value of a line
reg     [STATE_MSB:0]   current_state = ACQ0;   // FSM current state
reg     [STATE_MSB:0]   next_state;             // FSM next state
reg     [2:0]           loops = 3'b0;           // iteration counter
reg     [ERRCNT_MSB:0]  errcnt = 0;             // error counter
reg     [2:0]           std = 3'b0;             // internal vid_std register
 
// FSM inputs
wire                    composite;              // 1=composite video
wire                    eav;                    // asserted when EAV received
wire                    sav;                    // asserted when SAV received
wire                    loops_eq_0;             // asserted when loops == 0
wire                    loops_eq_7;             // asserted when loops == 7
wire                    loops_eq_1;             // asserted when loops == 1
wire                    match;                  // comparator output
wire                    int_xyz_err;            // error in XYZ parity
wire                    max_errs;               // asserted when errcnt reaches max

// FSM outputs
reg                     clr_loops;              // clears loops counter
reg                     inc_loops;              // increments loops counter
reg                     clr_errcnt;             // clears the error counter
reg                     inc_errcnt;             // increments the error counter
reg                     clr_locked;             // clears the locked output
reg                     set_locked;             // sets the locked output
reg                     clr_hcnt;               // clears the hcnt counter
reg     [1:0]           match_code;             // comparator control bits
reg                     ld_std;                 // loads the video std output register
reg                     ld_saved_hcnt;          // loads the saved_hcnt register
reg                     ld_s4444;               // loads the s4444 flip-flop

// other signals
wire    [HCNT_MSB:0]    cmp_a;                  // A input to comparator
wire    [HCNT_MSB:0]    cmp_b;                  // B input to comparator
wire    [2:0]           samples_adr;            // address inputs for samples ROM
reg     [HCNT_MSB:0]    samples;                // ROM storing the sample counts for 
                                                //   various supported video standards


//
// hcnt: horizontal counter
//
// The horizontal counter increments every clock cycle to keep track of the
// current horizontal position. If clr_hcnt is asserted by the FSM, hcnt is
// reloaded with a value of 1. A value of 1 is used because of the latency
// involved in detected the TRS symbol and deciding whether to clear hcnt or
// not.
//
always @ (posedge clk)
    if (ce)
        begin
            if (rst | clr_hcnt)
                hcnt <= 1;
            else
                hcnt <= hcnt + 1;
        end

//
// saved_hcnt
//
// This register loads the current value of the hcnt counter when ld_saved_hcnt
// is asserted.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            saved_hcnt <= 0;
        else if (ld_saved_hcnt)
            saved_hcnt <= hcnt;
    end

//
// error counter
//
// This counter increments when inc_errcnt is asserted by the FSM. It clears
// when the FSM asserts clr_errcnt. When the error counter reaches the 
// MAX_ERR_CNT value, max_errs is asserted.
//
always @ (posedge clk)
    if (ce)
        begin
            if (rst | clr_errcnt)
                errcnt <= 0;
            else if (inc_errcnt)
                errcnt <= errcnt + 1;
        end

assign max_errs = (errcnt == MAX_ERR_CNT);

//
// loops
//
// This iteration counter is used by the FSM for two purposes. First, it is
// used to count the number of consecutive times that the SAV occurs at the 
// same hcnt value. Second, it is used to index through the samples ROM to 
// search for a matching video standard.
//
always @ (posedge clk)
    if (ce)
        begin
            if (rst | clr_loops)
                loops <= 0;
            else if (inc_loops)
                loops <= loops + 1;
        end

//
// std
//
// This register holds the code representing the video standard found by the
// FSM. If the FSM asserted ld_std, the register loads the current value of the
// loops iteration counter.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            std <= NTSC_422;
        else if (ld_std)
            std <= loops;
    end

//-----------------------------------------------------------------------------
// FSM
//
// The finite state machine is implemented in three processes, one for the
// current_state register, one to generate the next_state value, and the
// third to decode the current_state to generate the outputs.
 
//
// FSM: current_state register
//
// This code implements the current state register. It loads with the ACQ0
// state on reset and the next_state value with each rising clock edge.
//
always @ (posedge clk)
    if (ce)
        begin
            if (rst | reacquire)
                current_state <= ACQ0;
            else
                current_state <= next_state;
        end

//
// FSM: next_state logic
//
// This case statement generates the next_state value for the FSM based on
// the current_state and the various FSM inputs.
//
always @ (*)
    case(current_state)
        ACQ0:   next_state = ACQ1;

        ACQ1:   if (rx_trs)
                    next_state = ACQ2;
                else
                    next_state = ACQ1;

        ACQ2:   if (eav | (sav & composite))
                    next_state = ACQ1;
                else if (~sav)
                    next_state = ACQ2;
                else
                    begin
                        if (loops_eq_0)
                            next_state = ACQ3;
                        else if (loops_eq_1)
                            next_state = ACQ4;
                        else if (loops_eq_7)
                            next_state = ACQ5;
                        else
                            next_state = ACQ7;
                    end                     
                        
        ACQ3:   next_state = ACQ1;

        ACQ4:   next_state = ACQ1;

        ACQ5:   if (match)
                    next_state = ACQ6;
                else
                    next_state = ACQ0;

        ACQ6:   if (match)
                    next_state = LCK0;
                else if (loops_eq_7)
                    next_state = ACQ0;
                else
                    next_state = ACQ6;

        ACQ7:   if (match)
                    next_state = ACQ1;
                else
                    next_state = ACQ0;

        LCK0:   if (rx_trs)
                    next_state = LCK1;
                else
                    next_state = LCK0;

        LCK1:   if (eav)
                    next_state = LCK0;
                else if (sav & int_xyz_err)
                    next_state = ERR0;
                else if (sav & ~int_xyz_err)
                    next_state = LCK2;
                else
                    next_state = LCK1;

        LCK2:   if (match)
                    next_state = LCK3;
                else
                    next_state = ERR1;

        LCK3:   next_state = LCK0;
                
        ERR0:   next_state = ERR1;

        ERR1:   next_state = ERR2;

        ERR2:   if (max_errs)
                    next_state = ACQ0;
                else
                    next_state = LCK0;

        default: next_state = ACQ0;
    endcase

        
//
// FSM: outputs
//
// This block decodes the current state to generate the various outputs of the
// FSM.
//
always @ (*)
begin
    // Unless specifically assigned in the case statement, all FSM outputs
    // are low.
    clr_loops     = 1'b0;
    inc_loops     = 1'b0;
    clr_errcnt    = 1'b0;
    inc_errcnt    = 1'b0;
    clr_locked    = 1'b0;
    set_locked    = 1'b0;
    clr_hcnt      = 1'b0;
    ld_saved_hcnt = 1'b0;
    match_code    = 2'b00;
    ld_std        = 1'b0;
    ld_s4444      = 1'b0;
            
    case(current_state)     
        ACQ0:   begin
                    clr_locked = 1'b1;
                    clr_errcnt = 1'b1;
                    clr_loops = 1'b1;
                end

        ACQ2:   if (rx_xyz)
                    ld_s4444 = 1'b1;
                else
                    ld_s4444 = 1'b0;

        ACQ3:   begin
                    inc_loops = 1'b1;
                    clr_hcnt = 1'b1;
                end

        ACQ4:   begin
                    ld_saved_hcnt = 1'b1;
                    clr_hcnt = 1'b1;
                    inc_loops = 1'b1;
                end

        ACQ5:   begin
                    match_code = 2'b00;
                    inc_loops = 1'b1;
                    clr_hcnt = 1'b1;
                end

        ACQ6:   begin
                    inc_loops = 1'b1;
                    ld_std = 1'b1;
                    match_code = 2'b01;
                end

        ACQ7:   begin
                    match_code = 2'b00;
                    clr_hcnt = 1'b1;
                    inc_loops = 1'b1;
                end

        LCK0:   set_locked = 1'b1;

        LCK1:   if (rx_xyz & (std == PAL_4444 || std == NTSC_4444))
                    ld_s4444 = 1'b1;
                else
                    ld_s4444 = 1'b0;

        LCK2:   begin
                    match_code = 2'b10;
                    clr_hcnt = 1'b1;
                end

        LCK3:   clr_errcnt = 1'b1;

        ERR0:   clr_hcnt = 1'b1;

        ERR1:   inc_errcnt = 1'b1;
    endcase
end

//
// locked flip-flop
//
// The locked signal is generated by the FSM to indicate when it is properly
// synchronized with the incoming video stream. This flip-flop is set when the
// set_locked signal is asserted by the FSM and cleared when the clr_locked
// signal is asserted by the FSM.
//
always @ (posedge clk)
    if (ce)
        begin
            if (rst | clr_locked)
                locked <= 1'b0;
            else if (set_locked)
                locked <= 1'b1;
        end

//
// These statements generate the composite, eav, sav, and int_xyz_err sigals.
//
assign composite = ~vid_in[9];
assign eav = vid_in[6] & rx_xyz;
assign sav = ~vid_in[6] & rx_xyz;
assign int_xyz_err = (std == NTSC_4444 || std == PAL_4444) ? 
                      rx_xyz_err_4444 : rx_xyz_err;

//
// These statements decode the loops interation counter.
//
assign loops_eq_0 = (loops == 3'b000);
assign loops_eq_1 = (loops == 3'b001);
assign loops_eq_7 = (loops == 3'b111);

//
// This is the samples ROM. It contains the total number of samples on a video
// line for each of the eight supported video standards.
//
always @ (*)
    case(samples_adr)
        NTSC_422:       samples = CNT_NTSC_422;
        NTSC_422_WIDE:  samples = CNT_NTSC_422_WIDE;
        NTSC_4444:      samples = CNT_NTSC_4444;
        PAL_422:        samples = CNT_PAL_422;
        PAL_422_WIDE:   samples = CNT_PAL_422_WIDE;
        PAL_4444:       samples = CNT_PAL_4444;
    default:            samples = 0;
endcase

//
// This code implements a MUX to generate the address into the samples counter.
// This address can come from either the loops counter or the std register
// depending on the MSB of the match_code from the FSM.
//
assign samples_adr = match_code[1] ? std : loops;

//
// This code implements the comparator that generates the match input to the
// FSM. It can compare hcnt to saved_hcnt, hcnt to the output of the samples
// ROM, or saved_hcnt to the output of the samples ROM depending the match_code
// value.
//
assign cmp_a = match_code[0] ? samples : hcnt;
assign cmp_b = match_code[1] ? samples : saved_hcnt;
assign match = cmp_a == cmp_b;

 
//
// Output register for s4444 signal
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            s4444 <= 1'b1;
        else if (ld_s4444 & ~int_xyz_err)
            s4444 <= vid_in[5];
    end

//
// vid_std output register
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            vid_std <= 3'b000;
        else if (set_locked)
            vid_std <= std;
    end

assign xyz_err = int_xyz_err;

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/* 
This module calculates the active picture and full-frame CRC values. The ITU-R
BT.1304 and SMPTE RP 165-1994 standards define how the two CRC values are to be
calculated.

The module uses the vertical line count (vcnt) input, the field bit (f), the
horizontal blanking interval bit (h), and the eav_next, sav_next, and xyz_word
inputs to determine which samples to include in the two CRC calculations.

The calculation is a standard CRC16 calculation with a polynomial of x^16 + x^12
+ x^5 + 1. The function considers the LSB of the video data as the first bit
shifted into the CRC generator, although the implementation given here is a
fully parallel CRC, calculating all 16 CRC bits from the 10-bit video data in
one clock cycle.  The CRC calculation is done is the edh_crc16 module. It is 
instanced twice, once for the full-frame calculation and once for the active-
picture calculation.    

For each CRC calculation, a valid bit is also generated. After reset the valid
bits will be negated until the locked input from the video decoder is asserted.
The valid bits remain asserted even if locked is negated. However, the valid
bits will be negated for one filed if the locked signal rises during a CRC
calculation, indicating that the video decoder has re-synchronized.
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_edh_crc #(
    parameter VCNT_WIDTH    = 10)
(
    input  wire                     clk,            // clock input
    input  wire                     ce,             // clock enable
    input  wire                     rst,            // sync reset input
    input  wire                     f,              // field bit
    input  wire                     h,              // horizontal blanking bit
    input  wire                     eav_next,       // asserted when next sample begins EAV symbol
    input  wire                     xyz_word,       // asserted when current word is the XYZ word of a TRS
    input  wire [9:0]               vid_in,         // video data
    input  wire [VCNT_WIDTH-1:0]    vcnt,           // vertical line count
    input  wire [2:0]               std,            // indicates the video standard
    input  wire                     locked,         // asserted when flywheel is locked
    output wire [15:0]              ap_crc,         // calculated active picture CRC
    output wire                     ap_crc_valid,   // asserted when CRC is valid
    output wire [15:0]              ff_crc,         // calculated full-frame CRC
    output wire                     ff_crc_valid    // asserted when CRC is valid
);


//-----------------------------------------------------------------------------
// Parameter definitions
//
localparam VCNT_MSB      = VCNT_WIDTH - 1;       // MS bit # of vcnt

//
// This group of parameters defines the encoding for the video standards output
// code.
//
localparam [2:0]
    NTSC_422        = 3'b000,
    NTSC_INVALID    = 3'b001,
    NTSC_422_WIDE   = 3'b010,
    NTSC_4444       = 3'b011,
    PAL_422         = 3'b100,
    PAL_INVALID     = 3'b101,
    PAL_422_WIDE    = 3'b110,
    PAL_4444        = 3'b111;

//
// This group of parameters defines the line numbers that begin and end the
// two CRC intervals. Values are given for both fields and for both NTSC and
// PAL.
//
localparam NTSC_FLD1_AP_FIRST    =  21;
localparam NTSC_FLD1_AP_LAST     = 262;
localparam NTSC_FLD1_FF_FIRST    =  12;
localparam NTSC_FLD1_FF_LAST     = 271;
    
localparam NTSC_FLD2_AP_FIRST    = 284;
localparam NTSC_FLD2_AP_LAST     = 525;
localparam NTSC_FLD2_FF_FIRST    = 275;
localparam NTSC_FLD2_FF_LAST     =   8;

localparam PAL_FLD1_AP_FIRST     =  24;
localparam PAL_FLD1_AP_LAST      = 310;
localparam PAL_FLD1_FF_FIRST     =   8;
localparam PAL_FLD1_FF_LAST      = 317;

localparam PAL_FLD2_AP_FIRST     = 336;
localparam PAL_FLD2_AP_LAST      = 622;
localparam PAL_FLD2_FF_FIRST     = 321;
localparam PAL_FLD2_FF_LAST      =   4;
    
//-----------------------------------------------------------------------------
// Signal defintions
//
wire                    ntsc;                   // 1 = NTSC, 0 = PAL
reg     [15:0]          ap_crc_reg = 16'b0;     // active picture CRC register
reg     [15:0]          ff_crc_reg = 16'b0;     // full field cRC register
wire    [15:0]          ap_crc16;               // active picture CRC calc output
wire    [15:0]          ff_crc16;               // full field CRC calc output
reg                     ap_region = 1'b0;       // asserted during active picture CRC interval
reg                     ff_region = 1'b0;       // asserted during full field CRC interval
reg     [VCNT_MSB:0]    ap_start_line;          // active picture interval start line
reg     [VCNT_MSB:0]    ap_end_line;            // active picture interval end line
reg     [VCNT_MSB:0]    ff_start_line;          // full field interval start line
reg     [VCNT_MSB:0]    ff_end_line;            // full field interval end line
wire                    ap_start;               // result of comparing ap_start_line with vcnt
wire                    ap_end;                 // result of comparing ap_end_line with vcnt
wire                    ff_start;               // result of comparing ff_start_line with vcnt
wire                    ff_end;                 // result of comparing ff_end_line with vcnt
wire                    sav;                    // asserted during XYZ word of SAV symbol
wire                    eav;                    // asserted during XYZ word of EAV symbol
wire                    ap_crc_clr;             // clears the active picture CRC register
wire                    ff_crc_clr;             // clears the full field CRC register
reg     [9:0]           clipped_vid;            // output of video clipper function
reg                     ap_valid = 1'b0;        // ap_crc_valid internal signal
reg                     ff_valid = 1'b0;        // ff_crc_valid internal signal
reg                     prev_locked = 1'b0;     // locked input signal delayed once clock
wire                    locked_rise;            // asserted on rising edge of locked

//
// video clipper
//
// The SMPTE and ITU specifications require that the video data values used
// by the CRC calculation have the 2 LSBs both be ones if the 8 MSBs are all
// ones.
//
always @ (*)
    begin
        clipped_vid[9:2] = vid_in[9:2];
        if (&vid_in[9:2])
            clipped_vid[1:0] = 2'b11;
        else
            clipped_vid[1:0] = vid_in[1:0];
    end

//
// decoding
//
// These assignments generate the ntsc, eav, and sav signals.
//
assign ntsc = (std == NTSC_422) || (std == NTSC_INVALID) ||
              (std == NTSC_422_WIDE) || (std == NTSC_4444);
assign sav = ~vid_in[6] & xyz_word;
assign eav = vid_in[6] & xyz_word;

//
// ap_region and ff_region generation
// 
// This code determines when the current video signal is within the active
// picture and full field CRC regions. Note that since the F bit changes before
// the end of the EDH full-field time period, the ff_end_line value is set
// to the opposite field value in the assignments below. That is, if F is low,
// normally indicating Field 1, the ff_end_line is assigned to xxx_FLD2_FF_LAST,
// not xxx_FLD1_FF_LAST as might be expected.
//

// This section looks up the starting and ending line numbers of the two CRC
// regions based on the current field and video standard.
always @ (*)
    if (ntsc)
        begin
            if (~f)
                begin
                    ap_start_line = NTSC_FLD1_AP_FIRST;
                    ap_end_line =   NTSC_FLD1_AP_LAST;
                    ff_start_line = NTSC_FLD1_FF_FIRST;
                    ff_end_line =   NTSC_FLD2_FF_LAST;
                end
            else
                begin
                    ap_start_line = NTSC_FLD2_AP_FIRST;
                    ap_end_line =   NTSC_FLD2_AP_LAST;
                    ff_start_line = NTSC_FLD2_FF_FIRST;
                    ff_end_line =   NTSC_FLD1_FF_LAST;
                end
        end
    else
        begin
            if (~f)
                begin
                    ap_start_line = PAL_FLD1_AP_FIRST;
                    ap_end_line =   PAL_FLD1_AP_LAST;
                    ff_start_line = PAL_FLD1_FF_FIRST;
                    ff_end_line =   PAL_FLD2_FF_LAST;
                end
            else
                begin
                    ap_start_line = PAL_FLD2_AP_FIRST;
                    ap_end_line =   PAL_FLD2_AP_LAST;
                    ff_start_line = PAL_FLD2_FF_FIRST;
                    ff_end_line =   PAL_FLD1_FF_LAST;
                end
        end

// These four statements compare the current vcnt value to the starting and
// ending line numbers of the two CRC regions.          
assign ap_start = vcnt == ap_start_line;
assign ap_end =   vcnt == ap_end_line;
assign ff_start = vcnt == ff_start_line;
assign ff_end =   vcnt == ff_end_line;

// This code block generates the ap_region signal indicating when the current
// position is in the active-picture CRC region.
assign ap_crc_clr = ap_start & xyz_word & sav;

always @ (posedge clk)
    if (ce)
        begin
            if (rst)
                ap_region <= 1'b0;
            else if (ap_crc_clr)
                ap_region <= 1'b1;
            else if (ap_end & eav_next)
                ap_region <= 1'b0;
        end


// This code block generates teh ff_region signal indicating when the current
// position is in the full-field CRC region.
assign ff_crc_clr = ff_start & xyz_word & eav;

always @ (posedge clk)
    if (ce)
        begin
            if (rst)
                ff_region <= 1'b0;
            else if (ff_crc_clr)
                ff_region <= 1'b1;
            else if (ff_end & eav_next)
                ff_region <= 1'b0;
        end

//
// Valid bit generation
//
// This code generates the two CRC valid bits.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            prev_locked <= 1'b0;
        else
            prev_locked <= locked;
    end

assign locked_rise = ~prev_locked & locked;

always @ (posedge clk)
    if (ce)
        begin
            if (rst | locked_rise)
                ap_valid <= 1'b0;
            else if (locked & ap_crc_clr)
                ap_valid <= 1'b1;
        end

always @ (posedge clk)
    if (ce)
        begin
            if (rst | locked_rise)
                ff_valid <= 1'b0;
            else if (locked & ff_crc_clr)
                ff_valid <= 1'b1;
        end

//
// CRC calculations and registers
//
// Each CRC is calculated separately by an edh_crc16 module. Associted with
// each is a register. The register acts as an accumulation register and is
// fed back into the edh_crc16 module to be combined with the next video
// word. Enable logic for the registers determines which words are accumulated
// into the CRC value by controlling the load enables to the two registers.
//

// Active-picture CRC calculator
v_smpte_sdi_v3_0_8_edh_crc16 apcrc16 (
    .c      (ap_crc_reg),
    .d      (clipped_vid),
    .crc    (ap_crc16)
);

// Active-picture CRC register
always @ (posedge clk)
    if (ce)
        begin
            if (rst | ap_crc_clr)
                ap_crc_reg <= 0;
            else if (ap_region & ~h)
                ap_crc_reg <= ap_crc16;
        end
        
// Full-field CRC calculator
v_smpte_sdi_v3_0_8_edh_crc16 ffcrc16 (
    .c      (ff_crc_reg),
    .d      (clipped_vid),
    .crc    (ff_crc16)
);

// Full-field CRC register
always @ (posedge clk)
    if (ce)
        begin
            if (rst | ff_crc_clr)
                ff_crc_reg <= 0;
            else if (ff_region)
                ff_crc_reg <= ff_crc16;
        end
        
//
// Output assignments
//
assign ap_crc = ap_crc_reg;
assign ap_crc_valid = ap_valid;
assign ff_crc = ff_crc_reg;
assign ff_crc_valid = ff_valid;
                        
endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
This module does a 16-bit CRC calculation.

The calculation is a standard CRC16 calculation with a polynomial of x^16 + x^12
+ x^5 + 1. The function considers the LSB of the video data as the first bit
shifted into the CRC generator, although the implementation given here is a
fully parallel CRC, calculating all 16 CRC bits from the 10-bit video data in
one clock cycle.  

The assignment statements have all be optimized to use 4-input XOR gates
wherever possible to fit efficiently in the Xilinx FPGA architecture.

There are two input ports: c and d. The 16-bit c port must be connected to the
CRC "accumulation" register hold the last calculated CRC value. The 10-bit d
port is connected to the video stream.

The output port, crc, must be connected to the input of CRC "accumulation"
register.
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_edh_crc16 (
    input  wire [15:0]      c,      // current CRC value
    input  wire [9:0]       d,      // input data word
    output wire [15:0]      crc     // new calculated CRC value
);

//-----------------------------------------------------------------------------
// Signal definitions
//
wire t1;  // intermediate product term used several times


assign t1 = d[4] ^ c[4] ^ d[0] ^ c[0];

assign crc[0]  = c[10] ^ crc[12];
assign crc[1]  = c[11] ^ d[0] ^ c[0] ^ crc[13];
assign crc[2]  = c[12] ^ d[1] ^ c[1] ^ crc[14];
assign crc[3]  = c[13] ^ d[2] ^ c[2] ^ crc[15];
assign crc[4]  = c[14] ^ d[3] ^ c[3];
assign crc[5]  = c[15] ^ t1;
assign crc[6]  = d[0] ^ c[0] ^ crc[11];
assign crc[7]  = d[1] ^ c[1] ^ crc[12];
assign crc[8]  = d[2] ^ c[2] ^ crc[13];
assign crc[9]  = d[3] ^ c[3] ^ crc[14];
assign crc[10] = t1 ^ crc[15];
assign crc[11] = d[5] ^ c[5] ^ d[1] ^ c[1];
assign crc[12] = d[6] ^ c[6] ^ d[2] ^ c[2];
assign crc[13] = d[7] ^ c[7] ^ d[3] ^ c[3];
assign crc[14] = d[8] ^ c[8] ^ t1;
assign crc[15] = d[9] ^ c[9] ^ crc[11];

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/* 
This module keeps a running count of the number of video fields that contain
an EDH error. By default, the counter is a 24-bit counter, but the counter
width can be modified by changing the ERROR_COUNT_WIDTH parameter.

A 16-bit wide error flag input vector, flags, allows up to sixteen different 
error flags to be monitored by the error counter. Each of the 16 error flags
has an associated flag_enable signal. If a flag_enable signal is low, the
corresponding error flag is ignored by the counter. If any enabled error flag
is asserted at the next EDH packet (edh_next asserted), the error counter is
incremented. There is no latching mechanism on the error flags -- they must
remain asserted until edh_next is asserted in order to increment the counter.

The error counter will saturate and will not roll over when it reaches the
maximum count. The counter is cleared on reset and when clr_errcnt is asserted.

A count enable input, count_en, is also provided to enable and disable the
error counter. This can be used to disable the counter when the video decoder
is not synchronized to the video stream. 
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_edh_errcnt #(
    parameter ERROR_COUNT_WIDTH = 24,
    parameter FLAGS_WIDTH       = 16)
(
    input  wire                         clk,            // clock input
    input  wire                         ce,             // clock enable
    input  wire                         rst,            // sync reset input
    input  wire                         clr_errcnt,     // clears the error counter
    input  wire                         count_en,       // enables error counter when high
    input  wire [FLAGS_WIDTH-1:0]       flag_enables,   // specifies which error flags cause the counter to increment
    input  wire [FLAGS_WIDTH-1:0]       flags,          // error flag inputs
    input  wire                         edh_next,       // counter increments on edh_next asserted
    output wire [ERROR_COUNT_WIDTH-1:0] errcnt          // error counter
);


//-----------------------------------------------------------------------------
// Parameter definitions
//

parameter ERRFLD_MSB    = ERROR_COUNT_WIDTH - 1;     // MS bit # of error counter
parameter FLAGS_MSB     = FLAGS_WIDTH - 1;      // MS bit # of error flag field
    
//-----------------------------------------------------------------------------
// Signal definitions
//
wire    [FLAGS_MSB:0]   enabled_flags;  // error flags after ANDing with enables
wire                    err_in_field;   // OR of all enabled error flags
wire                    errcnt_tc;      // asserted when errcnt reaches terminal count
wire    [ERRFLD_MSB:0]  next_count;     // current error count + 1
reg     [ERRFLD_MSB:0]  cntr = 0;       // actual error counter

//
// flag enabling logic
//
assign enabled_flags = flags & flag_enables;
assign err_in_field = |enabled_flags;

//
// error counter
//
assign next_count = cntr + 1;
assign errcnt_tc = next_count == 0;
    
always @ (posedge clk)
    if (ce)
        begin
            if (rst | clr_errcnt)
                cntr <= 0;
            else if (edh_next & ~errcnt_tc & err_in_field & count_en)
                cntr <= next_count;
        end
        
//
// output assignment
//
assign errcnt = cntr;
             
endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/* 
This module calculates new values for the EDH flags to be inserted into the
next generated EDH packet.

The flags captured from the received EDH packet are combined with the error 
flags generated by other modules and by internal EDH flags generated by
comparing the received CRC checkwords with the CRC values calculated by the
edh_crc module. 

The new flag values are calculated as the edh_gen module generates a new EDH
packet. The edh_flags module supplies the EDH flags to the edh_gen module over
a flag bus. The edh_gen module requests which set of EDH flags (ap, ff, or 
anc) is supplied over the flag bus with the ap_flag_word, ff_flag_word, and
anc_flag_word signals. The three flag sets are also captured and remain valid
on the ap_flags, ff_flags, and anc_flags output ports through the following
field.

edh flag (error detected here)

The edh flag for the ap and ff flag sets is asserted when the received and
calculated CRC values do not match. The edh flag will not be asserted if 
either CRC value is not valid or if an error was detected with the received 
EDH packet. A packet error is considered to have occurred if the EDH packet is 
missing or if the EDH packet contained a format or parity error. The checksum 
of the EDH packet is not checked soon enough to allow its consideration in 
this flag calculation.

The edh flag for the anc flag set is supplied as an input (anc_edh_local) to
this module. This normally comes from the edh_rx module and is asserted if any
ANC packet in the previous field had a parity or checksum error.

eda flag (error detected already)

The eda flag of each of the three flag sets is asserted if either the eda or 
the edh flag from the received EDH packet is asserted.

ues flag (unknown error status)

The ues flag for the ap and ff flag set is asserted if the ues flag in the
received EDH packet is asserted, if an error is detected in the EDH packet, or
if the corresponding CRC valid bit is not asserted.

The ues flag for the anc flag set is asserted if the ues flag in the anc flag
set of the received EDH packet is asserted, if an error is detected in the
received EDH packet, or if the anc_ues_local input signal is asserted.

idh flag (internal error detected here)

The idh flag for each flag set is set if the corresponding input signal
(ap_idh_local, ff_idh_local, and anc_idh_local), is asserted.

ida flag (internal error detected already)

The ida flag for each flag set is set if the either the idh or ida flags from
the received EDH packet are set.

The module has an input signal called receive_mode. If this signal is not
asserted, then the way the flags are generated is modified. The module assumes
that no EDH packets are being received by the processor (for example, if this
module is at the head end of a video chain). This input effectively disables
received packet errors from causing any of the flags to be asserted.
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_edh_flags (
    input  wire                 clk,                // clock input
    input  wire                 ce,                 // clock enable input
    input  wire                 rst,                // reset input
    input  wire                 receive_mode,       // asserted if receiver is active
    input  wire                 ap_flag_word,       // asserted to select AP flag word on flag_bus
    input  wire                 ff_flag_word,       // asserted to select FF flag word on flag_bus
    input  wire                 anc_flag_word,      // asserted to select ANC flag word on flag_bus
    input  wire                 edh_missing,        // EDH packet missing from data stream
    input  wire                 edh_parity_err,     // EDH packet parity error
    input  wire                 edh_format_err,     // EDH packet format error
    input  wire                 rx_ap_crc_valid,    // received AP CRC valid bit
    input  wire [15:0]          rx_ap_crc,          // received AP CRC
    input  wire                 rx_ff_crc_valid,    // received FF CRC valid bit
    input  wire [15:0]          rx_ff_crc,          // received FF CRC
    input  wire [4:0]           rx_ap_flags,        // received AP flags
    input  wire [4:0]           rx_ff_flags,        // received FF flags
    input  wire [4:0]           rx_anc_flags,       // received ANC flags
    input  wire                 anc_edh_local,      // local ANC EDH flag input
    input  wire                 anc_idh_local,      // local ANC IDH flag input
    input  wire                 anc_ues_local,      // local ANC UES flag input
    input  wire                 ap_idh_local,       // local AP IDH flag input
    input  wire                 ff_idh_local,       // local FF IDH flag input
    input  wire                 calc_ap_crc_valid,  // calculated AP CRC valid bit
    input  wire [15:0]          calc_ap_crc,        // calculated AP CRC
    input  wire                 calc_ff_crc_valid,  // calculated FF CRC valid bit
    input  wire [15:0]          calc_ff_crc,        // calculated FF CRC
    output wire [4:0]           flags,              // flag output bus
    output reg  [4:0]           ap_flags = 0,       // holds AP flags from last EDH packet sent
    output reg  [4:0]           ff_flags = 0,       // holds FF flags from last EDH packet sent
    output reg  [4:0]           anc_flags           // holds ANC flags from last EDH packet sent
);


//-----------------------------------------------------------------------------
// Parameter definitions
//
// This set of parameters defines the bit positions of the five flags in each
// flag set.
//
localparam  EDH_BIT = 0;
localparam  EDA_BIT = 1;
localparam  IDH_BIT = 2;
localparam  IDA_BIT = 3;
localparam  UES_BIT = 4;

//-----------------------------------------------------------------------------
// Signal definitions
//
wire        ap_edh;     // internally generated ap_edh flag
wire        ap_ues;     // internally generated ap_ues flag
wire        ff_edh;     // internally generated ff_edh flag
wire        ff_ues;     // internally generated ff_uew flag
wire        packet_err; // asserted on a received EDH packet error

//
// EDH packet error detection
//
assign packet_err = (edh_missing | edh_parity_err | edh_format_err) & receive_mode;

//
// AP flag generation
//
assign ap_edh = ~packet_err & calc_ap_crc_valid & rx_ap_crc_valid & 
                (calc_ap_crc != rx_ap_crc);
assign ap_ues = ~rx_ap_crc_valid & receive_mode;

//
// FF flag generation
//
assign ff_edh = ~packet_err & calc_ff_crc_valid & rx_ff_crc_valid & 
                (calc_ff_crc != rx_ff_crc);
assign ff_ues = ~rx_ff_crc_valid & receive_mode;

//
// flags bus generation
//
assign flags[EDH_BIT] = (ap_flag_word & ap_edh) |
                        (ff_flag_word & ff_edh) |
                        (anc_flag_word & anc_edh_local);

assign flags[EDA_BIT] = ~packet_err & (
                        (ap_flag_word & (rx_ap_flags[EDH_BIT] | rx_ap_flags[EDA_BIT])) |
                        (ff_flag_word & (rx_ff_flags[EDH_BIT] | rx_ff_flags[EDA_BIT])) |
                        (anc_flag_word & (rx_anc_flags[EDH_BIT] | rx_anc_flags[EDA_BIT])));
                        

assign flags[IDH_BIT] = (ap_flag_word & ap_idh_local) |
                        (ff_flag_word & ff_idh_local) |
                        (anc_flag_word & anc_idh_local);

assign flags[IDA_BIT] = ~packet_err & ( 
                        (ap_flag_word & (rx_ap_flags[IDH_BIT] | rx_ap_flags[IDA_BIT])) |
                        (ff_flag_word & (rx_ff_flags[IDH_BIT] | rx_ff_flags[IDA_BIT])) |
                        (anc_flag_word & (rx_anc_flags[IDH_BIT] | rx_anc_flags[IDA_BIT])));
  
assign flags[UES_BIT] = packet_err |
                        (ap_flag_word & (ap_ues | (receive_mode & rx_ap_flags[UES_BIT]))) | 
                        (ff_flag_word & (ff_ues | (receive_mode & rx_ff_flags[UES_BIT]))) |
                        (anc_flag_word & (anc_ues_local | (receive_mode & rx_anc_flags[UES_BIT])));

//
// flag registers
//
// These register capture the three flag sets as the EDH packet is being
// generated and retain the error flag values until the next EDH packet is
// generated. This allows the error flag values to be observed by some other
// module or processor.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            ap_flags <= 0;
        else if (ap_flag_word)
            ap_flags <= flags;
    end

always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            ff_flags <= 0;
        else if (ff_flag_word)
            ff_flags <= flags;
    end

always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            anc_flags <= 0;
        else if (anc_flag_word)
            anc_flags <= flags;
    end

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/* 
This module examines the vcnt and hcnt values to determine when it is time for
an EDH packet to appear in the video stream. The signal edh_next is asserted
during the sample before the first location of the first ADF word of the
EDH packet.

The output of this module is used to determine if EDH packets are missing from
the input video stream and to determine when to insert EDH packets into the
output video stream.
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_edh_loc #(
    parameter HCNT_WIDTH = 12,  // # of bits in horizontal sample counter
    parameter VCNT_WIDTH = 10)  // # of bits in vertical line counter
(
    input  wire                     clk,            // clock input
    input  wire                     ce,             // clock enable
    input  wire                     rst,            // sync reset input
    input  wire                     f,              // field bit
    input  wire [VCNT_WIDTH-1:0]    vcnt,           // vertical line count
    input  wire [HCNT_WIDTH-1:0]    hcnt,           // horizontal sample count
    input  wire [2:0]               std,            // indicates the video standard
    output reg                      edh_next = 1'b0 // EDH packet should begin on next sample
);


//-----------------------------------------------------------------------------
// Parameter definitions
//
localparam HCNT_MSB      = HCNT_WIDTH - 1;       // MS bit # of hcnt
localparam VCNT_MSB      = VCNT_WIDTH - 1;       // MS bit # of vcnt


//
// This group of parameters defines the encoding for the video standards output
// code.
//
localparam [2:0]
    NTSC_422        = 3'b000,
    NTSC_INVALID    = 3'b001,
    NTSC_422_WIDE   = 3'b010,
    NTSC_4444       = 3'b011,
    PAL_422         = 3'b100,
    PAL_INVALID     = 3'b101,
    PAL_422_WIDE    = 3'b110,
    PAL_4444        = 3'b111;


//
// This group of parameters defines the line numbers where the EDH packet is
// located.
//
localparam NTSC_FLD1_EDH_LINE = 272;
localparam NTSC_FLD2_EDH_LINE =   9;
localparam PAL_FLD1_EDH_LINE  = 318;
localparam PAL_FLD2_EDH_LINE  =   5;
         
//
// This group of parameters defines the word count two words before the
// start of the EDH packet for each different supported video standard. First,
// the position of the SAV is defined, then the EDH packet position is defined
// relative to the SAV. A point two words counts before the start of the EDH
// packet is used because the edh_next must be asserted the count before the
// EDH plus there is one cycle of clock latency.
//

localparam SAV_NTSC_422      = 1712;
localparam SAV_NTSC_422_WIDE = 2284;
localparam SAV_NTSC_4444     = 3428;
localparam SAV_PAL_422       = 1724;
localparam SAV_PAL_422_WIDE  = 2300;
localparam SAV_PAL_4444      = 3452;

localparam EDH_PACKET_LENGTH = 23;

localparam EDH_NTSC_422      = SAV_NTSC_422 - EDH_PACKET_LENGTH - 2;
localparam EDH_NTSC_422_WIDE = SAV_NTSC_422_WIDE - EDH_PACKET_LENGTH - 2;
localparam EDH_NTSC_4444     = SAV_NTSC_4444 - EDH_PACKET_LENGTH - 2;
localparam EDH_PAL_422       = SAV_PAL_422 - EDH_PACKET_LENGTH - 2;
localparam EDH_PAL_422_WIDE  = SAV_PAL_422_WIDE - EDH_PACKET_LENGTH - 2;
localparam EDH_PAL_4444      = SAV_PAL_4444 - EDH_PACKET_LENGTH - 2;
        
//-----------------------------------------------------------------------------
// Signal definitions
//
wire                    ntsc;           // 1 = NTSC, 0 = PAL
reg     [VCNT_MSB:0]    edh_line_num;   // EDH occurs on this line number
wire                    edh_line;       // asserted when vcnt == edh_line_num
reg     [HCNT_MSB:0]    edh_hcnt;       // EDH begins sample after this value
wire                    edh_next_d;     // asserted when next sample begins EDH

//
// EDH vertical position detector
// 
// The following code determines when the current video line number (vcnt)
// matches the line where the next EDH packet location occurs. The line numbers
// for the EDH packets are different for NTSC and PAL video standards. Also,
// there is one EDH per field, so the field bit (f) is used to determine the
// line number of the next EDH packet.
//
assign ntsc = (std == NTSC_422) || (std == NTSC_INVALID) ||
              (std == NTSC_422_WIDE) || (std == NTSC_4444);

always @ (*)
    if (ntsc)
        begin
            if (~f)
                edh_line_num = NTSC_FLD2_EDH_LINE;
            else
                edh_line_num = NTSC_FLD1_EDH_LINE;
        end
    else
        begin
            if (~f)
                edh_line_num = PAL_FLD2_EDH_LINE;
            else
                edh_line_num = PAL_FLD1_EDH_LINE;
        end
            
assign edh_line = vcnt == edh_line_num;

//
// EDH horizontal position detector
//
// This code matches the current horizontal count (hcnt) with the word count
// of the next EDH location. The location of the EDH packet is immediately 
// before the SAV. edh_next_d is asserted when both the vcnt and hcnt match
// the EDH packet location.
//
always @ (*)
    case(std)
        NTSC_422:       edh_hcnt = EDH_NTSC_422;
        NTSC_422_WIDE:  edh_hcnt = EDH_NTSC_422_WIDE;
        NTSC_4444:      edh_hcnt = EDH_NTSC_4444;
        PAL_422:        edh_hcnt = EDH_PAL_422;
        PAL_422_WIDE:   edh_hcnt = EDH_PAL_422_WIDE;
        PAL_4444:       edh_hcnt = EDH_PAL_4444;
        default:        edh_hcnt = EDH_NTSC_422;
    endcase

assign edh_next_d = edh_line & (edh_hcnt == hcnt);

//
// output register
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            edh_next <= 1'b0;
        else
            edh_next <= edh_next_d;
    end
                    
endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/* 
This module instances and interconnects the various modules that make up the
error detection and handling (EDH) packet processor. This processor includes
an ANC packet checksum checker, but does not include any ANC packet mux or
demux functions.

EDH packets for digital component video are defined by the standards 
ITU-R BT.1304 and SMPTE RP 165-1994. The documents define a standard method
of generating and inserting checkwords into the video stream. These checkwords
are not used for error correction. They are used to determine if the video
data is being corrupted somewhere in the chain of video equipment processing
the data. The nature of the EDH packets allows the malfunctioning piece of
equipment to be quickly located.

Two checkwords are defined, one for the field of active picture (AP) video data
words and the other for the full field (FF) of video data. Three sets of flags
are defined to feed forward information regarding detected errors. One of flags
is associated with the AP checkword, one set with the FF checkword. The third
set of flags identify errors detected in the ancillary data checksums within
the field. Implementation of this third set is optional in the standards.

The two checkwords and three sets of flags for each field are combined into an
ancillary data packet, commonly called the EDH packet. The EDH packet occurs
at a fixed location, always immediately before the SAV symbol on the line before
the synchronous switching line. The synchronous switching lines for NTSC are
lines 10 and 273. For 625-line PAL they are lines 6 and 319.

Three sets of error flags outputs are provided. One set consists of the 12
error flags received in the last EDH packet in the input video stream. The
second set consists of the twelve flags sent in the last EDH packet in the
output video stream. A third set contains error flags related to the processing
of the received EDH packet such as packet_missing errors.

*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_edh_processor #(
    parameter ERROR_COUNT_WIDTH = 24,   // # of bits in errored fields counter
    parameter HCNT_WIDTH        = 12,   // # of bits in horizontal word counter
    parameter VCNT_WIDTH        = 10,   // # of bits in vertical line counter
    parameter FLAGS_WIDTH       = 16)   // # of bits in error flag enable field
(
    input  wire                         clk,                // clock input
    input  wire                         ce,                 // clock enable
    input  wire                         rst,                // sync reset input
    input  wire [9:0]                   vid_in,             // input video
    input  wire                         reacquire,          // forces autodetect to reacquire the video standard
    input  wire                         en_sync_switch,     // enables synchronous switching
    input  wire                         en_trs_blank,       // enables TRS blanking when asserted
    input  wire                         anc_idh_local,      // ANC IDH flag input
    input  wire                         anc_ues_local,      // ANC UES flag input
    input  wire                         ap_idh_local,       // AP IDH flag input
    input  wire                         ff_idh_local,       // FF IDH flag input
    input  wire [FLAGS_WIDTH-1:0]       errcnt_flg_en,      // selects which error flags increment the error counter
    input  wire                         clr_errcnt,         // clears the error counter
    input  wire                         receive_mode,       // 1 enables receiver, 0 for generate only
    output reg [9:0]                    vid_out = 10'b0,    // output video stream with EDH packets inserted
    output reg [2:0]                    std = 3'b0,         // video standard code
    output reg                          std_locked = 1'b0,  // video standard detector is locked
    output reg                          trs = 1'b0,         // asserted during flywheel generated TRS symbol
    output reg                          field = 1'b0,       // field indicator
    output reg                          v_blank = 1'b0,     // vertical blanking indicator
    output reg                          h_blank = 1'b0,     // horizontal blanking indicator
    output reg [HCNT_WIDTH-1:0]         horz_count = 0,     // horizontal position
    output reg [VCNT_WIDTH-1:0]         vert_count = 0,     // vertical position
    output reg                          sync_switch = 1'b0, // asserted on lines where synchronous switching is allowed
    output reg                          locked = 1'b0,      // asserted when flywheel is synchronized to video
    output reg                          eav_next = 1'b0,    // next word is first word of EAV
    output reg                          sav_next = 1'b0,    // next word is first word of SAV
    output reg                          xyz_word = 1'b0,    // current word is the XYZ word of a TRS
    output reg                          anc_next = 1'b0,    // next word is first word of a received ANC packet
    output reg                          edh_next = 1'b0,    // next word is first word of a received EDH packet
    output wire [4:0]                   rx_ap_flags,        // received AP error flags from last EDH packet
    output wire [4:0]                   rx_ff_flags,        // received FF error flags from last EDH packet
    output wire [4:0]                   rx_anc_flags,       // received ANC error flags from last EDH packet
    output wire [4:0]                   ap_flags,           // AP error flags from last field
    output wire [4:0]                   ff_flags,           // FF error flags from last field
    output wire [4:0]                   anc_flags,          // ANC error flags from last field
    output wire [3:0]                   packet_flags,       // error flags related to the received packet processing
    output wire [ERROR_COUNT_WIDTH-1:0] errcnt,             // errored fields counter
    output reg                          edh_packet = 1'b0   // asserted during all words of a generated EDH packet
);

//-----------------------------------------------------------------------------
// Parameter definitions
//

//
// This group of parameters defines the bit widths of various fields in the
// module. 
//
localparam HCNT_MSB      = HCNT_WIDTH - 1;       // MS bit # of hcnt
localparam VCNT_MSB      = VCNT_WIDTH - 1;       // MS bit # of vcnt
localparam ERRFLD_MSB    = ERROR_COUNT_WIDTH - 1;// MS bit of errcnt
localparam FLAGS_MSB     = FLAGS_WIDTH - 1;      // MS bit of flag enable field

//
// This group of parameters defines the encoding for the video standards output
// code.
//
localparam [2:0]
    NTSC_422        = 3'b000,
    NTSC_INVALID    = 3'b001,
    NTSC_422_WIDE   = 3'b010,
    NTSC_4444       = 3'b011,
    PAL_422         = 3'b100,
    PAL_INVALID     = 3'b101,
    PAL_422_WIDE    = 3'b110,
    PAL_4444        = 3'b111;

//-----------------------------------------------------------------------------
// Signal definitions
//
wire    [2:0]           dec_std;            // video_decode std output
wire                    dec_std_locked;     // video_decode std locked output
wire    [9:0]           dec_vid;            // video_decode video output
wire                    dec_trs;            // video_decode trs output
wire                    dec_f;              // video_decode field output
wire                    dec_v;              // video_decode v_blank output
wire                    dec_h;              // video_decode h_blank output
wire    [HCNT_MSB:0]    dec_hcnt;           // video_decode horz_count output
wire    [VCNT_MSB:0]    dec_vcnt;           // video_decode vert_count output
wire                    dec_sync_switch;    // video_decode sync_switch output
wire                    dec_locked;         // video_decode locked output
wire                    dec_eav_next;       // video_decode eav_next output
wire                    dec_sav_next;       // video_decode sav_next output
wire                    dec_xyz_word;       // video_decode xyz_word output
wire                    dec_anc_next;       // video_decode anc_next output
wire                    dec_edh_next;       // video_decode edh_next output
wire    [15:0]          ap_crc;             // calculated active pic CRC
wire                    ap_crc_valid;       // calculated active pic CRC valid signal
wire    [15:0]          ff_crc;             // calculated full field CRC
wire                    ff_crc_valid;       // calculated full field CRC valid signal
wire                    edh_missing;        // EDH packet missing error flag
wire                    edh_parity_err;     // EDH packet parity error flag
wire                    edh_chksum_err;     // EDH packet checksum error flag
wire                    edh_format_err;     // EDH packet format error flag
wire                    tx_edh_next;        // generated EDH packet begins on next word
wire    [4:0]           flag_bus;           // flag bus between EDH_FLAGS and EDH_TX
wire                    ap_flag_word;       // selects AP flags for flag bus
wire                    ff_flag_word;       // selects FF flags for flag bus
wire                    anc_flag_word;      // selects ANC flags for flag bus
wire                    rx_ap_crc_valid;    // received active pic CRC valid signal
wire    [15:0]          rx_ap_crc;          // received active pic CRC
wire                    rx_ff_crc_valid;    // received full field CRC valid signal
wire    [15:0]          rx_ff_crc;          // received full field CRC
wire    [4:0]           in_ap_flags;        // received active pic flags to edh_flags
wire    [4:0]           in_ff_flags;        // received full field flags to edh_flags
wire    [4:0]           in_anc_flags;       // received ANC flags to edh_flags
reg                     errcnt_en = 1'b0;   // enables error counter
wire                    anc_edh_local;      // ANC EDH signal
wire    [9:0]           tx_vid_out;         // video out of edh_tx
wire                    tx_edh_packet;      // asserted when edh packet is to be generated


//
// Video decoder module from XAPP625
//
v_smpte_sdi_v3_0_8_video_decode #(
    .VCNT_WIDTH     (VCNT_WIDTH),
    .HCNT_WIDTH     (HCNT_WIDTH))
DEC (
    .clk            (clk),
    .ce             (ce),
    .rst            (rst),
    .vid_in         (vid_in),
    .reacquire      (reacquire),
    .en_sync_switch (en_sync_switch),
    .en_trs_blank   (en_trs_blank),
    .std            (dec_std),
    .std_locked     (dec_std_locked),
    .trs            (dec_trs),
    .vid_out        (dec_vid),
    .field          (dec_f),
    .v_blank        (dec_v),
    .h_blank        (dec_h),
    .horz_count     (dec_hcnt),
    .vert_count     (dec_vcnt),
    .sync_switch    (dec_sync_switch),
    .locked         (dec_locked),
    .eav_next       (dec_eav_next),
    .sav_next       (dec_sav_next),
    .xyz_word       (dec_xyz_word),
    .anc_next       (dec_anc_next),
    .edh_next       (dec_edh_next)
);

//
// edh_crc module
//
// This module computes the CRC values for the incoming video stream, vid_in.
// Also, the module generates valid signals for both CRC values based on the
// locked signal. If locked rises during a field, the CRC is considered to be
// invalid.
v_smpte_sdi_v3_0_8_edh_crc #(
    .VCNT_WIDTH     (VCNT_WIDTH))
EDH_CRC (
    .clk            (clk),
    .ce             (ce),
    .rst            (rst),
    .f              (dec_f),
    .h              (dec_h),
    .eav_next       (dec_eav_next),
    .xyz_word       (dec_xyz_word),
    .vid_in         (dec_vid),
    .vcnt           (dec_vcnt),
    .std            (dec_std),
    .locked         (dec_locked),
    .ap_crc         (ap_crc),
    .ap_crc_valid   (ap_crc_valid),
    .ff_crc         (ff_crc),
    .ff_crc_valid   (ff_crc_valid)
);

//
// edh_rx module
//
// This module processes EDH packets found in the incoming video stream. The
// CRC words and valid flags are captured from the packet. Various error flags
// related to errors found in the packet are generated.
//
v_smpte_sdi_v3_0_8_edh_rx EDH_RX (
    .clk            (clk),
    .ce             (ce),
    .rst            (rst),
    .rx_edh_next    (dec_edh_next),
    .vid_in         (dec_vid),
    .edh_next       (tx_edh_next),
    .reg_flags      (1'b0),
    .ap_crc_valid   (rx_ap_crc_valid),
    .ap_crc         (rx_ap_crc),
    .ff_crc_valid   (rx_ff_crc_valid),
    .ff_crc         (rx_ff_crc),
    .edh_missing    (edh_missing),
    .edh_parity_err (edh_parity_err),
    .edh_chksum_err (edh_chksum_err),
    .edh_format_err (edh_format_err),
    .in_ap_flags    (in_ap_flags),
    .in_ff_flags    (in_ff_flags),
    .in_anc_flags   (in_anc_flags),
    .rx_ap_flags    (rx_ap_flags),
    .rx_ff_flags    (rx_ff_flags),
    .rx_anc_flags   (rx_anc_flags)
);

//
// edh_loc module
//
// This module locates the beginning of an EDH packet in the incoming video
// stream. It asserts the tx_edh_next siganl the sample before the EDH packet
// begins on vid_in.
//
v_smpte_sdi_v3_0_8_edh_loc #(
    .HCNT_WIDTH     (HCNT_WIDTH),
    .VCNT_WIDTH     (VCNT_WIDTH))
EDH_LOC (
    .clk            (clk),
    .ce             (ce),
    .rst            (rst),
    .f              (dec_f),
    .vcnt           (dec_vcnt),
    .hcnt           (dec_hcnt),
    .std            (dec_std),
    .edh_next       (tx_edh_next)
);

//
// anc_rx module
//
// This module calculates checksums for every ANC packet in the input video
// stream and compares the calculated checksums against the CS word of each
// packet. It also checks the parity bits of all parity protected words in the
// ANC packets. An error in any ANC packet will assert the anc_edh_local signal.
// This output will remain asserted until after the next EDH packet is sent in
// the output video stream.
//
v_smpte_sdi_v3_0_8_anc_rx ANC_RC (
    .clk            (clk),
    .ce             (ce),
    .rst            (rst),
    .locked         (dec_locked),
    .rx_anc_next    (dec_anc_next),
    .rx_edh_next    (dec_edh_next),
    .edh_packet     (tx_edh_packet),
    .vid_in         (dec_vid),
    .anc_edh_local  (anc_edh_local)
);

//
// edh_tx module
//
// This module generates a new EDH packet based on the calculated CRC words
// and the incoming and local flags.
//
v_smpte_sdi_v3_0_8_edh_tx EDH_TX (
    .clk            (clk),
    .ce             (ce),
    .rst            (rst),
    .vid_in         (dec_vid),
    .edh_next       (tx_edh_next),
    .edh_missing    (edh_missing),
    .ap_crc_valid   (ap_crc_valid),
    .ap_crc         (ap_crc),
    .ff_crc_valid   (ff_crc_valid),
    .ff_crc         (ff_crc),
    .flags_in       (flag_bus),
    .ap_flag_word   (ap_flag_word),
    .ff_flag_word   (ff_flag_word),
    .anc_flag_word  (anc_flag_word),
    .edh_packet     (tx_edh_packet),
    .edh_vid        (tx_vid_out)
);

//
// edh_flags module
//
// This module creates the error flags that are included in the new
// EDH packet created by the GEN module. It also captures those flags until the
// next EDH packet and provides them as outputs.
//
v_smpte_sdi_v3_0_8_edh_flags EDH_FLAGS (
    .clk                (clk),
    .ce                 (ce),
    .rst                (rst),
    .receive_mode       (receive_mode),
    .ap_flag_word       (ap_flag_word),
    .ff_flag_word       (ff_flag_word),
    .anc_flag_word      (anc_flag_word),
    .edh_missing        (edh_missing),
    .edh_parity_err     (edh_parity_err),
    .edh_format_err     (edh_format_err),
    .rx_ap_crc_valid    (rx_ap_crc_valid),
    .rx_ap_crc          (rx_ap_crc),
    .rx_ff_crc_valid    (rx_ff_crc_valid),
    .rx_ff_crc          (rx_ff_crc),
    .rx_ap_flags        (in_ap_flags),
    .rx_ff_flags        (in_ff_flags),
    .rx_anc_flags       (in_anc_flags),
    .anc_edh_local      (anc_edh_local),
    .anc_idh_local      (anc_idh_local),
    .anc_ues_local      (anc_ues_local),
    .ap_idh_local       (ap_idh_local),
    .ff_idh_local       (ff_idh_local),
    .calc_ap_crc_valid  (ap_crc_valid),
    .calc_ap_crc        (ap_crc),
    .calc_ff_crc_valid  (ff_crc_valid),
    .calc_ff_crc        (ff_crc),
    .flags              (flag_bus),
    .ap_flags           (ap_flags),
    .ff_flags           (ff_flags),
    .anc_flags          (anc_flags)
);

//
// edh_errcnt module
//
// This counter increments once for every field that contains an enabled error.
// The error counter is disabled until after the video decoder is locked to the
// video stream for the first time and the first EDH packet has been received.
//
v_smpte_sdi_v3_0_8_edh_errcnt # (
    .ERROR_COUNT_WIDTH  (ERROR_COUNT_WIDTH),
    .FLAGS_WIDTH        (FLAGS_WIDTH))
EDH_ERRCNT (
    .clk                (clk),
    .ce                 (ce),
    .rst                (rst),
    .clr_errcnt         (clr_errcnt),
    .count_en           (errcnt_en),
    .flag_enables       (errcnt_flg_en),
    .flags              ({edh_chksum_err, ap_flags, ff_flags, anc_flags}),
    .edh_next           (tx_edh_next),
    .errcnt             (errcnt)
);

always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            errcnt_en <= 1'b0;
        else if (locked & dec_edh_next)
            errcnt_en <= 1'b1;
    end

//
// packet_flags
//
// This statement combines the four EDH packet flags into a vector.
//
assign packet_flags = {edh_format_err, edh_chksum_err, edh_parity_err, edh_missing};

//
// output registers
//
// This code implements an output register for the video path and all video
// timing signals.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
        begin
            vid_out <= 0;
            std <= 0;
            std_locked <= 0;
            trs <= 0;
            field <= 0;
            v_blank <= 0;
            h_blank <= 0;
            horz_count <= 0;
            vert_count <= 0;
            sync_switch <= 0;
            locked <= 0;
            eav_next <= 0;
            sav_next <= 0;
            xyz_word <= 0;
            anc_next <= 0;
            edh_next <= 0;
            edh_packet <= 0;
        end
        else
        begin
            vid_out <= tx_vid_out;
            std <= dec_std;
            std_locked <= dec_std_locked;
            trs <= dec_trs;
            field <= dec_f;
            v_blank <= dec_v;
            h_blank <= dec_h;
            horz_count <= dec_hcnt;
            vert_count <= dec_vcnt;
            sync_switch <= dec_sync_switch;
            locked <= dec_locked;
            eav_next <= dec_eav_next;
            sav_next <= dec_sav_next;
            xyz_word <= dec_xyz_word;
            anc_next <= dec_anc_next;
            edh_next <= dec_edh_next;
            edh_packet <= tx_edh_packet;
        end
    end

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/* 
This module processes a received EDH packet. It examines the vcnt and hcnt
values from the video flywheel to determine when an EDH packet should occur. If
there is no EDH packet then, the missing EDH packet flag is asserted. If an EDH
packet occurs somewhere other than where it is expected, the misplaced EDH
packet flag is asserted.

When an EDH packet at the expected location if found, it is checked to make
sure all the words of the packet are correct, that the parity of the payload
data words are correct, and that the checksum for the packet is correct.

The active picture and full field CRCs and flags are extracted and stored in
registers.
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_edh_rx (
    input  wire             clk,                    // clock input
    input  wire             ce,                     // clock enable
    input  wire             rst,                    // sync reset input
    input  wire             rx_edh_next,            // indicates the next word is the first word of a received EDH packet
    input  wire [9:0]       vid_in,                 // video data
    input  wire             edh_next,               // EDH packet begins on next sample
    input  wire             reg_flags,              // 1 = register flag words, 0 = feed vid_in through
    output reg              ap_crc_valid = 1'b0,    // valid bit for active picture CRC
    output wire [15:0]      ap_crc,                 // active picture CRC
    output reg              ff_crc_valid = 1'b0,    // valid bit for full field CRC
    output wire [15:0]      ff_crc,                 // full field CRC
    output reg              edh_missing = 1'b0,     // asserted when last expected EDH packet was missing
    output reg              edh_parity_err = 1'b0,  // asserted when a parity error occurs in EDH packet
    output reg              edh_chksum_err = 1'b0,  // asserted when a checksum error occurs in EDH packet
    output reg              edh_format_err = 1'b0,  // asserted when a format error is found in EDH packet
    output wire [4:0]       in_ap_flags,            // received AP flag word to edh_flags module
    output wire [4:0]       in_ff_flags,            // received FF flag word to edh_flags module
    output wire [4:0]       in_anc_flags,           // received ANC flag word to edh_flags module
    output wire [4:0]       rx_ap_flags,            // received & registered AP flags for external inspection
    output wire [4:0]       rx_ff_flags,            // received & registered FF flags for external inspection
    output wire [4:0]       rx_anc_flags            // received & registered ANC flags for external inspection
);


//-----------------------------------------------------------------------------
// Parameter definitions
//      

//
// This group of parameters defines the fixed values of some of the words in
// the EDH packet.
//
localparam EDH_DID           = 10'h1f4;
localparam EDH_DBN           = 10'h200;
localparam EDH_DC            = 10'h110;


//
// This group of parameters defines the states of the EDH processor state
// machine.
//
localparam STATE_WIDTH   = 5;
localparam STATE_MSB     = STATE_WIDTH - 1;

localparam [STATE_WIDTH-1:0]
    S_WAIT   = 0,
    S_ADF1   = 1,
    S_ADF2   = 2,
    S_ADF3   = 3,
    S_DID    = 4,
    S_DBN    = 5,
    S_DC     = 6,
    S_AP1    = 7,
    S_AP2    = 8,
    S_AP3    = 9,
    S_FF1    = 10,
    S_FF2    = 11,
    S_FF3    = 12,
    S_ANCFLG = 13,
    S_APFLG  = 14,
    S_FFFLG  = 15,
    S_RSV1   = 16,
    S_RSV2   = 17,
    S_RSV3   = 18,
    S_RSV4   = 19,
    S_RSV5   = 20,
    S_RSV6   = 21,
    S_RSV7   = 22,
    S_CHK    = 23,
    S_ERRM   = 24,  // Missing EDH packet
    S_ERRF   = 25,  // Format error in EDH packet
    S_ERRC   = 26;  // Checksum error in EDH packet

//-----------------------------------------------------------------------------
// Signal definitions
//
reg     [STATE_MSB:0]   current_state = S_WAIT;     // FSM current state
reg     [STATE_MSB:0]   next_state;                 // FSM next state
wire                    parity_err;                 // detects parity errors on EDH words
wire                    parity;                     // used to generate parity_err
reg     [8:0]           checksum = 9'b0;            // checksum for EDH packet
reg                     ld_ap1;                     // loads bits 5:0 of active picture crc
reg                     ld_ap2;                     // loads bits 11:6 of active picture crc
reg                     ld_ap3;                     // loads bits 15:12 of active picture crc
reg                     ld_ff1;                     // loads bits 5:0 of full field crc
reg                     ld_ff2;                     // loads bits 11:6 of full field crc
reg                     ld_ff3;                     // loads bits 15:12 of full field crc
reg                     ld_ap_flags;                // loads the rx_ap_flags register
reg                     ld_ff_flags;                // loads the rx_ff_flags register
reg                     ld_anc_flags;               // loads the rx_anc_flags register
reg                     clr_checksum;               // asserted to clear the checksum
reg                     clr_errors;                 // asserted to clear the EDH packet errs
reg     [15:0]          ap_crc_reg = 15'b0;         // active picture CRC register
reg     [15:0]          ff_crc_reg = 15'b0;         // full field CRC register                  
reg                     missing_err;                // asserted when EDH packet is missing
reg                     format_err;                 // asserted when format error in EDH packet is detected
reg                     check_parity;               // asserted when parity error in EDH packet is detected
reg                     checksum_err;               // asserted when checksum error in EDH packet is detected
reg                     rx_edh = 1'b0;              // asserted when current word is first word of received EDH
reg     [4:0]           rx_ap_flg_reg = 5'b0;       // holds the received AP flags
reg     [4:0]           rx_ff_flg_reg = 5'b0;       // holds the received FF flags
reg     [4:0]           rx_anc_flg_reg = 5'b0;      // holds the received ANC flags

//
// delay flip-flop for rx_edh_next
//
// The resulting signal, rx_edh, is asserted during the first word of a
// received EDH packet.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            rx_edh <= 1'b0;
        else
            rx_edh <= rx_edh_next;
    end

//
// FSM: current_state register
//
// This code implements the current state register. 
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            current_state <= S_WAIT;
        else
            current_state <= next_state;
    end

//
// FSM: next_state logic
//
// This case statement generates the next_state value for the FSM based on
// the current_state and the various FSM inputs.
//
always @ (*)
    case(current_state)
        S_WAIT:     if (edh_next)
                        next_state = S_ADF1;
                    else
                        next_state = S_WAIT;
                
        S_ADF1:     if (rx_edh)
                        next_state = S_ADF2;
                    else
                        next_state = S_ERRM;

        S_ADF2:     next_state = S_ADF3;

        S_ADF3:     next_state = S_DID;

        S_DID:      next_state = S_DBN;

        S_DBN:      if (vid_in[9:2] == (EDH_DBN >> 2))
                        next_state = S_DC;
                    else
                        next_state = S_ERRF;

        S_DC:       if (vid_in[9:2] == (EDH_DC >> 2))
                        next_state = S_AP1;
                    else
                        next_state = S_ERRF;

        S_AP1:      next_state = S_AP2;

        S_AP2:      next_state = S_AP3;

        S_AP3:      next_state = S_FF1;

        S_FF1:      next_state = S_FF2;

        S_FF2:      next_state = S_FF3;

        S_FF3:      next_state = S_ANCFLG;

        S_ANCFLG:   next_state = S_APFLG;

        S_APFLG:    next_state = S_FFFLG;
                    
        S_FFFLG:    next_state = S_RSV1;

        S_RSV1:     next_state = S_RSV2;

        S_RSV2:     next_state = S_RSV3;

        S_RSV3:     next_state = S_RSV4;

        S_RSV4:     next_state = S_RSV5;

        S_RSV5:     next_state = S_RSV6;

        S_RSV6:     next_state = S_RSV7;

        S_RSV7:     next_state = S_CHK;

        S_CHK:      if (checksum == vid_in[8:0] && checksum[8] == ~vid_in[9])
                        next_state = S_WAIT;
                    else
                        next_state = S_ERRC;

        S_ERRM:     next_state = S_WAIT;

        S_ERRF:     next_state = S_WAIT;

        S_ERRC:     next_state = S_WAIT;

        default: next_state = S_WAIT;

    endcase
        
//
// FSM: outputs
//
// This block decodes the current state to generate the various outputs of the
// FSM.
//
always @ (*)
begin
    // Unless specifically assigned in the case statement, all FSM outputs
    // default to the values below.
    ld_ap1          = 1'b0;
    ld_ap2          = 1'b0;
    ld_ap3          = 1'b0;
    ld_ff1          = 1'b0;
    ld_ff2          = 1'b0;
    ld_ff3          = 1'b0;
    ld_ap_flags     = 1'b0;
    ld_ff_flags     = 1'b0;
    ld_anc_flags    = 1'b0;
    clr_checksum    = 1'b0;
    clr_errors      = 1'b0;
    missing_err     = 1'b0;
    format_err      = 1'b0;
    check_parity    = 1'b0;
    checksum_err    = 1'b0;
                        
    case(current_state)     
        S_ADF1:     clr_errors = 1'b1;

        S_ADF3:     clr_checksum = 1'b1;

        S_AP1:      begin
                        ld_ap1 = 1'b1;
                        check_parity = 1'b1;
                    end

        S_AP2:      begin
                        ld_ap2 = 1'b1;
                        check_parity = 1'b1;
                    end

        S_AP3:      begin
                        ld_ap3 = 1'b1;
                        check_parity = 1'b1;
                    end

        S_FF1:      begin
                        ld_ff1 = 1'b1;
                        check_parity = 1'b1;
                    end

        S_FF2:      begin
                        ld_ff2 = 1'b1;
                        check_parity = 1'b1;
                    end

        S_FF3:      begin
                        ld_ff3 = 1'b1;
                        check_parity = 1'b1;
                    end

        S_ANCFLG:   begin
                        ld_anc_flags = 1'b1;
                        check_parity = 1'b1;
                    end

        S_APFLG:    begin
                        ld_ap_flags = 1'b1;
                        check_parity = 1'b1;
                    end

        S_FFFLG:    begin
                        ld_ff_flags = 1'b1;
                        check_parity = 1'b1;
                    end

        S_ERRM:     missing_err = 1'b1;

        S_ERRF:     format_err = 1'b1;

        S_ERRC:     checksum_err = 1'b1;

    endcase
end

//
// parity error detection
//
// This code calculates the parity of bits 7:0 of the video word. The calculated
// parity bit is compared to bit 8 and the complement of bit 9 to determine if
// a parity error has occured. If a parity error is detected, the parity_err
// signal is asserted. Parity is only valid on the payload portion of the
// EDH packet (user data words).
//
assign parity = vid_in[7] ^ vid_in[6] ^ vid_in[5] ^ vid_in[4] ^
                vid_in[3] ^ vid_in[2] ^ vid_in[1] ^ vid_in[0];

assign parity_err = (parity ^ vid_in[8]) | (parity ^ ~vid_in[9]);


//
// checksum calculator
//
// This code generates a checksum for the EDH packet. The checksum is cleared
// to zero prior to beginning the checksum calculation by the FSM asserting the
// clr_checksum signal. The vid_in word is added to the current checksum when
// the FSM asserts the do_checksum signal. The checksum is a 9-bit value and
// is computed by summing all but the MSB of the vid_in word with the current
// checksum value and ignoring any carry bits.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst | clr_checksum)
            checksum <= 0;
        else
            checksum <= checksum + vid_in[8:0];
    end


//
// Active-picture CRC and valid bit register
//
// This code captures the AP CRC word and valid bit. The CRC word is carried
// in three different words in the EDH packet and is assembled into a complete
// 16-bit checkword plus a valid bit by this logic.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
        begin
            ap_crc_valid <= 1'b0;
            ap_crc_reg <= 0;
        end
        else
        begin
            if (ld_ap1)
                ap_crc_reg <= {ap_crc_reg[15:6], vid_in[7:2]};
            else if (ld_ap2)
                ap_crc_reg <= {ap_crc_reg[15:12], vid_in[7:2], ap_crc_reg[5:0]};
            else if (ld_ap3)
            begin
                ap_crc_reg <= {vid_in[5:2], ap_crc_reg[11:0]};
                ap_crc_valid <= vid_in[7];
            end
        end
    end

//
// Full-field CRC and valid bit register
//
// This code captures the FF CRC word and valid bit. The CRC word is carried
// in three different words in the EDH packet and is assembled into a complete
// 16-bit checkword plus a valid bit by this logic.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
        begin
            ff_crc_valid <= 1'b0;
            ff_crc_reg <= 0;
        end
        else
        begin
            if (ld_ff1)
                ff_crc_reg <= {ff_crc_reg[15:6], vid_in[7:2]};
            else if (ld_ff2)
                ff_crc_reg <= {ff_crc_reg[15:12], vid_in[7:2], ff_crc_reg[5:0]};
            else if (ld_ff3)
            begin
                ff_crc_reg <= {vid_in[5:2], ff_crc_reg[11:0]};
                ff_crc_valid <= vid_in[7];
            end
        end
    end

//
// EDH packet error flags
//
// This code implements registers for each of the four different EDH packet
// error flags. These flags are captured as an EDH packet is received and
// remain asserted until the start of the next EDH packet.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst | clr_errors)
        begin
            edh_missing <= 1'b0;
            edh_parity_err <= 1'b0;
            edh_chksum_err <= 1'b0;
            edh_format_err <= 1'b0;
        end
        else 
        begin
            if (missing_err)
                edh_missing <= 1'b1;
            if (format_err)
                edh_format_err <= 1'b1;
            if (checksum_err)
                edh_chksum_err <= 1'b1;
            if (check_parity & parity_err)
                edh_parity_err <= 1'b1;
        end
    end


//
// received flags registers
//
// These registers capture the three sets of error status flags (ap, ff, and
// anc) from the received EDH packet. These flags remain in the registers 
// until overwritten by the next EDH packet.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            rx_ap_flg_reg <= 0;
        else if (ld_ap_flags)
            rx_ap_flg_reg <= vid_in[6:2];
    end

assign in_ap_flags = reg_flags ? rx_ap_flg_reg : vid_in[6:2];

always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            rx_ff_flg_reg <= 0;
        else if (ld_ff_flags)
            rx_ff_flg_reg <= vid_in[6:2];
    end

assign in_ff_flags = reg_flags ? rx_ff_flg_reg : vid_in[6:2];

always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            rx_anc_flg_reg <= 0;
        else if (ld_anc_flags)
            rx_anc_flg_reg <= vid_in[6:2];
    end
                            
assign in_anc_flags = reg_flags ? rx_anc_flg_reg : vid_in[6:2];

//
// outputs assignments
//
assign ap_crc = ap_crc_reg;
assign ff_crc = ff_crc_reg;
    
assign rx_ap_flags = rx_ap_flg_reg;
assign rx_ff_flags = rx_ff_flg_reg;
assign rx_anc_flags = rx_anc_flg_reg;
                    
endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/* 
This module generates a new EDH packet and inserts it into the output video
stream.

The module is controlled by a finite state machine. The FSM waits for the
edh_next signal to be asserted by the edh_loc module. This signal indicates
that the next word is beginning of the area where an EDH packet should be
inserted.

The FSM then generates all the words of the EDH packet, assembling the payload
of the packet from the CRC and error flag inputs. The three sets of error flags
enter the module sequentially on the flags_in port. The module generates three
outputs (ap_flag_word, ff_flag_word, and anc_flag_word) to indicate which flag
set it needs on the flags_in port.

The module generates an output signal, edh_packet, that is asserted during all
the entire time that a generated EDH packet is being inserted into the video
stream. This signal is used by various other modules to determine when an EDH
packet has been sent.
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_edh_tx (
    // inputs
    input  wire                 clk,                // clock input
    input  wire                 ce,                 // clock enable
    input  wire                 rst,                // sync reset input
    input  wire [9:0]           vid_in,             // input video data
    input  wire                 edh_next,           // asserted when next word begins generated EDH packet
    input  wire                 edh_missing,        // received EDH packet is missing
    input  wire                 ap_crc_valid,       // active picture CRC valid
    input  wire [15:0]          ap_crc,             // active picture CRC
    input  wire                 ff_crc_valid,       // full field CRC valid
    input  wire [15:0]          ff_crc,             // full field CRC
    input  wire [4:0]           flags_in,           // bus that carries AP, FF, and ANC flags
    output reg                  ap_flag_word,       // asserted during AP flag word in EDH packet
    output reg                  ff_flag_word,       // asserted during FF flag word in EDH packet
    output reg                  anc_flag_word,      // asserted during ANC flag word in EDH packet
    output reg                  edh_packet = 1'b0,  // asserted during all words of EDH packet
    output wire [9:0]           edh_vid             // generated EDH packet data
);


//-----------------------------------------------------------------------------
// Parameter definitions
//      

//
// This group of parameters defines the fixed values of some of the words in
// the EDH packet.
//
localparam EDH_ADF1          = 10'h000;
localparam EDH_ADF2          = 10'h3ff;
localparam EDH_ADF3          = 10'h3ff;
localparam EDH_DID           = 10'h1f4;
localparam EDH_DBN           = 10'h200;
localparam EDH_DC            = 10'h110;
localparam EDH_RSVD          = 10'h200;

//
// This group of parameters defines the states of the EDH generator state
// machine.
//
localparam STATE_WIDTH   = 5;
localparam STATE_MSB     = STATE_WIDTH - 1;

localparam [STATE_WIDTH-1:0]
    S_WAIT   = 0,
    S_ADF1   = 1,
    S_ADF2   = 2,
    S_ADF3   = 3,
    S_DID    = 4,
    S_DBN    = 5,
    S_DC     = 6,
    S_AP1    = 7,
    S_AP2    = 8,
    S_AP3    = 9,
    S_FF1    = 10,
    S_FF2    = 11,
    S_FF3    = 12,
    S_ANCFLG = 13,
    S_APFLG  = 14,
    S_FFFLG  = 15,
    S_RSV1   = 16,
    S_RSV2   = 17,
    S_RSV3   = 18,
    S_RSV4   = 19,
    S_RSV5   = 20,
    S_RSV6   = 21,
    S_RSV7   = 22,
    S_CHK    = 23;

//-----------------------------------------------------------------------------
// Signal definitions
//
reg     [STATE_MSB:0]   current_state = S_WAIT;     // FSM current state register
reg     [STATE_MSB:0]   next_state;                 // FSM next state value
wire                    parity;                     // used to generate parity bit for EDH packet words
reg     [8:0]           checksum = 9'b0;            // used to calculated EDH packet CS word
reg                     clr_checksum;               // clears the checksum register
reg     [9:0]           vid;                        // internal version of edh_vid output port
reg                     end_packet;                 // FSM output that clears the edh_packet signal


//
// FSM: current_state register
//
// This code implements the current state register. It loads with the HSYNC1
// state on reset and the next_state value with each rising clock edge.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            current_state <= S_WAIT;
        else
            current_state <= next_state;
    end

//
// FSM: next_state logic
//
// This case statement generates the next_state value for the FSM based on
// the current_state and the various FSM inputs.
//
always @ (*)
    case(current_state)
        S_WAIT:     if (edh_next)
                        next_state = S_ADF1;
                    else
                        next_state = S_WAIT;
                
        S_ADF1:     next_state = S_ADF2;

        S_ADF2:     next_state = S_ADF3;

        S_ADF3:     next_state = S_DID;

        S_DID:      next_state = S_DBN;

        S_DBN:      next_state = S_DC;

        S_DC:       next_state = S_AP1;

        S_AP1:      next_state = S_AP2;

        S_AP2:      next_state = S_AP3;

        S_AP3:      next_state = S_FF1;

        S_FF1:      next_state = S_FF2;

        S_FF2:      next_state = S_FF3;

        S_FF3:      next_state = S_ANCFLG;

        S_ANCFLG:   next_state = S_APFLG;

        S_APFLG:    next_state = S_FFFLG;
                    
        S_FFFLG:    next_state = S_RSV1;

        S_RSV1:     next_state = S_RSV2;

        S_RSV2:     next_state = S_RSV3;

        S_RSV3:     next_state = S_RSV4;

        S_RSV4:     next_state = S_RSV5;

        S_RSV5:     next_state = S_RSV6;

        S_RSV6:     next_state = S_RSV7;

        S_RSV7:     next_state = S_CHK;

        S_CHK:      next_state = S_WAIT;

        default: next_state = S_WAIT;

    endcase
        
//
// FSM: outputs
//
// This block decodes the current state to generate the various outputs of the
// FSM.
//
always @ (*)
begin
    // Unless specifically assigned in the case statement, all FSM outputs
    // default to the values below.
    vid             = vid_in;
    clr_checksum    = 1'b0;
    end_packet      = 1'b0;
    ap_flag_word    = 1'b0;
    ff_flag_word    = 1'b0;
    anc_flag_word   = 1'b0;
                                
    case(current_state)     
        S_ADF1:     vid = EDH_ADF1;

        S_ADF2:     vid = EDH_ADF2;

        S_ADF3:     begin
                        vid = EDH_ADF3;
                        clr_checksum = 1'b1;
                    end

        S_DID:      vid = EDH_DID;

        S_DBN:      vid = EDH_DBN;

        S_DC:       vid = EDH_DC;

        S_AP1:      vid = {~parity, parity, ap_crc[5:0], 2'b00};

        S_AP2:      vid = {~parity, parity, ap_crc[11:6], 2'b00};

        S_AP3:      vid = {~parity, parity, ap_crc_valid, 1'b0, 
                            ap_crc[15:12], 2'b00};

        S_FF1:      vid = {~parity, parity, ff_crc[5:0], 2'b00};

        S_FF2:      vid = {~parity, parity, ff_crc[11:6], 2'b00};

        S_FF3:      vid = {~parity, parity, ff_crc_valid, 1'b0, 
                            ff_crc[15:12], 2'b00};

        S_ANCFLG:   begin
                        vid = {~parity, parity, 1'b0, flags_in, 2'b00};
                        anc_flag_word = 1'b1;
                    end

        S_APFLG:    begin
                        vid = {~parity, parity, 1'b0, flags_in, 2'b00};
                        ap_flag_word = 1'b1;
                    end

        S_FFFLG:    begin
                        vid = {~parity, parity, 1'b0, flags_in, 2'b00};
                        ff_flag_word = 1'b1;
                    end

        S_RSV1:     vid = EDH_RSVD;

        S_RSV2:     vid = EDH_RSVD;

        S_RSV3:     vid = EDH_RSVD;

        S_RSV4:     vid = EDH_RSVD;

        S_RSV5:     vid = EDH_RSVD;

        S_RSV6:     vid = EDH_RSVD;

        S_RSV7:     vid = EDH_RSVD;

        S_CHK:      begin
                        vid = {~checksum[8], checksum};
                        end_packet = 1'b1;
                    end
    endcase
end

//
// parity bit generation
//
// This code calculates the parity of bits 7:0 of the video word. The parity
// bit is inserted into bit 8 of parity protected words of the EDH packet. The
// complement of the parity bit is inserted into bit 9 of those same words.
//
assign parity = vid[7] ^ vid[6] ^ vid[5] ^ vid[4] ^
                vid[3] ^ vid[2] ^ vid[1] ^ vid[0];


//
// checksum calculator
//
// This code generates a checksum for the EDH packet. The checksum is cleared
// to zero prior to beginning the checksum calculation by the FSM asserting the
// clr_checksum signal. The vid_in word is added to the current checksum when
// the FSM asserts the do_checksum signal. The checksum is a 9-bit value and
// is computed by summing all but the MSB of the vid_in word with the current
// checksum value and ignoring any carry bits.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst | clr_checksum)
            checksum <= 0;
        else 
            checksum <= checksum + vid[8:0];
    end

//
// edh_packet signal
//
// The edh_packet signal becomes asserted at the beginning of an EDH packet
// and remains asserted through the last word of the EDH packet.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            edh_packet <= 1'b0;
        else
        begin
            if (edh_next)
                edh_packet <= 1'b1;
            else if (end_packet)
                edh_packet <= 1'b0;
        end
    end

//
// output assignments
//
assign edh_vid = vid;

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
Module description:

This module implements the field related functions for the video flywheel.
There are two main field related functions included in this module. The first
is the F bit. This bit indicates the field that is currently active. The other
function is the received field transition detector. This function determines
when the received video transition from one field to the next.

The inputs to this module are:

clk: clock input

rst: synchronous reset input

ce: clock enable

ld_f: When this input is asserted, the F flip-flop is loaded with the 
current field value.

inc_f: When this input is asserted the F flip-flop is toggled.

eav_next: Must be asserted the clock cycle before the first word of an EAV 
symbol is processed by the flywheel.

rx_field: This is the F bit from the XYZ word of the input video stream. This
input is only valied when rx_xyz is asserted.

rx_xyz: Asserted when the flywheel is processing the XYZ word of a TRS symbol.

The outputs of this module are:

f: Current field bit

new_rx_field: Asserted for when a field transition is detected. This signal
will be asserted for the entire duration of the first line of a new field.
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_fly_field (
    input  wire             clk,            // clock input
    input  wire             rst,            // sync reset input
    input  wire             ce,             // clock enable
    input  wire             ld_f,           // loads the F bit
    input  wire             inc_f,          // toggles the F bit
    input  wire             eav_next,       // asserted when next word is first word of EAV
    input  wire             rx_field,       // F bit from received XYZ word
    input  wire             rx_xyz,         // asserted during XYZ word of received TRS symbol
    output reg              f = 1'b0,       // field bit
    output wire             new_rx_field    // asserted when received field changes
);

//-----------------------------------------------------------------------------
// Signal definitions
//

reg rx_f_now = 1'b0;    // holds F bit from most recent XYZ word
reg rx_f_prev = 1'b0;   // holds F bit from previous XYZ word

//
// field bit
//                                  
// The field bit keep track of the current field (even or odd). It loads from
// the rx_f_now value when ld_f is asserted during the time the flywheel is
// synchronizing with the incoming video. Otherwise, it toggles at the
// beginning of each field.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            f <= 1'b0;
        else
        begin
            if (ld_f) 
                f <= rx_f_now;
            else if (eav_next & inc_f)
                f <= ~f;
        end
    end
                    

//
// received video new field detection
//
// The rx_f_now register holds the field value for the current field.
// The rx_f_prev register holds the field value from the previous field. If
// there is a difference between these two registers, the new_rx_field signal
// is asserted. This informs the FSM that the received video has transitioned
// from one field to the next.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
        begin
            rx_f_now  <= 1'b0;
            rx_f_prev <= 1'b0;
        end
        else if (rx_xyz)
        begin
            rx_f_now  <= rx_field;
            rx_f_prev <= rx_f_now;
        end
    end

assign new_rx_field = rx_f_now ^ rx_f_prev;

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
Module description:

This module implement the finite state machine for the video flywheel. The FSM
synchronizes to the received video stream in two steps. 

First, the FSM syncs horizontally by waiting for a received SAV symbol. This
causes the FSM to reset the horizontal counter in the fly_hcnt module. After
receiving a SAV, the FSM checks the results by comparing the position of the
next received SAV with the expected location. If they match, then the FSM
assumes it is synchronized horizontally.

Next, the FSM syncs vertically. This is done by waiting for the received video
to change fields, as indicated by the F bit in the received TRS symbols. When
a field transition occurs, the vertical line counter in the fly_vcnt module
is updated to the correct count and the FSM asserts the lock signal to indicate
that it is synchronized with the video.

Once locked, the error detection logic continually compares the position and
contents of the received TRS symbols with the flywheel generated TRS symbols.
When the number of lines containing mismatched TRS symbols exceeds the MAX_ERRS
value over the observation window (defaults to 8 lines), the resync signal is
asserted. This causes the state machine to negate the lock signal and go
through the synchronization process again.

The FSM is designed to accomodate synchronous switching as defined by SMPTE
RP 168. This recommended practice defines one line per field in the vertical
blanking interval when it is allowed to switch the video stream between two
synchronous video sources. The video sources must be synchronized but minor
displacements of the EAV symbol on these switching lines is tolerated since the
switch sometimes induces minor errors on the line. During the switching
interval lines, errors in the position of the EAV symbol cause the FSM to
update the horizontal counter value immediately without going through the
normal synchronization process.

The FSM normally verifies that the received TRS symbol matches the flywheel 
generated TRS symbol by comparing the F, V, and H bits. However, previous
versions of the NTSC digital component video standards allowed the V bit to
fall early, anywhere between line 10 and line 20 for field 1 and lines
273 to 283 for the second field. These standards now specify that the V bit
must fall one lines 20 and 283, but also recommend that new equipment be
tolerant of the signal falling early. The FSM ignores the V bit transitioning
early.

The inputs to this module are:

clk: clock input

ce: clock enable

rst: synchronous reset

vid_f: Input video bit that carries the F signal during XYZ words.

vid_v: Input video bit that carries the V signal during XYZ words.

vid_h: Input video bit that carries the H signal during XYZ words.

rx_xyz: Asserted when the XYZ word is being processed by the flywheel.

fly_eav: Asserted when the XYZ word of an EAV is being generated by the flywheel.

fly_sav: Asserted when the XYZ word of an SAV is being generated by the flywheel.

fly_eav_next: Asserted the clock cycle before it is time for the flywheel to
generated an EAV symbol.

rx_eav: Asserted when the flywheel is receiving the XYZ word of an EAV.

rx_sav: Asserted when the flywheel is receiving the XYZ word of an SAV.

rx_eav_first: Asserted when the flywheel is receiving the first word of an EAV.

new_rx_field: From the new field detector in fly_field module. Asserted for the
duration of the first line of a new field.

xyz_err: Asserted when an error is detected in the received XYZ word.

std_locked: Asserted when autodetect module is locked to input video stream's
standard.

switch_interval: Asserted when the current video line is a synchronous
switching line.

xyz_f: F bit from flywheel generated XYZ word.

xyz_v: V bit from flywheel generated XYZ word.

xyz_h: H bit from flywheel generated XYZ word.

sloppy_v: Asserted one those lines when the status of the V bit is ambiguous.

The outputs of this module are:

lock: Asserted when the flywheel is locked to the input video stream.

ld_vcnt: Asserted during resync cycle to cause the vertical counter to load
with a new value at the start of a new field.

inc_vcnt: Asserted to cause the vertical counter to increment.

clr_hcnt: Asserted to cause the horizontal counter to reset.

resync_hcnt: Asserted during synchronous switching to cause the the horizontal
counter to update to the position of the new input video stream.

ld_std: Loads the flywheel's int_std register with the current video standard
code.

ld_f: Asserted during resynchronization to load the F bit.

clr_switch: This output clears the flywheel's switching_interval signal.
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_fly_fsm (
    input  wire         clk,            // clock input
    input  wire         ce,             // clock enable
    input  wire         rst,            // sync reset input
    input  wire         vid_f,          // video data F bit
    input  wire         vid_v,          // video data V bit
    input  wire         vid_h,          // video data H bit
    input  wire         rx_xyz,         // asserted during the XYZ word of a TRS symbol
    input  wire         fly_eav,        // asserted on XYZ word of flywheel generated EAV
    input  wire         fly_sav,        // asserted on XYZ word of flywheel generated SAV
    input  wire         fly_eav_next,   // asserted when flywheel will generate EAV starting with next word
    input  wire         fly_sav_next,   // asserted when flywheel will generate SAV starting with next word
    input  wire         rx_eav,         // asserted on XYZ word of received EAV
    input  wire         rx_sav,         // asserted on XYZ word of received SAV
    input  wire         rx_eav_first,   // asserted during the first word of a received EAV
    input  wire         new_rx_field,   // asserted when received field changes
    input  wire         xyz_err,        // asserted on parity error in XYZ word
    input  wire         std_locked,     // asserted by the autodetect unit when locked to video std
    input  wire         switch_interval,// asserted when in the synchronous switching interval
    input  wire         xyz_f,          // flywheel generated XYZ word F bit
    input  wire         xyz_v,          // flywheel generated XYZ word V bit
    input  wire         xyz_h,          // flywheel generated XYZ word H bit
    input  wire         sloppy_v,       // ignore V bit on XYZ comparison when asserted
    output reg          lock = 1'b0,    // asserted when flywheel is synchronized to video
    output reg          ld_vcnt,        // causes vcnt to load
    output reg          inc_vcnt,       // forces vcnt to increment during failed sync switch
    output reg          clr_hcnt,       // causes hcnt to clear
    output reg          resync_hcnt,    // reloads hcnt to SAV position during sync switch
    output reg          ld_std,         // loads the int_std register
    output reg          ld_f,           // loads the F bit
    output reg          clr_switch      // clears the switching_interval signal
);

//-----------------------------------------------------------------------------
// Parameter definitions
//

//
// This group of parameters defines the bit widths of various fields in the
// module.
//
// The ERRCNT_WIDTH must be big enough to generate a counter wide enough
// to accomodate error counts up to the MAX_ERRS value. It is recommended that
// one or two additional counts be available in the error counter above the
// MAX_ERRS value to prevent wrap around errors.
//
// The LSHIFT_WIDTH value dictates the number of lines in the error window. The
// default value of 32 provides a window of 32 lines over which the resync logic
// examines lines containing TRS errors. If the number of lines with errors
// exceeds MAX_ERRS over the error window, the FSM will be forced to
// resynchronize. It is recommended that the error window be larger than the
// vertical blanking interval and that the MAX_ERRS value never be set larger
// than 2, otherwise the flywheel will fail to resynchronize to a video stream
// that is offset by just a few lines from the current flywheel position.
//
//
parameter ERRCNT_WIDTH  = 3;                   // Width of errcnt
parameter LSHIFT_WIDTH  = 32;                  // Errored line shifter
 
localparam ERRCNT_MSB   = ERRCNT_WIDTH - 1;    // MS bit # of errcnt
localparam LSHIFT_MSB   = LSHIFT_WIDTH - 1;    // MS bit # of errored line shifter

parameter MAX_ERRS      = 2;                   // Max number of TRS errors allowed in window


//
// This group of parameters defines the states of the FSM.
//                                              
localparam STATE_WIDTH   = 4;
localparam STATE_MSB     = STATE_WIDTH - 1;

localparam [STATE_WIDTH-1:0]
    LOCK    = 0,
    HSYNC1  = 1,
    HSYNC2  = 2,
    FSYNC1  = 3,
    FSYNC2  = 4,
    FSYNC3  = 5,
    UNLOCK  = 6,
    SWITCH1 = 7,
    SWITCH2 = 8,
    SWITCH3 = 9,
    SWITCH4 = 10,
    SWITCH5 = 11,
    SWITCH6 = 12;

         
//-----------------------------------------------------------------------------
// Signal definitions
//

reg     [STATE_MSB:0]   current_state = UNLOCK;     // FSM current state
reg     [STATE_MSB:0]   next_state;                 // FSM next state
wire                    resync;                     // asserted to cause flywheel to resync
reg                     clr_resync;                 // reset resync logic
reg     [ERRCNT_MSB:0]  errcnt = 0;                 // resync error counter
reg     [LSHIFT_MSB:0]  lerr_shifter = 0;           // errored line shift register
reg                     line_err = 1'b0;            // SR flip-flop indicating error in this line
wire                    trs_err;                    // sets the line_err flip-flop
wire                    xyz_match;                  // asserted if flywheel XYZ word matches received data
reg                     set_lock;                   // sets the lock flip-flop
reg                     clr_lock;                   // clears the lock flip-flop
wire                    fly_xyz;                    // asserted when flywheel generates XYZ

//
// fly_xyz
//
// fly_xyz is asserted on the flywheel generated XYZ word
//
assign fly_xyz = fly_sav | fly_eav;

//
// lock
//
// This is the lock flip-flop. It is set and cleared by the state machine to
// indicate whether the flywheel is synchronized to the incoming video or not.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            lock <= 1'b0;
        else if (set_lock)
            lock <= 1'b1;
        else if (clr_lock)
            lock <= 1'b0;
    end

//
// resync logic
//
// The resync logic determines when it is time to resynchronize the flywheel.
// An SR flip-flop is set if a TRS error is detected on the current line. At
// the end of the line, when fly_eav_next is asserted, the contents of the SR
// flip-flop are shifted into the lerr_shifter and the flip-flop is cleared.
// 
// The lerr_shifter contains one bit for each line in the "window" over which
// the resync mechanism operates. The shifter shifts one bit position at the 
// end of each line. The output bit of the shifter will cause the errcnt to 
// decrement if it is asserted because a line with an error has moved out of
// the error window.
//
// The errcnt is a counter that increments at the end of every line in which
// a TRS error is detected (when the line_err SR flip-flop is asserted). It
// decrements if the output bit of the shifter is asserted. In this way,
// it keeps track of the number of lines in the current window that had TRS
// errors. If the errcnt value exceeds the maximum number of allowed errors in
// the window, the resync signal is asserted.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst | fly_eav_next | clr_resync)
            line_err <= 1'b0;
        else if (trs_err)
            line_err <= 1'b1;
    end
        
always @ (posedge clk)
    if (ce)
    begin
        if (rst | clr_resync)
            lerr_shifter <= 0;
        else if (fly_eav_next)
            lerr_shifter <= {lerr_shifter[LSHIFT_MSB - 1:0], line_err};
    end
        
always @ (posedge clk)
    if (ce)
    begin
        if (rst | clr_resync)
            errcnt <= 0;
        else if (fly_eav_next)
            begin
                if (line_err & !lerr_shifter[LSHIFT_MSB])
                    errcnt <= errcnt + 1;
                else if (!line_err & lerr_shifter[LSHIFT_MSB])
                    errcnt <= errcnt - 1;
            end
    end
        
assign resync = (errcnt >= MAX_ERRS);

//
// trs_err
//
// This signal is asserted when the received word is misplaced relative to the
// flywheel's TRS location or if the received TRS XYZ word doesn't match
// the flywheel's generated values. This signal tells resync logic than an
// error occurred.
//
assign trs_err = (~fly_xyz & rx_xyz) | 
                 (fly_xyz & rx_xyz & (~xyz_match | xyz_err));

//
// xyz_match logic
// 
// This logic compares the received XYZ word with the flywheel generated XYZ
// word to determine if they match. Only the F, V, and H bits of these words
// are compared. If the sloppy_v signal is asserted, then the V bit is ignored.
//

assign xyz_match = ~( vid_f ^ xyz_f |                   // F bit compare
                    ((vid_v ^ xyz_v) & ~sloppy_v) |     // V bit compare
                      vid_h ^ xyz_h);                   // H bit compare  

// FSM
//
// The finite state machine is implemented in three processes, one for the
// current_state register, one to generate the next_state value, and the
// third to decode the current_state to generate the outputs.
 
//
// FSM: current_state register
//
// This code implements the current state register. It loads with the HSYNC1
// state on reset and the next_state value with each rising clock edge.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            current_state <= UNLOCK;
        else
            current_state <= next_state;
    end

//
// FSM: next_state logic
//
// This case statement generates the next_state value for the FSM based on
// the current_state and the various FSM inputs.
//
always @ (*)
    case(current_state)
        LOCK:   if (~std_locked)
                    next_state = UNLOCK;
                else if (resync)
                    next_state = HSYNC1;
                else if (switch_interval)
                    next_state = SWITCH1;
                else
                    next_state = LOCK;
                

        HSYNC1: if (~rx_sav)
                    next_state = HSYNC1;
                else if (fly_sav)
                    next_state = FSYNC1;
                else
                    next_state = HSYNC2;

        HSYNC2: next_state = HSYNC1;

        FSYNC1: if (~fly_eav)
                    next_state = FSYNC1;
                else if (~rx_eav)
                    next_state = HSYNC1;
                else if (xyz_err)
                    next_state = FSYNC1;
                else
                    next_state = FSYNC2;

        FSYNC2: if (new_rx_field)
                    next_state = FSYNC3;
                else
                    next_state = FSYNC1;

        FSYNC3: next_state = LOCK;

        UNLOCK: if (~std_locked)
                    next_state = UNLOCK;
                else
                    next_state = HSYNC1;

        SWITCH1: if (~std_locked)
                    next_state = UNLOCK;
                 else if (rx_eav_first)
                    next_state = SWITCH2;
                 else if (fly_eav_next)
                    next_state = SWITCH5;
                 else
                    next_state = SWITCH1;

        SWITCH2: next_state = SWITCH3;

        SWITCH3: next_state = SWITCH4;

        SWITCH4: next_state = LOCK;

        SWITCH5: if (rx_eav_first)
                    next_state = LOCK;
                 else
                    next_state = SWITCH6;

        SWITCH6: if (rx_eav_first)
                    next_state = SWITCH2;
                 else if (fly_sav_next)
                    next_state = UNLOCK;
                 else
                    next_state = SWITCH6;
                    
        default: next_state = HSYNC1;
    endcase

        
//
// FSM: outputs
//
// This block decodes the current state to generate the various outputs of the
// FSM.
//
always @ (*)
begin
    // Unless specifically assigned in the case statement, all FSM outputs
    // are low.
    clr_resync      = 1'b0;
    ld_vcnt         = 1'b0;
    clr_hcnt        = 1'b0;
    resync_hcnt     = 1'b0;
    ld_vcnt         = 1'b0;
    set_lock        = 1'b0;
    clr_lock        = 1'b0;
    ld_std          = 1'b0;
    ld_f            = 1'b0;
    clr_switch      = 1'b0;
    inc_vcnt        = 1'b0;
                            
    case(current_state)     
        LOCK:   set_lock = 1'b1;

        HSYNC1: begin
                    clr_lock = 1'b1;
                    ld_std   = 1'b1;
                end

        HSYNC2: clr_hcnt  = 1'b1;

        FSYNC3: begin
                    ld_vcnt    = 1'b1;
                    ld_f       = 1'b1;
                    clr_resync = 1'b1;
                end

        UNLOCK: begin
                    clr_lock = 1'b1;
                    clr_switch = 1'b1;
                end

        SWITCH2: resync_hcnt = 1'b1;
                 
        SWITCH4: clr_switch = 1'b1;

        SWITCH6: if (fly_sav_next)
                    begin
                        clr_switch = 1'b1;
                        inc_vcnt   = 1'b1;
                    end
                else
                    begin
                        clr_switch = 1'b0;
                        inc_vcnt   = 1'b0;
                    end

    endcase
end

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/* 
This module implements the horizontal logic for the video flywheel.

The module contains the horizontal counter. This counter keeps track of the
current horizontal position of the video. The module also generates the H 
signal. The H signal is asserted during the inactive portion of each scan line.

This module has the following inputs:

clk: clock input

rst: synchronous reset

ce: clock enable

clr_hcnt: When this input is asserted, the horizontal counter is cleared.

resync_hcnt: When this input is asserted, the horizontal counter is reloaded
with the position of the EAV symbol. This happens during synchronous switches.

std: The video standard input code.

The module generates the following outputs:

hcnt: This is the value of the horizontal counter and indicates the current
horizontal positon of the video.

eav_next: Asserted the clock cycle before it is time for the flywheel to
generate the first word of an EAV symbol.

sav_next: Asserted the clock cycle before it is time for the flywheel to 
generate the first word of an SAV symbol.

h: This is the horizontal blanking bit.

trs_word: A 2-bit code indicating which word of the TRS symbol should be
generated by the flywheel.

fly_trs: Asserted during the first word of a flywheel generated TRS symbol.

fly_eav: Asserted during the XYZ word of a flywheel generated EAV symbol.

fly_sav: Asserted during the XYZ word of a flywheel generated SAV symbol.
*/

`timescale 1ns / 1ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_fly_horz #(
    parameter HCNT_WIDTH = 12)
(
    input  wire                     clk,            // clock input
    input  wire                     rst,            // sync reset input
    input  wire                     ce,             // clock enable
    input  wire                     clr_hcnt,       // clears the horizontal counter
    input  wire                     resync_hcnt,    // resynchronized horizontal counter during sync switch
    input  wire [2:0]               std,            // indicates current video standard
    output wire [HCNT_WIDTH-1:0]    hcnt,           // horizontal count
    output wire                     eav_next,       // asserted when next word is first word of EAV symbol
    output wire                     sav_next,       // asserted when next word is first word of SAV symbol
    output reg                      h = 1'b0,       // horizontal blanking bit
    output reg  [1:0]               trs_word = 0,   // indicates which word of the TRS symbol is being generated
    output wire                     fly_trs,        // asserted during first word of a flywheel generated TRS
    output wire                     fly_eav,        // asserted during xyz word of a flywheel generated EAV
    output wire                     fly_sav         // asserted during xyz word of a flywheel generated SAV
);

//-----------------------------------------------------------------------------
// Parameter definitions
//

localparam HCNT_MSB = HCNT_WIDTH - 1;

//
// This group of parameters defines the starting position of the EAV symbol
// for the various supported video standards.
//
localparam EAV_LOC_NTSC_422          = 1440;
localparam EAV_LOC_NTSC_COMPOSITE    = 790;
localparam EAV_LOC_NTSC_422_WIDE     = 1920;
localparam EAV_LOC_NTSC_4444         = 2880;
localparam EAV_LOC_PAL_422           = 1440;
localparam EAV_LOC_PAL_COMPOSITE     = 972;
localparam EAV_LOC_PAL_422_WIDE      = 1920;
localparam EAV_LOC_PAL_4444          = 2880;

//
// This group of parameters defines the starting position of the SAV symbol
// for the various supported video standards.
//
localparam SAV_LOC_NTSC_422          = 1712;
localparam SAV_LOC_NTSC_COMPOSITE    = 790;
localparam SAV_LOC_NTSC_422_WIDE     = 2284;
localparam SAV_LOC_NTSC_4444         = 3428;
localparam SAV_LOC_PAL_422           = 1724;
localparam SAV_LOC_PAL_COMPOSITE     = 972;
localparam SAV_LOC_PAL_422_WIDE      = 2300;
localparam SAV_LOC_PAL_4444          = 3452;

//
// This group of parameters defines the encoding for the video standards output
// code.
//
localparam [2:0]
    NTSC_422        = 3'b000,
    NTSC_INVALID    = 3'b001,
    NTSC_422_WIDE   = 3'b010,
    NTSC_4444       = 3'b011,
    PAL_422         = 3'b100,
    PAL_INVALID     = 3'b101,
    PAL_422_WIDE    = 3'b110,
    PAL_4444        = 3'b111;

//-----------------------------------------------------------------------------
// Signal definitions
//
reg     [HCNT_MSB:0]    hcount = 1;     // horizontal counter
wire                    trs_next;       // TRS symbol starts on next count
reg                     trs = 1'b0;     // internal version of fly_trs signal
reg                     fly_xyz = 1'b0; // asserted during flywheel generated XYZ word
reg     [HCNT_MSB:0]    eav_loc;        // EAV location
reg     [HCNT_MSB:0]    sav_loc;        // SAV location
reg     [HCNT_MSB:0]    resync_val;     // value to load on resync_hcnt

//
// hcount: horizontal counter
//
// The horizontal counter increments every clock cycle to keep track of the
// current horizontal position. If clr_hcnt is asserted by the FSM, hcnt is
// reloaded with a value of 1. A value of 1 is used because of the latency
// involved in detected the TRS symbol and deciding whether to clear hcnt or
// not. If resync_hcnt is asserted, the horizontal coutner is loaded with
// resync_val, a value derived from the EAV position. This happens during
// synchronous switches. 
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            hcount <= 1;
        else if (resync_hcnt)
            hcount <= resync_val;
        else if (clr_hcnt)
            hcount <= 1;
        else if (fly_sav)
            hcount <= 0;
        else
            hcount <= hcount + 1;
    end

//
// TRS word counter
//
// The TRS word counter is used to count out the words of a TRS symbol. A
// TRS symbol for component video is four words long.
//
// During the TRS symbol the trs signal is asserted. During the XYZ word of
// a component video signal fly_xyz is asserted and one of fly_sav or fly_eav.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst | trs_next)
            trs_word <= 0;
        else
            trs_word <= trs_word + 1;
    end

always @ (posedge clk)
    if (ce)
    begin
        if (rst | clr_hcnt | fly_xyz | resync_hcnt)
            trs <= 1'b0;
        else if (trs_next)
            trs <= 1'b1;
    end
        
always @ (posedge clk)
    if (ce)
    begin
        if (rst | clr_hcnt)
            fly_xyz <= 1'b0;
        else if (trs && (trs_word == 2'b10))
            fly_xyz <= 1'b1;
        else
            fly_xyz <= 1'b0;
    end
        
assign fly_eav = fly_xyz & h;
assign fly_sav = fly_xyz & ~h;

//
// TRS location detection
//
// This block of code generates the eav_next and sav_next signals. These signals
// are asserted the state before the flywheel will generate the first word of
// the EAV or SAV TRS symbols.
//
always @ (*)
    case (std)
        NTSC_422:
            begin
                eav_loc = EAV_LOC_NTSC_422 - 1;
                sav_loc = SAV_LOC_NTSC_422 - 1;
                resync_val = EAV_LOC_NTSC_422 + 2;
            end

        NTSC_422_WIDE:
            begin
                eav_loc = EAV_LOC_NTSC_422_WIDE - 1;
                sav_loc = SAV_LOC_NTSC_422_WIDE - 1;
                resync_val = EAV_LOC_NTSC_422_WIDE + 2;
            end

        NTSC_4444:
            begin
                eav_loc = EAV_LOC_NTSC_4444 - 1;
                sav_loc = SAV_LOC_NTSC_4444 - 1;
                resync_val = EAV_LOC_NTSC_4444 + 2;
            end

        PAL_422:
            begin
                eav_loc = EAV_LOC_PAL_422 - 1;
                sav_loc = SAV_LOC_PAL_422 - 1;
                resync_val = EAV_LOC_PAL_422 + 2;
            end

        PAL_422_WIDE:
            begin
                eav_loc = EAV_LOC_PAL_422_WIDE - 1;
                sav_loc = SAV_LOC_PAL_422_WIDE - 1;
                resync_val = EAV_LOC_PAL_422_WIDE + 2;
            end

        PAL_4444:
            begin
                eav_loc = EAV_LOC_PAL_4444 - 1;
                sav_loc = SAV_LOC_PAL_4444 - 1;
                resync_val = EAV_LOC_PAL_4444 + 2;
            end

        default:
            begin
                eav_loc = EAV_LOC_NTSC_422 - 1;
                sav_loc = SAV_LOC_NTSC_422 - 1;
                resync_val = EAV_LOC_NTSC_422 + 2;
            end

    endcase

assign eav_next = (hcount == eav_loc);
assign sav_next = (hcount == sav_loc);
assign trs_next = eav_next | sav_next;

//
// h
//
// This logic generates the H bit for the TRS XYZ word. The H bit becomes
// asserted at the start of EAV and is negated at the start of SAV. Note that
// the h_blank output from the flywheel module is similar to the H bit, but 
// remains asserted until after the last word of the SAV.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            h <= 1'b0;
        else if (eav_next | resync_hcnt)
            h <= 1'b1;
        else if (sav_next| clr_hcnt)
            h <= 1'b0;
    end

//
// output assignments
//
assign fly_trs = trs;
assign hcnt = hcount;

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/* 
This module implements the vertical functions of the video flywheel.

This module contains the vertical counter. This counter keeps track of the
current video scan line. The module also generates the V signal. This signal
is asserted during the vertical blanking interval of each field.

This module has the following inputs:

clk: clock input

rst: synchronous reset input

ce: clock enable

ntsc: Asserted when the input video stream is NTSC.

ld_vcnt: This input causes the vertical counter to load the value of the first
line of the current field.

fsm_inc_vcnt: This input is asserted by the FSM to force the vertical counter
to increment during a failed synchronous switch.

eav_next: Asserted the clock cycle before the first word of a flywheel generated
EAV symbol.

clr_switch: Causes the switch_interval output to be negated.

rx_f: This signal carries the F bit from the input video stream during XYZ 
words.

f: This is the flywheel generated F bit.

fly_sav: Asserted during the XYZ word of a flywheel generated SAV.

fly_eav: Asserted during the XYZ word of a flywheel generated EAV.

rx_eav_first: Asserted during the first word of an EAV in the input video 
stream.

lock: Asserted when the flywheel is locked.

This module generates the following outputs:

vcnt: This is the value of the vertical counter indicating the current video
line number.

v: This is the vertical blanking bit asserted during the vertical blanking
interval.

sloppy_v: This signal is asserted on those lines where the V bit may fall early.

inc_f: Toggles the F bit when asserted.

switch_interval: Asserted when the current line contains the synchronous
switching interval.
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_fly_vert #(
    parameter VCNT_WIDTH = 10)
(
    input  wire                     clk,                    // clock input
    input  wire                     rst,                    // sync reset input
    input  wire                     ce,                     // clock enable input
    input  wire                     ntsc,                   // 1 = NTSC, 0 = PAL
    input  wire                     ld_vcnt,                // causes vert counter to load
    input  wire                     fsm_inc_vcnt,           // forces vert counter to increment during failed sync switch
    input  wire                     eav_next,               // asserted when next word is first word of a flywheel EAV
    input  wire                     clr_switch,             // clears the switch_interval signal
    input  wire                     rx_f,                   // received F bit
    input  wire                     f,                      // flywheel generated field bit
    input  wire                     fly_sav,                // asserted during first word of flywheel generated SAV
    input  wire                     fly_eav,                // asserted during first word of flywheel generated EAV
    input  wire                     rx_eav_first,           // asserted during first word of received EAV
    input  wire                     lock,                   // asserted when flywheel is locked
    output wire [VCNT_WIDTH-1:0]    vcnt,                   // vertical counter
    output reg                      v = 1'b0,               // vertical blanking bit indicator
    output reg                      sloppy_v = 1'b0,        // asserted when FSM should ignore V bit in XYZ comparison
    output wire                     inc_f,                  // toggles the F bit when asserted
    output reg                      switch_interval = 1'b0  // asserted when current line is a sync switching line
);

//-----------------------------------------------------------------------------
// Parameter definitions
//
localparam VCNT_MSB      = VCNT_WIDTH - 1;       // MS bit # of vcnt

//
// This group of parameters defines the synchronous switching interval lines.
//
localparam NTSC_FLD1_SWITCH          = 10;
localparam NTSC_FLD2_SWITCH          = 273;
localparam PAL_FLD1_SWITCH           = 6;
localparam PAL_FLD2_SWITCH           = 319;
    
//
// This group of parameters defines the ending positions of the fields for
// NTSC and PAL.
//
localparam NTSC_FLD1_END             = 265;
localparam NTSC_FLD2_END             = 3;
localparam PAL_FLD1_END              = 312;
localparam PAL_FLD2_END              = 625;
localparam NTSC_V_TOTAL              = 525;
localparam PAL_V_TOTAL               = 625;
    
//
// This group of parameters defines the starting and ending active portions of
// of the fields.
//
localparam NTSC_FLD1_ACT_START       = 20;
localparam NTSC_FLD1_ACT_END         = 263;
localparam NTSC_FLD2_ACT_START       = 283;
localparam NTSC_FLD2_ACT_END         = 525;
localparam PAL_FLD1_ACT_START        = 23;
localparam PAL_FLD1_ACT_END          = 310;
localparam PAL_FLD2_ACT_START        = 336;
localparam PAL_FLD2_ACT_END          = 623;
         
//
// This group of parameters defines the starting lines on which it is possible
// for the V bit to change early. This is due to previous versions of the
// specifications that allowed for an early transition from 1 to 0 on the V
// bit. This only occurs in the NTSC specifications. The period of ambiguity
// on the V bit ends with the first active video line of each field as
// defined above.
//
localparam SLOPPY_V_START_FLD1       = 10;
localparam SLOPPY_V_START_FLD2       = 273;


//-----------------------------------------------------------------------------
// Signal definitions
//
reg     [VCNT_MSB:0]    vcount = 1;     // vertical counter
wire                    clr_vcnt;       // clears the vertical counter
reg     [VCNT_MSB:0]    new_vcnt;       // new value to load into vcount                
reg     [VCNT_MSB:0]    fld1_switch;    // synchronous switching line for field 1
reg     [VCNT_MSB:0]    fld2_switch;    // synchronous switching line for field 2
wire    [VCNT_MSB:0]    fld_switch;     // synchronous switching line for current field
wire                    switch_line;    // asserted when vcnt == fld_switch
wire    [VCNT_MSB:0]    v_total;        // total vertical lines for this video standard
reg     [VCNT_MSB:0]    fld1_act_start; // starting line of active video in field 1
reg     [VCNT_MSB:0]    fld1_act_end;   // ending line of active video in field 1
reg     [VCNT_MSB:0]    fld2_act_start; // starting line of active video in field 2
reg     [VCNT_MSB:0]    fld2_act_end;   // ending line of active video in field 2
wire    [VCNT_MSB:0]    fld_act_start;  // starting line of active video in current field
wire    [VCNT_MSB:0]    fld_act_end;    // ending line of active video in current field
wire                    act_start;      // result of comparing vcnt and fld_act_start
reg     [VCNT_MSB:0]    fld1_end;       // line count for end of field 1
reg     [VCNT_MSB:0]    fld2_end;       // line count for end of field 2
wire    [VCNT_MSB:0]    fld_end;        // line count for end of current field
wire    [VCNT_MSB:0]    sloppy_start;   // starting position of V bit ambiguity period

//
// vcnt: vertical counter
//
// The vertical counter increments once per line to keep track of the current
// vertical position. If clr_vcnt is asserted, vcnt is loaded with a value of
// 1. If ld_vcnt is asserted, the new_vcnt value is loaded into vcnt. If the
// state machine asserts the fsm_inc_vcnt signal indicating a synchronous
// switch event, then the vcnt must be forced to increment since the received
// EAV came before the flywheel's generated EAV, causing the hcnt to be updated
// to a position after the EAV and thus skipping the normal inc_vcnt signal
// that comes with the flywheel's EAV.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            vcount <= 1;
        else if (ld_vcnt)
            vcount <= new_vcnt;
        else if (fsm_inc_vcnt | ((lock & switch_interval) ? rx_eav_first : eav_next))
        begin
            if (clr_vcnt)
                vcount <= 1;
            else
                vcount <= vcount + 1;
        end
    end

assign v_total = ntsc ? NTSC_V_TOTAL : PAL_V_TOTAL;
assign clr_vcnt = (vcount == v_total);
assign vcnt = vcount;

always @ (*)
    if (ntsc)
    begin
        if (rx_f)
            new_vcnt = NTSC_FLD1_END + 1;
        else
            new_vcnt = NTSC_FLD2_END + 1;
    end
    else
    begin
        if (rx_f)
            new_vcnt = PAL_FLD1_END + 1;
        else
            new_vcnt = 1;
    end


//
// synchronous switching line detector
//
// This code determines when the current line is a line during which
// it is permitted to switch between synchronous video sources. These sources
// may have a small amount of offset. The flywheel will immediately 
// resynchronize to the new signal on the synchronous switching lines without
// the usual flywheel induced delay.
//
always @ (*)
    if (ntsc)
    begin
        fld1_switch <= NTSC_FLD1_SWITCH;
        fld2_switch <= NTSC_FLD2_SWITCH;
    end
    else
    begin
        fld1_switch <= PAL_FLD1_SWITCH;
        fld2_switch <= PAL_FLD2_SWITCH;
    end

assign fld_switch = f ? fld2_switch : fld1_switch;

assign switch_line = (vcount == fld_switch);

always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            switch_interval <= 1'b0;
        else if (switch_interval ? clr_switch : fly_eav)
            switch_interval <= 1'b0;
        else if (fly_sav)
            switch_interval <= switch_line;
    end

//
// v
//
// This logic generates the V bit for the TRS XYZ word. The V bit is asserted
// in the TRS symbols of all lines in the vertical blanking interval. It is
// generated by comparing the vcnt starting and ending positions of the
// current field at the beginning of the EAV symbol. Whenever the state 
// machine reloads the field counter by asserted ld_f, the v flag should be
// set because the field counter is only reloaded in the vertical blanking
// interval.
//
always @ (*)
    if (ntsc)
    begin
        fld1_act_start = NTSC_FLD1_ACT_START - 1;
        fld1_act_end   = NTSC_FLD1_ACT_END;
        fld2_act_start = NTSC_FLD2_ACT_START - 1;
        fld2_act_end   = NTSC_FLD2_ACT_END;
    end
    else
    begin
        fld1_act_start = PAL_FLD1_ACT_START - 1;
        fld1_act_end   = PAL_FLD1_ACT_END;
        fld2_act_start = PAL_FLD2_ACT_START - 1;
        fld2_act_end   = PAL_FLD2_ACT_END;
    end

assign fld_act_start = f ? fld2_act_start : fld1_act_start;
assign fld_act_end   = f ? fld2_act_end   : fld1_act_end;
assign act_start = vcnt == fld_act_start;

always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            v <= 1'b0;
        else if (ld_vcnt)
            v <= 1'b1;
        else if (eav_next)
            begin
                if (vcnt == fld_act_start)
                    v <= 1'b0;
                else if (vcnt == fld_act_end)
                    v <= 1'b1;
            end
    end

//
// inc_f
//
// This logic determines when to toggle the F bit.
//
always @ (*)
    if (ntsc)
    begin
        fld1_end = NTSC_FLD1_END;
        fld2_end = NTSC_FLD2_END;
    end
    else
    begin
        fld1_end = PAL_FLD1_END;
        fld2_end = PAL_FLD2_END;
    end

assign fld_end = f ? fld2_end : fld1_end;
assign inc_f = (vcnt == fld_end);

//
// sloppy_v
//
// This signal is asserted during the interval when the V bit should be
// ignored in XYZ comparisons due to ambiguity in earlier versions of the
// NTSC digital video specifications.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst | ld_vcnt | ~ntsc)
            sloppy_v <= 1'b0;
        else
        begin
            if (vcnt == sloppy_start)
                sloppy_v <= 1'b1;
            else if (eav_next & act_start)
                sloppy_v <= 1'b0;
        end
    end

assign sloppy_start = f ? SLOPPY_V_START_FLD2 : SLOPPY_V_START_FLD1;

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/* 
This module implements a video flywheel. Video flywheels are used to add
immunity to noise introduced into a video stream.

The flywheel synchronizes to the incoming video by examining the TRS symbols. It
then maintains internal horizontal and vertical counters to keep track of the
current position. The flywheel generates its own TRS symbols and compares them
to the incoming video. If the position or contents of the TRS symbols in the
incoming video doesn't match the flywheel's generated TRS symbols for a certain
period of time, the flywheel will resynchronize to the incoming video.

This module has the following inputs:

clk: clock input

ce: clock enable input

rst: synchronous reset input

rx_xyz_in: Asserted when rx_vid_in contains the XYZ word of a TRS symbol.

rx_trs_in: Asserted when rx_vid_in contains the first word of a TRS symbol.

rx_eav_first_in: Asserted when rx_vid_in contains the first word of an EAV.

rx_f_in: This is the latched F bit from the trs_detect module

rx_h_in: This is the latched H bit from the trs_detect module.

std_locked: When this signal is asserted the std_in code is assumed to be valid.

std_in: A three bit code indicating the video standard of the input video 
stream.

rx_xyz_err_in: This input indicates an error in the XYZ word. It is only
considered to be valid when rx_xyz_in is asserted.

rx_vid_in: This is the input port for the input video stream.

rx_s4444_in: This input is the S bit from the XYZ word of a 4:4:4:4 video 
stream.

rx_anc_in:  Asserted when rx_vid_in contains the first word of an ANC packet.

rx_edh_in: Asserted when rx_vid_in contains the first word of an EDH packet.

en_sync_switch: When this input is asserted, the flywheel will allow
synchronous switching.

en_trs_blank: When this input is asserted, the TRS blanking feature is enabled.
When this is enabled, TRS symbols from the input video stream are replaced with
black level video values if that TRS symbol does not occur when the flywheel
expects a TRS to occur.

This module has the following outputs:

trs: Asserted during all four words of a TRS symbol.

vid_out: This is the output video port.

field: This is the field indicator bit.

v_blank: Vertical blanking interval indicator.

h_blank: Horizontal blanking interval indicator.

horz_count: Current horizontal position of the video stream.

vert_count: Current vertical position of the video stream.

sync_switch: Asserted on lines when synchronous switching is allowed. This 
output should be used to disable TRS filtering in the framer of an SDI receiver
during the synchronous switching lines.

locked: This output is asserted when the flywheel is locked to the incoming
video stream.

eav_next: This output is asserted the clock cycle before the first word of an
EAV appears on vid_out.

sav_next: This output is asserted the clock cycle before the first word of an
SAV appears on vid_out.

xyz_word: This output is asserted clock cycle when vid_out contains the XYZ
word of a TRS symbol.

anc_next: This output is asserted the clock cycle before the first word of an
ancillary data packet appears on vid_out.

edh_next: This output is asserted the clock cycle before the first word of an
EDH packet appears on vid_out.

*/

`timescale 1ns / 1ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_flywheel #(
    parameter HCNT_WIDTH = 12,
    parameter VCNT_WIDTH = 10)
(
    input  wire                 clk,                // clock input
    input  wire                 ce,                 // clock enable
    input  wire                 rst,                // sync reset input
    input  wire                 rx_xyz_in,          // input asserted during the XYZ word of a TRS symbol
    input  wire                 rx_trs_in,          // input asserted during first word of received TRS symbol
    input  wire                 rx_eav_first_in,    // input asserted during first word of received EAV symbol
    input  wire                 rx_f_in,            // decoded F bit from received video
    input  wire                 rx_v_in,            // decoded V bit from received video
    input  wire                 rx_h_in,            // decoded H bit from received video
    input  wire                 std_locked,         // asserted by the autodetect unit when locked to video std
    input  wire [2:0]           std_in,             // input code for the current video standard
    input  wire                 rx_xyz_err_in,      // input asserted on parity error in XYZ word
    input  wire [9:0]           rx_vid_in,          // input video word
    input  wire                 rx_s4444_in,        // S bit for 4444 video
    input  wire                 rx_anc_in,          // asserted on first word of received ANC
    input  wire                 rx_edh_in,          // asserted on first word of received EDH
    input  wire                 en_sync_switch,     // enables synchronous switching when asserted
    input  wire                 en_trs_blank,       // enables TRS blanking when asserted
    output reg                  trs = 1'b0,         // asserted during TRS symbol
    output reg [9:0]            vid_out = 0,        // video stream out
    output reg                  field = 1'b0,       // field indicator
    output reg                  v_blank = 1'b0,     // vertical blanking bit
    output reg                  h_blank = 1'b0,     // horizontal blanking bit
    output reg [HCNT_WIDTH-1:0] horz_count = 0,     // current horizontal count
    output reg [VCNT_WIDTH-1:0] vert_count = 0,     // current vertical count
    output reg                  sync_switch = 1'b0, // asserted on lines where synchronous switching is allowed
    output reg                  locked = 1'b0,      // asserted when flywheel is synchronized to video
    output reg                  eav_next = 1'b0,    // next word is first word of EAV
    output reg                  sav_next = 1'b0,    // next word is first word of SAV
    output reg                  xyz_word = 1'b0,    // current word is the XYZ word of a TRS
    output wire                 anc_next,           // next word is first word of a received ANC
    output wire                 edh_next            // next word is first word of a received EDH
);


//-----------------------------------------------------------------------------
// Parameter definitions
//
parameter HCNT_MSB      = HCNT_WIDTH - 1;       // MS bit # of hcnt
parameter VCNT_MSB      = VCNT_WIDTH - 1;       // MS bit # of vcnt


//
// This group of parameters defines the encoding for the video standards output
// code.
//
parameter [2:0]
    NTSC_422        = 3'b000,
    NTSC_INVALID    = 3'b001,
    NTSC_422_WIDE   = 3'b010,
    NTSC_4444       = 3'b011,
    PAL_422         = 3'b100,
    PAL_INVALID     = 3'b101,
    PAL_422_WIDE    = 3'b110,
    PAL_4444        = 3'b111;


//
// This group of parameters defines the component video values that will be
// used to blank TRS symbols when TRS blanking.
//
parameter YCBCR_4444_BLANK_Y    = 10'h040;
parameter YCBCR_4444_BLANK_CB   = 10'h200;
parameter YCBCR_4444_BLANK_CR   = 10'h200;
parameter YCBCR_4444_BLANK_A    = 10'h040;

parameter RGB_4444_BLANK_R      = 10'h040;
parameter RGB_4444_BLANK_G      = 10'h040;
parameter RGB_4444_BLANK_B      = 10'h040;
parameter RGB_4444_BLANK_A      = 10'h040;

parameter YCBCR_422_BLANK_Y     = 10'h040;
parameter YCBCR_422_BLANK_C     = 10'h200;
         
//-----------------------------------------------------------------------------
// Signal definitions
//
reg                     rx_xyz = 1'b0;          // input register for rx_xyz_in
reg                     rx_trs = 1'b0;          // input register for rx_trs_in
reg                     rx_eav_first = 1'b0;    // input register for rx_eav_first_in
reg                     rx_xyz_err = 1'b0;      // input register for rx_xyz_err_in
reg                     rx_s4444 = 1'b0;        // input register for rx_s4444_in
reg     [9:0]           rx_vid = 1'b0;          // input register for rx_vid_in
reg                     rx_f = 1'b0;            // input register for rx_f_in
reg                     rx_v = 1'b0;            // input register for rx_v
reg                     rx_h = 1'b0;            // input register for rx_h_in
reg                     rx_anc = 1'b0;          // input register for rx_anc_in
reg                     rx_edh = 1'b0;          // input register for rx_edh_in
wire    [HCNT_MSB:0]    hcnt;                   // horizontal counter
wire    [VCNT_MSB:0]    vcnt;                   // vertical counter
wire                    fly_eav_next;           // EAV symbol starts on next count
wire                    fly_sav_next;           // SAV symbol starts on next count
wire    [1:0]           trs_word;               // counts length of TRS symbol
wire                    fly_trs;                // asserted during all words of flywheel TRS
wire                    trs_d;                  // input to trs output flip-flop
wire                    v_blank_d;              // input to v_blank output flip-flop
wire                    h_blank_d;              // input to h_blank output flip-flop
wire                    fly_eav;                // asserted on XYZ word of flywheel generated EAV
wire                    fly_sav;                // asserted on XYZ word of flywheel generated SAV
wire                    rx_eav;                 // asserted on XYZ word of received EAV
wire                    rx_sav;                 // asserted on XYZ word of received SAV
wire                    f;                      // field bit
wire                    v;                      // vertical blanking bit
wire                    h;                      // horizontal blanking bit
reg     [9:0]           xyz;                    // flywheel generated TRS XYZ word
wire                    new_rx_field;           // asserted when received field changes
wire                    ld_vcnt;                // loads vcnt
wire                    inc_vcnt;               // forces vertical counter to increment
wire                    clr_hcnt;               // reloads hcnt 
wire                    resync_hcnt;            // resynchronized hcnt during sync switch
wire                    ld_f;                   // loads field bit
wire                    inc_f;                  // toggles field bit
reg                     ntsc;                   // 1 = NTSC, 0 = PAL
wire                    lock;                   // internal version of locked output
reg     [2:0]           std = NTSC_422;         // register for the std_in inputs
wire                    ld_std;                 // loads the std register
wire                    switch_interval;        // asserted from SAV to EAV of switch line
wire                    sw_int;                 // qualified version of switch_interval
reg     [9:0]           fly_vid;                // flywheel video
wire                    clr_switch;             // clears the switch_interval signal
reg     [2:0]           rx_trs_delay = 3'b0;    // used to generate rx_trs_all4
wire                    rx_trs_all4;            // extended rx_trs, asserted for all 4 words
wire                    rx_field;               // the F bit from the received XYZ word
wire                    use_rx;                 // use decoded RX video info when asserted
wire                    use_fly;                // use flywheel generated video when asserted
wire                    sloppy_v;               // when asserted, V bit is ignored in XYZ comparisons
wire                    xyz_word_d;             // used to create the xyz output
wire                    is_ntsc;
wire                    is_422;

//
// input register for signals from trs_detect
//
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
        begin
            rx_xyz <= 0;
            rx_trs <= 0;
            rx_eav_first <= 0;
            rx_xyz_err <= 0;
            rx_s4444 <= 0;
            rx_vid <= 0;
            rx_f <= 0;
            rx_v <= 0;
            rx_h <= 0;
            rx_anc <= 0;
            rx_edh <= 0;
        end
        else
        begin
            rx_xyz <= rx_xyz_in;
            rx_trs <= rx_trs_in;
            rx_eav_first <= rx_eav_first_in;
            rx_xyz_err <= rx_xyz_err_in;
            rx_s4444 <= rx_s4444_in;
            rx_vid <= rx_vid_in;
            rx_f <= rx_f_in;
            rx_v <= rx_v_in;
            rx_h <= rx_h_in;
            rx_anc <= rx_anc_in;
            rx_edh <= rx_edh_in;
        end
    end


// 
// fly_horz instantiation
//
// The fly_horz module contains the horizontal functions of the flywheel. It
// generates the horizontal count and the H bit.It also generates several
// TRS related signals indicating when a TRS is to be generated by the flywheel
// and what type of TRS is to be generated.
//
v_smpte_sdi_v3_0_8_fly_horz #(
    .HCNT_WIDTH         (HCNT_WIDTH))
horz (
    .clk                (clk),
    .rst                (rst),
    .ce                 (ce),
    .clr_hcnt           (clr_hcnt),
    .resync_hcnt        (resync_hcnt),
    .std                (std),
    .hcnt               (hcnt),
    .eav_next           (fly_eav_next),
    .sav_next           (fly_sav_next),
    .h                  (h),
    .trs_word           (trs_word),
    .fly_trs            (fly_trs),
    .fly_eav            (fly_eav),
    .fly_sav            (fly_sav)
);

//
// fly_vert instantiation
//
// The fly_vert module contains the vertical functions of the flywheel. It
// generates the vertical line count and the V bit. It generates the inc_f
// signal indicating when it is time to advance to the next field. It also
// generates the switch_interval signal indicating when the current line is
// a line when switching between two synchronous video sources is permitted.
//
v_smpte_sdi_v3_0_8_fly_vert #(
    .VCNT_WIDTH         (VCNT_WIDTH))
vert (
    .clk                (clk),
    .rst                (rst),
    .ce                 (ce),
    .ntsc               (ntsc),
    .ld_vcnt            (ld_vcnt),
    .fsm_inc_vcnt       (inc_vcnt),
    .eav_next           (fly_eav_next),
    .clr_switch         (clr_switch),
    .rx_f               (rx_f),
    .f                  (f),
    .fly_sav            (fly_sav),
    .fly_eav            (fly_eav),
    .rx_eav_first       (rx_eav_first),
    .lock               (lock),
    .vcnt               (vcnt),
    .v                  (v),
    .sloppy_v           (sloppy_v),
    .inc_f              (inc_f),
    .switch_interval    (switch_interval)
);

assign sw_int = switch_interval & en_sync_switch;

//
// fly_fsm instantiation
//
// The fly_fsm module contains the finite state machine that controls the
// operation of the flywheel.
//
v_smpte_sdi_v3_0_8_fly_fsm fsm (
    .clk                (clk),
    .ce                 (ce),
    .rst                (rst),
    .vid_f              (rx_vid[8]),
    .vid_v              (rx_vid[7]),
    .vid_h              (rx_vid[6]),
    .rx_xyz             (rx_xyz),
    .fly_eav            (fly_eav),
    .fly_sav            (fly_sav),
    .fly_eav_next       (fly_eav_next),
    .fly_sav_next       (fly_sav_next),
    .rx_eav             (rx_eav),
    .rx_sav             (rx_sav),
    .rx_eav_first       (rx_eav_first),
    .new_rx_field       (new_rx_field),
    .xyz_err            (rx_xyz_err),
    .std_locked         (std_locked),
    .switch_interval    (sw_int),
    .xyz_f              (xyz[8]),
    .xyz_v              (xyz[7]),
    .xyz_h              (xyz[6]),
    .sloppy_v           (sloppy_v),
    .lock               (lock),
    .ld_vcnt            (ld_vcnt),
    .inc_vcnt           (inc_vcnt),
    .clr_hcnt           (clr_hcnt),
    .resync_hcnt        (resync_hcnt),
    .ld_std             (ld_std),
    .ld_f               (ld_f),
    .clr_switch         (clr_switch)
);

//
// fly_field instantiation
//
// The fly_field module contains the field related functions of the flywheel.
// It generates the F bit and also contains a logic to determine when the
// received field changes.
//
v_smpte_sdi_v3_0_8_fly_field fld (
    .clk                (clk),
    .rst                (rst),
    .ce                 (ce),
    .ld_f               (ld_f),
    .inc_f              (inc_f),
    .eav_next           (fly_eav_next),
    .rx_field           (rx_field),
    .rx_xyz             (rx_xyz),
    .f                  (f),
    .new_rx_field       (new_rx_field)
);

assign rx_field = rx_vid[8];

//
// rx_eav and rx_sav
//
// This code decodes the H bit from the received video to generate the rx_eav
// and rx_sav signals. These two signals are asserted during the XYZ word only
// of a received TRS symbol to indicate whether a SAV or an EAV symbol has
// been received.
//
assign rx_eav = rx_xyz & rx_vid[6];
assign rx_sav = rx_xyz & ~rx_vid[6];

//
// rx_trs_delay and rx_trs_all4 generation
//
// The trs_detect module only asserts the rx_trs signal during the first
// word of a received TRS symbol. This code stretches that signal so that
// it is asserted for all four words of the TRS symbol. The extended signal
// is called rx_trs_all4.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            rx_trs_delay <= 0;
        else
            rx_trs_delay <= {rx_trs_delay[1:0], rx_trs};
    end

assign rx_trs_all4 = |{rx_trs_delay,rx_trs};
        

//
// std register
//
// This register holds the current video standard code being used by the
// flywheel. It loads from the std inputs whenever the state machine begins
// the synchronization process.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            std <= NTSC_422;
        else if (ld_std)
            std <= std_in;
    end

//
// ntsc
//
// This signal is asserted when the code in the std register indicates a
// NTSC standard and is negated for PAL standards.
//
assign is_ntsc = std == NTSC_422 || std == NTSC_INVALID || std == NTSC_422_WIDE || std == NTSC_4444;

always @ (*)
    if (is_ntsc)
        ntsc = 1'b1;
    else
        ntsc = 1'b0;

//
// xyz generator
//
// This logic generates the TRS XYZ word. The XYZ word is constructed
// differently for the 4:4:4:4 standards than for the 4:2:2 standards.
//
assign is_422 = std == NTSC_422 || std == NTSC_422_WIDE || std == PAL_422  || std == PAL_422_WIDE;

always @ (*)
begin
    xyz[9] <= 1'b1;
    xyz[8] <= f;
    xyz[7] <= v;
    xyz[6] <= h;
    xyz[0] <= 1'b0;

    if (std == NTSC_4444 || std == PAL_4444)
        begin
            xyz[5] <= rx_s4444;
            xyz[4] <= f ^ v ^ h;
            xyz[3] <= f ^ v ^ rx_s4444;
            xyz[2] <= v ^ h ^ rx_s4444;
            xyz[1] <= f ^ h ^ rx_s4444;
        end
    else if (is_422)
        begin
            xyz[5] <= v ^ h;
            xyz[4] <= f ^ h;
            xyz[3] <= f ^ v;
            xyz[2] <= f ^ v ^ h;
            xyz[1] <= 1'b0;
        end
    else
        xyz <= 0;
end

//
// fly_vid generator
//
// This code generates the flywheel TRS symbol. The first three words of the
// TRS symbol are 0x3ff, 0x000, 0x000. The fourth word is the XYZ word. If
// a TRS symbol is not begin generated, the fly_vid value is assigned to
// the blank level value appropriate to the component being generated.
//
always @ (*)
    if (trs_d)
        case(trs_word)
            2'b00: fly_vid <= 10'h3ff;
            2'b01: fly_vid <= 10'h000;
            2'b10: fly_vid <= 10'h000;
            2'b11: fly_vid <= xyz;
        endcase
    else if (std == NTSC_4444 || std == PAL_4444)
        begin
            if (rx_s4444)
                case (hcnt[1:0])
                    2'b00: fly_vid <= YCBCR_4444_BLANK_CB;
                    2'b01: fly_vid <= YCBCR_4444_BLANK_Y;
                    2'b10: fly_vid <= YCBCR_4444_BLANK_CR;
                    2'b11: fly_vid <= YCBCR_4444_BLANK_A;
                endcase
            else
                case (hcnt[1:0])
                    2'b00: fly_vid <= RGB_4444_BLANK_B;
                    2'b01: fly_vid <= RGB_4444_BLANK_G;
                    2'b10: fly_vid <= RGB_4444_BLANK_R;
                    2'b11: fly_vid <= RGB_4444_BLANK_A;
                endcase
        end
    else
        begin
            if (hcnt[0])
                fly_vid <= YCBCR_422_BLANK_Y;
            else
                fly_vid <= YCBCR_422_BLANK_C;
        end 

//
// output register
//
// This is the output register for all the flywheel's output signals. The
// signals that can be derived internally or from the received video (trs,
// vid_out, and h_blank) use the use_rx signal to determine whether the flywheel
// generated signals or the signals decoded from the received video should be 
// used. The v_blank and field outputs are not affected by use_rx.
//
// Normally the output video stream (vid_out) is equal to the input video
// stream (vid_in). However, when the flywheel generates a TRS symbol, this
// internally generated TRS symbol is output instead of the input video
// stream. If the input video stream contains a TRS that does not line up
// with the flywheel's TRS symbol, then the TRS symbol in the input video
// stream is blanked by the flywheel. However, on the synchronous switching
// lines, the SAV symbol in the input video stream is always output and the 
// flywheel's SAV symbol is suppressed.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
        begin
            trs <= 1'b0;
            field <= 1'b0;
            v_blank <= 1'b0;
            h_blank <= 1'b0;
            horz_count <= 0;
            vert_count <= 1;
            locked <= 0;
            sync_switch <= 0;
            vid_out <= 0;
            eav_next <= 0;
            sav_next <= 0;
            xyz_word <= 0;
        end
        else
        begin
            trs <= trs_d;
            field <= f;
            v_blank <= v_blank_d;
            h_blank <= h_blank_d;
            horz_count <= hcnt;
            vert_count <= vcnt;
            locked <= lock;
            sync_switch <= sw_int;
            vid_out <= use_fly ? fly_vid : rx_vid;
            eav_next <= fly_eav_next;
            sav_next <= fly_sav_next;
            xyz_word <= xyz_word_d;
        end
    end

assign use_rx = lock & (sw_int | sloppy_v);
assign use_fly = (trs_d & ~use_rx) | ((~trs_d & rx_trs_all4) & en_trs_blank);
assign trs_d = use_rx ? rx_trs_all4 : fly_trs;
assign h_blank_d = use_rx ? (rx_h | rx_trs_all4) : (h | trs_d);
assign v_blank_d = use_rx ? rx_v : v;
assign xyz_word_d = trs_d & trs_word[1] & trs_word[0];
assign anc_next = rx_anc;
assign edh_next = rx_edh;
     
endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
Module Description:

This module does a 18-bit CRC calculation.

The calculation is the SMPTE 292M defined CRC18 calculation with a polynomial of 
x^18 + x^5 + x^4 + 1. The function considers the LSB of the video data as the 
first bit shifted into the CRC generator, although the implementation given here
is a fully parallel CRC, calculating all 18 CRC bits from the 10-bit video data
in one clock cycle.  

The clr input must be asserted coincident with the first input data word of
a new CRC calculation. The clr input forces the old CRC value stored in the
module's crc_reg to be discarded and a new calculation begins as if the old CRC
value had been cleared to zero.

This module is the same as hdsdi_crc, but adds an enable input in addition to
the clock enable.
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_hdsdi_crc2 (
    input  wire         clk,    // clock input
    input  wire         ce,     // clock enable
    input  wire         en,     // 1 = enable CRC calculation
    input  wire         rst,    // sync reset input
    input  wire         clr,    // forces the old CRC value to zero to start new calculation
    input  wire [9:0]   d,      // input data word
    output wire [17:0]  crc_out // new calculated CRC value
);

//-----------------------------------------------------------------------------
// Signal definitions
//
wire                    x10;
wire                    x9;
wire                    x8;
wire                    x7;
wire                    x6;
wire                    x5;
wire                    x4;
wire                    x3;
wire                    x2;
wire                    x1;
wire    [17:0]          newcrc;     // input to CRC register            
wire    [17:0]          crc;        // output of crc_reg, unless clr is asserted
reg     [17:0]          crc_reg = 0;// internal CRC register


//
// The previous CRC value is represented by the variable crc. This value is
// combined with the new data word to form the new CRC value. Normally, crc is
// equal to the contents of the crc_reg. However, if the clr input is asserted,
// the crc value is set to all zeros.
//
assign crc = clr ? 0 : crc_reg;

//
// The x variables are intermediate terms used in the new CRC calculation.
//                             
assign x10 = d[9] ^ crc[9];
assign x9  = d[8] ^ crc[8];
assign x8  = d[7] ^ crc[7];
assign x7  = d[6] ^ crc[6];
assign x6  = d[5] ^ crc[5];
assign x5  = d[4] ^ crc[4];
assign x4  = d[3] ^ crc[3];
assign x3  = d[2] ^ crc[2];
assign x2  = d[1] ^ crc[1];
assign x1  = d[0] ^ crc[0];

//
// These assignments generate the new CRC value.
//
assign newcrc[0]  = crc[10];
assign newcrc[1]  = crc[11];
assign newcrc[2]  = crc[12];
assign newcrc[3]  = x1  ^ crc[13];
assign newcrc[4]  = x2  ^ x1 ^ crc[14];
assign newcrc[5]  = x3  ^ x2 ^ crc[15];
assign newcrc[6]  = x4  ^ x3 ^ crc[16];
assign newcrc[7]  = x5  ^ x4 ^ crc[17];
assign newcrc[8]  = x6  ^ x5 ^ x1;
assign newcrc[9]  = x7  ^ x6 ^ x2;
assign newcrc[10] = x8  ^ x7 ^ x3;
assign newcrc[11] = x9  ^ x8 ^ x4;
assign newcrc[12] = x10 ^ x9 ^ x5;
assign newcrc[13] = x10 ^ x6;
assign newcrc[14] = x7;
assign newcrc[15] = x8;
assign newcrc[16] = x9;
assign newcrc[17] = x10;

//
// This is the crc_reg. On each clock cycle when ce is asserted, it loads the
// newcrc value. The module's crc_out vector is always assigned to the contents
// of the crc_reg.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            crc_reg <= 0;
        else if (en)
            crc_reg <= newcrc;
    end

assign crc_out = crc_reg;

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
This formats the 18-bit CRC values for each channel into two 10-bit video words
and inserts them into the appropriate places immediately after the line number
words in the EAV.

An 18-bit CRC value is formatted into two 10-bit words that are inserted after
the EAV and line number words. The format of the CRC words is shown below:
 
         b9     b8     b7     b6     b5     b4     b3     b2     b1     b0
      +------+------+------+------+------+------+------+------+------+------+
CRC0: |~crc8 | crc8 | crc7 | crc6 | crc5 | crc4 | crc3 | crc2 | crc1 | crc0 |
      +------+------+------+------+------+------+------+------+------+------+
CRC1: |~crc17| crc16| crc15| crc14| crc13| crc12| crc11| crc10| crc9 | crc8 |
      +------+------+------+------+------+------+------+------+------+------+

This module is purely combinatorial and contains no clocked registers.
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_hdsdi_insert_crc (
    input  wire         insert_crc, // CRC values will be inserted when this input is high
    input  wire         crc_word0,  // input asserted during time for first CRC word in EAV 
    input  wire         crc_word1,  // input asserted during time for second CRC word in EAV
    input  wire [9:0]   c_in,       // C channel video input
    input  wire [9:0]   y_in,       // Y channel video input
    input  wire [17:0]  c_crc,      // C channel CRC value input
    input  wire [17:0]  y_crc,      // Y channel CRC value input
    output reg  [9:0]   c_out,      // C channel video output
    output reg  [9:0]   y_out       // Y channel video output
);

always @ (*)
    if (insert_crc & crc_word0)
        c_out = {~c_crc[8], c_crc[8:0]};
    else if (insert_crc & crc_word1)
        c_out = {~c_crc[17], c_crc[17:9]};
    else
        c_out = c_in;

always @ (*)
    if (insert_crc & crc_word0)
        y_out = {~y_crc[8], y_crc[8:0]};
    else if (insert_crc & crc_word1)
        y_out = {~y_crc[17], y_crc[17:9]};
    else
        y_out = y_in;

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
This module formats the 11-bit line number value into two 10-bit words and 
inserts them into their proper places immediately after the EAV word. The
insert_ln input can disable the insertion of line numbers. The same line
number value is inserted into both video channels. 

In the SMPTE 292M standard, the 11-bit line numbers must be formatted into two
10-bit words with the format of each word as follows:

        b9    b8    b7    b6    b5    b4    b3    b2    b1    b0
     +-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+
LN0: | ~ln6| ln6 | ln5 | ln4 | ln3 | ln2 | ln1 | ln0 |  0  |  0  |
     +-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+
LN1: |  1  |  0  |  0  |  0  | ln10| ln9 | ln8 | ln7 |  0  |  0  |
     +-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+
      

This module is purely combinatorial and has no clocked registers.
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_hdsdi_insert_ln (
input  wire             insert_ln,      // enables insertion of line numbers when high
input  wire             ln_word0,       // asserted during first word of line number
input  wire             ln_word1,       // asserted during second word of line number
input  wire [9:0]       c_in,           // C channel video input
input  wire [9:0]       y_in,           // Y channel video input
input  wire [10:0]      ln,             // 11-bit line number input
output reg  [9:0]       c_out,          // C channel video output
output reg  [9:0]       y_out           // Y channel video output
);

always @ (*)
    if (insert_ln & ln_word0)
        c_out = {~ln[6], ln[6:0], 2'b00};
    else if (insert_ln & ln_word1)
        c_out = {4'b1000, ln[10:7], 2'b00};
    else
        c_out = c_in;

always @ (*)
    if (insert_ln & ln_word0)
        y_out = {~ln[6], ln[6:0], 2'b00};
    else if (insert_ln & ln_word1)
        y_out = {4'b1000, ln[10:7], 2'b00};
    else
        y_out = y_in;

endmodule



// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
Module Description:

This module calculates the CRC value for a line and compares it to the received
CRC value. The module does this for both the Y and C channels. If a CRC error
is detected, the corresponding CRC error output is asserted high. This output
remains asserted for one video line time, until the next CRC check is made.

The module also captures the line number values for the two channels and 
outputs them. The line number values are valid for the entire line time. 

--------------------------------------------------------------------------------
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_hdsdi_rx_crc (
    input  wire         clk,                // receiver clock
    input  wire         rst,                // reset signal
    input  wire         ce,                 // clock enable input
    input  wire [9:0]   c_video,            // C channel video input port
    input  wire [9:0]   y_video,            // Y channel video input port
    input  wire         trs,                // TRS signal asserted during all 4 words of TRS
    output reg          c_crc_err = 1'b0,   // C channel CRC error detected
    output reg          y_crc_err = 1'b0,   // Y channel CRC error detected
    output reg  [10:0]  c_line_num = 0,     // C channel received line number
    output reg  [10:0]  y_line_num = 0      // Y channel received line number
);

// Internal wires
reg     [17:0]      c_rx_crc = 0;
reg     [17:0]      y_rx_crc = 0;
wire    [17:0]      c_calc_crc;
wire    [17:0]      y_calc_crc;
reg     [7:0]       trslncrc = 0;
reg                 crc_clr = 0;
reg                 crc_en = 0;
reg     [6:0]       c_line_num_int = 0;
reg     [6:0]       y_line_num_int = 0;

//
// CRC generator modules
//
v_smpte_sdi_v3_0_8_hdsdi_crc2 crc_C (
    .clk            (clk),
    .ce             (ce),
    .en             (crc_en),
    .rst            (rst),
    .clr            (crc_clr),
    .d              (c_video),
    .crc_out        (c_calc_crc)
);

v_smpte_sdi_v3_0_8_hdsdi_crc2 crc_Y (
    .clk            (clk),
    .ce             (ce),
    .en             (crc_en),
    .rst            (rst),
    .clr            (crc_clr),
    .d              (y_video),
    .crc_out        (y_calc_crc)
);


//
// trslncrc generator
//
// This code generates timing signals indicating where the CRC and LN words
// are located in the EAV symbol.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            trslncrc <= 0;
        else
        begin
            if (trs & ~trslncrc[0] & ~trslncrc[1] & ~trslncrc[2])
                trslncrc[0] <= 1'b1;
            else
                trslncrc[0] <= 1'b0;
            trslncrc[7:1] <= {trslncrc[6:3], trslncrc[2] & y_video[6], trslncrc[1:0]};
        end
    end

//
// crc_clr signal
//
// The crc_clr signal controls when the CRC generator's accumulation register
// gets reset to begin calculating the CRC for a new line.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            crc_clr <= 1'b0;
        else if (trslncrc[2] & ~y_video[6])
            crc_clr <= 1'b1;
        else
            crc_clr <= 1'b0;
    end
        
//
// crc_en signal
//
// The crc_en signal controls which words are included in the CRC calculation.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            crc_en <= 1'b0;
        else if (trslncrc[2] & ~y_video[6])
            crc_en <= 1'b1;
        else if (trslncrc[4])
            crc_en <= 1'b0;
    end
        
//
// received CRC registers
//
// These registers hold the received CRC words from the input video stream.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
        begin
            c_rx_crc <= 0;
            y_rx_crc <= 0;
        end
        else if (trslncrc[5])
        begin
            c_rx_crc[8:0] <= c_video[8:0];
            y_rx_crc[8:0] <= y_video[8:0];
        end
        else if (trslncrc[6])
        begin
            c_rx_crc[17:9] <= c_video[8:0];
            y_rx_crc[17:9] <= y_video[8:0];
        end
    end

//
// CRC comparators
//
// Compare the received CRC values against the calculated CRCs.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
        begin
            c_crc_err <= 1'b0;
            y_crc_err <= 1'b0;
        end
        else if (trslncrc[7])
        begin
            if (c_rx_crc == c_calc_crc)
                c_crc_err <= 1'b0;
            else
                c_crc_err <= 1'b1;

            if (y_rx_crc == y_calc_crc)
                y_crc_err <= 1'b0;
            else
                y_crc_err <= 1'b1;
        end
    end

//
// line number registers
//
// These registers hold the line number values from the input video stream.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
        begin
            c_line_num_int <= 0;
            y_line_num_int <= 0;
            c_line_num <= 0;
            y_line_num <= 0;
        end
        else if (trslncrc[3])
        begin
            c_line_num_int <= c_video[8:2];
            y_line_num_int <= y_video[8:2];
        end
        else if (trslncrc[4])
        begin
            c_line_num <= {c_video[5:2], c_line_num_int};
            y_line_num <= {y_video[5:2], y_line_num_int};
        end
    end

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
Module Description:

This is a multi-rate SDI decoder module that supports both SD-SDI (SMPTE 259M)
and HD-SDI (SMPTE 292M).

SDI specifies that the serial bit stream shall be encoded in two ways. First,
a generator polynomial of x^9 + x^4 + 1 is used to generate a scrambled NRZ bit
sequence. Next, a generator polynomial of x + 1 is used to produce the final
polarity free NRZI sequence which is transmitted over the physical layer.

The decoder module described in this file sits at the receiving end of the
SDI link and reverses the two encoding steps to extract the original data. 
First, the x + 1 generator polynomial is used to convert the bit stream from 
NRZI to NRZ. Next, the x^9 + x^4 + 1 generator polynomial is used to descramble 
the data.

When running in HD-SDI mode (hd_sd = 0), 20 bits are decoded every clock cycle.
When running in SD-SDI mode (hd_sd = 1), the 10-bit SD-SDI data must be placed
on the MS 10 bits of the d port. Ten bits are decoded every clock cycle and
the decoded 10 bits are output on the 10 MS bits of the q port.

--------------------------------------------------------------------------------
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_multi_sdi_decoder (
    input  wire         clk,        // word-rate clock
    input  wire         rst,        // sync reset
    input  wire         ce,         // clock enable
    input  wire         hd_sd,      // 0 = HD, 1 = SD   
    input  wire [19:0]  d,          // input data (SD on bits [19:10])
    output wire [19:0]  q           // output data (SD on bits [19:10])
);

//
// Signal defintions
//
reg                 prev_d19 = 1'b0;// previous d[19] bit register
reg     [8:0]       prev_nrz = 0;   // holds 9 MSBs from NRZI-to-NRZ for use in next clock cycle
reg     [19:0]      out_reg = 0;
wire    [28:0]      desc_wide;      // concat of two input words used by descrambler
wire    [19:0]      nrz;            // output of the NRZI-to-NRZ converter
wire    [19:0]      nrz_in;         // input to NRZI-to-NRZ converter
integer             i;              // for loop variable


//
// prev_d19 register
//
// This register holds the MSB of the previous clock period's d input so
// that a 21-bit input vector is available to the NRZI-to-NRZ converter.
// 
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            prev_d19 <= 1'b0;
        else
            prev_d19 <= d[19];
    end

//
// NRZI-to-NRZ converter
//
// The 20 XOR gates generated by this statement convert the 21-bit wide
// nrzi data to 20 bits of NRZ data. Each bit from the input is XORed with
// the bit that preceded it in the bit stream. The LSB of d is XORed with the 
// MSB of input from the previous clock period that is held in the prev_d19 
// register. If only ten bits are being decoded (SD-SDI mode), then the 
// prev_d19 register needs to be XORed with bit 10, instead of bit 0 and the
// LS 10 bits out of this block are not used.
//
assign nrz_in[19:11] = d[18:10];
assign nrz_in[10]    = hd_sd ? prev_d19 : d[9];
assign nrz_in[9:1]   = d[8:0];
assign nrz_in[0]     = prev_d19;

assign nrz = d ^ nrz_in;

//
// prev_nrz input register of the descrambler
//
// This register is a pipeline delay register which loads from the output of the
// NRZI-to-NRZ converter. It only holds the nine MSBs from the converter which
// get combined with 20-bits coming from the converter on the next clock cycle
// to form a 29-bit wide input vector to the descrambler.
//
always @ (posedge clk)
    if (rst)
        prev_nrz <= 0;
    else if (ce)
        prev_nrz <= nrz[19:11];

//
// The desc_wide vector is the input to the descrambler below. This vector
// differs between HD-SDI mode and SD-SDI mode since the LS bits from the
// NRZI-to-NRZ converter are not valid in SD-SDI mode.
//
assign desc_wide[28:19] = nrz[19:10];
assign desc_wide[18:10] = hd_sd ? prev_nrz : nrz[9:1];
assign desc_wide[9]     = nrz[0];
assign desc_wide[8:0]   = prev_nrz;

// 
// Descrambler
//
// A for loop is used to generate the HD-SDI x^9 + x^4 + 1 polynomial for 
// each of the 20-bits to be output using the 29-bit desc_wide input vector 
// that is made up of the contents of the prev_nrz register and the output of 
// the NRZI-to-NRZ converter.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            out_reg <= 0;
        else
            for (i = 0; i < 20; i = i + 1)
                out_reg[i] <= desc_wide[i] ^ desc_wide[i + 4] ^ desc_wide[i + 9];
    end

assign q = out_reg;

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
Module Description:

This module is the top-level module of the multi-rate HD/SD-SDI encoder. For 
HD-SDI, this module encodes 20 bits of data, 10 bits of chroma (C) and 10 bits 
of luma (Y), per clock cycle. For SD-SDI, 10 bits are encoded per clock cycle.

This module instantiates the smpte_encoder module twice, with one module 
encoding the C data and the other the Y data. The two modules are cross 
connected so that the results from one encoder affects the encoding of the bits
in the other encoder, as required by the HD-SDI encoding scheme. When encoding
SD-SDI, only the Y channel SMPTE encoder is used

The q output is a 20-bit encoded value. Note that this value must be bit-swapped
before it can be connected to the 20-bit input of the RocketIO transmitter. For
SD-SDI, only the LS 10-bits of the output are valid.

Note that this module does not make multiple copies of each encoded bit for
SD-SDI as required to run the RocketIO MGT in oversampled mode for the slow
SD-SDI bit rates. This bit replication must be done externally to this module.
--------------------------------------------------------------------------------
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_multi_sdi_encoder (
input  wire         clk,        // input clock
input  wire         ce,         // input register load signal
input  wire         hd_sd,      // 0 = HD, 1 = SD
input  wire         nrzi,       // enables NRZ-to-NRZI conversion when high
input  wire         scram,      // enables SDI scrambler when high
input  wire [9:0]   c,          // C channel input data (not used for SD-SDI)
input  wire [9:0]   y,          // Y channel input data 
output wire [19:0]  q           // encoded output data
);


//
// Signal definitions
//
reg     [9:0]       c_in_reg = 0;   // C channel input register
reg     [9:0]       y_in_reg = 0;   // Y channel input register
wire    [8:0]       c_i_scram;      // C channel intermediate scrambled data
wire    [8:0]       y_i_scram_q;    // Y channel intermediate scrambled data
wire                c_i_nrzi;       // C channel intermediate nrzi data
wire    [9:0]       c_out;          // output of C scrambler
wire    [9:0]       y_out;          // output of Y scrambler
wire    [8:0]       y_p_scram_mux;  // p_scram input MUX for Y encoder
wire                y_p_nrzi_mux;   // p_nrzi input MUX for Y encoder

//
// Scrambler modules for both C and Y channels
//
v_smpte_sdi_v3_0_8_smpte_encoder C_scram (
    .clk        (clk),
    .ce         (~hd_sd & ce),
    .nrzi       (nrzi),
    .scram      (scram),
    .d          (c_in_reg),
    .p_scram    (y_i_scram_q),
    .p_nrzi     (y_out[9]),
    .q          (c_out),
    .i_scram    (c_i_scram),
    .i_scram_q  (),
    .i_nrzi     (c_i_nrzi)
);

v_smpte_sdi_v3_0_8_smpte_encoder Y_scram (
    .clk        (clk),
    .ce         (ce),
    .nrzi       (nrzi),
    .scram      (scram),
    .d          (y_in_reg),
    .p_scram    (y_p_scram_mux),
    .p_nrzi     (y_p_nrzi_mux),
    .q          (y_out),
    .i_scram    (),
    .i_scram_q  (y_i_scram_q),
    .i_nrzi     ()
);

//
// These MUXes control whether the two smpte_scrambler modules are configured
// for HD-SDI or SD-SDI. In HD-SDI, the C and Y channel scramblers are
// cross connected to encode a 20-bit word every clock cycle. In SD-SDI mode,
// only the Y channel scrambler is used and it's output is feedback to its
// inputs to allow the sequential scrambling of the data 10-bits at a time.
//
assign y_p_scram_mux = hd_sd ? y_i_scram_q : c_i_scram;
assign y_p_nrzi_mux = hd_sd ? y_out[9] : c_i_nrzi;


//
// Input registers
//
always @ (posedge clk)
    if (ce)
        y_in_reg <= y;

always @ (posedge clk)
    if (ce & ~hd_sd)
        c_in_reg <= c;

//
// Output assignment
//
assign q = {y_out, c_out};

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
Module Description:

SMPTE 292M-1998 HD-SDI is a standard for transmitting high-definition digital 
video over a serial link.  SMPTE 259M (SD-SDI) is an equivalent standard for 
standard-definition video. This module performs the framing function on the 
decoded data from the multi-rate decoder for both SD-SDI and HD-SDI

This module accepts 20-bit "unframed" data words in HD-SDI mode and
10-bit data in SD-SDI mode. It examines the video stream for the 30-bit TRS 
preamble. Once a TRS is found, the framer then knows the bit boundary of all 
subsequent 10-bit characters in the video stream and uses this offset to 
generate properly framed video.

The d input port is 20-bits wide to accommodate the 20-bit HD-SDI data word
from the decoder. In SD-SDI mode, only the 10 most significant bits (19:10)
are used.

The module has the following control inputs:

ce: The clock enable input controls loading of all registers in the module. It
must be asserted whenever a new 10-bit word is to be loaded into the module. By
providing a clock enable, this module can use a clock that is running at the
bit rate of the SDI bit stream if ce is asserted once every ten clock cycles.

hd_sd: Controls whether the framer runs in HD-SDI mode (0) or SD-SDI mode (1).

frame_en: This input controls whether the framer resynchronize to new character
offsets when out-of-phase TRS symbols are detected. When this input is high,
out-of-phase TRS symbols will cause the framer to resynchronize.

The module generates the following outputs:

c: This port contains the framed 10-bit C component for HD-SDI. It is unused
for SD-SDI.

y: This port contains the framed 10-bit Y component for HD-SDI or the 10-bit
framed video word for SD-SDI.

trs: (timing reference signal) This output is asserted when the y and c outputs
have any of the four words of a TRS.

xyz: This output is asserted when the XYZ word of a TRS is output.

eav: This output is asserted when the XYZ word of a EAV is output.

sav: This output is asserted when the XYZ word of a SAV is output.

trs_err: This output is asserted during the XYZ word if an error is detected
by examining the protection bits.

nsp: (new start position) If frame_en is low and a TRS is detected that does not
match the current character offset, this signal will be asserted high. The nsp
signal will remain asserted until the offset error has been corrected..

There are normally three ways to use the frame_en input:

frame_en tied high: When frame_en is tied high, the framer will resynchronize
on every TRS detected. 

frame_en tied to nsp: When in this mode, the framer implements TRS filtering.
If a TRS is detected that is out of phase with the existing character offset,
nsp will be asserted, but the framer will not resynchronize. If the next TRS
received is in phase with the current character offset, nsp will go low and the
will not resynchronize. If the next TRS arrives out of phase with the current
character offset, then the new character offset will be loaded and nsp will be
deasserted. Single erroneous TRS  are ignored in this mode, but if they persist,
the decoder will adjust.

frame_en tied low: The automatic framing function is disabled when frame_en is
tied low. If data is being sent across the interface that does not comply with
the SDI standard and may contain data that looks like TRS symbols, the framing
function can be disabled in this manner.
--------------------------------------------------------------------------------
*/

`timescale 1ns / 1ns
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_multi_sdi_framer (
    input  wire         clk,        // input clock
    input  wire         rst,        // reset signal
    input  wire         ce,         // clock enable
    input  wire [19:0]  d,          // input data
    input  wire         frame_en,   // enables resynchronization when high
    input  wire         hd_sd,
    output wire [9:0]   c,          // chroma channel output data
    output wire [9:0]   y,          // luma channel output data
    output reg          trs = 1'b0, // asserted when out reg contains a TRS symbol
    output wire         xyz,        // asserted during XYZ word of TRS symbol
    output wire         eav,        // asserted during XYZ word of EAV symbol
    output wire         sav,        // asserted during XYZ word of SAV symbol
    output wire         trs_err,    // asserted if error detected in XYZ word
    output reg          nsp = 1'b1  // new start position detected
);

//------------------------------------------------------------------------------
// Internal signals
//
reg     [19:0]      in_reg = 0;         // input register
reg     [19:0]      dly_reg = 0;        // pipeline delay register
reg     [19:0]      dly_reg2 = 0;       // pipeline delay register
wire    [4:0]       offset_val;         // HD/SD offset value mux output
wire                trs_detected;       // HD/SD TRS detected mux output
wire                hd_trs_err;
reg     [4:0]       offset_reg = 0;     // offset register
reg     [3:0]       trs_out = 0;        // used to generate the trs output signal
wire    [38:0]      hd_in_0;            // input vector for zeros detector
wire    [38:0]      hd_in_1;            // input vector for ones detector
reg     [19:0]      hd_ones_in;         // ones detector result vector 
reg     [19:0]      hd_zeros_in;        // zeros detector result vector
reg     [19:0]      hd_zeros_dly = 0;   // zeros detector result vector delayed
wire    [19:0]      hd_trs_match;       // TRS detector result vector
wire                hd_trs_detected;    // asserted when TRS symbol is detected
wire    [4:0]       hd_offset_val;      // calculated offset value to load into offset_reg
reg     [34:0]      bs_1_out;           // output of first level of barrel shifter
reg     [22:0]      bs_2_out;           // output of second level of barrel shifter
reg     [38:0]      barrel_in = 0;      // barrel shifter input register
reg     [19:0]      barrel_out;         // output of barrel shifter
wire                new_offset;         // mismatch between offset_val and offset_reg
wire    [50:0]      bs_in;              // input vector to barrel shifter first level
wire                bs_sel_1;           // barrel shifter first level select bit
wire    [1:0]       bs_sel_2;           // barrel shifter second level select bits
wire    [1:0]       bs_sel_3;           // barrel shifter third level select bits
reg     [9:0]       c_int = 0;          // internal version of c output
reg     [9:0]       y_int = 0;          // internal version of y output
reg                 xyz_int = 1'b0;     // internal flip-flop for XYZ output
integer             i,j,k;              // barrel shifter loop variables
integer             l,m;                // TRS detect for loop variables
wire    [38:0]      sd_in_vector;       // concatenation of the four input registers
reg     [9:0]       sd_trs_match1;      // which offsets in in_vector[18:0] match 0x3ff
reg     [9:0]       sd_trs_match2;      // which offsets in in_vector[28:10] match 0x000
reg     [9:0]       sd_trs_match3;      // which offsets in in_vector[38:29] match 0x000
wire    [9:0]       sd_trs_match_all;   // which offsets match complete 30-bit TRS symbol
reg     [15:0]      sd_trs_match1_l1;   // intermediate level of gate outputs in TRS detector
reg     [15:0]      sd_trs_match2_l1;   // intermediate level of gate outputs in TRS detector
reg     [15:0]      sd_trs_match3_l1;   // intermediate level of gate outputs in TRS detector
wire                sd_trs_detected;    // asserted when TRS symbol is detected
reg                 sd_trs_err;         // more than one offset matched the TRS symbol
wire    [3:0]       sd_offset_val;      // calculated offset value to load into offset_reg
      
//------------------------------------------------------------------------------
// Input and pipeline delay registers
//

//
// input register
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            in_reg <= 0;
        else
            in_reg <= d;
    end

//
// delay register
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            dly_reg <= 0;
        else
            dly_reg <= in_reg;
    end

//
// delay register 2
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            dly_reg2 <= 0;
        else
            dly_reg2 <= dly_reg;
    end

//------------------------------------------------------------------------------
// HD TRS detector and offset encoder
//
// The HD TRS detector identifies the 60-bit TRS sequence consisting of 20 '1'
// bits followed by 40 '0' bits. The first level of the TRS detector consists
// of a ones detector and a zeros detector. The ones detector looks for a run
// of 20 consecutive ones in the hd_in_1 vector. The hd_in_1 vector is a 39-bit
// vector made up of the contents of dly_reg2 and the 19 LSBs of dly_reg. The
// zeros detector looks for a run of 20 consecutive '0' bits in the hd_in_0 
// vector. The hd_in_0 vector is 39-bits wide and is made up of the contents of 
// in_reg and the 19 LSBs of the d input port. The output of the zeros detector 
// is stored in the hd_zeros_dly register so that the zeros detector can be used
// twice to find two consecutive runs of 20 zeros. The output of the zeros 
// detector (both hd_zeros_in and hd_zeros_dly) and the ones detector 
// (hd_ones_in) are 20-bit vectors with a bit for each possible starting 
// position of the 20-bit run.
//
// A vector called trs_match is created by ORing the hd_ones_in, hd_zeros_in, 
// and hd_zeros_dly values together. The 20-bit trs_match vector will have a 
// single bit set indicating the starting position of a TRS if one is present in
// the input vector. The trs_detected signal, asserted when a TRS is detected, 
// can then be created by ORing all of the bits of trs_match together. And the
// offset_val, which is a 4-bit binary value indicating the starting position
// of the TRS to the barrel shifter, can be generated from the trs_match vector.
// 
assign hd_in_0 = {d[18:0], in_reg};
assign hd_in_1 = {dly_reg[18:0], dly_reg2};


//
// zeros and ones detectors
//
always @ (*)
    for (l = 0; l < 20; l = l + 1)
        hd_zeros_in[l]  = ~(hd_in_0[l+19] | hd_in_0[l+18] | hd_in_0[l+17] | 
                            hd_in_0[l+16] | hd_in_0[l+15] | hd_in_0[l+14] | 
                            hd_in_0[l+13] | hd_in_0[l+12] | hd_in_0[l+11] | 
                            hd_in_0[l+10] | hd_in_0[l+ 9] | hd_in_0[l+ 8] |
                            hd_in_0[l+ 7] | hd_in_0[l+ 6] | hd_in_0[l+ 5] | 
                            hd_in_0[l+ 4] | hd_in_0[l+ 3] | hd_in_0[l+ 2] | 
                            hd_in_0[l+ 1] | hd_in_0[l+ 0]);

always @ (*)
    for (m = 0; m < 20; m = m + 1)
        hd_ones_in[m]  = hd_in_1[m+19] & hd_in_1[m+18] & hd_in_1[m+17] & 
                         hd_in_1[m+16] & hd_in_1[m+15] & hd_in_1[m+14] & 
                         hd_in_1[m+13] & hd_in_1[m+12] & hd_in_1[m+11] & 
                         hd_in_1[m+10] & hd_in_1[m+ 9] & hd_in_1[m+ 8] & 
                         hd_in_1[m+ 7] & hd_in_1[m+ 6] & hd_in_1[m+ 5] & 
                         hd_in_1[m+ 4] & hd_in_1[m+ 3] & hd_in_1[m+ 2] & 
                         hd_in_1[m+ 1] & hd_in_1[m+ 0];


// delay reg for hd_zeros_in
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            hd_zeros_dly <= 0;
        else
            hd_zeros_dly <= hd_zeros_in;
    end

// TRS match vector generation
assign hd_trs_match = hd_zeros_in & hd_zeros_dly & hd_ones_in;

// trs_detected signal
assign hd_trs_detected = |hd_trs_match;


//
// The following assignments encode the hd_trs_match vector into a binary
// offset code.
//
assign hd_offset_val[0] = hd_trs_match[1]  | hd_trs_match[3]  | hd_trs_match[5]  |
                          hd_trs_match[7]  | hd_trs_match[9]  | hd_trs_match[11] |
                          hd_trs_match[13] | hd_trs_match[15] | hd_trs_match[17] |
                          hd_trs_match[19];

assign hd_offset_val[1] = hd_trs_match[2]  | hd_trs_match[3]  | hd_trs_match[6]  |
                          hd_trs_match[7]  | hd_trs_match[10] | hd_trs_match[11] |
                          hd_trs_match[14] | hd_trs_match[15] | hd_trs_match[18] |
                          hd_trs_match[19];

assign hd_offset_val[2] = hd_trs_match[4]  | hd_trs_match[5]  | hd_trs_match[6]  |
                          hd_trs_match[7]  | hd_trs_match[12] | hd_trs_match[13] |
                          hd_trs_match[14] | hd_trs_match[15];

assign hd_offset_val[3] = hd_trs_match[8]  | hd_trs_match[9]  | hd_trs_match[10] |
                          hd_trs_match[11] | hd_trs_match[12] | hd_trs_match[13] |
                          hd_trs_match[14] | hd_trs_match[15];

assign hd_offset_val[4] = hd_trs_match[16] | hd_trs_match[17] | hd_trs_match[18] |
                          hd_trs_match[19];


//------------------------------------------------------------------------------
// SD TRS detector
//

//
// TRS detector and offset encoder
//
// The TRS detector finds 30-bit TRS preambles (0x3ff, 0x000, 0x000) in the
// input data stream. The TRS detector scans a 39-bit input vector
// consisting of all the bits from the three input registers plus the LS
// 9 bits of the d input data.
//
// The detector consists two main parts. 
//
// The first part is a series 10-bit AND and NOR gates that examine each
// possible bit location in the 39 input vector for the TRS preamble. These
// 10-bit wide AND and NOR gates have been coded here as two levels of
// 3 and 4 input gates because this results in a more compact implementation
// in most synthesis engines. 
//
// The outputs of these gates are assigned to the vectors trs_match1, 2, 
// and 3. These three vectors each contain 10 unary bits which indicate which 
// offset(s) matched the pattern being detected. ANDing these three vectors
// together generates another 10-bit vector called trs_match_all whose bits
// indicate which offset(s) matches the entire 30-bit TRS preamble.
//
// After the starting position of the TRS preamble has been detected, it must
// be encoded into an offset value which can drive the barrel shifter. The
// TRS encoder generates a 4-bit offset_val which contains the bit offset of
// the TRS preamble. It also generates a trs_error signal which is asserted if
// more than one start position is detected simultaneously.
// 
assign sd_in_vector = {d[18:10], in_reg[19:10], dly_reg[19:10], dly_reg2[19:10]};

// first level of gates

always @ (*)
    begin
        sd_trs_match1_l1[ 0] =  &sd_in_vector[ 3: 0];
        sd_trs_match1_l1[ 1] =  &sd_in_vector[ 4: 1];
        sd_trs_match1_l1[ 2] =  &sd_in_vector[ 5: 2];
        sd_trs_match1_l1[ 3] =  &sd_in_vector[ 6: 3];
        sd_trs_match1_l1[ 4] =  &sd_in_vector[ 7: 4];
        sd_trs_match1_l1[ 5] =  &sd_in_vector[ 8: 5];
        sd_trs_match1_l1[ 6] =  &sd_in_vector[ 9: 6];
        sd_trs_match1_l1[ 7] =  &sd_in_vector[10: 7];
        sd_trs_match1_l1[ 8] =  &sd_in_vector[11: 8];
        sd_trs_match1_l1[ 9] =  &sd_in_vector[12: 9];
        sd_trs_match1_l1[10] =  &sd_in_vector[13:10];
        sd_trs_match1_l1[11] =  &sd_in_vector[14:11];
        sd_trs_match1_l1[12] =  &sd_in_vector[15:12];
        sd_trs_match1_l1[13] =  &sd_in_vector[16:13];
        sd_trs_match1_l1[14] =  &sd_in_vector[17:14];
        sd_trs_match1_l1[15] =  &sd_in_vector[18:15];

        sd_trs_match2_l1[ 0] = ~|sd_in_vector[13:10];
        sd_trs_match2_l1[ 1] = ~|sd_in_vector[14:11];
        sd_trs_match2_l1[ 2] = ~|sd_in_vector[15:12];
        sd_trs_match2_l1[ 3] = ~|sd_in_vector[16:13];
        sd_trs_match2_l1[ 4] = ~|sd_in_vector[17:14];
        sd_trs_match2_l1[ 5] = ~|sd_in_vector[18:15];
        sd_trs_match2_l1[ 6] = ~|sd_in_vector[19:16];
        sd_trs_match2_l1[ 7] = ~|sd_in_vector[20:17];
        sd_trs_match2_l1[ 8] = ~|sd_in_vector[21:18];
        sd_trs_match2_l1[ 9] = ~|sd_in_vector[22:19];
        sd_trs_match2_l1[10] = ~|sd_in_vector[23:20];
        sd_trs_match2_l1[11] = ~|sd_in_vector[24:21];
        sd_trs_match2_l1[12] = ~|sd_in_vector[25:22];
        sd_trs_match2_l1[13] = ~|sd_in_vector[26:23];
        sd_trs_match2_l1[14] = ~|sd_in_vector[27:24];
        sd_trs_match2_l1[15] = ~|sd_in_vector[28:25];

        sd_trs_match3_l1[ 0] = ~|sd_in_vector[23:20];
        sd_trs_match3_l1[ 1] = ~|sd_in_vector[24:21];
        sd_trs_match3_l1[ 2] = ~|sd_in_vector[25:22];
        sd_trs_match3_l1[ 3] = ~|sd_in_vector[26:23];
        sd_trs_match3_l1[ 4] = ~|sd_in_vector[27:24];
        sd_trs_match3_l1[ 5] = ~|sd_in_vector[28:25];
        sd_trs_match3_l1[ 6] = ~|sd_in_vector[29:26];
        sd_trs_match3_l1[ 7] = ~|sd_in_vector[30:27];
        sd_trs_match3_l1[ 8] = ~|sd_in_vector[31:28];
        sd_trs_match3_l1[ 9] = ~|sd_in_vector[32:29];
        sd_trs_match3_l1[10] = ~|sd_in_vector[33:30];
        sd_trs_match3_l1[11] = ~|sd_in_vector[34:31];
        sd_trs_match3_l1[12] = ~|sd_in_vector[35:32];
        sd_trs_match3_l1[13] = ~|sd_in_vector[36:33];
        sd_trs_match3_l1[14] = ~|sd_in_vector[37:34];
        sd_trs_match3_l1[15] = ~|sd_in_vector[38:35];
    end

// second level of gates

always @ (*)
    begin
        sd_trs_match1[0] = sd_trs_match1_l1[ 0] & sd_trs_match1_l1[ 4] & 
                           sd_trs_match1_l1[ 6];
        sd_trs_match1[1] = sd_trs_match1_l1[ 1] & sd_trs_match1_l1[ 5] & 
                           sd_trs_match1_l1[ 7];
        sd_trs_match1[2] = sd_trs_match1_l1[ 2] & sd_trs_match1_l1[ 6] & 
                           sd_trs_match1_l1[ 8];
        sd_trs_match1[3] = sd_trs_match1_l1[ 3] & sd_trs_match1_l1[ 7] & 
                           sd_trs_match1_l1[ 9];
        sd_trs_match1[4] = sd_trs_match1_l1[ 4] & sd_trs_match1_l1[ 8] & 
                           sd_trs_match1_l1[10];
        sd_trs_match1[5] = sd_trs_match1_l1[ 5] & sd_trs_match1_l1[ 9] & 
                           sd_trs_match1_l1[11];
        sd_trs_match1[6] = sd_trs_match1_l1[ 6] & sd_trs_match1_l1[10] & 
                           sd_trs_match1_l1[12];
        sd_trs_match1[7] = sd_trs_match1_l1[ 7] & sd_trs_match1_l1[11] & 
                           sd_trs_match1_l1[13];
        sd_trs_match1[8] = sd_trs_match1_l1[ 8] & sd_trs_match1_l1[12] & 
                           sd_trs_match1_l1[14];
        sd_trs_match1[9] = sd_trs_match1_l1[ 9] & sd_trs_match1_l1[13] & 
                           sd_trs_match1_l1[15];
    end

always @ (*)
    begin
        sd_trs_match2[0] = sd_trs_match2_l1[ 0] & sd_trs_match2_l1[ 4] & 
                           sd_trs_match2_l1[ 6];
        sd_trs_match2[1] = sd_trs_match2_l1[ 1] & sd_trs_match2_l1[ 5] & 
                           sd_trs_match2_l1[ 7];
        sd_trs_match2[2] = sd_trs_match2_l1[ 2] & sd_trs_match2_l1[ 6] & 
                           sd_trs_match2_l1[ 8];
        sd_trs_match2[3] = sd_trs_match2_l1[ 3] & sd_trs_match2_l1[ 7] & 
                           sd_trs_match2_l1[ 9];
        sd_trs_match2[4] = sd_trs_match2_l1[ 4] & sd_trs_match2_l1[ 8] & 
                           sd_trs_match2_l1[10];
        sd_trs_match2[5] = sd_trs_match2_l1[ 5] & sd_trs_match2_l1[ 9] & 
                           sd_trs_match2_l1[11];
        sd_trs_match2[6] = sd_trs_match2_l1[ 6] & sd_trs_match2_l1[10] & 
                           sd_trs_match2_l1[12];
        sd_trs_match2[7] = sd_trs_match2_l1[ 7] & sd_trs_match2_l1[11] & 
                           sd_trs_match2_l1[13];
        sd_trs_match2[8] = sd_trs_match2_l1[ 8] & sd_trs_match2_l1[12] & 
                           sd_trs_match2_l1[14];
        sd_trs_match2[9] = sd_trs_match2_l1[ 9] & sd_trs_match2_l1[13] & 
                           sd_trs_match2_l1[15];
    end

always @ (*)
    begin
        sd_trs_match3[0] = sd_trs_match3_l1[ 0] & sd_trs_match3_l1[ 4] & 
                           sd_trs_match3_l1[ 6];
        sd_trs_match3[1] = sd_trs_match3_l1[ 1] & sd_trs_match3_l1[ 5] & 
                           sd_trs_match3_l1[ 7];
        sd_trs_match3[2] = sd_trs_match3_l1[ 2] & sd_trs_match3_l1[ 6] & 
                           sd_trs_match3_l1[ 8];
        sd_trs_match3[3] = sd_trs_match3_l1[ 3] & sd_trs_match3_l1[ 7] & 
                           sd_trs_match3_l1[ 9];
        sd_trs_match3[4] = sd_trs_match3_l1[ 4] & sd_trs_match3_l1[ 8] & 
                           sd_trs_match3_l1[10];
        sd_trs_match3[5] = sd_trs_match3_l1[ 5] & sd_trs_match3_l1[ 9] & 
                           sd_trs_match3_l1[11];
        sd_trs_match3[6] = sd_trs_match3_l1[ 6] & sd_trs_match3_l1[10] & 
                           sd_trs_match3_l1[12];
        sd_trs_match3[7] = sd_trs_match3_l1[ 7] & sd_trs_match3_l1[11] & 
                           sd_trs_match3_l1[13];
        sd_trs_match3[8] = sd_trs_match3_l1[ 8] & sd_trs_match3_l1[12] & 
                           sd_trs_match3_l1[14];
        sd_trs_match3[9] = sd_trs_match3_l1[ 9] & sd_trs_match3_l1[13] & 
                           sd_trs_match3_l1[15];
    end

//
// third level of gates generates a unary bit pattern indicating which offsets
// contain valid TRS symbols
//
assign sd_trs_match_all = sd_trs_match1 & sd_trs_match2 & sd_trs_match3;

//
// If any of the bits in sd_trs_match_all are asserted, the assert trs_detected        
//
assign sd_trs_detected = |sd_trs_match_all;

//
// The following asserts trs_error if more than one bit is set in 
// sd_trs_match_all
//
always @ (*)
    case (sd_trs_match_all)
        10'b00_0000_0000: sd_trs_err  <= 0;
        10'b00_0000_0001: sd_trs_err  <= 0;
        10'b00_0000_0010: sd_trs_err  <= 0;
        10'b00_0000_0100: sd_trs_err  <= 0;
        10'b00_0000_1000: sd_trs_err  <= 0;
        10'b00_0001_0000: sd_trs_err  <= 0;
        10'b00_0010_0000: sd_trs_err  <= 0;
        10'b00_0100_0000: sd_trs_err  <= 0;
        10'b00_1000_0000: sd_trs_err  <= 0;
        10'b01_0000_0000: sd_trs_err  <= 0;
        10'b10_0000_0000: sd_trs_err  <= 0;
        default:          sd_trs_err  <= 1;
    endcase

//
// The following assignments encode the sd_trs_match_all vector into a binary
// offset code.
//
assign sd_offset_val[0] = sd_trs_match_all[1] | sd_trs_match_all[3] | 
                          sd_trs_match_all[5] | sd_trs_match_all[7] | 
                          sd_trs_match_all[9];

assign sd_offset_val[1] = sd_trs_match_all[2] | sd_trs_match_all[3] | 
                          sd_trs_match_all[6] |
                          sd_trs_match_all[7];

assign sd_offset_val[2] = sd_trs_match_all[4] | sd_trs_match_all[5] | 
                          sd_trs_match_all[6] | sd_trs_match_all[7];

assign sd_offset_val[3] = sd_trs_match_all[8] | sd_trs_match_all[9];

//------------------------------------------------------------------------------
// Offset register & new start position detection
//

//
// HD/SD muxes for the trs_detected and offset_val signals
//
assign trs_detected = hd_sd ? sd_trs_detected : hd_trs_detected;
assign offset_val = hd_sd ? {1'b0, sd_offset_val} : hd_offset_val;

//
// offset_reg: barrel shifter offset register
//
// The offset_reg loads the offset_val whenever trs_detected is
// asserted and frame_en is asserted.
//
always @ (posedge clk)
    if (ce) 
    begin
        if (rst)
            offset_reg <= 0;
        else if (trs_detected & frame_en)
            offset_reg <= offset_val;
    end

//
// New start position detector
// 
// A comparison between offset_val and offset_reg determines if
// the new offset is different than the current one. If there is
// a mismatch and frame_en is not asserted, then the nsp output
// will be asserted.
//
assign new_offset = offset_val != offset_reg;

always @ (posedge clk)
    if (ce)        
    begin
        if (rst)
            nsp <= 1'b1;
        else if (trs_detected)
            nsp <= ~frame_en & new_offset;
    end

//------------------------------------------------------------------------------
// Barrel shifter
//

//
// barrel shifter input register
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            barrel_in <= 0;
        else
            barrel_in <= hd_sd ? 
                     {dly_reg[18:0], 1'b0, dly_reg[18:10], dly_reg2[19:10]} : {dly_reg[18:0], dly_reg2};
    end

//
// barrel shifter
//
// The barrel shifter extracts a 20-bit field from the bs_in vector.
// The bits extracted depend on the value of the offset_reg. 
//
assign bs_in = {12'b0000_0000_0000, barrel_in};
assign bs_sel_1 = offset_reg[4];
assign bs_sel_2 = offset_reg[3:2];
assign bs_sel_3 = offset_reg[1:0];

always @ (*)
    for (i = 0; i < 35; i = i + 1)
        if (bs_sel_1)
            bs_1_out[i] = bs_in[i + 16];
        else
            bs_1_out[i] = bs_in[i];

always @ (*)
    for (j = 0; j < 23; j = j + 1)
        case (bs_sel_2)
            2'b00: bs_2_out[j] = bs_1_out[j];
            2'b01: bs_2_out[j] = bs_1_out[j + 4];
            2'b10: bs_2_out[j] = bs_1_out[j + 8]; 
            2'b11: bs_2_out[j] = bs_1_out[j + 12];
        endcase

always @ (*)
    for (k = 0; k < 20; k = k + 1)
        case (bs_sel_3)
            2'b00: barrel_out[k] = bs_2_out[k];
            2'b01: barrel_out[k] = bs_2_out[k + 1];
            2'b10: barrel_out[k] = bs_2_out[k + 2];
            2'b11: barrel_out[k] = bs_2_out[k + 3];
        endcase

//
// Output registers
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
        begin
            c_int <= 0;
            y_int <= 0;
        end
        else
        begin
            c_int <= barrel_out[9:0];
            y_int <= hd_sd ? barrel_out[9:0] : barrel_out[19:10];
        end
    end

assign c = c_int;
assign y = y_int;

//
// trs: trs output generation logic
//
// The trs_out register is a 4-bit shift register which shifts every time
// the bit_cntr[0] bit is asserted. The trs output signal is the OR of
// the four bits in this register so it becomes asserted when the first
// character of the TRS symbol is output and remains asserted for the
// following three characters of the TRS symbol.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            trs_out <= 0;
        else
            trs_out <= {trs_detected, trs_out[3:1]};
    end

always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            trs <= 1'b0;
        else
            trs <= |trs_out;
    end

always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            xyz_int <= 1'b0;
        else
            xyz_int <= trs_out[0];
    end

assign xyz = xyz_int;
assign eav = xyz_int & y_int[6];
assign sav = xyz_int & ~y_int[6];

//
// TRS error detector
//
// This code examines the protection bits in the XYZ word and asserts the 
// trs_err output if an error is detected.
//
assign hd_trs_err = xyz_int & (
                    (y_int[5] ^ y_int[6] ^ y_int[7]) |
                    (y_int[4] ^ y_int[8] ^ y_int[6]) |
                    (y_int[3] ^ y_int[8] ^ y_int[7]) |
                    (y_int[2] ^ y_int[8] ^ y_int[7] ^ y_int[6]) |
                    ~y_int[9] | y_int[1] | y_int[0]);

assign trs_err = hd_sd ? sd_trs_err : hd_trs_err;

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
Module Description:

This module implements an optimized 12:1 MUX. The width of the MUX is set by the
parameter WIDTH.
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_mux12_wide #(
    parameter WIDTH = 10)                   // bit width of input & output vectors
(
    input  wire [WIDTH-1:0] d0,             // input vector 0
    input  wire [WIDTH-1:0] d1,             // input vector 1
    input  wire [WIDTH-1:0] d2,             // input vector 2
    input  wire [WIDTH-1:0] d3,             // input vector 3
    input  wire [WIDTH-1:0] d4,             // input vector 4
    input  wire [WIDTH-1:0] d5,             // input vector 5
    input  wire [WIDTH-1:0] d6,             // input vector 6
    input  wire [WIDTH-1:0] d7,             // input vector 7
    input  wire [WIDTH-1:0] d8,             // input vector 8
    input  wire [WIDTH-1:0] d9,             // input vector 9
    input  wire [WIDTH-1:0] d10,            // input vector 10
    input  wire [WIDTH-1:0] d11,            // input vector 11
    input  wire [3:0]       sel,            // select inputs
    output reg  [WIDTH-1:0] y               // output port
);

always @ (*)
    case(sel)
        4'b0001 :   y = d1;
        4'b0010 :   y = d2;
        4'b0011 :   y = d3;
        4'b0100 :   y = d4;
        4'b0101 :   y = d5;
        4'b0110 :   y = d6;
        4'b0111 :   y = d7;
        4'b1000 :   y = d8;
        4'b1001 :   y = d9;
        4'b1010 :   y = d10;
        4'b1011 :   y = d11;
        default:    y = d0;
    endcase
endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
Module Description:

This module performs the bit replication of the incoming data, 11 times and 
sends out 20 bits on every clock cycle. This module requires an alternating
cadence of 5/6/5/6 on the clock enable (ce) input. The state machine 
automatically aligns itself regardless of whether the first step of the 
cadence is 5 or 6 when it starts up. If the 5/6/5/6 cadence gets out of step,
the state machine will realign itself and will also assert the align_err
output for one clock cycle.

--------------------------------------------------------------------------------
*/

`timescale 1ns / 1ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_sdi_bitrep_20b (
    input  wire             clk,                // clock input
    input  wire             rst,                // sync reset 
    input  wire             ce,                 // clock enable 
    input  wire [9:0]       d,                  // input data
    output reg  [19:0]      q = 0,              // output data
    output reg              align_err = 1'b0);  // ce alignment error



//-------------------------------------------------------------------
// Parameter definitions
//

localparam STATE_WIDTH = 4;
localparam STATE_MSB   = STATE_WIDTH - 1;

localparam [STATE_MSB:0] 
    START = 4'b1111,
    S0    = 4'b0000,
    S1    = 4'b0001,
    S2    = 4'b0010,
    S3    = 4'b0011,
    S4    = 4'b0100,
    S5    = 4'b0101,
    S6    = 4'b0110,
    S7    = 4'b0111,
    S8    = 4'b1000,
    S9    = 4'b1001,
    S10   = 4'b1010,
    S5X   = 4'b1011;
  
//--------------------------------------------------------------------
// Signal definitions
//

reg  [STATE_MSB:0]  current_state = START;
reg  [STATE_MSB:0]  next_state;
reg  [9:0]          in_reg = 0;
reg  [9:0]          d_reg = 0;
reg                 b9_save = 1'b0;
reg                 ce_dly = 1'b0;
wire [19:0]         q_int;

//
// Input registers
//
always @ (posedge clk)
    if (ce)
        in_reg <= d;
        
always @ (posedge clk)
    ce_dly <= ce;
    
always @ (posedge clk)
    if (ce_dly)
        d_reg <= in_reg;                

always @ (posedge clk)
    if (ce_dly)
        b9_save <= d_reg[9];

//
// FSM: current_state register
//
// This code implements the current state register. It loads with the S0
// state on reset and the next_state value with each rising clock edge.
//
always @ (posedge clk)
    if (rst)
        current_state <= START;
    else 
        current_state <= next_state;
        

// FSM: next_state logic
//
// This case statement generates the next_state value for the FSM based on
// the current_state and the various FSM inputs.
//        
always@ *
    case(current_state)
        START:  if (ce_dly)
                    next_state = S0;
                else
                    next_state = START;
        
        S0:     next_state = S1;
        
        S1:     next_state = S2;
        
        S2:     next_state = S3;
        
        S3:     next_state = S4;
        
        S4:     if (ce_dly) 
                    next_state = S5;
                else
                    next_state = S5X;
        
        S5:     next_state = S6;            // Two different state 5's depending
                                            // on when the occurred
        S5X:    next_state = S6;
        
        S6:     next_state = S7;
        
        S7:     next_state = S8;
        
        S8:     next_state = S9;
        
        S9:     next_state = S10;
        
        S10:    if (ce_dly) 
                    next_state = S0; 
                else 
                    next_state = START;
        
        default: next_state = START; 
    endcase 

//
// Output mux
//
// Use the current state encoding to select the output bits.
//

v_smpte_sdi_v3_0_8_mux12_wide #(
    .WIDTH  (20)) 
OUTMUX (
    .d0     ({ {9{d_reg[1]}}, {11{d_reg[0]}}}),                 // state S0
    .d1     ({ {7{d_reg[3]}}, {11{d_reg[2]}}, {2{d_reg[1]}}}),  // state S1
    .d2     ({ {5{d_reg[5]}}, {11{d_reg[4]}}, {4{d_reg[3]}}}),  // state S2
    .d3     ({ {3{d_reg[7]}}, {11{d_reg[6]}}, {6{d_reg[5]}}}),  // state S3
    .d4     ({    d_reg[9],   {11{d_reg[8]}}, {8{d_reg[7]}}}),  // state S4
    .d5     ({{10{d_reg[0]}}, {10{b9_save}}}),                  // state S5
    .d6     ({ {8{d_reg[2]}}, {11{d_reg[1]}},    d_reg[0]}),    // state S6
    .d7     ({ {6{d_reg[4]}}, {11{d_reg[3]}}, {3{d_reg[2]}}}),  // state S7
    .d8     ({ {4{d_reg[6]}}, {11{d_reg[5]}}, {5{d_reg[4]}}}),  // state S8
    .d9     ({ {2{d_reg[8]}}, {11{d_reg[7]}}, {7{d_reg[6]}}}),  // state S9
    .d10    ({{11{d_reg[9]}}, { 9{d_reg[8]}}}),                 // state S10
    .d11    ({{10{in_reg[0]}},{10{d_reg[9]}}}),                 // state S5X
    .sel    (current_state),
    .y      (q_int));

always @ (posedge clk)
    q <= q_int;
        
always @ (posedge clk)
    align_err <= ((current_state == S10) || (current_state == S5X)) & ~ce_dly;

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
Module Description:

This module captures the SMPTE 352M video payload ID packet. The payload
output port is only updated when the packet does not have a checksum error. 
The vpid_valid output is asserted as long at least one valid packet has 
been detected in the last VPID_TIMEOUT_VBLANKS vertical blanking intervals.
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_SMPTE352_vpid_capture #(  
    parameter VPID_TIMEOUT_VBLANKS = 4)
( 
    // inputs
    input  wire         clk,            // clock input
    input  wire         ce,             // clock enable
    input  wire         rst,            // sync reset input
    input  wire         sav,            // asserted on XYZ word of SAV
    input  wire [9:0]   vid_in,         // video data input
        
    // outputs
    output reg  [31:0]  payload = 0,    // {byte 4, byte 3, byte 2, byte 1}
    output reg          valid = 1'b0    // 1 when payload is valid
);

//-----------------------------------------------------------------------------
// Parameter definitions
//      

//
// This group of parameters defines the states of the finite state machine.
//
localparam STATE_WIDTH   = 4;
localparam STATE_MSB     = STATE_WIDTH - 1;

localparam [STATE_WIDTH-1:0]
    STATE_START     = 0,
    STATE_ADF2      = 1,
    STATE_ADF3      = 2,
    STATE_DID       = 3,
    STATE_SDID      = 4,
    STATE_DC        = 5,
    STATE_UDW0      = 6,
    STATE_UDW1      = 7,
    STATE_UDW2      = 8,
    STATE_UDW3      = 9,
    STATE_CS        = 10;

localparam MUXSEL_MSB = 2;

localparam [MUXSEL_MSB:0]
    MUX_SEL_000     = 0,
    MUX_SEL_3FF     = 1,
    MUX_SEL_DID     = 2,
    MUX_SEL_SDID    = 3,
    MUX_SEL_DC      = 4,
    MUX_SEL_CS      = 5;

localparam SR_MSB = VPID_TIMEOUT_VBLANKS - 1;

reg  [STATE_MSB:0]  current_state = STATE_START;
reg  [STATE_MSB:0]  next_state;
reg  [8:0]          checksum = 0;
reg                 old_v = 0;
reg                 v = 0;
wire                v_fall;
wire                v_rise;
reg                 packet_rx = 0;
reg [SR_MSB:0]      packet_det = 0;
reg [7:0]           byte1 = 0;
reg [7:0]           byte2 = 0;
reg [7:0]           byte3 = 0;
reg [7:0]           byte4 = 0;
reg                 ld_byte1;
reg                 ld_byte2;
reg                 ld_byte3;
reg                 ld_byte4;
reg                 ld_cs_err;
reg                 clr_cs;
reg [MUXSEL_MSB:0]  cmp_mux_sel;
reg [9:0]           cmp_mux;
wire                cmp_equal;
reg                 packet_ok = 1'b0;


//
// FSM: current_state register
//
// This code implements the current state register. 
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            current_state <= STATE_START;
        else
            current_state <= next_state;
    end

//
// FSM: next_state logic
//
// This case statement generates the next_state value for the FSM based on
// the current_state and the various FSM inputs.
//
always @ (*)
    case(current_state)
        STATE_START:
            if (cmp_equal)
                next_state = STATE_ADF2;
            else
                next_state = STATE_START;
                
        STATE_ADF2:
            if (cmp_equal)
                next_state = STATE_ADF3;
            else
                next_state = STATE_START;

        STATE_ADF3:
            if (cmp_equal)
                next_state = STATE_DID;
            else
                next_state = STATE_START;

        STATE_DID:
            if (cmp_equal)
                next_state = STATE_SDID;
            else
                next_state = STATE_START;

        STATE_SDID:
            if (cmp_equal)
                next_state = STATE_DC;
            else
                next_state = STATE_START;

        STATE_DC:
            if (cmp_equal)
                next_state = STATE_UDW0;
            else
                next_state = STATE_START;

        STATE_UDW0:
            next_state = STATE_UDW1;

        STATE_UDW1:
            next_state = STATE_UDW2;

        STATE_UDW2:
            next_state = STATE_UDW3;

        STATE_UDW3:
            next_state = STATE_CS;

        STATE_CS:
            next_state = STATE_START;

        default:    next_state = STATE_START;
    endcase
        
//
// FSM: outputs
//
// This block decodes the current state to generate the various outputs of the
// FSM.
//
always @ (*)
    begin
        // Unless specifically assigned in the case statement, all FSM outputs
        // are given the values assigned here.
        ld_byte1    = 1'b0;
        ld_byte2    = 1'b0;
        ld_byte3    = 1'b0;
        ld_byte4    = 1'b0;
        ld_cs_err   = 1'b0;
        clr_cs      = 1'b0;
        cmp_mux_sel = MUX_SEL_000;
                                
        case(current_state) 

            STATE_START:    clr_cs = 1'b1;

            STATE_ADF2:     begin
                                cmp_mux_sel = MUX_SEL_3FF;
                                clr_cs = 1'b1;
                            end

            STATE_ADF3:     begin
                                cmp_mux_sel = MUX_SEL_3FF;
                                clr_cs = 1'b1;
                            end

            STATE_DID:      cmp_mux_sel = MUX_SEL_DID;

            STATE_SDID:     cmp_mux_sel = MUX_SEL_SDID;

            STATE_DC:       cmp_mux_sel = MUX_SEL_DC;

            STATE_UDW0:     ld_byte1 = 1'b1;

            STATE_UDW1:     ld_byte2 = 1'b1;

            STATE_UDW2:     ld_byte3 = 1'b1;

            STATE_UDW3:     ld_byte4 = 1'b1;

            STATE_CS:       begin
                                cmp_mux_sel = MUX_SEL_CS;
                                ld_cs_err = 1'b1;
                            end
        endcase
    end

//
// Comparator
//
// Compares the expected value of each word, except the user data words, to the
// received value.
//
always @ (*)
    case(cmp_mux_sel)
        MUX_SEL_000:    cmp_mux = 10'h000;
        MUX_SEL_3FF:    cmp_mux = 10'h3ff;
        MUX_SEL_DID:    cmp_mux = 10'h241;
        MUX_SEL_SDID:   cmp_mux = 10'h101;
        MUX_SEL_DC:     cmp_mux = 10'h104;
        MUX_SEL_CS:     cmp_mux = {~checksum[8], checksum};
        default:        cmp_mux = 10'h000;
    endcase

assign cmp_equal = cmp_mux == vid_in;

//
// User data word registers
//
always @ (posedge clk)
    if (ce & ld_byte1)
        byte1 <= vid_in[7:0];

always @ (posedge clk)
    if (ce & ld_byte2)
        byte2 <= vid_in[7:0];

always @ (posedge clk)
    if (ce & ld_byte3)
        byte3 <= vid_in[7:0];

always @ (posedge clk)
    if (ce & ld_byte4)
        byte4 <= vid_in[7:0];

//
// Checksum generation and error flag
//
always @ (posedge clk)
    if (ce) begin
        if (clr_cs)
            checksum <= 0;
        else
            checksum <= checksum + vid_in[8:0];
    end
    
always @ (posedge clk)
    if (ce) 
        packet_ok <= ld_cs_err & cmp_equal;

//
// Packet valid signal generation
//
// The valid output is updated immediatly if a packet is received. Once a
// packet has been detected in any of the last VPID_TIMEOUT_VBLANKS blanking 
// intervals, the valid output will be asserted.
//
always @ (posedge clk)
    if (ce & sav) begin
        v <= vid_in[7];
        old_v <= v;
    end
    
assign v_fall = old_v & ~v;
assign v_rise = ~old_v & v;

always @ (posedge clk)
    if (ce) begin
        if (packet_ok)
            packet_rx <= 1'b1;
        else if (v_rise)
            packet_rx <= 1'b0;
    end

always @ (posedge clk)
    if (ce & v_fall)
        packet_det <= {packet_det[SR_MSB - 1: 0], packet_rx};

always @ (posedge clk) 
    if (ce)
        valid <= packet_rx | (|packet_det);
         
//
// Output registers
//
// The payload register is loaded from the captured bytes at the same time that
// packet_rx is set -- when packet_ok is asserted.
//
always @ (posedge clk)
    if (ce & packet_ok)
        payload <= {byte4, byte3, byte2, byte1};

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
Module Description:

This module inserts SMPTE 352M video payload ID packets into a video stream.
The stream may be either HD or SD, as indicated by the hd_sd input signal.
The module will overwrite an existing VPID packet if the overwrite input
is asserted, otherwise if a VPID packet exists in the HANC space, it will
not be overwritten and a new packet will not be inserted.

The module does not create the user data words of the VPID packet. Those
are generated externally and enter the module on the byte1, byte2, byte3,
and byte4 ports.

The module requires an interface line number on its input. This line number
must be valid for the new line one clock cycle before the start of the
HANC space -- that is during the second CRC word following the EAV.

If the overwrite input is 1, this module will also deleted any VPID packets
that occur elsewhere in any HANC space. These packets will be marked as
deleted packets.

When the level_b input is 1, then the module works a little bit differently.
It will always overwrite the first data word of the VPID packet with the value
present on the byte1 input port, even if overwrite is 0. This is because
conversions from dual link to level B 3G-SDI require the first byte to be
modified. The checksum is recalculated and inserted.

This module is compliant with the 2007 revision of SMPTE 425M for inserting
SMPTE 352M VPID packets in level B streams.
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_SMPTE352_vpid_insert (
    input  wire             clk,            // clock input
    input  wire             ce,             // clock enable
    input  wire             rst,            // sync reset input
    input  wire             hd_sd,          // 0 = HD, 1 = SD
    input  wire             level_b,        // 1 = SMPTE 425M Level B
    input  wire             enable,         // 0 = disable insertion
    input  wire             overwrite,      // 1 = overwrite existing packets
    input  wire [10:0]      line,           // current video line
    input  wire [10:0]      line_a,         // field 1 line for packet insertion
    input  wire [10:0]      line_b,         // field 2 line for packet insertion
    input  wire             line_b_en,      // 1 = use line_b, 0 = ignore line_b
    input  wire [7:0]       byte1,          // first byte of VPID data
    input  wire [7:0]       byte2,          // second byte of VPID data
    input  wire [7:0]       byte3,          // third byte of VPID data
    input  wire [7:0]       byte4,          // fourth byte of VPID data
    input  wire [9:0]       y_in,           // Y data stream in
    input  wire [9:0]       c_in,           // C data stream in
    output reg  [9:0]       y_out = 0,      // Y data stream out
    output reg  [9:0]       c_out = 0,      // C data stream out
    output reg              eav_out = 0,    // asserted on XYZ word of EAV
    output reg              sav_out = 0     // asserted on XYZ word of SAV
);

localparam STATE_WIDTH   = 6;
localparam STATE_MSB     = STATE_WIDTH - 1;

localparam [STATE_WIDTH-1:0]
    STATE_WAIT      = 6'd0,
    STATE_ADF0      = 6'd1,
    STATE_ADF1      = 6'd2,
    STATE_ADF2      = 6'd3,
    STATE_DID       = 6'd4,
    STATE_SDID      = 6'd5,
    STATE_DC        = 6'd6,
    STATE_B0        = 6'd7,
    STATE_B1        = 6'd8,
    STATE_B2        = 6'd9,
    STATE_B3        = 6'd10,
    STATE_CS        = 6'd11,
    STATE_DID2      = 6'd12,
    STATE_SDID2     = 6'd13,
    STATE_DC2       = 6'd14,
    STATE_UDW       = 6'd15,
    STATE_CS2       = 6'd16,
    STATE_INS_ADF0  = 6'd17,
    STATE_INS_ADF1  = 6'd18,
    STATE_INS_ADF2  = 6'd19,
    STATE_INS_DID   = 6'd20,
    STATE_INS_SDID  = 6'd21,
    STATE_INS_DC    = 6'd22,
    STATE_INS_B0    = 6'd23,
    STATE_INS_B1    = 6'd24,
    STATE_INS_B2    = 6'd25,
    STATE_INS_B3    = 6'd26,
    STATE_ADF0_X    = 6'd27,
    STATE_ADF1_X    = 6'd28,
    STATE_ADF2_X    = 6'd29,
    STATE_DID_X     = 6'd30,
    STATE_SDID_X    = 6'd31,
    STATE_DC_X      = 6'd32,
    STATE_UDW_X     = 6'd33,
    STATE_CS_X      = 6'd34;
        
localparam [3:0]
    MUX_SEL_000     = 4'd0,
    MUX_SEL_3FF     = 4'd1,
    MUX_SEL_DID     = 4'd2,
    MUX_SEL_SDID    = 4'd3,
    MUX_SEL_DC      = 4'd4,
    MUX_SEL_UDW     = 4'd5,
    MUX_SEL_CS      = 4'd6,
    MUX_SEL_DEL     = 4'd7,
    MUX_SEL_VID     = 4'd8;

// internal signals
reg     [9:0]   vid_reg0 = 0;           // video pipeline register
reg     [9:0]   vid_reg1 = 0;           // video pipeline register
reg     [9:0]   vid_reg2 = 0;           // video pipeline register
reg     [9:0]   vid_dly = 0;            // last stage of video pipeline
wire            all_ones_in;            // asserted when in_reg is all ones
wire            all_zeros_in;           // asserted when in_reg is all zeros
reg     [2:0]   all_zeros_pipe = 0;     // delay pipe for all zeros
reg     [2:0]   all_ones_pipe = 0;      // delay pipe for all ones
wire            xyz;                    // current word is the XYZ word
wire            eav_next;               // 1 = next word is first word of EAV
wire            sav_next;               // 1 = next word is first word of SAV
wire            anc_next;               // 1 = next word is first word of ANC
wire            hanc_start_next;        // 1 = next word is first word of HANC
reg     [3:0]   hanc_dly;               // delay value from xyz to hanc_start_next
reg     [15:0]  hanc_dly_srl = 0;       // SRL reg used to generate hanc_start_next
reg     [9:0]   in_reg = 0;             // input register
reg     [9:0]   vid_out = 0;            // internal version of y_out
wire            line_match_a;           // output of line_a comparitor
wire            line_match_b;           // output of line_b comparitor
reg             vpid_line = 0;          // 1 = insert VPID packet on this line
wire            vpid_pkt;               // 1 = ANC packet is a VPID
wire            del_pkt_ok;             // 1 = ANC act is deleted packet with
reg     [7:0]   udw_cntr = 0;           // user data word counter
wire    [7:0]   udw_cntr_mux;           // mux on input of udw_cntr
reg             ld_udw_cntr;            // 1 = load udw_cntr
wire            udw_cntr_tc;            // 1 = udw_cntr == 0
reg     [8:0]   cs_reg = 0;             // checksum generation register
reg             clr_cs_reg;             // 1 = clear cs_reg to 0
reg     [7:0]   vpid_mux;               // selects the VPID byte to be output 
reg     [1:0]   vpid_mux_sel;           // controls vpid_mux
reg     [3:0]   out_mux_sel;            // controls the vid_out data mux
wire            parity;                 // parity calculation
reg     [3:0]   sav_timing = 0;         // shift register for generating sav_out
reg     [3:0]   eav_timing = 0;         // shift register for generating eav_out
reg     [9:0]   cdly0 = 0;
reg     [9:0]   cdly1 = 0;
reg     [9:0]   cdly2 = 0;
reg     [9:0]   cdly3 = 0;
reg     [9:0]   cdly4 = 0;

reg     [STATE_MSB:0]   current_state = STATE_WAIT;     // FSM current state
reg     [STATE_MSB:0]   next_state;                     // FSM next state

reg     [7:0]   byte1_reg = 0;
reg     [7:0]   byte2_reg = 0;
reg     [7:0]   byte3_reg = 0;
reg     [7:0]   byte4_reg = 0;

//
// Input registers and video pipeline registers
//
always @ (posedge clk)
    if (ce) begin
        in_reg    <= y_in;
        vid_reg0  <= in_reg;
        vid_reg1  <= vid_reg0;
        vid_reg2  <= vid_reg1;
        vid_dly   <= vid_reg2;
        byte1_reg <= byte1;
        byte2_reg <= byte2;
        byte3_reg <= byte3;
        byte4_reg <= byte4;
    end

//
// all ones and all zeros detectors
//
assign all_ones_in = &in_reg;
assign all_zeros_in = ~|in_reg;

always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            all_zeros_pipe <= 0;
        else
            all_zeros_pipe <= {all_zeros_pipe[1:0], all_zeros_in};
    end

always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            all_ones_pipe <= 0;
        else
            all_ones_pipe <= {all_ones_pipe[1:0], all_ones_in};
    end

//
// EAV, SAV, and ADF detection
//
assign xyz = all_ones_pipe[2] & all_zeros_pipe[1] & all_zeros_pipe[0];

assign eav_next = xyz & in_reg[6];
assign sav_next = xyz & ~in_reg[6];
assign anc_next = all_zeros_pipe[2] & all_ones_pipe[1] & all_ones_pipe[0];

//
// This SRL16 is used to generate the hanc_start_next signal. The input to the
// shift register is eav_next. The depth of the shift register depends on 
// whether the video is HD or SD.
//
always @ (*)
    if (hd_sd)
        hanc_dly = 4'd3;
    else
        hanc_dly = 4'd7;

always @ (posedge clk)
    if (ce)
        hanc_dly_srl <= {hanc_dly_srl[14:0], eav_next};
        
assign hanc_start_next = hanc_dly_srl[hanc_dly];         
         
//
// Line number comparison
//
// Two comparators are used to determine if the current line number matches
// either of the two lines where the VPID packets are located. The second
// line can be disabled for progressive video by setting line_b_en low.
//
assign line_match_a = line == line_a;
assign line_match_b = line == line_b;

always @ (posedge clk)
    if (ce)
        vpid_line <= line_match_a | (line_match_b & line_b_en);

//
// DID/SDID match
//
// The vpid_pkt signal is asserted when the next two words in the video delay
// pipeline indicate a video payload ID packet. The del_pkt_ok signal is
// asserted when the data in the video delay pipeline indicates that a deleted
// ANC packet is present with a data count of at least 4.
//
assign vpid_pkt = vid_reg2[7:0] == 8'h41 && vid_reg1[7:0] == 8'h01;
assign del_pkt_ok = vid_reg2[7:0] == 8'h80 && vid_reg0[7:0] >= 8'h04;

//
// UDW counter
//
// This counter is used to cycle through the user data words of non-VPID ANC 
// packets that may be encountered before empty HANC space is found.
//
assign udw_cntr_mux = ld_udw_cntr ? vid_dly[7:0] : udw_cntr;
assign udw_cntr_tc = udw_cntr_mux == 8'h00;

always @ (posedge clk)
    if (ce)
        udw_cntr <= udw_cntr_mux - 1;

//
// Checksum generation
//
always @ (posedge clk)
    if (ce) begin
        if (clr_cs_reg)
            cs_reg <= 0;
        else
            cs_reg <= cs_reg + vid_out[8:0];
    end

//
// Video data path
//
always @ (*)
    case(vpid_mux_sel)
        2'b00:   vpid_mux = byte1_reg;
        2'b01:   vpid_mux = byte2_reg;
        2'b10:   vpid_mux = byte3_reg;
        default: vpid_mux = byte4_reg;
    endcase

assign parity = ^vpid_mux;

always @ (*)
    case(out_mux_sel)
        MUX_SEL_000:  vid_out = 10'h000;
        MUX_SEL_3FF:  vid_out = 10'h3ff;
        MUX_SEL_DID:  vid_out = 10'h241;   // DID
        MUX_SEL_SDID: vid_out = 10'h101;   // SDID
        MUX_SEL_DC:   vid_out = 10'h104;   // DC
        MUX_SEL_UDW:  vid_out = {~parity, parity, vpid_mux};
        MUX_SEL_CS:   vid_out = {~cs_reg[8], cs_reg};
        MUX_SEL_DEL:  vid_out = 10'h180;   // deleted pkt DID
        default:      vid_out = vid_dly;
    endcase

always @ (posedge clk)
    if (ce)
        y_out <= vid_out;

//
// Delay the C data stream by 6 clock cycles to match the Y data stream delay.
//
always @ (posedge clk)
    if (ce)
    begin
        cdly0 <= c_in;
        cdly1 <= cdly0;
        cdly2 <= cdly1;
        cdly3 <= cdly2;
        cdly4 <= cdly3;
        c_out <= cdly4;
    end

//
// EAV & SAV output generation
//
always @ (posedge clk)
    if (ce)
        eav_timing <= {eav_timing[2:0], eav_next};
        
always @ (posedge clk)
    if (ce)
        eav_out <= eav_timing[3];

always @ (posedge clk)
    if (ce)
        sav_timing <= {sav_timing[2:0], sav_next};

always @ (posedge clk)
    if (ce)
        sav_out <= sav_timing[3];

//
// FSM: current_state register
//
// This code implements the current state register. 
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            current_state <= STATE_WAIT;
        else if (ce)
        begin
            if (sav_next)
                current_state <= STATE_WAIT;
            else
                current_state <= next_state;
        end
    end

//
// FSM: next_state logic
//
// This case statement generates the next_state value for the FSM based on
// the current_state and the various FSM inputs.
//
always @ (*)
    case(current_state)
        STATE_WAIT:
            if (enable & vpid_line & hanc_start_next) begin
                if (anc_next)
                    next_state = STATE_ADF0;
                else
                    next_state = STATE_INS_ADF0;
            end else if (enable & ~vpid_line & anc_next & overwrite)
                next_state = STATE_ADF0_X;
            else    
                next_state = STATE_WAIT;
                
        STATE_ADF0:
            next_state = STATE_ADF1;

        STATE_ADF1:
            next_state = STATE_ADF2;

        STATE_ADF2:
            if (vpid_pkt)
                next_state = STATE_DID;
            else if (del_pkt_ok)
                next_state = STATE_INS_DID;
            else
                next_state = STATE_DID2;

        STATE_DID:
            next_state = STATE_SDID;

        STATE_SDID:
            if (overwrite)
                next_state = STATE_INS_DC;
            else
                next_state = STATE_DC;

        STATE_DC:
            next_state = STATE_B0;

        STATE_B0:
            next_state = STATE_B1;

        STATE_B1:
            next_state = STATE_B2;

        STATE_B2:
            next_state = STATE_B3;

        STATE_B3:
            next_state = STATE_CS;

        STATE_CS:
            next_state = STATE_WAIT;

        STATE_DID2:
            next_state = STATE_SDID2;

        STATE_SDID2:
            next_state = STATE_DC2;

        STATE_DC2:
            if (udw_cntr_tc)
                next_state = STATE_CS2;
            else
                next_state = STATE_UDW;

        STATE_UDW:
            if (udw_cntr_tc)
                next_state = STATE_CS2;
            else
                next_state = STATE_UDW;

        STATE_CS2:
            if (anc_next)
                next_state = STATE_ADF0;
            else
                next_state = STATE_INS_ADF0;

        STATE_INS_ADF0:
            next_state = STATE_INS_ADF1;

        STATE_INS_ADF1:
            next_state = STATE_INS_ADF2;

        STATE_INS_ADF2:
            next_state = STATE_INS_DID;

        STATE_INS_DID:
            next_state = STATE_INS_SDID;

        STATE_INS_SDID:
            next_state = STATE_INS_DC;

        STATE_INS_DC:
            next_state = STATE_INS_B0;

        STATE_INS_B0:
            next_state = STATE_INS_B1;

        STATE_INS_B1:
            next_state = STATE_INS_B2;

        STATE_INS_B2:
            next_state = STATE_INS_B3;

        STATE_INS_B3:   
            next_state = STATE_CS;

        STATE_ADF0_X:
            next_state = STATE_ADF1_X;

        STATE_ADF1_X:
            next_state = STATE_ADF2_X;

        STATE_ADF2_X:
            if (vpid_pkt)
                next_state = STATE_DID_X;
            else
                next_state = STATE_WAIT;

        STATE_DID_X:
            next_state = STATE_SDID_X;

        STATE_SDID_X:
            next_state = STATE_DC_X;

        STATE_DC_X:
            if (udw_cntr_tc)
                next_state = STATE_CS_X;
            else
                next_state = STATE_UDW_X;

        STATE_UDW_X:
            if (udw_cntr_tc)
                next_state = STATE_CS_X;
            else
                next_state = STATE_UDW_X;

        STATE_CS_X:
            if (anc_next)
                next_state = STATE_ADF0_X;
            else
                next_state = STATE_WAIT;

        default:    next_state = STATE_WAIT;
    endcase
        
//
// FSM: outputs
//
// This block decodes the current state to generate the various outputs of the
// FSM.
//
always @ (*)
    begin
        // Unless specifically assigned in the case statement, all FSM outputs
        // are given the values assigned here.
        ld_udw_cntr     = 1'b0;
        clr_cs_reg      = 1'b0;
        vpid_mux_sel    = 2'b00;
        out_mux_sel     = MUX_SEL_VID;
                                
        case(current_state) 

            STATE_ADF2:     clr_cs_reg = 1'b1;

            STATE_B0:       begin
                                out_mux_sel = level_b ? MUX_SEL_UDW : MUX_SEL_VID;
                                vpid_mux_sel = 2'b00;
                            end
        
            STATE_CS:       out_mux_sel = MUX_SEL_CS;

            STATE_DC2:      ld_udw_cntr = 1'b1;

            STATE_INS_ADF0: out_mux_sel = MUX_SEL_000;

            STATE_INS_ADF1: out_mux_sel = MUX_SEL_3FF;

            STATE_INS_ADF2: begin
                                out_mux_sel = MUX_SEL_3FF;
                                clr_cs_reg = 1'b1;
                            end

            STATE_INS_DID:  out_mux_sel = MUX_SEL_DID;

            STATE_INS_SDID: out_mux_sel = MUX_SEL_SDID;

            STATE_INS_DC:   out_mux_sel = MUX_SEL_DC;

            STATE_INS_B0:   begin
                                out_mux_sel = MUX_SEL_UDW;
                                vpid_mux_sel = 2'b00;
                            end
        
            STATE_INS_B1:   begin
                                out_mux_sel = MUX_SEL_UDW;
                                vpid_mux_sel = 2'b01;
                            end
        
            STATE_INS_B2:   begin
                                out_mux_sel = MUX_SEL_UDW;
                                vpid_mux_sel = 2'b10;
                            end
        
            STATE_INS_B3:   begin
                                out_mux_sel = MUX_SEL_UDW;
                                vpid_mux_sel = 2'b11;
                            end

            STATE_ADF2_X:   clr_cs_reg = 1'b1;

            STATE_DID_X:    out_mux_sel = MUX_SEL_DEL;

            STATE_DC_X:     ld_udw_cntr = 1'b1;

            STATE_CS_X:     out_mux_sel = MUX_SEL_CS;

        endcase
    end

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
Module Description:

This is the SMPTE 425M 3G-SDI receiver demux for level B only. This
module takes two 10-bit streams at 148.5 MHz and converts them into two
streams each with two 10-bit components (Y and C) at 74.25 MHz. Typically,
the two 10-bit input streams to this module come directly from the C (ds1) 
and Y (ds2) outputs of a hdsdi_framer module.

The module also generates correct timing signals for the video including
TRS, XYZ, EAV, and SAV signals and line number information captured from the
data stream.

The module also creates an output clock enable signal, dout_rdy, that is
asserted when valid data is present on the outputs. If the input clock rate
is 148.5 MHz (with ce asserted high always), the dout_rdy will be asserted
every other clock cycle with a 50% duty cycle. If the input clock rate is
297 MHz (with ce asserted every other clock cycle), then dout_rdy will be
asserted one cycle out of every four with a 25% duty cycle.

Note: If ce input is used (not wired to 1), then dout_rdy will be asserted for
multiple clock cycles and will only change when the ce input is 1. Thus,
downstream devices should not treat dout_rdy as a clock enable, but as a
data ready signal that must be qualified with the clock enable.

This version of the file is identical to SMPTE425_B_demux except that the
dout_rdy output has been replaced with a dout_rdy_gen signal and a drdy_in
input has been added. This allows the dout_rdy signal to be generated externally
to this module, under control of the dout_rdy_gen, and fed back in on drdy_in.
This allows for better timing when generating the dout_rdy signal.

--------------------------------------------------------------------------------
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_SMPTE425_B_demux2 (
    input   wire        clk,            // word-rate clock
    input   wire        ce,             // input clock enable (always 1 if clk = 148.5 MHz)
    input   wire        drdy_in,
    input   wire        rst,            // sync reset input
    input   wire [9:0]  ds1,            // connect to Y output of hdsdi_framer
    input   wire [9:0]  ds2,            // connect to C output of hdsdi_framer
    input   wire        trs_in,         // input TRS signal from hdsdi_framer
    output  reg         level_b,        // 1 if data is SMPTE 424M Level B
    output  reg  [9:0]  c0 = 0,         // channel 0 data stream C output
    output  wire [9:0]  y0,             // channel 0 data stream Y output
    output  reg  [9:0]  c1 = 0,         // channel 1 data stream C output
    output  wire [9:0]  y1,             // channel 1 data stream Y output
    output  wire        trs,            // asserted during all 4 words of EAV & SAV
    output  wire        eav,            // asserted during XYZ word of EAV
    output  wire        sav,            // asserted during XYZ word of SAV
    output  wire        xyz,            // asserted during XYZ word
    output  wire        dout_rdy_gen,
    output  reg [10:0]  line_num = 0    // line number
);

//
// Internal signals
//
reg     [9:0]       c0_int = 0;         // internal capture reg for c0
reg     [9:0]       y0_int = 0;         // internal capture reg for y0
reg     [9:0]       c1_int = 0;         // internal capture reg for c1
reg     [9:0]       y1_int = 0;         // internal capture reg for y1
reg     [4:0]       trs_dly = 0;        // TRS timing delay shift register
reg     [6:0]       ln_ls = 0;          // LS bits of line number capture
reg                 trs_rise = 0;       // TRS rising edge detect
wire                all_ones;           // Y channel is all ones
wire                all_zeros;          // Y channel is all zeros
reg     [2:0]       zeros = 0;          // all zeros delay shift register
reg     [4:0]       ones = 0;           // all ones delay shift register
reg                 level_b_detect = 0; // level_b detect signal
reg                 trs_rise_dly = 0;

//
// Clock enable logic
//
// First detect the rising edge of the trs input signal. The dout_rdy_gen signal
// is set to one the cycle after the rising edge of trs. 
//
always @ (posedge clk)
    if (ce) begin
        if (trs_in & ~trs_dly[0])
            trs_rise <= 1'b1;
        else
            trs_rise <= 1'b0;
    end

always @ (posedge clk)
    if (ce)
        trs_rise_dly <= trs_rise;

assign dout_rdy_gen = trs_rise & ~trs_rise_dly;

//
// Capture registers
//
// The capture registers convert the two 10-bit data streams into two 20-bit
// data streams. The C components are captured first and stored in temporary
// registers. The temporary C component registers and the incoming Y components
// are then captured in the final capture registers and output from the module
// as y0, c0, y1, and c1.
//
always @ (posedge clk)
    if (ce) 
        if (~drdy_in) 
        begin
            c0_int <= ds1;
            c1_int <= ds2;
        end

always @ (posedge clk)
    if (ce)
        if (drdy_in) begin
            y0_int <= ds1;
            c0     <= c0_int;
            y1_int <= ds2;
            c1     <= c1_int;
        end

assign y0 = y0_int;
assign y1 = y1_int;

//
// TRS timing
//
// This logic generates the trs, xyz, eav, and sav timing signals, all derived
// from the trs_in signal.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            trs_dly <= 0;
        else if (drdy_in)
            trs_dly <= {trs_dly[3:0], trs_in};
    end

assign trs = |trs_dly[2:0] | (&trs_dly[3:2]);
assign xyz = trs_dly[3] & ~trs_dly[4];
assign eav = xyz & y0_int[6];
assign sav = xyz & ~y0_int[6];

//
// Line number capture
//
// This logic captures the line number information that is embedded in the y0
// data stream.
//
reg [1:0] eav_dly = 0;

always @ (posedge clk)
    if (ce)
        if (drdy_in)
            eav_dly <= {eav_dly[0], eav};

always @ (posedge clk)
    if (ce)
        if (drdy_in & eav_dly[0])
            ln_ls <= y0_int[8:2];

always @ (posedge clk)
    if (ce)
        if (drdy_in & eav_dly[1])
            line_num <= {y0_int[5:2], ln_ls};

//
// Level B detector
//
// This logic determines whether the input data streams are carrying level A
// or level B encoded data. This determination is not dependent upon SMPTE
// 352M video payload ID packets. The determination is made by examining the
// pattern of words with all 1's and all 0's at each TRS. The pattern is 
// different between level A and level B.
//
assign all_ones = &ds1;
assign all_zeros = ~|ds1;

always @ (posedge clk)
    if (ce)
        ones <= {ones[3:0], all_ones};

always @ (posedge clk)
    if (ce)
        zeros <= {zeros[1:0], all_zeros};

always @ (posedge clk)
    if (ce)
        if (drdy_in)
            level_b_detect <= (&ones[4:3]) & (&zeros[2:0]) & all_zeros;

always @ (posedge clk)
    if (ce)
        if (drdy_in & trs_dly[2] & trs_dly[1])
            level_b <= level_b_detect;


endmodule



// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
Module Description:

This module performs the SMPTE scrambling and NRZ-to-NRZI conversion algorithms
on 10-bit video words. It is designed to support both SDI (SMPTE 259M) and
HD-SDI (SMPTE 292M) standards.

When encoding HD-SDI video, two of these modules can be used to encode the
two video channels Y and C. Each module would run at the word rate (74.25 MHz)
and accept one video in and generate one encoded data word out per clock cycle.
It is also possible to use just one of these modules to encode both data
channels by running the module a 2X the video rate.

When encoding SD-SDI video, one module is used and data is encoded one word
per clock cycle.

The module has two clock cycles of latency. It accepts one 10-bit word every
clock cycle and also produces 10-bits of encoded data every clock cycle.

One clock cycle is used to scramble the data using the SMPTE X^9 + X^4 + 1
polynomial. During the second clock cycles, the scrambled data is converted to
NRZI data using the X + 1 polynomial.

Both the scrambling and NRZ-to-NRZI conversion have separate enable inputs. The
scram input enables scrambling when High. The nrzi input enables NRZ-to-NRZI
conversion when high.

The p_scram input vector provides 9 bits of data that was scrambled by the
during the previous clock cycle or by the other channel's smpte_encoder module. 
When implementing a HD-SDI encoder, the p_scram input of the C scrambler module 
must be connected to the i_scram_q output of the Y module and the p_scram input 
of the Y scrambler module must be connected to the i_scram output of the C 
module. For SD-SDI or for HD-SDI when running this module at 2X the HD-SDI word
rate, the p_scram input must be connected to the i_scram_q output of this same 
module.

The p_nrzi input provides one bit of data that was converted to NRZI by the
companion hdsdi_scram_lower module. When implementing a HD-SDI encoder, the 
p_nrzi input of the C scrambler module must be connected to the q[9] bit from 
the Y module and the p_nrzi input of the Y scrambler module must be connected to
the i_nrzi output of the C module. For SD-SDI or for HD-SDI when running this
module at 2X the HD-SDI word rate, the p_nrzi input must be connected to the 
q[9] output bit of this same module.

--------------------------------------------------------------------------------
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_smpte_encoder (
    input  wire         clk,        // input clock (bit-rate)
    input  wire         ce,         // clock enable
    input  wire         nrzi,       // enables NRZ-to-NRZI conversion when high
    input  wire         scram,      // enables SDI scrambler when high
    input  wire [9:0]   d,          // input data
    input  wire [8:0]   p_scram,    // previously scrambled data input 
    input  wire         p_nrzi,     // MSB of previously converted NRZI word
    output wire [9:0]   q,          // output data
    output wire [8:0]   i_scram,    // intermediate scrambled data output
    output wire [8:0]   i_scram_q,  // registered intermediate scrambled data output
    output wire         i_nrzi      // intermediate nrzi data output
);

//
// Signal definitions
//
reg     [9:0]       scram_reg = 0;  // pipeline delay register
reg     [9:0]       out_reg = 0;    // output register
wire    [13:0]      scram_in;       // input to the scrambler
reg     [9:0]       scram_temp;     // intermediate output of the scrambler
wire    [9:0]       scram_out;      // output of the scrambler
wire    [9:0]       nrzi_out;       // output of NRZ-to-NRZI converter
reg     [9:0]       nrzi_temp;      // intermediate output of the NRZ-to-NRZI converter
integer             i, j;           // for loop variables

//
// Scrambler
//
// This block of logic implements the SDI scrambler algorithm. The scrambler
// uses the 10 incoming bits from the input port and a 14-bit vector called 
// scram_in. scram_in is made up of 9 bits that were scrambled in the previous 
// clock cycle (p_scram) and the 5 LS scrambled bits that have been generated 
// during the current clock cycle. The results of the scrambler are assigned to 
// scram_temp.
//
// A MUX will output either the value of scram_temp or the d input word
// depending on the scram enable input. The output of the MUX is stored in the
// scram_reg.
//
assign scram_in = {scram_temp[4:0], p_scram[8:0]};

always @ (*)
    for (i = 0; i < 10; i = i + 1)
        scram_temp[i] = d[i] ^ scram_in[i] ^ scram_in[i + 4];

assign scram_out = scram ? scram_temp : d;

always @ (posedge clk)
    if (ce)
        scram_reg <= scram_out;

//
// NRZ-to-NRZI converter
//
// This block of logic implements the NRZ-to-NRZI conversion. It operates on the
// 10 bits coming from the scram_reg and the MSB from the output of the NRZ-to
// NRZI conversion done on the previous word (p_nrzi).. A MUX bypasses the 
// conversion process if the nrzi input is low.
//
always @ (*)
    begin
        nrzi_temp[0] = p_nrzi ^ scram_reg[0];
        for (j = 1; j < 10; j = j + 1)
            nrzi_temp[j] = nrzi_out[j - 1] ^ scram_reg[j];
    end

assign nrzi_out = nrzi ? nrzi_temp : scram_reg;

//
// out_reg: Output register
//
always @ (posedge clk)
    if (ce)
        out_reg <= nrzi_out;

//
// output assignments
//
assign q = out_reg;
assign i_scram = scram_temp[9:1];
assign i_scram_q = scram_reg[9:1];
assign i_nrzi = nrzi_temp[9];

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_triple_sdi_reset #(
    parameter RST_DLY  = 8,
    parameter NUM_OUTS = 2)
 (
    input  wire                 clk,            // clock input
    input  wire                 rst_in,         // reset input
    output reg [NUM_OUTS-1:0]   rst_out = ~0    // reset outputs
);

reg [RST_DLY-1:0]   sreg = {RST_DLY{1'b1}};
            
always @ (posedge clk)
    if (rst_in)
        sreg <= {RST_DLY{1'b1}};
    else
        sreg <= {sreg[RST_DLY-2:0], 1'b0};

always @ (posedge clk)
    if (rst_in)
        rst_out <= {NUM_OUTS{1'b1}};
    else
        rst_out <= {NUM_OUTS{sreg[RST_DLY-1]}};

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
Module Description:

This is the top level of the triple-rate SDI RX.
*/

`timescale 1ns / 1ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_triple_sdi_rx #(
    parameter NUM_SD_CE         = 2,        // number of SD-SDI clock enable outputs
    parameter NUM_3G_DRDY       = 2,        // number of dout_rdy_3G outputs
    parameter ERRCNT_WIDTH      = 4,        // width of counter tracking lines with errors
    parameter MAX_ERRS_LOCKED   = 15,       // max number of consecutive lines with errors
    parameter MAX_ERRS_UNLOCKED = 2)        // max number of lines with errors during search
(
    // inputs
    input  wire                     clk,                // rxusrclk input
    input  wire                     rst,                // sync reset input
    input  wire [19:0]              data_in,            // raw data from GTX RXDATA port
    input  wire                     sd_data_strobe,     // asserted high when SD data is available on data_in
    input  wire                     frame_en,           // 1 = enable framer position update
    input  wire                     bit_rate,           // 1 = 1000/1001 bit rate, 0 = 1000/1000 bit rate
    input  wire [2:0]               mode_enable,        // unary enable bits for SDI mode search {3G, SD, HD} 1=enable, 0=disable
    input  wire                     mode_detect_en,     // 1 enables SDI mode detection
    input  wire [1:0]               forced_mode,        // if mode_detect_en=0, this port specifies the SDI mode of the RX

    // outputs
    output wire [1:0]               mode,               // 00=HD, 01=SD, 10=3G
    output reg                      mode_HD = 1'b0,     // 1 = HD mode      
    output reg                      mode_SD = 1'b0,     // 1 = SD mode
    output reg                      mode_3G = 1'b0,     // 1 = 3G mode
    output wire                     mode_locked,        // auto mode detection locked
    output wire                     t_locked,           // transport format detection locked
    output wire [3:0]               t_family,           // transport format family
    output wire [3:0]               t_rate,             // transport frame rate
    output wire                     t_scan,             // transport scan: 0=interlaced, 1=progressive
    output reg                      level_b_3G = 1'b0,  // 0 = level A, 1 = level B
    output wire [NUM_SD_CE-1:0]     ce_sd,              // clock enable for SD, always 1 for HD & 3G
    output wire                     nsp,                // framer new start position
    output wire [10:0]              ln_a,               // line number for HD & 3G (link A for level B)
    output wire [31:0]              a_vpid,             // video payload ID packet ds1 for 3G or HD-SDI
    output wire                     a_vpid_valid,       // 1 = a_vpid is valid
    output wire [31:0]              b_vpid,             // video payload ID packet data from data stream 2
    output wire                     b_vpid_valid,       // 1 = b_vpid is valid
    output reg                      crc_err_a = 1'b0,   // CRC error for HD & 3G
    output wire [9:0]               ds1a,               // SD=Y/C, HD=Y, 3GA=ds1, 3GB=Y link A
    output wire [9:0]               ds2a,               // HD=C, 3GA=ds2, 3GB=C link A
    output wire                     eav,                // EAV
    output wire                     sav,                // SAV
    output wire                     trs,                // TRS

    // outputs valid for 3G level B mode only
    output wire [10:0]              ln_b,               // line number of 3G level B link B
    output wire [NUM_3G_DRDY-1:0]   dout_rdy_3G,        // 1 for level A, asserted every other clk for level B
    output reg                      crc_err_b = 1'b0,   // CRC error for ds2 (level B only)
    output wire [9:0]               ds1b,               // 3G level B only = Y link B
    output wire [9:0]               ds2b               // 3G level B only = C link B
);

//
// Internal signal declarations
//

// Clock enables
localparam NUM_INT_CE = 1;                      // Number of internal clock enables used
localparam NUM_INT_LVLB_CE = 1;

(* equivalent_register_removal = "no" *)
(* KEEP = "TRUE" *)
reg [NUM_INT_CE-1:0]        ce_int = 0;         // internal SD clock enable FFs

(* equivalent_register_removal = "no" *)
(* KEEP = "TRUE" *)
reg [NUM_INT_LVLB_CE-1:0]   ce_lvlb_int = 0;    // internal ce's correct for all modes

(* equivalent_register_removal = "no" *)
(* KEEP = "TRUE" *)
reg [NUM_SD_CE-1:0]         ce_sd_ff = 0;       // external SD clock enable FFs

(* equivalent_register_removal = "no" *)
(* KEEP = "TRUE" *)
reg [NUM_3G_DRDY-1:0]       dout_rdy_3G_ff = 0; // dout_rdy signals

reg             lvlb_drdy = 1'b0;
reg  [19:0]     rxdata = 0;
reg  [9:0]      sd_rxdata = 0;
wire [1:0]      mode_int;
wire [1:0]      mode_x;
wire            mode_locked_int;
wire            mode_locked_x;
reg             mode_HD_int;
reg             mode_SD_int;
reg             mode_3G_int;
wire [19:0]     descrambler_in;
wire [19:0]     descrambler_out;
wire [9:0]      framer_ds1;
wire [9:0]      framer_ds2;
wire            framer_eav;
wire            framer_sav;
wire            framer_trs;
wire            framer_trs_err;
wire            level_b;
wire [31:0]     a_vpid_int;
wire [31:0]     b_vpid_int;
wire [9:0]      vpid_b_in;
wire            a_vpid_valid_int;
wire            b_vpid_valid_int;
wire [9:0]      lvlb_a_y;
wire [9:0]      lvlb_a_c;
wire [9:0]      lvlb_b_y;
wire [9:0]      lvlb_b_c;
wire            lvlb_trs;
wire            lvlb_eav;
wire            lvlb_sav;
wire            lvlb_dout_rdy_gen;
wire            lvlb_sav_err;
reg             autodetect_sav = 1'b0;
reg             autodetect_trs_err = 1'b0;
reg             eav_int = 1'b0;
reg             sav_int = 1'b0;
reg             trs_int = 1'b0;
reg  [9:0]      ds1a_int = 0;
reg  [9:0]      ds2a_int = 0;
reg  [9:0]      ds1b_int = 0;
reg  [9:0]      ds2b_int = 0;
wire            ds1a_crc_err;
wire            ds2a_crc_err;
wire            ds1b_crc_err;
wire            ds2b_crc_err;
wire [10:0]     ln_a_int;


//------------------------------------------------------------------------------
// Clock enable generation
//

//
// The internal clock enables and the external SD clock enables are copies of
// the DRU's drdy output in SD mode and are always High in HD and 3G modes.
//
always @ (posedge clk)
    if (mode_int == 2'b01)
        ce_int <= {NUM_INT_CE {sd_data_strobe}};
    else
        ce_int <= {NUM_INT_CE {1'b1}};

always @ (posedge clk)
    if (mode_int == 2'b01)
        ce_sd_ff <= {NUM_SD_CE {sd_data_strobe}};
    else
        ce_sd_ff <= {NUM_SD_CE {1'b1}};
        
assign ce_sd = ce_sd_ff;

//
// The lvlb_drdy clock enable is High all of the time except when running in
// 3G-SDI level B mode. In that mode, it is generate by control signals in the
// SMPTE425_B_demux module. The lvlb_drdy signal is fed back into the 
// SMPTE425_B_demux module to control its timing. The signal is also used to
// produce the external dout_rdy_3G signals. The lvlb_drdy and the dout_rdy_3G
// signals are asserted at a 74.25 MHz rate in 3G-SDI level B mode to control
// the 40-bit data path.
//
always @ (posedge clk)
    if (lvlb_dout_rdy_gen | ~(mode_3G_int & level_b))
        lvlb_drdy <= 1'b1;
    else
        lvlb_drdy <= ~lvlb_drdy;

always @ (posedge clk)
    if (lvlb_dout_rdy_gen | ~(mode_3G_int & level_b))
        dout_rdy_3G_ff <= {NUM_3G_DRDY {1'b1}};
    else
        dout_rdy_3G_ff <= {NUM_3G_DRDY {~lvlb_drdy}};

assign dout_rdy_3G = dout_rdy_3G_ff;

// 
// The ce_lvlb_int signal is a clock enable that is correct for all three
// operating modes. It is equivalent to the data ready signal from the DRU in
// SD-SDI mode. It is High for HD-SDI and 3G-SDI level A modes. It is asserted
// every other clock cycle in 3G-SDI level B mode.
//
always @ (posedge clk)
    if (mode_int == 2'b01)
        ce_lvlb_int <= {NUM_INT_LVLB_CE {sd_data_strobe}};
    else if (mode_int == 2'b00)
        ce_lvlb_int <= {NUM_INT_LVLB_CE {1'b1}};
    else
        ce_lvlb_int <= {NUM_INT_LVLB_CE {lvlb_drdy}};

//------------------------------------------------------------------------------
// Data input registers
//
always @ (posedge clk)
    rxdata <= data_in;

always @ (posedge clk)
    if (sd_data_strobe)
        sd_rxdata <= data_in[9:0];

//------------------------------------------------------------------------------
// SDI descrambler and framer
//
// The output of the framer is valid for HD or SD data.
//
assign descrambler_in = mode_SD_int ? {sd_rxdata, 10'b0} : rxdata;

v_smpte_sdi_v3_0_8_multi_sdi_decoder DEC (
    .clk            (clk),
    .rst            (1'b0),
    .ce             (ce_int[0]),
    .hd_sd          (mode_SD_int),
    .d              (descrambler_in),
    .q              (descrambler_out));

v_smpte_sdi_v3_0_8_multi_sdi_framer FRM (
    .clk            (clk),
    .rst            (1'b0),
    .ce             (ce_int[0]),
    .d              (descrambler_out),
    .frame_en       (frame_en),
    .hd_sd          (mode_SD_int),
    .c              (framer_ds2),
    .y              (framer_ds1),
    .trs            (framer_trs),
    .xyz            (),
    .eav            (framer_eav),
    .sav            (framer_sav),
    .trs_err        (framer_trs_err),
    .nsp            (framer_nsp));

assign nsp = framer_nsp;

//------------------------------------------------------------------------------
// SDI mode detection
//
always @ (posedge clk)
    if (ce_int[0])
        if (mode_3G_int & level_b)
        begin
            autodetect_sav <= lvlb_sav;
            autodetect_trs_err <= lvlb_sav_err;
        end else begin
            autodetect_sav <= framer_sav;
            autodetect_trs_err <= framer_trs_err;
        end
       
v_smpte_sdi_v3_0_8_triple_sdi_rx_autorate #(
    .ERRCNT_WIDTH       (ERRCNT_WIDTH),
    .MAX_ERRS_LOCKED    (MAX_ERRS_LOCKED),
    .MAX_ERRS_UNLOCKED  (MAX_ERRS_UNLOCKED))
AUTORATE (
    .clk                (clk),
    .ce                 (ce_int[0]),
    .rst                (rst),
    .sav                (autodetect_sav),
    .trs_err            (autodetect_trs_err),
    .mode_enable        (mode_enable),
    .mode               (mode_x),
    .locked             (mode_locked_x));

always @ (*)
begin
    mode_HD_int = 1'b0;
    mode_SD_int = 1'b0;
    mode_3G_int = 1'b0;

    case(mode_int)
        2'b01:   mode_SD_int = 1'b1;
        2'b10:   mode_3G_int = 1'b1;
        default: mode_HD_int = 1'b1;
    endcase
end

//
// If the mode_detect_en input is 1, then use the mode detected by the triple_sdi_rx_autorate
// module and the associated mode_locked signal. Otherwise, use the forced_mode
// input and always assert mode_locked.
//
assign mode_int = mode_detect_en ? mode_x : forced_mode;
assign mode_locked_int = mode_detect_en ? mode_locked_x : 1'b1;

assign mode = mode_int;
assign mode_locked = mode_locked_int;

//------------------------------------------------------------------------------
// 3G-SDI level B demux
//
v_smpte_sdi_v3_0_8_SMPTE425_B_demux2 BDMUX (
    .clk            (clk),
    .ce             (ce_int[0]),
    .drdy_in        (lvlb_drdy),
    .rst            (rst),
    .ds1            (framer_ds1),
    .ds2            (framer_ds2),
    .trs_in         (framer_trs),
    .level_b        (level_b),
    .c0             (lvlb_a_c),
    .y0             (lvlb_a_y),
    .c1             (lvlb_b_c),
    .y1             (lvlb_b_y),
    .trs            (lvlb_trs),
    .eav            (lvlb_eav),
    .sav            (lvlb_sav),
    .xyz            (lvlb_xyz),
    .dout_rdy_gen   (lvlb_dout_rdy_gen),
    .line_num       ());

assign lvlb_sav_err = lvlb_sav & (
                       (lvlb_a_y[5] ^ lvlb_a_y[6] ^ lvlb_a_y[7]) |
                       (lvlb_a_y[4] ^ lvlb_a_y[8] ^ lvlb_a_y[6]) |
                       (lvlb_a_y[3] ^ lvlb_a_y[8] ^ lvlb_a_y[7]) |
                       (lvlb_a_y[2] ^ lvlb_a_y[8] ^ lvlb_a_y[7] ^ lvlb_a_y[6]) |
                       ~lvlb_a_y[9] | lvlb_a_y[1] | lvlb_a_y[0]);

//
// These pipelined muxes select between the framer output and the output of the
// level B data path. They also implement a pipeline delay to improve timing
// to the downstream logic.
//
always @ (posedge clk)
    if (ce_int[0])
    begin
        eav_int  <= (mode_3G_int & level_b) ? lvlb_eav : framer_eav;
        sav_int  <= (mode_3G_int & level_b) ? lvlb_sav : framer_sav;
        trs_int  <= (mode_3G_int & level_b) ? lvlb_trs : framer_trs;
        ds1a_int <= (mode_3G_int & level_b) ? lvlb_a_y : framer_ds1;
        ds2a_int <= (mode_3G_int & level_b) ? lvlb_a_c : framer_ds2;
        ds1b_int <= lvlb_b_y;
        ds2b_int <= lvlb_b_c;
    end

assign ds1a = ds1a_int;
assign ds2a = ds2a_int;
assign ds1b = ds1b_int;
assign ds2b = ds2b_int;
assign eav  = eav_int;
assign sav  = sav_int;
assign trs  = trs_int;

//------------------------------------------------------------------------------
// Transport timing detection module
//
v_smpte_sdi_v3_0_8_triple_sdi_transport_detect TD (
    .clk                (clk),
    .rst                (rst),
    .ce                 (lvlb_drdy & ce_int[0]),
    .vid_7              (ds1a_int[7]),
    .eav                (eav_int),
    .sav                (sav_int),
    .bit_rate           (bit_rate),
    .mode               (mode_int),
    .mode_locked        (mode_locked_int),
    .level_b            (level_b),
    .ln                 (ln_a_int),
    .transport_family   (t_family),
    .transport_rate     (t_rate),
    .transport_scan     (t_scan),
    .transport_locked   (t_locked));

//------------------------------------------------------------------------------
// CRC checking
//
v_smpte_sdi_v3_0_8_hdsdi_rx_crc RXCRC1 (
    .clk        (clk),
    .rst        (1'b0),
    .ce         (ce_lvlb_int[0]), 
    .c_video    (ds2a_int),
    .y_video    (ds1a_int),
    .trs        (trs_int),
    .c_crc_err  (ds2a_crc_err),
    .y_crc_err  (ds1a_crc_err),
    .c_line_num (),
    .y_line_num (ln_a_int));

assign ln_a = ln_a_int;

v_smpte_sdi_v3_0_8_hdsdi_rx_crc RXCRC2 (
    .clk        (clk),
    .rst        (1'b0),
    .ce         (ce_lvlb_int[0]), 
    .c_video    (ds2b_int),
    .y_video    (ds1b_int),
    .trs        (trs_int),
    .c_crc_err  (ds2b_crc_err),
    .y_crc_err  (ds1b_crc_err),
    .c_line_num (),
    .y_line_num (ln_b));

//------------------------------------------------------------------------------
// SMPTE 352 payload ID capture
//
v_smpte_sdi_v3_0_8_SMPTE352_vpid_capture PLOD1 (
    .clk            (clk),
    .ce             (ce_lvlb_int[0]),
    .rst            (rst),
    .sav            (sav_int),
    .vid_in         (ds1a_int),
    .payload        (a_vpid),
    .valid          (a_vpid_valid));

assign vpid_b_in = (mode_3G_int & level_b) ? ds1b_int : ds2a_int;

v_smpte_sdi_v3_0_8_SMPTE352_vpid_capture PLOD2 (
    .clk            (clk),
    .ce             (ce_lvlb_int[0]),
    .rst            (rst),
    .sav            (sav_int),
    .vid_in         (vpid_b_in),
    .payload        (b_vpid),
    .valid          (b_vpid_valid));

always @ (posedge clk)
    if (ce_int[0])
    begin
        if (rst)
        begin
            mode_HD <= 1'b0;
            mode_SD <= 1'b0;
            mode_3G <= 1'b0;
            level_b_3G <= 1'b0;
            crc_err_a <= 1'b0;
            crc_err_b <= 1'b0;
        end
        else
        begin
            mode_HD <= mode_HD_int & mode_locked_int;
            mode_SD <= mode_SD_int & mode_locked_int;
            mode_3G <= mode_3G_int & mode_locked_int;
            level_b_3G <= mode_3G_int & level_b;
            crc_err_a <= ds2a_crc_err | ds1a_crc_err;
            crc_err_b <= ds2b_crc_err | ds1b_crc_err;
        end
    end

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
Module Description:

This module, controls a MGT RX operating mode so as to automatically detect 
SD-SDI, HD-SDI, or 3G-SDI on the incoming bit stream.

The user needs to balance error tolerance against reaction speed in this design.
Occasional errors, or even a burst of errors, should not cause the circuit to
toggle reference clock frequencies prematurely. On the other hand, in some
cases it is necessary to reacquire lock with the bitstream as quickly as
possible after the incoming bitstream changes frequencies.

This module uses missing or erroneous TRS symbols as the detection mechanism for 
determining when to toggle the operating mode. A missing SAV or an SAV 
with protection bit errors will cause the finite state machine to flag the line 
as containing an error. 

Each line that contains an error causes the error counter to increment. If a 
line is found that is error free, the error counter is cleared back to zero. 
When MAX_ERRS_LOCKED consecutive lines occur with errors, the state machine will 
change the mode output to cycle through SD-SDI, HD-SDI, and 3G-SDI until lock
is reacquired. MAX_ERRS_LOCKED is provided to the module as a parameter. The
width of the error counter, as specified by ERRCNT_WIDTH, must be sufficient to
count up to MAX_ERRS_LOCKED (and MAX_ERRS_UNLOCKED).

When the receiver is not locked, the MAX_ERRS_UNLOCKED parameter controls
the maximum number of consecutive lines with TRS errors that must occur before
the state machine moves on to the next operating mode. MAX_ERRS_UNLOCKED
effectively controls the scan rate of the locking process whereas 
MAX_ERRS_LOCKED controls how quickly the module responds to loss of lock (and
how sensitive it is to noise on the input signal).

The TRSCNT_WIDTH parameter determines the width of the counter used to determine
if an SAV was not received during a line. It should be wide enough to count
more than the number of samples in the longest possible video line. Some video
formats are now longer than 4096 samples per line, so the default is set to 13,
allowing lines up to 8192 samples long.

The rst input resets the module asynchronously. However, this signal must be
negated synchronously with the clk signal, otherwise the state machine may
go to an invalid state.

This controller also has an input called mode_enable that allows the supported
modes to be specified. Only those modes whose corresponding bit on the 
mode_enable input will be tried during the search to lock to the input 
bitstream.
--------------------------------------------------------------------------------
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_triple_sdi_rx_autorate #(
    parameter ERRCNT_WIDTH      = 4,    // width of counter tracking lines with errors
    parameter TRSCNT_WIDTH      = 14,   // width of missing SAV timeout counter
    parameter MAX_ERRS_LOCKED   = 15,   // max number of consecutive lines with errors
    parameter MAX_ERRS_UNLOCKED = 2)    // max number of lines with errors during search
(
    input  wire         clk,            // rxusrclk input
    input  wire         ce,             // clock enable
    input  wire         rst,            // sync reset input
    input  wire         sav,            // asserted during SAV symbols
    input  wire         trs_err,        // TRS error bit from framer
    input  wire [2:0]   mode_enable,    // b0=HD, b1=SD, b2=3G
    output wire [1:0]   mode,           // 00 = HD, 01 = SD, 10 = 3G
    output wire         locked          // 1 = locked
);

//-----------------------------------------------------------------------------
// Parameter definitions
//
// Changing the ERRCNT_WIDTH parameter changes the width of the counter that is
// used to keep track of the number of consecutive lines that contained errors.
// By changing the counter width and changing the two MAX_ERRS parameters, the
// latency for refclksel switching can be changed. Making the MAX_ERRS values
// smaller will reduce the switching latency, but will also reduce the tolerance
// to errors and cause unintentional rate switching.
//
// There are two different MAX_ERRS parameters, one that is effective when the
// FSM is locked and and when it is unlocked. By making the MAX_ERRS_UNLOCKED
// value smaller, the scan process is more rapid. By making the MAX_ERRS_LOCKED
// parameter larger, the process is less sensitive to noise induced errors.
//
// The TRSCNT_WIDTH parameter determines the width of the missing SAV timeout
// counter. Increasing this counter's width causes the state machine to wait
// longer before determining that a SAV was missing. Note that the counter
// is actually implemented as one bit wider than the value given in TRSCNT_MSB
// allowing the MSB to be the timeout error flag.
//
localparam ERRCNT_MSB = ERRCNT_WIDTH - 1;    
localparam TRSCNT_MSB = TRSCNT_WIDTH;    

//
// This group of parameters defines the states of the FSM.
//                                              
localparam STATE_MSB = 2;

localparam [STATE_MSB:0]
    UNLOCK  = 0,
    LOCK1   = 1,
    LOCK2   = 2,
    ERR1    = 3,
    ERR2    = 4,
    CHANGE  = 5;
    
// 
// These parameters define the values used on the mode output
//      
localparam [1:0]
    MODE_HD = 2'b00,
    MODE_SD = 2'b01,
    MODE_3G = 2'b10,
    MODE_XX = 2'b11;

// 
// These parameters define the mode_enable input port bits.
//     
localparam
    VALID_BIT_HD = 0,
    VALID_BIT_SD = 1,
    VALID_BIT_3G = 2;

//-----------------------------------------------------------------------------
// Signal definitions
//

// internal signals
reg     [STATE_MSB:0]   current_state = UNLOCK; // FSM current state
reg     [STATE_MSB:0]   next_state;             // FSM next state
reg     [ERRCNT_MSB:0]  errcnt = 0;             // error counter
reg     [TRSCNT_MSB:0]  trscnt = 0;             // TRS timeout counter
reg                     clr_errcnt;             // FSM output that clears errcnt
reg                     inc_errcnt;             // FSM output that increments errcnt
wire                    max_errcnt;             // asserted when errcnt = MAX_ERRS
wire                    trs_tc;                 // terminal count output from trscnt
wire                    sav_ok;                 // asserted during SAV if no protection errors
reg     [1:0]           mode_int = 2'b00;       // internal version of mode output
reg                     change_mode;            // FSM output that changes mode
reg                     set_locked;             // FSM output that sets locked_int
reg                     clr_locked;             // FSM output that clears locked_int
reg                     locked_int = 1'b0;      // internal version of locked signal
wire    [ERRCNT_MSB:0]  max_errs;               // max errcnt mux
reg     [1:0]           next_mode;

//
// Error signals
//
// sav_ok is only asserted during the XYZ word of SAV symbols when there trs_err
// is not asserted.
//
assign sav_ok = sav & ~trs_err;

// 
// mode register
//
// The mode register changes when the change_mode signal from the FSM is 
// asserted.. The normal scan sequence is HD -> 3G -> SD -> HD if all 3 modes
// are enabled by the mode_enable port. Any modes that are not enabled are
// skipped.
//
always @ (*)
    case(mode_int)
        MODE_HD:    if (mode_enable[VALID_BIT_3G])
                        next_mode = MODE_3G;
                    else if (mode_enable[VALID_BIT_SD])
                        next_mode = MODE_SD;
                    else
                        next_mode = MODE_HD;

        MODE_3G:    if (mode_enable[VALID_BIT_SD])
                        next_mode = MODE_SD;
                    else if (mode_enable[VALID_BIT_HD])
                        next_mode = MODE_HD;
                    else
                        next_mode = MODE_3G;

        MODE_SD:    if (mode_enable[VALID_BIT_HD])
                        next_mode = MODE_HD;
                    else if (mode_enable[VALID_BIT_3G])
                        next_mode = MODE_3G;
                    else
                        next_mode = MODE_SD;

        default:    next_mode = MODE_HD;
    endcase

always @ (posedge clk)
    if (ce & change_mode)
        mode_int <= next_mode;

assign mode = mode_int;

//
// locked signal
//
// This flip-flop generates the locked signal based on set and clr signals from
// the FSM.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            locked_int <= 1'b0;
        else if (set_locked)
            locked_int <= 1'b1;
        else if (clr_locked)
            locked_int <= 1'b0;
    end

assign locked = locked_int;

//
// TRS timeout counter
//
// This counter is reset whenever a SAV signal is received, otherwise it
// increments. When it reaches its terminal count, the trs_tc signal is
// asserted and the the counter will roll over to zero on the next clock cycle.
//
always @ (posedge clk)
    if (ce)
        begin
            if (sav_ok | trs_tc)
                trscnt <= 0;
            else
                trscnt <= trscnt + 1;
        end

assign trs_tc = trscnt[TRSCNT_MSB];

//
// Error counter
//
// The error counter increments each time the inc_errcnt output from the FSM
// is asserted. It clears to zero when clr_errcnt is asserted. The max_errcnt
// output is asserted if the error counter equals max_errs. A MUX selects
// the correct MAX_ERRS parameter for the max_errs signal based on the locked
// signal from the FSM.
//
always @ (posedge clk)
    if (ce)
        begin
            if (inc_errcnt)
                errcnt <= errcnt + 1;
            else if (clr_errcnt)
                errcnt <= 0;
        end

assign max_errs = locked_int ? MAX_ERRS_LOCKED : MAX_ERRS_UNLOCKED;
assign max_errcnt = errcnt == max_errs;

// FSM
//
// The finite state machine is implemented in three processes, one for the
// current_state register, one to generate the next_state value, and the
// third to decode the current_state to generate the outputs.
 
//
// FSM: current_state register
//
// This code implements the current state register. It loads with the UNLOCK
// state on reset and the next_state value with each rising clock edge.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            current_state <= UNLOCK;
        else
            current_state <= next_state;
    end

//
// FSM: next_state logic
//
// This case statement generates the next_state value for the FSM based on
// the current_state and the various FSM inputs.
//
always @ (*)
    case(current_state)
        //
        // The FSM begins in the UNLOCK state and stays there until a SAV
        // symbol is found. In this state, if the TRS timeout counter reaches
        // its terminal count, the FSM moves to the ERR1 state to increment the
        // error counter.
        //
        UNLOCK: if (mode_int == MODE_XX)
                    next_state = CHANGE;
                else if (sav_ok)
                    next_state = LOCK1;
                else if (trs_tc)
                    next_state = ERR1;
                else
                    next_state = UNLOCK;

        //
        // This is the main locked state LOCK1. Once a SAV has been found, the
        // FSM stays here until either another SAV is found or the TRS counter
        // times out.
        //
        LOCK1:  if (sav_ok)
                    next_state = LOCK2;
                else if (trs_tc)
                    next_state = ERR1;
                else
                    next_state = LOCK1;

        //
        // The FSM moves to LOCK2 from LOCK1 if a SAV is found. The error
        // counter is reset in LOCK2.
        //
        LOCK2:  next_state = LOCK1;

        //
        // The FSM moves to ERR1 from LOCK 1 if the TRS timeout counter reaches
        // its terminal count before a SAV is found. In this state, the error
        // counter is incremented and the FSM moves to ERR2.
        //
        ERR1:   next_state = ERR2;

        //
        // The FSM enters ERR2 from ERR1 where the error counter was
        // incremented. In this state the max_errcnt signal is tested. If it
        // is asserted, the FSM moves to the TOGGLE state, otherwise the FSM
        // returns to LOCK1.
        //
        ERR2:   if (max_errcnt)
                    next_state = CHANGE;
                else if (locked_int)
                    next_state = LOCK1;
                else
                    next_state = UNLOCK;
                  
        //
        // In the CHANGE state, the FSM sets the change_mode signal and returns
        // to the UNLOCK state.
        //
        CHANGE: next_state = UNLOCK;

        default: next_state = UNLOCK;
    endcase

        
//
// FSM: outputs
//
// This block decodes the current state to generate the various outputs of the
// FSM.
//
always @ (*) 
begin
    // Unless specifically assigned in the case statement, all FSM outputs
    // are low.
    change_mode     = 1'b0;
    clr_errcnt      = 1'b0;
    inc_errcnt      = 1'b0;
    set_locked      = 1'b0;
    clr_locked      = 1'b0;
                                
    case(current_state) 
        
//        LOCK1:  set_locked = 1'b1;

        UNLOCK: clr_locked = 1'b1;

        LOCK2:  begin
                    clr_errcnt = 1'b1;
                    set_locked = 1'b1;
                end

        CHANGE: begin
                    change_mode = 1'b1;
                    clr_errcnt = 1'b1;
                end

        ERR1: inc_errcnt = 1'b1;
    endcase
end

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
Module Description:

This module will examine a HD data stream and detect the transport format. It
detects all the video standards currently supported by ST 292-2010, including
the ST 2048-2 2K video formats. It also detects the transports supported by 
ST 425-2010, ST 372-2010, and the SD-SDI NTSC and PAL formats.

Note that this module detects transport timing and not necessarily  the actual 
video format. The module determines the transport format by examining the timing
of the video signals and does not rely on ST 352 video payload ID packets.
However, this means that it is not able to determine the exact video format,
only the nature of the transport timing.

The transport_family port indicates the video format family of the signal
being received. It is encoded as follows:

ST 274      1920x1080   0000
ST 296      1280x720    0001
ST 2048-2   2048x1080   0010        This also includes the ST 428-9 and ST 428-19 formats
ST 295                  0011        Obsolete format
NTSC        720x486     1000
PAL         720x576     1001
UNKNOWN                 1111

All other codes are reserved for future use. The format detector does detect
and lock to the obsolete ST 260 video format, but simply reports it as the
1920x1080 ST 274 format.

The transport_rate port indicates the frame rate of the transport, not 
necessarily the frame rate of the picture. This port is encoded in the same way 
that the picture rate field of the ST 352 video payload ID packet is encoded:

NONE        0000
23.98 Hz    0010
24 Hz       0011
47.95 Hz    0100
25 Hz       0101
29.97 Hz    0110
30 Hz       0111
48 Hz       1000
50 Hz       1001
59.94 Hz    1010
60 Hz       1011

The format detector uses the bit_rate input port to distinguish between the
otherwise identical timings of the 1/1.000 rates and the 1/1.001 rates. If the
bit rate port is hard wired to 1'b0, all rates will be reported as exact 
1/1.000 rates.

The transport_locked output is asserted as long as the transport_family and
transport_rate are known good values. It will be cleared to zero whenever
mode_locked is negated.
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_triple_sdi_transport_detect
(
    input  wire        clk,                     // recovered SDI clock
    input  wire        rst,                     // synchronous reset
    input  wire        ce,                      // clock enable input
    input  wire        vid_7,                   // connect to bit 7 of C or Y data stream (V bit) 
    input  wire        eav,                     // must be asserted during XYZ word of EAV
    input  wire        sav,                     // must be asserted during XYZ word of SAV
    input  wire        bit_rate,                // 1 = rate/1.001
    input  wire [1:0]  mode,                    // SDI mode
    input  wire        mode_locked,             // indicates when mode is valid
    input  wire        level_b,                 // 3G-SDI level code
    input  wire [10:0] ln,                      // current line number
    output reg  [3:0]  transport_family=4'hF,   // transport format family code
    output reg  [3:0]  transport_rate=4'hF,     // frame rate code
    output reg         transport_scan=1'b0,     // 0 = interlaced, 1 = progressive
    output wire        transport_locked         // 1 = transport format has been detected
);

//-----------------------------------------------------------------------------
// Parameter definitions
//

localparam HCNT_MSB     = 5;                // MS bit # of modulo 63 HANC counter
localparam HANC_MOD     = 63;               // Modulo value to use for HANC counter
localparam HANC_TC      = HANC_MOD-1;
localparam VCNT_MSB     = 10;               // MS bit # of vertical counter
localparam FA_DLY_MSB   = 9;               // MS bit # of first active line delay shift reg

localparam [3:0]
    FAM_1920_1080       = 4'b0000,
    FAM_1280_720        = 4'b0001,
    FAM_2048_1080       = 4'b0010,
    FAM_ST295           = 4'b0011,
    FAM_NTSC            = 4'b1000,
    FAM_PAL             = 4'b1001,
    FAM_UNKNOWN         = 4'b1111;

localparam [2:0]
    RATE_24             = 3'b000,
    RATE_25             = 3'b001,
    RATE_30             = 3'b010,
    RATE_48             = 3'b011,
    RATE_50             = 3'b100,
    RATE_60             = 3'b101,
    RATE_UNKNOWN        = 3'b111;

localparam [3:0]
    SMPTE_RATE_NONE     = 4'h0,
    SMPTE_RATE_24M      = 4'h2,
    SMPTE_RATE_24       = 4'h3,
    SMPTE_RATE_48M      = 4'h4,
    SMPTE_RATE_25       = 4'h5,
    SMPTE_RATE_30M      = 4'h6,
    SMPTE_RATE_30       = 4'h7,
    SMPTE_RATE_48       = 4'h8,
    SMPTE_RATE_50       = 4'h9,
    SMPTE_RATE_60M      = 4'hA,
    SMPTE_RATE_60       = 4'hB;

//
// Signal definitions
//
reg                     eav_reg = 1'b0;
reg                     sav_reg = 1'b0;
reg     [1:0]           mode_reg = 0;           // SDI mode input register
reg                     level_b_reg = 0;
reg                     v_reg = 1'b0;
reg                     v_last = 1'b0;          // previous V flag value
wire                    fa;                     // first active line indicator
reg     [FA_DLY_MSB:0]  fa_dly = 0;             // delays first active signal by 8 clocks
wire                    fa_dly_out;
reg     [HCNT_MSB:0]    hanc_counter = 0;       // counts samples in HANC, modulo 8
reg     [HCNT_MSB:0]    hanc_counter_save = 0;  // saves the last HANC counter value
reg     [VCNT_MSB:0]    first_active_line = 0;  // register holds line # of first active video line
wire                    is_1080p;               // 1 when format is 1080p
reg                     hanc_counter_en = 1'b0; // HANC interval counter enable
wire                    mode_3GA;
reg                     locked = 1'b0;
reg     [HCNT_MSB+2:0]  rom_address = 0;
reg     [7:0]           rom_out = 0;
wire    [3:0]           family;
wire    [2:0]           rate;
wire                    scan;
reg                     bit_rate_reg = 1'b0;

// -----------------------------------------------------------------------------
// Input registers
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            eav_reg <= 1'b0;
        else
            eav_reg <= eav;
    end

always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            sav_reg <= 1'b0;
        else
            sav_reg <= sav;
    end

always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            mode_reg <= 2'b00;
        else
            mode_reg <= mode;
    end

always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            level_b_reg <= 1'b0;
        else
            level_b_reg <= level_b;
    end

assign mode_3GA = (mode == 2'b10) & ~level_b_reg;

always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            v_reg <= 1'b0;
        else
            v_reg <= vid_7;
    end

always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            bit_rate_reg <= 1'b0;
        else
            bit_rate_reg <= bit_rate;
    end

//------------------------------------------------------------------------------
// HANC counter
//
// The HANC counter is a modulo 63 counter that counts the duration of the
// HANC interval. It begins counting when the eav input is asserted and stops
// when sav is asserted.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst | sav_reg)
            hanc_counter_en <= 1'b0;
        else if (eav_reg)
            hanc_counter_en <= 1'b1;
    end

always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            hanc_counter <= 63; 
        else if (eav_reg)
            hanc_counter <= 0;
        else if (hanc_counter_en)
        begin
            if (hanc_counter == HANC_TC)
                hanc_counter <= 0;
            else
                hanc_counter <= hanc_counter + 1;
        end
    end

always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            hanc_counter_save <= 63;
        else if (~hanc_counter_en)
            hanc_counter_save <= hanc_counter;
    end

//------------------------------------------------------------------------------
// Detect first active video line
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            v_last <= 1'b0;
        else if (eav_reg)
            v_last <= v_reg;
    end

assign fa = ~v_reg & v_last & eav_reg;

always @ (posedge clk)
    if (ce)
        fa_dly <= {fa_dly[FA_DLY_MSB-1:0], fa};

assign fa_dly_out = fa_dly[FA_DLY_MSB-2];

always @ (posedge clk)
    if (ce)
    begin
        if (fa_dly_out)
            first_active_line <= ln;
    end
    
assign is_1080p = first_active_line == 11'd42;

//------------------------------------------------------------------------------
// Transport family code ROM
//
always @ (posedge clk)
    if (ce)
        rom_address <= {mode_3GA, is_1080p, hanc_counter_save};

always @ (*)
    case(rom_address)
        8'd20   :   rom_out = {1'b0, RATE_30, FAM_NTSC};           // SD:      NTSC
        8'd32   :   rom_out = {1'b0, RATE_25, FAM_PAL};            // SD:      PAL
        8'd24   :   rom_out = {1'b0, RATE_30, FAM_1920_1080};      // HD/3GB:  1080i60 
        8'd23   :   rom_out = {1'b0, RATE_25, FAM_1920_1080};      // HD/3GB:  1080i50
        8'd88   :   rom_out = {1'b1, RATE_30, FAM_1920_1080};      // HD/3GB:  1080p30
        8'd87   :   rom_out = {1'b1, RATE_25, FAM_1920_1080};      // HD/3GB:  1080p25
        8'd71   :   rom_out = {1'b1, RATE_24, FAM_1920_1080};      // HD-3GB:  1080p24
        8'd7    :   rom_out = {1'b0, RATE_24, FAM_1920_1080};      // HD-3GB:  1080psF24
        8'd51   :   rom_out = {1'b1, RATE_60, FAM_1280_720};       // HD:      720p60
        8'd3    :   rom_out = {1'b1, RATE_50, FAM_1280_720};       // HD:      720p50
        8'd0    :   rom_out = {1'b1, RATE_30, FAM_1280_720};       // HD:      720p30
        8'd30   :   rom_out = {1'b1, RATE_25, FAM_1280_720};       // HD:      720p25
        8'd6    :   rom_out = {1'b1, RATE_24, FAM_1280_720};       // HD:      720p24
        8'd86   :   rom_out = {1'b1, RATE_30, FAM_2048_1080};      // HD/3GB:  2Kx1080p30
        8'd85   :   rom_out = {1'b1, RATE_25, FAM_2048_1080};      // HD/3GB:  2Kx1080p25
        8'd69   :   rom_out = {1'b1, RATE_24, FAM_2048_1080};      // HD/3GB:  2Kx1080p24
        8'd22   :   rom_out = {1'b0, RATE_30, FAM_2048_1080};      // HD/3GB:  2Kx1080psF30
        8'd21   :   rom_out = {1'b0, RATE_25, FAM_2048_1080};      // HD/3GB:  2Kx1080psF25
        8'd5    :   rom_out = {1'b0, RATE_24, FAM_2048_1080};      // HD/3GB:  2Kx1080psF24
        8'd216  :   rom_out = {1'b1, RATE_60, FAM_1920_1080};      // 3GA:     1080p60
        8'd215  :   rom_out = {1'b1, RATE_50, FAM_1920_1080};      // 3GA:     1080p50
        8'd214  :   rom_out = {1'b1, RATE_60, FAM_2048_1080};      // 3GA:     2Kx1080p60
        8'd213  :   rom_out = {1'b1, RATE_50, FAM_2048_1080};      // 3GA:     2Kx1080p50
        8'd197  :   rom_out = {1'b1, RATE_48, FAM_2048_1080};      // 3GA:     2Kx1080p48
        8'd180  :   rom_out = {1'b0, RATE_30, FAM_1920_1080};      // 3GA:     1080i60
        8'd178  :   rom_out = {1'b0, RATE_25, FAM_1920_1080};      // 3GA:     1080i50
        8'd244  :   rom_out = {1'b1, RATE_30, FAM_1920_1080};      // 3GA:     1080p30
        8'd242  :   rom_out = {1'b1, RATE_25, FAM_1920_1080};      // 3GA:     1080p25
        8'd210  :   rom_out = {1'b1, RATE_24, FAM_1920_1080};      // 3GA:     1080p24
        8'd146  :   rom_out = {1'b0, RATE_24, FAM_1920_1080};      // 3GA:     1080psF24
        8'd240  :   rom_out = {1'b1, RATE_30, FAM_2048_1080};      // 3GA:     2Kx1080p30
        8'd238  :   rom_out = {1'b1, RATE_25, FAM_2048_1080};      // 3GA:     2Kx1080p25
        8'd206  :   rom_out = {1'b1, RATE_24, FAM_2048_1080};      // 3GA:     2Kx1080p24
        8'd176  :   rom_out = {1'b0, RATE_30, FAM_2048_1080};      // 3GA:     2Kx1080psF30
        8'd174  :   rom_out = {1'b0, RATE_25, FAM_2048_1080};      // 3GA:     2Kx1080psF25
        8'd142  :   rom_out = {1'b0, RATE_24, FAM_2048_1080};      // 3GA:     2Kx1080psF24
        8'd171  :   rom_out = {1'b1, RATE_60, FAM_1280_720};       // 3GA:     720p60
        8'd138  :   rom_out = {1'b1, RATE_50, FAM_1280_720};       // 3GA:     720p50
        8'd132  :   rom_out = {1'b1, RATE_30, FAM_1280_720};       // 3GA:     720p30
        8'd129  :   rom_out = {1'b1, RATE_25, FAM_1280_720};       // 3GA:     720p25
        8'd144  :   rom_out = {1'b1, RATE_24, FAM_1280_720};       // 3GA:     720p24
        8'd11   :   rom_out = {1'b0, RATE_25, FAM_ST295};          // HD:      ST295
        default :   rom_out = {1'b0, RATE_UNKNOWN, FAM_UNKNOWN};
    endcase

assign family = rom_out[3:0];
assign rate   = rom_out[6:4];
assign scan   = rom_out[7];

always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            transport_family <= FAM_UNKNOWN;
        else if (((family == FAM_PAL) || (family == FAM_NTSC)) && (mode_reg != 2'b01))
            transport_family <= FAM_UNKNOWN;
        else
            transport_family <= family;
    end

always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            transport_rate <= SMPTE_RATE_NONE;
        else if (family == FAM_NTSC)
            transport_rate <= SMPTE_RATE_30M;
        else
            casex({rate, bit_rate_reg})
                4'b000_0 :  transport_rate <= SMPTE_RATE_24;
                4'b000_1 :  transport_rate <= SMPTE_RATE_24M;
                4'b001_x :  transport_rate <= SMPTE_RATE_25;
                4'b010_0 :  transport_rate <= SMPTE_RATE_30;
                4'b010_1 :  transport_rate <= SMPTE_RATE_30M;
                4'b011_0 :  transport_rate <= SMPTE_RATE_48;
                4'b011_1 :  transport_rate <= SMPTE_RATE_48M;
                4'b100_x :  transport_rate <= SMPTE_RATE_50;
                4'b101_0 :  transport_rate <= SMPTE_RATE_60;
                4'b101_1 :  transport_rate <= SMPTE_RATE_60M;   
                default  :  transport_rate <= SMPTE_RATE_NONE;
            endcase
    end

always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            transport_scan <= 1'b0;
        else
            transport_scan <= scan;
    end


//------------------------------------------------------------------------------
// Transport locked detection
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst | ~mode_locked)
            locked <= 1'b0;
        else if (mode_locked & (mode == 2'b01))
            locked <= (rate != RATE_UNKNOWN) && (family != FAM_UNKNOWN);
        else if (fa_dly[FA_DLY_MSB])
            locked <= (rate != RATE_UNKNOWN) && (family != FAM_UNKNOWN);
    end

assign transport_locked = locked;

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
Module Description:

This is the output module for a triple-rate SD/HD/3G-SDI transmitter. It
inserts EDH packets for SD and CRC & LN words for HD and 3G. It scrambles the
data for transmission. For SD, it implements 11X bit replication. For HD and
3G, it converts the data to a 10-bit data stream for connection to a 20-bit
TXDATA port on the serializer.

The clk frequency is normally 74.25 MHz for HD-SDI and 148.5 MHz for 3G-SDI and
SD-SDI. The clock enable must be 1 always for HD-SDI and 3G-SDI, unless for some
reason, the clock frequency is twice as much as normal). For SD-SDI, it must 
average 27 MHz, by asserting it at a 5/6/5/6 clock cycle cadence. For 
level B 3G-SDI, all four input data streams are active and the actual data rate 
is 74.25 MHz, even though the clock frequency is 148.5 MHz. In this case, 
din_rdy must be asserted every other clock cycle to indicate on which clock 
cycle the input data should be taken by the module. For all other modes, 
din_rdy should always be High. For dual link HD-SDI with 1080p 60 Hz or 50 Hz
video, the clock frequency will typically be 148.5 MHz, but the data rate is
74.25 MHz and ce is asserted every other clock cycle with din_rdy always High.
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_triple_sdi_tx_output (
    input  wire             clk,                // 74.25 MHz (HD) or 148.5 MHz (SD/3G)
    input  wire             din_rdy,            // input data ready
    input  wire [1:0]       ce,                 // runs at scrambler data rate: 27 MHz, 74.25 MHz, or 148.5 MHz
    input  wire             rst,                // sync reset input
    input  wire [1:0]       mode,               // data path mode: 00 = HD or 3GA, 01 = SD, 10 = 3GB
    input  wire [9:0]       ds1a,               // SD Y/C input, HD Y input, 3G Y input, dual link A_Y input
    input  wire [9:0]       ds2a,               // HD C input, 3G C input, dual link A_C input
    input  wire [9:0]       ds1b,               // dual link B_Y input
    input  wire [9:0]       ds2b,               // dual link B_C input
    input  wire             insert_crc,         // 1 = insert CRC for HD and 3G
    input  wire             insert_ln,          // 1 = insert LN for HD and 3G
    input  wire             insert_edh,         // 1 = generate and insert EDH packets in SD
    input  wire [10:0]      ln_a,               // HD/3G line number for link A
    input  wire [10:0]      ln_b,               // HD/3G line number for link B
    input  wire             eav,                // HD/3G EAV (asserted on EAV XYZ word)
    input  wire             sav,                // HD/3G SAV (asserted on SAV XYZ word)
    input  wire             sd_bitrep_bypass,   // 1 bypasses the SD-SDI 11X bit replicator
    output wire [19:0]      txdata,             // output data stream
    output wire             ce_align_err);      // 1 if ce 5/6/5/6 cadence is broken


//
// Internal signals
//
reg  [9:0]      ds1a_reg = 0;               // input registers
reg  [9:0]      ds2a_reg = 0;
reg  [9:0]      ds1b_reg = 0;
reg  [9:0]      ds2b_reg = 0;
reg  [10:0]     ln_a_reg = 0;
reg  [10:0]     ln_b_reg = 0;
reg  [1:0]      mode_reg = 0;
reg             eav_reg = 0;
reg             sav_reg = 0;
reg             ins_crc_reg = 0;
reg             ins_ln_reg = 0;
reg             ins_edh_reg = 0;
reg  [3:0]      eav_dly = 0;                // generates timing signals based on EAV
wire [9:0]      edh_out;                    // EDH processor video output
wire [9:0]      edh_mux;                    // EDH processor bypass mux
wire [9:0]      ds1a_edh_mux;               // chooses SD or HD/3G data steam 1 A
wire [9:0]      ln_out_ds1a;                // data stream 1 A out of LN insert
wire [9:0]      ln_out_ds2a;                // data stream 2 A out of LN insert
wire [9:0]      ln_out_ds1b;                // data stream 1 B out of LN insert
wire [9:0]      ln_out_ds2b;                // data stream 2 B out of LN insert
wire [17:0]     crc_ds1a;                   // calculated CRC for data stream 1 A
wire [17:0]     crc_ds2a;                   // calculated CRC for data stream 2 A
wire [17:0]     crc_ds1b;                   // calculated CRC for data stream 1 B
wire [17:0]     crc_ds2b;                   // calculated CRC for data stream 2 B
wire [9:0]      crc_out_ds1a;               // data stream 1 A out of CRC insert
wire [9:0]      crc_out_ds2a;               // data stream 2 A out of CRC insert
wire [9:0]      crc_out_ds1b;               // data stream 1 B out of CRC insert
wire [9:0]      crc_out_ds2b;               // data stream 2 B out of CRC insert
wire [9:0]      scram_in_ds1;               // scrambler ds1 input
wire [9:0]      scram_in_ds2;               // scrambler ds2 input
wire [19:0]     scram_out;                  // scrambler registered output
wire [19:0]     sd_bit_rep_out;             // output of SD 11X bit replicate
reg             crc_en = 1'b0;              // CRC control signal
reg             clr_crc = 1'b0;             // CRC control signal
wire            mode_SD;                    // asserted when mode = 01
wire            mode_3G_B;                  // asserted when mode = 10
reg  [19:0]     txdata_reg = 0;
wire            align_err;


//
// Input registers
//
always @ (posedge clk)
    if (ce[0])
        if (din_rdy)
            begin
                ds1a_reg    <= ds1a;
                ds2a_reg    <= ds2a;
                ds1b_reg    <= ds1b;
                ds2b_reg    <= ds2b;
                ln_a_reg    <= ln_a;
                ln_b_reg    <= ln_b;
                mode_reg    <= mode;
                eav_reg     <= eav;
                sav_reg     <= sav;
                ins_crc_reg <= insert_crc;
                ins_ln_reg  <= insert_ln;
                ins_edh_reg <= insert_edh;
            end

assign mode_SD = mode_reg == 2'b01;
assign mode_3G_B = mode_reg == 2'b10;

//
// EAV delay register
//
// Generates timing control signals for line number insertion and CRC generation
// and insertion.
//
always @ (posedge clk)
    if (ce[0])
    begin
        if (rst) 
            eav_dly <= 0;
        else if (din_rdy)
            eav_dly <= {eav_dly[2:0], eav_reg};
    end

//
// Instantiate the line number formatting and insertion modules
//
v_smpte_sdi_v3_0_8_hdsdi_insert_ln INSLNA (
    .insert_ln  (ins_ln_reg),
    .ln_word0   (eav_dly[0]),
    .ln_word1   (eav_dly[1]),
    .c_in       (ds2a_reg),
    .y_in       (ds1a_reg),
    .ln         (ln_a_reg),
    .c_out      (ln_out_ds2a),
    .y_out      (ln_out_ds1a));
        
v_smpte_sdi_v3_0_8_hdsdi_insert_ln INSLNB (
    .insert_ln  (ins_ln_reg),
    .ln_word0   (eav_dly[0]),
    .ln_word1   (eav_dly[1]),
    .c_in       (ds2b_reg),
    .y_in       (ds1b_reg),
    .ln         (ln_b_reg),
    .c_out      (ln_out_ds2b),
    .y_out      (ln_out_ds1b));

//
// Generate timing control signals for the CRC calculators.
//
// The crc_en signal determines which words are included into the CRC 
// calculation. All words that enter the hdsdi_crc module when crc_en is high
// are included in the calculation. To meet the HD-SDI spec, the CRC calculation
// must being with the first word after the SAV and end after the second line
// number word after the EAV.
//
// The clr_crc signal clears the internal registers of the hdsdi_crc modules to
// cause a new CRC calculation to begin. The crc_en signal is asserted during
// the XYZ word of the SAV since the next word after the SAV XYZ word is the
// first word to be included into the new CRC calculation.
//
always @ (posedge clk)
    if (ce[0])
    begin
        if (rst)
            crc_en <= 1'b0;
        else if (din_rdy)
            begin
                if (sav_reg)
                    crc_en <= 1'b1;
                else if (eav_dly[1])
                    crc_en <= 1'b0;
            end
    end

always @ (posedge clk)
    if (ce[0])
    begin
        if (rst)
            clr_crc <= 1'b0;
        else if (din_rdy)
            clr_crc <= sav_reg;
    end

//
// Instantiate the CRC generators
//
v_smpte_sdi_v3_0_8_hdsdi_crc2 CRC1A (
    .clk        (clk),
    .ce         (ce[0]),
    .en         (din_rdy & crc_en),
    .rst        (rst),
    .clr        (clr_crc),
    .d          (ln_out_ds1a),
    .crc_out    (crc_ds1a)
);

v_smpte_sdi_v3_0_8_hdsdi_crc2 CRC2A (
    .clk        (clk),
    .ce         (ce[0]),
    .en         (din_rdy & crc_en),
    .rst        (rst),
    .clr        (clr_crc),
    .d          (ln_out_ds2a),
    .crc_out    (crc_ds2a)
);

v_smpte_sdi_v3_0_8_hdsdi_crc2 CRC1B (
    .clk        (clk),
    .ce         (ce[0]),
    .en         (din_rdy & crc_en),
    .rst        (rst),
    .clr        (clr_crc),
    .d          (ln_out_ds1b),
    .crc_out    (crc_ds1b)
);

v_smpte_sdi_v3_0_8_hdsdi_crc2 CRC2B (
    .clk        (clk),
    .ce         (ce[0]),
    .en         (din_rdy & crc_en),
    .rst        (rst),
    .clr        (clr_crc),
    .d          (ln_out_ds2b),
    .crc_out    (crc_ds2b)
);

//
// Insert the CRC values into the data streams. The CRC values are inserted
// after the line number words after the EAV.
//
v_smpte_sdi_v3_0_8_hdsdi_insert_crc CRCA (
    .insert_crc (ins_crc_reg),
    .crc_word0  (eav_dly[2]),
    .crc_word1  (eav_dly[3]),
    .y_in       (ln_out_ds1a),
    .c_in       (ln_out_ds2a),
    .y_crc      (crc_ds1a),
    .c_crc      (crc_ds2a),
    .y_out      (crc_out_ds1a),
    .c_out      (crc_out_ds2a));

v_smpte_sdi_v3_0_8_hdsdi_insert_crc CRCB (
    .insert_crc (ins_crc_reg),
    .crc_word0  (eav_dly[2]),
    .crc_word1  (eav_dly[3]),
    .y_in       (ln_out_ds1b),
    .c_in       (ln_out_ds2b),
    .y_crc      (crc_ds1b),
    .c_crc      (crc_ds2b),
    .y_out      (crc_out_ds1b),
    .c_out      (crc_out_ds2b));

//
// EDH Processor for SD-SDI
//

v_smpte_sdi_v3_0_8_edh_processor EDH (
    .clk             (clk),
    .ce              (ce[1]),
    .rst             (rst),
    .vid_in          (ds1a_reg),
    .reacquire       (1'b0),
    .en_sync_switch  (1'b0),
    .en_trs_blank    (1'b0),
    .anc_idh_local   (1'b0),
    .anc_ues_local   (1'b0),
    .ap_idh_local    (1'b0),
    .ff_idh_local    (1'b0),
    .errcnt_flg_en   (16'b0),
    .clr_errcnt      (1'b0),
    .receive_mode    (1'b0),

    .vid_out         (edh_out),
    .std             (),
    .std_locked      (),
    .trs             (),
    .field           (),
    .v_blank         (),
    .h_blank         (),
    .horz_count      (),
    .vert_count      (),
    .sync_switch     (),
    .locked          (),
    .eav_next        (),
    .sav_next        (),
    .xyz_word        (),
    .anc_next        (),
    .edh_next        (),
    .rx_ap_flags     (),
    .rx_ff_flags     (),
    .rx_anc_flags    (),
    .ap_flags        (),
    .ff_flags        (),
    .anc_flags       (),
    .packet_flags    (),
    .errcnt          (),
    .edh_packet      ());

//
// This mux bypasses the EDH inserter if insert_edh is 0.
//
assign edh_mux = ins_edh_reg ? edh_out : ds1a_reg;

//
// These muxes select the inputs for the scrambler. In SD, HD, and 3G level A
// modes, they simply pass ds1a and ds2a through. In 3G level B mode, they
// interleave data streams 1 and 2 of link A onto the Y input of the scrambler
// and data streams 1 and 2 of link B onto the C input.
//
assign scram_in_ds1 = mode_3G_B ? (din_rdy ? crc_out_ds1a : crc_out_ds2a) : crc_out_ds1a;
assign scram_in_ds2 = mode_3G_B ? (din_rdy ? crc_out_ds1b : crc_out_ds2b) : crc_out_ds2a;

//
// This mux selects the SD path or the HD/3G path for data stream 1.
//
assign ds1a_edh_mux = mode_SD ? edh_mux : scram_in_ds1;

//
// SDI scrambler
//
// In SD mode, this module scrambles just 10 bits on the Y channel. In HD and
// 3G modes, this modules scrambles 20 bits. In HD mode, the scrambler is
// enabled by ce AND din_rdy in order to support both regular HD-SDI and dual-
// link HD-SDI. In 3G-SDI mode, the scrambler is controlled by just ce.
//

v_smpte_sdi_v3_0_8_multi_sdi_encoder SCRAM (
    .clk        (clk),
    .ce         (ce[0]),
    .hd_sd      (mode_SD),
    .nrzi       (1'b1),
    .scram      (1'b1),
    .c          (scram_in_ds2),
    .y          (ds1a_edh_mux),
    .q          (scram_out));

//
// SD 11X bit replicater
//
v_smpte_sdi_v3_0_8_sdi_bitrep_20b BITREP (
    .clk        (clk),
    .rst        (rst),
    .ce         (ce[0]),
    .d          (scram_out[19:10]),
    .q          (sd_bit_rep_out),
    .align_err  (align_err));

assign ce_align_err = align_err & mode_SD;

//
// Output register
//
always @ (posedge clk)
    if (mode_SD & ~sd_bitrep_bypass)
        txdata_reg <= sd_bit_rep_out;
    else if (ce[0])
        txdata_reg <= scram_out;

assign txdata = txdata_reg;

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
Module Description:

This module inserts SMPTE 352M video payload ID packets into SD-SDI, HD-SDI, or
3G-SDI data streams. The module works with triple-rate SDI TX datapaths 
designed for 10-bit SERDES interfaces or 20-bit SERDES interfaces. The
difference is simply the clock, clock enable frequencies, and din_rdy
frequencies.

When used with 10-bit SERDES interfaces, such as the Virtex-5 GTP configured
with a 10-bit TXDATA port, the module works this way:

For SD-SDI, it accepts one 10-bit multiplexed Y/C data stream. The clock rate
must be 297 MHz and ce must be asserted 1 out of 11 clock cycles for a 27 MHz
data rate. The din_rdy input must be High always.

For HD-SDI, it accepts two 10-bit data streams, Y and C,. The clock rate is
148.5 MHz and ce must be asserted every other clock cycle for an input data
rate of 74.25 MHz. The din_rdy input must be High always.

For 3G-SDI level A, it accepts two 10-bit data streams. These can either be
the Y and C channels of 1080p 50 or 60 Hz video, or they can be pre-formatted
3G-SDI level A data streams. The clock frequency is 297 MHz and ce must be
asserted every other clock cycle for an input data rate of 148.5 MHz. The
din_rdy input must be High always.

For 3G-SDI level B, it accepts four 10-bit data streams. These can either be
a SMPTE 372M dual link pair or they can be two indpenedent, but synchronized,
HD-SDI signals. The clock frequency is 297 MHz, ce runs at 148.5 MHz, and
din_rdy is asserted one out of four clock cycles for an input data rate of
74.25 MHz. Input data is only accepted when din_rdy and ce are both High.
Because din_rdy is also used to mux the four data streams down to two data
streams on the output of the module, it must have a 50% duty cycle -- High for
two clock cycles and low for two clock cycles.

When used with 20-bit SERDES interfaces, such as the Virtex-5 GTX configured
with a 20-bit TXDATA port, the module works this way:

For SD-SDI, it accepts one 10-bit multiplexed Y/C data stream. The clock rate
must be 148.5 MHz and ce must be asserted with a 5/6/5/6 clock cycle cadence
giving a 27 MHz data rate. The din_rdy input must be High always.

For HD-SDI, it accepts two 10-bit data streams, Y and C,. The clock rate is
74.25 MHz and ce and din_rdy inputs must always be High.

For 3G-SDI level A, it accepts two 10-bit data streams. These can either be
the Y and C channels of 1080p 50 or 60 Hz video, or they can be pre-formatted
3G-SDI level A data streams. The clock frequency is 148.5 MHz. The ce and the
din_rdy inputs must be High always.

For 3G-SDI level B, it accepts four 10-bit data streams. These can either be
a SMPTE 372M dual link pair or they can be two indpenedent, but synchronized,
HD-SDI signals. The clock frequency is 148.5 MHz. The ce input should be High
always. The din_rdy input must be asserted every other clock cycle giving an
input data rate of 74.25 MHz. Input data is only accepted when din_rdy and ce 
are both High. Because din_rdy is also used to mux the four data streams down to two data
streams on the output of the module, it must have a 50% duty cycle -- High for
one clock cycle and low for one clock cycle.

*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_triple_sdi_vpid_insert (
    input  wire             clk,            // clock input
    input  wire             ce,             // clock enable
    input  wire             din_rdy,        // input data ready for level B, must be 1 for all other modes
    input  wire             rst,            // sync reset input
    input  wire [1:0]       sdi_mode,       // 00 = HD, 01 = SD, 10 = 3G
    input  wire             level,          // 0 = level A, 1 = level B
    input  wire             enable,         // 0 = disable insertion
    input  wire             overwrite,      // 1 = overwrite existing VPID packets
    input  wire [7:0]       byte1,          // VPID byte 1
    input  wire [7:0]       byte2,          // VPID byte 2
    input  wire [7:0]       byte3,          // VPID byte 3
    input  wire [7:0]       byte4a,         // VPID byte 4 for link A
    input  wire [7:0]       byte4b,         // VPID byte 4 for link B
    input  wire [10:0]      ln_a,           // current line number for link A
    input  wire [10:0]      ln_b,           // current line number for link B
    input  wire [10:0]      line_f1,        // VPID line for field 1
    input  wire [10:0]      line_f2,        // VPID line for field 2
    input  wire             line_f2_en,     // enable VPID insertion on line_f2
    input  wire [9:0]       a_y_in,         // SD in, HD & 3GA Y in, 3GB A Y in
    input  wire [9:0]       a_c_in,         // HD & 3GA C in, 3GB A C in
    input  wire [9:0]       b_y_in,         // 3GB only, B Y in
    input  wire [9:0]       b_c_in,         // 3GB only, B C in
    output wire [9:0]       ds1a_out,       // data stream 1, link A out
    output wire [9:0]       ds2a_out,       // data stream 2, link A out
    output wire [9:0]       ds1b_out,       // data stream 1, link B out
    output wire [9:0]       ds2b_out,       // data stream 2, link B out
    output wire             eav_out,        // asserted on XYZ word of EAV
    output wire             sav_out,        // asserted on XYZ word of SAV
    output reg  [1:0]       out_mode        // connect to mode port of the
                                            // triple_sdi_tx_output module
);

wire    [9:0]   ds2_in;
wire    [9:0]   ds1_c;
wire    [9:0]   ds2_y;
wire    [10:0]  ds2_ln;
reg     [1:0]   sdi_mode_reg = 2'b00;
wire            mode_SD;
wire            mode_3G_A;
wire            mode_3G_B;
reg             level_reg = 1'b0;

//
// Register timing critical signals
//
always @ (posedge clk)
    if (ce)
        sdi_mode_reg <= sdi_mode;

always @ (posedge clk)
    if (ce)
        level_reg <= level;

assign mode_SD = sdi_mode_reg == 2'b01;
assign mode_3G_A = (sdi_mode_reg == 2'b10) & ~level_reg;
assign mode_3G_B = (sdi_mode_reg == 2'b10) & level_reg;

//
// Insert VPID packets on both data streams
//
// The SMPTE352_vpid_insert module only inserts VPID packets into the Y data
// stream, so two of them are used to insert packets into each data stream.
//
v_smpte_sdi_v3_0_8_SMPTE352_vpid_insert VPIDINS1 (
    .clk            (clk),
    .ce             (ce & din_rdy),
    .rst            (rst),
    .hd_sd          (mode_SD),
    .level_b        (level_reg),
    .enable         (enable),
    .overwrite      (overwrite),
    .line           (ln_a),
    .line_a         (line_f1),
    .line_b         (line_f2),
    .line_b_en      (line_f2_en),
    .byte1          (byte1),
    .byte2          (byte2),
    .byte3          (byte3),
    .byte4          (byte4a),
    .y_in           (a_y_in),
    .c_in           (a_c_in),
    .y_out          (ds1a_out),
    .c_out          (ds1_c),
    .eav_out        (eav_out),
    .sav_out        (sav_out));

assign ds2_in = mode_3G_A ? a_c_in : b_y_in;
assign ds2_ln = mode_3G_B ? ln_b : ln_a;

v_smpte_sdi_v3_0_8_SMPTE352_vpid_insert VPIDINS2 (
    .clk            (clk),
    .ce             (ce & din_rdy),
    .rst            (rst),
    .hd_sd          (mode_SD),
    .level_b        (level_reg),
    .enable         (enable),
    .overwrite      (overwrite),
    .line           (ds2_ln),
    .line_a         (line_f1),
    .line_b         (line_f2),
    .line_b_en      (line_f2_en),
    .byte1          (byte1),
    .byte2          (byte2),
    .byte3          (byte3),
    .byte4          (byte4b),
    .y_in           (ds2_in),
    .c_in           (b_c_in),
    .y_out          (ds2_y),
    .c_out          (ds2b_out),
    .eav_out        (),
    .sav_out        ());

//
// Output muxes
//
assign ds2a_out = mode_3G_A ? ds2_y : ds1_c;
assign ds1b_out = ds2_y;

always @ (*)
    if (mode_SD)
        out_mode = 2'b01;
    else if (mode_3G_B)
        out_mode = 2'b10;
    else
        out_mode = 2'b00;
         
endmodule



// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/* 
This module examines the input video stream for TRS symbols and ancillary data
packets. It does some decoding of the TRS symbols and ANC packets to generate
a variety of outputs.

This input video stream is passed through a four register pipeline, delaying the
video by four clock cycles. This allows the pipeline to contain the entire TRS
symbol or the ancillary data flag plus DID word to allow them to be decoded
before the video emerges from the module.

This module has the following inputs:

clk: clock input

ce: clock enable

rst: synchronous reset input

vid_in: input video stream port

This module generates the following outputs:

vid_out: This is the output video stream. It is identical to the input video
stream, but delayed by four clock cycles.

rx_trs: This output is asserted only when the first word of a TRS symbol is
present on vid_out.

rx_eav: This output is asserted only when the first word of an EAV symbol is
present on vid_out.

rx_sav: This output is asserted only when the first word of an SAV symbol is
present on vid_out.

rx_f: This is the field indicator bit F latched from the XYZ word of the last
received TRS symbol.

rx_v: This is the vertical blanking interval bit V latched from the XYZ word of
the last received TRS symbol.

rx_h: This is the horizontal blanking interval bit H latched from the XYZ word
of the last received TRS symbol.

rx_xyz: This outpuot is asserted when the XYZ word of a TRS symbol is present on
vid_out.

rx_xyz_err: This output is asserted when the received XYZ word contains an
error. It is only asserted when the XYZ word appears on vid_out. This signal is
only valid for the 4:2:2 video standards.

rx_xyz_err_4444: This output is asserted when the received XYZ word contains an
error. It is only asserted when the XYZ word appears on vid_out. This signals is
only valid for the 4:4:4:4 video standards.

rx_anc: This output is asserted when the first word of an ANC packet (the first
word of the ancillary data flag) is present on vid_out.

rx_edh: This output is asserted when the first word of an EDH packet (the first
word of the ancillary data flag) is present on vid_out.
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_trs_detect (
    input  wire             clk,            // clock input
    input  wire             ce,             // clock enable
    input  wire             rst,            // sync reset input
    input  wire [9:0]       vid_in,         // video input

    // outputs
    output wire [9:0]       vid_out,        // delayed and clipped video output
    output wire             rx_trs,         // asserted during first word of TRS symbol
    output wire             rx_eav,         // asserted during first word of an EAV symbol
    output wire             rx_sav,         // asserted during first word of an SAV symbol
    output wire             rx_f,           // field bit from last received TRS symbol
    output wire             rx_v,           // vertical blanking interval bit from last TRS symbol
    output wire             rx_h,           // horizontal blanking interval bit from last TRS symbol
    output wire             rx_xyz,         // asserted during TRS XYZ word
    output wire             rx_xyz_err,     // XYZ error flag for non-4444 standards
    output wire             rx_xyz_err_4444,// XYZ error flag for 4444 standards
    output wire             rx_anc,         // asserted during first word of ADF
    output wire             rx_edh          // asserted during first word of ADF if it is an EDH packet
);

         
//-----------------------------------------------------------------------------
// Signal definitions
//

reg     [9:0]   in_reg = 0;                     // input register
reg     [9:0]   pipe1_vid = 0;                  // first pipeline register
reg             pipe1_ones = 1'b0;              // asserted if pipe1_vid[9:2] is all 1s
reg             pipe1_zeros = 1'b0;             // asserted if pipe1_vid[9:2] is all 0s
reg     [9:0]   pipe2_vid = 0;                  // second pipeline register
reg             pipe2_ones = 1'b0;              // asserted if pipe2_vid[9:2] is all 1s 
reg             pipe2_zeros = 1'b0;             // asserted if pipe2_vid[9:2] is all 0s
reg     [9:0]   out_reg_vid = 0;                // output register - video stream
reg             out_reg_anc = 1'b0;             // output register - rx_anc signal
reg             out_reg_edh = 1'b0;             // output register - rx_edh signal
reg             out_reg_trs = 1'b0;             // output register - rx_trs signal
reg             out_reg_eav = 1'b0;             // output register - rx_eav signal
reg             out_reg_sav = 1'b0;             // output register - rx_sav signal
reg             out_reg_xyz = 1'b0;             // output register - rx_xyz signal
reg             out_reg_xyz_err = 1'b0;         // output register - rx_xyz_err signal
reg             out_reg_xyz_err_4444 = 1'b0;    // output register - rx_xyz_err_4444 signal
reg             out_reg_f = 1'b0;               // output register - rx_f signal
reg             out_reg_v = 1'b0;               // output register - rx_v signal
reg             out_reg_h = 1'b0;               // output register - rx_h signal
wire            xyz;                            // XYZ detect input to out_reg
wire            xyz_err;                        // XYZ error detect input to out_reg
wire            xyz_err_4444;                   // XYZ 4444 error detect input to out_reg
wire            anc;                            // anc input to out_reg
wire            trs;                            // trs input to out_reg
wire            eav;                            // eav input to out_reg
wire            sav;                            // sav input to out_reg
wire            edh_in;                         // asserted when in_reg = 0x1f4 (EDH DID)
wire            all_ones_in;                    // asserted when in_reg is all ones
wire            all_zeros_in;                   // asserted when in_reg is all zeros
reg     [1:0]   trs_delay = 2'b00;              // delay register used to assert xyz signal
wire            f;                              // internal version of rx_f
wire            v;                              // internal version of rx_v
wire            h;                              // internal version of rx_h

//
// in_reg
//
// The input register loads the value on the vid_in port.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            in_reg <= 0;
        else
            in_reg <= vid_in;
    end


//
// all ones and all zeros detectors
//
// This logic determines if the input video word is all ones or all zeros. To
// provide compatibility with 8-bit video equipment, the LS two bits are
// ignored.  
// 
assign all_ones_in = &in_reg[9:2];
assign all_zeros_in = ~|in_reg[9:2];


//
// DID detector decoder
//
// The edh_in signal is asserted if the in_reg contains a value of 0x1f4.
// This is the value of the DID word for an EDH packet. 
//
assign edh_in    = (vid_in == 10'h1f4);

//
// pipe1
//
// The pipe1 register holds the inut video and the outputs of the all zeros
// and all ones detectors.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
        begin
            pipe1_vid   <= 0;
            pipe1_ones  <= 1'b0;
            pipe1_zeros <= 1'b0;
        end
        else
        begin
            pipe1_vid   <= in_reg;
            pipe1_ones  <= all_ones_in;
            pipe1_zeros <= all_zeros_in;
        end
    end


//
// pipe2_reg
//
// The pipe2 register delays the contents of the pipe1 register for one more
// clock cycle.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
        begin
            pipe2_vid   <= 0;
            pipe2_ones  <= 1'b0;
            pipe2_zeros <= 1'b0;
        end
        else
        begin
            pipe2_vid   <= pipe1_vid;
            pipe2_ones  <= pipe1_ones;
            pipe2_zeros <= pipe1_zeros;
        end
    end


//
// TRS & ANC detector
//
// The trs signal when the sequence 3ff, 000, 000 is stored in the pipe2, pipe1,
// and in_reg registers, respectively. The anc signal is asserted when these
// same registers hold the sequence 000, 3ff, 3ff.
//
assign trs = all_zeros_in & pipe1_zeros & pipe2_ones;
assign anc = all_ones_in & pipe1_ones & pipe2_zeros;
assign eav = trs & vid_in[6];
assign sav = trs & ~vid_in[6];

//
// f, v, and h flag generation
//
assign f = trs ? vid_in[8] : out_reg_f;
assign v = trs ? vid_in[7] : out_reg_v;
assign h = trs ? vid_in[6] : out_reg_h;

//
// XYZ and XYZ error logic
//
// The xyz signal is asserted when the pipe2 register holds the XYZ word of a
// TRS symbol. The xyz_err signal is asserted if an error is detected in the
// format of the XYZ word stored in pipe2. This signal is not valid for the
// 4444 component digital video formats. The xyz_err_4444 signal is asserted
// for XYZ word format errors.
//
assign xyz = trs_delay[1];

assign xyz_err = 
    xyz & 
    ((pipe2_vid[5] ^ pipe2_vid[7] ^ pipe2_vid[6]) |                 // P3 = V ^ H
     (pipe2_vid[4] ^ pipe2_vid[8] ^ pipe2_vid[6]) |                 // P2 = F ^ H
     (pipe2_vid[3] ^ pipe2_vid[8] ^ pipe2_vid[7]) |                 // P1 = F ^ V
     (pipe2_vid[2] ^ pipe2_vid[8] ^ pipe2_vid[7] ^ pipe2_vid[6]) |  // P0 = F ^ V ^ H
     ~pipe2_vid[9]);

assign xyz_err_4444 = 
    xyz &
    ((pipe2_vid[4] ^ pipe2_vid[8] ^ pipe2_vid[7] ^ pipe2_vid[6]) |  // P4 = F ^ V ^ H
     (pipe2_vid[3] ^ pipe2_vid[8] ^ pipe2_vid[7] ^ pipe2_vid[5]) |  // P3 = F ^ V ^ S
     (pipe2_vid[2] ^ pipe2_vid[7] ^ pipe2_vid[6] ^ pipe2_vid[5]) |  // P2 = V ^ H ^ S
     (pipe2_vid[1] ^ pipe2_vid[8] ^ pipe2_vid[6] ^ pipe2_vid[5]) |  // P1 = F ^ H ^ S
     ~pipe2_vid[9]);

//
// output reg
//
// The output register holds the the output video data and various flags.
// 
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
        begin
            out_reg_vid <= 0;
            out_reg_trs <= 1'b0;
            out_reg_eav <= 1'b0;
            out_reg_sav <= 1'b0;
            out_reg_anc <= 1'b0;
            out_reg_edh <= 1'b0;
            out_reg_xyz <= 1'b0;
            out_reg_xyz_err <= 1'b0;
            out_reg_xyz_err_4444 <= 1'b0;
            out_reg_f <= 0;
            out_reg_v <= 0;
            out_reg_h <= 0;
        end
        else
        begin
            out_reg_vid <= pipe2_vid;
            out_reg_trs <= trs;
            out_reg_eav <= eav;
            out_reg_sav <= sav;
            out_reg_anc <= anc;
            out_reg_edh <= anc & edh_in;
            out_reg_xyz <= xyz;
            out_reg_xyz_err <= xyz_err;
            out_reg_xyz_err_4444 <= xyz_err_4444;
            out_reg_f <= f;
            out_reg_v <= v;
            out_reg_h <= h;
        end
    end

//
// trs_delay register
//
// Used to assert the xyz signal when pipe2 contains the XYZ word of a TRS
// symbol.
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            trs_delay <= 2'b00;
        else
            trs_delay <= {trs_delay[0], out_reg_trs};
    end

//
// assign the outputs
//
assign vid_out = out_reg_vid;
assign rx_trs = out_reg_trs;
assign rx_eav = out_reg_eav;
assign rx_sav = out_reg_sav;
assign rx_anc = out_reg_anc;
assign rx_xyz = out_reg_xyz;
assign rx_xyz_err = out_reg_xyz_err;
assign rx_xyz_err_4444 = out_reg_xyz_err_4444;
assign rx_edh = out_reg_edh;
assign rx_f = out_reg_f;
assign rx_v = out_reg_v;
assign rx_h = out_reg_h;
            
endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------ 
/*
Module Description:

This module generates the EAV and SAV timing signals required at the input of 
the SDI transmitter module. Up to four video data streams may pass through the
module. These data streams are delayed by the appropriate amount to match the
latency of the TRS generation logic.
*/
`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_trsgen
(
    input  wire         clk,        // sample rate clock
    input  wire         ce,         // clock enable input
    input  wire         din_rdy,    // data ready
    input  wire [9:0]   video,      // connect to video data stream
    output wire         eav,        // 1 during XYZ word of EAV
    output wire         sav         // 1 during XYZ word of SAV     
);

// Internal signals
reg     [1:0]           ones_reg = 2'b00;
reg                     zeros_reg = 1'b0;
wire                    zeros_in;
reg                     trs = 1'b0;

always @ (posedge clk)
    if (ce & din_rdy)
        ones_reg <= {ones_reg[0], &video};

assign zeros_in = ~|video;

always @ (posedge clk)
    if (ce & din_rdy)
        zeros_reg <= zeros_in;

always @ (posedge clk)
    if (ce & din_rdy)
        trs <= ones_reg[1] & zeros_reg & zeros_in;

assign eav = trs & video[6];
assign sav = trs & ~video[6];

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/* 
This module instances and interconnects the three modules that make up the
digital video decoder: the TRS Detector, the Automatic Video Standard Detector,
and the Video Flywheel.

Together, these three modules will examine a video stream and determine the
format of the video from one of the six supported video standards. The flywheel
then synchronizes to the video stream to provide horizontal and vertical
counts so other modules can determine the location of data that occurs in
regular fixed locations, like the EDH packets. The flywheel will also 
regenerate TRS symbols and insert them into the video stream so that the video
contains valid TRS symbols even if the input video is noisy or stops 
altogether.

This module has the following inputs:

clk: clock input

ce: clock enable

rst: synchronous reset input

vid_in: input video stream

reacquire: forces the autodetect unit to reacquire the video standard

en_sync_switch: enables support for synchronous video switching

en_trs_blank: enable TRS blanking

The module has the following outputs:

std: 3-bit video standard code from the autodetect module

std_locked: asserted when std is valid

trs: asserted during the four words when vid_out contains the TRS symbol words

vid_out: output video stream

field: indicates the current video field

v_blank: vertical blanking interval indicator

h_blank: horizontal blanking interval indicator

horz_count: the horizontal position of the word present on vid_out

vert_count: the vertical position of the word present on vid_out

sync_switch: asserted during the synchronous switching interval

locked: asserted when the flywheel is synchronized with the input video stream

eav_next: asserted the clock cycle before the first word of an EAV appears on
vid_out

sav_next: asserted the clock sycle before the first word of an SAV appears on 
vid_out

xyz_word: asserted when vid_out contains the XYZ word of a TRS symbol

anc_next: asserted the clock cycle before the first word of the ADF of an ANC
packet appears on vid_out

edh_next: asserted the clock cycle before the first word of the ADF of an EDH
packet appears on vid_out
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8_video_decode #(
    parameter HCNT_WIDTH = 12,                      // number of bits in horizontal sample counter
    parameter VCNT_WIDTH = 10)                      // number of bits in vertical line counter
(
    input  wire                     clk,            // clock input
    input  wire                     ce,             // clock enable
    input  wire                     rst,            // sync reset input
    input  wire [9:0]               vid_in,         // input video
    input  wire                     reacquire,      // forces autodetect to reacquire the video standard
    input  wire                     en_sync_switch, // enables synchronous switching
    input  wire                     en_trs_blank,   // enables TRS blanking when asserted
    output wire [2:0]               std,            // video standard code
    output wire                     std_locked,     // autodetect ciruit is locked when this output is asserted
    output wire                     trs,            // asserted during flywheel generated TRS symbol
    output wire [9:0]               vid_out,        // TRS symbol data
    output wire                     field,          // field indicator
    output wire                     v_blank,        // vertical blanking bit
    output wire                     h_blank,        // horizontal blanking bit
    output wire [HCNT_WIDTH-1:0]    horz_count,     // current horizontal count
    output wire [VCNT_WIDTH-1:0]    vert_count,     // current vertical count
    output wire                     sync_switch,    // asserted on lines where synchronous switching is allowed
    output wire                     locked,         // asserted when flywheel is synchronized to video
    output wire                     eav_next,       // next word is first word of EAV
    output wire                     sav_next,       // next word is first word of SAV
    output wire                     xyz_word,       // current word is the XYZ word of a TRS
    output wire                     anc_next,       // next word is first word of a received ANC
    output wire                     edh_next        // next word is first word of a received EDH
);

localparam HCNT_MSB      = HCNT_WIDTH - 1;       // MS bit # of hcnt
localparam VCNT_MSB      = VCNT_WIDTH - 1;       // MS bit # of vcnt

//-----------------------------------------------------------------------------
// Signal definitions
//
wire                    td_xyz_err;         // trs_detect rx_xyz_err output
wire                    td_xyz_err_4444;    // trs_detect rx_xyz_err_4444 output
wire    [9:0]           td_vid;             // video stream from trs_detect
wire                    td_trs;             // trs_detect rx_trs output
wire                    td_xyz;             // trs_detect rx_xyz output
wire                    td_f;               // trs_detect rx_f output
wire                    td_v;               // trs_detect rx_v output
wire                    td_h;               // trs_detect rx_h output
wire                    td_anc;             // trs_detect rx_anc output
wire                    td_edh;             // trs_detect rx_edh output
wire                    td_eav;             // trs_detect rx_eav output
wire                    ad_s4444;           // autodetect s4444 output
wire                    ad_xyz_err;         // autodetect xyz_err output

//
// Instantiate the TRS detector module
//
v_smpte_sdi_v3_0_8_trs_detect TD (
    .clk                (clk),
    .ce                 (ce),
    .rst                (rst),
    .vid_in             (vid_in),
    .vid_out            (td_vid),
    .rx_trs             (td_trs),
    .rx_eav             (td_eav),
    .rx_sav             (),
    .rx_f               (td_f),
    .rx_v               (td_v),
    .rx_h               (td_h),
    .rx_xyz             (td_xyz),
    .rx_xyz_err         (td_xyz_err),
    .rx_xyz_err_4444    (td_xyz_err_4444),
    .rx_anc             (td_anc),
    .rx_edh             (td_edh)
);

//
// Instantiate the video standard autodetect module
//
v_smpte_sdi_v3_0_8_autodetect #(
    .HCNT_WIDTH      (HCNT_WIDTH))
AD (
    .clk                (clk),
    .ce                 (ce),
    .rst                (rst),
    .reacquire          (reacquire),
    .vid_in             (td_vid),
    .rx_trs             (td_trs),
    .rx_xyz             (td_xyz),
    .rx_xyz_err         (td_xyz_err),
    .rx_xyz_err_4444    (td_xyz_err_4444),
    .vid_std            (std),
    .locked             (std_locked),
    .xyz_err            (ad_xyz_err),
    .s4444              (ad_s4444)
);


//
// Instantiate the flywheel module
//
v_smpte_sdi_v3_0_8_flywheel #(
    .VCNT_WIDTH     (VCNT_WIDTH),
    .HCNT_WIDTH     (HCNT_WIDTH))
FLY (
    .clk            (clk),
    .ce             (ce),
    .rst            (rst),
    .rx_xyz_in      (td_xyz),
    .rx_trs_in      (td_trs),
    .rx_eav_first_in(td_eav),
    .rx_f_in        (td_f),
    .rx_v_in        (td_v),
    .rx_h_in        (td_h),
    .std_locked     (std_locked),
    .std_in         (std),
    .rx_xyz_err_in  (ad_xyz_err),
    .rx_vid_in      (td_vid),
    .rx_s4444_in    (ad_s4444),
    .rx_anc_in      (td_anc),
    .rx_edh_in      (td_edh),
    .en_sync_switch (en_sync_switch),
    .en_trs_blank   (en_trs_blank),
    .trs            (trs),
    .vid_out        (vid_out),
    .field          (field),
    .v_blank        (v_blank),
    .h_blank        (h_blank),
    .horz_count     (horz_count),
    .vert_count     (vert_count),
    .sync_switch    (sync_switch),
    .locked         (locked),
    .eav_next       (eav_next),
    .sav_next       (sav_next),
    .xyz_word       (xyz_word),
    .anc_next       (anc_next),
    .edh_next       (edh_next)
);

endmodule


// (c) Copyright 2002 - 2012 Xilinx, Inc. All rights reserved.
// 
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
// 
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
// 
// 
//------------------------------------------------------------------------------
/*
Module Description:

This is the top level SMPTE SDI combined RX & TX module.
*/

`timescale 1ns / 1 ps
(* DowngradeIPIdentifiedWarnings="yes" *)
module v_smpte_sdi_v3_0_8 #(
    parameter INCLUDE_RX_EDH_PROCESSOR = "TRUE",
    //From Coregen
    parameter  C_FAMILY = "virtex7"       // device family

    )
(
    
// RX signals
    input  wire                     rx_rst,             // sync reset for SDI RX pipeline
    input  wire                     rx_usrclk,          // rxusrclk input
    input  wire [19:0]              rx_data_in,         // input data for HD and 3G modes from transceiver
    input  wire [9:0]               rx_sd_data_in,      // input data for SD mode
    input  wire                     rx_sd_data_strobe,  // assert High when rx_sd_data_in is valid
    input  wire                     rx_frame_en,        // 1 = enable framer position update
    input  wire [2:0]               rx_mode_en,         // unary enable bits for SDI mode search {3G, SD, HD} 1=enable, 0=disable
    output wire [1:0]               rx_mode,            // 00=HD, 01=SD, 10=3G
    output wire                     rx_mode_hd,         // 1 = HD mode      
    output wire                     rx_mode_sd,         // 1 = SD mode
    output wire                     rx_mode_3g,         // 1 = 3G mode
    input  wire                     rx_mode_detect_en,  // 1 enables the autodetection of SDI mode
    output wire                     rx_mode_locked,     // auto mode detection locked
    input  wire [1:0]               rx_forced_mode,     // if rx_mode_detect_en is 0, these bits force the RX SDI mode, encoded the same as rx_mode
    input  wire                     rx_bit_rate,        // 0 = 1000/1000, 1 = 1000/1001
    output wire                     rx_t_locked,        // transport format detection locked
    output wire [3:0]               rx_t_family,        // transport format family
    output wire [3:0]               rx_t_rate,          // transport frame rate
    output wire                     rx_t_scan,          // transport scan: 0=interlaced, 1=progressive
    output wire                     rx_level_b_3g,      // 0 = level A, 1 = level B
    output wire                     rx_ce_sd,           // clock enable for SD, always 1 for HD & 3G
    output wire                     rx_nsp,             // framer new start position
    output wire [10:0]              rx_line_a,          // line number for HD & 3G (link A for level B)
    output wire [31:0]              rx_a_vpid,          // video payload ID packet ds1 for 3G or HD-SDI
    output wire                     rx_a_vpid_valid,    // 1 = a_vpid is valid
    output wire [31:0]              rx_b_vpid,          // video payload ID packet data from data stream 2
    output wire                     rx_b_vpid_valid,    // 1 = b_vpid is valid
    output wire                     rx_crc_err_a,       // CRC error for HD & 3G
    output wire [9:0]               rx_ds1a,            // SD=Y/C, HD=Y, 3GA=ds1, 3GB=Y link A
    output wire [9:0]               rx_ds2a,            // HD=C, 3GA=ds2, 3GB=C link A
    output wire                     rx_eav,             // 1 during XYZ word of EAV
    output wire                     rx_sav,             // 1 during XYZ word of SAV
    output wire                     rx_trs,             // 1 during all 4 words of EAV and SAV
    output wire [10:0]              rx_line_b,          // line number of 3G level B link B
    output wire                     rx_dout_rdy_3g,     // 1 for level A, asserted every other clk for level B
    output wire                     rx_crc_err_b,       // CRC error for ds2 (level B only)
    output wire [9:0]               rx_ds1b,            // 3G level B only = Y link B
    output wire [9:0]               rx_ds2b,            // 3G level B only = C link B
    input  wire [15:0]              rx_edh_errcnt_en,   // enables various error to increment rx_edh_errcnt
    input  wire                     rx_edh_clr_errcnt,  // clears rx_edh_errcnt
    output wire                     rx_edh_ap,          // 1 = AP CRC error detected previous field
    output wire                     rx_edh_ff,          // 1 = FF CRC error detected previous field
    output wire                     rx_edh_anc,         // 1 = ANC checksum error detected
    output wire [4:0]               rx_edh_ap_flags,    // EDH AP flags received in last EDH packet
    output wire [4:0]               rx_edh_ff_flags,    // EDH FF flags received in last EDH packet
    output wire [4:0]               rx_edh_anc_flags,   // EDH ANC flags received in last EDH packet
    output wire [3:0]               rx_edh_packet_flags,// EDH packet error condition flags
    output wire [15:0]              rx_edh_errcnt,      // EDH error counter

// TX signals
    input  wire                     tx_rst,             // sync reset for SDI TX pipeline
    input  wire                     tx_usrclk,          // clock input
    input  wire [2:0]               tx_ce,              // clock enable
    input  wire                     tx_din_rdy,         // input data ready for level B, must be 1 for all other modes
    input  wire [1:0]               tx_mode,            // 00 = HD, 01 = SD, 10 = 3G               7
    input  wire                     tx_level_b_3g,      // 0 = level A, 1 = level B
    input  wire                     tx_insert_crc,      // 1 = insert CRC for HD and 3G
    input  wire                     tx_insert_ln,       // 1 = insert LN for HD and 3G
    input  wire                     tx_insert_edh,      // 1 = generate & insert EDH for SD 
    input  wire                     tx_insert_vpid,     // 1 = enabled ST352 VPID packet insert
    input  wire                     tx_overwrite_vpid,  // 1 = overwrite existing VPID packets
    input  wire [9:0]               tx_video_a_y_in,    // SD in, HD & 3GA Y in, 3GB A Y in
    input  wire [9:0]               tx_video_a_c_in,    // HD & 3GA C in, 3GB A C in
    input  wire [9:0]               tx_video_b_y_in,    // 3GB only, B Y in
    input  wire [9:0]               tx_video_b_c_in,    // 3GB only, B C in
    input  wire [10:0]              tx_line_a,          // current line number for link A
    input  wire [10:0]              tx_line_b,          // current line number for link B
    input  wire [7:0]               tx_vpid_byte1,      // VPID byte 1
    input  wire [7:0]               tx_vpid_byte2,      // VPID byte 2
    input  wire [7:0]               tx_vpid_byte3,      // VPID byte 3
    input  wire [7:0]               tx_vpid_byte4a,     // VPID byte 4 for link A
    input  wire [7:0]               tx_vpid_byte4b,     // VPID byte 4 for link B
    input  wire [10:0]              tx_vpid_line_f1,    // VPID line for field 1
    input  wire [10:0]              tx_vpid_line_f2,    // VPID line for field 2
    input  wire                     tx_vpid_line_f2_en, // enable VPID insertion on line_f2
    output reg  [9:0]               tx_ds1a_out = 0,    // data stream 1, link A out
    output reg  [9:0]               tx_ds2a_out = 0,    // data stream 2, link A out
    output reg  [9:0]               tx_ds1b_out = 0,    // data stream 1, link B out
    output reg  [9:0]               tx_ds2b_out = 0,    // data stream 2, link B out
    input  wire                     tx_use_dsin,        // 0=tx the output of VPID inserter, 1=tx the input data streams
    input  wire [9:0]               tx_ds1a_in,         // SD Y/C, HD Y, 3G Y, dual-link A Y
    input  wire [9:0]               tx_ds2a_in,         // HD C, 3G C, dual-link A C
    input  wire [9:0]               tx_ds1b_in,         // dual-link B Y
    input  wire [9:0]               tx_ds2b_in,         // dual-link B C
    input  wire                     tx_sd_bitrep_bypass,// 1 bypasses the SD-SDI 11X bit replicator
    output wire [19:0]              tx_txdata,          // encoded data to SERDES TX
    output reg                      tx_ce_align_err=1'b0// 1 if ce 5/6/5/6 cadence is broken
);

//
// Local constants
//

//
// The following 3 parameters control the behavior of the SDI mode detector.
// ERRCNT_WIDTH controls the width of the counter used for the other two
// parameters. Thus, the default width of 4 is big enough to handle values of
// up to 15 in the other two parameters. MAX_ERRS_LOCKED specifies how many
// consecutive received lines with errors are allowed to occur before the RX
// determines that it is no longer locked to the SDI signal and begins looking
// for a new SDI mode. MAX_ERRS_UNLOCKED specifies the number of video line
// times to pause in each SDI mode during search for lock before moving on to the
// next SDI mode.
//
localparam ERRCNT_WIDTH  = 4;           // width of counter used for tracking locked & search mode errors
localparam MAX_ERRS_LOCKED = 15;        // max lines w/errors when locked (range: 1-15)
localparam MAX_ERRS_UNLOCKED = 2;       // max lines w/errors during mode search (range: 1-15)

localparam NUM_CE_SD = 1;
localparam EDH_ERR_WIDTH = 16;          // Number of bits in EDH error counter

//
// Local signals
//
wire [1:0]              tx_rst_int;
wire [1:0]              tx_out_mode;
wire                    tx_eav;
wire                    tx_sav;
wire                    tx_eav_mux;
wire                    tx_sav_mux;
wire                    tx_eav_int;
wire                    tx_sav_int;
wire [9:0]              tx_ds1a_mux;
wire [9:0]              tx_ds1b_mux;
wire [9:0]              tx_ds2a_mux;
wire [9:0]              tx_ds2b_mux;
wire [9:0]              tx_ds1a_int;
wire [9:0]              tx_ds1b_int;
wire [9:0]              tx_ds2a_int;
wire [9:0]              tx_ds2b_int;
reg  [9:0]              tx_ds1a_reg = 0;
reg  [9:0]              tx_ds1b_reg = 0;
reg  [9:0]              tx_ds2a_reg = 0;
reg  [9:0]              tx_ds2b_reg = 0;
wire                    tx_ce_alerr;

wire                    rx_rst_int;
wire [19:0]             rx_recclk_td;
wire [1:0]              rx_mode_int;
wire [1:0]              rx_mode_x;
reg  [1:0]              rx_forced_mode_reg = 2'b00;
reg                     rx_mode_detect_en_reg = 1'b0;
wire [NUM_CE_SD:0]      rx_ce_int;
wire [9:0]              rx_ds1a_int;
wire [4:0]              rx_ap_flags;
wire [4:0]              rx_ff_flags;
wire [4:0]              rx_anc_flags;
wire [19:0]             rx_data;
reg  [19:0]             rx_data_reg = 0;
reg  [9:0]              rx_sd_data_reg = 0;

//------------------------------------------------------------------------------
// SDI RX section
//

//
// Reset module
//
v_smpte_sdi_v3_0_8_triple_sdi_reset #(
    .NUM_OUTS       (1))
RSTMOD0 (
    .clk            (rx_usrclk),
    .rst_in         (rx_rst),
    .rst_out        (rx_rst_int));

//
// Input registers for the forced mode function
//
always @ (posedge rx_usrclk)
begin
    rx_forced_mode_reg <= rx_forced_mode;
    rx_mode_detect_en_reg <= rx_mode_detect_en;
end

//
// If the autodetect mode is enabled, the RX mode is determined by the SDI RX.
// If it is disabled, the rx_forced_mode inputs specify the RX mode to the core.
//
assign rx_mode_int = rx_mode_detect_en_reg ? rx_mode_x: rx_forced_mode_reg;

//
// Input registers for the data from the transceiver
//
always @ (posedge rx_usrclk)
    if (rx_ce_int[0])
    begin
        rx_data_reg <= rx_data_in;
    end

always @ (posedge rx_usrclk)
    if (rx_sd_data_strobe)
    begin
        rx_sd_data_reg <= rx_sd_data_in;
    end

//
// Depending on the RX mode, use either the SD-SDI input data or the 3G/HD-SDI
// input data.
//
assign rx_data = rx_mode_int == 2'b01 ? {10'b0, rx_sd_data_reg} : rx_data_reg;

//
// This is the SDI RX data path module.
//
v_smpte_sdi_v3_0_8_triple_sdi_rx #(
    .NUM_SD_CE          (NUM_CE_SD+1),
    .NUM_3G_DRDY        (1),
    .ERRCNT_WIDTH       (ERRCNT_WIDTH),
    .MAX_ERRS_LOCKED    (MAX_ERRS_LOCKED),
    .MAX_ERRS_UNLOCKED  (MAX_ERRS_UNLOCKED))
SDIRXTOP (
    .clk                (rx_usrclk),
    .rst                (rx_rst_int),
    .data_in            (rx_data),
    .sd_data_strobe     (rx_sd_data_strobe),
    .frame_en           (rx_frame_en),
    .bit_rate           (rx_bit_rate),
    .mode_enable        (rx_mode_en),
    .mode_detect_en     (rx_mode_detect_en_reg),
    .forced_mode        (rx_forced_mode_reg),
    .mode               (rx_mode_x),
    .mode_HD            (rx_mode_hd),
    .mode_SD            (rx_mode_sd),
    .mode_3G            (rx_mode_3g),
    .mode_locked        (rx_mode_locked),
    .t_locked           (rx_t_locked),
    .t_family           (rx_t_family),
    .t_rate             (rx_t_rate),
    .t_scan             (rx_t_scan),
    .level_b_3G         (rx_level_b_3g),
    .ce_sd              (rx_ce_int),
    .nsp                (rx_nsp),
    .ln_a               (rx_line_a),
    .a_vpid             (rx_a_vpid),
    .a_vpid_valid       (rx_a_vpid_valid),
    .b_vpid             (rx_b_vpid),
    .b_vpid_valid       (rx_b_vpid_valid),
    .crc_err_a          (rx_crc_err_a),
    .ds1a               (rx_ds1a_int),
    .ds2a               (rx_ds2a),
    .eav                (rx_eav),
    .sav                (rx_sav),
    .trs                (rx_trs),
    .ln_b               (rx_line_b),
    .dout_rdy_3G        (rx_dout_rdy_3g),
    .crc_err_b          (rx_crc_err_b),
    .ds1b               (rx_ds1b),
    .ds2b               (rx_ds2b));

assign rx_mode = rx_mode_int;
assign rx_ce_sd = rx_ce_int[1];
assign rx_ds1a = rx_ds1a_int;


//
// SD-SDI EDH processor
//
generate
    if (INCLUDE_RX_EDH_PROCESSOR == "TRUE")
    begin : INCLUDE_EDH
        v_smpte_sdi_v3_0_8_edh_processor #(
            .ERROR_COUNT_WIDTH  (EDH_ERR_WIDTH))
        EDH (
            .clk                (rx_usrclk),
            .ce                 (rx_ce_int[0]),
            .rst                (rx_rst_int),
            .vid_in             (rx_ds1a_int),
            .reacquire          (1'b0),
            .en_sync_switch     (1'b1),
            .en_trs_blank       (1'b0),
            .anc_idh_local      (1'b0),
            .anc_ues_local      (1'b0),
            .ap_idh_local       (1'b0),
            .ff_idh_local       (1'b0),
            .errcnt_flg_en      (rx_edh_errcnt_en),
            .clr_errcnt         (rx_edh_clr_errcnt),
            .receive_mode       (1'b1),                   
            .vid_out            (),
            .std                (),
            .std_locked         (),
            .trs                (),
            .field              (),
            .v_blank            (),
            .h_blank            (),
            .horz_count         (),
            .vert_count         (),
            .sync_switch        (),
            .locked             (),
            .eav_next           (),
            .sav_next           (),
            .xyz_word           (),
            .anc_next           (),
            .edh_next           (),
            .rx_ap_flags        (rx_edh_ap_flags),
            .rx_ff_flags        (rx_edh_ff_flags),
            .rx_anc_flags       (rx_edh_anc_flags),
            .ap_flags           (rx_ap_flags),
            .ff_flags           (rx_ff_flags),
            .anc_flags          (rx_anc_flags),
            .packet_flags       (rx_edh_packet_flags),
            .errcnt             (rx_edh_errcnt),
            .edh_packet         ());

        assign rx_edh_ap = rx_ap_flags[0];
        assign rx_edh_ff = rx_ff_flags[0];
        assign rx_edh_anc = rx_anc_flags[0];
    end
    else
    begin : NO_EDH
        assign rx_edh_ap_flags = 0;
        assign rx_edh_ff_flags = 0;
        assign rx_edh_anc_flags = 0;
        assign rx_edh_packet_flags = 0;
        assign rx_edh_ap = 1'b0;
        assign rx_edh_ff = 1'b0;
        assign rx_edh_anc = 1'b0;
        assign rx_edh_errcnt = 0;
    end
endgenerate

//------------------------------------------------------------------------------
// SDI TX section
//

//
// Reset module
//
v_smpte_sdi_v3_0_8_triple_sdi_reset #(
    .NUM_OUTS       (2))
RSTMOD1 (
    .clk            (tx_usrclk),
    .rst_in         (tx_rst),
    .rst_out        (tx_rst_int));

//
// SMPTE 352 video payload ID packet insertion
//
v_smpte_sdi_v3_0_8_triple_sdi_vpid_insert VPIDINS (
    .clk            (tx_usrclk),
    .ce             (tx_ce[0]),
    .din_rdy        (tx_din_rdy),
    .rst            (tx_rst_int[0]),
    .sdi_mode       (tx_mode),
    .level          (tx_level_b_3g),
    .enable         (tx_insert_vpid),
    .overwrite      (tx_overwrite_vpid),
    .byte1          (tx_vpid_byte1),
    .byte2          (tx_vpid_byte2),
    .byte3          (tx_vpid_byte3),
    .byte4a         (tx_vpid_byte4a),
    .byte4b         (tx_vpid_byte4b),
    .ln_a           (tx_line_a),
    .ln_b           (tx_line_b),
    .line_f1        (tx_vpid_line_f1),
    .line_f2        (tx_vpid_line_f2),
    .line_f2_en     (tx_vpid_line_f2_en),
    .a_y_in         (tx_video_a_y_in),
    .a_c_in         (tx_video_a_c_in),
    .b_y_in         (tx_video_b_y_in),
    .b_c_in         (tx_video_b_c_in),
    .ds1a_out       (tx_ds1a_int),
    .ds2a_out       (tx_ds2a_int),
    .ds1b_out       (tx_ds1b_int),
    .ds2b_out       (tx_ds2b_int),
    .eav_out        (tx_eav_int),
    .sav_out        (tx_sav_int),
    .out_mode       (tx_out_mode));
  
//
// IO registers for video streams
//  
always @ (posedge tx_usrclk)
    if (tx_ce[0] & tx_din_rdy)
    begin
        tx_ds1a_out <= tx_ds1a_int;
        tx_ds2a_out <= tx_ds2a_int;
        tx_ds1b_out <= tx_ds1b_int;
        tx_ds2b_out <= tx_ds2b_int;
    end

always @ (posedge tx_usrclk)
    if (tx_ce[0] & tx_din_rdy)
    begin
        tx_ds1a_reg <= tx_ds1a_in;
        tx_ds2a_reg <= tx_ds2a_in;
        tx_ds1b_reg <= tx_ds1b_in;
        tx_ds2b_reg <= tx_ds2b_in;
    end

//
// This module generates the eav and sav timing signals from the input data streams.
//
v_smpte_sdi_v3_0_8_trsgen TRSG (
    .clk            (tx_usrclk),
    .ce             (tx_ce[0]),
    .din_rdy        (tx_din_rdy),
    .video          (tx_ds1a_reg),
    .eav            (tx_eav),
    .sav            (tx_sav));

//
// This mux selects the internal data stream and timing signals when tx_use_dsin=0
// or the input data streams and timing signals generates by the trsgen module
// when tx_use_dsin=1.
//

assign tx_eav_mux  = tx_use_dsin ? tx_eav : tx_eav_int;
assign tx_sav_mux  = tx_use_dsin ? tx_sav : tx_sav_int;
assign tx_ds1a_mux = tx_use_dsin ? tx_ds1a_reg : tx_ds1a_int;
assign tx_ds2a_mux = tx_use_dsin ? tx_ds2a_reg : tx_ds2a_int;
assign tx_ds1b_mux = tx_use_dsin ? tx_ds1b_reg : tx_ds1b_int;
assign tx_ds2b_mux = tx_use_dsin ? tx_ds2b_reg : tx_ds2b_int;

//
// SDI TX output module
//
v_smpte_sdi_v3_0_8_triple_sdi_tx_output TXOUT (
    .clk                (tx_usrclk),
    .din_rdy            (tx_din_rdy),
    .ce                 (tx_ce[2:1]),
    .rst                (tx_rst_int[1]),
    .mode               (tx_out_mode),
    .ds1a               (tx_ds1a_mux),
    .ds2a               (tx_ds2a_mux),
    .ds1b               (tx_ds1b_mux),
    .ds2b               (tx_ds2b_mux),
    .insert_crc         (tx_insert_crc),
    .insert_ln          (tx_insert_ln),
    .insert_edh         (tx_insert_edh),
    .ln_a               (tx_line_a),
    .ln_b               (tx_line_b),
    .eav                (tx_eav_mux),
    .sav                (tx_sav_mux),
    .sd_bitrep_bypass   (tx_sd_bitrep_bypass),
    .txdata             (tx_txdata),
    .ce_align_err       (tx_ce_alerr));
    
always @ (posedge tx_usrclk)
    tx_ce_align_err <= tx_ce_alerr;

endmodule





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

`timescale 1ns / 1ps
`define INCLUDE_RX_EDH_PROCESSOR TRUE

module tb_smpte_sdi;

  reg clk;
  reg [10:0] sd_tx_ce_gen;
  reg level_b_ce;
  wire tx_ce;
  wire [1:0] mode;
  wire level;
  reg vidgen_ce;
  wire tx_din_rdy;
  wire eav;
  reg [13:0] hanc_check;
  reg [31:0] tx_vpid_data=0;
  reg [7:0]  tx_vpid_data_b4=0;
  reg [5:0]  count;
  reg rx_bit_rate;
  integer errs;
  wire locked;
  wire rx_mode_locked;
  wire [3:0]  family;
  wire [3:0]  rate;
  wire        scan;
  wire rst;
  wire sav;
  wire bit_rate;
  wire [10:0] line;
  wire [10:0] first_active;
  wire [13:0] active_samples;
  wire [13:0] total_samples;
  wire [9:0] y, c;
  wire [19:0] tx_out;
  wire [1:0] rx_mode;
  wire rx_mode_HD, rx_mode_SD, rx_mode_3G;
  wire               rx_level;
  wire               rx_ce;
  wire [10:0]            rx_ln_a, rx_ln_b;
  wire [9:0]          rx_ds1a, rx_ds2a, rx_ds1b, rx_ds2b;
  wire               rx_eav, rx_sav, rx_trs;
  wire               rx_dout_rdy_3G;
  wire               rx_crc_a, rx_crc_b;
  wire [31:0]      rx_a_vpid, rx_b_vpid;
  wire               rx_a_vpid_valid, rx_b_vpid_valid;


parameter DLY = 10; // Delay to account for global clock routing in post-PAR timing sim


  initial
  begin
    clk <= 1'h0;
    sd_tx_ce_gen <= 11'b00000100001;
    level_b_ce <= 1'b1;
    hanc_check <= 14'h0;
    tx_vpid_data <= 32'h0;
    tx_vpid_data_b4 <= 8'h0;
    count <= 6'h0;
    rx_bit_rate <= 1'b1;
    errs <= 32'h0;
  end

//  
// 148.5 MHz clock generator -- slowed down toe 14.85 MHz for post-PAR timing sim
//

  always
  begin
    #33.7 clk <= ~clk;
  end

//      
// 27 MHz TX clock enable generator
//
always @ (posedge clk)
begin
    # DLY sd_tx_ce_gen <= {sd_tx_ce_gen[9:0], sd_tx_ce_gen[10]};
end

always @ (posedge clk)
begin
    level_b_ce <= # DLY ~level_b_ce;
end

assign tx_ce = 1'b1; //(mode == 2'b01) ? sd_tx_ce_gen : 1'b1;	// JFS: Run SD-SDI in non-oversampled mode

always @ (*)
/*    if (mode == 2'b01)		// JFS: Run SD-SDI mode in non-oversampled mode
        vidgen_ce <= sd_tx_ce_gen;*/
    if (mode == 2'b10 && level)
        vidgen_ce <= level_b_ce;
    else
        vidgen_ce <= 1'b1;

assign tx_din_rdy =  (mode == 2'b10 && level) ? level_b_ce : 1'b1;

always @ (posedge clk)
    if (tx_ce & tx_din_rdy)
    begin
        if (eav)
            hanc_check <= 0;
        else
            hanc_check <= hanc_check + 1;
    end

//
// Generated VPID data
//
// Note that this doesn't generate real VPID values, just ones that can be tested.
//
always @ (posedge clk)
begin
    if (vidgen_ce)
    begin
        if (mode == 2'b01)                      // SD-SDI
        begin   
            # DLY tx_vpid_data <= 32'h81060001;
            # DLY tx_vpid_data_b4 <= 8'h01;
        end
        else if (mode == 2'b00)                 // HD-SDI
        begin
            # DLY tx_vpid_data <= 32'h84460001;
            # DLY tx_vpid_data_b4 <= 8'h01;
        end
        else if (mode == 2'b10 && ~level)
        begin
            # DLY tx_vpid_data <= 32'h89060802;
            # DLY tx_vpid_data_b4 <= 8'h02;
        end
        else
        begin
            # DLY tx_vpid_data <= 32'h8A210141;
            # DLY tx_vpid_data_b4 <= 8'h81;
        end
    end
end

  always@(negedge locked)
  begin
    wait(50) @(posedge clk);
    if(count < 4)
    begin
      rx_bit_rate = ~rx_bit_rate;
    end
    else
    begin
      rx_bit_rate = rx_bit_rate;
    end
    count=count+1;
  end

//
// This module generates the video timing based on the parameters specified
// by the test program.
//
video_gen_simulation_rxtx #(
    .DLY                (DLY))
VID (
    .clk                (clk),
    .rst                (rst),
    .ce                 (vidgen_ce),
    .mode               (mode),
    .rx_mode            (rx_mode),
    .first_active       (first_active),
    .active_samples     (active_samples),
    .total_samples      (total_samples),
    .line               (line),
    .eav                (eav),
    .sav                (sav),
    .y                  (y),
    .c                  (c));


check_data_rxtx DCHK (
    .clk                (clk),
    .ce                 (rx_ce),
    .dout_rdy           (rx_dout_rdy_3G),
    .rst                (rst),
    .mode_locked        (rx_mode_locked),
    .mode               (rx_mode),
    .level              (rx_level),
    .sav                (rx_sav),
    .eav                (rx_eav),
    .trs                (rx_trs),
    .ds1a               (rx_ds1a),
    .ds2a               (rx_ds2a),
    .ds1b               (rx_ds1b),
    .ds2b               (rx_ds2b),
    .line               (line),
    .ln_a               (rx_ln_a),
    .ln_b               (rx_ln_b),
    .crc_a              (rx_crc_a),
    .crc_b              (rx_crc_b),
    .t_locked           (locked),
    .a_vpid             ({rx_a_vpid[7:0], rx_a_vpid[15:8], rx_a_vpid[23:16], rx_a_vpid[31:24]}),
    .a_vpid_valid       (rx_a_vpid_valid),
    .b_vpid             ({rx_b_vpid[7:0], rx_b_vpid[15:8], rx_b_vpid[23:16], rx_b_vpid[31:24]}),
    .b_vpid_valid       (rx_b_vpid_valid),
    .first_active       (first_active),
    .total_samples      (total_samples),
    .active_samples     (active_samples));

// 
// Test program : This program controls the operation of the test bench.
//

test_rxtx #(
    .DLY                (DLY))
T1 (
    .clk                (clk),
    .sav                (sav),
    .rst                (rst),
    .line               (line),
    .first_active       (first_active),
    .total_samples      (total_samples),
    .active_samples     (active_samples),
    .bit_rate           (bit_rate),
    .mode               (mode),
    .level              (level));


   // SMPTE SDI DUT INSTANTIATION
    // -----------------------------
  // uut INSTANCE
  smpte_sdi uut 
   (
   // RX signals
    .rx_rst		(rst),             // sync reset for SDI RX pipeline
    .rx_usrclk		(clk),          // rxusrclk input
    .rx_data_in		(tx_out),         // input data for HD and 3G modes from transceiver  JJ Added
    .rx_sd_data_in	(tx_out[19:10]),      // input data for SD mode JFS: Modified
    .rx_sd_data_strobe	(1'b1),  // assert High when rx_sd_data_in is valid JJ Added JFS: Modified
    .rx_frame_en	(1'b1),        // 1 = enable framer position update
    .rx_mode_en		(3'b111),         // unary enable bits for SDI mode search {3G, SD, HD} 1=enable, 0=disable
    .rx_mode		(rx_mode),            // 00=HD, 01=SD, 10=3G
    .rx_mode_hd		(rx_mode_HD),         // 1 = HD mode      
    .rx_mode_sd		(rx_mode_SD),         // 1 = SD mode
    .rx_mode_3g		(rx_mode_3G),         // 1 = 3G mode
    .rx_mode_detect_en	(1'b1),  // 1 enables the autodetection of SDI mode JJ Added
    .rx_mode_locked	(rx_mode_locked),     // auto mode detection locked
    .rx_forced_mode	(),     // if rx_mode_detect_en is 0, these bits force the RX SDI mode, encoded the same as rx_mode
    .rx_bit_rate	(rx_bit_rate),        // 0 = 1000/1000, 1 = 1000/1001    JJ Added
    .rx_t_locked	(locked),        // transport format detection locked
    .rx_t_family	(family),        // transport format family
    .rx_t_rate		(rate),          // transport frame rate
    .rx_t_scan		(scan),          // transport scan: 0=interlaced, 1=progressive
    .rx_level_b_3g	(rx_level),      // 0 = level A, 1 = level B
    .rx_ce_sd		(rx_ce),           // clock enable for SD, always 1 for HD & 3G
    .rx_nsp		(),             // framer new start position
    .rx_line_a		(rx_ln_a),          // line number for HD & 3G (link A for level B)
    .rx_a_vpid		(rx_a_vpid),          // video payload ID packet ds1 for 3G or HD-SDI
    .rx_a_vpid_valid	(rx_a_vpid_valid),    // 1 = a_vpid is valid
    .rx_b_vpid		(rx_b_vpid),          // video payload ID packet data from data stream 2
    .rx_b_vpid_valid	(rx_b_vpid_valid),    // 1 = b_vpid is valid
    .rx_crc_err_a	(rx_crc_a),       // CRC error for HD & 3G
    .rx_ds1a		(rx_ds1a),            // SD=Y/C, HD=Y, 3GA=ds1, 3GB=Y link A
    .rx_ds2a		(rx_ds2a),            // HD=C, 3GA=ds2, 3GB=C link A
    .rx_eav		(rx_eav),             // 1 during XYZ word of EAV
    .rx_sav		(rx_sav),             // 1 during XYZ word of SAV
    .rx_trs		(rx_trs),             // 1 during all 4 words of EAV and SAV
    .rx_line_b		(rx_ln_b),          // line number of 3G level B link B
    .rx_dout_rdy_3g	(rx_dout_rdy_3G),     // 1 for level A, asserted every other clk for level B
    .rx_crc_err_b	(rx_crc_b),       // CRC error for ds2 (level B only)
    .rx_ds1b		(rx_ds1b),            // 3G level B only = Y link B
    .rx_ds2b		(rx_ds2b),            // 3G level B only = C link B
    //.rx_edh_errcnt_en	(16'b0),   // enables various error to increment rx_edh_errcnt
    //.rx_edh_clr_errcnt	(1'b0),  // clears rx_edh_errcnt
    //.rx_edh_ap		(),          // 1 = AP CRC error detected previous field
    //.rx_edh_ff		(),          // 1 = FF CRC error detected previous field
    //.rx_edh_anc		(),         // 1 = ANC checksum error detected
    //.rx_edh_ap_flags	(),    // EDH AP flags received in last EDH packet
    //.rx_edh_ff_flags	(),    // EDH FF flags received in last EDH packet
    //.rx_edh_anc_flags	(),   // EDH ANC flags received in last EDH packet
    //.rx_edh_packet_flags(),// EDH packet error condition flags
    //.rx_edh_errcnt	(),      // EDH error counter

    // TX signals
    .tx_rst		(rst),             // sync reset for SDI TX pipeline
    .tx_usrclk		(clk),          // clock input
    .tx_ce		({3{tx_ce}}),              // clock enable
    .tx_din_rdy		(tx_din_rdy),         // input data ready for level B, must be 1 for all other modes
    .tx_mode		(mode),            // 00 = HD, 01 = SD, 10 = 3G               7
    .tx_level_b_3g	(level),      // 0 = level A, 1 = level B
    .tx_insert_crc	(1'b1),      // 1 = insert CRC for HD and 3G
    .tx_insert_ln	(1'b1),       // 1 = insert LN for HD and 3G
    .tx_insert_edh	(1'b0),      // 1 = generate & insert EDH for SD 
    .tx_insert_vpid	(1'b1),     // 1 = enabled ST352 VPID packet insert
    .tx_overwrite_vpid	(1'b1),  // 1 = overwrite existing VPID packets
    .tx_video_a_y_in	(y),    // SD in, HD & 3GA Y in, 3GB A Y in
    .tx_video_a_c_in	(c),    // HD & 3GA C in, 3GB A C in
    .tx_video_b_y_in	(y),    // 3GB only, B Y in
    .tx_video_b_c_in	(c),    // 3GB only, B C in
    .tx_line_a		(line),          // current line number for link A
    .tx_line_b		(line),          // current line number for link B
    .tx_vpid_byte1	(tx_vpid_data[31:24]),      // VPID byte 1
    .tx_vpid_byte2	(tx_vpid_data[23:16]),      // VPID byte 2
    .tx_vpid_byte3	(tx_vpid_data[15:8]),      // VPID byte 3
    .tx_vpid_byte4a	(tx_vpid_data[7:0]),     // VPID byte 4 for link A
    .tx_vpid_byte4b	(tx_vpid_data_b4),     // VPID byte 4 for link B
    .tx_vpid_line_f1	(first_active - 11'd1),    // VPID line for field 1
    .tx_vpid_line_f2	(11'd0),    // VPID line for field 2
    .tx_vpid_line_f2_en	(1'b0), // enable VPID insertion on line_f2
    .tx_ds1a_out 	(),    // data stream 1, link A out
    .tx_ds2a_out 	(),    // data stream 2, link A out
    .tx_ds1b_out 	(),    // data stream 1, link B out
    .tx_ds2b_out 	(),    // data stream 2, link B out
    .tx_use_dsin	(1'b0),        // 0=tx the output of VPID inserter, 1=tx the input data streams
    .tx_ds1a_in		(10'b0),         // SD Y/C, HD Y, 3G Y, dual-link A Y
    .tx_ds2a_in		(10'b0),         // HD C, 3G C, dual-link A C
    .tx_ds1b_in		(10'b0),         // dual-link B Y
    .tx_ds2b_in		(10'b0),         // dual-link B C
    .tx_sd_bitrep_bypass(1'b1),// 1 bypasses the SD-SDI 11X bit replicator JJ Added JFS: Run SD-SDI in non-oversampled mode
    .tx_txdata		(tx_out),          // encoded data to SERDES TX JJ Added
    .tx_ce_align_err    () // 1 if ce 5/6/5/6 cadence is broken
);



endmodule 

//------------------------------------------------------------------------------
// This module simulates the generation of the video timing signals. It
// generates the eav and sav timing signals. It generates the line number.
// And, it generates a data bit corresponding to the V bit of the XYZ word
// of the EAV and SAV.
//
module video_gen_simulation_rxtx (
    input   wire           clk,
    input   wire           rst,
    input   wire           ce,
    input   wire [1:0]     mode,
    input   wire [1:0]     rx_mode,
    input   wire [10:0]    first_active,
    input   wire [13:0]    active_samples,
    input   wire [13:0]    total_samples,
    output  reg [10:0]     line,
    output  wire            eav,
    output  wire            sav,
    output  reg [9:0]      y,
    output  reg [9:0]      c);

parameter DLY = 10;


reg [13:0]  sample;
wire [9:0]  xyz;
wire        h;
reg         v;
integer           seed;

initial
begin
  v <= 0;
  seed <=32'd10;
end
//
// Sample counter
//
// Cleared to 0 on reset. Rolls over when it reaches total_samples-1. Otherwise
// increments every clock cycle.
//  
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            # DLY sample <= 0;
        else
        begin
            if (sample == total_samples-1)
                # DLY sample <= 0;
            else
                # DLY sample <= sample + 1;
        end
    end
//
// Line counter
//
// Set to line 1 on reset. Increments at actives_samples + 6. This is the point 
// in the video where the line number will have been captured by an SDI receiver.
//
always @ (posedge clk)
    if (ce)
    begin
        if (rst)
            line <= # DLY first_active - 15;
        else if (&line)
            begin
                $display ("Line counter reached maximum value. Test error.");
                $stop;
            end
        else if (sample == active_samples+6)
            line <= # DLY line + 1;
    end

//
// Generate the eav and sav timing signals at the appropriate place on each line
// by examining the sample counter.
//
assign eav = (sample == active_samples+3);
assign sav = (sample == total_samples-1);

//
// Generate the video outputs. Video is always black level video except at the
// EAV and SAV where actual EAV and SAV sequences are generated. If the RX mode
// doesn't match the TX mode, then random stuff on the Y and C ports to
// simulate that the GTX isn't locked to the right bit rate.
// 
always @ (posedge clk)
    if (ce & (sample == active_samples))
        v <= # DLY line < first_active-1;

assign h = (sample < active_samples+6);
assign xyz = {2'b10, v, h, v ^ h, h, v, v ^ h, 2'b00};

always @ (*)
    if (rx_mode != mode)
    begin
      y <= $dist_uniform (seed,32'd4,32'd1019);
      c <= $dist_uniform (seed,32'd4,32'd1019);
    end
    else
    begin
        if ((active_samples == sample) || (sample == total_samples-4))
        begin
            y <= 10'h3ff;
            c <= 10'h3ff;
        end
        else if ((active_samples+1 == sample) || (active_samples+2 == sample) || (sample == total_samples-2) || (sample == total_samples-3))
        begin
            y <= 10'h000;
            c <= 10'h000;
        end
        else if ((active_samples+3 == sample) || (sample == total_samples-1))
        begin
            y <= xyz;
            c <= xyz;
        end
        else if (mode == 2'b01)
        begin
            c <= 10'h000;
            if (~sample[0])
                y <= 10'h200;
            else
                y <= 10'h040;
        end
        else
        begin
            y <= 10'h200;
            c <= 10'h040;
        end
    end
endmodule


//------------------------------------------------------------------------------
// This module checks the data and timing signals from the RX module to determine
// if they are correct.
//
module check_data_rxtx (
    input wire             clk,
    input wire             ce,
    input wire             dout_rdy,
    input wire             rst,
    input wire             mode_locked,
    input wire [1:0]         mode,
    input wire             level,
    input wire             sav,
    input wire             eav,
    input wire             trs,
    input wire [9:0]        ds1a,
    input wire [9:0]        ds2a,
    input wire [9:0]        ds1b,
    input wire [9:0]        ds2b,
    input wire [10:0]       line,
    input wire [10:0]       ln_a,
    input wire [10:0]       ln_b,  
    input wire             crc_a,
    input wire             crc_b,
    input wire             t_locked,
    input wire [31:0]      a_vpid,
    input wire             a_vpid_valid,
    input wire [31:0]      b_vpid,
    input wire             b_vpid_valid,
    input wire [10:0]      first_active,
    input wire [13:0]        total_samples,
    input wire [13:0]        active_samples);

reg [13:0]      sample ;
wire [9:0]      xyz;
reg             test;
wire            h;
reg             v;
wire           mode_3GB;
wire           dly_ce;

initial
begin
  test <= 1'b0;
  sample <= 14'b0;
end

assign #1 dly_ce = dout_rdy & ce;

assign mode_3GB = (mode == 2'b10) && level;


//
// This forever loop turns off testing on reset, then re-enables after the first
// SAV following the assertion of mode_locked by the SDI RX.
//
initial forever
begin
    @ (posedge rst);
    test <= 1'b0;
    @ (negedge rst);
    @ (posedge mode_locked);
    @ (posedge sav);
    repeat (2) @ (posedge clk & dly_ce);
    #1 test <= 1'b1;
end

//
// This is a sample counter that keeps track of the sample count on each line.
//
always @ (posedge clk)
    if (ce & dout_rdy)
    begin
        if (sav)
            sample <= 0;
        else
            sample <= sample + 1;
    end


//
// Generate V and H bits in order to generate the XYZ word of the EAV and SAV.
//
always @ (posedge clk)
begin
    if (ce & dout_rdy & (sample == active_samples))
        v <= line < first_active;
end

assign h = (sample <= active_samples + 6);
assign xyz = {2'b10, v, h, v ^ h, h, v, v ^ h, 2'b00};


endmodule


//------------------------------------------------------------------------------
// Test program
//
// This is the main test program that controls the simulation.
//
module test_rxtx (
    input   wire           clk,
    input   wire           sav,
    output  reg           rst ,
    input   wire [10:0]        line,
    output  reg           bit_rate,
    output  reg [10:0]        first_active,
    output  reg [13:0]      total_samples,
    output  reg [13:0]      active_samples,
    output  reg [1:0]       mode,
    output  reg           level);

parameter DLY = 10;

localparam [1:0]
    MODE_HD = 2'b00,
    MODE_SD = 2'b01,
    MODE_3G = 2'b10;
    
localparam
    LEVEL_A = 1'b0,
    LEVEL_B = 1'b1;
    
localparam [3:0]
    FAM_1920_1080       = 4'b0000,
    FAM_1280_720        = 4'b0001,
    FAM_2048_1080       = 4'b0010,
    FAM_ST295           = 4'b0011,
    FAM_NTSC            = 4'b1000,
    FAM_PAL             = 4'b1001,
    FAM_UNKNOWN         = 4'b1111;

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

integer errors ;     // total error counter
integer tested ;     // formats tested counter
integer err ;

//
// This typedef defines the format of the record struct. Each record struct
// contains the parameter and expected results data for one video format.
//
//typedef struct packed {
//    line_num    first_active; 51:41
//    sample_num  active_samples; 40:27
//    sample_num  total_samples; 26:13
//    mode_type   mode;        12:11
//    bit         level;       10
//    bit         bit_rate;    9
//    nibble      exp_family;  8:5 
//    nibble      exp_rate;    4:1
//    bit         exp_scan; -- 0
//} record;

reg [51:0] record[0:9];

//
// This is an array of record structs that contain the information about each
// video format.
//

//record  rec_array [] ='{
////               video format specifications           ||           expected values
////  1st act  act samps tot samps  mode     level  brate     family        trans rate    p/i
//    {11'd21, 14'd1920, 14'd2200, MODE_HD, LEVEL_A, 1'b0, FAM_1920_1080, SMPTE_RATE_30,  1'b0},  //  0 HD:  1080 I 60
//    {11'd26, 14'd1280, 14'd1650, MODE_HD, LEVEL_A, 1'b1, FAM_1280_720,  SMPTE_RATE_60M, 1'b1},  // 11 HD:  720 P 60/M
//    {11'd21, 14'd2048, 14'd2640, MODE_HD, LEVEL_A, 1'b0, FAM_2048_1080, SMPTE_RATE_25,  1'b0},  // 25 HD:  2Kx1080 PsF 25
//    {11'd42, 14'd1920, 14'd2640, MODE_3G, LEVEL_A, 1'b0, FAM_1920_1080, SMPTE_RATE_50,  1'b1},  // 31 3GA: 1080 P 50
//    {11'd26, 14'd2560, 14'd8250, MODE_3G, LEVEL_A, 1'b1, FAM_1280_720,  SMPTE_RATE_24M, 1'b1},  // 47 3GA: 720 P 24/M
//    {11'd42, 14'd2048, 14'd2200, MODE_3G, LEVEL_A, 1'b1, FAM_2048_1080, SMPTE_RATE_60M, 1'b1},  // 49 3GA: 2Kx1080 P 60/M
//    {11'd21, 14'd1920, 14'd2200, MODE_3G, LEVEL_B, 1'b1, FAM_1920_1080, SMPTE_RATE_30M, 1'b0},  // 64 3GB: 1080 P 60/M & I 60/M
//    {11'd21, 14'd1920, 14'd2640, MODE_3G, LEVEL_B, 1'b0, FAM_1920_1080, SMPTE_RATE_25,  1'b0},  // 65 3GB: 1080 P 50 & I 50
//    {11'd21, 14'd2048, 14'd2750, MODE_3G, LEVEL_B, 1'b1, FAM_2048_1080, SMPTE_RATE_24M, 1'b0},  // 82 3GB: 2Kx1080 P 60 & PsF 24/M
//    {11'd20, 14'd1440, 14'd1716, MODE_SD, LEVEL_A, 1'b0, FAM_NTSC,      SMPTE_RATE_30M, 1'b0}   // 83 SD:  NTSC
////    {11'd23, 14'd1440, 14'd1728, MODE_SD, LEVEL_A, 1'b0, FAM_PAL,       SMPTE_RATE_25,  1'b0}   // 84 SD:  PAL
//};

initial
begin
rst = 1'b0;
errors = 32'h0;     // total error counter
tested = 32'h0;     // formats tested counter
err = 32'h0;
end


initial
begin
record[0] = {11'd21, 14'd1920, 14'd2200, MODE_HD, LEVEL_A, 1'b0, FAM_1920_1080, SMPTE_RATE_30,  1'b0};
record[1] = {11'd26, 14'd1280, 14'd1650, MODE_HD, LEVEL_A, 1'b1, FAM_1280_720,  SMPTE_RATE_60M, 1'b1};
record[2] = {11'd21, 14'd2048, 14'd2640, MODE_HD, LEVEL_A, 1'b0, FAM_2048_1080, SMPTE_RATE_25,  1'b0};
record[3] = {11'd42, 14'd1920, 14'd2640, MODE_3G, LEVEL_A, 1'b0, FAM_1920_1080, SMPTE_RATE_50,  1'b1};
record[4] = {11'd26, 14'd2560, 14'd8250, MODE_3G, LEVEL_A, 1'b1, FAM_1280_720,  SMPTE_RATE_24M, 1'b1};
record[5] = {11'd42, 14'd2048, 14'd2200, MODE_3G, LEVEL_A, 1'b1, FAM_2048_1080, SMPTE_RATE_60M, 1'b1};
record[6] = {11'd21, 14'd1920, 14'd2200, MODE_3G, LEVEL_B, 1'b1, FAM_1920_1080, SMPTE_RATE_30M, 1'b0};
record[7] = {11'd21, 14'd1920, 14'd2640, MODE_3G, LEVEL_B, 1'b0, FAM_1920_1080, SMPTE_RATE_25,  1'b0};
record[8] = {11'd21, 14'd2048, 14'd2750, MODE_3G, LEVEL_B, 1'b1, FAM_2048_1080, SMPTE_RATE_24M, 1'b0};
record[9] = {11'd20, 14'd1440, 14'd1716, MODE_SD, LEVEL_A, 1'b0, FAM_NTSC,      SMPTE_RATE_30M, 1'b0};
end

//function reg[50*8:0] get_format_str ;
function get_format_str ;
    input reg [3:0]  family;
    input reg [3:0]  rate;
    input reg   scan;

//string fam_str, rate_str, scan_str;

reg[8*15:0] fam_str;
reg[8*15:0] rate_str;
reg[8*15:0] scan_str;
begin
    case(family)
        4'b0000: fam_str = "1920x1080";
        4'b0001: fam_str = "1280x720";
        4'b0010: fam_str = "2048x1080";
        4'b0011: fam_str = "ST 295";
        4'b1000: fam_str = "NTSC";
        4'b1001: fam_str = "PAL";
        default: fam_str = "UNKNOWN";
    endcase 

    case(rate)
        4'h0: rate_str = "NONE";
        4'h2: rate_str = "23.98 Hz";
        4'h3: rate_str = "24 Hz";
        4'h4: rate_str = "47.95 Hz";
        4'h5: rate_str = "25 Hz";
        4'h6: rate_str = "29.97 Hz";
        4'h7: rate_str = "30 Hz";
        4'h8: rate_str = "48 Hz";
        4'h9: rate_str = "50 Hz";
        4'ha: rate_str = "59.94 Hz";
        4'hb: rate_str = "60 Hz";
        default: rate_str = "UNKNOWN";
    endcase

    scan_str = scan ? "P" : "I";

    $display("%0s %0s %0s",fam_str,rate_str,scan_str);
    $display("---------------------------");
    //get_format_str = {fam_str, "  ", scan_str, "  ", rate_str};
end
endfunction 
//
// Stimulus execution task
//
// This task tests one video format specified by the record supplied as an
// argument to the task.
//
task test_a_format;
    input [51:0] r;
reg[50*8:0]  exp_format_str, rec_format_str;
reg[8*8:0] mode_str;
reg[16*8:0] bit_rate_str;

begin
//
// Assert reset and set the video format parameters as specified by the struct.
//
//typedef struct packed {
//    line_num    first_active; 51:41
//    sample_num  active_samples; 40:27
//    sample_num  total_samples; 26:13
//    mode_type   mode;        12:11
//    bit         level;       10
//    bit         bit_rate;    9
//    nibble      exp_family;  8:5 
//    nibble      exp_rate;    4:1
//    bit         exp_scan; -- 0
//} record;

    rst <= # DLY 1'b1;
    first_active <= r[51:41];
    active_samples <= r[40:27];
    total_samples <= r[26:13];
    mode <= # DLY r[12:11];
    level <= # DLY r[10];
    bit_rate <= # DLY r[9];

//
// Wait for four clock cycles, then negate the reset. Then wait for the SAV on the
// second active line.  
//
    repeat (10) @ (posedge clk);
    rst <= # DLY 1'b0;
    @ (posedge clk);
    wait (line == r[51:41] + 15);
    @ (posedge clk);

    err = 0;

//
// Report an error and increment the error counter if the values from the
// format detector do not match the expected results.
//
    $display;
    $display ("Format #%0d: mode_locked = %0b", tested, tb_smpte_sdi.rx_mode_locked);
    if (tb_smpte_sdi.rx_mode_locked)
    begin
        case(r[12:11])
            2'b00: begin
                mode_str = "HD-SDI";
                bit_rate_str = r[9] == 1'b0 ? "1.485 Gb/s" : "1.485/1.001 Gb/s";
            end 
            2'b01: begin
                mode_str = "SD-SDI";
                bit_rate_str = "270 Mb/s";
            end
            3'b10: begin
                mode_str = r[10] == 1'b0 ? "3G-SDI A" : "3G-SDI B";
                bit_rate_str = r[9] == 1'b0 ? "2.97 Gb/s" : "2.97/1.001 Gb/s";
            end
            default: begin
                mode_str = "Unknown";
                bit_rate_str = " ";
            end
        endcase
        

        $display("SDI Mode is %s @ %s", mode_str, bit_rate_str);
        $display("Transport detect = %0b", tb_smpte_sdi.locked);

        //exp_format_str = get_format_str(r[8:5], r[4:1], r[0]);
        //rec_format_str = get_format_str(tb_smpte_sdi.family, tb_smpte_sdi.rate, tb_smpte_sdi.scan);

        if (!tb_smpte_sdi.locked)
        begin
            $display("ERROR: Video format detector is not locked to format ");
            exp_format_str = get_format_str(r[8:5], r[4:1], r[0]);
            err = err + 32'h1;
        end
        else
        begin
            if (tb_smpte_sdi.family == r[8:5] && tb_smpte_sdi.rate == r[4:1] && tb_smpte_sdi.scan == r[0])
	    begin
                $display("Detected format ");
                rec_format_str = get_format_str(tb_smpte_sdi.family, tb_smpte_sdi.rate, tb_smpte_sdi.scan);
	    end
            else
            begin
                $display("ERROR: Expected format does not match with detected format" );
                exp_format_str = get_format_str(r[8:5], r[4:1], r[0]);
                rec_format_str = get_format_str(tb_smpte_sdi.family, tb_smpte_sdi.rate, tb_smpte_sdi.scan);
                err = err + 32'h1;
            end
        end
    end
    else
    begin
        $display("ERROR: SDI mode detector is not locked");
        err = err + 32'h1;
    end

    if (err != 0)
    begin
        errors = errors + 32'h1;
        $display("Test failed  as format did not match");
        $finish;
    end
end
endtask

//
// Stimulus loop
//
// Calls test_a_format task for each entry in rec_array
//
integer i;
initial
begin
  //  foreach (rec_array[i])
  for(i = 32'd0;i<32'd10;i=i+32'd1)
    begin
        test_a_format(record[i]);
        tested = tested + 32'h1;
    end

//
// Display the test completed message with error count.
//
    if (errors > 0)
    begin
        $display("Test failed with %0d format detection errors out of %0d tested formats.", errors, tested);
    end else
    begin
        $display("Test passed after testing %0d video formats.", tested);
        $display("** Test completed successfully **");
    end
        
    $finish;
end

endmodule


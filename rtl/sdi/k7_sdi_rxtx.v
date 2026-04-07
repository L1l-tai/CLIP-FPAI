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
//  /   /         Filename: $File: //Groups/video_ip/demos/K7/xapp592_k7_sdi_demos_ver2/kc705_sdi_demo/k7_sdi_rxtx.v $
// /___/   /\     Timestamp: $DateTime: 2014/03/13 12:31:24 $
// \   \  /  \
//  \___\/\___\
//
// Description:
// This module is a wrapper around a set of modules that implement an independent
// SDI RX and TX. The SDI TX is driven by SD and HD video pattern generators. The
// TX and pattern generators are controlled by ChipScope. The output of the SDI RX
// is monitored by ChipScope.
//
// This version of the file also includes the GTX primitive and associated
// control logic.
//
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

module k7_sdi_rxtx #(
    USE_CHIPSCOPE = "TRUE")
(
    input   wire        clk,                // 27 MHz clock
    input   wire        tx_refclk_stable,   // Assert High when TX refclk is stable
    output  wire        tx_plllock,         // Indicates when CPLL is locked
    output  wire        tx_slew,            // SDI cable driver slew rate control
    output  wire        tx_txen,            // SDI bidirectional PHY TX enable
    input   wire        rx_refclk_stable,   // Assert High when RX refclk is stable
    output  wire        qpll_reset,         // Connect to the GTXE2_COMMON qpllreset
    input   wire        qpll_lock,          // Connect to the GTXE2_COMMON qplllock
    (* KEEP = "TRUE" *)output  wire        rx_locked,          // RX status signals
    output  wire [1:0]  rx_mode,
    output  wire        rx_level_b,
    output  wire [3:0]  rx_t_family,
    output  wire [3:0]  rx_t_rate,
    output  wire        rx_t_scan,
    output  wire        rx_m,
    input   wire        drpclk,             // DRP clock
    input   wire        cpll_refclk,        // CPLL reference clock
    output  wire        txp,                // GTX TXP output
    output  wire        txn,                // GTX TXN output
    input   wire        rxp,                // GTX RXP input
    input   wire        rxn,                // GTX RXN input
    input   wire        qpll_clk,           // Connect to the GTXE2_COMMON qplloutclk
    input   wire        qpll_refclk,        // Connect to the GTXE2_COMMON qplloutrefclk
    inout   wire [35:0] control0,           // ChipScope control signals
    inout   wire [35:0] control1,
    inout   wire [35:0] control2,

    output       [ 9:0] rx_ds1a ,
    output       [ 9:0] rx_ds2a ,
    output              rx_eav  ,
    output              rx_sav  ,
    output              rx_usrclk,
    input   wire        rx_gtx_reset,
    input   wire        rx_gtx_full_reset
);

//------------------------------------------------------------------------------
// Internal signals
//

// TX signals
wire        tx_usrclk;
wire        tx_bitrate_sel;
wire [1:0]  tx_mode;
wire [1:0]  tx_mode_x;
wire [2:0]  tx_fmt_sel;
wire [1:0]  tx_pat;
reg         tx_M;
wire [9:0]  tx_hd_y;
wire [9:0]  tx_hd_c;
wire [9:0]  tx_pal_patgen;
wire [9:0]  tx_ntsc_patgen;
wire [9:0]  tx_sd;
wire [10:0] tx_line;
reg  [2:0]  tx_fmt;
wire [9:0]  tx_c;
wire [9:0]  tx_y;
reg  [7:0]  tx_vpid_byte2;
wire        tx_din_rdy;
wire        tx_fabric_reset;
reg  [2:0]  tx_fabric_reset_sss = 3'b000;
wire        tx_gtx_full_reset;
wire        tx_gtx_reset;
wire        tx_change_done;
wire        tx_change_fail;
wire [2:0]  tx_change_fail_code;
(* shreg_extract = "NO" *)
reg  [2:0]  tx_gtx_full_reset_sss = 3'b000;
(* shreg_extract = "NO" *)
reg  [2:0]  tx_gtx_reset_sss = 3'b000;


(* equivalent_register_removal = "no" *)
(* KEEP = "TRUE" *)
reg [2:0]   tx_ce = 3'b111;                    // 3 copies of the TX clock enable
(* equivalent_register_removal = "no" *)
(* KEEP = "TRUE" *)
reg         tx_sd_ce = 1'b0;                   // This is the SD-SDI TX clock enable
(* equivalent_register_removal = "no" *)
(* KEEP = "TRUE" *)
reg  [10:0] tx_gen_sd_ce = 11'b00000100001;    // Generates 5/6/5/6 cadence SD-SDI TX clock enable
wire        tx_ce_mux;                         // Used to generate the tx_ce signals

// RX signals
(*keep = "true"*)wire [1:0]  rx_mode_int;
(*keep = "true"*)wire        rx_mode_locked;
(*keep = "true"*)wire        rx_m_int;
(*keep = "true"*)wire        rx_level_b_int;
(*keep = "true"*)wire [3:0]  rx_t_family_int;
(*keep = "true"*)wire [3:0]  rx_t_rate_int;
(*keep = "true"*)wire        rx_t_scan_int;
(*keep = "true"*)wire        rx_clr_errs;
(*keep = "true"*)wire        rx_ce;
(*keep = "true"*)wire        rx_dout_rdy_3G;
(*keep = "true"*)wire [10:0] rx_ln_a;
(*keep = "true"*)wire [31:0] rx_a_vpid;
(*keep = "true"*)wire        rx_a_vpid_valid;
(*keep = "true"*)wire        rx_crc_err_a;
(*keep = "true"*)wire        rx_crc_err_b;
(*keep = "true"*)reg         rx_hd_crc_err = 1'b0;
(*keep = "true"*)wire        rx_crc_err_ab;
(*keep = "true"*)reg  [1:0]  rx_crc_err_edge = 2'b00;
(*keep = "true"*)reg  [15:0] rx_crc_err_count = 0;
(*keep = "true"*)wire [15:0] rx_err_count;
(*keep = "true"*)wire        rx_err_count_tc;
(*keep = "true"*)reg         rx_sd_clr_errs = 1'b0;
(*keep = "true"*)wire [15:0] rx_edh_errcnt;
//(*keep = "true"*)wire [9:0]  rx_ds1a;
//(*keep = "true"*)wire [9:0]  rx_ds2a;
(*keep = "true"*)wire [9:0]  rx_ds1b;
(*keep = "true"*)wire [9:0]  rx_ds2b;
//(*keep = "true"*)wire        rx_eav;
//(*keep = "true"*)wire        rx_sav;
(*keep = "true"*)wire        rx_crc_err;
(*keep = "true"*)wire        rx_manual_reset;
(*keep = "true"*)wire        rx_change_done;
(*keep = "true"*)wire        rx_change_fail;
(*keep = "true"*)wire [2:0]  rx_change_fail_code;
(*keep = "true"*)reg  [2:0]  rx_gtx_reset_sss = 3'b000;
//(*keep = "true"*)wire        rx_gtx_reset;

//
// Assign some internal signals to module outputs
//
assign rx_mode = rx_mode_int;
assign rx_m = rx_m_int;
assign rx_level_b = rx_level_b_int;
assign rx_t_family = rx_t_family_int;
assign rx_t_rate = rx_t_rate_int;
assign rx_t_scan = rx_t_scan_int;

//
// Because of glitches on TXOUTCLK during changes to TXRATE and TXSYSCLKSEL, the
// SDI data path is reset as long as tx_change_done is Low.
//
always @ (posedge tx_usrclk or negedge tx_change_done)
    if (~tx_change_done)
        tx_fabric_reset_sss <= 3'b111;
    else
        tx_fabric_reset_sss <= {tx_fabric_reset_sss[1:0], ~tx_change_done};

assign tx_fabric_reset = tx_fabric_reset_sss[2];

//
// TX clock enable generator
//
// sd_ce runs at 27 MHz and is asserted at a 5/6/5/6 cadence
// tx_ce is always 1 for 3G-SDI and HD-SDI and equal to sd_ce for SD-SDI
//
// Create 3 identical but separate copies of the clock enable for loading purposes.
//
always @ (posedge tx_usrclk)
    if (tx_fabric_reset)
        tx_gen_sd_ce <= 11'b00000100001;
    else
        tx_gen_sd_ce <= {tx_gen_sd_ce[9:0], tx_gen_sd_ce[10]};

always @ (posedge tx_usrclk)
    tx_sd_ce <= tx_gen_sd_ce[10];

assign tx_ce_mux = tx_mode == 2'b01 ? tx_gen_sd_ce[10] : 1'b1;

always @ (posedge tx_usrclk)
    tx_ce <= {3 {tx_ce_mux}};

//------------------------------------------------------------------------------
// Some logic to insure that the TX bit rate and video formats chosen by the
// user are never illegal.
//
// In 3G-SDI mode, only video formats 4 (1080p60) and 5 (1080p50) are legal.
//
always @ (*)
    if (tx_mode == 2'b10 && tx_fmt_sel[2:1] != 2'b10)
        tx_fmt <= 3'b100;
    else
        tx_fmt <= tx_fmt_sel;

//
// In SD-SDI mode, tx_M must be 0. In HD and 3G modes, if the video format is
// 0 (720p50), 3 (1080i50), or 5 (1080p25), then tx_M must be 0.
//
always @ (*)
    if (tx_mode == 2'b01)          // In SD-SDI mode, tx_M must be 0
        tx_M <= 1'b0;
    else if (tx_fmt == 3'b000 || tx_fmt == 3'b011 || tx_fmt == 3'b101)
        tx_M <= 1'b0;
    else
        tx_M <= tx_bitrate_sel;

//------------------------------------------------------------------------------
// Video pattern generators
//
multigenHD VIDGEN (
    .clk                (tx_usrclk),
    .rst                (tx_fabric_reset),
    .ce                 (1'b1),
    .std                (tx_fmt),
    .pattern            (tx_pat),
    .user_opt           (2'b00),
    .y                  (tx_hd_y),
    .c                  (tx_hd_c),
    .h_blank            (),
    .v_blank            (),
    .field              (),
    .trs                (),
    .xyz                (),
    .line_num           (tx_line));

vidgen_ntsc NTSC (
    .clk                (tx_usrclk),
    .rst                (tx_fabric_reset),
    .ce                 (tx_sd_ce),
    .pattern            (tx_pat[0]),
    .q                  (tx_ntsc_patgen),
    .h_sync             (),
    .v_sync             (),
    .field              ());

vidgen_pal PAL (
    .clk                (tx_usrclk),
    .rst                (tx_fabric_reset),
    .ce                 (tx_sd_ce),
    .pattern            (tx_pat[0]),
    .q                  (tx_pal_patgen),
    .h_sync             (),
    .v_sync             (),
    .field              ());

//
// Video pattern generator output muxes
//
assign tx_sd = tx_fmt[0] ? tx_pal_patgen : tx_ntsc_patgen;
assign tx_c = tx_hd_c;
assign tx_y = tx_mode == 2'b01 ? tx_sd : tx_hd_y;

assign tx_din_rdy = 1'b1;

always @ (*)
    if (tx_fmt[0])
        tx_vpid_byte2 = 8'hC9;      // 50 Hz
    else if (tx_M)
        tx_vpid_byte2 = 8'hCA;      // 59.94 Hz
    else
        tx_vpid_byte2 = 8'hCB;      // 60 Hz

//------------------------------------------------------------------------------
// SDI core wrapper including GTX transceiver.
//
x7gtx_sdi_wrapper #(
    .FXDCLK_FREQ            (27000000),
    .DRPCLK_PERIOD          (37),
    .TIMEOUT_CNTR_BITWIDTH  (16),           // 2^16 / 27e6 is enough for 2ms timeout period
    .CPLL_REFCLK_PORT       ("REFCLK1"),    // CPLL reference clock connected to the gtrefclk1 port
    .TX_CLK0_QPLL           (1),            // TX uses QPLL as clock source when tx_m is Low
    .TX_CLK1_QPLL           (0))            // TX uses CPLL as clock source when tx_m is High
SDI (
    .clk                (clk),
    .drpclk             (drpclk),
    .qpllclk            (qpll_clk),
    .qpllrefclk         (qpll_refclk),
    .qpllreset          (qpll_reset),
    .qplllock           (qpll_lock),
    .cpllrefclk         (cpll_refclk),
    .cplllock           (tx_plllock),
    .rxp                (rxp),
    .rxn                (rxn),
    .txp                (txp),
    .txn                (txn),
    .rx_rst             (1'b0),
    .rx_usrclk_out      (rx_usrclk),
    .rx_gtx_full_reset  (rx_gtx_full_reset),
    .rx_gtx_reset       (rx_gtx_reset),
    .rx_refclk_stable   (rx_refclk_stable),
    .rx_frame_en        (1'b1),                     // Enable SDI framer
    .rx_mode_en         (3'b111),                   // Enable all three SDI protocols
    .rx_mode            (rx_mode_int),
    .rx_mode_hd         (),
    .rx_mode_sd         (),
    .rx_mode_3g         (),
    .rx_mode_locked     (rx_mode_locked),
    .rx_bit_rate        (rx_m_int),
    .rx_t_locked        (rx_locked),
    .rx_t_family        (rx_t_family_int),
    .rx_t_rate          (rx_t_rate_int),
    .rx_t_scan          (rx_t_scan_int),
    .rx_level_b_3g      (rx_level_b_int),
    .rx_ce_sd           (rx_ce),
    .rx_nsp             (),
    .rx_line_a          (rx_ln_a),
    .rx_a_vpid          (rx_a_vpid),
    .rx_a_vpid_valid    (rx_a_vpid_valid),
    .rx_b_vpid          (),
    .rx_b_vpid_valid    (),
    .rx_crc_err_a       (rx_crc_err_a),
    .rx_ds1a            (rx_ds1a),
    .rx_ds2a            (rx_ds2a),
    .rx_eav             (rx_eav),
    .rx_sav             (rx_sav),
    .rx_trs             (),
    .rx_line_b          (),
    .rx_dout_rdy_3g     (rx_dout_rdy_3G),
    .rx_crc_err_b       (rx_crc_err_b),
    .rx_ds1b            (rx_ds1b),
    .rx_ds2b            (rx_ds2b),
    .rx_edh_errcnt_en   (16'b0_00001_00001_00000),
    .rx_edh_clr_errcnt  (rx_sd_clr_errs),
    .rx_edh_ap          (),
    .rx_edh_ff          (),
    .rx_edh_anc         (),
    .rx_edh_ap_flags    (),
    .rx_edh_ff_flags    (),
    .rx_edh_anc_flags   (),
    .rx_edh_packet_flags(),
    .rx_edh_errcnt      (rx_edh_errcnt),
    .rx_change_done     (rx_change_done),
    .rx_change_fail     (rx_change_fail),
    .rx_change_fail_code(rx_change_fail_code),
    .drpbusy            (),

    .tx_rst             (tx_fabric_reset),
    .tx_usrclk_out      (tx_usrclk),
    .tx_gtx_full_reset  (tx_gtx_full_reset),
    .tx_gtx_reset       (tx_gtx_reset),
    .tx_refclk_stable   (tx_refclk_stable),
    .tx_ce              (tx_ce),
    .tx_din_rdy         (tx_din_rdy),
    .tx_mode            (tx_mode),
    .tx_m               (tx_M),
    .tx_level_b_3g      (1'b0),             // In 3G-SDI mode, this demo only transmits level A
    .tx_insert_crc      (1'b1),
    .tx_insert_ln       (1'b1),
    .tx_insert_edh      (1'b1),
    .tx_insert_vpid     (tx_mode == 2'b10),
    .tx_overwrite_vpid  (1'b1),
    .tx_video_a_y_in    (tx_y),
    .tx_video_a_c_in    (tx_c),
    .tx_video_b_y_in    (10'b0),
    .tx_video_b_c_in    (10'b0),
    .tx_line_a          (tx_line),
    .tx_line_b          (tx_line),
    .tx_vpid_byte1      (8'h89),
    .tx_vpid_byte2      (tx_vpid_byte2),
    .tx_vpid_byte3      (8'h00),
    .tx_vpid_byte4a     (8'h09),
    .tx_vpid_byte4b     (8'h09),
    .tx_vpid_line_f1    (11'd10),
    .tx_vpid_line_f2    (11'b0),
    .tx_vpid_line_f2_en (1'b0),
    .tx_ds1a_out        (),
    .tx_ds2a_out        (),
    .tx_ds1b_out        (),
    .tx_ds2b_out        (),
    .tx_use_dsin        (1'b0),
    .tx_ds1a_in         (10'b0),
    .tx_ds2a_in         (10'b0),
    .tx_ds1b_in         (10'b0),
    .tx_ds2b_in         (10'b0),
    .tx_ce_align_err    (),
    .tx_slew            (tx_slew),
    .tx_change_done     (tx_change_done),
    .tx_change_fail     (tx_change_fail),
    .tx_change_fail_code(tx_change_fail_code));


//------------------------------------------------------------------------------
// CRC eror capture and counting logic
//
assign rx_crc_err_ab = rx_crc_err_a | (rx_mode_int == 2'b10 && rx_level_b_int && rx_crc_err_b);

always @ (posedge rx_usrclk)
    if (rx_clr_errs)
        rx_hd_crc_err <= 1'b0;
    else if (rx_crc_err_ab)
        rx_hd_crc_err <= 1'b1;

always @ (posedge rx_usrclk)
    rx_crc_err_edge <= {rx_crc_err_edge[0], rx_crc_err_ab};

always @ (posedge rx_usrclk)
    if (rx_clr_errs | ~rx_mode_locked)
        rx_crc_err_count <= 0;
    else if (rx_crc_err_edge[0] & ~rx_crc_err_edge[1] & ~rx_err_count_tc)
        rx_crc_err_count <= rx_crc_err_count + 1;

assign rx_err_count = rx_mode_int == 2'b01 ? rx_edh_errcnt : rx_crc_err_count;
assign rx_err_count_tc = rx_crc_err_count == 16'hffff;

always @ (posedge rx_usrclk)
    if (rx_clr_errs)
        rx_sd_clr_errs <= 1'b1;
    else if (rx_ce)
        rx_sd_clr_errs <= 1'b0;

assign rx_crc_err = rx_mode_int == 2'b01 ? rx_edh_errcnt != 0 : rx_hd_crc_err;

//------------------------------------------------------------------------------
// ChipScope or Vivado Analyzer modules
//
wire tx_gtx_full_reset_async, tx_gtx_reset_async;






//generate
//if (USE_CHIPSCOPE == "TRUE")
//begin : chipscope
//    wire [8:0]  tx_vio_sync_out;
//    wire [1:0]  tx_vio_async_out;
//
//    tx_vio tx_vio (
//        .CONTROL    (control0),
//        .CLK        (tx_usrclk),
//        .ASYNC_IN   ({tx_M, tx_mode, tx_change_fail_code, 1'b0, tx_change_done, tx_change_fail}),   // 9 bits
//        .ASYNC_OUT  (tx_vio_async_out),
//        .SYNC_OUT   (tx_vio_sync_out));
//
//    assign tx_bitrate_sel = tx_vio_sync_out[0];
//    assign tx_txen = tx_vio_sync_out[1];
//    assign tx_fmt_sel = tx_vio_sync_out[4:2];
//    assign tx_pat = tx_vio_sync_out[6:5];
//    assign tx_mode_x = tx_vio_sync_out[8:7];
//
//    always @ (posedge drpclk)
//        tx_gtx_full_reset_sss = {tx_gtx_full_reset_sss[1:0], tx_gtx_full_reset_async};
//
//    assign tx_gtx_full_reset = tx_gtx_full_reset_sss[2];
//
//    always @ (posedge drpclk)
//        tx_gtx_reset_sss = {tx_gtx_reset_sss[1:0], tx_gtx_reset_async};
//
//    assign tx_gtx_reset = tx_gtx_reset_sss[2];
//
//    assign tx_gtx_full_reset_async = tx_vio_async_out[0];
//    assign tx_gtx_reset_async = tx_vio_async_out[1];
//
//    wire [31:0] rx_vpid;
//    assign rx_vpid = {rx_a_vpid[7:0], rx_a_vpid[15:8], rx_a_vpid[23:16], rx_a_vpid[31:24]};
//    wire [1:0]  rx_vio_sync_out;
//
//    rx_vio rx_vio (
//        .CONTROL    (control1),
//        .CLK        (rx_usrclk),
//        .ASYNC_IN   ({rx_change_fail_code, rx_change_fail, rx_change_done, 1'b0,
//                      rx_gtrxreset, rx_cdrhold, rx_t_scan_int, rx_t_rate_int,
//                      rx_err_count, rx_crc_err, rx_a_vpid_valid, rx_vpid, rx_m_int,
//                      rx_level_b_int, rx_t_family_int, rx_mode_locked, rx_mode_int}),           // 72 bits
//        .SYNC_OUT   (rx_vio_sync_out));
//
//
//    assign rx_clr_errs = rx_vio_sync_out[0];
//    assign rx_manual_reset = rx_vio_sync_out[1];
//
//    always @ (posedge drpclk or posedge rx_manual_reset)
//        if (rx_manual_reset)
//            rx_gtx_reset_sss = 3'b001;
//        else
//            rx_gtx_reset_sss = {rx_gtx_reset_sss[1:0], rx_manual_reset};
//
//    assign rx_gtx_reset = rx_gtx_reset_sss[2];
//
//    wire [55:0] rx_trig0;
//
//    rx_ila rx_ila (
//        .CONTROL    (control2),
//        .CLK        (rx_usrclk),
//        .TRIG0      (rx_trig0));
//
//    assign rx_trig0 = {rx_sav, rx_eav, rx_ds2b, rx_ds1b, rx_ds2a, rx_ds1a, rx_ln_a, rx_crc_err_ab, rx_dout_rdy_3G, rx_ce};
//
//end else
//begin : vivado_anaylzer
//    tx_vio tx_vio (
//        .clk        (tx_usrclk),
//        .probe_in0  (tx_change_fail),           // 1 bit
//        .probe_in1  (tx_change_done),           // 1 bit
//        .probe_in2  (tx_change_fail_code),      // 3 bit
//        .probe_out0 (tx_bitrate_sel),           // 1 bit
//        .probe_out1 (tx_en),                    // 1 bit
//        .probe_out2 (tx_fmt_sel),               // 3 bit
//        .probe_out3 (tx_pat),                   // 2 bit
//        .probe_out4 (tx_mode_x)                 // 2 bit
//    );
//
//    assign tx_gtx_full_reset = 1'b0;
//    assign tx_gtx_reset = 1'b0;
//
//    rx_vio rx_vio (
//        .clk        (rx_usrclk),
//        .probe_in0  (rx_mode_int),          // 2 bit
//        .probe_in1  (rx_mode_locked),       // 1 bit
//        .probe_in2  (rx_t_family_int),      // 4 bit
//        .probe_in3  (rx_level_b_int),       // 1 bit
//        .probe_in4  (rx_m_int),             // 1 bit
//        .probe_in5  (rx_vpid),              // 32 bit
//        .probe_in6  (rx_a_vpid_valid),      // 1 bit
//        .probe_in7  (rx_crc_err),           // 1 bit
//        .probe_in8  (rx_err_count),         // 16 bit
//        .probe_in9  (rx_t_rate_int),        // 4 bit
//        .probe_in10 (rx_t_scan_int),        // 1 bit
//        .probe_in11 (rx_cdrhold),           // 1 bit
//        .probe_in12 (rx_gtrxreset),         // 1 bit
//        .probe_in13 (rx_change_done),       // 1 bit
//        .probe_in14 (rx_change_fail),       // 1 bit
//        .probe_in15 (rx_change_fail_code),  // 3 bit
//        .probe_out0 (rx_clr_errs),          // 1 bit
//        .probe_out1 (rx_manual_reset)       // 1 bit
//    );
//
//    rx_ila rx_ila (
//        .clk        (rx_usrclk),
//        .probe0     (rx_ce),            // 1 bit
//        .probe1     (rx_dout_rdy_3G),   // 1 bit
//        .probe2     (rx_crc_err_ab),    // 1 bit
//        .probe3     (rx_ln_a),          // 11 bit
//        .probe4     (rx_ds1a),          // 10 bit
//        .probe5     (rx_ds2a),          // 10 bit
//        .probe6     (rx_ds1b),          // 10 bit
//        .probe7     (rx_ds2b),          // 10 bit
//        .probe8     (rx_eav),           // 1 bit
//        .probe9     (rx_sav));          // 1 bit
//end
//endgenerate

assign tx_mode = tx_mode_x == 2'b11 ? 2'b00 : tx_mode_x;

endmodule

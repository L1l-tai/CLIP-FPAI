// (c) Copyright 1995-2026 Xilinx, Inc. All rights reserved.
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
// DO NOT MODIFY THIS FILE.


// IP VLNV: xilinx.com:ip:v_smpte_sdi:3.0
// IP Revision: 8

(* X_CORE_INFO = "v_smpte_sdi_v3_0_8,Vivado 2018.3" *)
(* CHECK_LICENSE_TYPE = "smpte_sdi,v_smpte_sdi_v3_0_8,{}" *)
(* CORE_GENERATION_INFO = "smpte_sdi,v_smpte_sdi_v3_0_8,{x_ipProduct=Vivado 2018.3,x_ipVendor=xilinx.com,x_ipLibrary=ip,x_ipName=v_smpte_sdi,x_ipVersion=3.0,x_ipCoreRevision=8,x_ipLanguage=VERILOG,x_ipSimLanguage=MIXED,INCLUDE_RX_EDH_PROCESSOR=TRUE,C_FAMILY=zynq}" *)
(* DowngradeIPIdentifiedWarnings = "yes" *)
module smpte_sdi (
  rx_rst,
  rx_usrclk,
  rx_data_in,
  rx_sd_data_in,
  rx_sd_data_strobe,
  rx_frame_en,
  rx_mode_en,
  rx_mode,
  rx_mode_hd,
  rx_mode_sd,
  rx_mode_3g,
  rx_mode_detect_en,
  rx_mode_locked,
  rx_forced_mode,
  rx_bit_rate,
  rx_t_locked,
  rx_t_family,
  rx_t_rate,
  rx_t_scan,
  rx_level_b_3g,
  rx_ce_sd,
  rx_nsp,
  rx_line_a,
  rx_a_vpid,
  rx_a_vpid_valid,
  rx_b_vpid,
  rx_b_vpid_valid,
  rx_crc_err_a,
  rx_ds1a,
  rx_ds2a,
  rx_eav,
  rx_sav,
  rx_trs,
  rx_line_b,
  rx_dout_rdy_3g,
  rx_crc_err_b,
  rx_ds1b,
  rx_ds2b,
  rx_edh_errcnt_en,
  rx_edh_clr_errcnt,
  rx_edh_ap,
  rx_edh_ff,
  rx_edh_anc,
  rx_edh_ap_flags,
  rx_edh_ff_flags,
  rx_edh_anc_flags,
  rx_edh_packet_flags,
  rx_edh_errcnt,
  tx_rst,
  tx_usrclk,
  tx_ce,
  tx_din_rdy,
  tx_mode,
  tx_level_b_3g,
  tx_insert_crc,
  tx_insert_ln,
  tx_insert_edh,
  tx_insert_vpid,
  tx_overwrite_vpid,
  tx_video_a_y_in,
  tx_video_a_c_in,
  tx_video_b_y_in,
  tx_video_b_c_in,
  tx_line_a,
  tx_line_b,
  tx_vpid_byte1,
  tx_vpid_byte2,
  tx_vpid_byte3,
  tx_vpid_byte4a,
  tx_vpid_byte4b,
  tx_vpid_line_f1,
  tx_vpid_line_f2,
  tx_vpid_line_f2_en,
  tx_ds1a_out,
  tx_ds2a_out,
  tx_ds1b_out,
  tx_ds2b_out,
  tx_use_dsin,
  tx_ds1a_in,
  tx_ds2a_in,
  tx_ds1b_in,
  tx_ds2b_in,
  tx_sd_bitrep_bypass,
  tx_txdata,
  tx_ce_align_err
);

(* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME RX_RST_INTF, POLARITY ACTIVE_HIGH, INSERT_VIP 0" *)
(* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 RX_RST_INTF RST" *)
input wire rx_rst;
(* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME RX_CLK_INTF, ASSOCIATED_BUSIF SDI_RX_INTF, ASSOCIATED_RESET rx_rst, FREQ_HZ 100000000, PHASE 0.000, INSERT_VIP 0" *)
(* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 RX_CLK_INTF CLK" *)
input wire rx_usrclk;
input wire [19 : 0] rx_data_in;
input wire [9 : 0] rx_sd_data_in;
input wire rx_sd_data_strobe;
input wire rx_frame_en;
input wire [2 : 0] rx_mode_en;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_RX_INTF SDI_MODE" *)
output wire [1 : 0] rx_mode;
output wire rx_mode_hd;
output wire rx_mode_sd;
output wire rx_mode_3g;
input wire rx_mode_detect_en;
output wire rx_mode_locked;
input wire [1 : 0] rx_forced_mode;
input wire rx_bit_rate;
output wire rx_t_locked;
output wire [3 : 0] rx_t_family;
output wire [3 : 0] rx_t_rate;
output wire rx_t_scan;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_RX_INTF LVL_B_3G" *)
output wire rx_level_b_3g;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_RX_INTF CE" *)
output wire rx_ce_sd;
output wire rx_nsp;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_RX_INTF LINE_A" *)
output wire [10 : 0] rx_line_a;
output wire [31 : 0] rx_a_vpid;
output wire rx_a_vpid_valid;
output wire [31 : 0] rx_b_vpid;
output wire rx_b_vpid_valid;
output wire rx_crc_err_a;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_RX_INTF DS1A" *)
output wire [9 : 0] rx_ds1a;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_RX_INTF DS2A" *)
output wire [9 : 0] rx_ds2a;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_RX_INTF RX_EAV" *)
output wire rx_eav;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_RX_INTF RX_SAV" *)
output wire rx_sav;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_RX_INTF RX_TRS" *)
output wire rx_trs;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_RX_INTF LINE_B" *)
output wire [10 : 0] rx_line_b;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_RX_INTF D_RDY_3G" *)
output wire rx_dout_rdy_3g;
output wire rx_crc_err_b;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_RX_INTF DS1B" *)
output wire [9 : 0] rx_ds1b;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_RX_INTF DS2B" *)
output wire [9 : 0] rx_ds2b;
input wire [15 : 0] rx_edh_errcnt_en;
input wire rx_edh_clr_errcnt;
output wire rx_edh_ap;
output wire rx_edh_ff;
output wire rx_edh_anc;
output wire [4 : 0] rx_edh_ap_flags;
output wire [4 : 0] rx_edh_ff_flags;
output wire [4 : 0] rx_edh_anc_flags;
output wire [3 : 0] rx_edh_packet_flags;
output wire [15 : 0] rx_edh_errcnt;
(* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME TX_RST_INTF, POLARITY ACTIVE_HIGH, INSERT_VIP 0" *)
(* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 TX_RST_INTF RST" *)
input wire tx_rst;
(* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME TX_CLK_INTF, ASSOCIATED_BUSIF SDI_TX_INTF, ASSOCIATED_RESET tx_rst, FREQ_HZ 100000000, PHASE 0.000, INSERT_VIP 0" *)
(* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 TX_CLK_INTF CLK" *)
input wire tx_usrclk;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_TX_INTF CE" *)
input wire [2 : 0] tx_ce;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_TX_INTF D_RDY_3G" *)
input wire tx_din_rdy;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_TX_INTF SDI_MODE" *)
input wire [1 : 0] tx_mode;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_TX_INTF LVL_B_3G" *)
input wire tx_level_b_3g;
input wire tx_insert_crc;
input wire tx_insert_ln;
input wire tx_insert_edh;
input wire tx_insert_vpid;
input wire tx_overwrite_vpid;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_TX_INTF DS1A" *)
input wire [9 : 0] tx_video_a_y_in;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_TX_INTF DS2A" *)
input wire [9 : 0] tx_video_a_c_in;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_TX_INTF DS1B" *)
input wire [9 : 0] tx_video_b_y_in;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_TX_INTF DS2B" *)
input wire [9 : 0] tx_video_b_c_in;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_TX_INTF LINE_A" *)
input wire [10 : 0] tx_line_a;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_TX_INTF LINE_B" *)
input wire [10 : 0] tx_line_b;
input wire [7 : 0] tx_vpid_byte1;
input wire [7 : 0] tx_vpid_byte2;
input wire [7 : 0] tx_vpid_byte3;
input wire [7 : 0] tx_vpid_byte4a;
input wire [7 : 0] tx_vpid_byte4b;
input wire [10 : 0] tx_vpid_line_f1;
input wire [10 : 0] tx_vpid_line_f2;
input wire tx_vpid_line_f2_en;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_TX2ANC_INTF DS1A" *)
output wire [9 : 0] tx_ds1a_out;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_TX2ANC_INTF DS2A" *)
output wire [9 : 0] tx_ds2a_out;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_TX2ANC_INTF DS1B" *)
output wire [9 : 0] tx_ds1b_out;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_TX2ANC_INTF DS2B" *)
output wire [9 : 0] tx_ds2b_out;
input wire tx_use_dsin;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_ANC2TX_INTF DS1A" *)
input wire [9 : 0] tx_ds1a_in;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_ANC2TX_INTF DS2A" *)
input wire [9 : 0] tx_ds2a_in;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_ANC2TX_INTF DS1B" *)
input wire [9 : 0] tx_ds1b_in;
(* X_INTERFACE_INFO = "xilinx.com:interface:sdi_native:1.0 SDI_ANC2TX_INTF DS2B" *)
input wire [9 : 0] tx_ds2b_in;
input wire tx_sd_bitrep_bypass;
output wire [19 : 0] tx_txdata;
output wire tx_ce_align_err;

  v_smpte_sdi_v3_0_8 #(
    .INCLUDE_RX_EDH_PROCESSOR("TRUE"),
    .C_FAMILY("zynq")
  ) inst (
    .rx_rst(rx_rst),
    .rx_usrclk(rx_usrclk),
    .rx_data_in(rx_data_in),
    .rx_sd_data_in(rx_sd_data_in),
    .rx_sd_data_strobe(rx_sd_data_strobe),
    .rx_frame_en(rx_frame_en),
    .rx_mode_en(rx_mode_en),
    .rx_mode(rx_mode),
    .rx_mode_hd(rx_mode_hd),
    .rx_mode_sd(rx_mode_sd),
    .rx_mode_3g(rx_mode_3g),
    .rx_mode_detect_en(rx_mode_detect_en),
    .rx_mode_locked(rx_mode_locked),
    .rx_forced_mode(rx_forced_mode),
    .rx_bit_rate(rx_bit_rate),
    .rx_t_locked(rx_t_locked),
    .rx_t_family(rx_t_family),
    .rx_t_rate(rx_t_rate),
    .rx_t_scan(rx_t_scan),
    .rx_level_b_3g(rx_level_b_3g),
    .rx_ce_sd(rx_ce_sd),
    .rx_nsp(rx_nsp),
    .rx_line_a(rx_line_a),
    .rx_a_vpid(rx_a_vpid),
    .rx_a_vpid_valid(rx_a_vpid_valid),
    .rx_b_vpid(rx_b_vpid),
    .rx_b_vpid_valid(rx_b_vpid_valid),
    .rx_crc_err_a(rx_crc_err_a),
    .rx_ds1a(rx_ds1a),
    .rx_ds2a(rx_ds2a),
    .rx_eav(rx_eav),
    .rx_sav(rx_sav),
    .rx_trs(rx_trs),
    .rx_line_b(rx_line_b),
    .rx_dout_rdy_3g(rx_dout_rdy_3g),
    .rx_crc_err_b(rx_crc_err_b),
    .rx_ds1b(rx_ds1b),
    .rx_ds2b(rx_ds2b),
    .rx_edh_errcnt_en(rx_edh_errcnt_en),
    .rx_edh_clr_errcnt(rx_edh_clr_errcnt),
    .rx_edh_ap(rx_edh_ap),
    .rx_edh_ff(rx_edh_ff),
    .rx_edh_anc(rx_edh_anc),
    .rx_edh_ap_flags(rx_edh_ap_flags),
    .rx_edh_ff_flags(rx_edh_ff_flags),
    .rx_edh_anc_flags(rx_edh_anc_flags),
    .rx_edh_packet_flags(rx_edh_packet_flags),
    .rx_edh_errcnt(rx_edh_errcnt),
    .tx_rst(tx_rst),
    .tx_usrclk(tx_usrclk),
    .tx_ce(tx_ce),
    .tx_din_rdy(tx_din_rdy),
    .tx_mode(tx_mode),
    .tx_level_b_3g(tx_level_b_3g),
    .tx_insert_crc(tx_insert_crc),
    .tx_insert_ln(tx_insert_ln),
    .tx_insert_edh(tx_insert_edh),
    .tx_insert_vpid(tx_insert_vpid),
    .tx_overwrite_vpid(tx_overwrite_vpid),
    .tx_video_a_y_in(tx_video_a_y_in),
    .tx_video_a_c_in(tx_video_a_c_in),
    .tx_video_b_y_in(tx_video_b_y_in),
    .tx_video_b_c_in(tx_video_b_c_in),
    .tx_line_a(tx_line_a),
    .tx_line_b(tx_line_b),
    .tx_vpid_byte1(tx_vpid_byte1),
    .tx_vpid_byte2(tx_vpid_byte2),
    .tx_vpid_byte3(tx_vpid_byte3),
    .tx_vpid_byte4a(tx_vpid_byte4a),
    .tx_vpid_byte4b(tx_vpid_byte4b),
    .tx_vpid_line_f1(tx_vpid_line_f1),
    .tx_vpid_line_f2(tx_vpid_line_f2),
    .tx_vpid_line_f2_en(tx_vpid_line_f2_en),
    .tx_ds1a_out(tx_ds1a_out),
    .tx_ds2a_out(tx_ds2a_out),
    .tx_ds1b_out(tx_ds1b_out),
    .tx_ds2b_out(tx_ds2b_out),
    .tx_use_dsin(tx_use_dsin),
    .tx_ds1a_in(tx_ds1a_in),
    .tx_ds2a_in(tx_ds2a_in),
    .tx_ds1b_in(tx_ds1b_in),
    .tx_ds2b_in(tx_ds2b_in),
    .tx_sd_bitrep_bypass(tx_sd_bitrep_bypass),
    .tx_txdata(tx_txdata),
    .tx_ce_align_err(tx_ce_align_err)
  );
endmodule

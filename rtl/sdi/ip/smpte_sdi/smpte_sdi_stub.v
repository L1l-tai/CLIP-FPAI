// Copyright 1986-2018 Xilinx, Inc. All Rights Reserved.
// --------------------------------------------------------------------------------
// Tool Version: Vivado v.2018.3 (win64) Build 2405991 Thu Dec  6 23:38:27 MST 2018
// Date        : Fri May  1 22:06:40 2026
// Host        : Normalcy running 64-bit major release  (build 9200)
// Command     : write_verilog -force -mode synth_stub
//               D:/icraft-docker/Ubuntu20.04/clip-vit-base-patch32-zg/rtl/sdi/ip/smpte_sdi/smpte_sdi_stub.v
// Design      : smpte_sdi
// Purpose     : Stub declaration of top-level module interface
// Device      : xc7z030ffg676-2
// --------------------------------------------------------------------------------

// This empty module with port declaration file causes synthesis tools to infer a black box for IP.
// The synthesis directives are for Synopsys Synplify support to prevent IO buffer insertion.
// Please paste the declaration into a Verilog source file or add the file as an additional source.
(* X_CORE_INFO = "v_smpte_sdi_v3_0_8,Vivado 2018.3" *)
module smpte_sdi(rx_rst, rx_usrclk, rx_data_in, rx_sd_data_in, 
  rx_sd_data_strobe, rx_frame_en, rx_mode_en, rx_mode, rx_mode_hd, rx_mode_sd, rx_mode_3g, 
  rx_mode_detect_en, rx_mode_locked, rx_forced_mode, rx_bit_rate, rx_t_locked, rx_t_family, 
  rx_t_rate, rx_t_scan, rx_level_b_3g, rx_ce_sd, rx_nsp, rx_line_a, rx_a_vpid, rx_a_vpid_valid, 
  rx_b_vpid, rx_b_vpid_valid, rx_crc_err_a, rx_ds1a, rx_ds2a, rx_eav, rx_sav, rx_trs, rx_line_b, 
  rx_dout_rdy_3g, rx_crc_err_b, rx_ds1b, rx_ds2b, rx_edh_errcnt_en, rx_edh_clr_errcnt, 
  rx_edh_ap, rx_edh_ff, rx_edh_anc, rx_edh_ap_flags, rx_edh_ff_flags, rx_edh_anc_flags, 
  rx_edh_packet_flags, rx_edh_errcnt, tx_rst, tx_usrclk, tx_ce, tx_din_rdy, tx_mode, 
  tx_level_b_3g, tx_insert_crc, tx_insert_ln, tx_insert_edh, tx_insert_vpid, 
  tx_overwrite_vpid, tx_video_a_y_in, tx_video_a_c_in, tx_video_b_y_in, tx_video_b_c_in, 
  tx_line_a, tx_line_b, tx_vpid_byte1, tx_vpid_byte2, tx_vpid_byte3, tx_vpid_byte4a, 
  tx_vpid_byte4b, tx_vpid_line_f1, tx_vpid_line_f2, tx_vpid_line_f2_en, tx_ds1a_out, 
  tx_ds2a_out, tx_ds1b_out, tx_ds2b_out, tx_use_dsin, tx_ds1a_in, tx_ds2a_in, tx_ds1b_in, 
  tx_ds2b_in, tx_sd_bitrep_bypass, tx_txdata, tx_ce_align_err)
/* synthesis syn_black_box black_box_pad_pin="rx_rst,rx_usrclk,rx_data_in[19:0],rx_sd_data_in[9:0],rx_sd_data_strobe,rx_frame_en,rx_mode_en[2:0],rx_mode[1:0],rx_mode_hd,rx_mode_sd,rx_mode_3g,rx_mode_detect_en,rx_mode_locked,rx_forced_mode[1:0],rx_bit_rate,rx_t_locked,rx_t_family[3:0],rx_t_rate[3:0],rx_t_scan,rx_level_b_3g,rx_ce_sd,rx_nsp,rx_line_a[10:0],rx_a_vpid[31:0],rx_a_vpid_valid,rx_b_vpid[31:0],rx_b_vpid_valid,rx_crc_err_a,rx_ds1a[9:0],rx_ds2a[9:0],rx_eav,rx_sav,rx_trs,rx_line_b[10:0],rx_dout_rdy_3g,rx_crc_err_b,rx_ds1b[9:0],rx_ds2b[9:0],rx_edh_errcnt_en[15:0],rx_edh_clr_errcnt,rx_edh_ap,rx_edh_ff,rx_edh_anc,rx_edh_ap_flags[4:0],rx_edh_ff_flags[4:0],rx_edh_anc_flags[4:0],rx_edh_packet_flags[3:0],rx_edh_errcnt[15:0],tx_rst,tx_usrclk,tx_ce[2:0],tx_din_rdy,tx_mode[1:0],tx_level_b_3g,tx_insert_crc,tx_insert_ln,tx_insert_edh,tx_insert_vpid,tx_overwrite_vpid,tx_video_a_y_in[9:0],tx_video_a_c_in[9:0],tx_video_b_y_in[9:0],tx_video_b_c_in[9:0],tx_line_a[10:0],tx_line_b[10:0],tx_vpid_byte1[7:0],tx_vpid_byte2[7:0],tx_vpid_byte3[7:0],tx_vpid_byte4a[7:0],tx_vpid_byte4b[7:0],tx_vpid_line_f1[10:0],tx_vpid_line_f2[10:0],tx_vpid_line_f2_en,tx_ds1a_out[9:0],tx_ds2a_out[9:0],tx_ds1b_out[9:0],tx_ds2b_out[9:0],tx_use_dsin,tx_ds1a_in[9:0],tx_ds2a_in[9:0],tx_ds1b_in[9:0],tx_ds2b_in[9:0],tx_sd_bitrep_bypass,tx_txdata[19:0],tx_ce_align_err" */;
  input rx_rst;
  input rx_usrclk;
  input [19:0]rx_data_in;
  input [9:0]rx_sd_data_in;
  input rx_sd_data_strobe;
  input rx_frame_en;
  input [2:0]rx_mode_en;
  output [1:0]rx_mode;
  output rx_mode_hd;
  output rx_mode_sd;
  output rx_mode_3g;
  input rx_mode_detect_en;
  output rx_mode_locked;
  input [1:0]rx_forced_mode;
  input rx_bit_rate;
  output rx_t_locked;
  output [3:0]rx_t_family;
  output [3:0]rx_t_rate;
  output rx_t_scan;
  output rx_level_b_3g;
  output rx_ce_sd;
  output rx_nsp;
  output [10:0]rx_line_a;
  output [31:0]rx_a_vpid;
  output rx_a_vpid_valid;
  output [31:0]rx_b_vpid;
  output rx_b_vpid_valid;
  output rx_crc_err_a;
  output [9:0]rx_ds1a;
  output [9:0]rx_ds2a;
  output rx_eav;
  output rx_sav;
  output rx_trs;
  output [10:0]rx_line_b;
  output rx_dout_rdy_3g;
  output rx_crc_err_b;
  output [9:0]rx_ds1b;
  output [9:0]rx_ds2b;
  input [15:0]rx_edh_errcnt_en;
  input rx_edh_clr_errcnt;
  output rx_edh_ap;
  output rx_edh_ff;
  output rx_edh_anc;
  output [4:0]rx_edh_ap_flags;
  output [4:0]rx_edh_ff_flags;
  output [4:0]rx_edh_anc_flags;
  output [3:0]rx_edh_packet_flags;
  output [15:0]rx_edh_errcnt;
  input tx_rst;
  input tx_usrclk;
  input [2:0]tx_ce;
  input tx_din_rdy;
  input [1:0]tx_mode;
  input tx_level_b_3g;
  input tx_insert_crc;
  input tx_insert_ln;
  input tx_insert_edh;
  input tx_insert_vpid;
  input tx_overwrite_vpid;
  input [9:0]tx_video_a_y_in;
  input [9:0]tx_video_a_c_in;
  input [9:0]tx_video_b_y_in;
  input [9:0]tx_video_b_c_in;
  input [10:0]tx_line_a;
  input [10:0]tx_line_b;
  input [7:0]tx_vpid_byte1;
  input [7:0]tx_vpid_byte2;
  input [7:0]tx_vpid_byte3;
  input [7:0]tx_vpid_byte4a;
  input [7:0]tx_vpid_byte4b;
  input [10:0]tx_vpid_line_f1;
  input [10:0]tx_vpid_line_f2;
  input tx_vpid_line_f2_en;
  output [9:0]tx_ds1a_out;
  output [9:0]tx_ds2a_out;
  output [9:0]tx_ds1b_out;
  output [9:0]tx_ds2b_out;
  input tx_use_dsin;
  input [9:0]tx_ds1a_in;
  input [9:0]tx_ds2a_in;
  input [9:0]tx_ds1b_in;
  input [9:0]tx_ds2b_in;
  input tx_sd_bitrep_bypass;
  output [19:0]tx_txdata;
  output tx_ce_align_err;
endmodule

-- Copyright 1986-2018 Xilinx, Inc. All Rights Reserved.
-- --------------------------------------------------------------------------------
-- Tool Version: Vivado v.2018.3 (win64) Build 2405991 Thu Dec  6 23:38:27 MST 2018
-- Date        : Fri May  1 22:06:40 2026
-- Host        : Normalcy running 64-bit major release  (build 9200)
-- Command     : write_vhdl -force -mode synth_stub
--               D:/icraft-docker/Ubuntu20.04/clip-vit-base-patch32-zg/rtl/sdi/ip/smpte_sdi/smpte_sdi_stub.vhdl
-- Design      : smpte_sdi
-- Purpose     : Stub declaration of top-level module interface
-- Device      : xc7z030ffg676-2
-- --------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity smpte_sdi is
  Port ( 
    rx_rst : in STD_LOGIC;
    rx_usrclk : in STD_LOGIC;
    rx_data_in : in STD_LOGIC_VECTOR ( 19 downto 0 );
    rx_sd_data_in : in STD_LOGIC_VECTOR ( 9 downto 0 );
    rx_sd_data_strobe : in STD_LOGIC;
    rx_frame_en : in STD_LOGIC;
    rx_mode_en : in STD_LOGIC_VECTOR ( 2 downto 0 );
    rx_mode : out STD_LOGIC_VECTOR ( 1 downto 0 );
    rx_mode_hd : out STD_LOGIC;
    rx_mode_sd : out STD_LOGIC;
    rx_mode_3g : out STD_LOGIC;
    rx_mode_detect_en : in STD_LOGIC;
    rx_mode_locked : out STD_LOGIC;
    rx_forced_mode : in STD_LOGIC_VECTOR ( 1 downto 0 );
    rx_bit_rate : in STD_LOGIC;
    rx_t_locked : out STD_LOGIC;
    rx_t_family : out STD_LOGIC_VECTOR ( 3 downto 0 );
    rx_t_rate : out STD_LOGIC_VECTOR ( 3 downto 0 );
    rx_t_scan : out STD_LOGIC;
    rx_level_b_3g : out STD_LOGIC;
    rx_ce_sd : out STD_LOGIC;
    rx_nsp : out STD_LOGIC;
    rx_line_a : out STD_LOGIC_VECTOR ( 10 downto 0 );
    rx_a_vpid : out STD_LOGIC_VECTOR ( 31 downto 0 );
    rx_a_vpid_valid : out STD_LOGIC;
    rx_b_vpid : out STD_LOGIC_VECTOR ( 31 downto 0 );
    rx_b_vpid_valid : out STD_LOGIC;
    rx_crc_err_a : out STD_LOGIC;
    rx_ds1a : out STD_LOGIC_VECTOR ( 9 downto 0 );
    rx_ds2a : out STD_LOGIC_VECTOR ( 9 downto 0 );
    rx_eav : out STD_LOGIC;
    rx_sav : out STD_LOGIC;
    rx_trs : out STD_LOGIC;
    rx_line_b : out STD_LOGIC_VECTOR ( 10 downto 0 );
    rx_dout_rdy_3g : out STD_LOGIC;
    rx_crc_err_b : out STD_LOGIC;
    rx_ds1b : out STD_LOGIC_VECTOR ( 9 downto 0 );
    rx_ds2b : out STD_LOGIC_VECTOR ( 9 downto 0 );
    rx_edh_errcnt_en : in STD_LOGIC_VECTOR ( 15 downto 0 );
    rx_edh_clr_errcnt : in STD_LOGIC;
    rx_edh_ap : out STD_LOGIC;
    rx_edh_ff : out STD_LOGIC;
    rx_edh_anc : out STD_LOGIC;
    rx_edh_ap_flags : out STD_LOGIC_VECTOR ( 4 downto 0 );
    rx_edh_ff_flags : out STD_LOGIC_VECTOR ( 4 downto 0 );
    rx_edh_anc_flags : out STD_LOGIC_VECTOR ( 4 downto 0 );
    rx_edh_packet_flags : out STD_LOGIC_VECTOR ( 3 downto 0 );
    rx_edh_errcnt : out STD_LOGIC_VECTOR ( 15 downto 0 );
    tx_rst : in STD_LOGIC;
    tx_usrclk : in STD_LOGIC;
    tx_ce : in STD_LOGIC_VECTOR ( 2 downto 0 );
    tx_din_rdy : in STD_LOGIC;
    tx_mode : in STD_LOGIC_VECTOR ( 1 downto 0 );
    tx_level_b_3g : in STD_LOGIC;
    tx_insert_crc : in STD_LOGIC;
    tx_insert_ln : in STD_LOGIC;
    tx_insert_edh : in STD_LOGIC;
    tx_insert_vpid : in STD_LOGIC;
    tx_overwrite_vpid : in STD_LOGIC;
    tx_video_a_y_in : in STD_LOGIC_VECTOR ( 9 downto 0 );
    tx_video_a_c_in : in STD_LOGIC_VECTOR ( 9 downto 0 );
    tx_video_b_y_in : in STD_LOGIC_VECTOR ( 9 downto 0 );
    tx_video_b_c_in : in STD_LOGIC_VECTOR ( 9 downto 0 );
    tx_line_a : in STD_LOGIC_VECTOR ( 10 downto 0 );
    tx_line_b : in STD_LOGIC_VECTOR ( 10 downto 0 );
    tx_vpid_byte1 : in STD_LOGIC_VECTOR ( 7 downto 0 );
    tx_vpid_byte2 : in STD_LOGIC_VECTOR ( 7 downto 0 );
    tx_vpid_byte3 : in STD_LOGIC_VECTOR ( 7 downto 0 );
    tx_vpid_byte4a : in STD_LOGIC_VECTOR ( 7 downto 0 );
    tx_vpid_byte4b : in STD_LOGIC_VECTOR ( 7 downto 0 );
    tx_vpid_line_f1 : in STD_LOGIC_VECTOR ( 10 downto 0 );
    tx_vpid_line_f2 : in STD_LOGIC_VECTOR ( 10 downto 0 );
    tx_vpid_line_f2_en : in STD_LOGIC;
    tx_ds1a_out : out STD_LOGIC_VECTOR ( 9 downto 0 );
    tx_ds2a_out : out STD_LOGIC_VECTOR ( 9 downto 0 );
    tx_ds1b_out : out STD_LOGIC_VECTOR ( 9 downto 0 );
    tx_ds2b_out : out STD_LOGIC_VECTOR ( 9 downto 0 );
    tx_use_dsin : in STD_LOGIC;
    tx_ds1a_in : in STD_LOGIC_VECTOR ( 9 downto 0 );
    tx_ds2a_in : in STD_LOGIC_VECTOR ( 9 downto 0 );
    tx_ds1b_in : in STD_LOGIC_VECTOR ( 9 downto 0 );
    tx_ds2b_in : in STD_LOGIC_VECTOR ( 9 downto 0 );
    tx_sd_bitrep_bypass : in STD_LOGIC;
    tx_txdata : out STD_LOGIC_VECTOR ( 19 downto 0 );
    tx_ce_align_err : out STD_LOGIC
  );

end smpte_sdi;

architecture stub of smpte_sdi is
attribute syn_black_box : boolean;
attribute black_box_pad_pin : string;
attribute syn_black_box of stub : architecture is true;
attribute black_box_pad_pin of stub : architecture is "rx_rst,rx_usrclk,rx_data_in[19:0],rx_sd_data_in[9:0],rx_sd_data_strobe,rx_frame_en,rx_mode_en[2:0],rx_mode[1:0],rx_mode_hd,rx_mode_sd,rx_mode_3g,rx_mode_detect_en,rx_mode_locked,rx_forced_mode[1:0],rx_bit_rate,rx_t_locked,rx_t_family[3:0],rx_t_rate[3:0],rx_t_scan,rx_level_b_3g,rx_ce_sd,rx_nsp,rx_line_a[10:0],rx_a_vpid[31:0],rx_a_vpid_valid,rx_b_vpid[31:0],rx_b_vpid_valid,rx_crc_err_a,rx_ds1a[9:0],rx_ds2a[9:0],rx_eav,rx_sav,rx_trs,rx_line_b[10:0],rx_dout_rdy_3g,rx_crc_err_b,rx_ds1b[9:0],rx_ds2b[9:0],rx_edh_errcnt_en[15:0],rx_edh_clr_errcnt,rx_edh_ap,rx_edh_ff,rx_edh_anc,rx_edh_ap_flags[4:0],rx_edh_ff_flags[4:0],rx_edh_anc_flags[4:0],rx_edh_packet_flags[3:0],rx_edh_errcnt[15:0],tx_rst,tx_usrclk,tx_ce[2:0],tx_din_rdy,tx_mode[1:0],tx_level_b_3g,tx_insert_crc,tx_insert_ln,tx_insert_edh,tx_insert_vpid,tx_overwrite_vpid,tx_video_a_y_in[9:0],tx_video_a_c_in[9:0],tx_video_b_y_in[9:0],tx_video_b_c_in[9:0],tx_line_a[10:0],tx_line_b[10:0],tx_vpid_byte1[7:0],tx_vpid_byte2[7:0],tx_vpid_byte3[7:0],tx_vpid_byte4a[7:0],tx_vpid_byte4b[7:0],tx_vpid_line_f1[10:0],tx_vpid_line_f2[10:0],tx_vpid_line_f2_en,tx_ds1a_out[9:0],tx_ds2a_out[9:0],tx_ds1b_out[9:0],tx_ds2b_out[9:0],tx_use_dsin,tx_ds1a_in[9:0],tx_ds2a_in[9:0],tx_ds1b_in[9:0],tx_ds2b_in[9:0],tx_sd_bitrep_bypass,tx_txdata[19:0],tx_ce_align_err";
attribute X_CORE_INFO : string;
attribute X_CORE_INFO of stub : architecture is "v_smpte_sdi_v3_0_8,Vivado 2018.3";
begin
end;

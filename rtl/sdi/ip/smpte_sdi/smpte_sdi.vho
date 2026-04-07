-- (c) Copyright 1995-2026 Xilinx, Inc. All rights reserved.
-- 
-- This file contains confidential and proprietary information
-- of Xilinx, Inc. and is protected under U.S. and
-- international copyright and other intellectual property
-- laws.
-- 
-- DISCLAIMER
-- This disclaimer is not a license and does not grant any
-- rights to the materials distributed herewith. Except as
-- otherwise provided in a valid license issued to you by
-- Xilinx, and to the maximum extent permitted by applicable
-- law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
-- WITH ALL FAULTS, AND XILINX HEREBY DISCLAIMS ALL WARRANTIES
-- AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
-- BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
-- INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
-- (2) Xilinx shall not be liable (whether in contract or tort,
-- including negligence, or under any other theory of
-- liability) for any loss or damage of any kind or nature
-- related to, arising under or in connection with these
-- materials, including for any direct, or any indirect,
-- special, incidental, or consequential loss or damage
-- (including loss of data, profits, goodwill, or any type of
-- loss or damage suffered as a result of any action brought
-- by a third party) even if such damage or loss was
-- reasonably foreseeable or Xilinx had been advised of the
-- possibility of the same.
-- 
-- CRITICAL APPLICATIONS
-- Xilinx products are not designed or intended to be fail-
-- safe, or for use in any application requiring fail-safe
-- performance, such as life-support or safety devices or
-- systems, Class III medical devices, nuclear facilities,
-- applications related to the deployment of airbags, or any
-- other applications that could lead to death, personal
-- injury, or severe property or environmental damage
-- (individually and collectively, "Critical
-- Applications"). Customer assumes the sole risk and
-- liability of any use of Xilinx products in Critical
-- Applications, subject only to applicable laws and
-- regulations governing limitations on product liability.
-- 
-- THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
-- PART OF THIS FILE AT ALL TIMES.
-- 
-- DO NOT MODIFY THIS FILE.

-- IP VLNV: xilinx.com:ip:v_smpte_sdi:3.0
-- IP Revision: 8

-- The following code must appear in the VHDL architecture header.

------------- Begin Cut here for COMPONENT Declaration ------ COMP_TAG
COMPONENT smpte_sdi
  PORT (
    rx_rst : IN STD_LOGIC;
    rx_usrclk : IN STD_LOGIC;
    rx_data_in : IN STD_LOGIC_VECTOR(19 DOWNTO 0);
    rx_sd_data_in : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
    rx_sd_data_strobe : IN STD_LOGIC;
    rx_frame_en : IN STD_LOGIC;
    rx_mode_en : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
    rx_mode : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
    rx_mode_hd : OUT STD_LOGIC;
    rx_mode_sd : OUT STD_LOGIC;
    rx_mode_3g : OUT STD_LOGIC;
    rx_mode_detect_en : IN STD_LOGIC;
    rx_mode_locked : OUT STD_LOGIC;
    rx_forced_mode : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
    rx_bit_rate : IN STD_LOGIC;
    rx_t_locked : OUT STD_LOGIC;
    rx_t_family : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
    rx_t_rate : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
    rx_t_scan : OUT STD_LOGIC;
    rx_level_b_3g : OUT STD_LOGIC;
    rx_ce_sd : OUT STD_LOGIC;
    rx_nsp : OUT STD_LOGIC;
    rx_line_a : OUT STD_LOGIC_VECTOR(10 DOWNTO 0);
    rx_a_vpid : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    rx_a_vpid_valid : OUT STD_LOGIC;
    rx_b_vpid : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    rx_b_vpid_valid : OUT STD_LOGIC;
    rx_crc_err_a : OUT STD_LOGIC;
    rx_ds1a : OUT STD_LOGIC_VECTOR(9 DOWNTO 0);
    rx_ds2a : OUT STD_LOGIC_VECTOR(9 DOWNTO 0);
    rx_eav : OUT STD_LOGIC;
    rx_sav : OUT STD_LOGIC;
    rx_trs : OUT STD_LOGIC;
    rx_line_b : OUT STD_LOGIC_VECTOR(10 DOWNTO 0);
    rx_dout_rdy_3g : OUT STD_LOGIC;
    rx_crc_err_b : OUT STD_LOGIC;
    rx_ds1b : OUT STD_LOGIC_VECTOR(9 DOWNTO 0);
    rx_ds2b : OUT STD_LOGIC_VECTOR(9 DOWNTO 0);
    rx_edh_errcnt_en : IN STD_LOGIC_VECTOR(15 DOWNTO 0);
    rx_edh_clr_errcnt : IN STD_LOGIC;
    rx_edh_ap : OUT STD_LOGIC;
    rx_edh_ff : OUT STD_LOGIC;
    rx_edh_anc : OUT STD_LOGIC;
    rx_edh_ap_flags : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
    rx_edh_ff_flags : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
    rx_edh_anc_flags : OUT STD_LOGIC_VECTOR(4 DOWNTO 0);
    rx_edh_packet_flags : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
    rx_edh_errcnt : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    tx_rst : IN STD_LOGIC;
    tx_usrclk : IN STD_LOGIC;
    tx_ce : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
    tx_din_rdy : IN STD_LOGIC;
    tx_mode : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
    tx_level_b_3g : IN STD_LOGIC;
    tx_insert_crc : IN STD_LOGIC;
    tx_insert_ln : IN STD_LOGIC;
    tx_insert_edh : IN STD_LOGIC;
    tx_insert_vpid : IN STD_LOGIC;
    tx_overwrite_vpid : IN STD_LOGIC;
    tx_video_a_y_in : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
    tx_video_a_c_in : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
    tx_video_b_y_in : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
    tx_video_b_c_in : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
    tx_line_a : IN STD_LOGIC_VECTOR(10 DOWNTO 0);
    tx_line_b : IN STD_LOGIC_VECTOR(10 DOWNTO 0);
    tx_vpid_byte1 : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
    tx_vpid_byte2 : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
    tx_vpid_byte3 : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
    tx_vpid_byte4a : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
    tx_vpid_byte4b : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
    tx_vpid_line_f1 : IN STD_LOGIC_VECTOR(10 DOWNTO 0);
    tx_vpid_line_f2 : IN STD_LOGIC_VECTOR(10 DOWNTO 0);
    tx_vpid_line_f2_en : IN STD_LOGIC;
    tx_ds1a_out : OUT STD_LOGIC_VECTOR(9 DOWNTO 0);
    tx_ds2a_out : OUT STD_LOGIC_VECTOR(9 DOWNTO 0);
    tx_ds1b_out : OUT STD_LOGIC_VECTOR(9 DOWNTO 0);
    tx_ds2b_out : OUT STD_LOGIC_VECTOR(9 DOWNTO 0);
    tx_use_dsin : IN STD_LOGIC;
    tx_ds1a_in : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
    tx_ds2a_in : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
    tx_ds1b_in : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
    tx_ds2b_in : IN STD_LOGIC_VECTOR(9 DOWNTO 0);
    tx_sd_bitrep_bypass : IN STD_LOGIC;
    tx_txdata : OUT STD_LOGIC_VECTOR(19 DOWNTO 0);
    tx_ce_align_err : OUT STD_LOGIC
  );
END COMPONENT;
-- COMP_TAG_END ------ End COMPONENT Declaration ------------

-- The following code must appear in the VHDL architecture
-- body. Substitute your own instance name and net names.

------------- Begin Cut here for INSTANTIATION Template ----- INST_TAG
your_instance_name : smpte_sdi
  PORT MAP (
    rx_rst => rx_rst,
    rx_usrclk => rx_usrclk,
    rx_data_in => rx_data_in,
    rx_sd_data_in => rx_sd_data_in,
    rx_sd_data_strobe => rx_sd_data_strobe,
    rx_frame_en => rx_frame_en,
    rx_mode_en => rx_mode_en,
    rx_mode => rx_mode,
    rx_mode_hd => rx_mode_hd,
    rx_mode_sd => rx_mode_sd,
    rx_mode_3g => rx_mode_3g,
    rx_mode_detect_en => rx_mode_detect_en,
    rx_mode_locked => rx_mode_locked,
    rx_forced_mode => rx_forced_mode,
    rx_bit_rate => rx_bit_rate,
    rx_t_locked => rx_t_locked,
    rx_t_family => rx_t_family,
    rx_t_rate => rx_t_rate,
    rx_t_scan => rx_t_scan,
    rx_level_b_3g => rx_level_b_3g,
    rx_ce_sd => rx_ce_sd,
    rx_nsp => rx_nsp,
    rx_line_a => rx_line_a,
    rx_a_vpid => rx_a_vpid,
    rx_a_vpid_valid => rx_a_vpid_valid,
    rx_b_vpid => rx_b_vpid,
    rx_b_vpid_valid => rx_b_vpid_valid,
    rx_crc_err_a => rx_crc_err_a,
    rx_ds1a => rx_ds1a,
    rx_ds2a => rx_ds2a,
    rx_eav => rx_eav,
    rx_sav => rx_sav,
    rx_trs => rx_trs,
    rx_line_b => rx_line_b,
    rx_dout_rdy_3g => rx_dout_rdy_3g,
    rx_crc_err_b => rx_crc_err_b,
    rx_ds1b => rx_ds1b,
    rx_ds2b => rx_ds2b,
    rx_edh_errcnt_en => rx_edh_errcnt_en,
    rx_edh_clr_errcnt => rx_edh_clr_errcnt,
    rx_edh_ap => rx_edh_ap,
    rx_edh_ff => rx_edh_ff,
    rx_edh_anc => rx_edh_anc,
    rx_edh_ap_flags => rx_edh_ap_flags,
    rx_edh_ff_flags => rx_edh_ff_flags,
    rx_edh_anc_flags => rx_edh_anc_flags,
    rx_edh_packet_flags => rx_edh_packet_flags,
    rx_edh_errcnt => rx_edh_errcnt,
    tx_rst => tx_rst,
    tx_usrclk => tx_usrclk,
    tx_ce => tx_ce,
    tx_din_rdy => tx_din_rdy,
    tx_mode => tx_mode,
    tx_level_b_3g => tx_level_b_3g,
    tx_insert_crc => tx_insert_crc,
    tx_insert_ln => tx_insert_ln,
    tx_insert_edh => tx_insert_edh,
    tx_insert_vpid => tx_insert_vpid,
    tx_overwrite_vpid => tx_overwrite_vpid,
    tx_video_a_y_in => tx_video_a_y_in,
    tx_video_a_c_in => tx_video_a_c_in,
    tx_video_b_y_in => tx_video_b_y_in,
    tx_video_b_c_in => tx_video_b_c_in,
    tx_line_a => tx_line_a,
    tx_line_b => tx_line_b,
    tx_vpid_byte1 => tx_vpid_byte1,
    tx_vpid_byte2 => tx_vpid_byte2,
    tx_vpid_byte3 => tx_vpid_byte3,
    tx_vpid_byte4a => tx_vpid_byte4a,
    tx_vpid_byte4b => tx_vpid_byte4b,
    tx_vpid_line_f1 => tx_vpid_line_f1,
    tx_vpid_line_f2 => tx_vpid_line_f2,
    tx_vpid_line_f2_en => tx_vpid_line_f2_en,
    tx_ds1a_out => tx_ds1a_out,
    tx_ds2a_out => tx_ds2a_out,
    tx_ds1b_out => tx_ds1b_out,
    tx_ds2b_out => tx_ds2b_out,
    tx_use_dsin => tx_use_dsin,
    tx_ds1a_in => tx_ds1a_in,
    tx_ds2a_in => tx_ds2a_in,
    tx_ds1b_in => tx_ds1b_in,
    tx_ds2b_in => tx_ds2b_in,
    tx_sd_bitrep_bypass => tx_sd_bitrep_bypass,
    tx_txdata => tx_txdata,
    tx_ce_align_err => tx_ce_align_err
  );
-- INST_TAG_END ------ End INSTANTIATION Template ---------

-- You must compile the wrapper file smpte_sdi.vhd when simulating
-- the core, smpte_sdi. When compiling the wrapper file, be sure to
-- reference the VHDL simulation library.


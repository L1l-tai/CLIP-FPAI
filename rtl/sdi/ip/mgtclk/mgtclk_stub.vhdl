-- Copyright 1986-2018 Xilinx, Inc. All Rights Reserved.
-- --------------------------------------------------------------------------------
-- Tool Version: Vivado v.2018.3 (win64) Build 2405991 Thu Dec  6 23:38:27 MST 2018
-- Date        : Sun Apr  5 16:42:34 2026
-- Host        : Normalcy running 64-bit major release  (build 9200)
-- Command     : write_vhdl -force -mode synth_stub
--               C:/Users/norma/Desktop/CICC/demo/30tai_fpga_demo/20260326/fpai_demo_src_vivado/rtl/sdi/ip/mgtclk/mgtclk_stub.vhdl
-- Design      : mgtclk
-- Purpose     : Stub declaration of top-level module interface
-- Device      : xc7z030ffg676-2
-- --------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity mgtclk is
  Port ( 
    clk_out1 : out STD_LOGIC;
    locked : out STD_LOGIC;
    clk_in1 : in STD_LOGIC
  );

end mgtclk;

architecture stub of mgtclk is
attribute syn_black_box : boolean;
attribute black_box_pad_pin : string;
attribute syn_black_box of stub : architecture is true;
attribute black_box_pad_pin of stub : architecture is "clk_out1,locked,clk_in1";
begin
end;

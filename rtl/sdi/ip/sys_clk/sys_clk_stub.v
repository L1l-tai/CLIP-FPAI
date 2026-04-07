// Copyright 1986-2018 Xilinx, Inc. All Rights Reserved.
// --------------------------------------------------------------------------------
// Tool Version: Vivado v.2018.3 (win64) Build 2405991 Thu Dec  6 23:38:27 MST 2018
// Date        : Mon Mar 23 14:58:53 2026
// Host        : DESKTOP-7CRHBA3 running 64-bit major release  (build 9200)
// Command     : write_verilog -force -mode synth_stub
//               D:/project/sfweng/fpai_demo/fpai_demo.srcs/rtl/sdi/ip/sys_clk/sys_clk_stub.v
// Design      : sys_clk
// Purpose     : Stub declaration of top-level module interface
// Device      : xc7z030ffg676-2
// --------------------------------------------------------------------------------

// This empty module with port declaration file causes synthesis tools to infer a black box for IP.
// The synthesis directives are for Synopsys Synplify support to prevent IO buffer insertion.
// Please paste the declaration into a Verilog source file or add the file as an additional source.
module sys_clk(clk_out1, locked, clk_in1)
/* synthesis syn_black_box black_box_pad_pin="clk_out1,locked,clk_in1" */;
  output clk_out1;
  output locked;
  input clk_in1;
endmodule

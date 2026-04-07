// (c) Copyright 2011 - 2014 Xilinx, Inc. All rights reserved.
//
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
//------------------------------------------------------------------------------
//   ____  ____
//  /   /\/   /
// /___/  \  /    Vendor: Xilinx
// \   \   \/     Version: $Revision: #1 $
//  \   \
//  /   /         Filename: $File: //Groups/video_ip/demos/K7/xapp592_k7_sdi_demos_ver2/kc705_sdi_demo/kc705_sdi_demo.v $
// /___/   /\     Timestamp: $DateTime: 2014/03/13 12:31:24 $
// \   \  /  \
//  \___\/\___\
//
// Description:
//      This is the top level module for the Quad SDI demo for Kintex-7 GTX
//      transceivers. It runs on the KC705 board + inrevium TB-FMCH-3GSDI2A FMC
//      mezzanine card.
//------------------------------------------------------------------------------
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

`timescale 1ns / 1ps
   
module rx_sdi (
// MGTs
    output             FMC_HPC_DP0_C2M_N          , // FMC HPC GTX0 TX 差分负端 (Controller to Module)
    output             FMC_HPC_DP0_C2M_P          , // FMC HPC GTX0 TX 差分正端 (Controller to Module)
    input              FMC_HPC_DP0_M2C_N          , // FMC HPC GTX0 RX 差分负端 (Module to Controller)
    input              FMC_HPC_DP0_M2C_P          , // FMC HPC GTX0 RX 差分正端 (Module to Controller)
// MGT REFCLKs
    input              FMC_HPC_GBTCLK0_M2C_C_N    ,   // FMC HPC GTX0 参考时钟差分负端 (156.25MHz)
    input              FMC_HPC_GBTCLK0_M2C_C_P    ,   // FMC HPC GTX0 参考时钟差分正端 (156.25MHz)

    //input              sys_diff_clock_clk_n       ,   //200M
    //input              sys_diff_clock_clk_p       , 
    input              sys_clk_200m               ,   // 系统输入时钟 (200MHz)
    
    output             led1                       , // LED1 指示信号 (通常指示用户时钟活动或状态)
    output             led2                       , // LED2 指示信号 (通常指示参考时钟PLL锁定状态)
    output             led3                       , // LED3 指示信号 (通常指示SDI RX链路锁定状态)
    output             cam_hs                     , // 摄像头/视频输出行同步信号 (HSYNC)
    output             cam_vs                     , // 摄像头/视频输出场同步信号 (VSYNC)
    output    [23:0]   cam_rgb                    , // 摄像头/视频输出RGB888数据总线 [23:0]
    output             cam_clk                    , // 摄像头/视频输出像素时钟
    output             cam_data_en                , // 摄像头/视频输出数据有效使能信号
   
    input              rx_gtx_full_reset_n        , // SDI GTX 全局复位信号 (低电平有效)
    input              rx_gtx_reset_n             // SDI GTX 模块复位信号 (低电平有效)

);

		
//
// Set this parameter to "TRUE" to use ChipScope to control and monitor the demo.
// Set this parameter to "FALSE" to use Vivado Analyzer to control and monitor
// the demo.
//
parameter USE_CHIPSCOPE = "FALSE";

//------------------------------------------------------------------------------
// Internal signals definitions

// Global signals
//wire        clk_27M;
wire        rx_usrclk;
wire        mgtclk_156_25;
wire        mgtclk_156_25_bufg;
wire        mgtclk_148_5;
wire        qplllock;
wire        qpllclk;
wire        qpllrefclk;
wire        qpllreset;
wire        cpll0lock;

// TX0 signals
wire        tx0_usrclk;
wire        tx0_slew;
wire        tx0_userrdy;

// RX0 signals
wire        rx0_locked;
wire [1:0]  rx0_mode;
wire        rx0_level_b;
wire [3:0]  rx0_t_family;
wire [3:0]  rx0_t_rate;
wire        rx0_t_scan;
wire        rx0_m;
wire        _2s_flag;

wire [35:0] control1;
wire [35:0] control2;
wire [35:0] control3;

(*keep = "true"*) wire locked1;
(*keep = "true"*) wire locked2;
wire [15:0] _200MHz_SYSCLK_o;          
wire [15:0] _148_5_USERCLK_o;   
wire [15:0] rx_usrclk_o ;  
//wire        sys_clock_out;  
//wire        sys_clock_bufg; 
wire [ 9:0] rx_ds1a ;
wire [ 9:0] rx_ds2a ;
 wire        rx_eav  ;
 wire        rx_sav  ; 
wire [7:0] img_red;
wire [7:0] img_green;
wire [7:0] img_blue;
wire [7:0] img_Y;
wire [7:0] img_CbCr;
wire       YCbCr422_vsync;
wire       YCbCr422_hsync;
wire       YCbCr422_clken;  
wire       YCbCr422_data_en;
wire       clk_27M;

//// SYSCLK
//IBUFDS IBUFDS_inst_sys_clock(
//	.O(sys_clock_out), // Buffer output
//	.I(sys_diff_clock_clk_p), // Diff_p buffer input (connect directly to top-level port)
//	.IB(sys_diff_clock_clk_n)); // Diff_n buffer input (connect directly to top-level port)
//
//BUFG BUFG_inst_sys_clock (
//      .O(sys_clock_bufg), // 1-bit output: Clock output
//      .I(sys_clock_out));


//sysclk
sys_clk sys_clk_inst0
   (// Clock in ports
    .clk_in1(sys_clk_200m),      // IN
    // Clock out ports
    .clk_out1(clk_27M),     // OUT
    // Status and control signals
    .locked(locked1));      // OUT
// INST_TAG_END ------ End INSTANTIATION Template ---------


// 148.5 MHz MGT reference clock input from the FMC SDI mezzanine board.
//(* LOC = "IBUFDS_GTE2_X0Y6" *)
IBUFDS_GTE2 MGTCLKIN0 (
    .I          (FMC_HPC_GBTCLK0_M2C_C_P),
    .IB         (FMC_HPC_GBTCLK0_M2C_C_N),
    .CEB        (1'b0),
    .O          (mgtclk_156_25),
    .ODIV2      ());

BUFG BUFG125M (
    .I          (mgtclk_156_25),
    .O          (mgtclk_156_25_bufg));

mgtclk mgtclk_inst0
   (
    // Clock out ports
    .clk_out1(mgtclk_148_5),     // output clk_out1
    // Status and control signals
    .locked(locked2),       // output locked
   // Clock in ports
    .clk_in1(mgtclk_156_25_bufg));    // input clk_in1
assign led2 = locked2;

//------------------------------------------------------------------------------
// SDI RX/TX modules
//
k7_sdi_rxtx #(
    .USE_CHIPSCOPE      (USE_CHIPSCOPE))
SDI0 (
    .clk                (clk_27M),
    .tx_refclk_stable   (1'b1),
    .tx_plllock         (cpll0lock),
    .tx_slew            (tx0_slew),
    .tx_txen            (),
    .rx_refclk_stable   (locked2),
    .qpll_lock          (qplllock),
    .qpll_reset         (qpllreset),        // SDI0 is the QPLL master and resets the QPLL
    .rx_locked          (rx0_locked),
    .rx_mode            (rx0_mode),
    .rx_level_b         (rx0_level_b),
    .rx_t_family        (rx0_t_family),
    .rx_t_rate          (rx0_t_rate),
    .rx_t_scan          (rx0_t_scan),
    .rx_m               (rx0_m),
    .drpclk             (clk_27M),
    .cpll_refclk        (mgtclk_148_5),
    .txp                (FMC_HPC_DP0_C2M_P),
    .txn                (FMC_HPC_DP0_C2M_N),
    .rxp                (FMC_HPC_DP0_M2C_P),
    .rxn                (FMC_HPC_DP0_M2C_N),
    .qpll_clk           (qpllclk),
    .qpll_refclk        (qpllrefclk),
    .control0           (control1),
    .control1           (control2),
    .control2           (control3),
    .rx_ds1a            (rx_ds1a),
    .rx_ds2a            (rx_ds2a),
    .rx_eav             (rx_eav),
    .rx_sav             (rx_sav),    
    .rx_gtx_full_reset  ((~rx_gtx_full_reset_n) | (_2s_flag)),
    .rx_gtx_reset       ((~rx_gtx_reset_n) | (_2s_flag)),
    .rx_usrclk          (rx_usrclk)    
    );
    assign led3 = rx0_locked;

    reg  [25:0] rx_usrclk_cnt;
    always @(posedge rx_usrclk) begin
        if(rx_gtx_full_reset_n==1'b0)
            rx_usrclk_cnt <= 'd0;
        else 
            rx_usrclk_cnt <= rx_usrclk_cnt + 1'b1;               
    end
    assign led1 = rx_usrclk_cnt[25];
    
    reg  [27:0] _2s_cnt;
    always @(posedge clk_27M) begin
        if(rx_gtx_reset_n==1'b0)
            _2s_cnt <= 'd0;
        else if(_2s_cnt==28'd54000000)
            _2s_cnt <= _2s_cnt;   
        else if(locked1)     
            _2s_cnt <= _2s_cnt + 1'b1;               
    end    
    
    assign _2s_flag = (_2s_cnt==28'd54000000-1'b1);
//
// GTXE2_COMMON wrapper
// This wrapper contains the QPLL for the GTX Quad. All GTX transceivers used are
// in the same Quad, so only one GTXE2_COMMON block is required for this demo.
//
k7gtx_sdi_wrapper_common #(
    .WRAPPER_SIM_GTRESET_SPEEDUP    ("FALSE"))
gtxe2_common_0 (
    .GTGREFCLK_IN                   (1'b0),
    .GTNORTHREFCLK0_IN              (1'b0),
    .GTNORTHREFCLK1_IN              (1'b0),
    .GTREFCLK0_IN                   (mgtclk_148_5),
    .GTREFCLK1_IN                   (1'b0),
    .GTSOUTHREFCLK0_IN              (1'b0),
    .GTSOUTHREFCLK1_IN              (1'b0),
    .QPLLLOCK_OUT                   (qplllock),
    .QPLLLOCKDETCLK_IN              (clk_27M),
    .QPLLOUTCLK_OUT                 (qpllclk),
    .QPLLOUTREFCLK_OUT              (qpllrefclk),
    .QPLLREFCLKLOST_OUT             (),
    .QPLLRESET_IN                   (qpllreset));

/*
ibert_freq_counter freq_counter1
  (.FREQ_CNT_O (_200MHz_SYSCLK_o),
   .RST_I (~rx_gtx_full_reset_n),
   .TEST_TERM_CNT_I (16'h4000),
   .REF_CLK_I (sys_clk_200m),
   .TEST_CLK_I (sys_clk_200m)
	);
	
ibert_freq_counter freq_counter2
  (.FREQ_CNT_O (_148_5_USERCLK_o),
   .RST_I (~rx_gtx_full_reset_n),
   .TEST_TERM_CNT_I (16'h4000),
   .REF_CLK_I (sys_clk_200m),
   .TEST_CLK_I (mgtclk_148_5)
	);	
	
ibert_freq_counter freq_counter3
  (.FREQ_CNT_O (rx_usrclk_o),
   .RST_I (~rx_gtx_full_reset_n),
   .TEST_TERM_CNT_I (16'h4000),
   .REF_CLK_I (sys_clk_200m),
   .TEST_CLK_I (rx_usrclk)
	);
		
vio_0 VIO_INST
(
  .clk         (sys_clk_200m), //200MHz
  .probe_in0   (_148_5_USERCLK_o),//148.5MHz
  .probe_in1   (_200MHz_SYSCLK_o),//200MHz
  .probe_in2   (rx_usrclk_o)//74.25MHz
);
*/    
//========================================================
frame_convertor frame_convertor_u0(
    .rx_eav          ( rx_eav             ),                 //The EAV exists at the end of each video data block
    .rx_sav          ( rx_sav             ),                 //The SAV exists at the beginning of each video data block
    .rx_t_locked     ( rx0_locked         ),
    .rx_t_family     ( rx0_t_family       ),
               
    .rx_ds1a         ( rx_ds1a            ),
    .rx_ds2a         ( rx_ds2a            ),
    .rx_clken        ( rx0_locked         ),
      
    .YCbCr422_vsync  ( YCbCr422_vsync     ),
    .YCbCr422_hsync  ( YCbCr422_hsync     ),
    .YCbCr422_clken  ( YCbCr422_clken     ),
     
    .img_Y           ( img_Y              ),      
    .img_CbCr        ( img_CbCr           ),                           
               
    .clk             ( rx_usrclk          ),
    .rst_n           ( rx_gtx_full_reset_n)   

);
assign YCbCr422_data_en = YCbCr422_vsync & YCbCr422_hsync ;

YCbCr422_2_RGB888 YCbCr422_2_RGB888_u0(   
    //CMOS YCbCr422 data input
    .YCbCr422_vsync  (YCbCr422_vsync      ),   //Prepared Image data vsync valid signal
    .YCbCr422_hsync  (YCbCr422_hsync      ),   //Prepared Image data hsync vaild signal
    .YCbCr422_data_en(YCbCr422_data_en    ),  
    .img_Y           (img_Y               ),   //Prepared Image data of Y
    .img_CbCr        (img_CbCr            ),   //Prepared Image data of CbCr

    //CMOS RGB888 data output
    .RGB888_vsync    (cam_vs              ),   //Processed Image data vsync valid signal
    .RGB888_hsync    (cam_hs              ),   //Processed Image data hsync vaild signal
    .RGB888_data_en  (cam_data_en         ),  
    .img_red         (img_red             ),   //Prepared Image green data to be processed
    .img_green       (img_green           ),   //Prepared Image green data to be processed
    .img_blue        (img_blue            ),   //Prepared Image blue data to be processed
     
    .clk             (rx_usrclk           ),   //cmos video pixel clock
    .rst_n           (rx_gtx_full_reset_n )    //global reset
);

assign cam_rgb = {img_red,img_green,img_blue};
assign cam_clk = rx0_locked ? rx_usrclk : sys_clk_200m;
endmodule

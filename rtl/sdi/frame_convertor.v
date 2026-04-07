//==============================================================================
// Orgnization   : Shanghai Fudan Microelectronics Co., Ltd. Confidential
// File Name     : frame_convertor.v
// Author        : wangrui
// Project       : NB2014
// Create Date   : 2021.07.07
// Description   :
// -             : 
//------------------------------------------------------------------------------
// Modification History :
// Rev     Date         Who          Description
//==============================================================================
module frame_convertor(
    input                             rx_eav     ,                 //The EAV exists at the end of each video data block
    input                             rx_sav     ,                 //The SAV exists at the beginning of each video data block
    input                             rx_t_locked,                 // transport format detection locked
    input        [  3 : 0]            rx_t_family,                 // transport format family
                   
    input        [  9 : 0]            rx_ds1a ,
    input        [  9 : 0]            rx_ds2a ,
    input                             rx_clken,
 
    output reg                        YCbCr422_vsync,
    output                            YCbCr422_hsync,
    output                            YCbCr422_clken,

    output       [  7 : 0]            img_Y   ,      
    output       [  7 : 0]            img_CbCr,                           
       
    input                             clk     ,
    input                             rst_n

);

   
    reg                        YCbCr422_hsync_tmp;
    reg          [  3 : 0]     YCbCr422_hsync_r  ;
    reg          [  3 : 0]     rx_clken_r        ;
    reg          [  11: 0]     hcnt              ;
                           reg          [  11: 0]     hend              ;
                           wire         [   3: 0]     rx_family         ;
    assign rx_family = rx_t_locked ? rx_t_family : 4'h0;

    always @ (*) begin
        case (rx_family)
            4'b0000, 4'b0011 : hend = 12'd1919 ;
            4'b0001          : hend = 12'd1279 ;
            4'b1000, 4'b1001 : hend = 12'd719  ;
            4'b0010          : hend = 12'd2047 ;
            default          : hend = 12'd1919 ;
        endcase
    end 

    //============== generate vsync signal
    always@(posedge clk) begin
        if(rst_n==1'b0)
            YCbCr422_vsync <= 1'b0;
        else if(rx_eav==1'b1) begin
            if(rx_ds1a[7]==1'b1)
                YCbCr422_vsync <= 1'b0;
            else 
                YCbCr422_vsync <= 1'b1;
        end            
    end
    //============== generate hsync signal
    always @(posedge clk) begin
        if(rst_n==1'b0)
            YCbCr422_hsync_tmp <= 1'b0;
//        else if(hcnt==11'd1919)
        else if(hcnt==hend)
            YCbCr422_hsync_tmp <= 1'b0;
        else if(rx_sav==1'b1)
            YCbCr422_hsync_tmp <= 1'b1;
    end

      
    
    always @(posedge clk) begin
        if(rst_n==1'b0)
            hcnt <= 'd0;
//        else if(hcnt==11'd1919)
        else if(hcnt==hend)
            hcnt <= 'd0;
        else if(YCbCr422_hsync_tmp==1'b1)
            hcnt <= hcnt + 1'b1;                       
    end

    
    //========== pipeline =========
    

    always @(posedge clk) begin
        if(rst_n==1'b0)
            YCbCr422_hsync_r <= 'd0;
        else 
            YCbCr422_hsync_r <= {YCbCr422_hsync_r[2:0],YCbCr422_hsync_tmp};               
    end

    assign  YCbCr422_hsync = YCbCr422_hsync_r[3];
    
    always @(posedge clk) begin
        if(rst_n==1'b0)
            rx_clken_r <= 'd0;
        else 
            rx_clken_r <= {rx_clken_r[2:0],rx_clken};               
    end

    assign  YCbCr422_clken = rx_clken_r[3];

    reg         [  7 : 0]       rx_ds1a_d1;
    reg         [  7 : 0]       rx_ds1a_d2;
    reg         [  7 : 0]       rx_ds1a_d3;
    reg         [  7 : 0]       rx_ds1a_d4;   

    always @(posedge clk) begin                    //  rs_ds1a HD-SDI: Y component
        if(rst_n==1'b0)begin
            rx_ds1a_d1 <= 'd0;
            rx_ds1a_d2 <= 'd0;
            rx_ds1a_d3 <= 'd0;
            rx_ds1a_d4 <= 'd0;
        end
        else begin
            rx_ds1a_d1 <= rx_ds1a[9:2]   ;
            rx_ds1a_d2 <= rx_ds1a_d1;
            rx_ds1a_d3 <= rx_ds1a_d2;
            rx_ds1a_d4 <= rx_ds1a_d3;
        end
    end

    assign img_Y = rx_ds1a_d4;

    reg         [  7 : 0]       rx_ds2a_d1;
    reg         [  7 : 0]       rx_ds2a_d2;
    reg         [  7 : 0]       rx_ds2a_d3;
    reg         [  7 : 0]       rx_ds2a_d4;

    always @(posedge clk) begin                    //  rs_ds2a HD-SDI: Interleaved CB and CR components
        if(rst_n==1'b0)begin
            rx_ds2a_d1 <= 'd0;
            rx_ds2a_d2 <= 'd0;
            rx_ds2a_d3 <= 'd0;
            rx_ds2a_d4 <= 'd0;
         end
        else begin 
            rx_ds2a_d1 <= rx_ds2a[9:2];
            rx_ds2a_d2 <= rx_ds2a_d1  ;
            rx_ds2a_d3 <= rx_ds2a_d2  ;
            rx_ds2a_d4 <= rx_ds2a_d3  ;
        end
    end

    assign img_CbCr = rx_ds2a_d4;

    
 



endmodule

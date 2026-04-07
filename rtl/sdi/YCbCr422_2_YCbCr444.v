//==============================================================================
// Orgnization   : Shanghai Fudan Microelectronics Co., Ltd. Confidential
// File Name     : YCbCr422_2_YCbCr444.v
// Author        : wangrui
// Project       : cgs_camara
// Create Date   : 2021.07.06
// Description   :
// -             : 
//------------------------------------------------------------------------------
// Modification History :
// Rev     Date         Who          Description
//==============================================================================

module YCbCr422_2_YCbCr444(	
	input          [  7: 0]      y_i     ,                                                                     //输入视频亮度信号y
	input          [  7: 0]      cbcr_i  ,                                                                     //输入视频色度信号cbcr
	input                        valid_i ,                                                                     //输入视频有效
	input                        hsync_i ,                                                                     //输入视频行同步
	input                        vsync_i ,                                                                     //输入视频场同步

	output         [  7: 0]      y_o     ,                                                                     //输出视频亮度分量y
	output         [  7: 0]      cb_o    ,                                                                     //输出视频Cb分量
	output         [  7: 0]      cr_o    ,                                                                     //输出视频Cr分量
	output reg                   valid_o ,                                                                     //输出视频有效
	output reg                   hsync_o ,                                                                     //输出视频行同步
	output reg                   vsync_o ,                                                                     //输出视频场同步

    input                        clk     ,                                                                     //系统时钟
	input                        rst_n                                                                         //复位信号
);

    reg                          flag ;                                                                        //CbCr分离时标记信号
    reg            [  7: 0]      cbcr_0, cbcr_1, y_r ;

    assign  cb_o = (flag == 1'b0) ? cbcr_0 : cbcr_1;
    assign  cr_o = (flag == 1'b0) ? cbcr_i : cbcr_0;
    assign  y_o = y_r;

    always@(posedge clk) begin
        if(rst_n==1'b0) begin
            valid_o <= 'd0;
    	    hsync_o <= 'd0;
    	    vsync_o <= 'd0;

    	    cbcr_0  <= 'd0;
    	    cbcr_1  <= 'd0;
    	    y_r     <= 'd0;
        end
        else begin
    	    valid_o <= valid_i;
    	    hsync_o <= hsync_i;
    	    vsync_o <= vsync_i;

    	    cbcr_0  <= cbcr_i ;
    	    cbcr_1  <= cbcr_0 ;
    	    y_r     <= y_i    ;
        end
    end

    always@(posedge clk)begin                      
        if(rst_n==1'b0)
            flag <= 1'b0;
        else if(valid_o==1'b1)
            flag <= ~flag;
        else
            flag <= 1'b0;
    end

endmodule




//==============================================================================
// Orgnization   : Shanghai Fudan Microelectronics Co., Ltd. Confidential
// File Name     : YCbCr444_2_RGB888.v
// Author        : wangrui
// Project       : cgs_camara
// Create Date   : 2021.07.06
// Description   :
// -             : 
//------------------------------------------------------------------------------
// Modification History :
// Rev     Date         Who          Description
//==============================================================================

module YCbCr422_2_RGB888(   
    //CMOS YCbCr422 data input
    input                         YCbCr422_vsync  ,       //Prepared Image data vsync valid signal
    input                         YCbCr422_hsync  ,       //Prepared Image data hsync vaild signal
    input                         YCbCr422_data_en,       
    input        [  7 : 0]        img_Y           ,       //Prepared Image data of Y
    input        [  7 : 0]        img_CbCr        ,       //Prepared Image data of CbCr


    //CMOS RGB888 data output
    output                        RGB888_vsync    ,       //Processed Image data vsync valid signal
    output                        RGB888_hsync    ,       //Processed Image data hsync vaild signal
    output                        RGB888_data_en  ,       
    output       [  7 : 0]        img_red         ,       //Prepared Image green data to be processed
    output       [  7 : 0]        img_green       ,       //Prepared Image green data to be processed
    output       [  7 : 0]        img_blue        ,       //Prepared Image blue data to be processed
       
    input                         clk             ,       //cmos video pixel clock
    input                         rst_n                   //global reset
);

        
    wire         [  7 : 0]        YCbCr444_Y    ;   
    wire         [  7 : 0]        YCbCr444_Cb   ;   
    wire         [  7 : 0]        YCbCr444_Cr   ;  

    wire                          YCbCr444_vsync;
    wire                          YCbCr444_hsync;
    wire                          YCbCr444_data_en;
        

    YCbCr422_2_YCbCr444 YCbCr422_2_YCbCr444_u(
        .y_i       (img_Y           ),  
        .cbcr_i    (img_CbCr        ),
        .valid_i   (YCbCr422_data_en),                    
        .hsync_i   (YCbCr422_hsync  ),
        .vsync_i   (YCbCr422_vsync  ),
  
        .y_o       (YCbCr444_Y      ),
        .cb_o      (YCbCr444_Cb     ),
        .cr_o      (YCbCr444_Cr     ),
        .valid_o   (YCbCr444_data_en), 
        .hsync_o   (YCbCr444_hsync  ),
        .vsync_o   (YCbCr444_vsync  ),
  
        .clk       (clk             ),
        .rst_n     (rst_n           )
    );


    YCbCr444_2_RGB888 YCbCr444_2_RGB888_u(
        .per_frame_vsync  (YCbCr444_vsync),
        .per_frame_href   (YCbCr444_hsync),
        .per_frame_clken  (YCbCr444_data_en),
        .per_img_Y        (YCbCr444_Y    ),    
        .per_img_Cb       (YCbCr444_Cb   ),    
        .per_img_Cr       (YCbCr444_Cr   ),
           
        .post_frame_vsync (RGB888_vsync  ),
        .post_frame_href  (RGB888_hsync  ),
        .post_frame_clken (RGB888_data_en  ),
        .post_img_red     (img_red       ),
        .post_img_green   (img_green     ),
        .post_img_blue    (img_blue      ),

        .clk              (clk           ),
        .rst_n            (rst_n         )
    );

/*
ycbcr_to_rgb	ycbcr_to_rgb_u0(
	    .clk              (clk       ) ,
	    .i_y_8b           (YCbCr444_Y    ) ,
	    .i_cb_8b          (YCbCr444_Cb   ) ,
	    .i_cr_8b          (YCbCr444_Cr   ) ,
 
	    .i_h_sync         (YCbCr444_hsync  ) ,
	    .i_v_sync         (YCbCr444_vsync  ) ,
	    .i_data_en        (YCbCr444_data_en ) ,
 
	    .o_r_8b           (img_red    ) ,
	    .o_g_8b           (img_green    ) ,
	    .o_b_8b           (img_blue    ) ,
 
	    .o_h_sync         (RGB888_hsync  ) ,
	    .o_v_sync         (RGB888_vsync  ) ,                                                                                                    
	    .o_data_en        (RGB888_data_en )                                                                                                          
);
*/
endmodule

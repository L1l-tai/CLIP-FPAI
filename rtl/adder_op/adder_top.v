
//==============================================================================
// Orgnization   : Shanghai Fudan Microelectronics Co., Ltd. Confidential
// File Name     : adder_top.v
// Author        :
// Project       : 
// Create Date   : 2021.03.31
// Description   :
// 
//------------------------------------------------------------------------------
// Modification History :
// Rev     Date         Who          Description
// 
//==============================================================================

module adder_top(

  //------------ Register Access interface ------------   
    input        [      31 : 0]   itf_ra_awaddr     , 
    input        [      31 : 0]   itf_ra_awdata     ,
    input                         itf_ra_awvalid    ,
    output                        itf_ra_awready    ,

    input        [      31 : 0]   itf_ra_araddr     ,  
    input                         itf_ra_arvalid    ,
    output                        itf_ra_arready    ,

    output       [      31 : 0]   itf_ra_rdata      ,
    output                        itf_ra_rvalid     ,
    input                         itf_ra_rready     ,
 
  //------------ DMA interface -------------------------
    output       [      31 : 0]   itf_awaddr        ,
    output       [      63 : 0]   itf_awdata        ,
    output                        itf_awvalid       ,
    input                         itf_awready       ,

    output       [      31 : 0]   itf_araddr        ,
    output                        itf_arvalid       ,
    input                         itf_arready       ,

    input        [      63 : 0]   itf_rdata         ,
    input                         itf_rvalid        ,
    output                        itf_rready        ,

    output  reg                   reset_reg         ,

    input                         clk               ,
    input                         ra_clk            ,
    input                         rst_n             ,
    input                         ra_rst_n

);
    localparam RESET_ADDR = 16'h77;

    wire              comp_start ;
    wire              comp_done  ;
    wire   [ 15: 0]   arbase     ;
    wire   [ 15: 0]   arsize     ;
    wire   [ 15: 0]   awbase     ;
    wire   [ 15: 0]   awsize     ;
    wire   [ 63: 0]   comp_data  ; 
    wire              data_valid ; 
    wire              data_ready ; 

    wire              rst_n_1    ;
    wire              ra_rst_n_1 ;
    wire              comp_done_cross;
    wire              comp_start_cross;
 
  reg_ctrl   U_reg_ctrl(
   
          .ra_awaddr     ( itf_ra_awaddr[17:2]    ),  
          .ra_awdata     ( itf_ra_awdata    ),
          .ra_awvalid    ( itf_ra_awvalid   ),
          .ra_awready    ( itf_ra_awready   ),
   
          .ra_araddr     ( itf_ra_araddr[17:2]    ),  
          .ra_arvalid    ( itf_ra_arvalid   ),
          .ra_arready    ( itf_ra_arready   ),
   
          .ra_rdata      ( itf_ra_rdata     ),
          .ra_rvalid     ( itf_ra_rvalid    ),
          .ra_rready     ( itf_ra_rready    ),
   
          .comp_start    ( comp_start       ),
          .comp_done     ( comp_done_cross  ),
   
          .rbase         ( arbase           ),
          .rsize         ( arsize           ),

          .wbase         ( awbase           ),
          .wsize         ( awsize           ),
          
          .rfu_rreg0     ( 32'd0            ),       //read reg;                                            
          .rfu_rreg1     ( 32'd0            ),                                              
          .rfu_rreg2     ( 32'd0            ),                                              
          .rfu_rreg3     ( 32'd0            ),                                              
          .rfu_rreg4     ( 32'd0            ),                                              
          .rfu_rreg5     ( 32'd0            ),                                              
          .rfu_rreg6     ( 32'd0            ),                                              
          .rfu_rreg7     ( 32'd0            ),                                              
          .rfu_rreg8     ( 32'd0            ),                                              
          .rfu_rreg9     ( 32'd0            ),                                              
   
          .rfu_wreg0     (                  ),       //wirte reg;                                      
          .rfu_wreg1     (                  ),                                              
          .rfu_wreg2     (                  ),                                              
          .rfu_wreg3     (                  ),                                              
          .rfu_wreg4     (                  ),                                              
          .rfu_wreg5     (                  ),                                              
          .rfu_wreg6     (                  ),                                              
          .rfu_wreg7     (                  ),                                              
          .rfu_wreg8     (                  ),                                              
          .rfu_wreg9     (                  ),
   
          .clk           ( ra_clk           ),
          .rst_n         ( ra_rst_n_1       )
   
   );

   dma    U_dma(

       .arbase           ( arbase           ),
       .arsize           ( arsize           ),
     
       .awbase           ( awbase           ),
       .awsize           ( awsize           ),
                         
       .araddr           ( itf_araddr       ),
       .arvalid          ( itf_arvalid      ),
       .arready          ( itf_arready      ),

       .comp_data        ( comp_data        ),
       .data_valid       ( data_valid       ),
       .data_ready       ( data_ready       ),
                         
       .awaddr           ( itf_awaddr       ),
       .awdata           ( itf_awdata       ),
       .awvalid          ( itf_awvalid      ),
       .awready          ( itf_awready      ),

       .comp_start       ( comp_start_cross ),

       .clk              ( clk              ),
       .rst_n            ( rst_n_1          )
  );
   
  adder    U_adder(
        .a               ( itf_rdata[31:0]  ),
        .a_valid         ( itf_rvalid       ),
        .a_ready         ( itf_rready       ),

        .sum             ( comp_data        ),
        .sum_valid       ( data_valid       ),
        .sum_ready       ( data_ready       ),

        .arsize          ( arsize           ),
        .comp_done       ( comp_done        ),

        .clk             ( clk              ),
        .rst_n           ( rst_n_1          )
  );

  pulse_cross U0_pulse_cross(
        .a2      (  comp_done_cross  ),
        .clk2    (  ra_clk           ),
        .rst2    (  ~ra_rst_n_1      ),
       
        .rdy1    (                   ),
        .a1      (  comp_done        ),
        .clk1    (  clk              ),
        .rst1    (  ~rst_n_1         )
  );

  pulse_cross U1_pulse_cross(
        .a2      (  comp_start_cross ),
        .clk2    (  clk              ),
        .rst2    (  ~rst_n_1         ),
     
        .rdy1    (                   ),
        .a1      (  comp_start       ),
        .clk1    (  ra_clk           ),
        .rst1    (  ~ra_rst_n_1      )
  );

  always@(posedge clk or negedge ra_rst_n) begin
     if(ra_rst_n==1'b0)
         reset_reg <= #0.1 0;
    else if(itf_ra_awvalid && itf_ra_awready && itf_ra_awaddr[17:2]==RESET_ADDR)
         reset_reg <= #0.1 itf_ra_awdata[0];
 end

 assign  rst_n_1    = (~reset_reg) && rst_n; 
 assign  ra_rst_n_1 = (~reset_reg) && ra_rst_n; 


endmodule

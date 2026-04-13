//================================================================================
// Orgnization   : School of Electronic Science, NUDT
// File Name     : gather_top.v
// Author        : Changtai Lin
// Project       : 
// Create Date   : 2026.04.05
// Description   :
// 
//--------------------------------------------------------------------------------
// Modification History :
// Rev     Date         Who               Description
// 0.5.0   2021.03.31   Changtai Lin      Modify transformation logic of Gather OP
//================================================================================

module gather_top(

  //所有自定义算子的接口都是相同的
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
    output       [      511 : 0]  itf_awdata        ,
    output                        itf_awvalid       ,
    input                         itf_awready       ,

    output       [      31 : 0]   itf_araddr        ,
    output                        itf_arvalid       ,
    input                         itf_arready       ,

    input        [      511 : 0]  itf_rdata         ,
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
    wire   [ 15: 0]   arbase_incdces;
    wire   [ 15: 0]   arsize_incdces;
    wire   [ 15: 0]   arbase_data;
    wire   [ 15: 0]   arsize_data;
    wire   [ 15: 0]   awbase_dout;
    wire   [ 15: 0]   awsize_dout;
    wire   [511: 0]   comp_data  ; 
    wire              data_valid ; 
    wire              data_ready ; 

    wire              rst_n_1    ;
    wire              ra_rst_n_1 ;
    wire              comp_done_cross;
    wire              comp_start_cross;

    // FSM internal signals
    wire              rd_done;
    wire              wr_done;
    wire              addr_gen_valid;
    wire [15:0]       arbase_data_gen;
    wire [15:0]       arsize_data_gen;
    wire [15:0]       awbase_gen;
    wire [15:0]       awsize_gen;
    wire              rd_last_line;
    wire [15:0]       arbase;
    wire [15:0]       arsize;
    wire [15:0]       awbase;
    wire [15:0]       awsize;
    wire              rd_start;
    wire              wr_start;
    wire              rd_indices;
    wire              trans_data;   
    wire              gen_status;

    wire [31:0]       indices_width;
    wire [31:0]       data_width;
 
  /*-------------Regs are controled by runtime application------------*/
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
   
          .rbase1         ( arbase_incdces   ),
          .rsize1         ( arsize_incdces   ),
          .rbase2         ( arbase_data      ),
          .rsize2         ( arsize_data      ),

          .wbase1         ( awbase_dout      ),
          .wsize1         ( awsize_dout      ),
          
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
   
          .rfu_wreg0     ( indices_width    ),       //wirte reg;                                      
          .rfu_wreg1     ( data_width       ),                                              
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

   // Instantiate Gather FSM
   gather_fsm U_gather_fsm (
       .rd_done          ( rd_done          ), // input
       .wr_done          ( wr_done          ), // input
       .comp_start       ( comp_start_cross ), // input
       
       .arbase_incdces   ( arbase_incdces   ), // input
       .arsize_incdces   ( arsize_incdces   ), // input
       .arbase_data_gen  ( arbase_data_gen  ), // input
       .arsize_data_gen  ( arsize_data_gen  ), // input
       .awbase_gen       ( awbase_gen       ), // input
       .awsize_gen       ( awsize_gen       ), // input
       .addr_gen_valid   ( addr_gen_valid   ), // input
       .rd_last_line     ( rd_last_line     ), // input
       
       .arbase           ( arbase          ), // output
       .arsize           ( arsize          ), // output
       .awbase           ( awbase          ), // output
       .awsize           ( awsize          ), // output
       
       .rd_start         ( rd_start         ), // output
       .wr_start         ( wr_start         ), // output
       .comp_done        ( comp_done        ), // output
       .rd_indices       ( rd_indices       ), // output
       .gen_status       ( gen_status       ), // output
       .trans_data       ( trans_data       ), // output
       
       .clk              ( clk              ), // input
       .rst_n            ( rst_n_1          )  // input
   );

   dma    U_dma(

       .arbase           ( arbase           ), // input
       .arsize           ( arsize           ), // input
     
       .awbase           ( awbase           ), // input
       .awsize           ( awsize           ), // input
                         
       .araddr           ( itf_araddr       ), // output
       .arvalid          ( itf_arvalid      ), // output
       .arready          ( itf_arready      ), // input

       .comp_data        ( comp_data        ), // input
       .data_valid       ( data_valid       ), // input
       .data_ready       ( data_ready       ), // output
                         
       .awaddr           ( itf_awaddr       ), // output
       .awdata           ( itf_awdata       ), // output
       .awvalid          ( itf_awvalid      ), // output
       .awready          ( itf_awready      ), // input

       .rd_start         ( rd_start         ), // input
       .wr_start         ( wr_start         ), // input

       .rd_done          ( rd_done          ), // output
       .wr_done          ( wr_done          ), // output

      // .comp_start       ( comp_start_cross ),

       .clk              ( clk              ), // input
       .rst_n            ( rst_n_1          )  // input
  );


   
  gather    U_gather(
        .rd_indices      ( rd_indices       ),
        .trans_data      ( trans_data       ),
        .gen_status      ( gen_status       ),
        .indices_width   ( indices_width    ),
        .data_width      ( data_width       ),

        .din             ( itf_rdata        ),
        .din_valid       ( itf_rvalid       ),
        .din_ready       ( itf_rready       ),

        .arbase_data     ( arbase_data      ),
        .arsize_data     ( arsize_data      ),
        .awbase_dout     ( awbase_dout      ),
        .awsize_dout     ( awsize_dout      ),

        .addr_gen_valid  ( addr_gen_valid   ),
        .arbase_data_gen ( arbase_data_gen  ),
        .arsize_data_gen ( arsize_data_gen  ),
        .awbase_gen      ( awbase_gen       ),
        .awsize_gen      ( awsize_gen       ),
        .rd_last_line    ( rd_last_line     ),

        .dout            ( comp_data        ),
        .dout_valid      ( data_valid       ),
        .dout_ready      ( data_ready       ),

        //.arsize          ( arsize           ),
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

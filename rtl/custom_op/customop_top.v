//================================================================================
// File Name     : gather_top.v
// Project       : 
// Create Date   : 2026.04.05
// Description   :
// 
//--------------------------------------------------------------------------------
// Modification History :
// Rev     Date         Who               Description
//================================================================================

module customop_top(

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
    wire   [ 31: 0]   arbase_data;
    //wire   [ 15: 0]   arsize_data;
    wire   [ 31: 0]   awbase_dout;
    //wire   [ 15: 0]   awsize_dout;
    wire   [511: 0]   comp_data  ; 
    wire              data_valid ; 
    wire              data_ready ; 

    wire              rst_n_1    ;
    wire              ra_rst_n_1 ;
    wire              comp_done_cross;
    wire              comp_start_cross;
    wire              comp_start_hd_cross;
    wire              comp_done_hd_cross;
    wire              comp_start_rs_cross;
    wire              comp_done_rs_cross;

    //Gather FSM internal signals
    wire              addr_gen_valid;
    wire [31:0]       arbase_data_gen;
    wire [15:0]       arsize_data_gen;
    wire [31:0]       awbase_gen;
    wire [15:0]       awsize_gen;
    wire              rd_last_line;
    wire [31:0]       arbase;
    wire [15:0]       arsize;
    wire [31:0]       awbase;
    wire [15:0]       awsize;
    wire              rd_start;
    wire              wr_start;
    wire              rd_indices;
    wire              trans_data;   
    wire              gen_status;

    wire [31:0]       indices_width;
    wire [31:0]       data_width;
    wire              din_ready;
    wire              rd_data_ready_gather;  // 索引数据全部到达

    //Hadamard signals
    wire              comp_start_hd;
    wire [31:0]       arbase_hd;
    wire [31:0]       awbase_hd;
    wire [31:0]       wrsize_hd;
    wire              comp_done_hd;
    wire [31:0]       hd_data_width;
    wire              hd_cal_percision; //0: int8, 1: fp16
    wire [15:0]       fwht_num;
    wire              hd_din_ready;

    //Hadamard FSM signals
    wire [31:0]       arbase_hd_fsm;
    wire [31:0]       awbase_hd_fsm;
    wire [15:0]       arsize_hd_fsm;
    wire [15:0]       awsize_hd_fsm;
    wire              rd_start_hd;
    wire              wr_start_hd;
    wire [1:0]        trans_status_hd;
    wire              gen_status_hd;
    wire              fwht_status_hd;
    wire              fwht_done_hd;
    wire              rd_data_ready_hd;    // 读数据全部到达

    //Hadamard addr_gen signals
    wire              hd_addr_gen_valid;
    wire [31:0]       arbase_hd_gen;
    wire [15:0]       arsize_hd_gen;
    wire [31:0]       awbase_hd_gen;
    wire [15:0]       awsize_hd_gen;
    wire              hd_first_line;
    wire              hd_last_line;

    //Resize signals (from reg_ctrl)
    wire              comp_start_rs;
    wire [31:0]       rbase_rs;
    wire [15:0]       rwidth_rs;
    wire [15:0]       rheight_rs;
    wire [31:0]       wbase_rs;
    wire [15:0]       wwidth_rs;
    wire [15:0]       wheight_rs;
    wire              comp_done_rs;

    //Resize FSM signals
    wire [31:0]       arbase_rs_fsm;
    wire [31:0]       awbase_rs_fsm;
    wire [15:0]       arsize_rs_fsm;
    wire [15:0]       awsize_rs_fsm;
    wire              rd_start_rs;
    wire              wr_start_rs;
    wire              rd_second_rs;
    wire [1:0]        trans_status_rs;
    wire              gen_status_rs;
    wire              axis_pre_cal_rs;
    wire              axis_cal_status_rs;
    wire              resize_status_rs;

    //Resize crop signals
    wire              crop_enable;
    wire [15:0]       crop_size;
    wire [15:0]       crop_off_x;
    wire [15:0]       crop_off_y;

    //Resize axis signals
    wire [15:0]       resize_ratio_less;
    wire [15:0]       resize_ratio_greater;
    wire [7:0]        data_valid_axis;
    wire [255:0]      x_delta_axis;
    wire [7:0]        y_delta_axis;
    wire [15:0]       y_bias_axis;
    wire              axis_done_axis;
    wire              axis_pre_cal_done_axis;

    //Resize addr_gen signals
    wire              rs_addr_gen_valid;
    wire [31:0]       arbase_rs_gen;
    wire [31:0]       arbase_rs_gen_2;
    wire [15:0]       arsize_rs_gen;
    wire [31:0]       awbase_rs_gen;
    wire [15:0]       awsize_rs_gen;
    wire [31:0]       awbase_comb_rs;
    wire              rs_first_line;
    wire              rs_last_line;

    //Resize module signals
    wire [511:0]      rs_dout;
    wire              rs_dout_valid;
    wire              rs_dout_ready;
    wire              rs_din_ready;
    wire              rs_resize_done;
    wire              fifo_flush_ready_rs;
    wire              fifo_empty_rs;
    wire              src_done_rs;
    wire              fifo_drain_rs;
    wire              clr_dbeat_1_rs;
    wire              rd_data_ready_rs_0; // 第一行读数据到达
    wire              rd_data_ready_rs_1; // 第二行读数据到达

    //Arbiter signals
    wire [31:0]       arb_arbase_gather;
    wire [15:0]       arb_arsize_gather;
    wire [31:0]       arb_awbase_gather;
    wire [15:0]       arb_awsize_gather;
    wire              arb_rd_start_gather;
    wire              arb_wr_start_gather;
    wire [511:0]      arb_comp_data_gather;
    wire              arb_data_valid_gather;
    wire              arb_data_ready_gather;
    wire              arb_rd_done_gather;
    wire              arb_wr_done_gather;

    wire [31:0]       arb_arbase_hd;
    wire [15:0]       arb_arsize_hd;
    wire [31:0]       arb_awbase_hd;
    wire [15:0]       arb_awsize_hd;
    wire              arb_rd_start_hd;
    wire              arb_wr_start_hd;
    wire [511:0]      arb_dout_hd;
    wire              arb_dout_valid_hd;
    wire              arb_dout_ready_hd;
    wire              arb_rd_done_hd;
    wire              arb_wr_done_hd;

    wire [31:0]       arb_arbase_rs;
    wire [15:0]       arb_arsize_rs;
    wire [31:0]       arb_awbase_rs;
    wire [15:0]       arb_awsize_rs;
    wire              arb_rd_start_rs;
    wire              arb_wr_start_rs;
    wire [511:0]      arb_dout_rs;
    wire              arb_dout_valid_rs;
    wire              arb_dout_ready_rs;
    wire              arb_rd_done_rs;
    wire              arb_wr_done_rs;

    // Hadamard to arbiter signals
    wire [511:0]      hd_dout;
    wire              hd_dout_valid;
    wire              hd_dout_ready;

    wire [31:0]       itf_arbase_arb;
    wire [15:0]       itf_arsize_arb;
    wire [31:0]       itf_awbase_arb;
    wire [15:0]       itf_awsize_arb;
    wire              itf_rd_start_arb;
    wire              itf_wr_start_arb;
    wire [511:0]      itf_comp_data_arb;
    wire              itf_data_valid_arb;
    wire              itf_data_ready_arb;
    wire              itf_rd_done_arb;
    wire              itf_wr_done_arb;

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
          .wbase1         ( awbase_dout      ),

          .comp_start_hd  ( comp_start_hd    ) ,
          .rbase_hd       ( arbase_hd        ) ,
          .wbase_hd       ( awbase_hd        ) ,
          .wrsize_hd      ( wrsize_hd        ) ,
          .comp_done_hd   ( comp_done_hd_cross ) ,

          .comp_start_rs  ( comp_start_rs    ) ,
          .rbase_rs       ( rbase_rs         ) ,
          .rwidth_rs      ( rwidth_rs        ) ,
          .rheight_rs     ( rheight_rs       ) ,
          .wbase_rs       ( wbase_rs         ) ,
          .wwidth_rs      ( wwidth_rs        ) ,
          .wheight_rs     ( wheight_rs       ) ,
          .comp_done_rs   ( comp_done_rs_cross ) ,
          
          .rfu_rreg0     ( 32'd0            ),
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
          .rfu_wreg2     ( hd_data_width    ),                                              
          .rfu_wreg3     ( hd_cal_percision ),                                              
          .rfu_wreg4     ( resize_ratio_less),                                              
          .rfu_wreg5     ( resize_ratio_greater),                                              
          .rfu_wreg6     ( crop_enable      ),                                   
          .rfu_wreg7     (                  ),                                              
          .rfu_wreg8     (                  ),                                              
          .rfu_wreg9     (                  ),
   
          .clk           ( ra_clk           ),
          .rst_n         ( ra_rst_n_1       )
   
   );

   // Instantiate Gather FSM
   gather_fsm U_gather_fsm (
       .rd_done          ( arb_rd_done_gather ), // input - from arbiter
       .wr_done          ( arb_wr_done_gather ), // input - from arbiter
       .comp_start       ( comp_start_cross ), // input
       .rd_data_ready    ( rd_data_ready_gather ), // input - from gather core

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

       .arbase           ( itf_arbase_arb        ), // input
       .arsize           ( itf_arsize_arb        ), // input
       .awbase           ( itf_awbase_arb        ), // input
       .awsize           ( itf_awsize_arb        ), // input
                         
       .araddr           ( itf_araddr       ), // output
       .arvalid          ( itf_arvalid      ), // output
       .arready          ( itf_arready      ), // input

       .comp_data        ( itf_comp_data_arb     ), // input
       .data_valid       ( itf_data_valid_arb    ), // input
       .data_ready       ( itf_data_ready_arb    ), // output
                         
       .awaddr           ( itf_awaddr       ), // output
       .awdata           ( itf_awdata       ), // output
       .awvalid          ( itf_awvalid      ), // output
       .awready          ( itf_awready      ), // input

       .rd_start         ( itf_rd_start_arb      ), // input
       .wr_start         ( itf_wr_start_arb      ), // input

       .rd_done          ( itf_rd_done_arb       ), // output
       .wr_done          ( itf_wr_done_arb       ), // output

       .clk              ( clk              ), // input
       .rst_n            ( rst_n_1          )  // input
  );

    // Arbiter instantiation
  arbiter U_arbiter (
      // Gather DMA interface
      .gather_arbase      ( arbase              ),
      .gather_arsize      ( arsize              ),
      .gather_awbase      ( awbase              ),
      .gather_awsize      ( awsize              ),
      .gather_rd_start    ( rd_start            ),
      .gather_wr_start    ( wr_start            ),
      .gather_din_ready   ( din_ready           ),
      .gather_comp_data   ( comp_data           ),
      .gather_data_valid  ( data_valid          ),
      .gather_data_ready  ( data_ready          ),
      .gather_rd_done     ( arb_rd_done_gather  ),
      .gather_wr_done     ( arb_wr_done_gather  ),
      .gather_comp_done   ( comp_done           ),

      // Hadamard DMA interface
      .hadamard_arbase    ( arbase_hd_fsm       ),
      .hadamard_arsize    ( arsize_hd_fsm       ),
      .hadamard_awbase    ( awbase_hd_fsm       ),
      .hadamard_awsize    ( awsize_hd_fsm       ),
      .hadamard_rd_start  ( rd_start_hd         ),
      .hadamard_wr_start  ( wr_start_hd         ),
      .hadamard_din_ready ( hd_din_ready        ),
      .hadamard_dout      ( hd_dout           ),
      .hadamard_dout_valid( hd_dout_valid     ),
      .hadamard_dout_ready( hd_dout_ready     ),
      .hadamard_rd_done   ( arb_rd_done_hd      ),
      .hadamard_wr_done   ( arb_wr_done_hd      ),
      .hadamard_comp_done ( comp_done_hd        ),

      // Resize DMA interface
      .resize_arbase      ( arbase_rs_fsm       ),
      .resize_arsize      ( arsize_rs_fsm       ),
      .resize_awbase      ( awbase_rs_fsm       ),
      .resize_awsize      ( awsize_rs_fsm       ),
      .resize_rd_start    ( rd_start_rs         ),
      .resize_wr_start    ( wr_start_rs         ),
      .resize_din_ready   ( rs_din_ready        ),
      .resize_dout        ( rs_dout             ),
      .resize_dout_valid  ( rs_dout_valid       ),
      .resize_rd_done     ( arb_rd_done_rs      ),
      .resize_wr_done     ( arb_wr_done_rs      ),
      .resize_comp_done   ( comp_done_rs        ),

      // To DMA interface
      .itf_arbase         ( itf_arbase_arb      ),
      .itf_arsize         ( itf_arsize_arb      ),
      .itf_awbase         ( itf_awbase_arb      ),
      .itf_awsize         ( itf_awsize_arb      ),
      .itf_rd_start       ( itf_rd_start_arb    ),
      .itf_wr_start       ( itf_wr_start_arb    ),
      .itf_comp_data      ( itf_comp_data_arb   ),
      .itf_data_valid     ( itf_data_valid_arb  ),
      .itf_data_ready     ( itf_data_ready_arb  ),
      .itf_rd_done        ( itf_rd_done_arb     ),
      .itf_wr_done        ( itf_wr_done_arb     ),
      .itf_rready         ( itf_rready          ),

      // Control signals
      .gather_comp_start  ( comp_start_cross    ),
      .hadamard_comp_start( comp_start_hd_cross ),
      .resize_comp_start  ( comp_start_rs_cross ),

      .clk                ( clk                 ),
      .rst_n              ( rst_n_1             )
  );
   
  gather    U_gather(
        .rd_indices      ( rd_indices       ),
        .trans_data      ( trans_data       ),
        .gen_status      ( gen_status       ),
        .indices_beats   ( arsize_incdces   ),
        .indices_width   ( indices_width    ),
        .data_width      ( data_width       ),

        .din             ( itf_rdata        ),
        .din_valid       ( itf_rvalid       ),
        .din_ready       ( din_ready        ),

        .arbase_data     ( arbase_data      ),
        //.arsize_data     ( arsize_data      ),
        .awbase_dout     ( awbase_dout      ),
        //.awsize_dout     ( awsize_dout      ),

        .addr_gen_valid  ( addr_gen_valid   ),
        .arbase_data_gen ( arbase_data_gen  ),
        .arsize_data_gen ( arsize_data_gen  ),
        .awbase_gen      ( awbase_gen       ),
        .awsize_gen      ( awsize_gen       ),
        .rd_last_line    ( rd_last_line     ),

        .dout            ( comp_data        ),
        .dout_valid      ( data_valid       ),
        .dout_ready      ( data_ready       ),

        .rd_data_ready   ( rd_data_ready_gather ),

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

      // CDC for Hadamard start (ra_clk -> clk)
      pulse_cross U2_pulse_cross(
            .a2      (  comp_start_hd_cross ),
            .clk2    (  clk                 ),
            .rst2    (  ~rst_n_1            ),

            .rdy1    (                      ),
            .a1      (  comp_start_hd       ),
            .clk1    (  ra_clk              ),
            .rst1    (  ~ra_rst_n_1         )
      );

      // CDC for Hadamard done (clk -> ra_clk)
      pulse_cross U3_pulse_cross(
            .a2      (  comp_done_hd_cross ),
            .clk2    (  ra_clk             ),
            .rst2    (  ~ra_rst_n_1        ),

            .rdy1    (                     ),
            .a1      (  comp_done_hd       ),
            .clk1    (  clk                ),
            .rst1    (  ~rst_n_1           )
      );

      // CDC for Resize start (ra_clk -> clk)
      pulse_cross U4_pulse_cross(
            .a2      (  comp_start_rs_cross ),
            .clk2    (  clk                 ),
            .rst2    (  ~rst_n_1            ),

            .rdy1    (                      ),
            .a1      (  comp_start_rs       ),
            .clk1    (  ra_clk              ),
            .rst1    (  ~ra_rst_n_1         )
      );

      // CDC for Resize done (clk -> ra_clk)
      pulse_cross U5_pulse_cross(
            .a2      (  comp_done_rs_cross ),
            .clk2    (  ra_clk             ),
            .rst2    (  ~ra_rst_n_1        ),

            .rdy1    (                     ),
            .a1      (  comp_done_rs       ),
            .clk1    (  clk                ),
            .rst1    (  ~rst_n_1           )
      );

  // ============================================================
  // Hadamard Module Instances
  // ============================================================

  // Hadamard FSM
  hadamard_fsm U_hadamard_fsm (
      .rd_done          ( arb_rd_done_hd     ), // input - from arbiter
      .wr_done          ( arb_wr_done_hd     ), // input - from arbiter
      .hd_comp_start    ( comp_start_hd_cross ), // input - from reg_ctrl (via CDC)
      .arbase_hd_gen    ( arbase_hd_gen    ), // input
      .arsize_hd_gen    ( arsize_hd_gen    ), // input
      .awbase_hd_gen    ( awbase_hd_gen    ), // input
      .awsize_hd_gen    ( awsize_hd_gen    ), // input
      .hd_addr_gen_valid( hd_addr_gen_valid), // input
      .hd_first_line    ( hd_first_line    ), // input
      .hd_last_line     ( hd_last_line     ), // input
      .fwht_done        ( fwht_done_hd     ), // input - from hadamard core
      .rd_data_ready    ( rd_data_ready_hd ), // input - from hadamard core

      .arbase           ( arbase_hd_fsm    ), // output
      .arsize           ( arsize_hd_fsm    ), // output
      .awbase           ( awbase_hd_fsm    ), // output
      .awsize           ( awsize_hd_fsm    ), // output
      .rd_start         ( rd_start_hd       ), // output
      .wr_start         ( wr_start_hd      ), // output
      .comp_done        ( comp_done_hd     ), // output
      .trans_status     ( trans_status_hd  ), // output [1:0]
      .gen_status       ( gen_status_hd    ), // output
      .fwht_status      ( fwht_status_hd   ), // output


      .clk              ( clk              ),
      .rst_n            ( rst_n_1          )
  );

  // Hadamard Address Generator
  hadamard_addr_gen U_hadamard_addr_gen (
      .trans_status     ( trans_status_hd  ), // input [1:0]
      .gen_status       ( gen_status_hd    ), // input
      .hd_data_width    ( hd_data_width    ), // input [31:0]
      .arbase_hd        ( arbase_hd         ), // input [31:0]
      .wrsize_hd        ( wrsize_hd         ), // input [31:0]
      .awbase_hd        ( awbase_hd         ), // input [31:0]
      .cal_percision    ( hd_cal_percision ),
      //.fwht_num         ( fwht_num          ), // input [15:0]

      .hd_addr_gen_valid( hd_addr_gen_valid ), // output
      .arbase_hd_gen   ( arbase_hd_gen     ), // output [31:0]
      .arsize_hd_gen   ( arsize_hd_gen     ), // output [15:0]
      .awbase_hd_gen   ( awbase_hd_gen     ), // output [31:0]
      .awsize_hd_gen   ( awsize_hd_gen     ), // output [15:0]
      .hd_first_line   ( hd_first_line     ), // output
      .hd_last_line    ( hd_last_line      ), // output

      .comp_done        ( comp_done_hd      ), // input

      .clk              ( clk               ),
      .rst_n            ( rst_n_1           )
  );

  // Hadamard Core (FWHT)
  hadamard U_hadamard (
      .gen_status       ( gen_status_hd    ), // input
      .fwht_status      ( fwht_status_hd   ), // input
      .trans_status     ( trans_status_hd  ), // input [1:0]
      .wr_done          ( arb_wr_done_hd   ),
      .cal_percision    ( hd_cal_percision ), // input

      .din              ( itf_rdata         ), // input [511:0] - 直接连接DMA读数据
      .din_valid        ( itf_rvalid        ), // input
      .din_ready        ( hd_din_ready      ), // output

      .dout             ( hd_dout           ), // output [511:0] - 通过arbiter仲裁
      .dout_valid       ( hd_dout_valid     ), // output
      .dout_ready       ( hd_dout_ready     ), // input

      .comp_done        ( comp_done_hd      ), // input
      .fwht_done        ( fwht_done_hd      ), // output
      .rd_data_ready    ( rd_data_ready_hd ), // output

      .clk              ( clk               ),
      .rst_n            ( rst_n_1           )
  );

  // ============================================================
  // Resize Module Instances
  // ============================================================

  // Resize FSM
  resize_fsm U_resize_fsm (
      .rd_done          ( arb_rd_done_rs     ), // input - from arbiter
      .wr_done          ( arb_wr_done_rs     ), // input - from arbiter
      .rs_comp_start    ( comp_start_rs_cross ), // input - from reg_ctrl (via CDC)
      .arbase_rs_gen   ( arbase_rs_gen    ), // input
      .arbase_rs_gen_2 ( arbase_rs_gen_2   ), // input
      .arsize_rs_gen   ( arsize_rs_gen    ), // input
      .awbase_rs_gen   ( awbase_rs_gen    ), // input
      .awsize_rs_gen   ( awsize_rs_gen    ), // input
      .awbase_comb     ( awbase_comb_rs   ), // input
      .rs_addr_gen_valid( rs_addr_gen_valid ), // input
      .rs_first_line   ( rs_first_line     ), // input
      .fifo_flush_ready ( fifo_flush_ready_rs ),
      .fifo_empty       ( fifo_empty_rs       ),
      .src_done         ( src_done_rs         ),
      .rs_last_line    ( rs_last_line      ), // input
      .resize_done      ( rs_resize_done    ), // input - from resize core
      .axis_done        ( axis_done_axis     ), // input - from resize_axis
      .axis_pre_cal_done( axis_pre_cal_done_axis ), // input - from resize_axis
      .rd_data_ready_0  ( rd_data_ready_rs_0 ), // input - from resize core
      .rd_data_ready_1  ( rd_data_ready_rs_1 ), // input - from resize core

      .arbase           ( arbase_rs_fsm    ), // output
      .arsize           ( arsize_rs_fsm    ), // output
      .awbase           ( awbase_rs_fsm    ), // output
      .awsize           ( awsize_rs_fsm    ), // output
      .rd_start         ( rd_start_rs       ), // output
      .wr_start         ( wr_start_rs       ), // output
      .rd_second        ( rd_second_rs      ), // output
      .clr_dbeat_1      ( clr_dbeat_1_rs   ), // output
      .comp_done        ( comp_done_rs      ), // output
      .trans_status     ( trans_status_rs   ), // output [1:0]
      .gen_status       ( gen_status_rs     ), // output
      .axis_pre_cal    ( axis_pre_cal_rs   ), // output
      .axis_cal_status ( axis_cal_status_rs ), // output
      .resize_status    ( resize_status_rs  ), // output
      .fifo_drain       ( fifo_drain_rs       ),

      .clk              ( clk              ),
      .rst_n            ( rst_n_1          )
  );

  // Resize Axis Calculator
  resize_axis U_resize_axis (
      .axis_pre_cal    ( axis_pre_cal_rs   ), // input
      .axis_cal_status ( axis_cal_status_rs ), // input
      .resize_status    ( resize_status_rs  ), // input
      .trans_status    ( trans_status_rs   ), // input [1:0]
      .resize_ratio_less (resize_ratio_less),
      .resize_ratio_greater (resize_ratio_greater),

      .rwidth_rs       ( rwidth_rs        ), // input [15:0]
      .rheight_rs      ( rheight_rs       ), // input [15:0]
      .wwidth_rs       ( wwidth_rs        ), // input [15:0]
      .wheight_rs      ( wheight_rs       ), // input [15:0]

      .crop_enable     ( crop_enable      ), // input
      .crop_size       ( crop_size        ), // output [15:0]
      .crop_off_x      ( crop_off_x       ), // output [15:0]
      .crop_off_y      ( crop_off_y       ), // output [15:0]

      .data_valid      ( data_valid_axis   ), // output [7:0]
      .x_delta         ( x_delta_axis      ), // output [255:0]
      .y_delta         ( y_delta_axis      ), // output [7:0]
      .y_bias          ( y_bias_axis       ), // output [15:0]

      .axis_done       ( axis_done_axis     ), // output
      .axis_pre_cal_done( axis_pre_cal_done_axis ), // output

      .clk              ( clk              ),
      .rst_n            ( rst_n_1          )
  );

  // Resize Address Generator
  resize_addr_gen U_resize_addr_gen (
      .trans_status    ( trans_status_rs   ), // input [1:0]
      .rd_second       ( rd_second_rs     ), // input
      .gen_status      ( gen_status_rs     ), // input

      .crop_off_x      ( crop_off_x       ), // input [15:0]
      .crop_off_y      ( crop_off_y       ), // input [15:0]
      .crop_size       ( crop_size        ), // input [15:0]

      .rbase_rs        ( rbase_rs         ), // input [31:0]
      .rwidth_rs       ( rwidth_rs        ), // input [15:0]
      .wheight_rs      ( wheight_rs       ), // input [15:0]
      .dst_width       ( wwidth_rs        ), // input [15:0]
      .wbase_rs        ( wbase_rs         ), // input [31:0]

      .y_bias          ( y_bias_axis       ), // input [15:0]

      .rs_addr_gen_valid( rs_addr_gen_valid ), // output
      .arbase_rs_gen   ( arbase_rs_gen    ), // output [31:0]
      .arbase_rs_gen_2 ( arbase_rs_gen_2   ), // output [31:0]
      .arsize_rs_gen   ( arsize_rs_gen    ), // output [15:0]
      .awbase_rs_gen   ( awbase_rs_gen    ), // output [31:0]
      .awsize_rs_gen   ( awsize_rs_gen    ), // output [15:0]
      .awbase_comb     ( awbase_comb_rs   ), // output [31:0]
      .rs_first_line   ( rs_first_line     ), // output
      .rs_last_line    ( rs_last_line      ), // output
      .src_done         ( src_done_rs         ), // output

      .comp_done_rs    ( comp_done_rs      ), // input

      .clk              ( clk              ),
      .rst_n            ( rst_n_1          )
  );

  // Resize Core (Bilinear Interpolation)
  resize U_resize (
      .gen_status      ( gen_status_rs     ), // input
      .resize_status    ( resize_status_rs  ), // input
      .rd_second       ( rd_second_rs     ), // input
      .trans_status    ( trans_status_rs   ), // input [1:0]
      .wr_done         ( arb_wr_done_rs   ), // input
      .axis_cal_done   ( axis_cal_status_rs ), // input

      .data_valid      ( data_valid_axis   ), // input [7:0]
      .x_delta         ( x_delta_axis      ), // input [255:0]
      .y_delta         ( y_delta_axis      ), // input [7:0]

      .arsize_input    ( arsize_rs_gen     ), // input [15:0] - 当前行的期望beat数

      .din             ( itf_rdata         ), // input [511:0] - 直接连接DMA读数据
      .din_valid       ( itf_rvalid        ), // input
      .din_ready       ( rs_din_ready      ), // output

      .dout            ( rs_dout           ), // output [511:0] - 通过arbiter仲裁
      .dout_valid      ( rs_dout_valid     ), // output
      .dout_ready      ( rs_dout_ready     ), // input

      .comp_done       ( comp_done_rs      ), // input
      .resize_done     ( rs_resize_done    ), // output
      .rd_data_ready_0 ( rd_data_ready_rs_0 ), // output
      .rd_data_ready_1 ( rd_data_ready_rs_1 ), // output

      .clr_dbeat_1      ( clr_dbeat_1_rs     ), // input
      .fifo_flush_ready ( fifo_flush_ready_rs ),
      .fifo_empty       ( fifo_empty_rs       ),
      .fifo_drain       ( fifo_drain_rs       ),

      .clk              ( clk              ),
      .rst_n            ( rst_n_1          )
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

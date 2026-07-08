
//==============================================================================
// Orgnization   : Shanghai Fudan Microelectronics Co., Ltd. Confidential
// File Name     : reg_ctrl.v
// Author        :
// Project       : 
// Create Date   : 2021.03.31
// Description   :
// - Register Ctrl
//------------------------------------------------------------------------------
// Modification History :
// Rev     Date         Who          Description
// 
//==============================================================================

module reg_ctrl(    

    input         [   15 : 0]   ra_awaddr        ,  
    input         [   31 : 0]   ra_awdata        ,
    input                       ra_awvalid       ,
    output                      ra_awready       ,

    input         [   15 : 0]   ra_araddr        ,  
    input                       ra_arvalid       ,
    output                      ra_arready       ,

    output  reg   [   31 : 0]   ra_rdata         ,
    output  reg                 ra_rvalid        ,
    input                       ra_rready        ,

    output  reg                 comp_start       ,
    input                       comp_done        ,

    output reg    [   15 : 0]   rbase1           ,
    output reg    [   15 : 0]   rsize1           ,

    output reg    [   31 : 0]   wbase1           ,
    output reg    [   31 : 0]   rbase2           ,

    output reg    [   15 : 0]   comp_start_hd    ,
    output reg    [   31 : 0]   rbase_hd         ,
    output reg    [   31 : 0]   wbase_hd         ,
    output reg    [   31 : 0]   wrsize_hd        ,
    input                       comp_done_hd     ,

    output reg    [   15 : 0]   comp_start_rs    ,
    output reg    [   31 : 0]   rbase_rs         ,
    output reg    [   31 : 0]   wbase_rs         ,
    output reg    [   15 : 0]   rwidth_rs        ,
    output reg    [   15 : 0]   rheight_rs       ,
    output reg    [   15 : 0]   wwidth_rs        ,
    output reg    [   15 : 0]   wheight_rs       ,
    input                       comp_done_rs     ,

    output reg                  comp_start_fc    ,
    output reg                  direction_fc     ,
    output reg  [31:0]          rbase_fc         ,
    output reg  [31:0]          wbase_fc         ,
    output reg  [31:0]          pixel_cnt_fc     ,
    input                       comp_done_fc     ,

    input         [   31 : 0]   rfu_rreg0        ,                                              
    input         [   31 : 0]   rfu_rreg1        ,                                              
    input         [   31 : 0]   rfu_rreg2        ,                                              
    input         [   31 : 0]   rfu_rreg3        ,                                              
    input         [   31 : 0]   rfu_rreg4        ,                                              
    input         [   31 : 0]   rfu_rreg5        ,                                              
    input         [   31 : 0]   rfu_rreg6        ,                                              
    input         [   31 : 0]   rfu_rreg7        ,                                              
    input         [   31 : 0]   rfu_rreg8        ,                                              
    input         [   31 : 0]   rfu_rreg9        ,                                              

    output reg    [   31 : 0]   rfu_wreg0        ,                                              
    output reg    [   31 : 0]   rfu_wreg1        ,                                              
    output reg    [   31 : 0]   rfu_wreg2        ,                                              
    output reg    [   31 : 0]   rfu_wreg3        ,                                              
    output reg    [   31 : 0]   rfu_wreg4        ,                                              
    output reg    [   31 : 0]   rfu_wreg5        ,                                              
    output reg    [   31 : 0]   rfu_wreg6        ,                                              
    output reg    [   31 : 0]   rfu_wreg7        ,                                              
    output reg    [   31 : 0]   rfu_wreg8        ,                                              
    output reg    [   31 : 0]   rfu_wreg9        ,

    input                              clk       ,
    input                            rst_n 

);

    localparam DEBUG_REG_ADDR    = 16'hff;
    localparam RESET_ADDR        = 16'h77;
    localparam COMP_START_ADDR   = 16'h00;
    localparam RSIZE1_BASE_ADDR  = 16'h01;
    localparam WSIZE1_BASE_ADDR  = 16'h02;
    localparam COMPUTE_DONE_ADDR = 16'h20;
    localparam RSIZE2_BASE_ADDR  = 16'h03;
//  localparam WSIZE2_BASE_ADDR  = 16'h04;

    localparam RFU_WADDR0        = 16'h05;
    localparam RFU_WADDR1        = 16'h06;
    localparam RFU_WADDR2        = 16'h07;
    localparam RFU_WADDR3        = 16'h08;
    localparam RFU_WADDR4        = 16'h09;
    localparam RFU_WADDR5        = 16'h0a;
    localparam RFU_WADDR6        = 16'h0b;
    localparam RFU_WADDR7        = 16'h0c;
    localparam RFU_WADDR8        = 16'h0d;
    localparam RFU_WADDR9        = 16'h0f;

    localparam RFU_RADDR0        = 16'h21;
    localparam RFU_RADDR1        = 16'h22;
    localparam RFU_RADDR2        = 16'h23;
    localparam RFU_RADDR3        = 16'h24;
    localparam RFU_RADDR4        = 16'h25;
    localparam RFU_RADDR5        = 16'h26;
    localparam RFU_RADDR6        = 16'h27;
    localparam RFU_RADDR7        = 16'h28;
    localparam RFU_RADDR8        = 16'h29;
    localparam RFU_RADDR9        = 16'h2a;

    localparam GATHER_VERSION       = 32'h20260611;

    localparam HD_COMP_START_ADDR   = 16'h31;
    localparam HD_RBASE_ADDR  = 16'h32;
    localparam HD_WBASE_ADDR  = 16'h33;
    localparam HD_WRSIZE_ADDR  = 16'h34;
    localparam HD_COMP_DONE_ADDR = 16'h40;

    localparam HD_VERSION       = 32'h20260611;

    localparam RS_COMP_START_ADDR   = 16'h41;
    localparam RS_RBASE_ADDR        = 16'h42;
    localparam RS_WBASE_ADDR        = 16'h43;
    localparam RS_RSIZE_ADDR        = 16'h44;
    localparam RS_WSIZE_ADDR        = 16'h45;
    localparam RS_COMP_DONE_ADDR    = 16'h50;

    localparam RS_VERSION          = 32'h20260611;

    localparam FC_COMP_START_ADDR  = 16'h51;
    localparam FC_SRC_ADDR         = 16'h52;
    localparam FC_DST_ADDR         = 16'h53;
    localparam FC_PIXEL_CNT        = 16'h54;
    localparam FC_COMP_DONE_ADDR   = 16'h61;
    localparam FC_VER_ADDR         = 16'h81;
    localparam FC_VERSION          = 32'h20260708;


    wire              ra_awevent      ;
    reg   [31 : 0]    debug_reg       ;
    reg               comp_done_reg   ;
    reg               comp_done_hd_reg;
    reg               comp_done_rs_reg;

    assign ra_awready = 1'b1;
    assign ra_arready = ra_rvalid==1'b0;

    assign ra_awevent = ra_awvalid && ra_awready;

    always@(posedge clk or negedge rst_n) begin
        if(rst_n==1'b0)
            ra_rvalid <= #0.1 1'b0;
        else if(ra_arvalid && ra_arready)
            ra_rvalid <= #0.1 1'b1;
        else if(ra_rready)
            ra_rvalid <= #0.1 1'b0;
    end

    always@(posedge clk or negedge rst_n) begin
        if(rst_n==1'b0)
            comp_start <= #0.1 0;
        else if(comp_start==1'b1)
            comp_start <= #0.1 0;
        else if(ra_awevent && ra_awaddr==COMP_START_ADDR)
            comp_start <= #0.1 ra_awdata[0];
    end

    always@(posedge clk or negedge rst_n) begin
       if(rst_n==1'b0)begin
            rbase1 <= #0.1 0;
            rsize1 <= #0.1 0;
       end
       else if(ra_awevent && ra_awaddr==RSIZE1_BASE_ADDR)begin
            rbase1 <= #0.1 ra_awdata[15:0];
            rsize1 <= #0.1 ra_awdata[31:16];
       end
    end

     always@(posedge clk or negedge rst_n) begin
       if(rst_n==1'b0)begin
            wbase1 <= #0.1 0;
            //wsize1 <= #0.1 0;
       end
       else if(ra_awevent && ra_awaddr==WSIZE1_BASE_ADDR)begin
            wbase1 <= #0.1  ra_awdata[31:0];
            //wsize1 <= #0.1  ra_awdata[31:16];
       end
    end

    always@(posedge clk or negedge rst_n) begin
       if(rst_n==1'b0)begin
            rbase2 <= #0.1 0;
            //rsize2 <= #0.1 0;
       end
       else if(ra_awevent && ra_awaddr==RSIZE2_BASE_ADDR)begin
            rbase2 <= #0.1 ra_awdata[31:0];
            //rsize2 <= #0.1 ra_awdata[31:16];
       end
    end


    always@(posedge clk or negedge rst_n) begin
        if(rst_n==1'b0)
            comp_start_hd <= #0.1 0;
        else if(comp_start_hd==1'b1)
            comp_start_hd <= #0.1 0;
        else if(ra_awevent && ra_awaddr==HD_COMP_START_ADDR)
            comp_start_hd <= #0.1 ra_awdata[0];
    end

    always@(posedge clk or negedge rst_n) begin
       if(rst_n==1'b0)begin
            rbase_hd <= #0.1 0;
       end
       else if(ra_awevent && ra_awaddr==HD_RBASE_ADDR)begin
            rbase_hd <= #0.1 ra_awdata;
       end
    end

     always@(posedge clk or negedge rst_n) begin
       if(rst_n==1'b0)begin
            wbase_hd <= #0.1 0;
            //wsize1 <= #0.1 0;
       end
       else if(ra_awevent && ra_awaddr==HD_WBASE_ADDR)begin
            wbase_hd <= #0.1  ra_awdata[31:0];
            //wsize1 <= #0.1  ra_awdata[31:16];
       end
    end

    always@(posedge clk or negedge rst_n) begin
       if(rst_n==1'b0)begin
            wrsize_hd <= #0.1 0;
            //rsize2 <= #0.1 0;
       end
       else if(ra_awevent && ra_awaddr==HD_WRSIZE_ADDR)begin
            wrsize_hd <= #0.1 ra_awdata[31:0];
            //rsize2 <= #0.1 ra_awdata[31:16];
       end
    end

    always@(posedge clk or negedge rst_n) begin
        if(rst_n==1'b0)
            comp_start_rs <= #0.1 0;
        else if(comp_start_rs==1'b1)
            comp_start_rs <= #0.1 0;
        else if(ra_awevent && ra_awaddr==RS_COMP_START_ADDR)
            comp_start_rs <= #0.1 ra_awdata[0];
    end

    always@(posedge clk or negedge rst_n) begin
       if(rst_n==1'b0)begin
            rbase_rs <= #0.1 0;
       end
       else if(ra_awevent && ra_awaddr==RS_RBASE_ADDR)begin
            rbase_rs <= #0.1 ra_awdata;
       end
    end

    always@(posedge clk or negedge rst_n) begin
       if(rst_n==1'b0)begin
            wbase_rs <= #0.1 0;
       end
       else if(ra_awevent && ra_awaddr==RS_WBASE_ADDR)begin
            wbase_rs <= #0.1 ra_awdata;
       end
    end

    always@(posedge clk or negedge rst_n) begin
       if(rst_n==1'b0)begin
            rwidth_rs <= #0.1 16'd0;
            rheight_rs <= #0.1 16'd0;
       end
       else if(ra_awevent && ra_awaddr==RS_RSIZE_ADDR)begin
            rwidth_rs <= #0.1 ra_awdata[31:16];
            rheight_rs <= #0.1 ra_awdata[15:0];
       end
    end

    always@(posedge clk or negedge rst_n) begin
       if(rst_n==1'b0)begin
            wwidth_rs <= #0.1 16'd0;
            wheight_rs <= #0.1 16'd0;
       end
       else if(ra_awevent && ra_awaddr==RS_WSIZE_ADDR)begin
            wwidth_rs <= #0.1 ra_awdata[31:16];
            wheight_rs <= #0.1 ra_awdata[15:0];
       end
    end

    // ---- fmt_cvt registers ----
    always@(posedge clk or negedge rst_n) begin
        if(rst_n==1'b0) begin
            comp_start_fc <= #0.1 0;
            direction_fc  <= #0.1 0;
        end else if(comp_start_fc==1'b1) begin
            comp_start_fc <= #0.1 0;
        end else if(ra_awevent && ra_awaddr==FC_COMP_START_ADDR) begin
            comp_start_fc <= #0.1 ra_awdata[0];
            direction_fc  <= #0.1 ra_awdata[1];
        end
    end

    always@(posedge clk or negedge rst_n) begin
       if(rst_n==1'b0)
            rbase_fc <= #0.1 0;
       else if(ra_awevent && ra_awaddr==FC_SRC_ADDR)
            rbase_fc <= #0.1 ra_awdata;
    end

    always@(posedge clk or negedge rst_n) begin
       if(rst_n==1'b0)
            wbase_fc <= #0.1 0;
       else if(ra_awevent && ra_awaddr==FC_DST_ADDR)
            wbase_fc <= #0.1 ra_awdata;
    end

    always@(posedge clk or negedge rst_n) begin
       if(rst_n==1'b0)
            pixel_cnt_fc <= #0.1 0;
       else if(ra_awevent && ra_awaddr==FC_PIXEL_CNT)
            pixel_cnt_fc <= #0.1 ra_awdata;
    end


    always@(posedge clk or negedge rst_n) begin
        if(rst_n==1'b0)
            rfu_wreg0 <= #0.1 0;
        else if(ra_awevent && ra_awaddr==RFU_WADDR0)
            rfu_wreg0 <= #0.1 ra_awdata;
    end

    always@(posedge clk or negedge rst_n) begin
        if(rst_n==1'b0)
            rfu_wreg1 <= #0.1 0;
        else if(ra_awevent && ra_awaddr==RFU_WADDR1)
            rfu_wreg1 <= #0.1 ra_awdata;
    end


    always@(posedge clk or negedge rst_n) begin
        if(rst_n==1'b0)
            rfu_wreg2 <= #0.1 0;
        else if(ra_awevent && ra_awaddr==RFU_WADDR2)
            rfu_wreg2 <= #0.1 ra_awdata;
    end
    

    always@(posedge clk or negedge rst_n) begin
        if(rst_n==1'b0)
            rfu_wreg3 <= #0.1 0;
        else if(ra_awevent && ra_awaddr==RFU_WADDR3)
            rfu_wreg3 <= #0.1 ra_awdata;
    end
  
    always@(posedge clk or negedge rst_n) begin
        if(rst_n==1'b0)
            rfu_wreg4 <= #0.1 0;
        else if(ra_awevent && ra_awaddr==RFU_WADDR4)
            rfu_wreg4 <= #0.1 ra_awdata;
    end
    
    always@(posedge clk or negedge rst_n) begin
        if(rst_n==1'b0)
            rfu_wreg5 <= #0.1 0;
        else if(ra_awevent && ra_awaddr==RFU_WADDR5)
            rfu_wreg5 <= #0.1 ra_awdata;
    end

    always@(posedge clk or negedge rst_n) begin
        if(rst_n==1'b0)
            rfu_wreg6 <= #0.1 0;
        else if(ra_awevent && ra_awaddr==RFU_WADDR6)
            rfu_wreg6 <= #0.1 ra_awdata;
    end
    
    always@(posedge clk or negedge rst_n) begin
        if(rst_n==1'b0)
            rfu_wreg7 <= #0.1 0;
        else if(ra_awevent && ra_awaddr==RFU_WADDR7)
            rfu_wreg7 <= #0.1 ra_awdata;
    end
    
    always@(posedge clk or negedge rst_n) begin
        if(rst_n==1'b0)
            rfu_wreg8 <= #0.1 0;
        else if(ra_awevent && ra_awaddr==RFU_WADDR8)
            rfu_wreg8 <= #0.1 ra_awdata;
    end
    
    always@(posedge clk or negedge rst_n) begin
        if(rst_n==1'b0)
            rfu_wreg9 <= #0.1 0;
        else if(ra_awevent && ra_awaddr==RFU_WADDR9)
            rfu_wreg9 <= #0.1 ra_awdata;
    end

    always@(posedge clk or negedge rst_n) begin
        if(rst_n==1'b0)
            debug_reg <= #0.1 0;
        else if(ra_awevent && ra_awaddr==DEBUG_REG_ADDR)
            debug_reg <= #0.1 ra_awdata;
    end

    always@(posedge clk or negedge rst_n) begin
        if(rst_n==1'b0)
            comp_done_reg <= #0.1 0;
        else if(comp_start==1'b1)
            comp_done_reg <= #0.1 0;
        else if(comp_done)
            comp_done_reg <= #0.1 1;
    end

    always@(posedge clk or negedge rst_n) begin
        if(rst_n==1'b0)
            comp_done_hd_reg <= #0.1 0;
        else if(comp_start_hd==1'b1)
            comp_done_hd_reg <= #0.1 0;
        else if(comp_done_hd)
            comp_done_hd_reg <= #0.1 1;
    end

    always@(posedge clk or negedge rst_n) begin
        if(rst_n==1'b0)
            comp_done_rs_reg <= #0.1 0;
        else if(comp_start_rs==1'b1)
            comp_done_rs_reg <= #0.1 0;
        else if(comp_done_rs)
            comp_done_rs_reg <= #0.1 1;
    end

    reg comp_done_fc_reg;
    always@(posedge clk or negedge rst_n) begin
        if(rst_n==1'b0)
            comp_done_fc_reg <= #0.1 0;
        else if(comp_start_fc==1'b1)
            comp_done_fc_reg <= #0.1 0;
        else if(comp_done_fc)
            comp_done_fc_reg <= #0.1 1;
    end

    always@(posedge clk or negedge rst_n) begin
        if(rst_n==1'b0)
            ra_rdata <= #0.1 0;
        else if(ra_arvalid && ra_arready) begin
            case(ra_araddr)

                DEBUG_REG_ADDR    : ra_rdata <= #0.1 debug_reg;
                COMPUTE_DONE_ADDR : ra_rdata <= #0.1 {31'd0,comp_done_reg};
                HD_COMP_DONE_ADDR : ra_rdata <= #0.1 {31'd0,comp_done_hd_reg};
                RS_COMP_DONE_ADDR : ra_rdata <= #0.1 {31'd0,comp_done_rs_reg};
                FC_COMP_DONE_ADDR : ra_rdata <= #0.1 {31'd0,comp_done_fc_reg};
                RFU_RADDR0        : ra_rdata <= #0.1 rfu_rreg0;
                RFU_RADDR1        : ra_rdata <= #0.1 rfu_rreg1;
                RFU_RADDR2        : ra_rdata <= #0.1 rfu_rreg2;               
                RFU_RADDR3        : ra_rdata <= #0.1 rfu_rreg3;
                RFU_RADDR4        : ra_rdata <= #0.1 rfu_rreg4;
                RFU_RADDR5        : ra_rdata <= #0.1 rfu_rreg5;
                RFU_RADDR6        : ra_rdata <= #0.1 rfu_rreg6;
                RFU_RADDR7        : ra_rdata <= #0.1 rfu_rreg7;
                RFU_RADDR8        : ra_rdata <= #0.1 rfu_rreg8;
                RFU_RADDR9        : ra_rdata <= #0.1 rfu_rreg9;
                16'h30            : ra_rdata <= #0.1 GATHER_VERSION;
                16'h60            : ra_rdata <= #0.1 HD_VERSION;
                16'h70            : ra_rdata <= #0.1 RS_VERSION;
                FC_VER_ADDR       : ra_rdata <= #0.1 FC_VERSION;
              
                default : ra_rdata <= #0.1 32'hFFFFFFFF;
            endcase
        end
    end

endmodule


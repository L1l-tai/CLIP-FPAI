//================================================================================
// File Name     : arbiter.v
// Project       :
// Create Date   : 2026.04.25
// Description   :
// DMA仲裁器：实现Gather、Hadamard和Resize到DMA接口的信号选择
// 同一时间只允许一个模块访问DMA，无抢占机制
// DMA功能由原有dma模块完成
//--------------------------------------------------------------------------------
// Modification History :
//================================================================================

module arbiter (
    //============ Gather DMA接口 ============
    input        [31:0]   gather_arbase      ,
    input        [15:0]   gather_arsize      ,
    input        [31:0]   gather_awbase      ,
    input        [15:0]   gather_awsize      ,
    input                 gather_rd_start    ,
    input                 gather_wr_start    ,
    input        [511:0]  gather_comp_data  ,
    input                 gather_din_ready  ,
    input                 gather_data_valid  ,
    output                gather_data_ready  ,
    output                gather_rd_done    ,
    output                gather_wr_done    ,
    input                 gather_comp_done   ,

    //============ Hadamard DMA接口 ============
    input        [31:0]   hadamard_arbase    ,
    input        [15:0]   hadamard_arsize    ,
    input        [31:0]   hadamard_awbase    ,
    input        [15:0]   hadamard_awsize    ,
    input                 hadamard_rd_start  ,
    input                 hadamard_wr_start  ,
    input                 hadamard_din_ready ,
    input        [511:0]  hadamard_dout      ,
    input                 hadamard_dout_valid,
    output                hadamard_dout_ready,
    output                hadamard_rd_done  ,
    output                hadamard_wr_done  ,
    input                 hadamard_comp_done ,

    //============ Resize DMA接口 ============
    input        [31:0]   resize_arbase      ,
    input        [15:0]   resize_arsize      ,
    input        [31:0]   resize_awbase      ,
    input        [15:0]   resize_awsize      ,
    input                 resize_rd_start    ,
    input                 resize_wr_start    ,
    input                 resize_din_ready   ,
    input        [511:0]  resize_dout        ,
    input                 resize_dout_valid  ,
    output                resize_rd_done    ,
    output                resize_wr_done    ,
    input                 resize_comp_done   ,

    //============ 连接到DMA的接口 ============
    output       [31:0]   itf_arbase         ,  // DMA读地址基地址
    output       [15:0]   itf_arsize         ,  // DMA读数据长度
    output       [31:0]   itf_awbase         ,  // DMA写地址基地址
    output       [15:0]   itf_awsize         ,  // DMA写数据长度
    output                itf_rd_start       ,  // DMA读启动信号
    output                itf_wr_start       ,  // DMA写启动信号
    output       [511:0]  itf_comp_data      ,  // DMA写入数据
    output                itf_data_valid     ,  // DMA数据有效信号
    output                itf_rready         ,

    input                 itf_data_ready     ,  // DMA数据接收就绪
    input                 itf_rd_done        ,  // DMA读完成信号
    input                 itf_wr_done        ,  // DMA写完成信号

    //============ 控制信号 ============
    input                 gather_comp_start  ,
    input                 hadamard_comp_start,
    input                 resize_comp_start ,

    input                 clk               ,
    input                 rst_n
);

    // 仲裁状态
    localparam IDLE     = 3'b00;
    localparam GATHER   = 3'b01;
    localparam HADAMARD = 3'b10;
    localparam RESIZE   = 3'b11;

    reg [2:0] grant;
    reg       gather_active;
    reg       hadamard_active;
    reg       resize_active;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            gather_active <= 1'b0;
        end
        else begin
            if(gather_comp_start) begin
                gather_active <= 1'b1;
            end
            else if(gather_comp_done) begin
                gather_active <= 1'b0;
            end
            else begin
                gather_active <= gather_active;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            hadamard_active <= 1'b0;
        end
        else begin
            if(hadamard_comp_start) begin
                hadamard_active <= 1'b1;
            end
            else if(hadamard_comp_done) begin
                hadamard_active <= 1'b0;
            end
            else begin
                hadamard_active <= hadamard_active;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            resize_active <= 1'b0;
        end
        else begin
            if(resize_comp_start) begin
                resize_active <= 1'b1;
            end
            else if(resize_comp_done) begin
                resize_active <= 1'b0;
            end
            else begin
                resize_active <= resize_active;
            end
        end
    end

    // 仲裁逻辑
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grant <= IDLE;
        end
        else begin
            case (grant)
                IDLE: begin
                    if (gather_active && !gather_comp_done) begin
                        grant <= GATHER;
                    end
                    else if (hadamard_active && !hadamard_comp_done) begin
                        grant <= HADAMARD;
                    end
                    else if (resize_active && !resize_comp_done) begin
                        grant <= RESIZE;
                    end
                end
                GATHER: begin
                    if (gather_comp_done) begin
                        grant <= IDLE;
                    end
                end
                HADAMARD: begin
                    if (hadamard_comp_done) begin
                        grant <= IDLE;
                    end
                end
                RESIZE: begin
                    if (resize_comp_done) begin
                        grant <= IDLE;
                    end
                end
                default: grant <= IDLE;
            endcase
        end
    end

    wire gather_grant   = (grant == GATHER);
    wire hadamard_grant = (grant == HADAMARD);
    wire resize_grant   = (grant == RESIZE);

    // ============ DMA信号选择 ============

    // 读地址基地址
    assign itf_arbase = gather_grant   ? gather_arbase   :
                        hadamard_grant ? hadamard_arbase :
                        resize_grant   ? resize_arbase   : 32'b0;

    // 读数据长度
    assign itf_arsize = gather_grant   ? gather_arsize   :
                        hadamard_grant ? hadamard_arsize :
                        resize_grant   ? resize_arsize   : 16'b0;

    // 读启动信号
    assign itf_rd_start = gather_grant   ? gather_rd_start   :
                           hadamard_grant ? hadamard_rd_start :
                           resize_grant   ? resize_rd_start   : 1'b0;

    // 写地址基地址
    assign itf_awbase = gather_grant   ? gather_awbase   :
                        hadamard_grant ? hadamard_awbase :
                        resize_grant   ? resize_awbase   : 32'b0;

    // 写数据长度
    assign itf_awsize = gather_grant   ? gather_awsize   :
                        hadamard_grant ? hadamard_awsize :
                        resize_grant   ? resize_awsize   : 16'b0;

    // 写启动信号
    assign itf_wr_start = gather_grant   ? gather_wr_start   :
                           hadamard_grant ? hadamard_wr_start :
                           resize_grant   ? resize_wr_start   : 1'b0;

    // 写数据
    assign itf_comp_data = gather_grant   ? gather_comp_data  :
                           hadamard_grant ? hadamard_dout     :
                           resize_grant   ? resize_dout       : 512'b0;

    // 数据有效信号
    assign itf_data_valid = gather_grant   ? gather_data_valid   :
                             hadamard_grant ? hadamard_dout_valid :
                             resize_grant   ? resize_dout_valid   : 1'b0;

    // 数据接收就绪信号
    assign itf_rready = gather_grant   ? gather_din_ready   :
                        hadamard_grant ? hadamard_din_ready :
                        resize_grant   ? resize_din_ready   : 1'b0;

    // ============ 完成信号路由 ============
    assign gather_data_ready    = gather_grant   ? itf_data_ready : 1'b0;
    assign gather_rd_done       = gather_grant   ? itf_rd_done : 1'b0;
    assign gather_wr_done       = gather_grant   ? itf_wr_done : 1'b0;
    assign hadamard_dout_ready  = hadamard_grant ? itf_data_ready : 1'b0;
    assign hadamard_rd_done     = hadamard_grant ? itf_rd_done : 1'b0;
    assign hadamard_wr_done     = hadamard_grant ? itf_wr_done : 1'b0;
    assign resize_dout_ready    = resize_grant   ? itf_data_ready : 1'b0;
    assign resize_rd_done       = resize_grant   ? itf_rd_done : 1'b0;
    assign resize_wr_done       = resize_grant   ? itf_wr_done : 1'b0;

endmodule

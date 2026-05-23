`timescale 1ns / 1ps

module resize_sim;

    // 参数定义
    localparam CLK_PERIOD = 10;      // 10ns = 100MHz
    localparam RA_CLK_PERIOD = 10;   // 10ns = 100MHz

    // 测试数据参数
    localparam SRC_WIDTH = 64;       // 源图像宽度
    localparam SRC_HEIGHT = 48;      // 源图像高度 (与宽度不同, 测试center crop)
    localparam DST_WIDTH = 32;
    localparam DST_HEIGHT = 32;
    localparam CROP_ENABLE = 1;      // 1=启用center crop to square, 0=不裁剪

    // 计算实际有效的源尺寸 (crop后)
    localparam CROP_SIZE = (SRC_WIDTH < SRC_HEIGHT) ? SRC_WIDTH : SRC_HEIGHT;  // 短边=48

    // 缩放比例 (Q1.3.12 / Q1.7.8)
    localparam [15:0] RESIZE_RATIO_LESS = (DST_WIDTH << 12) / CROP_SIZE;
    localparam [15:0] RESIZE_RATIO_GREATER = (CROP_SIZE << 8) / DST_WIDTH;

    localparam SRC_BASE_ADDR = 32'h0000_2000;
    localparam DST_BASE_ADDR = 32'h0001_0000;

    // 输入信号
    reg clk;
    reg ra_clk;
    reg rst_n;
    reg ra_rst_n;

    // 寄存器访问接口
    reg  [31:0] itf_ra_awaddr;
    reg  [31:0] itf_ra_awdata;
    reg         itf_ra_awvalid;
    wire        itf_ra_awready;

    reg  [31:0] itf_ra_araddr;
    reg         itf_ra_arvalid;
    wire        itf_ra_arready;

    wire [31:0] itf_ra_rdata;
    wire        itf_ra_rvalid;
    reg         itf_ra_rready;

    // DMA接口
    wire [31:0] itf_awaddr;
    wire [511:0] itf_awdata;
    wire        itf_awvalid;
    reg         itf_awready;

    wire [31:0] itf_araddr;
    wire        itf_arvalid;
    reg         itf_arready;

    reg  [511:0] itf_rdata;
    reg         itf_rvalid;
    wire        itf_rready;

    wire        reset_reg;

    // DUT实例化
    customop_top U_customop_top (
        .itf_ra_awaddr     (itf_ra_awaddr),
        .itf_ra_awdata     (itf_ra_awdata),
        .itf_ra_awvalid    (itf_ra_awvalid),
        .itf_ra_awready    (itf_ra_awready),
        .itf_ra_araddr     (itf_ra_araddr),
        .itf_ra_arvalid    (itf_ra_arvalid),
        .itf_ra_arready    (itf_ra_arready),
        .itf_ra_rdata      (itf_ra_rdata),
        .itf_ra_rvalid     (itf_ra_rvalid),
        .itf_ra_rready     (itf_ra_rready),

        .itf_awaddr        (itf_awaddr),
        .itf_awdata        (itf_awdata),
        .itf_awvalid       (itf_awvalid),
        .itf_awready       (itf_awready),
        .itf_araddr        (itf_araddr),
        .itf_arvalid       (itf_arvalid),
        .itf_arready       (itf_arready),
        .itf_rdata         (itf_rdata),
        .itf_rvalid        (itf_rvalid),
        .itf_rready        (itf_rready),

        .reset_reg         (reset_reg),
        .clk               (clk),
        .ra_clk            (ra_clk),
        .rst_n             (rst_n),
        .ra_rst_n          (ra_rst_n)
    );

    // 时钟生成
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    initial begin
        ra_clk = 0;
        forever #(RA_CLK_PERIOD/2) ra_clk = ~ra_clk;
    end

    // 仿真用内存模型
    reg [511:0] mem [0:4095];
    integer i;

    function automatic integer get_mem_index;
        input [31:0] addr;
        begin
            get_mem_index = addr / 64;
        end
    endfunction

    // 支持非 64B 对齐读取: 跨两个 512-bit 块拼接
    function [511:0] read_mem_unaligned;
        input [31:0] addr;
        integer blk_idx, byte_off;
        reg [1023:0] combined;
        begin
            blk_idx  = addr / 64;
            byte_off = addr % 64;
            if (byte_off == 0) begin
                read_mem_unaligned = mem[blk_idx];
            end else begin
                combined = {mem[blk_idx + 1], mem[blk_idx]};
                read_mem_unaligned = combined >> (8 * byte_off);
            end
        end
    endfunction

    localparam DST_BLOCKS_PER_ROW = (DST_WIDTH + 15) / 16;  // ceil(DST_W/16)

    reg read_busy;
    reg pending_awvalid;
    reg [31:0] pending_awaddr;

    // 复位序列
    initial begin
        rst_n = 0;
        ra_rst_n = 0;
        itf_ra_awaddr = 0;
        itf_ra_awdata = 0;
        itf_ra_awvalid = 0;
        itf_ra_araddr = 0;
        itf_ra_arvalid = 0;
        itf_ra_rready = 0;
        itf_awready = 0;
        itf_arready = 0;
        itf_rdata = 0;
        itf_rvalid = 0;
        read_busy = 0;
        pending_awvalid = 0;
        pending_awaddr = 0;

        #100;
        rst_n = 1;
        ra_rst_n = 1;
        #100;

        // 初始化内存
        $display("Initializing Memory Array...");
        for (i = 0; i < 4096; i = i + 1) begin
            mem[i] = 512'd0;
        end

        // --- 从文件加载源图像 ---
        $display("Loading Source Image from resize-input-src.mem (%d x %d)...",
                 SRC_WIDTH, SRC_HEIGHT);
        $readmemh("resize-input-src.mem", mem, get_mem_index(SRC_BASE_ADDR));
        $display("  Loaded, first_pixel=0x%08X", mem[get_mem_index(SRC_BASE_ADDR)][31:0]);

        // --- 寄存器配置 ---
        $display("Configuring Resize Registers (CROP_ENABLE=%d)...", CROP_ENABLE);

        // 源图像尺寸
        ra_write_reg(16'h44, {SRC_WIDTH[15:0], SRC_HEIGHT[15:0]});
        // 目标图像尺寸
        ra_write_reg(16'h45, {DST_WIDTH[15:0], DST_HEIGHT[15:0]});
        // 源基地址
        ra_write_reg(16'h42, SRC_BASE_ADDR);
        // 目标基地址
        ra_write_reg(16'h43, DST_BASE_ADDR);
        // 缩放比
        ra_write_reg(16'h09, RESIZE_RATIO_LESS);
        ra_write_reg(16'h0a, RESIZE_RATIO_GREATER);
        // crop_enable (rfu_wreg6[0])
        ra_write_reg(16'h0b, {31'd0, CROP_ENABLE});

        // 启动
        $display("Starting Resize (crop=%d: %dx%d -> %dx%d)...",
                 CROP_ENABLE, SRC_WIDTH, SRC_HEIGHT, DST_WIDTH, DST_HEIGHT);
        ra_write_reg(16'h41, 32'h0000_0001);

        // --- DMA传输 + 超时 ---
        fork
            begin
                #5000000;
                $display("ERROR: Simulation Timeout!");
                $finish;
            end
            begin
                wait (reset_reg == 1);
                $display("Computation Done Signal Detected.");
            end
        join_none

        serve_axi_transactions();
        #50;
        $display("DMA Transfer Completed.");

        // --- 硬件输出写入文件 ---
        write_mem_to_file("resize-output.mem",
                          DST_BASE_ADDR, DST_HEIGHT * DST_BLOCKS_PER_ROW);

        $display("========================================");
        $display("RESIZE SIMULATION COMPLETED");
        $display("========================================");

        #100;
        $finish;
    end

    // $writememh 写入
    task write_mem_to_file;
        input string filename;
        input [31:0] base_addr;
        input integer num_blocks;
        integer start_idx, end_idx;
        begin
            start_idx = get_mem_index(base_addr);
            end_idx   = get_mem_index(base_addr + (num_blocks - 1) * 64);
            $writememh(filename, mem, start_idx, end_idx);
            $display("Wrote %d blocks to %s", num_blocks, filename);
        end
    endtask

    // 寄存器写入
    task ra_write_reg;
        input [15:0] addr_offset;
        input [31:0] data;
        begin
            @(posedge ra_clk);
            itf_ra_awaddr = addr_offset << 2;
            itf_ra_awdata = data;
            itf_ra_awvalid = 1;

            wait (itf_ra_awready);
            @(posedge ra_clk);
            itf_ra_awvalid = 0;
        end
    endtask

    // AXI事务处理 (延迟写模式, 匹配 hadamard/gather testbench)
    task serve_axi_transactions;
        integer trans_count;
        integer max_trans;
        begin
            max_trans = DST_WIDTH + DST_HEIGHT;

            trans_count = 0;
            while (trans_count < max_trans) begin
                @(posedge clk);

                // AR通道
                if (itf_arvalid && !itf_arready && !read_busy) begin
                    itf_arready <= 1;
                    $display("TB: AR Addr 0x%08X", itf_araddr);
                end else begin
                    itf_arready <= 0;
                end

                // R通道
                if (itf_arready && itf_arvalid) begin
                    fork
                        begin
                            reg [511:0] temp_data;
                            read_busy <= 1;
                            temp_data = read_mem_unaligned(itf_araddr);
                            itf_rdata <= temp_data;
                            itf_rvalid <= 1;
                            wait (itf_rready);
                            @(posedge clk);
                            itf_rvalid <= 0;
                            read_busy <= 0;
                        end
                    join_none
                end

                // AW通道
                if (itf_awvalid && !itf_awready) begin
                    itf_awready <= 1;
                    $display("TB: AW Addr 0x%08X", itf_awaddr);
                end else begin
                    itf_awready <= 0;
                end

                // W通道 (延迟一拍写入)
                if (itf_awvalid && itf_awready) begin
                    pending_awvalid <= 1;
                    pending_awaddr <= itf_awaddr;
                end
                if (pending_awvalid) begin
                    integer w_idx;
                    w_idx = get_mem_index(pending_awaddr);
                    mem[w_idx] <= itf_awdata;
                    $display("TB: Wrote to Addr 0x%08X (Idx %d)", pending_awaddr, w_idx);
                    pending_awvalid <= 0;
                    trans_count = trans_count + 1;
                end
            end
        end
    endtask

endmodule

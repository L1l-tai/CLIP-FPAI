`timescale 1ns / 1ps

module resize_sim;

    // 参数定义
    localparam CLK_PERIOD = 10;      // 10ns = 100MHz
    localparam RA_CLK_PERIOD = 10;   // 10ns = 100MHz

    // 测试数据参数
    // 假设源图像: 64x64 像素
    // 目标图像: 32x32 像素 (下采样)
    localparam SRC_WIDTH = 64;
    localparam SRC_HEIGHT = 64;
    localparam DST_WIDTH = 32;
    localparam DST_HEIGHT = 32;
    localparam PIXEL_WIDTH = 32;     // 像素位宽: {8'b0, R, G, B}

    localparam SRC_BASE_ADDR = 32'h0000_2000;
    localparam DST_BASE_ADDR = 32'h0001_0000;

    // 输入信号
    reg clk;
    reg ra_clk;
    reg rst_n;
    reg ra_rst_n;

    // 寄存器访问接口 (DUT中为从机, TB中为主机)
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

    // DMA接口 (DUT中为主机, TB中为从机/内存模型)
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
    reg error_flag;

    // 地址到内存索引的映射函数 (以 64-byte/512-bit 行为单位)
    function automatic integer get_mem_index;
        input [31:0] addr;
        begin
            get_mem_index = addr / 64;
        end
    endfunction

    // 获取字节偏移
    function automatic integer get_byte_offset;
        input [31:0] addr;
        begin
            get_byte_offset = addr % 64;
        end
    endfunction

    // 生成测试图像像素
    function [31:0] gen_pixel;
        input [15:0] x;
        input [15:0] y;
        begin
            // 生成简单的渐变图像 R=x, G=y, B=(x+y)/2
            gen_pixel = {8'b0, x[7:0], y[7:0], ((x[7:0] + y[7:0]) >> 1)};
        end
    endfunction

    reg read_busy;
    reg write_busy;

    // 复位序列
    initial begin
        // 初始化输出
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
        write_busy = 0;

        // 等待全局复位
        #100;
        rst_n = 1;
        ra_rst_n = 1;
        #100;

        // 初始化内存数组所有单元为0
        $display("Initializing Memory Array...");
        for (i = 0; i < 4096; i = i + 1) begin
            mem[i] = 512'd0;
        end

        // --- 准备测试数据 ---
        // 源图像: SRC_WIDTH x SRC_HEIGHT 像素
        // 每个内存行存储 16 个像素 (16 * 32bit = 512bit)
        $display("Loading Source Image (%d x %d)...", SRC_WIDTH, SRC_HEIGHT);

        for (i = 0; i < SRC_HEIGHT; i = i + 1) begin
            integer j;
            integer src_addr;
            reg [511:0] line_data;
            line_data = 512'd0;

            for (j = 0; j < SRC_WIDTH; j = j + 1) begin
                reg [31:0] pixel;
                pixel = gen_pixel(j, i);
                // 每个像素32bit，16个像素填满一行512bit
                line_data[j * 32 +: 32] = pixel;
            end

            src_addr = SRC_BASE_ADDR + i * 64;
            mem[get_mem_index(src_addr)] = line_data;
            $display("  Row[%d] @ Addr 0x%08X, first_pixel=0x%08X", i, src_addr, line_data[31:0]);
        end

        // --- 通过寄存器访问进行配置阶段 ---

        $display("Configuring Resize Registers...");

        // 1. 设置源图像尺寸 (RS_RSIZE_ADDR = 16'h44, 高16bit=宽, 低16bit=高)
        ra_write_reg(16'h44, {SRC_WIDTH[15:0], SRC_HEIGHT[15:0]});

        // 2. 设置目标图像尺寸 (RS_WSIZE_ADDR = 16'h45, 高16bit=宽, 低16bit=高)
        ra_write_reg(16'h45, {DST_WIDTH[15:0], DST_HEIGHT[15:0]});

        // 3. 设置源图像基地址 (RS_RBASE_ADDR = 16'h42)
        ra_write_reg(16'h42, SRC_BASE_ADDR);

        // 4. 设置目标图像基地址 (RS_WBASE_ADDR = 16'h43)
        ra_write_reg(16'h43, DST_BASE_ADDR);

        // 5. 启动 Resize 计算 (RS_COMP_START_ADDR = 16'h41)
        $display("Starting Resize Computation (Source: %d x %d -> Dest: %d x %d)...",
                 SRC_WIDTH, SRC_HEIGHT, DST_WIDTH, DST_HEIGHT);
        ra_write_reg(16'h41, 32'h0000_0001);

        // --- DMA传输阶段 ---

        error_flag = 0;

        // 运行仿真直到完成或超时
        fork
            begin
                // 超时监视器
                #5000000;
                $display("ERROR: Simulation Timeout!");
                $finish;
            end
            begin
                // 监控完成状态
                wait (reset_reg == 1);
                $display("Computation Done Signal Detected.");
            end
        join_none

        // 服务 AXI 事务
        serve_axi_transactions();

        $display("DMA Transfer Completed.");

        // --- 验证阶段 ---
        $display("Verifying Results...");

        // 检查是否有数据写入目标地址
        for (i = 0; i < DST_HEIGHT; i = i + 1) begin
            integer dst_addr;
            integer dst_idx;
            reg [511:0] result_line;

            dst_addr = DST_BASE_ADDR + i * 64;
            dst_idx = get_mem_index(dst_addr);
            result_line = mem[dst_idx];

            // 检查是否有非零数据写入
            if (result_line != 512'd0) begin
                $display("PASS at Row[%d]: Addr 0x%08X, first_pixel=0x%08X",
                         i, dst_addr, result_line[31:0]);
            end else begin
                $display("WARNING at Row[%d]: Addr 0x%08X, No data written",
                         i, dst_addr);
            end
        end

        $display("========================================");
        $display("RESIZE SIMULATION COMPLETED");
        $display("========================================");

        #100;
        $finish;
    end

    // 向寄存器访问接口写入的任务
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

    // 处理来自 DUT 的 AXI 读写事务的过程
    task serve_axi_transactions;
        integer trans_count;
        integer max_trans;
        begin
            // 估算最大事务数
            // 源图像: SRC_HEIGHT 行
            // 目标图像: DST_HEIGHT 行
            // 每次迭代可能需要读写多行
            max_trans = (SRC_HEIGHT + DST_HEIGHT) * 2;

            trans_count = 0;
            while (trans_count < max_trans) begin
                @(posedge clk);

                // 处理读地址通道 (AR)
                if (itf_arvalid && !itf_arready && !read_busy) begin
                    itf_arready <= 1;
                    $display("TB: Received AR Addr: 0x%08X", itf_araddr);
                end else begin
                    itf_arready <= 0;
                end

                // 处理读数据通道 (R)
                if (itf_arready && itf_arvalid && !read_busy) begin
                    fork
                        begin
                            integer r_idx;
                            reg [511:0] temp_data;

                            read_busy <= 1;

                            r_idx = get_mem_index(itf_araddr);
                            temp_data = mem[r_idx];
                            itf_rdata <= temp_data;
                            itf_rvalid <= 1;
                            $display("TB: Sent R Data from Idx %d (Addr 0x%08X), first32=0x%08X",
                                     r_idx, itf_araddr, temp_data[31:0]);

                            wait (itf_rready);
                            @(posedge clk);
                            itf_rvalid <= 0;
                            read_busy <= 0;
                        end
                    join_none
                end

                // 处理写地址通道 (AW)
                if (itf_awvalid && !itf_awready && !write_busy) begin
                    itf_awready <= 1;
                    $display("TB: Received AW Addr: 0x%08X", itf_awaddr);
                end else begin
                    itf_awready <= 0;
                end

                // 处理写数据通道 (W)
                if (itf_awvalid && itf_awready && !write_busy) begin
                    fork
                        begin
                            integer w_idx;
                            write_busy <= 1;

                            w_idx = get_mem_index(itf_awaddr);
                            mem[w_idx] <= itf_awdata;
                            $display("TB: Wrote Data 0x%08X to Addr 0x%08X (Idx: %d)",
                                     itf_awdata[31:0], itf_awaddr, w_idx);
                            trans_count = trans_count + 1;
                            write_busy <= 0;
                        end
                    join_none
                end
            end
        end
    endtask

endmodule

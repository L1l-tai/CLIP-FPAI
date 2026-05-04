`timescale 1ns / 1ps

module hadamard_sim;

    // 参数定义
    localparam CLK_PERIOD = 10;      // 10ns = 100MHz
    localparam RA_CLK_PERIOD = 10;   // 10ns = 100MHz

    // 测试数据参数 (FP16模式)
    localparam TOTAL_BLOCKS = 8;      // 8个512bit数据块 = 64个FP16数据 × 4次迭代
    localparam FP16_PER_BLOCK = 32; // 每个512bit块包含32个FP16数据

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

    // FP16 helper function: convert integer to FP16 format (IEEE 754 half-precision)
    function [15:0] int_to_fp16;
        input [31:0] value;
        integer exp;
        integer mant;
        integer i;
        begin
            // Handle zero
            if (value == 0) begin
                int_to_fp16 = 16'h0000;
            end
            else begin
                // Find the exponent (position of leading 1)
                exp = 0;
                for (i = 30; i >= 0; i = i - 1) begin
                    if (value[i]) begin
                        exp = i;
                    end
                end

                // Calculate mantissa
                if (exp < 10) begin
                    // Small value: shift left to create proper mantissa format
                    mant = (value << (10 - exp)) & 10'h3FF;
                end
                else begin
                    // Large value: shift right to fit in 10 bits
                    mant = (value >> (exp - 10)) & 10'h3FF;
                end

                // Combine: Sign(1) + Exponent(5) + Mantissa(10)
                int_to_fp16 = {1'b0, (exp[4:0] + 5'd15), mant[9:0]};
            end
        end
    endfunction

    reg read_busy;
    reg pending_awvalid;
    reg [31:0] pending_awaddr;
    reg [511:0] pending_awdata;

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
        pending_awvalid = 0;
        pending_awaddr = 0;
        pending_awdata = 0;

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

        // --- 准备测试数据 (FP16格式) ---
        // FP16: 每个数据16bit, 每个512bit块包含32个FP16数据
        // 每个iteration需要2个DMA beats (共64个FP16数据)

        $display("Loading FP16 Source Data...");

        // 每个FWHT块需要64个FP16数据: 1, 2, 3, ... 64
        // 分2个512bit块写入，每个块32个FP16
        // 后续内存重复赋值四次（共8个块，模拟多次迭代）
        // Block i 的数据为 j + 1 + i*0.5 (j=1~32, i=0~7)
        for (i = 0; i < 8; i = i + 1) begin
            integer j;
            integer src_addr;
            src_addr = SRC_BASE_ADDR + i * 64;  // 每个块64字节

            // 填充32个FP16数据
            for (j = 0; j < 32; j = j + 1) begin
                integer word_idx;
                integer bit_pos;
                reg [15:0] fp16_val;
                reg [15:0] fp16_half;
                word_idx = j / 2;  // 2个FP16打包成一个32bit word
                bit_pos = word_idx * 32;  // 32bit per word

                // 生成FP16数据
                fp16_val = int_to_fp16(j + 1 + (i >> 1));  // i>>1 = i/2 (integer part)
                fp16_half = 16'h0035;  
                if (i[0]) begin  // i为奇数时加0035
                    fp16_val = fp16_val + fp16_half;
                end

                if (j % 2 == 0) begin
                    // 低16位
                    mem[get_mem_index(src_addr)][bit_pos+ : 15] = fp16_val;
                end else begin
                    // 高16位
                    mem[get_mem_index(src_addr)][bit_pos + 16 + : 16] = fp16_val;
                end
            end
            $display("  Block[%d] @ Addr 0x%08X, base=%.1f, first=0x%04X, last=0x%04X",
                     i, src_addr, 1.0 + real'(i) * 0.5,
                     int_to_fp16(1 + (i >> 1)) + (i[0] ? 16'h3C00 : 16'h0000),
                     int_to_fp16(32 + (i >> 1)) + (i[0] ? 16'h3C00 : 16'h0000));
        end

        // --- 通过寄存器访问进行配置阶段 ---

        $display("Configuring Hadamard Registers...");

        // 1. 设置 hd_data_width (rfu_wreg2, Addr 0x07)
        // 每次迭代处理的数据量，这里设为2 (2个512bit块 per iteration)
        ra_write_reg(16'h07, 32'd2);

        // 2. 设置 hd_cal_percision (rfu_wreg3, Addr 0x08)
        // 1 = FP16 mode
        ra_write_reg(16'h08, 32'd1);

        // 3. 设置 Read Base (HD_RBASE_ADDR = 16'h32)
        ra_write_reg(16'h32, SRC_BASE_ADDR);

        // 4. 设置 Write Base (HD_WBASE_ADDR = 16'h33)
        ra_write_reg(16'h33, DST_BASE_ADDR);

        // 5. 设置 Write Size (HD_WRSIZE_ADDR = 16'h34)
        // 总共要处理的512bit数据块数量
        ra_write_reg(16'h34, TOTAL_BLOCKS);

        // 6. 启动 Hadamard 计算 (HD_COMP_START_ADDR = 16'h31)
        $display("Starting Hadamard Computation...");
        ra_write_reg(16'h31, 32'h0000_0001);

        // --- DMA传输阶段 ---

        error_flag = 0;

        // 运行仿真直到完成或超时
        fork
            begin
                // 超时监视器
                #500000;
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
        #50;

        $display("DMA Transfer Completed.");

        // --- 验证阶段 ---
        // 注: FWHT是Walsh-Hadamard变换，输出是输入的Hadamard变换结果
        // 这里仅做基本的格式验证，不验证具体数学结果

        $display("Verifying Results...");

        // 验证写入的数据格式是否正确
        for (i = 0; i < TOTAL_BLOCKS; i = i + 1) begin
            integer dst_addr;
            integer dst_idx;

            dst_addr = DST_BASE_ADDR + i * 64;
            dst_idx = get_mem_index(dst_addr);

            // 检查是否有非零数据写入
            if (mem[dst_idx] != 512'd0) begin
                $display("PASS at Block[%d]: Addr 0x%08X, Data[63:0] = 0x%08X",
                         i, dst_addr, mem[dst_idx][63:0]);
            end else begin
                $display("WARNING at Block[%d]: Addr 0x%08X, No data written",
                         i, dst_addr);
            end
        end

        $display("========================================");
        $display("SIMULATION COMPLETED");
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
            // FP16: 每个iteration需要2个read beats (64个FP16数据)
            // 2个blocks需要 2/2 = 1次iteration，需要1次read + 1次write
            max_trans = 8;

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
                if (itf_arready && itf_arvalid) begin
                    fork
                        begin
                            integer r_idx;
                            reg [511:0] temp_data;

                            read_busy <= 1;

                            r_idx = get_mem_index(itf_araddr);

                            temp_data = mem[r_idx];
                            itf_rdata <= temp_data;
                            itf_rvalid <= 1;
                            $display("TB: Sent R Data from Idx %d (Addr 0x%08X), first16=0x%04X",
                                     r_idx, itf_araddr, mem[r_idx][15:0]);

                            wait (itf_rready);
                            @(posedge clk);
                            itf_rvalid <= 0;
                            read_busy <= 0;
                        end
                    join_none
                end

                // 处理写地址通道 (AW)
                if (itf_awvalid && !itf_awready) begin
                    itf_awready <= 1;
                    $display("TB: Received AW Addr: 0x%08X", itf_awaddr);
                end else begin
                    itf_awready <= 0;
                end

                // 处理写数据通道 (W) - 延迟一拍写入
                if (itf_awvalid && itf_awready) begin
                    pending_awvalid <= 1;
                    pending_awaddr <= itf_awaddr;
                end

                // 下一周期写入内存
                if (pending_awvalid) begin
                    integer w_idx;
                    w_idx = get_mem_index(pending_awaddr);
                    mem[w_idx] <= itf_awdata;
                    $display("TB: Wrote Data 0x%04X to Addr 0x%08X (Idx: %d)",
                             itf_awdata[15:0], pending_awaddr, w_idx);
                    pending_awvalid <= 0;
                    trans_count = trans_count + 1;
                end
            end
        end
    endtask

endmodule
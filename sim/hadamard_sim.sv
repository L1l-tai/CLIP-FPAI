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

    // 观测 hadamard 完成信号 (层次化引用)
    wire        hd_comp_done;
    wire        hd_rd_data_ready;
    wire        hd_cal_percision;
    wire [1:0]  hd_rd_cnt;
    assign hd_comp_done     = U_customop_top.comp_done_hd;
    assign hd_rd_data_ready = U_customop_top.rd_data_ready_hd;
    assign hd_cal_percision = U_customop_top.U_hadamard.cal_percision;
    assign hd_rd_cnt        = U_customop_top.U_hadamard.rd_cnt;

    // 监控 rready 和 rd_data_ready 变化
    reg         itf_rready_r;
    always @(posedge clk) itf_rready_r <= itf_rready;
    wire rready_negedge = !itf_rready && itf_rready_r;
    wire [2:0] hd_fsm_state = U_customop_top.U_hadamard_fsm.state;
    always @(posedge clk) begin
        if (rready_negedge)
            $display("TB: *** rready FELL (rd_ready=%b rd_cnt=%d state=%d cal=%b) ***",
                     hd_rd_data_ready, hd_rd_cnt, hd_fsm_state, hd_cal_percision);
    end

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

    // ============================================================
    // $readmemh 加载数据 (最可靠, 不依赖 $fopen 文件权限)
    // 使用纯 hex 格式 .txt, 每行 128 hex 字符 = 512-bit 块
    // 用法: Vivado 中将 .txt 添加为 Simulation Source, 自动复制到仿真目录
    // ============================================================
    task load_mem_from_file;
        input string filename;
        input [31:0] base_addr;
        begin
            $display("Loading input from %s...", filename);
            $readmemh(filename, mem, get_mem_index(base_addr));
            $display("Loaded into memory starting at 0x%08X", base_addr);
        end
    endtask

    // ============================================================
    // 真实 AXI DDR 模型 (对齐硬件验证行为)
    // - AR: 脉冲式 ready + r_busy 串行化 (一次AR→一次R握手完成后才接受下一个)
    // - R:  AR握手后 READ_LATENCY 拍延迟, r_busy 在R握手后释放
    // - AW: 脉冲式 ready, 由 valid 唤醒
    // ============================================================
    localparam READ_LATENCY = 4;
    reg         r_busy;
    reg [31:0]  pending_ar_addr;
    reg [7:0]   r_latency_cnt;

    // ---- 读地址通道: 脉冲 ready + r_busy 串行化 ----
    always @(posedge clk) begin
        if (!rst_n) begin
            itf_arready <= 1'b0;
            r_busy      <= 1'b0;
        end else begin
            if (itf_arvalid && !itf_arready && !r_busy)
                itf_arready <= 1'b1;
            else
                itf_arready <= 1'b0;

            if (itf_arvalid && itf_arready) begin
                pending_ar_addr <= itf_araddr;
                r_busy <= 1'b1;
                $display("TB: AR Addr=0x%08X", itf_araddr);
            end
        end
    end

    // ---- 读数据通道: 延迟后返回, r_busy 在 R 握手完成后释放 ----
    always @(posedge clk) begin
        if (!rst_n) begin
            itf_rvalid     <= 1'b0;
            itf_rdata      <= 512'd0;
            r_latency_cnt  <= 0;
        end else begin
            if (itf_rvalid && itf_rready && r_queue_cnt > 0) begin
                itf_rvalid    <= 1'b0;
                r_busy        <= 1'b0;
                r_latency_cnt <= 0;
                $display("TB: R handshake Addr=0x%08X", pending_ar_addr);
            end

            if (r_busy && !itf_rvalid) begin
                if (r_latency_cnt < READ_LATENCY)
                    r_latency_cnt <= r_latency_cnt + 1'b1;
                else begin
                    itf_rdata  <= mem[get_mem_index(pending_ar_addr)];
                    itf_rvalid <= 1'b1;
                    $display("TB: R data Addr=0x%08X first16=0x%04X",
                             pending_ar_addr,
                             mem[get_mem_index(pending_ar_addr)][15:0]);
                end
            end
        end
    end

    // ---- 写通道: 脉冲式 ready ----
    always @(posedge clk) begin
        if (!rst_n) begin
            itf_awready <= 1'b0;
        end else begin
            if (itf_awvalid && !itf_awready)
                itf_awready <= 1'b1;
            else
                itf_awready <= 1'b0;

            if (itf_awvalid && itf_awready) begin
                mem[get_mem_index(itf_awaddr)] <= itf_awdata;
                $display("TB: Wrote Addr=0x%08X data[15:0]=0x%04X",
                         itf_awaddr, itf_awdata[15:0]);
            end
        end
    end

    // ============================================================
    // 测试序列
    // ============================================================
    initial begin
        rst_n = 0;
        ra_rst_n = 0;
        itf_ra_awaddr = 0;
        itf_ra_awdata = 0;
        itf_ra_awvalid = 0;
        itf_ra_araddr = 0;
        itf_ra_arvalid = 0;
        itf_ra_rready = 0;

        // 等待全局复位
        #100;
        rst_n = 1;
        ra_rst_n = 1;
        #100;

        // 初始化内存
        $display("Initializing Memory Array...");
        for (i = 0; i < 4096; i = i + 1) begin
            mem[i] = 512'd0;
        end

        // 加载测试数据
        load_mem_from_file("fwht-input-fp16.mem", SRC_BASE_ADDR);

        // 配置寄存器
        $display("Configuring Hadamard Registers...");
        ra_write_reg(16'h07, 32'd2);                           // hd_data_width
        ra_write_reg(16'h08, 32'd1);                           // cal_percision (FP16)
        ra_write_reg(16'h32, SRC_BASE_ADDR);                   // rbase_hd
        ra_write_reg(16'h33, DST_BASE_ADDR);                   // wbase_hd
        ra_write_reg(16'h34, TOTAL_BLOCKS);                    // wrsize_hd
        $display("Starting Hadamard Computation...");
        ra_write_reg(16'h31, 32'h0000_0001);                   // start

        // 等待 hadamard 计算完成
        $display("Waiting for completion...");
        fork
            begin
                #500000;
                $display("ERROR: Simulation Timeout!");
                $finish;
            end
            begin
                @(posedge hd_comp_done);
                $display("Computation Done (hd_comp_done = 1).");
            end
        join_any
        disable fork;

        // 等待最后的 AXI 写事务完成 + 内存模型流水线排空
        repeat (10) @(posedge clk);

        $display("DMA Transfer Completed.");

        // 验证
        $display("Verifying Results...");
        for (i = 0; i < TOTAL_BLOCKS; i = i + 1) begin
            integer dst_addr, dst_idx;
            dst_addr = DST_BASE_ADDR + i * 64;
            dst_idx = get_mem_index(dst_addr);
            if (mem[dst_idx] != 512'd0) begin
                $display("PASS Block[%d]: Addr 0x%08X Data[63:0]=0x%016X",
                         i, dst_addr, mem[dst_idx][63:0]);
            end else begin
                $display("WARNING Block[%d]: Addr 0x%08X No data written", i, dst_addr);
            end
        end

        write_mem_to_file("fwht-output-fp16.mem", DST_BASE_ADDR, TOTAL_BLOCKS);

        $display("========================================");
        $display("SIMULATION COMPLETED");
        $display("========================================");
        #100;
        $finish;
    end

    // 寄存器写入任务
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

    // 写内存到文件
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

endmodule
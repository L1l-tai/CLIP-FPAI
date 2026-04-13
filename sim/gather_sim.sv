`timescale 1ns / 1ps

module gather_sim;

    // 参数定义
    localparam CLK_PERIOD = 10;      // 10ns = 100MHz
    localparam RA_CLK_PERIOD = 10;   // 10ns = 100MHz
    
    // 测试数据参数
    // 修改: Indices 总宽度设置为 20
    localparam INDICES_LEN = 20;      
    localparam DATA_LEN = 32;
    
    // 修改: Data Width 配置
    // 说明: data_width 寄存器设置为 8
    // 含义: 每个 Gather 元素之间的步长为 8 个 DMA Beats (512-bit)
    // 8 * 64 Bytes = 512 Bytes per element.
    // 需求提及: "每行 Data 存有 128 个 word"
    // 假设 Word = 32-bit (4 Bytes), 128 * 4 = 512 Bytes。匹配成功
    localparam DATA_WIDTH_BEATS = 8; 
    localparam DATA_WIDTH_BYTES = DATA_WIDTH_BEATS * 64; // 512 Bytes

    localparam TOTAL_DATA_BEATS = INDICES_LEN * DATA_WIDTH_BEATS; 
    
    localparam IDX_BASE_ADDR = 32'h0000_1000;
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
    gather_top U_gather_top (
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
    // 修改: 增加内存大小至 1024 行，每行 512-bit
    reg [511:0] mem [0:2047]; 
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

    integer idx_addr;
    integer idx_val;
    integer mem_idx;
    integer byte_off;
    integer expected_indices [INDICES_LEN];
    reg read_busy;

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

        // 等待全局复位
        #100;
        rst_n = 1;
        ra_rst_n = 1;
        #100;

        // 初始化内存数组所有单元为0
        $display("Initializing Memory Array...");
        // 修改: 循环上限改为 1024 以匹配新的内存大小
        for (i = 0; i < 2048; i = i + 1) begin
            mem[i] = 512'd0;
        end

        // --- 准备测试数据 ---
        
        // 1. 初始化索引 (Indices)
        // 修改: 循环次数改为 INDICES_LEN (20)
        $display("Loading Indices...");
        
        // 索引存放于 IDX_BASE_ADDR
        // 20 个索引 * 4 字节 = 80 字节
        // Line 0 (0x1000): 存放 Index[0..15] (64 Bytes)
        // Line 1 (0x1040): 存放 Index[16..19] (16 Bytes)
        
        for (i = 0; i < INDICES_LEN; i++) begin
            // 生成简单的递增索引用于验证，或者保持之前的乱序逻辑
            // 这里使用 i % 16 确保索引在源数据的前几个元素中，避免访问未初始化内存
            idx_val = i % 16; 
            
            idx_addr = IDX_BASE_ADDR + i * 4;
            mem_idx = get_mem_index(idx_addr);
            byte_off = get_byte_offset(idx_addr);
            
            // 存入内存
            mem[mem_idx][byte_off*8 +: 32] = idx_val;
            $display("  Index[%d] = %d @ Addr 0x%08X", i, idx_val, idx_addr);
        end

        // 2. 初始化源数据 (Source Data)
        // 修改: 根据新的 Stride 初始化源数据
        // 每个元素占据 DATA_WIDTH_BYTES (512 Bytes = 8 Beats)
        $display("Loading Source Data...");
        for (i = 0; i < DATA_LEN; i++) begin
            integer src_base_addr;
            integer k;
            src_base_addr = SRC_BASE_ADDR + i * DATA_WIDTH_BYTES;
            
            // 填充该元素对应的 8 个 Beats
            for (k = 0; k < DATA_WIDTH_BEATS; k++) begin
                integer curr_addr;
                integer curr_idx;
                
                curr_addr = src_base_addr + k * 64;
                curr_idx = get_mem_index(curr_addr);
                
                if (k == 0) begin
                    mem[curr_idx] = i+k;
                end else begin
                    mem[curr_idx] = i+k; // 或其他填充
                end
            end
            $display("  Src[%d] Base @ 0x%08X (Stride %d Beats)", i, src_base_addr, DATA_WIDTH_BEATS);
        end

        // --- 通过寄存器访问进行配置阶段 ---
        
        $display("Configuring Registers...");

        // 1. 设置 Indices Width (rfu_wreg0, Addr 0x05)
        // 修改: 写入 20
        ra_write_reg(16'h05, INDICES_LEN);
        
        // 2. 设置 Data Width (rfu_wreg1, Addr 0x06)
        // 修改: 写入 8 (表示步长为 8 个 DMA Beats)
        ra_write_reg(16'h06, DATA_WIDTH_BEATS);

        // 3. 设置 Read Indices Base & Size (rbase1/rsize1, Addr 0x01)
        // Indices 总共 80 Bytes. 
        // DMA Beat = 64 Bytes.
        // 需要 2 个 Beats (Line 0 full, Line 1 partial).
        // Size = 2.
        ra_write_reg(16'h01, {16'd2, IDX_BASE_ADDR[15:0]});

        // 4. 设置 Read Data Base & Size (rbase2/rsize2, Addr 0x03)
        // 修改: Size = INDICES_LEN * DATA_WIDTH_BEATS
        // 20 * 8 = 160 Beats.
        ra_write_reg(16'h03,  SRC_BASE_ADDR);

        // 5. 设置 Write Base & Size (wbase1/wsize1, Addr 0x02)
        // 修改: Size = INDICES_LEN * DATA_WIDTH_BEATS
        // 输出也是同样大小的数据量
        ra_write_reg(16'h02,  DST_BASE_ADDR);

        // 6. 启动计算 (COMP_START_ADDR = 16'h00)
        $display("Starting Computation...");
        ra_write_reg(16'h00, 32'h0000_0001);

        // --- DMA传输阶段 ---
        
        error_flag = 0;
        
        // 运行仿真直到完成或超时
        fork
            begin
                // 超时监视器
                #100000;
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
        
        // 预期结果:
        // Indices[i] = i % 16
        // Src[k] 的第一个 Beat 的低 64位 = k
        // Expected Dest[i] 的第一个 Beat 的低 64位 = Indices[i]
        
        for (i = 0; i < INDICES_LEN; i++) begin
            expected_indices[i] = i % 16;
        end

        for (i = 0; i < INDICES_LEN; i++) begin
            integer dst_base_addr;
            integer dst_idx;
            reg [63:0] actual_val;
            reg [63:0] expected_val;
            
            // 目的地址基址 + 偏移
            dst_base_addr = DST_BASE_ADDR + i * DATA_WIDTH_BYTES;
            
            // 只验证每个元素的第一个 Beat (Offset 0)
            dst_idx = get_mem_index(dst_base_addr);
            
            actual_val = mem[dst_idx][63:0];
            
            // 预期值: Src[expected_indices[i]] 的低 64 位
            // Src[k] 的低 64 位被设置为 k
            expected_val = expected_indices[i];
            
            if (actual_val !== expected_val) begin
                $display("ERROR at Output[%d]: Addr 0x%08X. Expected %d (Src[%d]), Got %d", 
                         i, dst_base_addr, expected_val, expected_indices[i], actual_val);
                error_flag = 1;
            end else begin
                $display("PASS at Output[%d]: Addr 0x%08x. %d == Src[%d]", i, dst_base_addr, actual_val, expected_indices[i]);
            end
        end

        if (!error_flag) begin
            $display("========================================");
            $display("SIMULATION PASSED");
            $display("========================================");
        end else begin
            $display("========================================");
            $display("SIMULATION FAILED");
            $display("========================================");
        end

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
            // 修改: 重新估算最大事务数
            // 1. Read Indices: 2 beats
            // 2. Read Data: 20 * 8 = 160 beats
            // 3. Write Data: 20 * 8 = 160 beats
            // Total ~ 322 beats. Add buffer.
            max_trans = 160; 
            
            trans_count = 0;
            while (trans_count < max_trans) begin 
                @(posedge clk);
                
                // 修改: 处理读地址通道 (AR)
                // 只有当读通道不忙 (!read_busy) 且 DUT 发出有效地址请求 (itf_arvalid) 时，才拉高 ready
                if (itf_arvalid && !itf_arready && !read_busy) begin
                    itf_arready <= 1;
                    $display("TB: Received AR Addr: 0x%08X", itf_araddr);
                end else begin
                    itf_arready <= 0;
                end

                // 处理读数据通道 (R)
                if (itf_arready && itf_arvalid) begin
                    // 调度读数据响应
                    fork
                        begin
                            integer r_idx;
                            integer byte_off;
                            reg [511:0] temp_data;
                            
                            read_busy <= 1;

                            r_idx = get_mem_index(itf_araddr);
                            byte_off = get_byte_offset(itf_araddr);
                            
                            // 直接返回对齐的数据
                            temp_data = mem[r_idx];
                            itf_rdata <= temp_data;
                            itf_rvalid <= 1;
                            $display("TB: Sent R Data 0x%16X from Idx %d (Addr 0x%08X)", mem[r_idx][63:0], r_idx, itf_araddr);

                            wait (itf_rready);
                            @(posedge clk);
                            itf_rvalid <= 0;
                            
                            // 在 valid 拉低的同时或之后解除 busy
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

                // 处理写数据通道 (W)
                // 在 dma.v 中，awvalid 和 awdata 同时有效
                if (itf_awvalid && itf_awready) begin
                    integer w_idx;
                    w_idx = get_mem_index(itf_awaddr);
                    mem[w_idx] <= itf_awdata;
                    $display("TB: Wrote Data 0x%16X to Addr 0x%08X (Idx: %d)", itf_awdata[63:0], itf_awaddr, w_idx);
                    trans_count = trans_count + 1;
                    $display("TB: The %dth transportation", trans_count);
                end
            end
        end
    endtask

endmodule
`timescale 1ns / 1ps

module adder_sim;

    // 参数定义
    localparam CLK_PERIOD = 10; // 10ns = 100MHz
    localparam RA_CLK_PERIOD = 10; // 寄存器访问时钟 10ns = 100MHz
    
    // 测试数据参数
    localparam TEST_DATA_LEN = 16; // 处理的32位字数量
    localparam READ_BASE_ADDR = 32'h0000_1000;
    localparam WRITE_BASE_ADDR = 32'h0000_2000;

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
    wire [63:0] itf_awdata;
    wire        itf_awvalid;
    reg         itf_awready;

    wire [31:0] itf_araddr;
    wire        itf_arvalid;
    reg         itf_arready;

    reg  [63:0] itf_rdata;
    reg         itf_rvalid;
    wire        itf_rready;

    wire        reset_reg;

    // DUT实例化
    adder_top U_adder_top (
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
    // 修改为大小为64的固定数组，通过映射方式访问
    reg [63:0] mem [0:63];
    integer i;
    reg [31:0] expected_data;
    reg [31:0] actual_data;
    reg error_flag;

    // 地址到内存索引的映射函数
    function automatic integer get_mem_index;
        input [31:0] addr;
        begin
            // 读地址映射: 0-15
            if (addr >= READ_BASE_ADDR && addr < READ_BASE_ADDR + TEST_DATA_LEN * 64) begin
                get_mem_index = (addr - READ_BASE_ADDR) / 64;
            end
            // 写地址映射: 16-31
            else if (addr >= WRITE_BASE_ADDR && addr < WRITE_BASE_ADDR + TEST_DATA_LEN * 64) begin
                get_mem_index = (addr - WRITE_BASE_ADDR) / 64 + TEST_DATA_LEN;
            end
            else begin
                get_mem_index = 0; // 默认返回0，防止越界，实际应报错
                $display("Warning: Address 0x%08X out of mapped range", addr);
            end
        end
    endfunction

    // 复位序列
    initial begin
        // 初始化输入
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

        // 等待全局复位
        #100;
        rst_n = 1;
        ra_rst_n = 1;
        #100;

        // 初始化内存数组所有单元为0
        $display("Initializing Memory Array...");
        for (i = 0; i < 64; i = i + 1) begin
            mem[i] = 64'd0;
        end

        // 用测试数据初始化内存 (映射到读区域)
        $display("Loading Test Data...");
        for (i = 0; i < TEST_DATA_LEN; i = i + 1) begin
            // 计算映射后的索引
            integer idx;
            idx = get_mem_index(READ_BASE_ADDR + i*64);
            // 准备输入数据: i
            mem[idx] = {32'd0, i}; // 高32位为0，低32位为i
        end

        // --- 通过寄存器访问进行配置阶段 ---
        
        // 1. 设置读基地址和大小 (RSIZE_BASE_ADDR = 16'h01)
        // 数据格式: [31:16] 大小, [15:0] 基地址 (32位地址的低16位?)
        // reg_ctrl 使用 ra_awaddr[17:2]。所以地址 0x04 对应偏移量 1。
        // 让我们使用与顶层模块切片 [17:2] 逻辑匹配的字节地址
        
        // 写 RSIZE: Base=READ_BASE_ADDR[15:0], Size=TEST_DATA_LEN
        ra_write_reg(16'h01, {TEST_DATA_LEN, READ_BASE_ADDR[15:0]});
        
        // 写 WSIZE: Base=WRITE_BASE_ADDR[15:0], Size=TEST_DATA_LEN
        ra_write_reg(16'h02, {TEST_DATA_LEN, WRITE_BASE_ADDR[15:0]});

        // 2. 启动计算 (COMP_START_ADDR = 16'h00)
        ra_write_reg(16'h00, 32'h0000_0001);

        $display("Configuration Done. Starting DMA Transfer...");

        // --- DMA传输阶段 ---
        // DUT 现在将发出 AR 和 AW 请求。
        // 我们需要响应它们。
        
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
                wait (reset_reg == 1); // 可选：如果我们使用复位寄存器信号表示完成，但这里 comp_done 跨时钟域
                // 实际上，让我们只运行足够的周期或检查内部信号（如果可访问），
                // 但由于它们不易暴露，我们依赖事务计数。
            end
        join_none

        // 服务 AXI 事务
        serve_axi_transactions();

        $display("DMA Transfer Completed.");

        // --- 验证阶段 ---
        $display("Verifying Results...");
        for (i = 0; i < TEST_DATA_LEN; i = i + 1) begin
            // 计算写地址对应的映射索引
            integer w_idx;
            w_idx = get_mem_index(WRITE_BASE_ADDR + i*64);
            
            actual_data = mem[w_idx][31:0]; // 结果的低32位
            expected_data = i + 1; // adder.v 执行: sum = 1 + a
            
            if (actual_data !== expected_data) begin
                $display("ERROR at index %d: Expected %d, Got %d", i, expected_data, actual_data);
                error_flag = 1;
            end else begin
                $display("PASS at index %d: %d + 1 = %d", i, i, actual_data);
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
        input [15:0] addr_offset; // 32位字的偏移量 (匹配 ra_awaddr[17:2])
        input [31:0] data;
        begin
            @(posedge ra_clk);
            itf_ra_awaddr = {16'd0, addr_offset, 2'b00}; // 如果需要，左移2位以匹配字节地址逻辑，但顶层切片 [17:2]
            // 顶层模块: .ra_awaddr(itf_ra_awaddr[17:2])。所以如果我们想要偏移量1，我们发送4？
            // 让我们看看 reg_ctrl 地址。COMP_START_ADDR = 16'h00。
            // 如果我发送 awaddr=0, [17:2]=0。正确。
            // 如果我发送 awaddr=4, [17:2]=1。正确。
            
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
        begin
            trans_count = 0;
            while (trans_count <= TEST_DATA_LEN) begin // 期望有 READs 和 WRITEs
                @(posedge clk);
                
                // 处理读地址通道 (AR)
                if (itf_arvalid && !itf_arready) begin
                    itf_arready <= 1;
                    $display("TB: Received AR Addr: 0x%08X", itf_araddr);
                end else begin
                    itf_arready <= 0;
                end

                // 处理读数据通道 (R)
                // DUT 期望在 ar 握手后得到 rdata。
                // 简单模型：如果被接受，则在下一个周期立即响应
                if (itf_arready && itf_arvalid) begin
                    // 调度读数据响应
                    itf_rvalid <= 1;
                    fork
                        begin
                            integer r_idx;
                            @(posedge clk);
                            r_idx = get_mem_index(itf_araddr);
                            itf_rdata <= mem[r_idx];
                            //itf_rvalid <= 1;
                            wait (itf_rready);
                            @(posedge clk);
                            //itf_rvalid <= 0;
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

                // 处理写数据通道 (W) - 在此简单的 AXI-Lite 类或特定 DMA 实现中与 AW 组合
                // 在 dma.v 中，awvalid 与数据一起断言。它看起来像 AXI-Stream 类或简化的 AXI。
                // dma.v 赋值 awvalid = aawvalid && data_valid。
                // 所以当 awvalid 为高时，数据在 awdata 总线上有效。
                if (itf_awvalid && itf_awready) begin
                    integer w_idx;
                    w_idx = get_mem_index(itf_awaddr);
                    mem[w_idx] <= itf_awdata;
                    $display("TB: Wrote Data 0x%016X to Addr 0x%08X (Idx: %d)", itf_awdata, itf_awaddr, w_idx);
                    trans_count = trans_count + 1;
                    $display("Trans count: ", trans_count);
                end
            end
        end
    endtask

endmodule
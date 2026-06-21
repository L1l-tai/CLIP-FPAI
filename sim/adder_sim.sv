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

    // 仿真用内存模型 (64-bit 数据宽度, 与adder_demo DMA匹配)
    reg [63:0] mem [0:255];
    integer i;
    reg [31:0] expected_data;
    reg [31:0] actual_data;
    reg error_flag;

    // 地址到内存索引的映射函数
    function automatic integer get_mem_index;
        input [31:0] addr;
        begin
            if (addr >= READ_BASE_ADDR && addr < READ_BASE_ADDR + TEST_DATA_LEN * 64) begin
                get_mem_index = (addr - READ_BASE_ADDR) / 64;
            end
            else if (addr >= WRITE_BASE_ADDR && addr < WRITE_BASE_ADDR + TEST_DATA_LEN * 64) begin
                get_mem_index = (addr - WRITE_BASE_ADDR) / 64 + TEST_DATA_LEN;
            end
            else begin
                get_mem_index = 0;
                $display("Warning: Address 0x%08X out of mapped range", addr);
            end
        end
    endfunction

    // ============================================================
    // 真实 AXI DDR 模型 (64-bit, 对齐硬件验证行为)
    // ============================================================
    localparam READ_LATENCY = 4;
    reg         r_busy;
    reg [31:0]  pending_ar_addr;
    reg [7:0]   r_latency_cnt;
    reg [15:0]  write_cnt;

    // AR: 脉冲 ready + r_busy 串行化
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

    // R: 延迟后返回 (64-bit), r_busy 在 R 握手后释放
    always @(posedge clk) begin
        if (!rst_n) begin
            itf_rvalid     <= 1'b0;
            itf_rdata      <= 64'd0;
            r_latency_cnt  <= 0;
        end else begin
            if (itf_rvalid && itf_rready ) begin
                itf_rvalid    <= 1'b0;
                r_busy        <= 1'b0;
                r_latency_cnt <= 0;
            end

            if (r_busy && !itf_rvalid) begin
                if (r_latency_cnt < READ_LATENCY)
                    r_latency_cnt <= r_latency_cnt + 1'b1;
                else begin
                    itf_rdata  <= mem[get_mem_index(pending_ar_addr)];
                    itf_rvalid <= 1'b1;
                end
            end
        end
    end

    // AW: 脉冲式 ready
    always @(posedge clk) begin
        if (!rst_n) begin
            itf_awready <= 1'b0;
            write_cnt   <= 0;
        end else begin
            if (itf_awvalid && !itf_awready)
                itf_awready <= 1'b1;
            else
                itf_awready <= 1'b0;

            if (itf_awvalid && itf_awready) begin
                mem[get_mem_index(itf_awaddr)] <= itf_awdata;
                write_cnt <= write_cnt + 1'b1;
                $display("TB: Wrote Addr=0x%08X Data=0x%016X (cnt=%d)",
                         itf_awaddr, itf_awdata, write_cnt);
            end
        end
    end

    // 测试序列
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
        for (i = 0; i < 256; i = i + 1) begin
            mem[i] = 64'd0;
        end

        // 加载测试数据 (映射到读区域)
        $display("Loading Test Data...");
        for (i = 0; i < TEST_DATA_LEN; i = i + 1) begin
            integer idx;
            idx = get_mem_index(READ_BASE_ADDR + i * 64);
            mem[idx] = {32'd0, i[31:0]};
        end

        // 配置寄存器
        $display("Configuring Adder Registers...");
        ra_write_reg(16'h01, {TEST_DATA_LEN[15:0], READ_BASE_ADDR[15:0]});
        ra_write_reg(16'h02, {TEST_DATA_LEN[15:0], WRITE_BASE_ADDR[15:0]});

        // 启动计算
        $display("Starting Adder Computation...");
        ra_write_reg(16'h00, 32'h0000_0001);

        // 等待完成: 写计数达到 TEST_DATA_LEN 或超时
        $display("Waiting for completion...");
        fork
            begin
                #500000;
                $display("ERROR: Simulation Timeout! (write_cnt=%d)", write_cnt);
                $finish;
            end
            begin
                wait (write_cnt >= TEST_DATA_LEN);
                $display("All %d write beats completed.", TEST_DATA_LEN);
            end
        join_any
        disable fork;

        // 等待最后的 AXI 写事务完成 + 流水线排空
        repeat (10) @(posedge clk);

        $display("DMA Transfer Completed.");

        // 验证结果
        $display("Verifying Results...");
        error_flag = 0;
        for (i = 0; i < TEST_DATA_LEN; i = i + 1) begin
            integer w_idx;
            w_idx = get_mem_index(WRITE_BASE_ADDR + i * 64);

            actual_data = mem[w_idx][31:0];
            expected_data = i + 1;  // adder: sum = 1 + a

            if (actual_data !== expected_data) begin
                $display("ERROR at index %d: Expected %d, Got %d",
                         i, expected_data, actual_data);
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

endmodule
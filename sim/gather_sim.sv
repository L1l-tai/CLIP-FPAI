`timescale 1ns / 1ps

module gather_sim;

    localparam CLK_PERIOD = 10;
    localparam RA_CLK_PERIOD = 10;
    localparam INDICES_LEN = 20;
    localparam DATA_LEN = 32;
    localparam DATA_WIDTH_BEATS = 8;
    localparam DATA_WIDTH_BYTES = DATA_WIDTH_BEATS * 64;
    localparam TOTAL_DATA_BEATS = INDICES_LEN * DATA_WIDTH_BEATS;
    localparam IDX_BASE_ADDR = 32'h0000_1000;
    localparam SRC_BASE_ADDR = 32'h0000_2000;
    localparam DST_BASE_ADDR = 32'h0001_0000;

    reg clk, ra_clk, rst_n, ra_rst_n;
    reg [31:0] itf_ra_awaddr, itf_ra_awdata;
    reg itf_ra_awvalid, itf_ra_arvalid, itf_ra_rready;
    wire itf_ra_awready, itf_ra_arready;
    wire [31:0] itf_ra_rdata;
    wire itf_ra_rvalid;
    wire [31:0] itf_awaddr, itf_araddr;
    wire [511:0] itf_awdata;
    wire itf_awvalid, itf_arvalid;
    reg itf_awready, itf_arready;
    reg [511:0] itf_rdata;
    reg itf_rvalid;
    wire itf_rready;
    wire reset_reg;
    wire gather_comp_done;
    wire gather_rd_data_ready;
    wire [2:0] gather_fsm_state;
    reg  [31:0] itf_ra_araddr;
    assign gather_comp_done     = U_customop_top.comp_done;
    assign gather_rd_data_ready = U_customop_top.rd_data_ready_gather;
    assign gather_fsm_state     = U_customop_top.U_gather_fsm.state;

    // 监控 rready 变化
    reg         itf_rready_r;
    always @(posedge clk) itf_rready_r <= itf_rready;
    wire rready_negedge = !itf_rready && itf_rready_r;
    always @(posedge clk) begin
        if (rready_negedge)
            $display("TB: *** rready FELL (rd_ready=%b state=%d) ***",
                     gather_rd_data_ready, gather_fsm_state);
    end

    customop_top U_customop_top (
        .itf_ra_awaddr(itf_ra_awaddr), .itf_ra_awdata(itf_ra_awdata),
        .itf_ra_awvalid(itf_ra_awvalid), .itf_ra_awready(itf_ra_awready),
        .itf_ra_araddr(itf_ra_araddr), .itf_ra_arvalid(itf_ra_arvalid),
        .itf_ra_arready(itf_ra_arready), .itf_ra_rdata(itf_ra_rdata),
        .itf_ra_rvalid(itf_ra_rvalid), .itf_ra_rready(itf_ra_rready),
        .itf_awaddr(itf_awaddr), .itf_awdata(itf_awdata),
        .itf_awvalid(itf_awvalid), .itf_awready(itf_awready),
        .itf_araddr(itf_araddr), .itf_arvalid(itf_arvalid),
        .itf_arready(itf_arready), .itf_rdata(itf_rdata),
        .itf_rvalid(itf_rvalid), .itf_rready(itf_rready),
        .reset_reg(reset_reg), .clk(clk), .ra_clk(ra_clk),
        .rst_n(rst_n), .ra_rst_n(ra_rst_n)
    );

    initial begin clk = 0; forever #(CLK_PERIOD/2) clk = ~clk; end
    initial begin ra_clk = 0; forever #(RA_CLK_PERIOD/2) ra_clk = ~ra_clk; end

    reg [511:0] mem [0:4095];
    integer i;

    function automatic integer get_mem_index;
        input [31:0] addr;
        get_mem_index = addr / 64;
    endfunction

    // ============================================================
    // 真实 AXI DDR 模型 (对齐硬件验证行为)
    // ============================================================
    localparam READ_LATENCY = 4;
    reg         r_busy;
    reg [31:0]  pending_ar_addr;
    reg [7:0]   r_latency_cnt;

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

    // R: 延迟后返回, r_busy 在 R 握手后释放
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

    // AW: 脉冲式 ready
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
        rst_n = 0; ra_rst_n = 0;
        itf_ra_awaddr = 0; itf_ra_awdata = 0; itf_ra_awvalid = 0;
        itf_ra_araddr = 0; itf_ra_arvalid = 0; itf_ra_rready = 0;

        #100; rst_n = 1; ra_rst_n = 1; #100;

        for (i = 0; i < 2048; i = i + 1) mem[i] = 512'd0;

        $readmemh("gather-input-idx.mem", mem, get_mem_index(IDX_BASE_ADDR));
        $readmemh("gather-input-data.mem", mem, get_mem_index(SRC_BASE_ADDR));

        $display("Configuring Gather Registers...");
        ra_write_reg(16'h05, INDICES_LEN);
        ra_write_reg(16'h06, DATA_WIDTH_BEATS);
        ra_write_reg(16'h01, {16'd2, IDX_BASE_ADDR[15:0]});
        ra_write_reg(16'h03, SRC_BASE_ADDR);
        ra_write_reg(16'h02, DST_BASE_ADDR);
        ra_write_reg(16'h00, 32'h1);

        fork
            begin #100000; $display("TIMEOUT!"); $finish; end
            begin @(posedge gather_comp_done); $display("Done."); end
        join_any
        disable fork;

        repeat (10) @(posedge clk);
        $display("DMA Transfer Completed.");

        // 验证结果
        $display("Verifying Results...");
        for (i = 0; i < TOTAL_DATA_BEATS; i = i + 1) begin
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

        write_mem_to_file("gather-output.mem", DST_BASE_ADDR, TOTAL_DATA_BEATS);
        $display("GATHER SIMULATION COMPLETED");
        #100; $finish;
    end

    task ra_write_reg;
        input [15:0] addr_offset; input [31:0] data;
        begin
            @(posedge ra_clk);
            itf_ra_awaddr = addr_offset << 2; itf_ra_awdata = data; itf_ra_awvalid = 1;
            wait (itf_ra_awready);
            @(posedge ra_clk);
            itf_ra_awvalid = 0;
        end
    endtask

    task write_mem_to_file;
        input string filename; input [31:0] base_addr; input integer num_blocks;
        integer start_idx, end_idx;
        begin
            start_idx = get_mem_index(base_addr);
            end_idx   = get_mem_index(base_addr + (num_blocks - 1) * 64);
            $writememh(filename, mem, start_idx, end_idx);
            $display("Wrote %d blocks to %s", num_blocks, filename);
        end
    endtask

endmodule

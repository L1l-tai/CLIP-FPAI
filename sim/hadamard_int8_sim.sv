`timescale 1ns / 1ps

module hadamard_int8_sim;

    localparam CLK_PERIOD = 10;
    localparam RA_CLK_PERIOD = 10;
    localparam TOTAL_BLOCKS = 8;
    localparam INT8_PER_BLOCK = 64;
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
    wire hd_comp_done;
    reg  itf_ra_araddr;
    assign hd_comp_done = U_customop_top.comp_done_hd;

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

    task load_mem_from_file;
        input string filename;
        input [31:0] base_addr;
        begin
            $display("Loading input from %s...", filename);
            $readmemh(filename, mem, get_mem_index(base_addr));
        end
    endtask

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
                    $display("TB: R data Addr=0x%08X", pending_ar_addr);
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
                $display("TB: Wrote Addr=0x%08X", itf_awaddr);
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

        for (i = 0; i < 4096; i = i + 1) mem[i] = 512'd0;

        load_mem_from_file("fwht-input-int8.mem", SRC_BASE_ADDR);

        $display("Configuring Hadamard Registers (INT8)...");
        ra_write_reg(16'h07, 32'd2);        // hd_data_width
        ra_write_reg(16'h08, 32'd0);        // INT8 mode
        ra_write_reg(16'h32, SRC_BASE_ADDR);
        ra_write_reg(16'h33, DST_BASE_ADDR);
        ra_write_reg(16'h34, TOTAL_BLOCKS);
        ra_write_reg(16'h31, 32'h1);        // start

        fork
            begin #500000; $display("TIMEOUT!"); $finish; end
            begin @(posedge hd_comp_done); $display("Done (hd_comp_done=1)."); end
        join_any
        disable fork;

        repeat (10) @(posedge clk);
        $display("DMA Transfer Completed.");

        $display("Verifying...");
        for (i = 0; i < TOTAL_BLOCKS; i = i + 1) begin
            integer dst_addr, dst_idx;
            dst_addr = DST_BASE_ADDR + i * 64;
            dst_idx = get_mem_index(dst_addr);
            if (mem[dst_idx] != 512'd0)
                $display("PASS Block[%d]: Addr=0x%08X Data[7:0]=0x%02X", i, dst_addr, mem[dst_idx][7:0]);
            else
                $display("WARN Block[%d]: Addr=0x%08X ZERO", i, dst_addr);
        end

        write_mem_to_file("fwht-output-int8.mem", DST_BASE_ADDR, TOTAL_BLOCKS);
        $display("INT8 SIMULATION COMPLETED");
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

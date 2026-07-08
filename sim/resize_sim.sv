`timescale 1ns / 1ps

module resize_sim;

    localparam CLK_PERIOD = 10;
    localparam RA_CLK_PERIOD = 10;
    localparam SRC_WIDTH = 640;
    localparam SRC_HEIGHT = 480;
    localparam DST_WIDTH = 224;
    localparam DST_HEIGHT = 224;
    localparam CROP_ENABLE = 1;
    localparam CROP_SIZE = (SRC_WIDTH < SRC_HEIGHT) ? SRC_WIDTH : SRC_HEIGHT;
    localparam [15:0] RESIZE_RATIO_LESS = (DST_WIDTH << 12) / CROP_SIZE;
    localparam [15:0] RESIZE_RATIO_GREATER = (CROP_SIZE << 8) / DST_WIDTH;
    localparam SRC_BLOCKS_PER_ROW = (SRC_WIDTH + 15) / 16;
    localparam DST_BLOCKS_PER_ROW = (DST_WIDTH + 15) / 16;
    localparam SRC_BASE_ADDR = 32'h0000_2000;
    localparam DST_BASE_ADDR = 32'h0014_0000;  // 640x480 need ~22K blocks, leave gap
    localparam MEM_DEPTH = 32768;              // 32K entries × 64B = 2MB

    reg clk;
    reg ra_clk;
    reg rst_n;
    reg ra_rst_n;
    reg [31:0] itf_ra_awaddr;
    reg [31:0] itf_ra_awdata;
    reg itf_ra_awvalid;
    reg itf_ra_arvalid;
    reg itf_ra_rready;
    wire itf_ra_awready;
    wire itf_ra_arready;
    wire [31:0] itf_ra_rdata;
    wire itf_ra_rvalid;
    wire [31:0] itf_awaddr;
    wire [31:0] itf_araddr;
    wire [511:0] itf_awdata;
    wire itf_awvalid;
    wire itf_arvalid;
    reg itf_awready;
    reg itf_arready;
    reg [511:0] itf_rdata;
    reg itf_rvalid;
    wire itf_rready;
    wire reset_reg;
    wire rs_comp_done;
    reg  [31:0] itf_ra_araddr;
    assign rs_comp_done = U_customop_top.comp_done_rs;

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

    initial begin clk = 0; forever #(CLK_PERIOD/2) clk = ~clk; end
    initial begin ra_clk = 0; forever #(RA_CLK_PERIOD/2) ra_clk = ~ra_clk; end

    reg [511:0] mem [0:MEM_DEPTH-1];
    integer i;

    function automatic integer get_mem_index;
        input [31:0] addr;
        get_mem_index = addr / 64;
    endfunction

    // ============================================================
    // 真实 AXI DDR 模型 (对齐硬件验证行为)
    // ============================================================
    localparam READ_LATENCY = 4;
    localparam R_QUEUE_DEPTH = 4;
    reg [31:0]  r_queue_addr  [0:R_QUEUE_DEPTH-1];
    reg [7:0]   r_queue_timer [0:R_QUEUE_DEPTH-1];
    reg         r_queue_valid [0:R_QUEUE_DEPTH-1];
    integer     r_queue_wr_ptr, r_queue_rd_ptr, r_queue_cnt;

    // AR: 脉冲 ready + 队列入队
    always @(posedge clk) begin
        if (!rst_n) begin
            itf_arready <= 1'b0; r_queue_wr_ptr <= 0; r_queue_cnt <= 0;
            for (int q = 0; q < R_QUEUE_DEPTH; q++) r_queue_valid[q] <= 1'b0;
        end else begin
            if (itf_arvalid && !itf_arready && r_queue_cnt < R_QUEUE_DEPTH)
                itf_arready <= 1'b1;
            else
                itf_arready <= 1'b0;

            if (itf_arvalid && itf_arready) begin
                r_queue_addr[r_queue_wr_ptr]  <= itf_araddr;
                r_queue_timer[r_queue_wr_ptr] <= READ_LATENCY;
                r_queue_valid[r_queue_wr_ptr] <= 1'b1;
                r_queue_wr_ptr <= (r_queue_wr_ptr + 1) % R_QUEUE_DEPTH;
                r_queue_cnt   <= r_queue_cnt + 1;
                $display("TB: AR Addr=0x%08X (q=%d)", itf_araddr, r_queue_cnt);
            end
        end
    end

    // R: burst 模式, rvalid �?? beat 保持�??
    always @(posedge clk) begin
        if (!rst_n) begin
            itf_rvalid <= 1'b0; itf_rdata <= 512'd0; r_queue_rd_ptr <= 0;
        end else begin
            if (r_queue_cnt > 0 && r_queue_valid[r_queue_rd_ptr]) begin
                if (r_queue_timer[r_queue_rd_ptr] > 0) begin
                    r_queue_timer[r_queue_rd_ptr] <= r_queue_timer[r_queue_rd_ptr] - 1;
                    if (r_queue_timer[r_queue_rd_ptr] == 1)
                        $display("TB: R timer expiring next cycle, addr=0x%08X rready=%b cnt=%d",
                                 r_queue_addr[r_queue_rd_ptr], itf_rready, r_queue_cnt);
                end
                else begin
                    itf_rdata  <= mem[get_mem_index(r_queue_addr[r_queue_rd_ptr])];
                    itf_rvalid <= 1'b1;
                    $display("TB: R data presented addr=0x%08X rready=%b",
                             r_queue_addr[r_queue_rd_ptr], itf_rready);
                end
            end else begin
                if (r_queue_cnt == 0)
                    itf_rvalid <= 1'b0;
                else if (!r_queue_valid[r_queue_rd_ptr])
                    $display("TB: R queue entry INVALID rd_ptr=%d cnt=%d", r_queue_rd_ptr, r_queue_cnt);
            end

            if (itf_rvalid && itf_rready && r_queue_cnt > 0) begin
                r_queue_valid[r_queue_rd_ptr] <= 1'b0;
                r_queue_rd_ptr <= (r_queue_rd_ptr + 1) % R_QUEUE_DEPTH;
                r_queue_cnt   <= r_queue_cnt - 1;
            end
        end
    end

    // AW: 脉冲�?? ready
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

        for (i = 0; i < MEM_DEPTH; i = i + 1) mem[i] = 512'd0;

        $readmemh("resize-input-640x480.mem", mem, get_mem_index(SRC_BASE_ADDR));
        $display("Loaded source image (%dx%d)", SRC_WIDTH, SRC_HEIGHT);

        $display("Configuring Resize Registers (CROP=%d)...", CROP_ENABLE);
        ra_write_reg(16'h44, {SRC_WIDTH[15:0], SRC_HEIGHT[15:0]});
        ra_write_reg(16'h45, {DST_WIDTH[15:0], DST_HEIGHT[15:0]});
        ra_write_reg(16'h42, SRC_BASE_ADDR);
        ra_write_reg(16'h43, DST_BASE_ADDR);
        ra_write_reg(16'h09, RESIZE_RATIO_LESS);
        ra_write_reg(16'h0a, RESIZE_RATIO_GREATER);
        ra_write_reg(16'h0b, {31'd0, CROP_ENABLE});
        ra_write_reg(16'h41, 32'h1);

        fork
            begin #5000000; $display("TIMEOUT!"); $finish; end
            begin @(posedge rs_comp_done); $display("Done (comp_done_rs=1)."); end
        join_any
        disable fork;

        repeat (10) @(posedge clk);
        $display("DMA Transfer Completed.");

        write_mem_to_file("resize-output-640x480.mem", DST_BASE_ADDR, DST_HEIGHT * DST_BLOCKS_PER_ROW);
        $display("RESIZE SIMULATION COMPLETED");
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

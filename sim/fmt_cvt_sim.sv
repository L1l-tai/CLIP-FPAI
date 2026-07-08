`timescale 1ns / 1ps

module fmt_cvt_sim;

    localparam CLK_PERIOD = 10;
    localparam RA_CLK_PERIOD = 10;
    // Test image: 64×48 pixels (fits in 1 group/row)
    localparam SRC_WIDTH  = 64;
    localparam SRC_HEIGHT = 48;
    localparam TOTAL_PX   = SRC_WIDTH * SRC_HEIGHT;       // 3072
    localparam TOTAL_GROUPS = (TOTAL_PX + 63) / 64;       // 48
    // Direction: 0=RGB888→X888 (forward), 1=X888→RGB888 (reverse)
    localparam DIRECTION = 1;
    // Forward: rd=3, wr=4   Reverse: rd=4, wr=3
    localparam RD_BEATS  = DIRECTION ? 4 : 3;
    localparam WR_BEATS  = DIRECTION ? 3 : 4;
    localparam TOTAL_RD_BEATS = TOTAL_GROUPS * RD_BEATS;
    localparam TOTAL_WR_BEATS = TOTAL_GROUPS * WR_BEATS;
    localparam SRC_BASE_ADDR = 32'h0000_2000;
    localparam DST_BASE_ADDR = 32'h0001_0000;   // after src, enough space
    localparam MEM_DEPTH = 2048;
    localparam CTRL_START = DIRECTION ? 32'h3 : 32'h1;  // bit[0]=start, bit[1]=dir

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
    wire fc_comp_done;
    reg  [31:0] itf_ra_araddr;

    assign fc_comp_done = U_customop_top.comp_done_fc;

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

    // ============================================================
    // DDR memory model
    // ============================================================
    reg [511:0] mem [0:MEM_DEPTH-1];
    integer i;

    function automatic integer get_mem_index;
        input [31:0] addr;
        get_mem_index = addr / 64;
    endfunction

    // ============================================================
    // AXI Read model (align gather_sim: r_busy serialization)
    // ============================================================
    localparam READ_LATENCY = 4;
    reg         r_busy;
    reg [31:0]  pending_ar_addr;
    reg [7:0]   r_latency_cnt;

    // AR: pulse ready + r_busy serialization (one read at a time)
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
            end
        end
    end

    // R: latency then single beat return, r_busy released on handshake
    always @(posedge clk) begin
        if (!rst_n) begin
            itf_rvalid     <= 1'b0;
            itf_rdata      <= 512'd0;
            r_latency_cnt  <= 0;
        end else begin
            if (itf_rvalid && itf_rready) begin
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

    // ============================================================
    // AXI Write model (pulse ready, align gather_sim)
    // ============================================================
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
    // Test sequence
    // ============================================================
    initial begin
        rst_n = 0; ra_rst_n = 0;
        itf_ra_awaddr = 0; itf_ra_awdata = 0; itf_ra_awvalid = 0;
        itf_ra_araddr = 0; itf_ra_arvalid = 0; itf_ra_rready = 0;

        #100; rst_n = 1; ra_rst_n = 1; #100;

        // Clear memory
        for (i = 0; i < MEM_DEPTH; i = i + 1) mem[i] = 512'd0;

        // Load source data (format depends on direction)
        if (DIRECTION == 0) begin
            $readmemh("fmt_cvt-input-64x48.mem", mem, get_mem_index(SRC_BASE_ADDR));
            $display("Loaded RGB888 source data (%dx%d, %d beats) [FORWARD mode]", SRC_WIDTH, SRC_HEIGHT, TOTAL_RD_BEATS);
        end else begin
            $readmemh("fmt_cvt-golden-64x48.mem", mem, get_mem_index(SRC_BASE_ADDR));
            $display("Loaded X888 source data (%dx%d, %d beats) [REVERSE mode]", SRC_WIDTH, SRC_HEIGHT, TOTAL_RD_BEATS);
        end

        // Configure fmt_cvt registers
        $display("Configuring fmt_cvt Registers (direction=%d)...", DIRECTION);
        ra_write_reg(16'h52, SRC_BASE_ADDR);      // FC_SRC_ADDR
        ra_write_reg(16'h53, DST_BASE_ADDR);      // FC_DST_ADDR
        ra_write_reg(16'h54, TOTAL_PX);            // FC_PIXEL_CNT
        ra_write_reg(16'h51, CTRL_START);          // FC_COMP_START (bit[0]=start, bit[1]=dir)

        // Wait for completion or timeout
        fork
            begin #5000000; $display("TIMEOUT!"); $finish; end
            begin @(posedge fc_comp_done); $display("Done (comp_done_fc=1)."); end
        join_any
        disable fork;

        repeat (10) @(posedge clk);
        $display("DMA Transfer Completed.");

        // Write output to file
        write_mem_to_file("fmt_cvt-output-64x48.mem", DST_BASE_ADDR, TOTAL_WR_BEATS);

        // Quick verification: check first and last output blocks
        $display("Verifying output...");
        $display("  DST[0]      = 0x%0128X", mem[get_mem_index(DST_BASE_ADDR)]);
        $display("  DST[1]      = 0x%0128X", mem[get_mem_index(DST_BASE_ADDR + 64)]);
        $display("  DST[%d]     = 0x%0128X", TOTAL_WR_BEATS-1,
                 mem[get_mem_index(DST_BASE_ADDR + (TOTAL_WR_BEATS-1)*64)]);

        $display("FMT_CVT SIMULATION COMPLETED");
        #100; $finish;
    end

    // ============================================================
    // Helper tasks
    // ============================================================
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

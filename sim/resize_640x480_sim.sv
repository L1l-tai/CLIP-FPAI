`timescale 1ns / 1ps

module resize_640x480_sim;

    localparam CLK_PERIOD = 10;
    localparam RA_CLK_PERIOD = 10;
    localparam SRC_WIDTH = 640;
    localparam SRC_HEIGHT = 480;
    localparam DST_WIDTH = 224;
    localparam DST_HEIGHT = 224;
    localparam CROP_ENABLE = 1;
    localparam CROP_SIZE = (SRC_WIDTH < SRC_HEIGHT) ? SRC_WIDTH : SRC_HEIGHT;  // 480
    localparam [15:0] RESIZE_RATIO_LESS = (DST_WIDTH << 12) / CROP_SIZE;
    localparam [15:0] RESIZE_RATIO_GREATER = (CROP_SIZE << 8) / DST_WIDTH;
    localparam SRC_BLOCKS_PER_ROW = (SRC_WIDTH + 15) / 16;   // 40
    localparam DST_BLOCKS_PER_ROW = (DST_WIDTH + 15) / 16;   // 14
    localparam DST_TOTAL_BLOCKS = DST_BLOCKS_PER_ROW * DST_HEIGHT;  // 3136
    localparam SRC_TOTAL_BLOCKS = SRC_BLOCKS_PER_ROW * SRC_HEIGHT;  // 19200
    localparam SRC_BASE_ADDR = 32'h0000_2000;
    localparam DST_BASE_ADDR = 32'h0001_0000;

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

    reg [511:0] mem [0:30000];
    integer i, fd, status;

    function automatic integer get_mem_index;
        input [31:0] addr;
        get_mem_index = addr / 64;
    endfunction

    // ============================================================
    // AXI 内存模型 (r_busy 串行化)
    // ============================================================
    localparam READ_LATENCY = 4;
    reg         r_busy;
    reg [31:0]  pending_ar_addr;
    reg [7:0]   r_latency_cnt;

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

        // 清零内存
        for (i = 0; i < 30000; i = i + 1) mem[i] = 512'd0;

        // 从二进制文件加载 RGBA 图像 (640×480, 32bpp)
        $display("Loading 640x480 RGBA image from input.raw...");
        fd = $fopen("input.raw", "rb");
        if (fd == 0) begin
            $display("ERROR: Cannot open input.raw");
            $finish;
        end

        i = get_mem_index(SRC_BASE_ADDR);
        while (!$feof(fd)) begin
            reg [7:0] byte_buf [0:63];
            integer j;
            // 读 64 字节 (= 1 个 512-bit 块 = 16 个 RGBA 像素)
            for (j = 0; j < 64; j = j + 1) begin
                status = $fgetc(fd);
                if (status == -1) begin
                    // EOF, 填 0
                    byte_buf[j] = 8'd0;
                end else begin
                    byte_buf[j] = status[7:0];
                end
            end
            // 打包为 512-bit (little-endian: byte_buf[0] = LSB)
            mem[i] = {byte_buf[63], byte_buf[62], byte_buf[61], byte_buf[60],
                       byte_buf[59], byte_buf[58], byte_buf[57], byte_buf[56],
                       byte_buf[55], byte_buf[54], byte_buf[53], byte_buf[52],
                       byte_buf[51], byte_buf[50], byte_buf[49], byte_buf[48],
                       byte_buf[47], byte_buf[46], byte_buf[45], byte_buf[44],
                       byte_buf[43], byte_buf[42], byte_buf[41], byte_buf[40],
                       byte_buf[39], byte_buf[38], byte_buf[37], byte_buf[36],
                       byte_buf[35], byte_buf[34], byte_buf[33], byte_buf[32],
                       byte_buf[31], byte_buf[30], byte_buf[29], byte_buf[28],
                       byte_buf[27], byte_buf[26], byte_buf[25], byte_buf[24],
                       byte_buf[23], byte_buf[22], byte_buf[21], byte_buf[20],
                       byte_buf[19], byte_buf[18], byte_buf[17], byte_buf[16],
                       byte_buf[15], byte_buf[14], byte_buf[13], byte_buf[12],
                       byte_buf[11], byte_buf[10], byte_buf[9],  byte_buf[8],
                       byte_buf[7],  byte_buf[6],  byte_buf[5],  byte_buf[4],
                       byte_buf[3],  byte_buf[2],  byte_buf[1],  byte_buf[0]};
            i = i + 1;
        end
        $fclose(fd);
        $display("Loaded %d blocks into memory (start offset 0x%08X)", i - get_mem_index(SRC_BASE_ADDR), SRC_BASE_ADDR);

        // 配置寄存器
        $display("Configuring Resize: %dx%d -> %dx%d (CROP=%d)...",
                 SRC_WIDTH, SRC_HEIGHT, DST_WIDTH, DST_HEIGHT, CROP_ENABLE);
        ra_write_reg(16'h44, {SRC_WIDTH[15:0], SRC_HEIGHT[15:0]});
        ra_write_reg(16'h45, {DST_WIDTH[15:0], DST_HEIGHT[15:0]});
        ra_write_reg(16'h42, SRC_BASE_ADDR);
        ra_write_reg(16'h43, DST_BASE_ADDR);
        ra_write_reg(16'h09, RESIZE_RATIO_LESS);
        ra_write_reg(16'h0a, RESIZE_RATIO_GREATER);
        ra_write_reg(16'h0b, {31'd0, CROP_ENABLE});
        ra_write_reg(16'h41, 32'h1);

        // 等待完成 (640x480->224x224 需要更长时间)
        fork
            begin #50000000; $display("TIMEOUT!"); $finish; end
            begin @(posedge rs_comp_done); $display("Done (comp_done_rs=1)."); end
        join_any
        disable fork;

        repeat (10) @(posedge clk);
        $display("DMA Transfer Completed.");

        // 输出 224×224 结果
        write_mem_to_file("resize-output-224x224.mem", DST_BASE_ADDR, DST_TOTAL_BLOCKS);
        $display("RESIZE 640x480->224x224 SIMULATION COMPLETED");
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

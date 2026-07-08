//================================================================================
// File Name     : fmt_cvt.v
// Project       : CLIP ViT-B/32
// Create Date   : 2026.07.08
// Description   : RGB888→RGBX8888 format converter – data path + addr gen + AVR
//                 Aligned with gather.v pattern
//================================================================================

module fmt_cvt #(
    parameter RD_BEATS = 3,    // forward: 3 beats read  (RGB888)
    parameter WR_BEATS = 4     // forward: 4 beats write (X888)
) (
    // ---- FSM control ----
    input               gen_status,
    input               trans_data,
    input               repack_en,
    input               comp_done,

    // ---- DMA data ----
    input  [511:0]      din,
    input               din_valid,
    output              din_ready,

    // ---- Address generation → FSM ----
    output              addr_gen_valid,

    // ---- Address output → arbiter ----
    output [31:0]       arbase,
    output [15:0]       arsize,
    output [31:0]       awbase,
    output [15:0]       awsize,

    // ---- Configuration ----
    input               direction,    // 0=RGB888→X888, 1=X888→RGB888
    input  [31:0]       src_addr,
    input  [31:0]       dst_addr,
    input  [31:0]       total_groups,

    // ---- AVR output → arbiter ----
    output [511:0]      dout,
    output              dout_valid,
    input               dout_ready,

    // ---- Status ----
    output              rd_data_ready,

    input               clk,
    input               rst_n
);

    // ============================================================
    // Address generation (align gather offset pattern)
    // ============================================================
    reg [31:0] group_cnt;
    reg [31:0] rd_offset;
    reg [31:0] wr_offset;
    reg        gen_status_r;

    // Dynamic beat counts and byte offsets per group
    wire [31:0] rd_bytes_per_group = direction ? (WR_BEATS << 6) : (RD_BEATS << 6);
    wire [31:0] wr_bytes_per_group = direction ? (RD_BEATS << 6) : (WR_BEATS << 6);
    wire [2:0]  rd_beats_needed    = direction ? WR_BEATS[2:0] : RD_BEATS[2:0];
    wire [2:0]  wr_beats_needed    = direction ? RD_BEATS[2:0] : WR_BEATS[2:0];

    (* use_dsp = "yes" *) wire [31:0] rd_offset_c;
    (* use_dsp = "yes" *) wire [31:0] wr_offset_c;
    assign rd_offset_c = group_cnt * rd_bytes_per_group;
    assign wr_offset_c = group_cnt * wr_bytes_per_group;

    // group_cnt: increments on gen_status rising edge only (avoid double-count)
    wire gen_status_pos;
    assign gen_status_pos = gen_status && !gen_status_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            group_cnt <= #0.1 32'd0;
        end else if (comp_done) begin
            group_cnt <= #0.1 32'd0;
        end else if (gen_status_pos) begin
            group_cnt <= #0.1 group_cnt + 32'd1;
        end
    end

    // Offset latch on gen_status rising edge (avoid double-latch across 2-cycle state)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_offset <= #0.1 32'd0;
            wr_offset <= #0.1 32'd0;
        end else if (gen_status_pos) begin
            rd_offset <= #0.1 rd_offset_c;
            wr_offset <= #0.1 wr_offset_c;
        end
    end

    // gen_status_r → addr_gen_valid pulse
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            gen_status_r <= #0.1 1'b0;
        else
            gen_status_r <= #0.1 gen_status;
    end
    assign addr_gen_valid = gen_status_r;

    // Address outputs (dynamic beat counts for direction)
    assign arbase = src_addr + rd_offset;
    assign arsize = {13'd0, rd_beats_needed};
    assign awbase = dst_addr + wr_offset;
    assign awsize = {13'd0, wr_beats_needed};

    // ============================================================
    // Read beat counter + rd_data_ready (align gather rd_cnt)
    // ============================================================
    reg [2:0] rd_beat_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_beat_cnt <= #0.1 2'd0;
        end else if (comp_done || gen_status) begin
            rd_beat_cnt <= #0.1 2'd0;
        end else if (!trans_data && din_valid && din_ready) begin
            rd_beat_cnt <= #0.1 rd_beat_cnt + 2'd1;
        end
    end
    assign rd_data_ready = (rd_beat_cnt >= rd_beats_needed);

    // ============================================================
    // Shift register + bidirectional repack core + output register
    // ============================================================
    reg [2047:0] shift_reg;   // max(3,4)*512 = 2048b
    reg [2047:0] dout_reg;    // 2048b
    wire [2047:0] core_dout;

    // Read: accumulate beats into shift_reg
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_reg <= #0.1 2048'd0;
        end else if (!trans_data && din_valid && din_ready) begin
            shift_reg[rd_beat_cnt*512 +: 512] <= #0.1 din;
        end
    end

    // Repack core (combinational, direction-aware)
    wire [23:0] px24 [63:0];
    wire [31:0] px32 [63:0];
    genvar i;
    generate
        for (i = 0; i < 64; i = i + 1) begin : gen_px
            // Forward: shift_reg[i*24 +: 24] → RGB888 pixel → {0,R,G,B}
            // Reverse: shift_reg[i*32 +: 24] → X888 bits[23:0] → RGB888 pixel → {0,R,G,B}
            assign px24[i] = direction ? shift_reg[i*32 +: 24]     // reverse: drop X888 padding
                                       : shift_reg[i*24 +: 24];    // forward: RGB888 passthrough
            assign px32[i] = {8'd0, px24[i]};                      // both: zero-extend 24b→32b
        end
    endgenerate
    // Build output: forward=64×32b (2048b), reverse=64×24b packed (1536b→2048b)
    wire [2047:0] dout_forward;
    wire [1535:0] dout_reverse;
    assign dout_forward = {px32[63], px32[62], px32[61], px32[60],
                           px32[59], px32[58], px32[57], px32[56],
                           px32[55], px32[54], px32[53], px32[52],
                           px32[51], px32[50], px32[49], px32[48],
                           px32[47], px32[46], px32[45], px32[44],
                           px32[43], px32[42], px32[41], px32[40],
                           px32[39], px32[38], px32[37], px32[36],
                           px32[35], px32[34], px32[33], px32[32],
                           px32[31], px32[30], px32[29], px32[28],
                           px32[27], px32[26], px32[25], px32[24],
                           px32[23], px32[22], px32[21], px32[20],
                           px32[19], px32[18], px32[17], px32[16],
                           px32[15], px32[14], px32[13], px32[12],
                           px32[11], px32[10], px32[ 9], px32[ 8],
                           px32[ 7], px32[ 6], px32[ 5], px32[ 4],
                           px32[ 3], px32[ 2], px32[ 1], px32[ 0]};
    // Reverse: pack 64 × 24b directly into 1536b (no padding between pixels)
    genvar j;
    generate
        for (j = 0; j < 64; j = j + 1) begin : gen_rev
            assign dout_reverse[j*24 +: 24] = px24[j];
        end
    endgenerate
    // core_dout: forward uses 32b/px, reverse uses packed 24b/px (zero-extended to 2048b)
    assign core_dout = direction ? {512'd0, dout_reverse} : dout_forward;

    // Latch dout_reg on repack_en
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout_reg <= #0.1 2048'd0;
        end else if (repack_en) begin
            dout_reg <= #0.1 core_dout;
        end
    end

    // ============================================================
    // Write output: align hadamard multi-beat AVR pattern
    //   beat_sent:    counts AVR captures, gates at WR_BEATS (max 4 per group)
    //   wr_cnt:       beat index for data MUX, advances on arbiter consumption
    //   pipeline_busy: prevents >1 beat in AVR pipeline
    // ============================================================
    reg         pipeline_busy;
    reg [2:0]   wr_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipeline_busy <= #0.1 1'b0;
        end else if (comp_done || !trans_data) begin
            pipeline_busy <= #0.1 1'b0;
        end else if (dout_valid && dout_ready) begin
            pipeline_busy <= #0.1 1'b0;
        end else if (dout_valid_rs && dout_ready_rs) begin
            pipeline_busy <= #0.1 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_cnt <= #0.1 3'd0;
        end else if (!trans_data) begin
            wr_cnt <= #0.1 3'd0;
        end else if (dout_valid && dout_ready) begin
            wr_cnt <= #0.1 wr_cnt + 3'd1;
        end
    end

    // ============================================================
    // AVR passthrough (align hadamard dout_rs → avr_rs → dout pattern)
    // ============================================================
    wire [511:0] dout_rs;
    wire        dout_valid_rs;
    wire        dout_ready_rs;

    // result_valid: gate by wr_cnt, max wr_beats_needed per trans_data phase
    wire result_valid;
    assign result_valid = trans_data && (wr_cnt < wr_beats_needed);

    // dout_rs selects current beat from dout_reg
    assign dout_rs       = dout_reg[wr_cnt*512 +: 512];
    assign dout_valid_rs = result_valid && !pipeline_busy && trans_data;
    assign din_ready     = !trans_data;  // accept DMA reads in RD_GROUP

    // AVR register slice (timing isolation + backpressure)
    avr_rs #(.DW(512)) U_avr_rs (
        .m_data   (dout_rs),
        .m_valid  (dout_valid_rs),
        .m_ready  (dout_ready_rs),
        .s_data   (dout),
        .s_valid  (dout_valid),
        .s_ready  (dout_ready),
        .clk      (clk),
        .rst_n    (rst_n)
    );

endmodule

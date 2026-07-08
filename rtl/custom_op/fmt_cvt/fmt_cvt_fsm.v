//================================================================================
// File Name     : fmt_cvt_fsm.v
// Project       : CLIP ViT-B/32
// Create Date   : 2026.07.08
// Description   : Format converter FSM – aligned with gather_fsm pattern
//                 IDLE → GEN_ADDR → RD_GROUP → REPACK → WR_GROUP → (loop or DONE)
//================================================================================

module fmt_cvt_fsm #(
    parameter RD_BEATS = 3,
    parameter WR_BEATS = 4
) (
    input               start,
    input               rd_done,
    input               wr_done,
    input               addr_gen_valid,
    input               rd_data_ready,
    input  [31:0]       total_groups,

    output reg          rd_start,
    output reg          wr_start,
    output reg          gen_status,
    output reg          trans_data,
    output reg          repack_en,
    output reg          comp_done,
    output reg          rd_last_line,
    output [2:0]        state_out,

    input               clk,
    input               rst_n
);

    localparam IDLE      = 3'd0;
    localparam GEN_ADDR  = 3'd1;
    localparam RD_GROUP  = 3'd2;
    localparam REPACK    = 3'd3;
    localparam WR_GROUP  = 3'd4;
    localparam DONE_S    = 3'd5;

    reg [2:0]  state, next_state;
    reg [2:0]  prev_state;
    reg [31:0] group_cnt;
    reg        rd_done_reg;
    reg        wr_done_reg;
    reg        rd_start_pulse;
    reg        wr_start_pulse;

    assign state_out = state;

    // Edge detection for 1-cycle-pulse states
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) prev_state <= #0.1 3'd0;
        else        prev_state <= #0.1 state;
    end
    wire enter_gen_addr;
    assign enter_gen_addr = (state == GEN_ADDR) && (prev_state != GEN_ADDR);

    // ============ rd_done / wr_done edge detect (align gather) ============
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_done_reg <= #0.1 1'b0;
            wr_done_reg <= #0.1 1'b0;
        end else begin
            if (state == GEN_ADDR) begin
                rd_done_reg <= #0.1 1'b0;
                wr_done_reg <= #0.1 1'b0;
            end else begin
                if (rd_done) rd_done_reg <= #0.1 1'b1;
                if (wr_done) wr_done_reg <= #0.1 1'b1;
            end
        end
    end

    // ============ group counter (edge-triggered: increment once per GEN_ADDR entry) ============
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            group_cnt <= #0.1 32'd0;
        end else if (state == IDLE) begin
            group_cnt <= #0.1 32'd0;
        end else if (enter_gen_addr) begin
            group_cnt <= #0.1 group_cnt + 32'd1;
        end
    end

    // ============ state register ============
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= #0.1 IDLE;
        else
            state <= #0.1 next_state;
    end

    // ============ next state logic ============
    always @(*) begin
        next_state = state;
        case (state)
            IDLE: begin
                if (start)
                    next_state = GEN_ADDR;
            end
            GEN_ADDR: begin
                if (addr_gen_valid)
                    next_state = RD_GROUP;
            end
            RD_GROUP: begin
                if (rd_done_reg && rd_data_ready)
                    next_state = REPACK;
            end
            REPACK: begin
                next_state = WR_GROUP;
            end
            WR_GROUP: begin
                if (wr_done_reg) begin
                    if (group_cnt >= total_groups)
                        next_state = DONE_S;
                    else
                        next_state = GEN_ADDR;
                end
            end
            DONE_S: begin
                if (!start)
                    next_state = IDLE;
            end
            default: next_state = IDLE;
        endcase
    end

    // ============ rd_start / wr_start pulse generation (align gather) ============
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_start       <= #0.1 1'b0;
            rd_start_pulse <= #0.1 1'b0;
            wr_start       <= #0.1 1'b0;
            wr_start_pulse <= #0.1 1'b0;
        end else begin
            // rd_start: 1-cycle pulse on entering RD_GROUP
            if (state == GEN_ADDR && next_state == RD_GROUP)
                rd_start <= #0.1 1'b1;
            else
                rd_start <= #0.1 1'b0;

            // wr_start: 1-cycle pulse on entering WR_GROUP
            if (state == REPACK && next_state == WR_GROUP)
                wr_start <= #0.1 1'b1;
            else
                wr_start <= #0.1 1'b0;
        end
    end

    // ============ repack_en: 1-cycle pulse on REPACK entry ============
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            repack_en <= #0.1 1'b0;
        else
            repack_en <= #0.1 (state == RD_GROUP && next_state == REPACK);
    end

    // ============ rd_last_line (last group before final row) ============
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rd_last_line <= #0.1 1'b0;
        else if (state == GEN_ADDR)
            rd_last_line <= #0.1 (group_cnt + 1 >= total_groups);
        else if (state == IDLE)
            rd_last_line <= #0.1 1'b0;
    end

    // ============ output signals ============
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gen_status  <= #0.1 1'b0;
            trans_data  <= #0.1 1'b0;
            comp_done   <= #0.1 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    gen_status <= #0.1 1'b0;
                    trans_data <= #0.1 1'b0;
                    comp_done  <= #0.1 1'b0;
                end
                GEN_ADDR: begin
                    gen_status <= #0.1 1'b1;
                    trans_data <= #0.1 1'b0;
                    comp_done  <= #0.1 1'b0;
                end
                RD_GROUP: begin
                    gen_status <= #0.1 1'b0;
                    trans_data <= #0.1 1'b0;
                    comp_done  <= #0.1 1'b0;
                end
                REPACK: begin
                    gen_status <= #0.1 1'b0;
                    trans_data <= #0.1 1'b0;
                    comp_done  <= #0.1 1'b0;
                end
                WR_GROUP: begin
                    gen_status <= #0.1 1'b0;
                    trans_data <= #0.1 1'b1;
                    comp_done  <= #0.1 1'b0;
                end
                DONE_S: begin
                    gen_status <= #0.1 1'b0;
                    trans_data <= #0.1 1'b0;
                    comp_done  <= #0.1 1'b1;
                end
                default: ;
            endcase
        end
    end

endmodule

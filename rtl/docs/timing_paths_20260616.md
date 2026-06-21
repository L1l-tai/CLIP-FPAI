# 自定义算子关键时序路径标注

**日期：** 2026-06-16  
**状态：** 标注完成，待后续优化

---

## 一、Hadamard

| # | 路径 | 位置 | 深度 | 风险 |
|---|------|------|------|------|
| 1 | PUB barrel shifter: exp_diff→abs→cmp→右移 | fwht_pub.v:133-150 | ~7-8 LUT | 中，INT16 路径绕过 |
| 2 | 6:1 mux ×64：stage_cnt 扇出到 16 PUB | hadamard.v:348-367 | ~3 LUT + 高扇出 | 中-高，布线拥堵 |
| 3 | FP16 LOD + barrel 左移（归一化） | fwht_pub.v:184-220 | ~6 LUT | 中，仅 FP16 |

**当前状态**：三条路径均已寄存器化。Hadamard 整体为 6 级流水线，每条路径跨单周期。瓶颈在 fanout（stage_cnt → 64 mux）而非逻辑深度。

## 二、Gather ⚠️ 最关键

| # | 路径 | 位置 | 深度 | 风险 |
|---|------|------|------|------|
| **1** | **DSP 32×32 乘法 → arbase_offset** | gather.v:233→108 | 2-3 DSP 级联 | **最高** |
| **2** | **FIFO 组合读 → 2:1 mux → 16:1 part-select** | gather.v:249→235→92 | ~10 LUT | **高** |
| 3 | 地址生成 32-bit 加法 | gather.v:191 | 32-bit 进位链 | 低 |

**路径 1 详述**（最高优先级）：
```verilog
assign arbase_offset_c = indice_now_reg * (data_width_reg << 6);  // 32×32 DSP乘, 纯组合
// → arbase_offset <= arbase_offset_c  (单寄存器, 无流水线)
```
32×32 乘法需要 2-3 个 DSP48E2 级联，DSP 内部的 P 寄存器未被使用。优化：在 DSP 输出与 `arbase_offset` 之间插入一级流水寄存器，或启用 DSP 内部流水线寄存器。

**路径 2 详述**：
```verilog
rdata = mem[raddr];                                    // 组合 RAM 读 (~5 LUT)
current_indices = (empty|rd_idx) ? 0 : fifo_dout;      // 512b 2:1 mux (1 LUT)
indice_now = current_indices[cnt*32 +: 32];             // 16:1 part-select (4 LUT)
indice_now_reg <= indice_now;                           // 寄存器
```
三段组合逻辑叠加约 10 LUT 级。优化：在 `current_indices` 或 `indice_now` 前插入寄存器。

## 三、Resize

| # | 路径 | 位置 | 深度 | 风险 |
|---|------|------|------|------|
| **1** | **4 输入 32-bit 加法树** | resize.v:546-554 | 32-bit 进位链 + 2 LUT | **高** |
| 2 | 像素 mux + 权重计算 | resize.v:370-380, 315-335 | ~4-5 LUT | 中 |
| 3 | 地址生成 3 输入加法 | resize_addr_gen.v:118-119 | 32-bit 进位链 | 中 |
| 4 | DSP 32×32 乘法（地址生成） | resize_addr_gen.v:110→196 | 2-3 DSP 级联 | 中（已有 2 级流水线） |

**路径 1 详述**（高优先级）：
```verilog
sum_RG_full[a] = RG_11[a] + RG_12[a] + RG_21[a] + RG_22[a];  // 4输入32b加法
// → result_val[s] <= {8'b0, r_c, g_c, b_c};  (单寄存器)
```
4 输入加法会被综合为进位保留压缩器 + 进位传播加法器。32-bit 进位链是瓶颈。优化：拆成两次 2 输入加法，中间插入寄存器。

**路径 3 详述**：
```verilog
arbase_offset_c = crop_off_x_b + (addr_rd_cnt << RS_SHIFT);         // 2输入加法
arbase_rs_gen_c = rbase_rs_reg + y_bias_x_rwidth_r + arbase_offset_c; // 3输入加法
// → arbase_rs_gen <= arbase_rs_gen_c  (单寄存器)
```
两段加法组合级联。`awbase_comb` 还作为纯组合输出供外部使用，若外部不立即寄存器化，路径会进一步延长。

## 四、整体优化优先级

| 优先级 | 模块 | 路径 | 预期收益 |
|--------|------|------|---------|
| **P0** | Gather | DSP 32×32 乘法 | 显著，当前最可能违反时序 |
| **P1** | Gather | FIFO 组合读路径 | 显著，10 级 LUT |
| **P2** | Resize | 4 输入 32-bit 加法树 | 中等，32-bit 进位链 |
| **P3** | Resize | 地址生成 3 输入加法 | 中等 |
| P4 | Hadamard | stage_cnt 高扇出 | 低，可通过复制/约束缓解 |

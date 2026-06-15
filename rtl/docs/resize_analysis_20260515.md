# Resize/Crop 算子 RTL 分析报告（修订版）

**原版日期：** 2026-05-15
**修订日期：** 2026-06-16
**分析范围：** `rtl/custom_op/resize_crop/`

---

## 1. 模块架构

```
resize_fsm → resize_axis → resize_addr_gen → resize → resize_fifo → DMA
    ↑            ↑              ↑              ↑
    └── fifo_flush_ready, fifo_empty, src_done ──┘
```

| 模块 | 功能 |
|------|------|
| `resize_fsm` | 状态机：控制读/写/计算时序流 |
| `resize_axis` | 坐标映射：x_delta, y_delta, y_bias, data_valid |
| `resize_addr_gen` | 地址生成：源读地址 + 目标写地址 |
| `resize` | 双线性插值核心 + 输出 FIFO 控制 |
| `resize_fifo` | 像素累积 FIFO：批量写入，16 像素读出 |

---

## 2. 整体流水线时序

```
FSM state:  AXIS_PRE  AXIS_CAL   GEN_ADDR   RD_ONLY   RD_SECONE   RESIZE (8 cyc)  ...
                │         │          │          │          │            │
axis:      pre-cal   Stage1   negedge   negedge1  negedge2     negedge3
                     latch    x/y_delta  data_valid next_bias   pre_bias
                     y_bias(提前)                              
                │         │          │
addr_gen:                  └── Stage1 ──→ Stage2 ──→ Stage3
                           rbase+y_bias   DSP(×rw)   arbase
                │         │          │          │          │            │
resize:                                                          resize_cycle 0~7
                                                               pass0(half0)→pass1(half1)
                                                               串行 2-pass, 8 cycles
```

### 2.1 关键时序约束

| 路径 | 起点 | 终点 | 级数 |
|------|------|------|------|
| axis: ratioed_x | axis_cal_status (Stage1) | negedge1 (data_valid) | reg→DSP→reg→compare→reg |
| axis: next_bias | negedge1 (data_valid) | negedge2 (next_bias_mul_r) | reg→DSP→reg |
| axis: pre_bias | negedge2 (next_bias_mul_r) | negedge3 (pre_bias) | reg→adder→reg |
| addr: y_bias_sum | gen_status (Stage1) | pipe_valid_2 (arbase) | reg→adder→reg→DSP→reg→adder→reg (3 级) |
| resize: pass0 | resize_cycle=0 | resize_cycle=2 (result[0:7]) | reg→DSP→reg→adder→reg (3 级) |
| resize: pass1 | resize_cycle=5 | resize_cycle=7 (result[8:15]) | reg→DSP→reg→adder→reg (3 级) |

---

## 3. 坐标映射 (resize_axis)

### 3.1 流水线结构（5 级输出）

```
axis_cal_status → negedge → negedge1 → negedge2 → negedge3

Stage1 (axis_cal_status):  锁存 ratioed_x_full_add_r, x_delta_mul_r,
                           ratioed_y_full_r, y_delta_next_r, y_bias_next_r,
                           current_row_y_next_r, pixel_cnt_next_r,
                           ratioed_x_full_r (DSP 乘积, 提前计算)
negedge:                   输出 x_delta, y_delta, current_row_y, pixel_cnt
negedge1:                  输出 data_valid (从已寄存的 ratioed_x_full_r 取值)
negedge2:                  锁存 next_bias_mul_r (= RG × data_valid)
negedge3:                  锁存 pre_bias (= 16 + pre_bias - next_bias_mul_r)

y_bias:                    在 axis_cal_status 第 2 周期提前更新
                           (消除 resize_addr_gen 中 gen_status 的时序竞争)
```

### 3.2 x 方向

```
x_delta_mul[i] = ratio_greater × i          (i = 1..16)
x_delta[i]     = x_delta_mul[i] - pre_bias - 1
```

- `ratio_greater = src_w / dst_w`，Q1.7.8 格式（例：48/32 = 1.5 = 0x0180）
- `pre_bias`：跨块累积偏移，Q1.7.8 有符号
- `-1`：抵消 `x_delta_mul` 从 `i=1` 起算的 +1 偏移

**Golden Model 对照：**
```python
src_x = (dst_x + 1) * scale_x - 1
```

### 3.3 y 方向

```
ratioed_y_full = height_ratio_greater × current_row_y - 1.0   (Q1.23.8)
y_bias  = ratioed_y_full[23:8]    // 整数部分
y_delta = ratioed_y_full[7:0]     // 小数部分
```

- `current_row_y`：从 1 起始，`pixel_cnt_next == crop_size` 时 +1
- `-1.0`：抵消 `current_row_y` 从 1 起算的偏移

**Golden Model 对照：**
```python
src_y = (dst_y + 1) * scale_y - 1
```

### 3.4 pre_bias 链

```
pre_bias_next = 16.0 + pre_bias - next_bias_mul_r      (行 wrap 时归 0)
next_bias_mul = ratio_greater × data_valid              (本块像素消耗)
```

| 块 | pre_bias (入) | data_valid | next_bias_mul | pre_bias (出) |
|----|-------------|-----------|---------------|---------------|
| 0  | 0           | 10        | 15.0          | 1.0           |
| 1  | 1.0         | 11        | 16.5          | 0.5           |
| 2  | 0.5         | 11        | 16.5          | 0 (wrap)      |

每行 10+11+11 = 32 像素。

### 3.5 data_valid 计算

```
ratioed_x_full_add = 16.0 + pre_bias                      (Q1.7.8, 有符号加法)
ratioed_x_full     = ratio_less × ratioed_x_full_add      (DSP, 32-bit)
ratioed_x_full_r   ← 锁存于 Stage1                          (切断 DSP→比较器)
ratioed_x          = ratioed_x_full_r[27:12]              (Q1.7.8)
data_valid_int     = clamp(ratioed_x[15:8], 0, 16)        (整数截断, 钳位)
data_valid         ← 锁存于 negedge1
```

`ratio_less = dst_w / src_w`，Q1.3.12 格式（例：32/48 = 2730 = 0x0AAA）。

---

## 4. 地址生成 (resize_addr_gen)

### 4.1 流水线结构（3 级）

```
gen_status → pipe_valid → pipe_valid_2

Stage1 (gen_status):   锁存 rbase_rs_reg, wbase_rs_reg
                       锁存 y_bias_sum_r (= y_bias + crop_off_y)
                       锁存 y_bias_sum_p1_r (= y_bias + crop_off_y + 1)
Stage2 (pipe_valid):   锁存 y_bias_x_rwidth_r (= sum_r × rwidth_bytes, DSP)
Stage3 (pipe_valid_2): 锁存 arbase_rs_gen → rs_addr_gen_valid

y_bias 在 AXIS_CAL 内由 axis_cal_status 提前更新, Stage1 时已稳定
位拼接 {signal, 2'b0} 替代 << 和 * 常数, 避免综合工具误推 DSP
```

### 4.2 读地址

```
arbase = rbase + (y_bias + crop_off_y) × rwidth_rs × 4
               + crop_off_x × 4 + rs_rd_cnt × 64
```

- `rs_rd_cnt`：行内块索引 (0,1,2)，行切换时 `row_changed` 检测归零
- `total_rd_cnt`：全局计数，用于 `src_done` 和 `rs_first_line`
- `addr_rd_cnt = (gen_status && row_changed) ? 0 : rs_rd_cnt`：行首组合逻辑强制偏移 0

### 4.3 写地址

```
awbase = wbase + rs_wr_cnt × 64    (组合逻辑 awbase_comb, 始终反映当前 rs_wr_cnt)
```

- `rs_wr_cnt` 在 `wr_pos`（`trans_status[1]` 上升沿）递增
- `awbase_comb`：组合逻辑输出，**WR_ONLY / WAIT_DRAIN 直接使用**，不依赖 GEN_ADDR 锁存值

### 4.4 src_done

```
total_src_blocks = wheight_rs × ceil(crop_size / 16)
src_done = (total_rd_cnt >= total_src_blocks_r)   // 使用寄存后的 total_src_blocks_r
```

常量乘积 `total_src_blocks_r` / `rs_num_r` 每周期寄存，消除 DSP→比较器长路径。

---

## 5. 双线性插值 (resize)

### 5.1 流水线结构（串行 2-pass, 8 周期）

```
resize_cycle:  0  1  2  3  4  5  6  7
pass_sel:      0  0  0  0  1  1  1  1

Pass 0 (cycles 0-3, half0 pixel 0~7):
  cycle 0: Stage1 — 权重+像素(half0) 锁存
  cycle 1: Stage2 — DSP 乘法(half0) 锁存
  cycle 2: Stage3 — 加法+输出(half0) 锁存 → result_val[0:7]
  cycle 3: 流水线排空, pass_sel 保持 0

Pass 1 (cycles 4-7, half1 pixel 8~15):
  cycle 4: pass_sel 翻转 (NBA, cycle 5 生效)
  cycle 5: Stage1 — 权重+像素(half1) 锁存
  cycle 6: Stage2 — DSP 乘法(half1) 锁存
  cycle 7: Stage3 — 加法+输出(half1) 锁存 → result_val[8:15]
           result_valid 置位

3 级自定时流水线: weight/pixel_reg → result_reg(multiply) → result_val_reg(add)
所有寄存器均以 resize_status 为使能, 数据经 3 拍传播
```

16 像素拆为 2 个半区（half0: pixel 0~7, half1: pixel 8~15），串行执行。
`pass_sel` 单一信号控制在 cycle 4 翻转。像素 MUX、权重 MUX 均复用同一组硬件（8 路）。

### 5.2 R/G 通道 DSP 打包

```
A = {1'b0, R[7:0], 8'b0, G[7:0]} = R×2^16 + G   (24-bit < DSP48 A=25)
B = weight (max 64, 6-bit)

A×B = R×w×2^16 + G×w
  R×w ∈ [29:16], ΣR ∈ [31:16]  ← 16-bit 间隔, 无通道间污染
  G×w ∈ [13:0],  ΣG ∈ [15:0]

R_final = sum_RG[29:22]  (= ΣR >> 6 & 0xFF)  // sum_RG[31:16] 的 [13:6]
G_final = sum_RG[13:6]   (= ΣG >> 6 & 0xFF)
B_final = sum_B[13:6]    (B 通道单独 DSP)
```

每像素-邻居从 3 DSP → 2 DSP（R+G 打包 1 DSP + B 单独 1 DSP）。
8 像素 × 4 邻居 × 2 DSP(neighbor) = **64 DSP**。

### 5.3 半区复用

| 信号 | pass_sel=0 | pass_sel=1 |
|------|-----------|-----------|
| `px_base` | 0 | 8 |
| `src_idx_half[h]` | `src_idx[h]` | `src_idx[h+8]` |
| `q_val_half[h]` | `q_val[h]` | `q_val[h+8]` |
| `weight_half[h]` | `weight[h]` | `weight[h+8]` |
| `pixel_val_reg` 写入 | `q_val[0:7]` | `q_val[8:15]` |
| `result_val_reg` 写入 | `result_val[0:7]` | `result_val[8:15]` |

### 5.4 资源优化总结

| 项目 | 改前 | 改后 | 节省 |
|------|------|------|------|
| DSP | 192 | 64 | -67% |
| 32-bit 16:1 MUX | 64 | 32 | -50% |
| LUT (估算) | ~11,000 | ~5,500 | -50% |
| 流水线延迟 | ~4 cycle | 8 cycle | — |

优化手段：R/G 通道 DSP 打包 + 像素半区串行复用（8 像素/cycle × 2 pass）。

### 5.4 源像素索引

```
src_idx = x_delta_reg[11:8]     (4-bit, 0~15, 块内列索引)
```

- `x_delta ≥ 16.0` 时 `[11:8]` 模 16 回绕 → resize.v 内 `x_delta_clamped` 钳位到 0x0FFF
- **Q12 边界容错**：`src_idx < 15 ? rs_regs[src_idx+1] : rs_regs[15]`

### 5.5 权重量化

```
x_small = x_delta[7:5]    (3-bit, 0~7, 步长 1/8)
y_small = y_delta[7:5]

w11 = (8 - x_small) × (8 - y_small)     (1~64)
w12 = x_small × (8 - y_small)
w21 = (8 - x_small) × y_small
w22 = x_small × y_small

Σw = 64
```

### 5.6 输出归一化

```
sum   = w11·Q11 + w12·Q12 + w21·Q21 + w22·Q22    (每通道独立)
pixel = sum[13:6]                                  (÷64, floor)
```

像素格式：`{8'b0, R[7:0], G[7:0], B[7:0]}`。三通道（R/G/B）分别计算。

---

## 6. 输出 FIFO (resize_fifo)

### 6.1 接口

| 端口 | 说明 |
|------|------|
| `batch_wr_en` | 写使能，`result_valid_pos` 触发 |
| `batch_wr_data` | 512-bit，16 像素打包 |
| `batch_wr_count` | 有效像素数 (0~16) |
| `rd_en` | 读使能 (`flush_ready && !rd_valid`) |
| `rd_data` | 512-bit 输出 |
| `force_rd` | 强制排空 (< 16 像素补零) |

### 6.2 双槽设计

- 容量：32 × 32-bit = 2 个 16 像素槽
- `rd_ptr` 在 0↔16 交替，每次读完整一槽
- `wr_ptr` 按 `batch_wr_count` 递增
- 读后**不跳转** `wr_ptr`：剩余像素自然从下一槽起始位置开始

### 6.3 写入触发

```
result_valid: resize_cycle == 3 拉高 → resize_status_negedge 清零
result_valid_pos: 每次 RESIZE 精确触发一次
batch_wr_en = result_valid_pos
```

---

## 7. FSM 状态转移

```
IDLE → AXIS_PRE → AXIS_CAL → GEN_ADDR
                                 ↓
                    src_done → WAIT_DRAIN ⇄ WR_ONLY → COMP_DONE
                    rs_first_line → RD_ONLY
                    fifo_flush_ready && rs_last_line → WR_ONLY
                    fifo_flush_ready && !rs_last_line → WR_PIPELINE
                    !fifo_flush_ready → RD_ONLY
                                 ↓
                    RD_ONLY → RD_SECONE → RESIZE (8 cycles)
                    WR_PIPELINE → RD_SECONE → RESIZE (8 cycles)
                                 ↓
                    src_done? → WAIT_DRAIN : AXIS_CAL
```

**关键状态：**

| 状态 | 说明 |
|------|------|
| AXIS_PRE | 锁存缩放比 + crop 参数 |
| AXIS_CAL | axis 坐标计算 (stage1 latch) |
| GEN_ADDR | 地址生成 (addr_gen 3级流水线) |
| RESIZE | 双线性插值 (8 周期串行 2-pass) |
| WAIT_DRAIN | 排空 FIFO：`trans_status=00`, `awbase=awbase_comb` |
| WR_ONLY | 仅写不读：`trans_status=10`, `fifo_drain=1` |

**WAIT_DRAIN 循环：** `WAIT_DRAIN → WR_ONLY → WAIT_DRAIN → ... → fifo_empty → COMP_DONE`
- 每次 WR_ONLY 进入产生 `wr_pos` 沿 → `rs_wr_cnt++`
- `wr_done_reg` / `rd_done_reg` 在 WAIT_DRAIN 时清零，避免误跳转

**GEN_ADDR 延迟：** `rs_addr_gen_valid` 在 3 级流水线完成后置位，FSM 自动等待。

---

## 8. 定点数格式参考

| 信号 | 格式 | 范围 | 示例 (r=1.5) |
|------|------|------|-------------|
| `ratio_less` | Q1.3.12 | 0~7.999 | 2730 (= 32/48) |
| `ratio_greater` | Q1.7.8 | 0~127.996 | 384 (= 1.5) |
| `x_delta`, `y_delta` | Q1.7.8 | ±127.996 | 0x0180 = 1.5 |
| `pre_bias` | Q1.7.8 (signed) | ±16 | 0x0040 = 0.25 |
| `ratioed_y_full` | Q1.23.8 | | y_bias:[23:8], y_delta:[7:0] |
| 权重 | 3-bit 量化 | 0~7 (步长 1/8) | `x_delta[7:5]` |
| `data_valid` | INT | 0~16 | 10, 11 |

---

## 9. Golden Model 对照

```python
# 坐标映射 (== RTL)
src_x = (dst_x + 1) * scale_x - 1
src_y = (dst_y + 1) * scale_y - 1

# 权重量化 (3-bit, == RTL x_delta[7:5])
x_small = int(fx * 8)     # 0~7
w00_i = (8 - x_small) * (8 - y_small)

# 归一化 (== RTL sum >> 6)
val_i = (w00_i*p00 + w10_i*p10 + w01_i*p01 + w11_i*p11) // 64
```

---

## 10. 硬件适配修改（2026-06-16）

### 10.1 双行独立 rd_data_ready

**问题**：resize 需要读两行源数据（RD_ONLY → RD_SECONE），但原 `rd_data_ready` 只有一个信号，`dbeat_cnt` 在两行之间不清零，导致 RD_SECONE 立即跳转。

**修复**：拆分为两个独立信号：
```verilog
assign rd_data_ready_0 = (dbeat_cnt_0 >= arsize_input);  // 第一行
assign rd_data_ready_1 = !clr_dbeat_1 && (dbeat_cnt_1 >= arsize_input);  // 第二行
```

FSM 转换：
```
RD_ONLY:    rd_done_reg && rd_data_ready_0 → RD_SECONE
RD_SECONE:  rd_done_reg && rd_data_ready_1 → RESIZE
WR_PIPLINE: rd_done_reg && wr_done_reg && rd_data_ready_0 → RD_SECONE
```

### 10.2 enter_rd_secone / clr_dbeat_1

**问题**：`rd_second` 是 FSM 寄存器输出，`rd_second_pos` 比 `state` 进入 RD_SECONE 延迟一拍。FSM 在此延迟拍内已用旧 `rd_data_ready_1` 判断完毕。

**修复**：新增 `prev_state` 寄存器 + `enter_rd_secone` 边沿检测（比 `rd_second_pos` 早一拍）：
```verilog
wire enter_rd_secone = (state == RD_SECONE) && (prev_state != RD_SECONE);
assign clr_dbeat_1 = enter_rd_secone;
```

`clr_dbeat_1` 组合逻辑门控 `rd_data_ready_1`（`!clr_dbeat_1` 同拍清零），确保 FSM 检查条件时看到 0。

### 10.3 rd_start 在 RD_SECONE 触发

**问题**：`rd_start_pulse_gen` 在 `RD_ONLY → RD_SECONE` 时未清零，DMA 不会为第二行产生读脉冲。

**修复**：`enter_rd_secone` 复位 `rd_start_pulse_gen`，允许在 RD_SECONE 产生新的 `rd_start`。

### 10.4 batch_wr_data 保持组合逻辑

`batch_wr_data` 改为纯组合逻辑 `assign batch_wr_data = {result_val[15:0]}`，`result_valid_pos`（cycle 6）触发时 16 像素已全部稳定。

### 10.5 rd_cnt / wr_cnt 计数简化

同 hadamard/gather：直接每拍握手计数，不加武装机制。

### 10.6 仿真 R 队列修复

`r_queue_cnt > 0` 保护防止对空队列重复握手导致计数器下溢。

### 10.7 寄存器映射

| 功能 | 寄存器索引 | 字节偏移 |
|------|-----------|---------|
| Resize 启动 | 0x41 | 0x104 |
| Resize 完成 | 0x50 | 0x140 |
| FSM 状态调试 | 0x24 | 0x90 |

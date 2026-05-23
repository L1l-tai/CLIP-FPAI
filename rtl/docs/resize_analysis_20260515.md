# Resize/Crop 算子 RTL 分析报告（修订版）

**原版日期：** 2026-05-15
**修订日期：** 2026-05-23
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

## 2. 坐标映射

### 2.1 x 方向

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

### 2.2 y 方向

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

### 2.3 pre_bias 链

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

### 2.4 data_valid 计算

```
ratioed_x_full_add = 16.0 + pre_bias                      (Q1.7.8, 有符号加法)
ratioed_x_full     = ratio_less × ratioed_x_full_add_r    (32-bit)
ratioed_x          = ratioed_x_full[27:12]                (Q1.7.8)
data_valid_int     = clamp(ratioed_x[15:8], 0, 16)        (整数截断, 钳位)
```

`ratio_less = dst_w / src_w`，Q1.3.12 格式（例：32/48 = 2730 = 0x0AAA）。

## 3. 双线性插值

### 3.1 源像素索引

```
src_idx = x_delta_reg[11:8]     (4-bit, 0~15, 块内列索引)
```

- `x_delta ≥ 16.0` 时 `[11:8]` 模 16 回绕 → resize.v 内 `x_delta_clamped` 钳位到 0x0FFF
- **Q12 边界容错**：`src_idx < 15 ? rs_regs[src_idx+1] : rs_regs[15]`

### 3.2 权重量化

```
x_small = x_delta[7:5]    (3-bit, 0~7, 步长 1/8)
y_small = y_delta[7:5]

w11 = (8 - x_small) × (8 - y_small)     (1~64)
w12 = x_small × (8 - y_small)
w21 = (8 - x_small) × y_small
w22 = x_small × y_small

Σw = 64
```

### 3.3 输出归一化

```
sum   = w11·Q11 + w12·Q12 + w21·Q21 + w22·Q22    (每通道独立)
pixel = sum[13:6]                                  (÷64, floor)
```

像素格式：`{8'b0, R[7:0], G[7:0], B[7:0]}`。三通道（R/G/B）分别计算。

## 4. 输出 FIFO (resize_fifo)

### 4.1 接口

| 端口 | 说明 |
|------|------|
| `batch_wr_en` | 写使能，`result_valid_pos` 触发 |
| `batch_wr_data` | 512-bit，16 像素打包 |
| `batch_wr_count` | 有效像素数 (0~16) |
| `rd_en` | 读使能 (`flush_ready && !rd_valid`) |
| `rd_data` | 512-bit 输出 |
| `force_rd` | 强制排空 (< 16 像素补零) |

### 4.2 双槽设计

- 容量：32 × 32-bit = 2 个 16 像素槽
- `rd_ptr` 在 0↔16 交替，每次读完整一槽
- `wr_ptr` 按 `batch_wr_count` 递增
- 读后**不跳转** `wr_ptr`：剩余像素自然从下一槽起始位置开始

### 4.3 写入触发

```
result_valid: resize_status_r3_pos 拉高 → resize_status_negedge 清零
result_valid_pos: 每次 RESIZE 精确触发一次
batch_wr_en = result_valid_pos
```

## 5. 地址生成 (resize_addr_gen)

### 5.1 读地址

```
arbase = rbase + (y_bias + crop_off_y) × rwidth_rs × 4
               + crop_off_x × 4 + rs_rd_cnt × 64
```

- `rs_rd_cnt`：行内块索引 (0,1,2)，行切换时 `row_changed` 检测归零
- `total_rd_cnt`：全局计数，用于 `src_done` 和 `rs_first_line`
- `addr_rd_cnt = (gen_status && row_changed) ? 0 : rs_rd_cnt`：行首组合逻辑强制偏移 0

### 5.2 写地址

```
awbase = wbase + rs_wr_cnt × 64    (组合逻辑 awbase_comb, 始终反映当前 rs_wr_cnt)
```

- `rs_wr_cnt` 在 `wr_pos`（`trans_status[1]` 上升沿）递增
- `awbase_comb`：组合逻辑输出，**WR_ONLY / WAIT_DRAIN 直接使用**，不依赖 GEN_ADDR 锁存值

### 5.3 src_done

```
total_src_blocks = wheight_rs × ceil(crop_size / 16)
src_done = (total_rd_cnt >= total_src_blocks)
```

## 6. FSM 状态转移

```
IDLE → AXIS_PRE → AXIS_CAL → GEN_ADDR
                                 ↓
                    src_done → WAIT_DRAIN ⇄ WR_ONLY → COMP_DONE
                    rs_first_line → RD_ONLY
                    fifo_flush_ready && rs_last_line → WR_ONLY
                    fifo_flush_ready && !rs_last_line → WR_PIPELINE
                    !fifo_flush_ready → RD_ONLY
                                 ↓
                    RD_ONLY → RD_SECONE → RESIZE
                    WR_PIPELINE → RD_SECONE → RESIZE
                                 ↓
                    src_done? → WAIT_DRAIN : AXIS_CAL
```

**关键状态：**

| 状态 | 说明 |
|------|------|
| AXIS_PRE | 锁存缩放比 + crop 参数 |
| AXIS_CAL | 2 级流水线计算 x/y 坐标 |
| WAIT_DRAIN | 排空 FIFO：`trans_status=00`, `awbase=awbase_comb` |
| WR_ONLY | 仅写不读：`trans_status=10`, `fifo_drain=1` |

**WAIT_DRAIN 循环：** `WAIT_DRAIN → WR_ONLY → WAIT_DRAIN → ... → fifo_empty → COMP_DONE`
- 每次 WR_ONLY 进入产生 `wr_pos` 沿 → `rs_wr_cnt++`
- `wr_done_reg` / `rd_done_reg` 在 WAIT_DRAIN 时清零，避免误跳转

## 7. 定点数格式参考

| 信号 | 格式 | 范围 | 示例 (r=1.5) |
|------|------|------|-------------|
| `ratio_less` | Q1.3.12 | 0~7.999 | 2730 (= 32/48) |
| `ratio_greater` | Q1.7.8 | 0~127.996 | 384 (= 1.5) |
| `x_delta`, `y_delta` | Q1.7.8 | ±127.996 | 0x0180 = 1.5 |
| `pre_bias` | Q1.7.8 (signed) | ±16 | 0x0040 = 0.25 |
| `ratioed_y_full` | Q1.23.8 | | y_bias:[23:8], y_delta:[7:0] |
| 权重 | 3-bit 量化 | 0~7 (步长 1/8) | `x_delta[7:5]` |
| `data_valid` | INT | 0~16 | 10, 11 |

## 8. Golden Model 对照

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

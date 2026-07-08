# fmt_cvt 格式转换算子 RTL 分析报告

**日期：** 2026-07-08
**分析范围：** `rtl/custom_op/fmt_cvt/` 全部 RTL 文件

---

## 一、文件清单

| 文件 | 功能 |
|------|------|
| `fmt_cvt_fsm.v` | 5 状态 FSM：GEN_ADDR → RD_GROUP → REPACK → WR_GROUP → DONE |
| `fmt_cvt.v` | 核心模块：地址生成 + DMA 数据通路 + AVR 输出 + 双向 repack |

---

## 二、整体架构

```
fmt_cvt_fsm                              fmt_cvt
    │                                       │
    │ gen_status ──────────────────────────►│ 地址偏移计算 (每 group 一次)
    │ trans_data ──────────────────────────►│ 0=RD_GROUP(读), 1=WR_GROUP(写+AVR输出)
    │ repack_en ───────────────────────────►│ 锁存 core_dout 到 dout_reg
    │                                       │
    ▼                                       ▼
 arbiter ←── arbase/awsize ──────────────── DMA 读 3 or 4 beats
          ←── awbase/awsize ──────────────── DMA 写 4 or 3 beats
          ←── dout/dout_valid ────────────── AVR → arbiter → DMA 写
          ──► din/din_valid ──────────────── DMA 读数据直连
```

---

## 三、FSM 状态机

```
IDLE ──(start)──► GEN_ADDR ──(addr_gen_valid)──► RD_GROUP
  ▲                                                  │
  │                                          (rd_done && rd_data_ready)
  │                                                  │
  │                                                  ▼
  │                                               REPACK
  │                                                  │
  │                                            (1 cycle)
  │                                                  │
  │                                                  ▼
  └────────────── DONE ◄──(group_cnt>=total)── WR_GROUP
                      ◄──(wr_done_reg)──────────────┘
```

| 状态 | 操作 |
|------|------|
| `IDLE` | 等待 `comp_start` |
| `GEN_ADDR` | `gen_status=1`，等 `addr_gen_valid`（1 拍延迟），地址锁存 |
| `RD_GROUP` | `rd_start=1`，`trans_data=0`，DMA 读 beats 入 shift_reg，双重校验 `rd_done_reg && rd_data_ready` |
| `REPACK` | 1 拍：`repack_en` 锁存 core_dout → dout_reg |
| `WR_GROUP` | `wr_start=1`，`trans_data=1`，AVR 逐拍输出，`pipeline_busy` 流控 |
| `DONE` | `comp_done=1`，等 `start=0` 回 IDLE |

---

## 四、数据通路

### 4.1 正向 (direction=0): RGB888 → X888

```
DDR (RGB888, 3 beats × 512b = 1536b)
  │  din[511:0] × 3 → shift_reg[1535:0]
  ▼
shift_reg[i*24 +: 24] → px24[i] (64 × 24b)
  │  {8'd0, px24} → px32[i] (64 × 32b)
  ▼
dout_forward[2047:0] = {px32[63], ..., px32[0]}
  │  repack_en → dout_reg[2047:0]
  ▼
dout_reg[wr_cnt*512 +: 512] → dout_rs → AVR → dout
  │  wr_cnt=0,1,2,3 → 4 beats × 512b
  ▼
DDR (X888, 4 beats × 512b = 2048b)
```

### 4.2 反向 (direction=1): X888 → RGB888

```
DDR (X888, 4 beats × 512b = 2048b)
  │  din[511:0] × 4 → shift_reg[2047:0]
  ▼
shift_reg[i*32 +: 24] → px24[i] (64 × 24b, 去掉 [31:24] padding)
  │  直接 pack: dout_reverse[j*24 +: 24] = px24[j]
  ▼
dout_reverse[1535:0] (64 × 24b 紧凑, 无 padding)
  │  {512'd0, dout_reverse} → core_dout[2047:0]
  │  repack_en → dout_reg[2047:0]
  ▼
dout_reg[wr_cnt*512 +: 512] → dout_rs → AVR → dout
  │  wr_cnt=0,1,2 → 3 beats × 512b
  ▼
DDR (RGB888, 3 beats × 512b = 1536b)
```

### 4.3 关键时序约束

| 信号 | 读阶段 (trans_data=0) | 写阶段 (trans_data=1) |
|------|------|------|
| `din_ready` | 1（直通） | 0 |
| `dout_rs` | 512'd0 | dout_reg 当前 beat |
| `dout_valid_rs` | 0 | result_valid && !pipeline_busy |
| `pipeline_busy` | 0（复位） | AVR 捕获=1, arbiter 消费=0 |

---

## 五、地址生成

```
rd_offset = group_cnt × rd_bytes_per_group  (DSP 乘法)
wr_offset = group_cnt × wr_bytes_per_group  (DSP 乘法)

rd_bytes_per_group: direction=0 → 192 (3×64), direction=1 → 256 (4×64)
wr_bytes_per_group: direction=0 → 256 (4×64), direction=1 → 192 (3×64)

arbase = src_addr + rd_offset    arsize = rd_beats_needed (3 or 4)
awbase = dst_addr + wr_offset    awsize = wr_beats_needed (4 or 3)
```

`group_cnt` 在 `gen_status_pos`（上升沿）递增，避免 GEN_ADDR 多拍重复计数。

---

## 六、寄存器映射

| 地址 | 名称 | R/W | 描述 |
|------|------|-----|------|
| 0x51 | FC_CTRL | W | [0]=start, [1]=direction (0=RGB888→X888, 1=X888→RGB888) |
| 0x52 | FC_SRC_ADDR | W | 源 PL-DDR 地址 |
| 0x53 | FC_DST_ADDR | W | 目标 PL-DDR 地址 |
| 0x54 | FC_PIXEL_CNT | W | 总像素数（须为 64 的倍数） |
| 0x61 | FC_STATUS | R | [0]=busy, [1]=done（通过 `comp_done` 间接） |
| 0x81 | FC_VERSION | R | 0x20260708 |

---

## 七、AVR 输出流控（对齐 hadamard）

```
result_valid = trans_data && (wr_cnt < wr_beats_needed)
dout_valid_rs = result_valid && !pipeline_busy && trans_data

pipeline_busy:  AVR 捕获 (dout_valid_rs && dout_ready_rs) → 1
                arbiter 消费 (dout_valid && dout_ready)   → 0
wr_cnt:         每次 arbiter 消费后 +1, 到 wr_beats_needed 后 result_valid=0
```

每 beat 独立脉冲，AVR 不会堆积多拍数据。

---

## 八、参数汇总

| 参数 | 正向 | 反向 |
|------|------|------|
| 输入格式 | RGB888 (24b/px) | RGBX8888 (32b/px) |
| 输出格式 | RGBX8888 (32b/px) | RGB888 (24b/px) |
| 读 beats/组 | 3 | 4 |
| 写 beats/组 | 4 | 3 |
| 读偏移/组 | 192B | 256B |
| 写偏移/组 | 256B | 192B |
| shift_reg 有效位 | [1535:0] | [2047:0] |
| dout_reg 有效位 | [2047:0] | [1535:0] |
| 总 groups | ceil(pixels/64) | ceil(pixels/64) |

---

## 九、软件集成

```cpp
// 正向: RGB888 → X888
reg.write(0x52, imk_output_addr);
reg.write(0x53, temp_buffer_addr);
reg.write(0x54, total_pixels);
reg.write(0x51, 0x1);   // start, direction=0

// 反向: X888 → RGB888
reg.write(0x52, temp_buffer_addr);
reg.write(0x53, npu_input_addr);
reg.write(0x54, total_pixels);
reg.write(0x51, 0x3);   // start, direction=1

// 等待完成
while ((reg.read(0x61) & 1) == 0);
```

# Gather 算子 RTL 分析报告

**日期：** 2026-05-15  
**分析范围：** `rtl/custom_op/gather/` 全部 RTL 文件  
**分析人：** Claude Code (Normalcy_Lin session)

---

## 一、文件清单

| 文件 | 功能 |
|------|------|
| `gather_fsm.v` | 顶层状态机，控制索引读取 → 地址生成 → 数据搬移流程 |
| `gather.v` | 核心模块：索引 FIFO 管理 + DMA 地址计算 + 数据直通 |

---

## 二、整体架构

```
gather_fsm                              gather
   │                                       │
   │ gen_status ──────────────────────────►│ 生成 DMA 读写地址 (每行一次)
   │ rd_indices ──────────────────────────►│ 索引读取使能 (存入 FIFO)
   │ trans_data ──────────────────────────►│ 数据传输使能 (从 FIFO 读索引)
   │                                       │
   ▼                                       ▼
DMA ←── arbase/awbase ───────────────────  arbiter → DMA
        (FSM 控制)                         (地址计算)
```

---

## 三、计算流程

### 3.1 FSM 状态机

```
IDLE ──(comp_start)──► RD_INDICES ──(rd_done)──► R_INDICES_DONE
  ▲                                                    │
  │                                                    ▼
  │                                               GEN_ADDR
  │                                                    │
  │                                          (addr_gen_valid)
  │                                                    │
  │                                                    ▼
  └──────────── COMP_DONE ◄──(rd_last_line)── WR_PIPLINE
                    │                            │
                    └──(rd_done && wr_done)──────┘
```

| 状态 | 操作 |
|------|------|
| `IDLE` | 等待 `comp_start`（经 pulse_cross 同步） |
| `RD_INDICES` | DMA 读取索引表 → `gather.v` 将索引写入内部 FIFO |
| `R_INDICES_DONE` | 索引读取完成，过渡到地址生成 |
| `GEN_ADDR` | `gather.v` 从 FIFO 弹出一个索引，计算源/目标地址 |
| `WR_PIPLINE` | DMA 按计算出的地址读取源数据并写入目标地址 |
| `COMP_DONE` | 所有索引处理完毕，拉高 `comp_done` |

### 3.2 地址计算（gather.v）

```verilog
// 源地址: 从索引指向的行读取数据
arbase_offset_c = indice_now_reg * (data_width_reg << 6);
arbase_data_gen_c = arbase_data_reg + arbase_offset;
arsize_data_gen_c = data_width_reg;

// 目标地址: 按输出顺序连续写入
awbase_offset_c = output_addr_cnt * (data_width_reg << 6);
awbase_gen_c = awbase_dout_reg + awbase_offset;
awsize_gen_c = data_width_reg;
```

**地址公式：**
```
src_addr = arbase_data + index × data_width × 64    // 64 = bytes per 512-bit block
dst_addr = awbase_dout + out_pos   × data_width × 64  // 顺序输出
```

**关键参数 `data_width`：** 每个数据行的 512-bit 块数量。例如 CLIP 的 text embedding (512 维 float32 = 2048 字节)，`data_width = 2048 / 64 = 32`。

### 3.3 索引 FIFO 管理（gather.v）

```
DMA 读数据 (rd_indices=1)
    │
    ▼
indices_fifo_winc = rd_indices & din_valid & ~indices_fifo_almost_full
indices_fifo_wdata = din                    // 512-bit 直接入 FIFO
    │
    ▼
sync_fifo_reg (深度 32, 512-bit 宽, 几乎满阈值 20)
    │
    ▼
trans_data_pos → indices_fifo_rinc         // 弹出下一个 512-bit 索引块
current_indices = indices_fifo_dout        // 当前正在处理的索引块
indice_now = current_indices[current_indices_cnt*32 +: 32]  // 提取 32-bit 索引值
```

**索引处理流程：**
1. `RD_INDICES` 状态：DMA 将索引表读入，通过 `din` 写入 FIFO
2. `GEN_ADDR` 状态：从 FIFO 弹出一个 512-bit 块，按 `current_indices_cnt` 提取对应的 32-bit 索引值
3. 一个 512-bit 块包含 16 个 32-bit 索引，`current_indices_cnt` 从 0 递增到 15，自动切换到下一个 FIFO 块

### 3.4 行计数器

| 信号 | 功能 |
|------|------|
| `current_indices_cnt[3:0]` | 当前 512-bit 块内的索引偏移 (0~15)，每个索引 32-bit |
| `output_addr_cnt[7:0]` | 输出行计数器，每完成一次 `trans_data` 加 1 |
| `rd_last_line` | `output_addr_cnt == indices_width - 1` 时拉高，表示最后一行 |

### 3.5 数据直通

```
dout_rs = rd_indices ? 512'd0 : din         // 索引读取阶段输出 0, 数据传输阶段直通
din_ready = rd_indices ? ~fifo_almost_full  // 索引阶段背压由 FIFO 控制
                      : dout_ready_rs       // 数据阶段背压由 AVR 控制
dout_valid_rs = rd_indices ? 1'b0           // 索引阶段不输出
                          : din_valid && din_ready
```

---

## 四、寄存器配置

| 寄存器 | 地址 | 功能 |
|--------|------|------|
| `rfu_wreg0` | 0x05 | `indices_width`：索引总数量 |
| `rfu_wreg1` | 0x06 | `data_width`：每行 512-bit 块数 |
| `rbase1` | 0x01 | 索引表基地址 (低 16-bit) |
| `rsize1` | 0x01 | 索引表大小 (高 16-bit，单位 512-bit 块) |
| `rbase2` | 0x03 | 源数据基地址 |
| `wbase1` | 0x02 | 目标数据基地址 |
| `comp_start` | 0x00 | 启动计算（写 1 触发） |

---

## 五、CLIP 典型参数

```
indices_width = 77          # token 序列长度
data_width    = 8           # 8 blocks = 512 bytes per token embedding
data_len      = 49408       # vocab size
arbase_data   = 0x0000_2000 # 源数据起始地址
awbase_dout   = 0x0001_0000 # 目标地址
```

一次 Gather 操作：从 49408 行中按 77 个索引读取，输出 77 × 512 字节。

---

## 六、数据流时序

```
Cycle     RD_INDICES              R_INDICES_DONE    GEN_ADDR         WR_PIPLINE
─────     ──────────              ──────────────    ────────         ──────────
  0       DMA读索引块0 → FIFO
  1       DMA读索引块1 → FIFO
  2                               过渡
  3                                                弹出FIFO块0
                                                  提取idx[0]
                                                  计算地址
  4                                                                DMA读src[idx[0]]
                                                                   DMA写dst[0]
  5                                                                (等待rd_done+wr_done)
 ...                                                               ...
  N                                                弹出idx[15]
                                                   rd_last_line?
                                                                   DMA读/写最后一行
                                                                   → COMP_DONE
```

---

## 七、验证结论

| 验证项 | 状态 | 说明 |
|--------|------|------|
| FSM 状态转移 | ✓ 正确 | 索引读取 → 地址生成 → 数据搬移流程完整 |
| 地址计算公式 | ✓ 正确 | `index * data_width * 64` 匹配 Python golden model |
| 索引 FIFO 管理 | ✓ 正确 | 深度 32, 512-bit 宽, 支持流式索引处理 |
| 数据直通 | ✓ 正确 | 索引阶段输出 0, 数据阶段 din→dout 直通 |
| AVR 寄存器切片 | ✓ 正确 | 输出端隔离组合逻辑 |
| Golden model 对比 | ✓ 通过 | RTL 输出与 `gather_golden.py` 完全一致 |

---

## 八、与 Hadamard/Resize 的接口差异

Gather 算子在 `customop_top.v` 中的接口与 Hadamard/Resize 相同（统一的 `itf_ra_*` 寄存器接口 + `itf_*` DMA 接口），通过 `arbiter.v` 仲裁 DMA 访问。Gather 优先级最高（arbiter 按 Gather > Hadamard > Resize 顺序检查）。

Gather 特有的信号：
- `rd_indices`：索引读取阶段使能（Hadamard/Resize 无此阶段）
- `trans_data`：数据传输阶段使能
- `indices_width` / `data_width`：Gather 专用配置寄存器

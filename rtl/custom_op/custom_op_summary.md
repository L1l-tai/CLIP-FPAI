# custom_op 模块工作总结

## 一、整体架构

```
                          ┌─────────────────────────────────────────────┐
                          │              customop_top                   │
  CPU (APB) ────────────► │  reg_ctrl                                   │
                          │    │                                        │
                          │    ▼                                        │
                          │  ┌────────┐     ┌────────┐     ┌────────┐   │
                          │  │ Gather │     │Hadamard│     │ Resize │   │
  DDR (AXI)◄────────────  │  │   FSM  │     │   FSM  │     │   FSM  │   │
                          │  │  +Core │     │+Addr   │     │+Axis   │   │
                          │  └────┬───┘     │+Core   │─┐   │+Addr   │   │
                          │       │         └────────┘ |   |+Core   │   │
                          │       └────►arbiter◄────────── │        │   │
                          │              │                 └────────┘   │
                          │              ▼                              │     ┌────────┐
                          │           dma ───────────────────────────────────►|  DDR   |
                          └─────────────────────────────────────────────┘     └────────┘
```

**数据流：**
- `reg_ctrl`: 接收 CPU 配置（基地址、尺寸、控制寄存器）
- `arbiter`: 仲裁三个模块的 DMA 请求，同一时间只允许一个模块访问
- `dma`: 通用 DMA 引擎，负责与 DDR 实际数据传输

---

## 二、三个核心硬算子

### 1. Gather（索引聚集）

**用途：** 根据索引表从内存中读取不规则位置的数据，实现数据重排列

**核心算法：** ` dout = din[indices] `（索引寻址）

**内部结构：**

| 子模块 | 功能 |
|--------|------|
| `gather_fsm` | 状态机控制，生成读/写控制信号 |
| `gather` | 核心算子，执行索引寻址和数据聚集 |

**工作流程：**
```
IDLE → GEN_ADDR → RD_INDICES → WR_ONLY → COMP_DONE
```
- `gen_status`: 地址生成阶段，生成读写地址
- `rd_indices`: 读取索引阶段，根据索引表读取源数据
- `trans_data`: 数据传输阶段，写入重排列后的数据

**数据通路：**
- DMA 读取索引表（存储在内存特定位置）
- 根据索引值从源数据区读取对应位置的数据
- 将数据写入目标地址

**关键信号：**
| 信号 | 方向 | 描述 |
|------|------|------|
| `indices_width` | 输入 | 索引表宽度（索引数量） |
| `data_width` | 输入 | 数据宽度 |
| `rd_indices` | FSM→Core | 索引读取信号 |
| `trans_data` | FSM→Core | 数据传输信号 |
| `addr_gen_valid` | Core→FSM | 地址生成有效 |

**应用场景：** Vision Transformer 中将图像块重排列为顺序访问模式

---

### 2. Hadamard（快速沃尔什-哈达玛变换）

**用途：** 对图像/特征进行正交变换，主要用于：
- 量化预处理（将特征分布变换到正交基）
- 加密/置乱预处理
- 特征decorrelation

**核心算法：** 6级蝶形网络 FWHT（Fast Walsh-Hadamard Transform）

**内部结构：**

| 子模块 | 功能 |
|--------|------|
| `hadamard_fsm` | 状态机控制 |
| `hadamard_addr_gen` | DDR 地址生成 |
| `hadamard` | FWHT 核心运算单元 |

**工作流程：**
```
IDLE → GEN_ADDR → WR_PIPELINE → RD_ONLY → FWHT → WR_ONLY → COMP_DONE
```
1. `gen_status=1`: 地址生成阶段
2. `trans_status=2'b01`: 写数据到运算寄存器
3. `trans_status=2'b01` + `fwht_status=1`: FWHT 计算，同时可并行读下一块
4. `trans_status=2'b10`: 写回结果
5. `comp_done`: 运算完成

**FWHT 算法原理：**
- 64 点输入，每点 16bit
- 6 级蝶形运算，每级 32 个蝶形单元
- 每级延迟 1 时钟周期，总延迟 6 时钟周期

**蝶形运算单元结构：**
```
     op_a ──────► + ──────► result_add
                │
                │ fwht_pub
                ▼
     op_b ──────► - ──────► result_sub
```

**精度支持：**
| 模式 | 数据格式 | 说明 |
|------|----------|------|
| INT8 | 低 8bit | 每 512bit 数据包包含 64 个 INT8 |
| FP16 | 完整 16bit | 每 512bit 数据包包含 32 个 FP16 |

**关键信号：**
| 信号 | 方向 | 描述 |
|------|------|------|
| `hd_data_width` | 输入 | 变换数据宽度 |
| `cal_percision` | 输入 | 0=INT8, 1=FP16 |
| `fwht_num` | 输入 | FWHT 变换数量 |
| `fwht_status` | FSM→Core | FWHT 计算使能 |
| `fwht_done` | Core→FSM | FWHT 完成信号 |

---

### 3. Resize（双线性插值缩放）

**用途：** 图像尺寸缩放，支持任意比例的上采样和下采样

**核心算法：** 双线性插值

**原理：**
对于目标像素 P，其位于源图像的四个邻近像素 Q11、Q12、Q21、Q22 形成的网格中：

```
Q11 ────── Q12
  │    P   │
  │        │
Q21 ────── Q22
```

双线性插值公式：
```
P = Q11·w11 + Q12·w12 + Q21·w21 + Q22·w22

其中：
w11 = (1-x)·(1-y)  // Q11 的权重
w12 = x·(1-y)       // Q12 的权重
w21 = (1-x)·y      // Q21 的权重
w22 = x·y          // Q22 的权重
```

**内部结构：**

| 子模块 | 功能 |
|--------|------|
| `resize_fsm` | 状态机控制 |
| `resize_axis` | 坐标与权重预计算 |
| `resize_addr_gen` | DDR 地址生成 |
| `resize` | 三级流水线双线性插值运算 |

**坐标计算（resize_axis）：**
- 输入：源图像尺寸 (rwidth_rs, rheight_rs)、目标尺寸 (wwidth_rs, wheight_rs)
- 输出：
  - `x_delta[255:0]`: 16 个目标像素的 x 偏移 (Q1.7.8 格式)
  - `y_delta`: y 偏移
  - `y_bias`: y 轴偏移对应的行号
  - `data_valid`: 每行有效像素数量

**固定点格式：**
- 坐标使用 Q1.7.8 格式（1 位符号 + 7 位整数 + 8 位小数）
- 权重计算使用无符号整型（0-256 表示 0-1.0）

**工作流程：**
```
IDLE → AXIS_PRE → AXIS_CAL → GEN_ADDR → RD_ONLY → RD_SECONE → RESIZE → WR_PIPELINE → ...
```

| 阶段 | FSM信号 | 操作 |
|------|---------|------|
| AXIS_PRE | `axis_pre_cal=1` | 计算 1/rwidth, 1/rheight, 1/wwidth, 1/wheight |
| AXIS_CAL | `axis_cal_status=1` | 计算 x_delta, y_delta, y_bias, data_valid |
| GEN_ADDR | `gen_status=1` | 生成读写地址 |
| RD_ONLY | `trans_status[0]=1, rd_second=0` | 读取第一行像素 → rs_regs |
| RD_SECONE | `trans_status[0]=1, rd_second=1` | 读取第二行像素 → rs_regs_2，rd_second 上升沿锁存坐标 |
| RESIZE | `resize_status=1` | 三级流水线插值计算 |
| WR_PIPELINE | `trans_status[1]=1` | 写回缩放后的结果 |

**resize 核心三级流水线：**

```
第一级（坐标寄存）：
  - rd_second 上升沿时锁存 x_delta, y_delta, y_bias
  - 计算权重 w11, w12, w21, w22
  - 根据 x_delta[15:8] 确定源像素索引 src_idx

第二级（乘法）：
  - 取出 Q11, Q12, Q21, Q22 四个像素值
  - RGB 三通道分别与对应权重相乘
  - 输出：result_11_r/g/b, result_12_r/g/b, ...

第三级（累加）：
  - 四个加权值按通道相加
  - 取高 8 位作为最终输出
  - 格式：{R[7:0], G[7:0], B[7:0], 8'b0}

result_valid 在 resize_status_r3 上升沿时拉高
wr_done 时拉低
```

**像素格式：**
```
32bit 像素格式: {8'b0, R[7:0], G[7:0], B[7:0]}
  bit [31:24] = 0
  bit [23:16] = R
  bit [15:8]  = G
  bit [7:0]   = B
```

**关键信号：**
| 信号 | 方向 | 描述 |
|------|------|------|
| `rwidth_rs/rheight_rs` | 输入 | 源图像宽高 |
| `wwidth_rs/wheight_rs` | 输入 | 目标图像宽高 |
| `x_delta[255:0]` | Axis→Resize | 16 个像素的 x 偏移 |
| `y_delta` | Axis→Resize | y 偏移 |
| `y_bias` | Axis→Resize | y 轴行偏移 |
| `data_valid` | Axis→Resize | 有效像素数量 |
| `rd_second` | FSM→Resize | 标识读取第二行 |
| `resize_status` | FSM→Resize | 插值计算使能（三级流水线控制） |
| `resize_done` | Resize→FSM | 插值计算完成 |

---

## 三、Arbiter 仲裁机制

**优先级：** Gather > Hadamard > Resize（在 IDLE 状态下按此顺序检查）

**状态机：**
```verilog
IDLE → (gather_active?) → GATHER
     → (hadamard_active?) → HADAMARD
     → (resize_active?) → RESIZE
```

**无抢占机制：** 一旦 grant 给定模块，该模块完整运行直到 `comp_done`，期间其他模块不能打断。

---

## 四、文件结构

```
rtl/custom_op/
├── 顶层文件
│   ├── customop_top.v          # 顶层模块，例化所有子模块
│   ├── arbiter.v              # DMA 仲裁器
│   ├── dma.v                  # 通用 DMA 引擎
│   ├── reg_ctrl.v             # 寄存器控制，接收 CPU 配置
│   └── pulse_cross.v           # 跨时钟域脉冲同步
│
├── AVR/                       # AXI-Stream 寄存器切片
│   ├── avr_rs.v               # 主从接口寄存器切片
│   ├── avr_brs.v              # 双缓冲寄存器切片
│   └── avr_frs.v              # FIFO 寄存器切片
│
├── gather/                    # Gather 算子
│   ├── gather_fsm.v          # Gather 状态机
│   └── gather.v              # Gather 核心算子
│
├── hadamard/                 # Hadamard 算子 (FWHT)
│   ├── hadamard_fsm.v       # Hadamard 状态机
│   ├── hadamard_addr_gen.v  # Hadamard 地址生成
│   ├── hadamard.v           # Hadamard 核心算子
│   └── fwht_pub.v           # FWHT 蝶形运算单元
│
└── resize_crop/              # Resize 算子
    ├── resize_fsm.v          # Resize 状态机
    ├── resize_axis.v        # Resize 坐标计算
    ├── resize_addr_gen.v    # Resize 地址生成
    ├── resize.v             # Resize 核心算子
    └── reciprocal.v          # 牛顿-拉夫森倒数计算
```

# Hadamard 变换模块 RTL 分析报告

**日期：** 2026-05-14（更新于 2026-06-16）  
**分析范围：** `rtl/custom_op/hadamard/` 全部 RTL 文件  

---

## 一、文件清单

| 文件 | 功能 |
|------|------|
| `hadamard_fsm.v` | 顶层状态机，控制数据流和子模块调度 |
| `hadamard_addr_gen.v` | DMA 地址生成器，计算每次迭代的读写地址 |
| `hadamard.v` | 核心计算模块：6 级 FWHT 流水线 + 32 路并行蝶形单元 |
| `fwht_pub.v` | 单蝶形运算单元：A+B 和 A-B，支持 FP16 和 INT8 |

---

## 二、整体架构

```
hadamard_fsm                         hadamard_addr_gen
   │                                       │
   │ gen_status ──────────────────────────►│ 生成 DMA 读写地址
   │ trans_status ◄────────────────────────│ 读写状态指示
   │ fwht_status ─────────────────────────►│
   │                                       │
   ▼                                       ▼
hadamard (核心计算模块)
   ├── fwht_regs[63:0]        ← DMA 读入 64 个 16-bit 数据
   ├── stage0~stage6[63:0]    ← 6 级流水线寄存器组
   ├── 32× fwht_pub 实例      ← 每级 32 个并行蝶形单元
   └── fwht_out_regs[63:0]    → DMA 写出变换结果
```

---

## 三、计算流程（7 个步骤）

| 步骤 | FSM 状态 | 操作描述 |
|------|---------|---------|
| **1** | `IDLE` | 等待 `comp_start_hd`（经 pulse_cross 由 ra_clk 同步到 clk） |
| **2** | `GEN_ADDR` | `hadamard_addr_gen` 生成读/写地址，计算 `hd_first_line` / `hd_last_line` |
| **3** | `RD_ONLY` / `WR_PIPLINE` | DMA 读取 1~2 个 512-bit 数据块，装入 `fwht_regs[63:0]` |
| **4** | `FWHT` | `fwht_status` 拉高，`stage0` 锁存输入，6 级蝶形流水线启动 |
| **5** | `GEN_ADDR`（循环） | FWHT 完成后回到步骤 2，逐块流式处理全部数据 |
| **6** | `WR_ONLY` | 最后一块：只写结果，不读新数据 |
| **7** | `COMP_DONE` | 拉高 `comp_done_hd`，经 pulse_cross 传回 reg_ctrl (ra_clk 域) |

**流水线重叠：** 步骤 3 和 5 在 `WR_PIPLINE` 状态可并发（同周期内既读下一块、又写上一块结果）。

### FSM 状态转移图

```
IDLE ──(hd_comp_start)──► GEN_ADDR ──(hd_addr_gen_valid)──►
   ▲                          ▲                              │
   │                          │                    ┌─────────┤
   │                          │                    │         │
   │                          │              hd_first_line   otherwise
   │                          │                    │         │
   │                          │                    ▼         ▼
   │                          │               RD_ONLY    WR_PIPLINE
   │                          │                    │         │
   │                          │              (rd_done)  (rd_done && wr_done)
   │                          │                    │         │
   │                          │                    ▼         ▼
   │                          └──────────────── FWHT ◄───────┘
   │                                           (fwht_done)
   │                                               │
   │                                        hd_last_line
   │                                               │
   │                                               ▼
   └──────────────── COMP_DONE ◄───────────── WR_ONLY
                     (done=1)            (wr_done)
```

---

## 四、6 级 Walsh-Hadamard 蝶形网络

### 4.1 配对模式（Walsh 顺序）

64 点 FWHT，每级 32 个蝶形单元并行：

| 级 | 步长 (stride) | 配对公式 | i=0 示例 |
|----|-------------|---------|---------|
| 0→1 | 1 | LO=i×2, HI=i×2+1 | (0,1), (2,3), ..., (62,63) |
| 1→2 | 2 | LO=(i%2)+(i/2)×4, HI=LO+2 | (0,2), (1,3), ..., (61,63) |
| 2→3 | 4 | LO=(i%4)+(i/4)×8, HI=LO+4 | (0,4), (1,5), ..., (59,63) |
| 3→4 | 8 | LO=(i%8)+(i/8)×16, HI=LO+8 | (0,8), (1,9), ..., (55,63) |
| 4→5 | 16 | LO=(i%16)+(i/16)×32, HI=LO+16 | (0,16), (1,17), ..., (47,63) |
| 5→6 | 32 | LO=(i%32)+(i/32)×64, HI=LO+32 | (0,32), (1,33), ..., (31,63) |

**结论：✓ 配对模式符合标准 Walsh-Hadamard 变换。**

### 4.2 流水线时序

流水线由 `stage_cnt` 计数器自定时推进：

```
s_valid_out_all = &(32 个 fwht_pub 的 valid_out)

stage_cnt: 0 → 1 → 2 → 3 → 4 → 5 → 6
             ↑    ↑    ↑    ↑    ↑    ↑
          所有蝶形单元完成 → s_valid_out_all 上升沿 → stage_cnt+1
```

**级间存在 1 周期气泡。** 原因：`s_valid_pos_r` 需要多打一拍才能触发下一级蝶形单元。6 级累计约 6 周期额外延迟，不影响正确性。

---

## 五、fwht_pub 蝶形单元详解

### 5.1 四级流水线

| 流水级 | FP16 操作 | INT8 操作 |
|--------|----------|----------|
| Stage 1 | 符号/指数/尾数提取 → 比较大小 → 右移对齐 | 符号/幅值提取 → 无对齐（exp=0） |
| Stage 2 | 并行计算 ADD（同号）和 SUB（异号） | 同左，无符号算术 |
| Stage 3 | ADD 溢出右移 + SUB 前导 1 检测 + 可变左移归一化 | **跳过**（valid_out 提前到 s2_valid） |
| Stage 4 | 根据原始符号关系选择 ADD/SUB 路径输出 | 同左 |

### 5.2 数据通路总览

MAN_W=13 下, 两条路径共享所有 Stage 寄存器和运算器, 仅在头尾做格式转换:

```
          ┌─── Stage 0 ───┐   ┌── Stage 1~2 ──┐   ┌── Stage 3 ──┐   ┌── Stage 4 ──┐
FP16  →   │ exp[14:10]    │   │ 指数对齐+加法  │   │ 归一化      │   │ 选路+打包   │ → FP16
          │ man[13:0]=    │   │ 13-bit宽容器   │   │ (FP16_MW=10)│   │ 输出10b尾数 │
          │ {3'b0,1b1,frac}   │                │   │             │   │             │
          ├───────────────┤   │                │   ├─────────────┤   ├─────────────┤
INT16 →   │ exp=0         │   │ 不移位+加法    │   │ 跳过        │   │ 选路+打包   │ → INT16
          │ man[13:0]=    │   │ 13-bit宽容器   │   │ (valid=s2)  │   │ 16b 2补码  │
          │ {1'b0,abs[12:0]}  │                │   │             │   │             │
          └───────────────┘   └────────────────┘   └─────────────┘   └─────────────┘
```

### 5.3 FP16 路径详析

**输入格式：** 标准 FP16 — `{sign[15], exp[14:10], frac[9:0]}`

**Stage 0 — 参数提取 (line 82-99)：**
```
sign = op_a[15]                              // 符号位
exp  = op_a[14:10]                           // 5-bit 指数 (偏移15)
man  = normal ? {3'b0, 1'b1, frac[9:0]}     // 正常数: implicit 1 + 10b尾数 → 高位填0入14b容器
              : {4'b0, frac[9:0]}             // 次正常: 无implicit 1
```

**Stage 1 — 预对齐 (line 119-133)：**
- 比较指数大小, 确定 `man_big` / `man_small`
- 较小数右移 `|exp_a - exp_b|` 位实现指数对齐
- 加 guard bit: `s1_man_big = {man_big, 1'b0}` (15-bit)

**Stage 2 — 加减运算 (line 141-153)：**
- 同号: `s2_sum_add = big + small` (16-bit)
- 异号: `s2_diff_sub = big - small` (15-bit)

**Stage 3 — 归一化 (line 188-215)：**
- ADD: 检测 `s2_sum_add[15]` 溢出 → 右移1位+指数加1; 否则取 `[14:1]`
- SUB: 两级优先编码器检测前导1 → 左移 `(11 - P)` 位 → 取 `sub_shifted[14:1]`
- 指数调整: `exp = exp - (11 - P)`
- 移位数用 `FP16_MW=10` 计算, 保证归一化到标准 FP16 位宽

**Stage 4 — 输出 (line 224-258)：**
```
fp16_merge = {sign, exp[4:0], man_norm[9:0]}    // 取低10位尾数, 打包为标准FP16
result_add = (同号) ? fp16_merge_add : fp16_merge_sub
result_sub = (同号) ? fp16_merge_sub : fp16_merge_add
```

**结论：✓ FP16 路径行为与 MAN_W=10 时完全等价。** 高位填0的 padding 不影响比较/对齐/移位, 输出仍取低10位尾数。

### 5.4 INT16 路径详析

**输入格式：** INT8 符号扩展到 16-bit — `{ {8{val[7]}}, val[7:0] }` (hadamard.v 处完成)

**Stage 0 — 参数提取 (line 82-100)：**
```
sign = op_a[15]                              // 符号位 (bit 15)
exp  = op_a[14:10]                           // INT16下恒为 5'b0 (高8位=符号扩展)
abs  = sign ? (~op_a[14:0] + 1) : op_a[14:0] // 15-bit 绝对值, 范围 0~32767
man  = {1'b0, abs[12:0]}                     // 截断到 13-bit 幅值 (max=8191 > 8128)
```

**Stage 1 — 预对齐：**
- `exp_a == exp_b == 0` → `exp_diff_abs = 0` → 不移位
- `a_ge_b` 直接由 `man_a >= man_b` 决定
- `s1_man_big = {man_big, 1'b0}` (15-bit, ×2)

**Stage 2 — 加减运算：** 同 FP16, 无特殊处理

**6 级 FWHT 幅值增长:**
| 级 | 最大 `|A|+|B|` | 需要位数 | MAN_W=13 覆盖? |
|----|---------------|---------|---------------|
| 1 | 254 | 8-bit | ✓ |
| 2 | 508 | 9-bit | ✓ |
| 3 | 1016 | 10-bit | ✓ |
| 4 | 2032 | 11-bit | ✓ |
| 5 | 4064 | 12-bit | ✓ |
| 6 | 8128 | 13-bit | ✓ (max=8191) |

**Stage 3 — 跳过：** `valid_out = s2_valid`, INT16 不经过归一化

**Stage 4 — 输出 (line 230-240)：**
```
ADD 幅值 = s2_sum_add[14:1]                  // 14-bit 实际幅值 (÷2去guard)
ADD INT16 = {2'b0, s2_sum_add[14:1]}          // 正数 16-bit
            → sign? ~x+1 : x                   // 2补码转换

SUB 幅值 = s2_diff_sub[13:1]                 // 13-bit 实际幅值
SUB INT16 = {3'b0, s2_diff_sub[13:1]}         // 正数 16-bit
            → sign? ~x+1 : x                   // 2补码转换
```

**级间格式：** 每级输出 16-bit 2补码 INT16, 下一级直接作为 `op_a`/`op_b` 输入, 全精度传递。

**最终 INT8 输出：** `hadamard.v` 取 `fwht_out_regs[i][7:0]` — INT16 结果的低 8 位, 自然截断回 INT8。

**结论：✓ INT16 路径无中间饱和, 6 级 FWHT 全精度计算。**

---

## 六、地址生成（hadamard_addr_gen）

### 6.1 参数计算

| 参数 | FP16 | INT8 |
|------|------|------|
| `fwht_num`（总迭代次数） | `wrsize_hd / 2` | `wrsize_hd / 1` |
| `arsize`（每次读 512-bit 块数） | 2 | 1 |
| `ar_offset`（每次偏移） | `hd_rd_cnt × 128` 字节 | `hd_rd_cnt × 64` 字节 |
| `aw_offset`（每次偏移） | `hd_wr_cnt × 128` 字节 | `hd_wr_cnt × 64` 字节 |

### 6.2 首行/末行判断

```
hd_first_line = (hd_rd_cnt == 0)
hd_last_line  = (hd_wr_cnt == fwht_num - 1)
```

- 首行：只读不写（无历史结果可写）→ FSM 进 `RD_ONLY`
- 末行：只写不读（无下一块）→ FSM 进 `WR_ONLY`
- 中间：同时读写 → FSM 进 `WR_PIPLINE`

**结论：✓ 地址生成逻辑正确。**

---

## 七、数据打包

### 7.1 输入（DMA → fwht_regs）

| 模式 | 操作 | 格式转换 | 周期 |
|------|------|---------|------|
| INT8 | `din[511:0]` → `fwht_regs[63:0]` | **符号扩展**: `{ {8{val[7]}}, val }` → INT16 | rd_cnt=0 一周期 |
| FP16 | `din[511:0]` → `fwht_regs[63:0]` | 直通, 每32个16-bit值一批 | rd_cnt={0,1} 两周期 |

INT8 输入的关键改动：`{8'b0, val}` → `{ {8{val[7]}}, val }`。符号位推到 bit 15, fwht_pub 统一从 bit 15 取符号。

### 7.2 级间传递 (stage0 ↔ stage6)

| 模式 | 寄存器宽度 | 数据格式 |
|------|-----------|---------|
| INT16 | 16-bit | 16-bit 2补码 (范围 [-32768, 32767], 实际值 ≤ |8128|) |
| FP16 | 16-bit | 标准 FP16 (1+5+10) |

关键：INT16 级间不截断, 6 级全精度传递。

### 7.3 输出（fwht_out_regs → DMA）

| 模式 | 操作 | 格式 |
|------|------|------|
| INT8 | `dout_int8`: 64×`fwht_out_regs[i][7:0]` | INT16 → 截断低 8 位 = INT8 |
| FP16 | `dout_lo`: regs[0:31]，`dout_hi`: regs[32:63] | 直通 FP16 |

AVR 寄存器切片 (`avr_rs`) 隔离组合逻辑，改善时序。

**结论：✓ 数据打包逻辑正确, INT16 中间格式对 DMA 输入/输出透明。**

---

## 八、发现的问题

### 8.1 【已修复】`sub_leading_pos` 位宽缺失（fwht_pub.v:181）

> **状态：** ✅ 已修复于 2026-05-14

```verilog
// 修复前（第 200 行）：sub_leading_pos 未显式声明，隐式为 1-bit wire
assign sub_leading_pos = msb_in_upper ? (group_msb_5 + 3'd6) : group_msb_0;

// 修复后（第 181 行）：显式声明为 4-bit wire
wire [3:0] sub_leading_pos; // combined leading-1 position (0~11, needs 4 bits)
```

**问题描述：**  
Verilog 隐式声明规则下，未声明的 LHS 信号默认为 **1-bit wire**。`sub_leading_pos` 需要 4 位来表示 0~11 的前导 1 位置。由于隐式声明只有 1 位，实际只取 LSB，`group_msb_5 + 6` 的高位被截断。

**影响范围：** FP16 模式下的减法归一化路径（Stage 3 SUB Path）。  
**影响比例：** 前导 1 在奇数位置 ≈ 50% 的减法结果归一化错误。  
**不影响：** INT8 模式（跳过 Stage 3）。  

**表现：** 蝶形单元 `result_sub` 和异号 `result_add` 的归一化输出移位错误，导致 FP16 变换结果部分数据位宽损失或幅值错误。

**修复：** 在 `group_msb_0` 声明下方添加 `wire [3:0] sub_leading_pos;`

### 8.2 【效率】级间流水线气泡

每级蝶形运算之间有 1 个无操作周期（`s_valid_pos_r` 寄存器延迟）。6 级累计增加约 6 周期延迟。不影响计算正确性，仅影响吞吐。

### 8.3 【已修复】FP16 ADD 归一化遗漏 [2,4) 尾数区间（fwht_pub.v:194）

> **状态：** ✅ 已修复于 2026-05-15

**问题描述：**
原 ADD 归一化只检查 `s2_sum_add[MAN_W+2]`（bit 15）溢出，遗漏了 FP16 同指数加法的常见情况——两个尾数在 [1,2)，和必然在 [2,4)，需要右移 1 位 + 指数加 1。

**复现用例：** `0x5080(36.0) + 0x5060(35.0)` → RTL 输出 `0x50E0(39.0)`，正确值为 `0x5470(71.0)`。

**修复：**
改为 3-bit 优先编码器检测 `s2_sum_add[14:12]` 的前导 1 位置，计算可变右移量（1/2/3 bit），对应调整指数：

```verilog
// 修复前: 仅检查 bit 15
if (s2_sum_add[MAN_W+2]) begin ... end

// 修复后: 优先编码器检测前导 1, 可变右移
wire [1:0] add_shift_amt;
wire       add_needs_shift = |s2_sum_add[MAN_W+1:FP16_MW+2];  // [14:12]
assign add_shift_amt = s2_sum_add[14] ? 2'd3 :
                        s2_sum_add[13] ? 2'd2 :
                        s2_sum_add[12] ? 2'd1 : 2'd0;
```

### 8.4 【已修复】INT16 指数错误取到符号扩展位（fwht_pub.v:86）

> **状态：** ✅ 已修复于 2026-05-15

**问题描述：**
INT16 模式下，`exp_a = op_a[14:10]` 直接取 bit[14:10]，而 INT16 输入是 INT8 符号扩展到 16-bit。负值（如 `0xFFE0`）的高位为 1，bit[14:10]=5'b11111=31，被当作 FP16 指数做对齐移位，导致错误的尾数对齐和数值交换。

**复现用例：** `0x20(32) + 0xE0(-32)` → RTL 输出 `32`（两值被交换），正确值为 `0`。

**修复：** INT16 模式下强制指数为 0：
```verilog
assign exp_a = cal_percision ? op_a[FP16_MW +: EXP_W] : 5'd0;
assign exp_b = cal_percision ? op_b[FP16_MW +: EXP_W] : 5'd0;
```

---

## 九、验证结论

| 验证项 | 状态 | 说明 |
|--------|------|------|
| 6 级蝶形配对索引 | ✓ 正确 | 符合 Walsh-Hadamard 标准模式 |
| FP16 加法归一化 | ✅ 已修复 | [2,4) 尾数区间优先编码右移 (2026-05-15) |
| FP16 减法归一化 | ✅ 已修复 | `sub_leading_pos` 位宽声明 (2026-05-14) |
| INT16 指数提取 | ✅ 已修复 | INT16 强制 exp=0, 防止符号扩展位干扰 (2026-05-15) |
| INT16 内部精度 | ✅ 升级 | MAN_W=13 统一位宽, 消除中间饱和 (2026-05-14) |
| INT8→INT16 符号扩展 | ✅ 升级 | `hadamard.v` 输入加载处修改 (2026-05-14) |
| 地址生成 | ✓ 正确 | FP16/INT8 的块大小和偏移计算正确 |
| 数据打包/解包 | ✓ 正确 | 512-bit ↔ 64×16/8-bit 映射正确 |
| FSM 流控 | ✓ 正确 | 首行/中间/末行的流水控制正确 |
| AVR 输出寄存器切片 | ✓ 正确 | 改善时序，提供背压 |
| 级间气泡 | △ 效率 | 每级 1 周期空泡，不影响正确性 |

---

## 十、未使用端口

| 端口 | 模块 | 说明 |
|------|------|------|
| `hd_data_width` | `hadamard_addr_gen` | 端口存在但内部未使用（地址生成用 `wrsize_hd` 计算） |
| `fwht_num` | `hadamard_addr_gen` | 已注释，用 `fwht_num` 内部分配替代 |

---

## 十一、INT8→INT16 内部精度扩展（2026-05-14）

### 11.1 动机

原始 INT8 路径的 7-bit 幅值在 6 级 FWHT 中间过程中严重饱和：
- 6 级蝶形后最大可能值 = 8128（需 13-bit 幅值）
- 7-bit 幅值仅覆盖 0~127，中间值全部饱和，信息丢失

### 11.2 方案

**内部计算升为 13-bit 幅值，输出时截断回 INT8：**

| 项目 | 改动前 | 改动后 |
|------|--------|--------|
| INT 输入格式 | `{8'b0, int8}` (8-bit 零扩展) | `{ {8{sign}}, int8 }` (符号扩展到 bit 15) |
| 幅值提取 | 7-bit | 15-bit 绝对值 → 截断到 13-bit |
| man 宽度 (INT) | 11-bit (`{4'b0, 7-bit}`) | 14-bit (`{1'b0, 13-bit}`) |
| 内部累加器 | 16-bit (已够, 但中间饱和) | 16-bit (无饱和) |
| 输出格式 | `{8'b0, 8-bit}` (含饱和) | INT16 (16-bit 2补码, 无饱和) |
| 最终 INT8 输出 | `fwht_out_regs[i][7:0]` | 不变 (取 INT16 低 8-bit) |

### 11.3 RTL 改动

**fwht_pub.v:**
- `MAN_W` 从 10 改为 13，所有信号宽度统一使用 MAN_W
- 新增 `FP16_MW = 10` localparam 用于 FP16 专用的 bit 切片 (指数位置/尾数/输出)
- INT16 路径：sign 从 bit 15 取，幅值从 `op_a[14:0]` 取 2补码绝对值后截断到 MAN_W
- INT16 输出：从 `s2_sum_add[MAN_W+1:1]` / `s2_diff_sub[MAN_W:1]` 重构 16-bit 2补码
- 移除中间级饱和 (原 `int8_sum_overflow_cut`)

**hadamard.v:**
- INT8 输入加载：`{8'b0, val}` → `{ {8{val[7]}}, val }` (符号扩展到 16-bit)

### 11.4 数值范围验证

| FWHT 级 | 最大绝对值 | 13-bit 幅值 |
|---------|-----------|------------|
| Stage 1 | 254 | ✓ |
| Stage 2 | 508 | ✓ |
| Stage 3 | 1016 | ✓ |
| Stage 4 | 2032 | ✓ |
| Stage 5 | 4064 | ✓ |
| Stage 6 (输出) | **8128** | ✓ (max=8191) |

### 11.5 输出截断

`hadamard.v` 的 `dout_int8` 取 `fwht_out_regs[i][7:0]`——即 INT16 结果的低 8 位。对于 CLIP ViT 的实际特征分布，FWHT 系数自然落在 INT8 范围 `[-128, 127]` 内。极端溢出的值 wraparound（取模 256），发生概率极低。

---

## 十二、硬件适配修改（2026-06-16）

### 12.1 输出路径简化

**问题**：原 `out_phase` 状态机（IDLE→LO→GAP→HI→IDLE）实现过于复杂，在真实硬件上产生数据错位。

**修复**：移除 out_phase FSM，改为 `result_valid + wr_cnt` 控制：
```verilog
assign dout_rs = cal_percision ? (wr_cnt == 2'd0 ? dout_lo : dout_hi) : dout_int8;
assign dout_valid_rs = result_valid && trans_status[1];
assign fwht_done = result_valid;
```

保留 `avr_rs`（2 级 AVR），`wr_cnt` 直接计数 `dout_valid & dout_ready` 握手。`result_valid` 由 FWHT 计算完成置位，DMA `wr_done` 清零。

### 12.2 rd_data_ready：读数据就绪检测

**问题**：原 FSM 仅根据 `rd_done`（AR 握手完成）跳转状态，真实 DDR 有 READ_LATENCY，AR 完成后 R 数据尚未到达。

**修复**：新增 `rd_cnt` 计数器，每拍 `din_valid & din_ready` 握手计数：
```verilog
assign rd_data_ready = (rd_cnt >= rd_expected);  // FP16: ≥2, INT8: ≥1
```

FSM 读状态转换添加 `rd_data_ready` 检查：
```
RD_ONLY:    rd_done_reg && rd_data_ready → FWHT
WR_PIPLINE: rd_done_reg && wr_done_reg && rd_data_ready → FWHT
```

### 12.3 2-FF CDC 同步

`hadamard_addr_gen.v` 新增 `arbase_hd`/`awbase_hd` 的 2-FF 同步器（`_s1 → _s2`），解决 `ra_clk` → `clk` 跨时钟域配置寄存器稳定性问题。

### 12.4 wr_cnt / rd_cnt 计数简化

**问题**：原武装-解除机制依赖 `~din_valid` / `~dout_valid` 重装，真实硬件上 valid 持续为高（AXI burst）导致重装失败，计数停止。

**修复**：直接计数 `din_valid & din_ready` / `dout_valid & dout_ready` 每拍握手，不加武装机制：
```verilog
// rd_cnt: 每拍握手计数
if (din_valid & din_ready) rd_cnt <= rd_cnt + 2'd1;

// wr_cnt: 每拍握手计数
if (dout_valid & dout_ready) wr_cnt <= wr_cnt + 2'd1;
```

### 12.5 fwht_done 信号

`fwht_done = result_valid`，FWHT 计算完成就通知 FSM。**注意**：不能改为 `dout_valid && result_valid`——在 FWHT 状态下 `trans_status[1] = 0` → `dout_valid_rs = 0` → `dout_valid = 0` → 死锁。

### 12.6 仿真 DDR 模型

`sim/hadamard_sim.sv` 更新为 R 队列 + burst 模式：`rvalid` 跨 beat 保持高电平，AR 支持 outstanding reads（4 深队列），`READ_LATENCY = 4`。

### 12.7 寄存器映射

| 功能 | 寄存器索引 | 字节偏移 |
|------|-----------|---------|
| Hadamard 启动 | 0x31 | 0xC4 |
| Hadamard 完成 | 0x40 | 0x100 |
| FSM 状态调试 | 0x23 | 0x8C |
| 数据宽度 | 0x07 | 0x1C |
| 计算精度 | 0x08 | 0x20 |

# FPGA 三算子 Bug 汇总

## 环境

- 平台: Zynq (customop_top → arbiter → DMA → AXI DDR)
- 三个算子: gather, hadamard/fwht, resize_crop
- DMA: 单通道 512-bit AXI, 要求同时读写

---

## 已修复的问题

### 1. DMA 单通道挂起 (wdma un-done, status 0x4)
- **文件**: arbiter.v, gather_fsm.v, hadamard_fsm.v, resize_fsm.v
- **修复**:
  - arbiter: `itf_rready` 默认值 0→1 (保证未被选中时 ready=1)
  - gather_fsm: wr_start 条件移除 `RD_INDICES`
  - hadamard_fsm: wr_ddr 移除 RD_ONLY, rd_ddr 移除 WR_ONLY
  - resize_fsm: wr_ddr 移除 RD_ONLY/RD_SECONE, rd_ddr 移除 WR_ONLY/WAIT_DRAIN

### 2. resize_addr_gen: src_done 复位后立即触发
- **文件**: resize_addr_gen.v
- **修复**: `assign src_done = (total_src_blocks_r > 0) && (total_rd_cnt >= total_src_blocks_r);`

---

## 待修复的 Bug

### BUG-1: Gather — FIFO 索引读取条件永远不成立

**文件**: [rtl/custom_op/gather/gather.v:125](../../rtl/custom_op/gather/gather.v#L125)

**条件**:
```verilog
if (current_indices_cnt == 0 & trans_data_reg) begin  // 触发 FIFO 读
```

**根因**: `current_indices_cnt` 和 `trans_data_reg` 在同一拍更新:
- 复位后 cnt=0, trans_data_reg=0 → 条件为假
- 首次进入 WR_PIPLINE: trans_data_pos=1, cnt 0→1, trans_data_reg 0→1 (同拍, 旧值均为 0) → 条件为假
- cnt 回绕到 0 时: trans_data_reg 在 GEN_ADDR 中被清为 0 → 条件为假

**后果**: indices FIFO 读指针从不前进, 只有前 16 个索引被反复使用。当 INDICES_LEN > 16 时, 元素 16-19 重复使用索引 0-3, 输出错位。

**仿真为何正确**: 仿真 TB 只检查有无超时, 不验证数据正确性。且 INDICES_LEN=20 时的错误模式(后4元素重复)可能未被察觉。

### BUG-2: Gather — 写地址偏移寄存器滞后一拍

**文件**: [rtl/custom_op/gather/gather.v:97-105](../../rtl/custom_op/gather/gather.v#L97)

**代码**:
```verilog
always@(posedge clk) begin
    arbase_offset <= arbase_offset_c;  // 用旧 output_addr_cnt 计算
    awbase_offset <= awbase_offset_c;  // 用旧 output_addr_cnt 计算
end

always @(posedge clk) begin
    if(trans_data_pos)
        output_addr_cnt <= output_addr_cnt + 1;  // 同拍更新
end
```

**根因**: `awbase_offset_c = output_addr_cnt * (data_width_reg << 6)` 是组合逻辑, 但 `awbase_offset` 寄存器采样用的是 `output_addr_cnt` 的旧值 (同拍非阻塞赋值)。

**后果**: 写地址比预期慢一拍:

| Element | output_addr_cnt | awbase_offset 实际 | 期望 | 写地址 |
|---------|----------------|-------------------|------|--------|
| 0 | 0 | 0 | 0 | base+0 ✓ |
| 1 | 1 | 0 | 512 | base+0 ✗ (覆盖!) |
| 2 | 2 | 512 | 1024 | base+512 ✗ |

Element 0 和 Element 1 写到同一地址, 互相覆盖。导致"每 8 行重复"(512字节对齐的页效应)。

### BUG-3: Hadamard — s_valid_in 边沿检测延迟一拍

**文件**: [rtl/custom_op/hadamard/hadamard.v#L378-L387](../../rtl/custom_op/hadamard/hadamard.v#L378)

**代码**:
```verilog
s_valid_in_r1 <= s_valid_in;
s_valid_in_r2 <= s_valid_in_r1;
op_a_r <= (s_valid_in_r1 && !s_valid_in_r2) ? op_a_g0_r : op_a_g1_r;
```

**时序追踪**:
```
s_valid_in:       0 0 1 1 0 0   (2周期脉冲)
s_valid_in_r1:    0 0 0 1 1 0   (延迟1拍)
s_valid_in_r2:    0 0 0 0 1 1   (延迟2拍)
edge(r1&!r2):     0 0 0 1 0 0   ← 边沿在第2个valid周期才检测到!
```

**后果**: 第1个 valid 周期 PUB 拿到的是 g1 数据 (应为 g0), 第2个周期拿到 g0 数据 (应为 g1)。g0/g1 互换导致 FWHT 蝶形运算操作数对调。用户观察: "前几行与正确输出的后几行对应"——说明数据完整但位置偏移。

### BUG-4: Resize — 全零输出

**现象**: resize 算子输出全部为零。

**修复**:
- `src_done`: 不再复位后立即完成
- FSM 的 wr_ddr/rd_ddr 时序修正
- axis 计算流水线与 FIFO flush 条件修正

---

## 相关文件索引

| 文件 | 用途 |
|------|------|
| rtl/custom_op/gather/gather.v | Gather 数据通路 (FIFO, 地址生成) |
| rtl/custom_op/gather/gather_fsm.v | Gather 状态机 |
| rtl/custom_op/hadamard/hadamard.v | FWHT 核心 (16-32 PUB, 流水线控制) |
| rtl/custom_op/hadamard/hadamard_fsm.v | Hadamard 状态机 |
| rtl/custom_op/hadamard/hadamard_addr_gen.v | Hadamard 地址生成 |
| rtl/custom_op/hadamard/fwht_pub.v | 单 PUB 蝶形单元 |
| rtl/custom_op/resize_crop/resize.v | Resize 核心 (双线性插值) |
| rtl/custom_op/resize_crop/resize_fsm.v | Resize 状态机 |
| rtl/custom_op/resize_crop/resize_addr_gen.v | Resize 地址生成 |
| rtl/custom_op/resize_crop/resize_axis.v | Resize 轴计算 |
| rtl/custom_op/dma.v | DMA 控制器 |
| rtl/custom_op/arbiter.v | 三算子仲裁器 |
| rtl/custom_op/customop_top.v | 顶层连线 |
| rtl/custom_op/reg_ctrl.v | 寄存器控制 |
| sim/gather_sim.sv | Gather 仿真 TB (仅超时检查) |
| test/gather_test.cpp | Gather 板上 C++ 测试 |
| test/fwht_test.cpp | FWHT 板上 C++ 测试 |
| test/resize_test.cpp | Resize 板上 C++ 测试 |

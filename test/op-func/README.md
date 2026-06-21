# 自定义算子函数库

封装 FWHT、Gather、Resize 的 FPGA 寄存器配置与执行等待，供其他 C++ 程序直接调用。

数据已在 PL-DDR 中，函数**不负责 DMA 读写**——调用方自行管理内存。

## 文件

| 文件 | 功能 |
|------|------|
| `op_fwht.h/cpp`   | FWHT/Hadamard 变换：配置寄存器 → 启动 → 轮询完成 |
| `op_gather.h/cpp` | Gather 索引重排：配置寄存器 → 启动 → 轮询完成 |
| `op_resize.h/cpp` | Resize/Crop 双线性插值：配置寄存器 → 启动 → 轮询完成 |
| `README.md`       | 本文档 |

## 依赖

- `compile_fpai_target.hpp` (fpai SDK)
- `<chrono>`, `<thread>`, `<iostream>` (标准库)
- C++17

## 编译

将 `op-func/*.cpp` 加入 CMakeLists.txt：

```cmake
file(GLOB OP_FUNC_SRC "test/op-func/*.cpp")
add_executable(my_app my_app.cpp ${OP_FUNC_SRC})
```

## FWHT 示例

```cpp
#include "op-func/op_fwht.h"

int main() {
    auto device     = Device::Open("axi://zg330aiu?...");
    auto fpai_dev   = device.cast<FPAIDevice>();
    uint32_t reg_base = 0x400C0000;

    // 假设数据已通过 DMA 写入 PL-DDR, 物理地址如下:
    FwhtConfig cfg { .src_addr = 0x80001000, .dst_addr = 0x80002000,
                     .total_blocks = 8, .cal_percision = 1 };

    if (!op_fwht_run(fpai_dev.get(), reg_base, cfg))
        return -1;

    // 从 dst_addr 读回结果...
    return 0;
}
```

## Gather 示例

```cpp
#include "op-func/op_gather.h"

GatherConfig cfg { .idx_addr = 0x80001000, .src_addr = 0x80002000, .dst_addr = 0x80010000,
                   .indices_len = 20, .data_width_beats = 8, .indices_beats = 2 };

if (!op_gather_run(fpai_dev.get(), reg_base, cfg))
    return -1;
```

## Resize 示例

```cpp
#include "op-func/op_resize.h"

ResizeConfig cfg { .src_addr = 0x80001000, .dst_addr = 0x80010000,
                   .src_w = 64, .src_h = 48, .dst_w = 32, .dst_h = 32,
                   .crop_enable = 1 };

if (!op_resize_run(fpai_dev.get(), reg_base, cfg, 30000))  // 30s 超时
    return -1;
```

## API 签名

```cpp
bool op_fwht_run  (fpai::FPAIDevice* dev, uint32_t reg_base, const FwhtConfig&   cfg, int timeout_ms = 5000);
bool op_gather_run(fpai::FPAIDevice* dev, uint32_t reg_base, const GatherConfig& cfg, int timeout_ms = 5000);
bool op_resize_run(fpai::FPAIDevice* dev, uint32_t reg_base, const ResizeConfig& cfg, int timeout_ms = 30000);
```

- `dev`: `Device::Open().cast<FPAIDevice>()` 返回的指针
- `reg_base`: 寄存器基址, 通常 `0x400C0000`
- 返回 `true` 表示执行完成, `false` 表示超时

## 寄存器地址参考

| 算子 | 启动 | 完成 | 其他配置 |
|------|------|------|---------|
| FWHT | `+0xC4` (0x31) | `+0x100` (0x40) | `+0x1C` data_width, `+0x20` precision, `+0xC8` rbase, `+0xCC` wbase, `+0xD0` wrsize |
| Gather | `+0x00` | `+0x80` (0x20) | `+0x14` idx_len, `+0x18` data_width, `+0x04` idx_base, `+0x0C` src_base, `+0x08` dst_base |
| Resize | `+0x104` (0x41) | `+0x140` (0x50) | `+0x110` rsize, `+0x114` wsize, `+0x108` rbase, `+0x10C` wbase, `+0x24`/`+0x28` ratio, `+0x2C` crop |

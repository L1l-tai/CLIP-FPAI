#pragma once

#include <cstdint>
#include "compile_fpai_target.hpp"

struct ResizeConfig {
    uint32_t src_addr;    // PL-DDR 源图像物理地址
    uint32_t dst_addr;    // PL-DDR 目标物理地址
    int      src_w;
    int      src_h;
    int      dst_w;
    int      dst_h;
    int      crop_enable = 1;
};

// 配置寄存器 → 启动 → 轮询完成, 超时返回 false; cycle_cnt 输出周期数 (可为nullptr)
bool op_resize_run(fpai::FPAIDevice* dev, uint32_t reg_base, const ResizeConfig& cfg,
                   int timeout_ms = 30000, uint32_t* cycle_cnt = nullptr);

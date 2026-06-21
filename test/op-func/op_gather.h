#pragma once

#include <cstdint>

namespace fpai { class FPAIDevice; }

struct GatherConfig {
    uint32_t idx_addr;       // PL-DDR 索引区物理地址
    uint32_t src_addr;       // PL-DDR 源数据物理地址
    uint32_t dst_addr;       // PL-DDR 目标物理地址
    int      indices_len;    // 索引数量
    int      data_width_beats; // 每元素 DMA beat 数
    int      indices_beats;  // 索引区 beat 数
};

// 配置寄存器 → 启动 → 轮询完成, 超时返回 false
bool op_gather_run(fpai::FPAIDevice* dev, uint32_t reg_base, const GatherConfig& cfg,
                   int timeout_ms = 5000);

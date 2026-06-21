#pragma once

#include <cstdint>

namespace fpai { class FPAIDevice; }

struct FwhtConfig {
    uint32_t src_addr;       // PL-DDR 源数据物理地址
    uint32_t dst_addr;       // PL-DDR 目标物理地址
    int      total_blocks;   // wrsize_hd
    int      cal_percision;  // 0=INT8, 1=FP16
    int      hd_data_width = 2;
};

// 配置寄存器 → 启动 → 轮询完成, 超时返回 false
bool op_fwht_run(fpai::FPAIDevice* dev, uint32_t reg_base, const FwhtConfig& cfg,
                 int timeout_ms = 5000);

#pragma once

#include <cstdint>
#include "compile_fpai_target.hpp"

struct FwhtConfig {
    uint32_t src_addr;
    uint32_t dst_addr;
    int      total_blocks;
    int      cal_percision;  // 0=INT8, 1=FP16
    int      hd_data_width = 2;
};

bool op_fwht_run(fpai::FPAIDevice* dev, uint32_t reg_base, const FwhtConfig& cfg,
                 int timeout_ms = 5000, uint32_t* cycle_cnt = nullptr);

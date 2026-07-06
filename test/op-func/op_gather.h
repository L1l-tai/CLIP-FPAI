#pragma once

#include <cstdint>
#include "compile_fpai_target.hpp"

struct GatherConfig {
    uint32_t idx_addr;
    uint32_t src_addr;
    uint32_t dst_addr;
    int      indices_len;
    int      data_width_beats;
    int      indices_beats;
};

bool op_gather_run(fpai::FPAIDevice* dev, uint32_t reg_base, const GatherConfig& cfg,
                   int timeout_ms = 5000, uint32_t* cycle_cnt = nullptr);

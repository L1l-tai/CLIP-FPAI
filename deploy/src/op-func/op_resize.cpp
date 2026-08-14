#include "op_resize.h"

#include "compile_fpai_target.hpp"
#include <iostream>
#include <chrono>
#include <thread>
#include <algorithm>

using namespace fpai;

static inline uint32_t calc_ratio_less(int dst, int crop) {
    return ((uint32_t)dst << 12) / crop;
}
static inline uint32_t calc_ratio_greater(int crop, int dst) {
    return ((uint32_t)crop << 8) / dst;
}

bool op_resize_run(FPAIDevice* dev, uint32_t reg_base, const ResizeConfig& cfg,
                   int timeout_ms, uint32_t* cycle_cnt)
{
    auto& reg = dev->defaultRegRegion();

    // 复位
    reg.write(reg_base + 0x1DC, 1, false);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    reg.write(reg_base + 0x1DC, 0, false);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    int crop_size = std::min(cfg.src_w, cfg.src_h);
    uint32_t ratio_less    = calc_ratio_less(cfg.dst_w, crop_size);
    uint32_t ratio_greater = calc_ratio_greater(crop_size, cfg.dst_w);

    reg.write(reg_base + 0x110, (cfg.src_w << 16) | cfg.src_h, false);
    reg.write(reg_base + 0x114, (cfg.dst_w << 16) | cfg.dst_h, false);
    reg.write(reg_base + 0x108, cfg.src_addr, false);
    reg.write(reg_base + 0x10C, cfg.dst_addr, false);
    reg.write(reg_base + 0x24,  ratio_less, false);
    reg.write(reg_base + 0x28,  ratio_greater, false);
    reg.write(reg_base + 0x2C,  (uint32_t)cfg.crop_enable, false);

    reg.write(reg_base + 0x104, 1, false);

    auto start = std::chrono::system_clock::now();
    while (true) {
        if (reg.read(reg_base + 0x140, false)) break;
        auto now = std::chrono::system_clock::now();
        int  ms  = (int)std::chrono::duration_cast<std::chrono::milliseconds>(now - start).count();
        if (ms > timeout_ms) {
            std::cerr << "Resize: timeout after " << ms << "ms" << std::endl;
            return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    if (cycle_cnt) *cycle_cnt = reg.read(reg_base + 0x8C, false);
    return true;
}

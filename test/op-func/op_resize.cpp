#include "op_resize.h"

#include "compile_fpai_target.hpp"
#include <iostream>
#include <chrono>
#include <thread>
#include <algorithm>

using namespace fpai;

static inline uint16_t calc_ratio_less(int dst, int crop) {
    return (uint16_t)(((uint32_t)dst << 12) / crop);
}
static inline uint16_t calc_ratio_greater(int crop, int dst) {
    return (uint16_t)(((uint32_t)crop << 8) / dst);
}

bool op_resize_run(FPAIDevice* dev, uint32_t reg_base, const ResizeConfig& cfg, int timeout_ms)
{
    auto& reg = dev->defaultRegRegion();

    int crop_size = std::min(cfg.src_w, cfg.src_h);
    uint16_t ratio_less    = calc_ratio_less(cfg.dst_w, crop_size);
    uint16_t ratio_greater = calc_ratio_greater(crop_size, cfg.dst_w);

    // 配置寄存器
    reg.write(reg_base + 0x110, (cfg.src_w << 16) | cfg.src_h, false);  // 0x44 rsize
    reg.write(reg_base + 0x114, (cfg.dst_w << 16) | cfg.dst_h, false);  // 0x45 wsize
    reg.write(reg_base + 0x108, cfg.src_addr, false);   // 0x42 rbase_rs
    reg.write(reg_base + 0x10C, cfg.dst_addr, false);   // 0x43 wbase_rs
    reg.write(reg_base + 0x24,  ratio_less, false);     // 0x09 ratio_less
    reg.write(reg_base + 0x28,  ratio_greater, false);  // 0x0a ratio_greater
    reg.write(reg_base + 0x2C,  (uint32_t)cfg.crop_enable, false);  // 0x0b crop_enable

    // 启动
    reg.write(reg_base + 0x104, 1, false);              // 0x41 comp_start_rs
    std::cout << "Resize: started, " << cfg.src_w << "x" << cfg.src_h
              << " -> " << cfg.dst_w << "x" << cfg.dst_h
              << " crop=" << cfg.crop_enable << std::endl;

    // 轮询完成
    auto start = std::chrono::system_clock::now();
    while (true) {
        if (reg.read(reg_base + 0x140, false))          // 0x50 comp_done_rs
            break;
        auto now = std::chrono::system_clock::now();
        int  ms  = (int)std::chrono::duration_cast<std::chrono::milliseconds>(now - start).count();
        if (ms > timeout_ms) {
            std::cerr << "Resize: timeout after " << ms << "ms" << std::endl;
            return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    std::cout << "Resize: done" << std::endl;
    return true;
}

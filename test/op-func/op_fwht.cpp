#include "op_fwht.h"

#include "compile_fpai_target.hpp"
#include <iostream>
#include <chrono>
#include <thread>

using namespace fpai;

bool op_fwht_run(FPAIDevice* dev, uint32_t reg_base, const FwhtConfig& cfg,
                 int timeout_ms, uint32_t* cycle_cnt)
{
    auto& reg = dev->defaultRegRegion();

    reg.write(reg_base + 0x1C, cfg.hd_data_width, false);
    reg.write(reg_base + 0x20, cfg.cal_percision, false);
    reg.write(reg_base + 0xC8, cfg.src_addr, false);
    reg.write(reg_base + 0xCC, cfg.dst_addr, false);
    reg.write(reg_base + 0xD0, cfg.total_blocks, false);

    reg.write(reg_base + 0xC4, 1, false);

    auto start = std::chrono::system_clock::now();
    while (true) {
        if (reg.read(reg_base + 0x100, false)) break;
        auto now = std::chrono::system_clock::now();
        int  ms  = (int)std::chrono::duration_cast<std::chrono::milliseconds>(now - start).count();
        if (ms > timeout_ms) {
            std::cerr << "FWHT: timeout after " << ms << "ms" << std::endl;
            return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    if (cycle_cnt) *cycle_cnt = reg.read(reg_base + 0x88, false);
    return true;
}

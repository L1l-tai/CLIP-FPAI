#include "op_gather.h"

#include "compile_fpai_target.hpp"
#include <iostream>
#include <chrono>
#include <thread>

using namespace fpai;

bool op_gather_run(FPAIDevice* dev, uint32_t reg_base, const GatherConfig& cfg,
                   int timeout_ms, uint32_t* cycle_cnt)
{
    auto& reg = dev->defaultRegRegion();

    reg.write(reg_base + 0x14, cfg.indices_len, false);
    reg.write(reg_base + 0x18, cfg.data_width_beats, false);
    reg.write(reg_base + 0x04, (cfg.indices_beats << 16) | (cfg.idx_addr & 0xFFFF), false);
    reg.write(reg_base + 0x0C, cfg.src_addr, false);
    reg.write(reg_base + 0x08, cfg.dst_addr, false);

    reg.write(reg_base + 0x00, 1, false);

    auto start = std::chrono::system_clock::now();
    while (true) {
        if (reg.read(reg_base + 0x80, false)) break;
        auto now = std::chrono::system_clock::now();
        int  ms  = (int)std::chrono::duration_cast<std::chrono::milliseconds>(now - start).count();
        if (ms > timeout_ms) {
            std::cerr << "Gather: timeout after " << ms << "ms" << std::endl;
            return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    if (cycle_cnt) *cycle_cnt = reg.read(reg_base + 0x84, false);
    return true;
}

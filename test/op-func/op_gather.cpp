#include "op_gather.h"

#include "compile_fpai_target.hpp"
#include <iostream>
#include <chrono>
#include <thread>

using namespace fpai;

bool op_gather_run(FPAIDevice* dev, uint32_t reg_base, const GatherConfig& cfg, int timeout_ms)
{
    auto& reg = dev->defaultRegRegion();

    // 配置寄存器
    reg.write(reg_base + 0x14, cfg.indices_len, false);    // 0x05 rfu_wreg0
    reg.write(reg_base + 0x18, cfg.data_width_beats, false); // 0x06 rfu_wreg1
    reg.write(reg_base + 0x04, (cfg.indices_beats << 16) | (cfg.idx_addr & 0xFFFF), false); // 0x01
    reg.write(reg_base + 0x0C, cfg.src_addr, false);       // 0x03 rbase2
    reg.write(reg_base + 0x08, cfg.dst_addr, false);       // 0x02 wbase1

    // 启动
    reg.write(reg_base + 0x00, 1, false);                  // 0x00 comp_start
    std::cout << "Gather: started, indices=" << cfg.indices_len
              << " beats=" << cfg.data_width_beats << std::endl;

    // 轮询完成
    auto start = std::chrono::system_clock::now();
    while (true) {
        if (reg.read(reg_base + 0x80, false))              // 0x20 comp_done
            break;
        auto now = std::chrono::system_clock::now();
        int  ms  = (int)std::chrono::duration_cast<std::chrono::milliseconds>(now - start).count();
        if (ms > timeout_ms) {
            std::cerr << "Gather: timeout after " << ms << "ms" << std::endl;
            return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    std::cout << "Gather: done" << std::endl;
    return true;
}

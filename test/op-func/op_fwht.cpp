#include "op_fwht.h"

#include "compile_fpai_target.hpp"
#include <iostream>
#include <chrono>
#include <thread>

using namespace fpai;

bool op_fwht_run(FPAIDevice* dev, uint32_t reg_base, const FwhtConfig& cfg, int timeout_ms)
{
    auto& reg = dev->defaultRegRegion();

    // 配置寄存器
    reg.write(reg_base + 0x1C, cfg.hd_data_width, false);  // 0x07 rfu_wreg2
    reg.write(reg_base + 0x20, cfg.cal_percision, false);  // 0x08 rfu_wreg3
    reg.write(reg_base + 0xC8, cfg.src_addr, false);       // 0x32 rbase_hd
    reg.write(reg_base + 0xCC, cfg.dst_addr, false);       // 0x33 wbase_hd
    reg.write(reg_base + 0xD0, cfg.total_blocks, false);   // 0x34 wrsize_hd

    // 启动
    reg.write(reg_base + 0xC4, 1, false);                  // 0x31 comp_start_hd
    std::cout << "FWHT: started, blocks=" << cfg.total_blocks
              << " precision=" << cfg.cal_percision << std::endl;

    // 轮询完成
    auto start = std::chrono::system_clock::now();
    while (true) {
        if (reg.read(reg_base + 0x100, false))             // 0x40 comp_done_hd
            break;
        auto now = std::chrono::system_clock::now();
        int  ms  = (int)std::chrono::duration_cast<std::chrono::milliseconds>(now - start).count();
        if (ms > timeout_ms) {
            std::cerr << "FWHT: timeout after " << ms << "ms" << std::endl;
            return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    std::cout << "FWHT: done" << std::endl;
    return true;
}

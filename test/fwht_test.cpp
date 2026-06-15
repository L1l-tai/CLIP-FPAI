#include "file_utils.hpp"
#include "et_device.hpp"
#include "fps_calculator.hpp"
#include "vis_helper.hpp"
#include "icraft_utils.hpp"
#include "mem_file_utils.hpp"
// icraft includes
#include <icraft-xrt/core/session.h>
#include "compile_fpai_target.hpp"
// 3rd-party dependency includes
#include <opencv2/opencv.hpp>
#include "yaml-cpp/yaml.h"
// system libs
#include <fstream>
#include <iostream>
#include <string>
#include <vector>
#include <memory>
#include <thread>
#include <chrono>
#include <ctime>
#include <cstring>

using namespace icraft::xrt;
using namespace icraft::xir;
using namespace std::chrono;
using namespace std::chrono_literals;
namespace fs = std::filesystem;
using namespace fpai;

// ============================================================
// FSM 状态位域解析 (from customop_top.v dbg2_s2)
// [11:9]  hadamard_state[2:0]
// [8]     gen_status_hd
// [7]     fwht_status_hd
// [6:5]   trans_status_hd[1:0]
// [4]     rd_start_hd
// [3]     wr_start_hd
// [2]     arb_rd_done_hd
// [1]     arb_wr_done_hd
// [0]     comp_done_hd
// ============================================================
static const char* hadamard_state_name(uint32_t state) {
    switch (state & 0x7) {
        case 0: return "IDLE";
        case 1: return "GEN_ADDR";
        case 2: return "RD_ONLY";
        case 3: return "FWHT";
        case 4: return "WR_PIPLINE";
        case 5: return "WR_ONLY";
        case 6: return "COMP_DONE";
        default: return "UNKNOWN";
    }
}

static void print_hadamard_fsm(uint32_t dbg) {
    uint32_t state = (dbg >> 9) & 0x7;
    std::cout << "  [FSM] state=" << hadamard_state_name(state)
              << " gen=" << ((dbg >> 8) & 1)
              << " fwht=" << ((dbg >> 7) & 1)
              << " trans=" << ((dbg >> 5) & 3)
              << " rd_st=" << ((dbg >> 4) & 1)
              << " wr_st=" << ((dbg >> 3) & 1)
              << " rd_done=" << ((dbg >> 2) & 1)
              << " wr_done=" << ((dbg >> 1) & 1)
              << " comp=" << (dbg & 1) << std::endl;
}

static void print_cdc_overview(uint32_t dbg) {
    std::cout << "  [CDC] rst=" << (dbg & 1)
              << " comp_start=" << ((dbg >> 4) & 1)
              << " comp_done=" << ((dbg >> 6) & 1)
              << " hd_start=" << ((dbg >> 8) & 1)
              << " hd_done=" << ((dbg >> 10) & 1) << std::endl;
}

int main(int argc, char *argv[])
{
    std::string device_url = "axi://zg330aiu?npu=0x40000000&dma=0x80000000";
    auto device = Device::Open(device_url.c_str());
    auto fpai_device = device.cast<FPAIDevice>();

    uint32_t reg_base = 0x400C0000;

    // -------- 寄存器地址 (reg_ctrl 索引 × 4) --------
    uint32_t REG_START       = reg_base + 0xC4;   // 0x31 HD_COMP_START_ADDR
    uint32_t REG_DONE        = reg_base + 0x100;  // 0x40 HD_COMP_DONE_ADDR
    uint32_t REG_VERSION     = reg_base + 0x180;  // 0x60
    uint32_t REG_RESET       = reg_base + 0x1DC;  // 0x77
    uint32_t REG_DATA_WIDTH  = reg_base + 0x1C;   // 0x07 RFU_WADDR2
    uint32_t REG_PRECISION   = reg_base + 0x20;   // 0x08 RFU_WADDR3
    uint32_t REG_RBASE       = reg_base + 0xC8;   // 0x32
    uint32_t REG_WBASE       = reg_base + 0xCC;   // 0x33
    uint32_t REG_WRSIZE      = reg_base + 0xD0;   // 0x34
    uint32_t REG_DBG_CDC     = reg_base + 0x84;   // 0x21 RFU_RADDR0
    uint32_t REG_DBG_HD_FSM  = reg_base + 0x8C;   // 0x23 RFU_RADDR2

    uint32_t version = fpai_device.defaultRegRegion().read(REG_VERSION, false);
    std::cout << "Hadamard version is 0x" << std::hex << version << std::dec << std::endl;

    // ============================================================
    // 从 test/input-data/ 加载 FP16 测试数据
    // ============================================================
    const int TOTAL_BLOCKS = 8;
    const int CAL_PRECISION = 1;       // FP16

    int src_data_size = TOTAL_BLOCKS * 64;   // 512 bytes
    int dst_data_size = TOTAL_BLOCKS * 64;   // 512 bytes

    // 用 padding 检测 DMA 是否写到区域外
    const int PAD_BLOCKS = 8;
    int pad_size = PAD_BLOCKS * 64;

    int src_offset = 0;
    int dst_offset = src_data_size + pad_size;
    int total_size = src_data_size + pad_size + dst_data_size + pad_size;

    std::shared_ptr<int8_t[]> src_buf(new int8_t[src_data_size]{0});
    int loaded = read_mem_file("test/input-data/fwht-input-fp16.mem", src_buf.get(), src_data_size);
    if (loaded < 0 || loaded < src_data_size) {
        std::cout << "Error: failed to load fwht-input-fp16.mem (loaded=" << loaded << ")" << std::endl;
        return -1;
    }
    std::cout << "Loaded " << loaded << " bytes from fwht-input-fp16.mem" << std::endl;

    auto mem_chunk = fpai_device.defaultMemRegion().malloc(total_size, 0, 64);
    uint32_t mem_addr = mem_chunk->begin.addr();
    std::cout << "PL-DDR base addr: 0x" << std::hex << mem_addr << std::dec << std::endl;

    uint32_t src_addr = mem_addr + src_offset;
    uint32_t dst_addr = mem_addr + dst_offset;
    std::cout << "Source addr: 0x" << std::hex << src_addr << std::dec << std::endl;
    std::cout << "Dest   addr: 0x" << std::hex << dst_addr << std::dec << std::endl;

    // ============================================================
    // 复位 FPGA 逻辑
    // ============================================================
    std::cout << "\n=== Resetting FPGA logic ===" << std::endl;
    fpai_device.defaultRegRegion().write(REG_RESET, 1, false);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    fpai_device.defaultRegRegion().write(REG_RESET, 0, false);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    std::cout << "  Reset complete" << std::endl;

    // ============================================================
    // 全部区域填入已知递增模式
    // ============================================================
    std::cout << "\n=== Pre-filling entire region with known pattern ===" << std::endl;
    {
        std::vector<int8_t> prefill(total_size);
        for (int i = 0; i < total_size; i++) {
            prefill[i] = (int8_t)(i & 0xFF);
        }
        mem_chunk.write(0, (char*)prefill.data(), total_size);
    }
    std::cout << "  All " << total_size << " bytes filled" << std::endl;

    // 写入 src 数据
    std::cout << "\n=== Writing src data (from fwht-input-fp16.mem) ===" << std::endl;
    mem_chunk.write(src_offset, (char*)src_buf.get(), src_data_size);
    std::cout << "  Wrote " << src_data_size << " bytes" << std::endl;

    // ============================================================
    // 启动前读取 CDC 状态
    // ============================================================
    std::cout << "\n=== Pre-start CDC status ===" << std::endl;
    {
        uint32_t cdc = fpai_device.defaultRegRegion().read(REG_DBG_CDC, false);
        print_cdc_overview(cdc);
    }

    // ============================================================
    // 寄存器配置
    // ============================================================
    std::cout << "\n=== Configuring Hadamard Registers ===" << std::endl;
    fpai_device.defaultRegRegion().write(REG_DATA_WIDTH, 2, false);
    fpai_device.defaultRegRegion().write(REG_PRECISION, CAL_PRECISION, false);
    fpai_device.defaultRegRegion().write(REG_RBASE, src_addr, false);
    fpai_device.defaultRegRegion().write(REG_WBASE, dst_addr, false);
    fpai_device.defaultRegRegion().write(REG_WRSIZE, TOTAL_BLOCKS, false);
    std::cout << "  hd_data_width = 2" << std::endl;
    std::cout << "  cal_percision = " << CAL_PRECISION << std::endl;
    std::cout << "  rbase_hd = 0x" << std::hex << src_addr << std::dec << std::endl;
    std::cout << "  wbase_hd = 0x" << std::hex << dst_addr << std::dec << std::endl;
    std::cout << "  wrsize_hd = " << TOTAL_BLOCKS << std::endl;

    // ============================================================
    // 启动并轮询, 同时抓取 FSM 状态
    // ============================================================
    fpai_device.defaultRegRegion().write(REG_START, 1, false);
    std::cout << "\nHadamard started..." << std::endl;

    auto start = std::chrono::system_clock::now();
    int done = 0;
    int poll_count = 0;
    while (done == 0) {
        done = fpai_device.defaultRegRegion().read(REG_DONE, false);
        poll_count++;
        auto end = std::chrono::system_clock::now();
        int during = (int)std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();

        // 每 100ms 打印一次 FSM 状态
        if (poll_count % 10 == 0) {
            uint32_t fsm = fpai_device.defaultRegRegion().read(REG_DBG_HD_FSM, false);
            std::cout << "  [" << during << "ms] ";
            print_hadamard_fsm(fsm);
        }

        if (during > 10000) {
            std::cout << "\n=== TIMEOUT! Dumping FSM state ===" << std::endl;
            uint32_t fsm = fpai_device.defaultRegRegion().read(REG_DBG_HD_FSM, false);
            uint32_t cdc = fpai_device.defaultRegRegion().read(REG_DBG_CDC, false);
            std::cout << "  Poll count: " << poll_count << std::endl;
            print_cdc_overview(cdc);
            print_hadamard_fsm(fsm);
            std::cout << "Error: FPGA Time Out!" << std::endl;
            return -1;
        }
    }
    std::cout << "Hadamard completed in " << poll_count << " polls." << std::endl;

    // ============================================================
    // 完成后读取 FSM 状态
    // ============================================================
    {
        uint32_t fsm = fpai_device.defaultRegRegion().read(REG_DBG_HD_FSM, false);
        std::cout << "Post-completion FSM: ";
        print_hadamard_fsm(fsm);
    }

    // ============================================================
    // 读回全部区域，逐 block 检查
    // ============================================================
    std::cout << "\n=== Reading back entire region ===" << std::endl;
    std::vector<int8_t> all_buf(total_size);
    mem_chunk.read((char*)all_buf.data(), 0, total_size);

    int total_blocks = total_size / 64;

    std::cout << "\n=== Memory Write Detection (all " << total_blocks
              << " blocks, 64B each) ===" << std::endl;
    std::cout << "  Block  Offset     Region     Status" << std::endl;
    std::cout << "  -----  --------   ---------  ------" << std::endl;

    int written_before = 0, written_dst = 0, written_after = 0;
    int first_written = -1, last_written = -1;

    for (int b = 0; b < total_blocks; b++) {
        int boff = b * 64;
        bool modified = false;
        for (int off = 0; off < 64; off++) {
            if (all_buf[boff + off] != (int8_t)((boff + off) & 0xFF)) {
                modified = true;
                break;
            }
        }

        const char* region;
        if (boff < src_offset)                    region = "BEFORE_SRC";
        else if (boff < src_offset + src_data_size) region = "SRC";
        else if (boff < dst_offset)                region = "PAD(OK)";
        else if (boff < dst_offset + dst_data_size) region = "DST";
        else                                       region = "AFTER_DST";

        if (modified) {
            if (strcmp(region, "SRC") == 0 || strcmp(region, "PAD(OK)") == 0 || strcmp(region, "BEFORE_SRC") == 0) {
                std::cout << "  [" << b << "]   0x" << std::hex << boff << std::dec
                          << "  " << region << "  *** WRITTEN (unexpected!)" << std::endl;
                if (strcmp(region, "BEFORE_SRC") == 0) written_before++;
            } else {
                std::cout << "  [" << b << "]   0x" << std::hex << boff << std::dec
                          << "  " << region << "  written" << std::endl;
                if (strcmp(region, "DST") == 0) {
                    written_dst++;
                    if (first_written < 0) first_written = b;
                    last_written = b;
                }
                if (strcmp(region, "AFTER_DST") == 0) written_after++;
            }
        }
    }
    std::cout << "  Summary: before=" << written_before
              << " dst=" << written_dst
              << " after=" << written_after << std::endl;

    // ============================================================
    // 逐元素验证
    // ============================================================
    std::cout << "\n=== Element Verification (first 8 blocks) ===" << std::endl;
    int dst_start = total_blocks - (PAD_BLOCKS + TOTAL_BLOCKS);
    for (int b = 0; b < TOTAL_BLOCKS; b++) {
        int boff = (dst_start + b) * 64;
        bool any_nonzero = false;
        for (int off = 0; off < 64; off++) {
            if (all_buf[boff + off] != 0) { any_nonzero = true; break; }
        }
        std::cout << "  Block[" << b << "] offset=0x" << std::hex << boff << std::dec
                  << " nonzero=" << (any_nonzero ? "YES" : "NO");
        if (any_nonzero) {
            std::cout << " data[15:0]=0x"
                      << std::hex
                      << ((uint16_t)(uint8_t)all_buf[boff + 1] << 8 | (uint8_t)all_buf[boff])
                      << std::dec;
        }
        std::cout << std::endl;
    }

    // ============================================================
    // 保存输出
    // ============================================================
    auto ts = std::chrono::system_clock::now().time_since_epoch().count();
    char fname[256];
    snprintf(fname, sizeof(fname), "test/output-data/hardware/fwht-output-fp16-%lld.mem", (long long)ts);
    write_mem_file(fname, all_buf.data() + dst_offset, dst_data_size);
    std::cout << "\nOutput saved to " << fname << std::endl;

    std::cout << "\n=== HADAMARD TEST COMPLETE ===" << std::endl;
    return 0;
}

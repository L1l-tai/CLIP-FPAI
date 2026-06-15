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
#include <condition_variable>
#include <atomic>
#include <thread>
#include <functional>
#include <filesystem>
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
// FSM 状态位域解析 (from customop_top.v dbg1_s2)
// [10:8]  gather_state[2:0]
// [7]     gen_status
// [6]     rd_indices
// [5]     trans_data
// [4]     rd_start
// [3]     wr_start
// [2]     arb_rd_done_gather
// [1]     arb_wr_done_gather
// [0]     comp_done (gather)
// ============================================================
static const char* gather_state_name(uint32_t state) {
    switch (state & 0x7) {
        case 0: return "IDLE";
        case 1: return "RD_INDICES";
        case 2: return "R_INDICES_DONE";
        case 3: return "GEN_ADDR";
        case 4: return "WR_PIPLINE";
        case 5: return "COMP_DONE";
        default: return "UNKNOWN";
    }
}

static void print_gather_fsm(uint32_t dbg) {
    uint32_t state = (dbg >> 8) & 0x7;
    std::cout << "  [FSM] state=" << gather_state_name(state)
              << " gen=" << ((dbg >> 7) & 1)
              << " rd_idx=" << ((dbg >> 6) & 1)
              << " trans=" << ((dbg >> 5) & 1)
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
    uint32_t REG_START       = reg_base + 0x00;   // 0x00 COMP_START_ADDR
    uint32_t REG_DONE        = reg_base + 0x80;   // 0x20 COMPUTE_DONE_ADDR
    uint32_t REG_VERSION     = reg_base + 0xC0;   // 0x30 GATHER_VERSION
    uint32_t REG_RESET       = reg_base + 0x1DC;  // 0x77
    uint32_t REG_IDX_BASE    = reg_base + 0x04;   // 0x01 RSIZE1_BASE_ADDR
    uint32_t REG_WRITE_BASE  = reg_base + 0x08;   // 0x02 WSIZE1_BASE_ADDR
    uint32_t REG_SRC_BASE    = reg_base + 0x0C;   // 0x03 RSIZE2_BASE_ADDR
    uint32_t REG_IDX_LEN     = reg_base + 0x14;   // 0x05 RFU_WADDR0 (indices_width)
    uint32_t REG_DATA_WIDTH  = reg_base + 0x18;   // 0x06 RFU_WADDR1 (data_width)
    uint32_t REG_DBG_CDC     = reg_base + 0x84;   // 0x21 RFU_RADDR0
    uint32_t REG_DBG_GA_FSM  = reg_base + 0x88;   // 0x22 RFU_RADDR1

    uint32_t version = fpai_device.defaultRegRegion().read(REG_VERSION, false);
    std::cout << "Gather version is 0x" << std::hex << version << std::dec << std::endl;

    // ============================================================
    // 参数 (与 test/input-data/ 中的数据匹配)
    // ============================================================
    const int INDICES_LEN = 20;
    const int DATA_WIDTH_BEATS = 8;

    int indices_beats = 2;
    int indices_size = indices_beats * 64;          // 128
    int elem_size    = DATA_WIDTH_BEATS * 64;       // 512
    int src_elements = 32;
    int src_data_size = src_elements * elem_size;   // 16384
    int dst_data_size = INDICES_LEN * elem_size;    // 10240

    // 用 padding 检测越界
    const int PAD_SIZE = 4096;

    int idx_offset  = 0;
    int src_offset  = idx_offset + indices_size + PAD_SIZE;
    int dst_offset  = src_offset + src_data_size + PAD_SIZE;
    int total_size  = dst_offset + dst_data_size + PAD_SIZE;

    // ============================================================
    // 从 test/input-data/ 加载测试数据
    // ============================================================
    std::shared_ptr<int8_t[]> idx_buf(new int8_t[indices_size]{0});
    std::shared_ptr<int8_t[]> src_buf(new int8_t[src_data_size]{0});

    int idx_loaded = read_mem_file("test/input-data/gather-input-idx.mem", idx_buf.get(), indices_size);
    int src_loaded = read_mem_file("test/input-data/gather-input-data.mem", src_buf.get(), src_data_size);

    if (idx_loaded < 0 || idx_loaded < indices_size) {
        std::cout << "Error: failed to load gather-input-idx.mem (loaded=" << idx_loaded << ")" << std::endl;
        return -1;
    }
    if (src_loaded < 0 || src_loaded < src_data_size) {
        std::cout << "Error: failed to load gather-input-data.mem (loaded=" << src_loaded << ")" << std::endl;
        return -1;
    }
    std::cout << "Loaded " << idx_loaded << " bytes from gather-input-idx.mem" << std::endl;
    std::cout << "Loaded " << src_loaded << " bytes from gather-input-data.mem" << std::endl;

    auto mem_chunk = fpai_device.defaultMemRegion().malloc(total_size, 0, 64);
    uint32_t mem_addr = mem_chunk->begin.addr();
    std::cout << "PL-DDR base addr: 0x" << std::hex << mem_addr << std::dec << std::endl;

    uint32_t idx_addr  = mem_addr + idx_offset;
    uint32_t src_addr  = mem_addr + src_offset;
    uint32_t dst_addr  = mem_addr + dst_offset;
    std::cout << "Idx  addr: 0x" << std::hex << idx_addr  << std::dec << std::endl;
    std::cout << "Src  addr: 0x" << std::hex << src_addr  << std::dec << std::endl;
    std::cout << "Dst  addr: 0x" << std::hex << dst_addr  << std::dec << std::endl;

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

    // 写入索引和数据
    std::cout << "\n=== Writing test data ===" << std::endl;
    mem_chunk.write(idx_offset, (char*)idx_buf.get(), indices_size);
    std::cout << "  Wrote " << indices_size << " bytes indices" << std::endl;
    mem_chunk.write(src_offset, (char*)src_buf.get(), src_data_size);
    std::cout << "  Wrote " << src_data_size << " bytes source data" << std::endl;

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
    std::cout << "\n=== Configuring Gather Registers ===" << std::endl;
    fpai_device.defaultRegRegion().write(REG_IDX_LEN, INDICES_LEN, false);
    fpai_device.defaultRegRegion().write(REG_DATA_WIDTH, DATA_WIDTH_BEATS, false);
    fpai_device.defaultRegRegion().write(REG_IDX_BASE, (indices_beats << 16) | (idx_addr & 0xFFFF), false);
    fpai_device.defaultRegRegion().write(REG_SRC_BASE, src_addr, false);
    fpai_device.defaultRegRegion().write(REG_WRITE_BASE, dst_addr, false);
    std::cout << "  indices_width = " << INDICES_LEN << std::endl;
    std::cout << "  data_width    = " << DATA_WIDTH_BEATS << std::endl;
    std::cout << "  idx_base      = 0x" << std::hex << idx_addr << " (beats=" << indices_beats << ")" << std::dec << std::endl;
    std::cout << "  src_base      = 0x" << std::hex << src_addr << std::dec << std::endl;
    std::cout << "  dst_base      = 0x" << std::hex << dst_addr << std::dec << std::endl;

    // ============================================================
    // 启动并轮询, 同时抓取 FSM 状态
    // ============================================================
    fpai_device.defaultRegRegion().write(REG_START, 1, false);
    std::cout << "\nGather started..." << std::endl;

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
            uint32_t fsm = fpai_device.defaultRegRegion().read(REG_DBG_GA_FSM, false);
            std::cout << "  [" << during << "ms] ";
            print_gather_fsm(fsm);
        }

        if (during > 10000) {
            std::cout << "\n=== TIMEOUT! Dumping FSM state ===" << std::endl;
            uint32_t fsm = fpai_device.defaultRegRegion().read(REG_DBG_GA_FSM, false);
            uint32_t cdc = fpai_device.defaultRegRegion().read(REG_DBG_CDC, false);
            std::cout << "  Poll count: " << poll_count << std::endl;
            print_cdc_overview(cdc);
            print_gather_fsm(fsm);
            std::cout << "Error: FPGA Time Out!" << std::endl;
            return -1;
        }
    }
    std::cout << "Gather completed in " << poll_count << " polls." << std::endl;

    // ============================================================
    // 完成后读取 FSM 状态
    // ============================================================
    {
        uint32_t fsm = fpai_device.defaultRegRegion().read(REG_DBG_GA_FSM, false);
        std::cout << "Post-completion FSM: ";
        print_gather_fsm(fsm);
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
    std::cout << "  Block  Offset     Region       Status" << std::endl;
    std::cout << "  -----  --------   -----------  ------" << std::endl;

    int written_src = 0, written_dst = 0, written_pad = 0;
    int first_dst = -1, last_dst = -1;

    for (int b = 0; b < total_blocks; b++) {
        int boff = b * 64;
        bool modified = false;
        for (int off = 0; off < 64; off++) {
            if (all_buf[boff + off] != (int8_t)((boff + off) & 0xFF)) {
                modified = true;
                break;
            }
        }
        if (!modified) continue;

        const char* region;
        if (boff < idx_offset)                          region = "BEFORE_IDX";
        else if (boff < idx_offset + indices_size)       region = "IDX";
        else if (boff < src_offset)                      region = "PAD1";
        else if (boff < src_offset + src_data_size)     { region = "SRC"; written_src++; }
        else if (boff < dst_offset)                     { region = "PAD2"; written_pad++; }
        else if (boff < dst_offset + dst_data_size)     {
            region = "DST"; written_dst++;
            if (first_dst < 0) first_dst = b;
            last_dst = b;
        }
        else                                             region = "AFTER_DST";

        std::cout << "  [" << b << "]   0x" << std::hex << boff << std::dec
                  << "  " << region << "  written" << std::endl;
    }
    std::cout << "  Summary: src_modified=" << written_src
              << " dst=" << written_dst
              << " pad=" << written_pad << std::endl;

    // ============================================================
    // 逐元素验证
    // ============================================================
    std::cout << "\n=== Element Verification (DST region) ===" << std::endl;
    int dst_blocks = dst_data_size / 64;
    for (int b = 0; b < dst_blocks && b < 20; b++) {  // 前 20 个 block
        int boff = dst_offset + b * 64;
        int buf_idx = boff;  // all_buf is flat, offset = boff
        bool any_nonzero = false;
        uint16_t first_val = 0;
        for (int off = 0; off < 64; off++) {
            if (all_buf[buf_idx + off] != 0) { any_nonzero = true; break; }
        }
        first_val = ((uint16_t)(uint8_t)all_buf[buf_idx + 1] << 8) | (uint8_t)all_buf[buf_idx];
        std::cout << "  Block[" << b << "] nonzero=" << (any_nonzero ? "YES" : " NO")
                  << " first16=0x" << std::hex << first_val << std::dec << std::endl;
    }

    // ============================================================
    // 保存输出
    // ============================================================
    auto ts = std::chrono::system_clock::now().time_since_epoch().count();
    char fname[256];
    snprintf(fname, sizeof(fname), "test/output-data/hardware/gather-output-%lld.mem", (long long)ts);
    write_mem_file(fname, all_buf.data() + dst_offset, dst_data_size);
    std::cout << "\nOutput saved to " << fname << std::endl;

    std::cout << "\n=== GATHER TEST COMPLETE ===" << std::endl;
    return 0;
}

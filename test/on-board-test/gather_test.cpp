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

    uint32_t version = fpai_device.defaultRegRegion().read(REG_VERSION, false);
    std::cout << "Gather version is 0x" << std::hex << version << std::dec << std::endl;

    // ============================================================
    // 内联生成 256×256 INT8 彩虹矩阵 + 77 随机索引
    // ============================================================
    const int N = 256, D = 256;
    const int INDICES_LEN = 77;
    const int DATA_WIDTH_BEATS = 4;       // 256B/row = 4 beats

    int indices_beats = 5;                // 77×4=308 → 5 beats
    int indices_size = indices_beats * 64;              // 320
    int elem_size    = DATA_WIDTH_BEATS * 64;           // 256
    int src_data_size = N * elem_size;                  // 65536
    int dst_data_size = INDICES_LEN * elem_size;        // 19712

    const int PAD_SIZE = 4096;
    int idx_offset  = 0;
    int src_offset  = idx_offset + indices_size + PAD_SIZE;
    int dst_offset  = src_offset + src_data_size + PAD_SIZE;
    int total_size  = dst_offset + dst_data_size + PAD_SIZE;

    // 生成数据
    std::vector<int8_t> idx_buf(indices_size, 0);
    std::vector<int8_t> src_buf(src_data_size, 0);

    std::srand(42);
    for (int i = 0; i < INDICES_LEN; i++) {
        int32_t val = std::rand() % N;
        idx_buf[i * 4 + 0] = val & 0xFF;
        idx_buf[i * 4 + 1] = (val >> 8) & 0xFF;
        idx_buf[i * 4 + 2] = (val >> 16) & 0xFF;
        idx_buf[i * 4 + 3] = (val >> 24) & 0xFF;
    }
    for (int row = 0; row < N; row++) {
        float phase = row * 2.0f * 3.14159f / N;
        for (int col = 0; col < D; col++) {
            float val = sinf(col * 3.0f * 3.14159f / D + phase) * 0.6f
                      + sinf(2.0f * col * 3.14159f / D + phase * 1.7f) * 0.3f
                      + sinf(3.0f * col * 3.14159f / D + phase * 0.5f) * 0.1f;
            src_buf[row * D + col] = (int8_t)((val + 1.0f) * 127.5f);
        }
    }
    std::cout << "Generated " << N << "x" << D << " rainbow matrix + " << INDICES_LEN << " indices" << std::endl;

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
    mem_chunk.write(idx_offset, (char*)idx_buf.data(), indices_size);
    std::cout << "  Wrote " << indices_size << " bytes indices" << std::endl;
    mem_chunk.write(src_offset, (char*)src_buf.data(), src_data_size);
    std::cout << "  Wrote " << src_data_size << " bytes source data" << std::endl;

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
    // 启动并轮询
    // ============================================================
    fpai_device.defaultRegRegion().write(REG_START, 1, false);
    std::cout << "\nGather started..." << std::endl;

    auto start = std::chrono::system_clock::now();
    int done = 0;
    while (done == 0) {
        done = fpai_device.defaultRegRegion().read(REG_DONE, false);
        auto end = std::chrono::system_clock::now();
        int during = (int)std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();
        if (during > 10000) {
            std::cout << "Error: FPGA Time Out!" << std::endl;
            return -1;
        }
    }
    std::cout << "Gather completed." << std::endl;

    // ============================================================
    // 读回输出
    // ============================================================
    std::vector<int8_t> dst_buf(dst_data_size);
    mem_chunk.read((char*)dst_buf.data(), dst_offset, dst_data_size);

    // ============================================================
    // 保存输出
    // ============================================================
    const char* out_mem = "test/output-data/hardware/gather-output-board.mem";
    write_mem_file(out_mem, dst_buf.data(), dst_data_size);
    std::cout << "\nOutput saved to " << out_mem << std::endl;

    // 读取周期计数器
    uint32_t cycle_cnt = fpai_device.defaultRegRegion().read(reg_base + 0x84, false);
    std::cout << "Gather cycle count: " << cycle_cnt << " cycles ("
              << (cycle_cnt / 100.0) << " us @ 100MHz)" << std::endl;

    std::cout << "\n=== GATHER TEST COMPLETE ===" << std::endl;
    return 0;
}

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

// ---- FP16 conversion (IEEE 754 half-precision, round-to-nearest-even) ----
static uint16_t float_to_fp16(float x) {
    if (x == 0.0f) return 0;
    uint16_t sign = (x < 0) ? 0x8000 : 0;
    float abs_x = (x < 0) ? -x : x;

    if (abs_x < 6.0e-8f) return sign;  // underflow to zero
    if (abs_x > 65504.0f) return sign | 0x7C00;  // overflow to inf

    int exp;
    float mant = frexpf(abs_x, &exp);  // mant in [0.5, 1)
    int e = exp + 14;  // biased exponent (bias=15, but frexp gives exp-1 bias)
    if (e <= 0) {  // subnormal
        mant *= (1 << (-e + 1));
        return sign | ((uint16_t)mant & 0x3FF);
    }
    if (e >= 31) return sign | 0x7C00;  // overflow

    int frac = (int)(mant * 2048.0f) & 0x7FF;  // 11 bits with extra
    frac = (frac + 1) >> 1;  // round to nearest, 10 bits
    if (frac >= 1024) { e++; frac = 0; }  // carry

    return sign | ((e & 0x1F) << 10) | (frac & 0x3FF);
}

// ---- 768x30 outlier data generation ----
static std::vector<uint16_t> generate_768x30_outlier_data(int seed = 42) {
    const int VEC_DIM = 768, NUM_VECTORS = 30;
    std::vector<uint16_t> data(VEC_DIM * NUM_VECTORS);
    std::mt19937 rng(seed);

    std::normal_distribution<float> normal(0.0f, 0.5f);
    std::uniform_real_distribution<float> outlier_mag(2.0f, 6.0f);
    std::uniform_int_distribution<int> n_outliers(3, 8);
    std::uniform_int_distribution<int> pos_idx(0, VEC_DIM - 1);
    std::uniform_real_distribution<float> coin(0.0f, 1.0f);

    for (int v = 0; v < NUM_VECTORS; v++) {
        int base = v * VEC_DIM;
        // Normal values
        for (int i = 0; i < VEC_DIM; i++) {
            float val = normal(rng);
            if (val > 1.5f) val = 1.5f;
            if (val < -1.5f) val = -1.5f;
            data[base + i] = float_to_fp16(val);
        }
        // Outliers
        int n = n_outliers(rng);
        for (int k = 0; k < n; k++) {
            int idx = pos_idx(rng);
            float mag = outlier_mag(rng);
            if (coin(rng) > 0.5f) mag = -mag;
            data[base + idx] = float_to_fp16(mag);
        }
    }
    return data;
}

// ---- Pack FP16 values to 512-bit blocks (RTL DDR byte order) ----
static void pack_to_blocks(const std::vector<uint16_t>& data, int8_t* buf, int num_blocks) {
    // Each block = 64 bytes = 32 FP16 values
    // Byte order: fwht_regs[j] = {bytearray[62-j*2], bytearray[63-j*2]}
    for (int b = 0; b < num_blocks; b++) {
        for (int j = 0; j < 32; j++) {
            int idx = b * 32 + j;
            uint16_t fp16 = (idx < (int)data.size()) ? data[idx] : 0;
            int hi = 62 - j * 2;
            int lo = 63 - j * 2;
            buf[b * 64 + hi] = (fp16 >> 8) & 0xFF;
            buf[b * 64 + lo] = fp16 & 0xFF;
        }
    }
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

    uint32_t version = fpai_device.defaultRegRegion().read(REG_VERSION, false);
    std::cout << "Hadamard version is 0x" << std::hex << version << std::dec << std::endl;

    // ============================================================
    // 内联生成 768×30 FP16 离群值测试数据
    // ============================================================
    const int VEC_DIM = 768, NUM_VECTORS = 30;
    const int TOTAL_ELEMS = VEC_DIM * NUM_VECTORS;  // 23040
    const int TOTAL_BLOCKS = TOTAL_ELEMS / 32;       // 720 (FP16, 32值/块)
    const int CAL_PRECISION = 1;  // FP16

    std::cout << "Generating " << NUM_VECTORS << "x" << VEC_DIM
              << " outlier data (" << TOTAL_BLOCKS << " blocks)..." << std::endl;
    auto fp16_data = generate_768x30_outlier_data(42);

    int src_data_size = TOTAL_BLOCKS * 64;   // 46080 bytes
    int dst_data_size = TOTAL_BLOCKS * 64;   // 46080 bytes

    // 用 padding 检测 DMA 是否写到区域外
    const int PAD_BLOCKS = 64;
    int pad_size = PAD_BLOCKS * 64;          // 4096 bytes

    int src_offset = pad_size;
    int dst_offset = src_offset + src_data_size + pad_size;
    int total_size = dst_offset + dst_data_size + pad_size;

    std::vector<int8_t> src_buf(src_data_size, 0);
    pack_to_blocks(fp16_data, src_buf.data(), TOTAL_BLOCKS);
    // 同步写入 .mem 供仿真使用
    write_mem_file("test/input-data/fwht-input-768x30.mem", src_buf.data(), src_data_size);
    std::cout << "Generated " << src_data_size << " bytes source data" << std::endl;

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
    std::cout << "\n=== Writing src data ===" << std::endl;
    mem_chunk.write(src_offset, (char*)src_buf.data(), src_data_size);
    std::cout << "  Wrote " << src_data_size << " bytes" << std::endl;

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
    // 启动并轮询
    // ============================================================
    fpai_device.defaultRegRegion().write(REG_START, 1, false);
    std::cout << "\nHadamard started..." << std::endl;

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
    std::cout << "Hadamard completed." << std::endl;

    // ============================================================
    // 读回输出区域
    // ============================================================
    std::vector<int8_t> dst_buf(dst_data_size);
    mem_chunk.read((char*)dst_buf.data(), dst_offset, dst_data_size);

    // ============================================================
    // 保存输出
    // ============================================================
    const char* out_mem = "test/output-data/hardware/fwht-output-board.mem";
    write_mem_file(out_mem, dst_buf.data(), dst_data_size);
    std::cout << "\nOutput saved to " << out_mem << std::endl;

    // ============================================================
    // 读取周期计数器
    // ============================================================
    uint32_t cycle_cnt = fpai_device.defaultRegRegion().read(reg_base + 0x88, false);
    std::cout << "Hadamard cycle count: " << cycle_cnt << " cycles ("
              << (cycle_cnt / 200.0) << " us @ 200MHz)" << std::endl;

    std::cout << "\n=== HADAMARD TEST COMPLETE ===" << std::endl;
    return 0;
}

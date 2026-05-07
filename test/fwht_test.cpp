#include "file_utils.hpp"
#include "et_device.hpp"
#include "fps_calculator.hpp"
#include "vis_helper.hpp"
#include "icraft_utils.hpp"
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

using namespace icraft::xrt;
using namespace icraft::xir;
using namespace std::chrono;
using namespace std::chrono_literals;
namespace fs = std::filesystem;
using namespace fpai;

// Hadamard 寄存器地址 (对应 reg_ctrl.v 中的定义)
// 16'h31: HD_COMP_START_ADDR
// 16'h32: HD_RBASE_ADDR
// 16'h33: HD_WBASE_ADDR
// 16'h34: HD_WRSIZE_ADDR
// 16'h40: HD_COMP_DONE_ADDR
// 16'h07: rfu_wreg2 (hd_data_width)
// 16'h08: rfu_wreg3 (hd_cal_percision)

int main(int argc, char *argv[])
{
    // FPAI设备初始化
    std::string device_url = "axi://zg330aiu?npu=0x40000000&dma=0x80000000";
    auto device = Device::Open(device_url.c_str());
    auto fpai_device = device.cast<FPAIDevice>();

    // Hadamard 寄存器基地址 (与 Gather 不同的地址偏移)
    uint32_t reg_base = 0x400C0000;

    // 读取 Hadamard 版本寄存器 (0x40)
    uint32_t version = fpai_device.defaultRegRegion().read(reg_base + 0x40, false);
    std::cout << "Hadamard version is " << std::hex << "0x" << version << std::dec << std::endl;

    // *******************************************
    // @ Hadamard 算子参数配置
    // *******************************************
    // 与 hadamard_sim.sv / hadamard_int8_sim.sv 中的参数保持一致

    // 数据精度: 0 = INT8, 1 = FP16
    const int FP16_MODE = 1;  // 选择 FP16 模式
    const int INT8_MODE = 0;

    // 每次迭代处理的512bit数据块数量 (hd_data_width)
    const int HD_DATA_WIDTH = 2;

    // 内存地址定义
    const uint32_t SRC_BASE_ADDR = 0x2000;    // 源数据存储地址
    const uint32_t DST_BASE_ADDR = 0x10000;   // 目的数据存储地址

    // 数据块数量
    const int TOTAL_BLOCKS = 8;  // 8个512bit数据块

    // 计算内存大小
    // 每个块 64 bytes (512 bits)
    int src_data_size = TOTAL_BLOCKS * 64;   // 512 bytes
    int dst_data_size = TOTAL_BLOCKS * 64;   // 512 bytes
    int total_size = src_data_size + dst_data_size;

    // 分配内存
    std::shared_ptr<int8_t[]> src_data = std::shared_ptr<int8_t[]>(new int8_t[src_data_size]{ 0 });
    std::shared_ptr<int8_t[]> dst_data = std::shared_ptr<int8_t[]>(new int8_t[dst_data_size]{ 0 });

    // 在FPGA内存中分配空间
    auto mem_chunk = fpai_device.defaultMemRegion().malloc(total_size, 0, 64);
    uint32_t mem_addr = mem_chunk->begin.addr();
    std::cout << "PL-DDR base addr: 0x" << std::hex << mem_addr << std::dec << std::endl;

    // 计算实际存储地址
    uint32_t src_addr = mem_addr + SRC_BASE_ADDR;
    uint32_t dst_addr = mem_addr + DST_BASE_ADDR;

    std::cout << "Source data base addr: 0x" << std::hex << src_addr << std::dec << std::endl;
    std::cout << "Dest data base addr: 0x" << std::hex << dst_addr << std::dec << std::endl;

    // *******************************************
    // @ 准备源数据 (FP16 模式)
    // *******************************************
    std::cout << "\n=== Loading Source Data (FP16 Mode) ===" << std::endl;

    if (FP16_MODE) {
        // FP16 模式: 每个512bit块包含32个FP16数据 (每个16bit)
        // 数据生成: 1, 2, 3, ... 64 (分8个块，每块32个FP16)
        for (int i = 0; i < TOTAL_BLOCKS; i++) {
            for (int j = 0; j < 32; j++) {
                // 生成简单的测试数据
                uint16_t fp16_val = (i * 32 + j + 1) & 0xFFFF;
                int byte_offset = i * 64 + (j / 2) * 4;
                int bit_offset = (j % 2) * 16;
                ((uint16_t*)((char*)src_data.get() + byte_offset))[0] |=
                    (fp16_val << bit_offset);
            }
            std::cout << "Block[" << i << "]: first=" << std::hex
                      << ((uint16_t*)((char*)src_data.get() + i * 64))[0] << std::dec << std::endl;
        }
    } else {
        // INT8 模式: 每个512bit块包含64个INT8数据
        // 数据生成: 交替正负数
        for (int i = 0; i < TOTAL_BLOCKS; i++) {
            for (int j = 0; j < 64; j++) {
                int8_t val;
                if (j % 2 == 0) {
                    val = (j / 2 + 1 + i * 2);  // 正数
                } else {
                    val = -(j / 2 + 1 + i * 2);  // 负数
                }
                ((int8_t*)src_data.get())[i * 64 + j] = val;
            }
            std::cout << "Block[" << i << "]: first=" << std::hex
                      << (int)((int8_t*)src_data.get())[i * 64] << std::dec << std::endl;
        }
    }
    mem_chunk.write(SRC_BASE_ADDR, (char*)src_data.get(), src_data_size);

    // *******************************************
    // @ Hadamard 算子寄存器配置
    // *******************************************
    std::cout << "\n=== Configuring Hadamard Registers ===" << std::endl;

    // 1. rfu_wreg2 (Addr 0x07): hd_data_width - 每次迭代处理的数据块数量
    fpai_device.defaultRegRegion().write(reg_base + 0x1C, HD_DATA_WIDTH, false);
    std::cout << "Write rfu_wreg2 (hd_data_width): " << HD_DATA_WIDTH << std::endl;

    // 2. rfu_wreg3 (Addr 0x08): hd_cal_percision - 0=INT8, 1=FP16
    fpai_device.defaultRegRegion().write(reg_base + 0x20, FP16_MODE, false);
    std::cout << "Write rfu_wreg3 (hd_cal_percision): " << FP16_MODE
              << " (" << (FP16_MODE ? "FP16" : "INT8") << ")" << std::endl;

    // 3. HD_RBASE_ADDR (Addr 0x32): 读基地址
    fpai_device.defaultRegRegion().write(reg_base + 0xC8, src_addr, false);
    std::cout << "Write HD_RBASE_ADDR: 0x" << std::hex << src_addr << std::dec << std::endl;

    // 4. HD_WBASE_ADDR (Addr 0x33): 写基地址
    fpai_device.defaultRegRegion().write(reg_base + 0xCC, dst_addr, false);
    std::cout << "Write HD_WBASE_ADDR: 0x" << std::hex << dst_addr << std::dec << std::endl;

    // 5. HD_WRSIZE_ADDR (Addr 0x34): 要处理的512bit数据块总数量
    fpai_device.defaultRegRegion().write(reg_base + 0xD0, TOTAL_BLOCKS, false);
    std::cout << "Write HD_WRSIZE_ADDR (total blocks): " << TOTAL_BLOCKS << std::endl;

    // 6. 启动 Hadamard 计算 (HD_COMP_START_ADDR = 0x31)
    fpai_device.defaultRegRegion().write(reg_base + 0xC4, 1, false);
    std::cout << "\nHadamard started..." << std::endl;

    // *******************************************
    // @ 等待完成
    // *******************************************
    auto start = std::chrono::system_clock::now();
    int done = 0;
    int during = 0;
    while (done == 0) {
        done = fpai_device.defaultRegRegion().read(reg_base + 0x100, false);
        auto end = std::chrono::system_clock::now();
        during = (int)std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();
        if (during > 10000) {
            std::cout << "Error: FPGA Time Out!" << std::endl;
            return -1;
        }
    }
    std::cout << "Hadamard completed in " << during << "ms" << std::endl;

    // *******************************************
    // @ 读取输出数据并验证
    // *******************************************
    std::cout << "\n=== Reading Output Data ===" << std::endl;
    mem_chunk.read((char*)dst_data.get(), DST_BASE_ADDR, dst_data_size);

    std::cout << "Output (first 4 blocks):" << std::endl;
    for (int i = 0; i < 4 && i < TOTAL_BLOCKS; i++) {
        uint64_t val = ((uint64_t*)((char*)dst_data.get() + i * 64))[0];
        std::cout << "Block[" << i << "]: 0x" << std::hex << val << std::dec
                  << " (first 64 bits)" << std::endl;
    }

    // 清理
    Device::Close(device);
    return 0;
}
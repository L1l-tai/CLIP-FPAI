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
#include <condition_variable>
#include <atomic>
#include <thread>
#include <functional>
#include <filesystem>

using namespace icraft::xrt;
using namespace icraft::xir;
using namespace std::chrono;
using namespace std::chrono_literals;
namespace fs = std::filesystem;
using namespace fpai;

int main(int argc, char *argv[])
{
    // FPAI设备初始化
    std::string device_url = "axi://zg330aiu?npu=0x40000000&dma=0x80000000";
    auto device = Device::Open(device_url.c_str());
    auto fpai_device = device.cast<FPAIDevice>();

    // Gather寄存器基地址
    uint32_t reg_base = 0x400C0000;

    // 读取Gather版本寄存器
    uint32_t version = fpai_device.defaultRegRegion().read(reg_base + 0xC0, false);
    std::cout << "Gather version is " << std::hex << "0x" << version << std::dec << std::endl;

    // *******************************************
    // @ Gather算子参数配置
    // *******************************************
    // 与gather_sim.sv中的参数保持一致
    const int INDICES_LEN = 20;           // 索引数量
    const int DATA_WIDTH_BEATS = 8;       // 每个元素的步长(beats)
    const int DATA_WIDTH_BYTES = DATA_WIDTH_BEATS * 64;  // 512 Bytes per element

    // 内存地址定义
    const uint32_t IDX_BASE_ADDR = 0x1000;   // 索引存储地址
    const uint32_t SRC_BASE_ADDR = 0x2000;    // 源数据存储地址
    const uint32_t DST_BASE_ADDR = 0x10000;   // 目的数据存储地址

    // 计算内存大小
    // Indices: 20 * 4 bytes = 80 bytes
    // Source Data: 32 * 512 bytes = 16384 bytes (每个element 512 bytes)
    // Dest Data: 20 * 512 bytes = 10240 bytes
    int indices_size = INDICES_LEN * 4;  // 80 bytes
    int src_data_size = 32 * DATA_WIDTH_BYTES;  // 16384 bytes
    int dst_data_size = INDICES_LEN * DATA_WIDTH_BYTES;  // 10240 bytes
    int total_size = indices_size + src_data_size + dst_data_size;

    // 分配内存
    std::shared_ptr<int8_t[]> indices = std::shared_ptr<int8_t[]>(new int8_t[indices_size]{ 0 });
    std::shared_ptr<int8_t[]> src_data = std::shared_ptr<int8_t[]>(new int8_t[src_data_size]{ 0 });
    std::shared_ptr<int8_t[]> dst_data = std::shared_ptr<int8_t[]>(new int8_t[dst_data_size]{ 0 });

    // 在FPGA内存中分配空间
    auto mem_chunk = fpai_device.defaultMemRegion().malloc(total_size, 0, 64);
    uint32_t mem_addr = mem_chunk->begin.addr();
    std::cout << "PL-DDR base addr: 0x" << std::hex << mem_addr << std::dec << std::endl;

    // 计算实际存储地址
    uint32_t idx_addr = mem_addr + IDX_BASE_ADDR;
    uint32_t src_addr = mem_addr + SRC_BASE_ADDR;
    uint32_t dst_addr = mem_addr + DST_BASE_ADDR;

    std::cout << "Indices base addr: 0x" << std::hex << idx_addr << std::dec << std::endl;
    std::cout << "Source data base addr: 0x" << std::hex << src_addr << std::dec << std::endl;
    std::cout << "Dest data base addr: 0x" << std::hex << dst_addr << std::dec << std::endl;

    // *******************************************
    // @ 准备Indices数据
    // *******************************************
    std::cout << "\n=== Loading Indices ===" << std::endl;
    for (int i = 0; i < INDICES_LEN; i++) {
        uint32_t idx_val = i % 16;  // 索引值
        ((uint32_t*)indices.get())[i] = idx_val;
        std::cout << "Index[" << i << "] = " << idx_val << std::endl;
    }
    mem_chunk.write(IDX_BASE_ADDR, (char*)indices.get(), indices_size);

    // *******************************************
    // @ 准备Source Data数据
    // *******************************************
    std::cout << "\n=== Loading Source Data ===" << std::endl;
    // 每个element占据DATA_WIDTH_BYTES(512 bytes)
    for (int i = 0; i < 32; i++) {
        uint32_t base_offset = SRC_BASE_ADDR + i * DATA_WIDTH_BYTES;
        // 每个element的第一个beat的低32位存储i
        ((uint32_t*)((char*)src_data.get() + base_offset))[0] = i;
        std::cout << "Src[" << i << "] @ offset 0x" << std::hex << base_offset
                  << " = " << std::dec << i << std::endl;
    }
    mem_chunk.write(SRC_BASE_ADDR, (char*)src_data.get(), src_data_size);

    // *******************************************
    // @ Gather算子寄存器配置
    // *******************************************
    std::cout << "\n=== Configuring Gather Registers ===" << std::endl;

    // 1. rfu_wreg0 (Addr 0x05): Indices数量 = 20
    fpai_device.defaultRegRegion().write(reg_base + 0x14, INDICES_LEN, false);
    std::cout << "Write rfu_wreg0 (Indices Len): " << INDICES_LEN << std::endl;

    // 2. rfu_wreg1 (Addr 0x06): Data步长 = 8 beats
    fpai_device.defaultRegRegion().write(reg_base + 0x18, DATA_WIDTH_BEATS, false);
    std::cout << "Write rfu_wreg1 (Data Width Beats): " << DATA_WIDTH_BEATS << std::endl;

    // 3. rbase1/rsize1 (Addr 0x01): Indices基地址和大小
    uint32_t reg_rsize1 = 2;  // 2 beats
    uint32_t reg_rbase1 = idx_addr & 0xFFFF;
    uint32_t reg_indices = (reg_rsize1 << 16) | reg_rbase1;
    fpai_device.defaultRegRegion().write(reg_base + 0x04, reg_indices, false);
    std::cout << "Write RSIZE1_BASE_ADDR: {rsize1:" << reg_rsize1
              << ", rbase1:0x" << std::hex << reg_rbase1 << "} = 0x" << reg_indices << std::dec << std::endl;

    // 4. wbase1 (Addr 0x02): 写基地址
    fpai_device.defaultRegRegion().write(reg_base + 0x08, dst_addr, false);
    std::cout << "Write WSIZE1_BASE_ADDR (Dest Base): 0x" << std::hex << dst_addr << std::dec << std::endl;

    // 5. rbase2 (Addr 0x03): 源数据读基地址
    fpai_device.defaultRegRegion().write(reg_base + 0x0C, src_addr, false);
    std::cout << "Write RSIZE2_BASE_ADDR (Src Base): 0x" << std::hex << src_addr << std::dec << std::endl;

    // 6. 启动Gather算子 (COMP_START_ADDR = 0x00)
    fpai_device.defaultRegRegion().write(reg_base + 0x00, 1, false);
    std::cout << "\nGather started..." << std::endl;

    // *******************************************
    // @ 等待完成
    // *******************************************
    auto start = std::chrono::system_clock::now();
    int done = 0;
    int during = 0;
    while (done == 0) {
        done = fpai_device.defaultRegRegion().read(reg_base + 0x80, false);
        auto end = std::chrono::system_clock::now();
        during = (int)std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();
        if (during > 10000) {
            std::cout << "Error: FPGA Time Out!" << std::endl;
            return -1;
        }
    }
    std::cout << "Gather completed in " << during << "ms" << std::endl;

    // *******************************************
    // @ 读取输出数据并验证
    // *******************************************
    std::cout << "\n=== Reading Output Data ===" << std::endl;
    mem_chunk.read((char*)dst_data.get(), DST_BASE_ADDR, dst_data_size);

    std::cout << "Output (first 8 elements):" << std::endl;
    for (int i = 0; i < 8 && i < INDICES_LEN; i++) {
        uint32_t base_offset = i * DATA_WIDTH_BYTES;
        uint32_t val = ((uint32_t*)((char*)dst_data.get() + base_offset))[0];
        uint32_t expected = i % 16;
        std::cout << "Dest[" << i << "] = " << val
                  << " (expected: " << expected << ")"
                  << (val == expected ? " [PASS]" : " [FAIL]") << std::endl;
    }

    // 清理
    Device::Close(device);
    return 0;
}
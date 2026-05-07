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

// Resize 寄存器地址 (对应 reg_ctrl.v 中的定义)
// 16'h41: RS_COMP_START_ADDR
// 16'h42: RS_RBASE_ADDR
// 16'h43: RS_WBASE_ADDR
// 16'h44: RS_RSIZE_ADDR
// 16'h45: RS_WSIZE_ADDR
// 16'h50: RS_COMP_DONE_ADDR
// 16'h09: rfu_wreg4 (resize_ratio_less)
// 16'h0a: rfu_wreg5 (resize_ratio_greater)

int main(int argc, char *argv[])
{
    // FPAI设备初始化
    std::string device_url = "axi://zg330aiu?npu=0x40000000&dma=0x80000000";
    auto device = Device::Open(device_url.c_str());
    auto fpai_device = device.cast<FPAIDevice>();

    // Resize 寄存器基地址
    uint32_t reg_base = 0x400C0000;

    // 读取 Resize 版本寄存器
    uint32_t version = fpai_device.defaultRegRegion().read(reg_base + 0x50, false);
    std::cout << "Resize version is " << std::hex << "0x" << version << std::dec << std::endl;

    // *******************************************
    // @ Resize 算子参数配置
    // *******************************************
    // 与 resize_sim.sv 中的参数保持一致

    // 源图像尺寸
    const int SRC_WIDTH = 64;
    const int SRC_HEIGHT = 64;

    // 目标图像尺寸
    const int DST_WIDTH = 32;
    const int DST_HEIGHT = 32;

    // 内存地址定义
    const uint32_t SRC_BASE_ADDR = 0x2000;    // 源图像存储地址
    const uint32_t DST_BASE_ADDR = 0x10000;   // 目标图像存储地址

    // 计算内存大小
    // 每行 64 bytes (16 像素 × 4 bytes)
    int src_row_size = (SRC_WIDTH + 3) / 4 * 64;  // 对齐到64字节
    int dst_row_size = (DST_WIDTH + 3) / 4 * 64;  // 对齐到64字节
    int src_data_size = src_row_size * SRC_HEIGHT;   // 源图像总大小
    int dst_data_size = dst_row_size * DST_HEIGHT;   // 目标图像总大小
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

    std::cout << "Source image base addr: 0x" << std::hex << src_addr << std::dec << std::endl;
    std::cout << "Dest image base addr: 0x" << std::hex << dst_addr << std::dec << std::endl;

    // *******************************************
    // @ 计算缩放比例
    // *******************************************
    // resize_ratio_less = wsize/rsize (<1, Q1.3.12: 1符号+3整数+12小数)
    // resize_ratio_greater = rsize/wsize (>1, Q1.7.8: 1符号+7整数+8小数)
    uint32_t resize_ratio_less = (DST_WIDTH << 12) / SRC_WIDTH;      // Q1.3.12格式
    uint32_t resize_ratio_greater = (SRC_WIDTH << 8) / DST_WIDTH;     // Q1.7.8格式
    std::cout << "\nResize ratio (Q format):" << std::endl;
    std::cout << "  resize_ratio_less: 0x" << std::hex << resize_ratio_less
              << " (Q1.3.12)" << std::dec << std::endl;
    std::cout << "  resize_ratio_greater: 0x" << std::hex << resize_ratio_greater
              << " (Q1.7.8)" << std::dec << std::endl;

    // *******************************************
    // @ 准备源图像数据
    // *******************************************
    std::cout << "\n=== Loading Source Image (" << SRC_WIDTH << "x" << SRC_HEIGHT << ") ===" << std::endl;

    for (int y = 0; y < SRC_HEIGHT; y++) {
        for (int x = 0; x < SRC_WIDTH; x++) {
            // 格式: {8'b0, R, G, B} - 每个像素32bit
            uint32_t pixel = (0 << 24) | ((x & 0xFF) << 16) | ((y & 0xFF) << 8) | ((x + y) >> 1);
            int row_offset = y * src_row_size;
            int col_offset = x * 4;
            ((uint32_t*)((char*)src_data.get() + row_offset))[0] = pixel;
        }
    }
    std::cout << "Source image loaded, first pixel = 0x"
              << std::hex << ((uint32_t*)src_data.get())[0] << std::dec << std::endl;
    mem_chunk.write(SRC_BASE_ADDR, (char*)src_data.get(), src_data_size);

    // *******************************************
    // @ Resize 算子寄存器配置
    // *******************************************
    std::cout << "\n=== Configuring Resize Registers ===" << std::endl;

    // 1. RS_RSIZE_ADDR (Addr 0x44): 源图像尺寸 {rwidth, rheight}
    // 格式: {rwidth[15:0], rheight[15:0]}
    uint32_t rsize = (SRC_WIDTH << 16) | SRC_HEIGHT;
    fpai_device.defaultRegRegion().write(reg_base + 0x110, rsize, false);
    std::cout << "Write RS_RSIZE_ADDR: 0x" << std::hex << rsize
              << " (width=" << SRC_WIDTH << ", height=" << SRC_HEIGHT << ")" << std::dec << std::endl;

    // 2. RS_WSIZE_ADDR (Addr 0x45): 目标图像尺寸 {wwidth, wheight}
    uint32_t wsize = (DST_WIDTH << 16) | DST_HEIGHT;
    fpai_device.defaultRegRegion().write(reg_base + 0x114, wsize, false);
    std::cout << "Write RS_WSIZE_ADDR: 0x" << std::hex << wsize
              << " (width=" << DST_WIDTH << ", height=" << DST_HEIGHT << ")" << std::dec << std::endl;

    // 3. RS_RBASE_ADDR (Addr 0x42): 源图像基地址
    fpai_device.defaultRegRegion().write(reg_base + 0x108, src_addr, false);
    std::cout << "Write RS_RBASE_ADDR: 0x" << std::hex << src_addr << std::dec << std::endl;

    // 4. RS_WBASE_ADDR (Addr 0x43): 目标图像基地址
    fpai_device.defaultRegRegion().write(reg_base + 0x10C, dst_addr, false);
    std::cout << "Write RS_WBASE_ADDR: 0x" << std::hex << dst_addr << std::dec << std::endl;

    // 5. rfu_wreg4 (Addr 0x09): resize_ratio_less (Q1.3.12格式)
    fpai_device.defaultRegRegion().write(reg_base + 0x24, resize_ratio_less, false);
    std::cout << "Write rfu_wreg4 (resize_ratio_less): 0x" << std::hex << resize_ratio_less << std::dec << std::endl;

    // 6. rfu_wreg5 (Addr 0x0a): resize_ratio_greater (Q1.7.8格式)
    fpai_device.defaultRegRegion().write(reg_base + 0x28, resize_ratio_greater, false);
    std::cout << "Write rfu_wreg5 (resize_ratio_greater): 0x" << std::hex << resize_ratio_greater << std::dec << std::endl;

    // 7. 启动 Resize 计算 (RS_COMP_START_ADDR = 0x41)
    fpai_device.defaultRegRegion().write(reg_base + 0x104, 1, false);
    std::cout << "\nResize started (Source: " << SRC_WIDTH << "x" << SRC_HEIGHT
              << " -> Dest: " << DST_WIDTH << "x" << DST_HEIGHT << ")..." << std::endl;

    // *******************************************
    // @ 等待完成
    // *******************************************
    auto start = std::chrono::system_clock::now();
    int done = 0;
    int during = 0;
    while (done == 0) {
        done = fpai_device.defaultRegRegion().read(reg_base + 0x140, false);
        auto end = std::chrono::system_clock::now();
        during = (int)std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();
        if (during > 30000) {  // Resize 相比 Hadamard 需要更长时间
            std::cout << "Error: FPGA Time Out!" << std::endl;
            return -1;
        }
    }
    std::cout << "Resize completed in " << during << "ms" << std::endl;

    // *******************************************
    // @ 读取输出数据并验证
    // *******************************************
    std::cout << "\n=== Reading Output Data ===" << std::endl;
    mem_chunk.read((char*)dst_data.get(), DST_BASE_ADDR, dst_data_size);

    std::cout << "Output image (" << DST_WIDTH << "x" << DST_HEIGHT << "):" << std::endl;
    for (int y = 0; y < 4 && y < DST_HEIGHT; y++) {
        int row_offset = y * dst_row_size;
        uint32_t pixel = ((uint32_t*)((char*)dst_data.get() + row_offset))[0];
        std::cout << "  Row[" << y << "]: first pixel = 0x" << std::hex << pixel << std::dec << std::endl;
    }

    // 清理
    Device::Close(device);
    return 0;
}
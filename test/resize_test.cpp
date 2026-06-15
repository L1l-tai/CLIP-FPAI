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

int main(int argc, char *argv[])
{
    std::string device_url = "axi://zg330aiu?npu=0x40000000&dma=0x80000000";
    auto device = Device::Open(device_url.c_str());
    auto fpai_device = device.cast<FPAIDevice>();

    uint32_t reg_base = 0x400C0000;

    uint32_t version = fpai_device.defaultRegRegion().read(reg_base + 0x1C0, false);
    std::cout << "Resize version is " << std::hex << "0x" << version << std::dec << std::endl;

    // ============================================================
    // 参数: 不使用 crop, 简单恒等缩放或缩小
    // ============================================================
    const int SRC_WIDTH = 64;
    const int SRC_HEIGHT = 64;
    const int DST_WIDTH = 32;
    const int DST_HEIGHT = 32;

    // 无 crop
    const int CROP_ENABLE = 0;

    // 每 64 字节块放 16 个 32-bit 像素
    int src_blocks_per_row = (SRC_WIDTH + 15) / 16;  // = 4
    int dst_blocks_per_row = (DST_WIDTH + 15) / 16;  // = 2
    int src_row_size = src_blocks_per_row * 64;   // 256 bytes/row
    int dst_row_size = dst_blocks_per_row * 64;   // 128 bytes/row
    int src_data_size = src_row_size * SRC_HEIGHT;   // 16384
    int dst_data_size = dst_row_size * DST_HEIGHT;   // 4096

    // Q 格式缩放比
    uint32_t resize_ratio_less    = (DST_WIDTH  << 12) / SRC_WIDTH;   // Q1.3.12
    uint32_t resize_ratio_greater = (SRC_WIDTH  << 8)  / DST_WIDTH;  // Q1.7.8

    // padding 防水
    const int PAD_SIZE = 4096;
    int src_offset = PAD_SIZE;
    int dst_offset = src_offset + src_data_size + PAD_SIZE;
    int total_size = dst_offset + dst_data_size + PAD_SIZE;

    std::shared_ptr<int8_t[]> src_buf(new int8_t[src_data_size]{0});
    std::shared_ptr<int8_t[]> dst_buf(new int8_t[dst_data_size]{0});

    auto mem_chunk = fpai_device.defaultMemRegion().malloc(total_size, 0, 64);
    uint32_t mem_addr = mem_chunk->begin.addr();
    std::cout << "PL-DDR base addr: 0x" << std::hex << mem_addr << std::dec << std::endl;

    uint32_t src_addr = mem_addr + src_offset;
    uint32_t dst_addr = mem_addr + dst_offset;
    std::cout << "Source addr: 0x" << std::hex << src_addr << std::dec << std::endl;
    std::cout << "Dest   addr: 0x" << std::hex << dst_addr << std::dec << std::endl;
    std::cout << "Layout: [pad:" << PAD_SIZE << "] [src:" << src_data_size
              << "] [pad:" << PAD_SIZE << "] [dst:" << dst_data_size
              << "] [pad:" << PAD_SIZE << "]" << std::endl;

    // ============================================================
    // 复位 FPGA
    // ============================================================
    std::cout << "\n=== Resetting FPGA logic ===" << std::endl;
    fpai_device.defaultRegRegion().write(reg_base + 0x1DC, 1, false);
    fpai_device.defaultRegRegion().write(reg_base + 0x1DC, 0, false);
    std::cout << "  Reset complete" << std::endl;

    // ============================================================
    // 预填充全部区域为已知递增模式
    // ============================================================
    std::cout << "\n=== Pre-filling entire region ===" << std::endl;
    {
        std::vector<int8_t> prefill(total_size);
        for (int i = 0; i < total_size; i++) {
            prefill[i] = (int8_t)(i & 0xFF);
        }
        mem_chunk.write(0, (char*)prefill.data(), total_size);
    }
    std::cout << "  All " << total_size << " bytes filled" << std::endl;

    // ============================================================
    // 生成已知源图像: pixel(x,y) = {0, R=x, G=y, B=0}
    // 逐像素填入, 格式: {8'b0, R[7:0], G[7:0], B[7:0]}
    // ============================================================
    std::cout << "\n=== Generating source image (" << SRC_WIDTH << "x"
              << SRC_HEIGHT << ") ===" << std::endl;
    for (int y = 0; y < SRC_HEIGHT; y++) {
        for (int x = 0; x < SRC_WIDTH; x++) {
            int row_off = y * src_row_size;
            int px_off  = x * 4;
            uint32_t pixel = (0 << 24) | ((x & 0xFF) << 16) | ((y & 0xFF) << 8) | 0x00;
            ((uint32_t*)(src_buf.get() + row_off + px_off))[0] = pixel;
        }
    }
    mem_chunk.write(src_offset, (char*)src_buf.get(), src_data_size);
    uint32_t first_px = ((uint32_t*)src_buf.get())[0];
    std::cout << "  First pixel = 0x" << std::hex << first_px
              << " (R=0, G=0, B=0)" << std::dec << std::endl;

    // ============================================================
    // 寄存器配置
    // ============================================================
    std::cout << "\n=== Configuring Resize Registers ===" << std::endl;

    // 0x44: {rwidth, rheight}
    uint32_t rsize_val = (SRC_WIDTH << 16) | SRC_HEIGHT;
    fpai_device.defaultRegRegion().write(reg_base + 0x110, rsize_val, false);
    std::cout << "  0x44 (rsize): " << SRC_WIDTH << "x" << SRC_HEIGHT << std::endl;

    // 0x45: {wwidth, wheight}
    uint32_t wsize_val = (DST_WIDTH << 16) | DST_HEIGHT;
    fpai_device.defaultRegRegion().write(reg_base + 0x114, wsize_val, false);
    std::cout << "  0x45 (wsize): " << DST_WIDTH << "x" << DST_HEIGHT << std::endl;

    // 0x42: rbase_rs
    fpai_device.defaultRegRegion().write(reg_base + 0x108, src_addr, false);
    std::cout << "  0x42 (rbase): 0x" << std::hex << src_addr << std::dec << std::endl;

    // 0x43: wbase_rs
    fpai_device.defaultRegRegion().write(reg_base + 0x10C, dst_addr, false);
    std::cout << "  0x43 (wbase): 0x" << std::hex << dst_addr << std::dec << std::endl;

    // 0x09: resize_ratio_less
    fpai_device.defaultRegRegion().write(reg_base + 0x24, resize_ratio_less, false);
    std::cout << "  0x09 (ratio_less): 0x" << std::hex << resize_ratio_less << std::dec << std::endl;

    // 0x0a: resize_ratio_greater
    fpai_device.defaultRegRegion().write(reg_base + 0x28, resize_ratio_greater, false);
    std::cout << "  0x0a (ratio_greater): 0x" << std::hex << resize_ratio_greater << std::dec << std::endl;

    // 0x0b: crop_enable = 0
    fpai_device.defaultRegRegion().write(reg_base + 0x2C, CROP_ENABLE, false);
    std::cout << "  0x0b (crop_enable): " << CROP_ENABLE << std::endl;

    // ============================================================
    // 启动并等待
    // ============================================================
    fpai_device.defaultRegRegion().write(reg_base + 0x104, 1, false);
    std::cout << "\nResize started..." << std::endl;

    auto start = std::chrono::system_clock::now();
    int done = 0;
    int last_state = -1;
    int last_wr_start = -1;
    int loop_cnt = 0;
    while (done == 0) {
        done = fpai_device.defaultRegRegion().read(reg_base + 0x140, false);
        auto end = std::chrono::system_clock::now();
        int during = (int)std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();

        // 每次循环都读 FSM 状态 (约每几十 us)
        uint32_t dbg3 = fpai_device.defaultRegRegion().read(reg_base + 0x90, false);
        int state = (dbg3 >> 11) & 0xF;
        int wr_start = (dbg3 >> 3) & 1;
        int rd_start = (dbg3 >> 4) & 1;
        if (state != last_state || wr_start != last_wr_start) {
            std::cout << "  [loop " << loop_cnt << ", t=" << during << "ms]"
                      << " state=" << state
                      << " wr=" << wr_start
                      << " rd=" << rd_start << std::endl;
            last_state = state;
            last_wr_start = wr_start;
        }
        loop_cnt++;

        if (during > 30000) {
            std::cout << "Error: FPGA Time Out! FSM state=" << last_state << std::endl;
            return -1;
        }
    }
    std::cout << "Resize completed." << std::endl;

    // ============================================================
    // 读 FSM debug 寄存器 (rfu_rreg3 = 0x24)
    // bit[14:11]=resize_state, [7]=resize_status, [3]=wr_start
    // ============================================================
    {
        uint32_t dbg3 = fpai_device.defaultRegRegion().read(reg_base + 0x90, false);
        std::cout << "\n=== FSM Debug (rfu_rreg3) ===" << std::endl;
        std::cout << "  Raw: 0x" << std::hex << dbg3 << std::dec << std::endl;
        std::cout << "  resize_state  = " << ((dbg3 >> 11) & 0xF)
                  << " (expect 0=IDLE)" << std::endl;
        std::cout << "  resize_status = " << ((dbg3 >> 7) & 1) << std::endl;
        std::cout << "  wr_start      = " << ((dbg3 >> 3) & 1) << std::endl;
        std::cout << "  rd_start      = " << ((dbg3 >> 4) & 1) << std::endl;
    }

    // ============================================================
    // 读回全部区域
    // ============================================================
    std::cout << "\n=== Reading back entire region ===" << std::endl;
    std::vector<int8_t> all_buf(total_size);
    mem_chunk.read((char*)all_buf.data(), 0, total_size);

    // ============================================================
    // 1. SRC 完整性
    // ============================================================
    std::cout << "\n=== SRC integrity ===" << std::endl;
    int src_corrupted = 0;
    for (int i = 0; i < src_data_size; i++) {
        if (all_buf[src_offset + i] != src_buf[i]) {
            src_corrupted++;
            if (src_corrupted == 1)
                std::cout << "  First corruption at src+" << i << std::endl;
        }
    }
    if (src_corrupted == 0)
        std::cout << "  SRC intact" << std::endl;
    else
        std::cout << "  SRC CORRUPTED: " << src_corrupted << " bytes" << std::endl;

    // ============================================================
    // 2. DST 是否全零
    // ============================================================
    std::cout << "\n=== DST data check ===" << std::endl;
    bool dst_all_zero = true;
    bool dst_has_data  = false;
    for (int i = 0; i < dst_data_size; i++) {
        if (all_buf[dst_offset + i] != 0) {
            dst_all_zero = false;
            dst_has_data = true;
            break;
        }
    }
    if (dst_all_zero) {
        std::cout << "  DST is ALL ZEROS - no data was written!" << std::endl;
    } else {
        // 检查是否全为预填充模式（说明完全没被覆盖）
        int unchanged = 0;
        for (int i = 0; i < dst_data_size; i++) {
            int8_t expected = (int8_t)((dst_offset + i) & 0xFF);
            if (all_buf[dst_offset + i] == expected) unchanged++;
        }
        if (unchanged > dst_data_size * 9 / 10) {
            std::cout << "  DST mostly UNCHANGED (" << unchanged << "/" << dst_data_size
                      << " bytes match prefill) - little to no data written" << std::endl;
        } else {
            std::cout << "  DST has data (" << unchanged << "/" << dst_data_size
                      << " bytes still match prefill)" << std::endl;
        }
    }

    // ============================================================
    // 3. DST 逐行检查
    // ============================================================
    std::cout << "\n=== DST first 8 rows (first pixel) ===" << std::endl;
    for (int y = 0; y < 8 && y < DST_HEIGHT; y++) {
        int boff = dst_offset + y * dst_row_size;
        uint32_t pixel = ((uint32_t*)(&all_buf[boff]))[0];
        // 预期: 缩小2倍, 第y行对应源图像第 y*ratio 行
        uint32_t expected_y = (uint32_t)(y * 64 / 32);  // SRC_HEIGHT/DST_HEIGHT = 2
        uint32_t expected_r = (expected_y * SRC_WIDTH / DST_WIDTH) & 0xFF;  // rough
        printf("  DST row[%d] pixel[0] = 0x%08X\n", y, pixel);
    }

    // ============================================================
    // 4. Padding 越界检测
    // ============================================================
    std::cout << "\n=== Padding overflow check ===" << std::endl;

    auto check_padding = [&](int start, int end, const char* name) {
        int modified = 0;
        for (int i = start; i < end; i++) {
            if (all_buf[i] != (int8_t)(i & 0xFF)) {
                modified++;
                if (modified == 1)
                    std::cout << "  " << name << " first mod at +0x"
                              << std::hex << (i - start) << std::dec << std::endl;
            }
        }
        std::cout << "  " << name << ": "
                  << (modified > 0 ? "MODIFIED (" + std::to_string(modified) + " bytes)"
                                   : "clean")
                  << std::endl;
    };

    // src 之前的 padding
    check_padding(0, src_offset, "Pad before src");
    // src 和 dst 之间的 padding
    check_padding(src_offset + src_data_size, dst_offset, "Pad between");
    // dst 之后的 padding
    check_padding(dst_offset + dst_data_size, total_size, "Pad after dst");

    // ============================================================
    // 5. 写入 .mem 文件
    // ============================================================
    mem_chunk.read((char*)dst_buf.get(), dst_offset, dst_data_size);
    auto now = std::chrono::system_clock::now();
    auto t = std::chrono::system_clock::to_time_t(now);
    std::string out_path = "test/output-data/hardware/resize-output-" + std::to_string(t) + ".mem";
    std::cout << "\nWriting output to " << out_path << std::endl;
    write_mem_file(out_path, dst_buf.get(), dst_data_size);

    Device::Close(device);
    return 0;
}

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
// 模式切换: 注释掉用 64x48 测试, 取消注释用 640x480 真实图像
// ============================================================
#define USE_REAL_IMAGE

// ---- 图像 → .mem 转换 ----
static void image_to_mem(const std::string& img_path, const std::string& mem_path,
                          int target_w, int target_h)
{
    cv::Mat img = cv::imread(img_path, cv::IMREAD_COLOR);
    if (img.empty()) {
        std::cerr << "Failed to load image: " << img_path << std::endl;
        return;
    }
    cv::Mat resized;
    cv::resize(img, resized, cv::Size(target_w, target_h), 0, 0, cv::INTER_LINEAR);

    int blocks_per_row = (target_w + 15) / 16;
    int total_bytes = blocks_per_row * 64 * target_h;
    std::vector<int8_t> buf(total_bytes, 0);

    for (int y = 0; y < target_h; y++) {
        for (int x = 0; x < target_w; x++) {
            cv::Vec3b bgr = resized.at<cv::Vec3b>(y, x);
            int block = x / 16;
            int px    = x % 16;
            int off   = y * blocks_per_row * 64 + block * 64 + px * 4;
            // RTL input order: [B, G, R, X]
            // [7:0]=B→blue, [15:8]=G→green, [23:16]=R→red
            buf[off + 0] = (int8_t)bgr[0];     // B → [7:0]
            buf[off + 1] = (int8_t)bgr[1];     // G → [15:8]
            buf[off + 2] = (int8_t)bgr[2];     // R → [23:16]
            buf[off + 3] = (int8_t)0x00;       // X → [31:24]
        }
    }
    write_mem_file(mem_path, buf.data(), total_bytes);
    std::cout << "Image " << target_w << "x" << target_h
              << " -> " << mem_path << " (" << total_bytes << " bytes)" << std::endl;
}

// ---- .mem → 图像转换 ----
static void mem_to_image(const std::string& mem_path, const std::string& img_path,
                          int width, int height)
{
    int blocks_per_row = (width + 15) / 16;
    int total_bytes = blocks_per_row * 64 * height;
    std::vector<int8_t> buf(total_bytes, 0);
    int loaded = read_mem_file(mem_path, buf.data(), total_bytes);
    if (loaded < 0) {
        std::cerr << "Failed to load " << mem_path << std::endl;
        return;
    }
    cv::Mat img(height, width, CV_8UC3);
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            int block = x / 16;
            int px    = x % 16;
            int off   = y * blocks_per_row * 64 + block * 64 + px * 4;
            // DDR [B, G, R, X] → OpenCV BGR
            img.at<cv::Vec3b>(y, x) = cv::Vec3b(
                (uint8_t)buf[off + 0],  // B
                (uint8_t)buf[off + 1],  // G
                (uint8_t)buf[off + 2]   // R
            );
        }
    }
    cv::imwrite(img_path, img);
    std::cout << "Output image " << width << "x" << height
              << " -> " << img_path << std::endl;
}

int main(int argc, char *argv[])
{
    std::string device_url = "axi://zg330aiu?npu=0x40000000&dma=0x80000000";
    auto device = Device::Open(device_url.c_str());
    auto fpai_device = device.cast<FPAIDevice>();

    uint32_t reg_base = 0x400C0000;

    uint32_t version = fpai_device.defaultRegRegion().read(reg_base + 0x1C0, false);
    std::cout << "Resize version is " << std::hex << "0x" << version << std::dec << std::endl;

    // ============================================================
    // 参数
    // ============================================================
#ifdef USE_REAL_IMAGE
    // CLIP ViT-B/32 标准预处理: 640x480 → 中心裁剪 480x480 → 缩放 224x224
    // crop_off_x=80, 16像素对齐 → DMA 地址 64B 对齐
    const int SRC_WIDTH  = 640;
    const int SRC_HEIGHT = 480;
    const int DST_WIDTH  = 224;
    const int DST_HEIGHT = 224;
    const int CROP_ENABLE = 1;
    const int CROP_SIZE = (SRC_WIDTH < SRC_HEIGHT) ? SRC_WIDTH : SRC_HEIGHT;  // 480

    uint32_t resize_ratio_less    = (DST_WIDTH  << 12) / CROP_SIZE;   // Q1.3.12
    uint32_t resize_ratio_greater = (CROP_SIZE  << 8)  / DST_WIDTH;  // Q1.7.8

    int src_blocks_per_row = (SRC_WIDTH  + 15) / 16;   // 40
    int dst_blocks_per_row = (DST_WIDTH  + 15) / 16;   // 14
    int src_data_size = src_blocks_per_row * 64 * SRC_HEIGHT;  // 1228800
    int dst_data_size = dst_blocks_per_row * 64 * DST_HEIGHT;  // 200704
#else
    // 调试用: 64x48 → 32x32, CROP_ENABLE=1
    const int SRC_WIDTH  = 64;
    const int SRC_HEIGHT = 48;
    const int DST_WIDTH  = 32;
    const int DST_HEIGHT = 32;
    const int CROP_ENABLE = 1;
    const int CROP_SIZE = (SRC_WIDTH < SRC_HEIGHT) ? SRC_WIDTH : SRC_HEIGHT;  // 48

    uint32_t resize_ratio_less    = (DST_WIDTH  << 12) / CROP_SIZE;   // Q1.3.12
    uint32_t resize_ratio_greater = (CROP_SIZE  << 8)  / DST_WIDTH;  // Q1.7.8

    int src_blocks_per_row = (SRC_WIDTH  + 15) / 16;   // 4
    int dst_blocks_per_row = (DST_WIDTH  + 15) / 16;   // 2
    int src_data_size = src_blocks_per_row * 64 * SRC_HEIGHT;  // 12288
    int dst_data_size = dst_blocks_per_row * 64 * DST_HEIGHT;  // 4096
#endif

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

#ifdef USE_REAL_IMAGE
    // 从真实图像生成 .mem 并加载
    const char* IMAGE_PATH = (argc > 1) ? argv[1] : "qtset/test_image.jpg";
    std::cout << "Input image: " << IMAGE_PATH << std::endl;
    const char* MEM_PATH   = "test/input-data/resize-input-640x480.mem";
    image_to_mem(IMAGE_PATH, MEM_PATH, SRC_WIDTH, SRC_HEIGHT);
    int loaded = read_mem_file(MEM_PATH, src_buf.get(), src_data_size);
    if (loaded < 0) {
        std::cerr << "Failed to load " << MEM_PATH << std::endl;
        return -1;
    }
    std::cout << "Loaded " << loaded << " bytes from " << MEM_PATH << std::endl;
#else
    // 从 .mem 文件加载源数据
    int loaded = read_mem_file("test/input-data/resize-input-src.mem", src_buf.get(), src_data_size);
    if (loaded < 0) {
        std::cerr << "Failed to load resize-input-src.mem" << std::endl;
        return -1;
    }
    std::cout << "Loaded " << loaded << " bytes from resize-input-src.mem" << std::endl;
#endif
    mem_chunk.write(src_offset, (char*)src_buf.get(), src_data_size);

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
    while (done == 0) {
        done = fpai_device.defaultRegRegion().read(reg_base + 0x140, false);
        auto end = std::chrono::system_clock::now();
        int during = (int)std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();
        if (during > 30000) {
            std::cout << "Timeout!" << std::endl;
            return -1;
        }
    }
    std::cout << "Resize completed." << std::endl;

    // ============================================================
    // 读回全部区域
    // ============================================================
    std::cout << "\n=== Reading back entire region ===" << std::endl;
    std::vector<int8_t> all_buf(total_size);
    mem_chunk.read((char*)all_buf.data(), 0, total_size);

    // ============================================================
    // 3. DST 逐行检查
    // ============================================================
    std::cout << "\n=== DST first 8 rows (first pixel) ===" << std::endl;
    for (int y = 0; y < 8 && y < DST_HEIGHT; y++) {
        int boff = dst_offset + y * dst_blocks_per_row * 64;
        uint32_t pixel = ((uint32_t*)(&all_buf[boff]))[0];
        printf("  DST row[%d] pixel[0] = 0x%08X\n", y, pixel);
    }

    // ============================================================
    // 写入 .mem 文件
    // ============================================================
    mem_chunk.read((char*)dst_buf.get(), dst_offset, dst_data_size);
    std::string out_mem = "test/output-data/hardware/resize-output-board.mem";
    std::string out_img = "test/output-data/hardware/resize-output-board.png";
    std::cout << "\nWriting output to " << out_mem << std::endl;
    write_mem_file(out_mem, dst_buf.get(), dst_data_size);
    mem_to_image(out_mem, out_img, DST_WIDTH, DST_HEIGHT);

    // 读取周期计数器 (RFU_RADDR2 = 0x23, AXI offset 0x8C)
    uint32_t cycle_cnt = fpai_device.defaultRegRegion().read(reg_base + 0x8C, false);
    std::cout << "Resize cycle count: " << cycle_cnt << " cycles ("
              << (cycle_cnt / 200.0) << " us @ 200MHz)" << std::endl;

    Device::Close(device);
    return 0;
}

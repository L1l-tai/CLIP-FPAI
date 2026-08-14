/* SDI Camera Capture: IMK → padded → FPGA Resize → 反量化 fp32 */

#include "pipeline/io/input/sdicamera.hpp"
#include "pipeline/memory/buffer_manager.hpp"

#include "et_device.hpp"
#include "compile_fpai_target.hpp"
#include <icraft-xrt/core/session.h>

#include "./op-func/op_resize.h"
#include "./op-func/op_resize.cpp"

#include <opencv2/opencv.hpp>
#include "yaml-cpp/yaml.h"

#include <iostream>
#include <vector>
#include <memory>
#include <cstring>
#include <cmath>

using namespace icraft::xrt;
using namespace icraft::xir;
using namespace fpai;

int main(int argc, char *argv[])
{
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0] << " <config yaml>" << std::endl;
        return 1;
    }

    YAML::Node config;
    try {
        config = YAML::LoadFile(argv[1]);
    } catch (const YAML::BadFile &e) {
        std::cerr << "Failed to load config: " << e.what() << std::endl;
        return -1;
    }

    const auto &sys_yaml = config["sys"];
    const auto &display_yaml = config["pipeline"]["display"];
    const auto &camera_yaml = config["pipeline"]["camera"];

    const int CAMERA_W = camera_yaml["width"].as<int>();
    const int CAMERA_H = camera_yaml["height"].as<int>();
    const bool VTC_ON = camera_yaml["vtc"] ? camera_yaml["vtc"].as<bool>() : false;
    const int FRAME_W = display_yaml["width"].as<int>();
    const int FRAME_H = display_yaml["height"].as<int>();

    const int NET_W = 640, NET_H = 480;
    const int DST_W = 224, DST_H = 224;

    auto device = Device::Open(sys_yaml["device"].as<std::string>().c_str());
    auto fpai_device = device.cast<FPAIDevice>();
    auto &reg = fpai_device.defaultRegRegion();

    auto camera = std::make_unique<GenericSDICamera>(
        0, fpai_device,
        CAMERA_W, CAMERA_H, camera_fmt::RGB565,
        FRAME_W, FRAME_H, camera_fmt::RGB565, crop_position::center,
        NET_W, NET_H, crop_position::center,
        0x40080000, VTC_ON);

    const int PS_SIZE = camera->getBufferSize();

    const size_t BUF_COUNT = 4;
    BufferManager buffer_mgr(BUF_COUNT);
    std::string chunk_grp = "input_udma_buff_camera0";
    buffer_mgr.createChunkGroup(chunk_grp, fpai_device, PS_SIZE);

    auto dummy_disp = fpai_device.getMemRegion("udma").malloc(PS_SIZE, false);
    reg.write(0x40080054, dummy_disp->begin.addr() >> 3);

    const int IMK_CH = 3;

    // CLIP ViT-B/32 预处理参数 → IMK MSC 寄存器
    const float mean_c[3] = {0.48145466f, 0.4578275f, 0.40821073f};   // RGB order
    const float std_c[3]  = {0.26862954f, 0.26130258f, 0.27577711f};
    const int clip_order[3] = {2, 1, 0};  // B,G,R → mean_c/std_c index
    uint32_t msc_val[3];
    int16_t mean_reg[3];
    uint16_t scale_reg[3];
    for (int i = 0; i < 3; i++) {
        int ci = clip_order[i];
        mean_reg[i] = (int16_t)std::round(mean_c[ci] * 255.0f - 128.0f);
        scale_reg[i] = (uint16_t)std::round(1024.0f / (std_c[ci] * 255.0f));
        msc_val[i] = ((uint32_t)(uint16_t)mean_reg[i] << 16) | scale_reg[i];
        std::cout << "MSC ch" << i << " ("
                  << (i==0?"B":i==1?"G":"R") << "): mean=" << mean_reg[i]
                  << " scale=" << scale_reg[i] << " reg=0x" << std::hex << msc_val[i] << std::dec << std::endl;
    }

    const int IMK_SIZE = NET_W * NET_H * IMK_CH;
    auto imk_mem = fpai_device.defaultMemRegion().malloc(IMK_SIZE + 4096, 0, 64);
    uint64_t imk_addr = imk_mem->begin.addr();
    std::cout << "IMK PL-DDR addr: 0x" << std::hex << imk_addr << std::dec
              << " size=" << IMK_SIZE << std::endl;

    // --- Resize 用 PL-DDR buffer ---
    const int RS_SRC_SIZE = NET_W * NET_H * 4;    // 640×480×4 ({0,B,G,R} padded)
    const int RS_DST_SIZE = DST_W * DST_H * 4;    // 224×224×4 ({0,B,G,R} padded)
    const int FINAL_SIZE   = DST_W * DST_H * 3 * (int)sizeof(float);  // fp32 BGR
    auto rs_src = fpai_device.defaultMemRegion().malloc(RS_SRC_SIZE + 4096, 0, 64);
    auto rs_dst = fpai_device.defaultMemRegion().malloc(RS_DST_SIZE + 4096, 0, 64);
    auto final_out = fpai_device.defaultMemRegion().malloc(FINAL_SIZE + 4096, 0, 64);
    uint64_t rs_src_addr = rs_src->begin.addr();
    uint64_t rs_dst_addr = rs_dst->begin.addr();
    uint64_t final_addr   = final_out->begin.addr();
    std::cout << "Resize src addr: 0x" << std::hex << rs_src_addr << std::dec << std::endl;
    std::cout << "Resize dst addr: 0x" << std::hex << rs_dst_addr << std::dec << std::endl;

    // --- IMK 初始化 ---
    const uint64_t IMK_BASE = 0x80000400;
    std::vector<float> empty_vec;
    uint64_t imk_ver = reg.read(IMK_BASE + 0x234);
    std::cout << "IMK version: 0x" << std::hex << imk_ver << std::dec
              << (imk_ver == 0x20220623 ? " (OK)" : " (UNEXPECTED)") << std::endl;

    auto take_one = [&](bool save) -> bool {
        int idx = buffer_mgr.requestIndex(chunk_grp);
        if (idx < 0) return false;
        auto &chunk = buffer_mgr.getChunk(chunk_grp, idx);

        reg.write(IMK_BASE + 0x114, imk_addr);
        initImageMake(fpai_device, 0, NET_W, NET_H, IMK_CH, imk_addr, 8, empty_vec, empty_vec);

        // bypass=1: IMK 不做预处理, 输出原始 BGR888 uint8
        reg.write(IMK_BASE + 0x254, 0x4);        // bit[2]=1 bypass

        camera->take(chunk);
        runImageMakeForward(fpai_device, 0, NET_W, NET_H, IMK_CH, imk_addr, 8);

        if (!camera->wait(500)) {
            std::cerr << "PS DMA fail" << std::endl;
            buffer_mgr.returnIndex(chunk_grp, idx);
            return false;
        }

        if (save) {
            // PS 通路: 保存 640x480 软件裁剪
            std::vector<uint8_t> ps(PS_SIZE);
            buffer_mgr.read(ps.data(), chunk, PS_SIZE);
            int cx = (FRAME_W - 640) / 2, cy = (FRAME_H - 480) / 2;
            cv::Mat full(FRAME_H, FRAME_W, CV_8UC2, ps.data());
            cv::Mat bgr_ps;
            cv::cvtColor(full(cv::Rect(cx, cy, 640, 480)).clone(), bgr_ps, cv::COLOR_BGR5652BGR);
            cv::imwrite("sdi_capture.png", bgr_ps);
            std::cout << "Saved sdi_capture.png" << std::endl;

            // ---- Step 1: 读 IMK BGR888 → 转 {0,B,G,R} padded → 写 rs_src ----
            std::vector<uint8_t> imk(IMK_SIZE);
            imk_mem.read((char *)imk.data(), 0, IMK_SIZE);

            std::vector<uint32_t> padded(NET_W * NET_H);
            for (int i = 0; i < NET_W * NET_H; i++) {
                padded[i] = (uint32_t)imk[i*3+2] << 16   // R → byte2
                          | (uint32_t)imk[i*3+1] << 8    // G → byte1
                          | (uint32_t)imk[i*3+0];         // B → byte0
            }
            // 保存 padded 后的图片 (640x480, 提取BGR + XOR128)
            {
                std::vector<uint8_t> imk_vis(NET_W * NET_H * 3);
                for (int i = 0; i < NET_W * NET_H; i++) {
                    uint32_t w = padded[i];  // 0x00RRGGBB → byte0=B,byte1=G,byte2=R
                    imk_vis[i*3+0] = (uint8_t)(w & 0xFF);           // B (raw uint8)
                    imk_vis[i*3+1] = (uint8_t)((w >> 8) & 0xFF);    // G
                    imk_vis[i*3+2] = (uint8_t)((w >> 16) & 0xFF);   // R
                }
                cv::imwrite("sdi_imk_padded.png", cv::Mat(NET_H, NET_W, CV_8UC3, imk_vis.data()));
                std::cout << "Saved sdi_imk_padded.png" << std::endl;
            }

            rs_src.write(0, (char *)padded.data(), RS_SRC_SIZE);

            // ---- Step 2: FPGA Resize 640×480 → 224×224 ----
            ResizeConfig rcfg;
            rcfg.src_addr = (uint32_t)rs_src_addr;
            rcfg.dst_addr = (uint32_t)rs_dst_addr;
            rcfg.src_w = NET_W;
            rcfg.src_h = NET_H;
            rcfg.dst_w = DST_W;
            rcfg.dst_h = DST_H;
            rcfg.crop_enable = 1;
                    uint32_t rs_cycles;
            if (!op_resize_run(&fpai_device, 0x400C0000, rcfg, 5000, &rs_cycles)) {
                std::cerr << "Resize failed!" << std::endl;
                return false;
            }

            // ---- Step 3-4: 读 resize 输出 → 反量化 int8 → fp32 ----
            std::vector<uint8_t> rs_out(RS_DST_SIZE);
            rs_dst.read((char *)rs_out.data(), 0, RS_DST_SIZE);

            // 保存 resize 后图片 (224x224, raw uint8 BGR, 无反量化)
            {
                std::vector<uint8_t> rs_vis(DST_W * DST_H * 3);
                for (int i = 0; i < DST_W * DST_H; i++) {
                    uint32_t w = ((uint32_t*)rs_out.data())[i];
                    rs_vis[i*3+0] = (uint8_t)(w & 0xFF);           // B
                    rs_vis[i*3+1] = (uint8_t)((w >> 8) & 0xFF);    // G
                    rs_vis[i*3+2] = (uint8_t)((w >> 16) & 0xFF);   // R
                }
                cv::imwrite("sdi_resize_raw.png", cv::Mat(DST_H, DST_W, CV_8UC3, rs_vis.data()));
                std::cout << "Saved sdi_resize_raw.png" << std::endl;
            }

            // ---- 软件 CLIP 预处理: uint8 BGR → fp32 CLIP 归一化 ----
            std::vector<float> fp32_bgr(DST_W * DST_H * 3);
            for (int i = 0; i < DST_W * DST_H; i++) {
                uint32_t w = ((uint32_t*)rs_out.data())[i];  // 0x00RRGGBB
                float b_u8 = (float)(w & 0xFF);              // byte0 = B
                float g_u8 = (float)((w >> 8) & 0xFF);       // byte1 = G
                float r_u8 = (float)((w >> 16) & 0xFF);      // byte2 = R

                // CLIP 归一化 BGR→RGB: mean_c/std_c 是 RGB 序
                // output: RGB interleaved (byte2=R→C0, byte1=G→C1, byte0=B→C2)
                fp32_bgr[i*3+0] = (r_u8 / 255.0f - mean_c[0]) / std_c[0];  // R
                fp32_bgr[i*3+1] = (g_u8 / 255.0f - mean_c[1]) / std_c[1];  // G
                fp32_bgr[i*3+2] = (b_u8 / 255.0f - mean_c[2]) / std_c[2];  // B
            }
            final_out.write(0, (char *)fp32_bgr.data(), FINAL_SIZE);
            std::cout << "CLIP fp32 BGR written to PL-DDR, " << FINAL_SIZE << " bytes" << std::endl;

            // ---- 保存可视化: 反归一化 clamp 到 uint8 ----
            {
                std::vector<uint8_t> vis(DST_W * DST_H * 3);
                for (int i = 0; i < DST_W * DST_H * 3; i++) {
                    float v = fp32_bgr[i] * 255.0f * std_c[i%3] + 255.0f * mean_c[i%3];
                    vis[i] = (uint8_t)std::max(0.0f, std::min(255.0f, v));
                }
                cv::imwrite("sdi_resized.png", cv::Mat(DST_H, DST_W, CV_8UC3, vis.data()));
                std::cout << "Saved sdi_resized.png (224x224, CLIP norm → uint8)" << std::endl;
            }

            // 保存 fp32 raw binary
            {
                std::ofstream f("sdi_fp32.bin", std::ios::binary);
                f.write((char *)fp32_bgr.data(), FINAL_SIZE);
                std::cout << "Saved sdi_fp32.bin (" << FINAL_SIZE << " bytes fp32)" << std::endl;
            }
        }

        buffer_mgr.returnIndex(chunk_grp, idx);
        return true;
    };

    for (int i = 0; i < 10; i++)
        if (!take_one(false)) { std::cerr << "warm-up fail" << std::endl; return -1; }
    if (!take_one(true)) { std::cerr << "capture fail" << std::endl; return -1; }

    Device::Close(device);
    return 0;
}
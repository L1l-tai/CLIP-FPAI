/* CLIP 模型预热: 完全模拟一次完整的 clip_dual 运行流程
 * 加载模型 → 文本编码 → 相机+HDMI → 视觉编码 → 退出
 * 用法: ./clip_warmup clip_config.yaml
 */
#include "icraft_utils.hpp"
#include "simple_tokenizer.hpp"
#include <icraft-xrt/core/session.h>
#include <opencv2/opencv.hpp>
#include <chrono>
#include <iostream>
#include <fstream>
#include <vector>
#include <mutex>
#include <atomic>
#include <thread>

#include "pipeline/actor/sdicamera_input_actor.hpp"
#include "pipeline/actor/hdmi_display_actor.hpp"
#include "pipeline/io/input/sdicamera.hpp"
#include "pipeline/memory/buffer_manager.hpp"
#include "pipeline/base/messages.hpp"
#include "pipeline/base/thread_safe_queue.hpp"
#include "et_device.hpp"
#include "compile_fpai_target.hpp"
#include "./op-func/op_resize.h"
#include "./op-func/op_resize.cpp"
#include "yaml-cpp/yaml.h"

using namespace icraft::xrt;
using namespace icraft::xir;
using namespace std::chrono;
using namespace fpai;

const int DIM = 512;

static void l2norm(std::vector<float>& v) {
    double s = 0;
    for (float x : v) s += (double)x * x;
    s = std::sqrt(s);
    if (s > 1e-12) for (float& x : v) x = (float)(x / s);
}
static std::vector<float> read_float_bin(const std::string& path, size_t count) {
    std::ifstream ifs(path, std::ios::binary);
    if (!ifs) { std::cerr << "[warmup] ERROR open " << path << std::endl; return {}; }
    std::vector<float> buf(count);
    ifs.read((char*)buf.data(), count * sizeof(float));
    return buf;
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0] << " <clip_config.yaml>" << std::endl;
        return 1;
    }

    YAML::Node cfg = YAML::LoadFile(argv[1]);
    std::string CAMERA_YAML = cfg["camera_yaml"].as<std::string>();
    std::string VIS_JSON    = cfg["vis_json"].as<std::string>();
    std::string VIS_RAW     = cfg["vis_raw"].as<std::string>();
    std::string TEXT_JSON   = cfg["text_json"].as<std::string>();
    std::string TEXT_RAW    = cfg["text_raw"].as<std::string>();
    std::string DATA_DIR    = cfg["data_dir"].as<std::string>();
    if (!DATA_DIR.empty() && DATA_DIR.back() != '/') DATA_DIR += "/";

    YAML::Node config = YAML::LoadFile(CAMERA_YAML);
    const auto& sys_yaml = config["sys"];

    // ============================================================
    // 1. 设备
    // ============================================================
    auto device = Device::Open(sys_yaml["device"].as<std::string>().c_str());
    auto fpai_device = device.cast<FPAIDevice>();

    // ============================================================
    // 2. Gather 内存分配
    // ============================================================
    const int SEQ = 77;
    const int DATA_WIDTH_BEATS = 32, INDICES_LEN = 1;
    int indices_beats = 1, indices_size = indices_beats * 64;
    int elem_size = DATA_WIDTH_BEATS * 64, src_data_size = SEQ * elem_size;
    int dst_data_size = INDICES_LEN * elem_size;
    const int PAD = 4096;
    int total = PAD + indices_size + PAD + src_data_size + PAD + dst_data_size + PAD;
    auto gather_chunk = fpai_device.defaultMemRegion().malloc(total, 0, 64);
    uint32_t mem_base = gather_chunk->begin.addr();
    uint32_t idx_addr = mem_base + PAD;
    uint32_t src_addr = mem_base + PAD + indices_size + PAD;
    uint32_t dst_addr = mem_base + PAD + indices_size + PAD + src_data_size + PAD;

    // ============================================================
    // 3. 加载模型
    // ============================================================
    std::cerr << "[warmup] loading text model..." << std::endl;
    auto text_network = loadNetwork(TEXT_JSON, TEXT_RAW);
    auto text_session = initSession("zg330", text_network, device, 4, true, true, false);
    text_session.apply();

    std::cerr << "[warmup] loading vision model..." << std::endl;
    auto vis_network = loadNetwork(VIS_JSON, VIS_RAW);
    auto vis_session = initSession("zg330", vis_network, device, 4, true, true, false);
    vis_session.apply();

    // ============================================================
    // 4. 文本编码 (触发 text 编译 + gather)
    // ============================================================
    SimpleTokenizer tok(DATA_DIR + "merges.txt");
    std::string prompt = "a photo of a cat";
    std::cerr << "[warmup] encoding: " << prompt << std::endl;

    auto token_emb = read_float_bin(DATA_DIR + "token_emb.bin", (size_t)49408 * DIM);
    auto pos_emb   = read_float_bin(DATA_DIR + "pos_emb.bin",   (size_t)SEQ * DIM);
    if (!token_emb.empty()) {
        auto ids = tok.tokenize(prompt);
        std::vector<float> mid_in((size_t)SEQ * DIM);
        int eot_idx = 0; int32_t maxv = ids[0];
        for (int i = 0; i < SEQ; i++) {
            int id = ids[i];
            for (int j = 0; j < DIM; j++)
                mid_in[(size_t)i*DIM + j] = token_emb[(size_t)id*DIM + j] + pos_emb[(size_t)i*DIM + j];
            if (ids[i] > maxv) { maxv = ids[i]; eot_idx = i; }
        }

        // Text warmup forward (触发编译)
        std::cerr << "[warmup] text warmup forward..." << std::endl;
        {
            Tensor in_w = data2Tensor(mid_in.data(), text_network.inputs()[0]);
            auto w = text_session.forward({in_w});
            for (auto& t : w) t.waitForReady(std::chrono::milliseconds(120000));
            device.reset(1);
        }
        // Text real forward
        std::cerr << "[warmup] text real forward..." << std::endl;
        Tensor in_r = data2Tensor(mid_in.data(), text_network.inputs()[0]);
        auto out = text_session.forward({in_r});
        for (auto& t : out) t.waitForReady(std::chrono::milliseconds(120000));
        device.reset(1);

        // Gather
        auto& reg = fpai_device.defaultRegRegion();
        uint32_t GB = 0x400C0000;
        reg.write(GB + 0x1DC, 1, false); std::this_thread::sleep_for(std::chrono::milliseconds(10));
        reg.write(GB + 0x1DC, 0, false); std::this_thread::sleep_for(std::chrono::milliseconds(10));

        auto out_host = out[0].to(HostDevice::MemRegion());
        const float* feat_seq = (const float*)out_host.data().cptr();
        std::vector<float> feat_seq_buf(feat_seq, feat_seq + (size_t)SEQ * DIM);

        std::vector<int8_t> idx_buf(indices_size, 0);
        idx_buf[0] = eot_idx & 0xFF; idx_buf[1] = (eot_idx>>8)&0xFF;
        idx_buf[2] = (eot_idx>>16)&0xFF; idx_buf[3] = (eot_idx>>24)&0xFF;
        gather_chunk.write(0, (char*)idx_buf.data(), indices_size);
        gather_chunk.write(indices_size + PAD, (char*)feat_seq_buf.data(), src_data_size);

        reg.write(GB + 0x14, INDICES_LEN, false);
        reg.write(GB + 0x18, DATA_WIDTH_BEATS, false);
        reg.write(GB + 0x04, (indices_beats<<16) | (idx_addr & 0xFFFF), false);
        reg.write(GB + 0x0C, src_addr, false);
        reg.write(GB + 0x08, dst_addr, false);
        reg.write(GB + 0x00, 1, false);

        auto t0 = system_clock::now();
        while (!reg.read(GB + 0x80, false)) {
            if (duration_cast<seconds>(system_clock::now() - t0).count() > 10) break;
        }
        device.reset(1);
        std::cerr << "[warmup] text encoding done" << std::endl;
    }

    // ============================================================
    // 5. 相机 + HDMI
    // ============================================================
    const auto& cam_y = config["pipeline"]["camera"];
    const auto& dsp_y = config["pipeline"]["display"];
    const int CW = cam_y["width"].as<int>(), CH = cam_y["height"].as<int>();
    const int DW = dsp_y["width"].as<int>(), DH = dsp_y["height"].as<int>();
    const bool VTC = cam_y["vtc"] ? cam_y["vtc"].as<bool>() : false;
    const int NET_W = 640, NET_H = 480, DST_SZ = 224;

    const size_t BC = 4;
    BufferManager bm(BC);
    ThreadSafeQueue<InputMessageForIcore> dq(BC);
    std::vector<Session> es;
    auto cam = std::make_unique<GenericSDICamera>(
        0, fpai_device, CW, CH, camera_fmt::RGB565,
        DW, DH, camera_fmt::RGB565, crop_position::center,
        NET_W, NET_H, crop_position::center, 0x40080000, VTC);
    SDICameraInputActor<FPAIDevice, FPAIBackend> ca(
        cam->getSourceId(), std::move(cam), fpai_device, bm, es, 0x80000400);
    ca.bindOutputQueue(&dq);

    auto imk_mem = fpai_device.defaultMemRegion().malloc(NET_W*NET_H*3+4096, 0, 64);
    auto rs_src  = fpai_device.defaultMemRegion().malloc(NET_W*NET_H*4+4096, 0, 64);
    auto rs_dst  = fpai_device.defaultMemRegion().malloc(DST_SZ*DST_SZ*4+4096, 0, 64);
    uint64_t imk_addr    = imk_mem->begin.addr();
    uint64_t rs_src_addr = rs_src->begin.addr();
    uint64_t rs_dst_addr = rs_dst->begin.addr();

    const float mean_c[3] = {0.48145466f, 0.4578275f, 0.40821073f};
    const float std_c[3]  = {0.26862954f, 0.26130258f, 0.27577711f};

    std::atomic<int> frame_cnt{0};
    std::atomic<bool> imk_armed{false};
    std::atomic<bool> warmup_done_flag{false};

    auto hd = std::make_unique<RGB565HDMIDisplay<FPAIDevice>>(0, fpai_device, DW, DH);
    HDMIDisplayActor<FPAIDevice, InputMessageForIcore> da(
        hd->getSinkId(), std::move(hd), fpai_device, bm, ca.getChunkGroupId(),
        [&](const InputMessageForIcore&, cv::Mat& f) {
            int n = frame_cnt.fetch_add(1);
            if (n % 10 == 0) {
                auto& reg = fpai_device.defaultRegRegion();
                if (imk_armed.load()) {
                    // 采集并编码一帧
                    runImageMakeForward(fpai_device, 0, NET_W, NET_H, 3, imk_addr, 8);
                    std::vector<uint8_t> imk(NET_W*NET_H*3);
                    imk_mem.read((char*)imk.data(), 0, NET_W*NET_H*3);
                    std::vector<uint32_t> padded(NET_W*NET_H);
                    for (int i = 0; i < NET_W*NET_H; i++)
                        padded[i] = (uint32_t)imk[i*3+2]<<16 | (uint32_t)imk[i*3+1]<<8 | imk[i*3+0];
                    rs_src.write(0, (char*)padded.data(), NET_W*NET_H*4);

                    ResizeConfig rcfg;
                    rcfg.src_addr=(uint32_t)rs_src_addr; rcfg.dst_addr=(uint32_t)rs_dst_addr;
                    rcfg.src_w=NET_W; rcfg.src_h=NET_H; rcfg.dst_w=DST_SZ; rcfg.dst_h=DST_SZ; rcfg.crop_enable=1;
                    uint32_t rs_cycles;
                    if (op_resize_run(&fpai_device, 0x400C0000, rcfg, 2000, &rs_cycles)) {
                        std::vector<uint8_t> rs_out(DST_SZ*DST_SZ*4);
                        rs_dst.read((char*)rs_out.data(), 0, DST_SZ*DST_SZ*4);
                        std::vector<float> fp32(DST_SZ*DST_SZ*3);
                        for (int i = 0; i < DST_SZ*DST_SZ; i++) {
                            uint32_t w = ((uint32_t*)rs_out.data())[i];
                            fp32[i*3+0] = ((float)((w>>16)&0xFF)/255.f - mean_c[2]) / std_c[2];
                            fp32[i*3+1] = ((float)((w>>8)&0xFF)/255.f - mean_c[1]) / std_c[1];
                            fp32[i*3+2] = ((float)(w&0xFF)/255.f - mean_c[0]) / std_c[0];
                        }
                        cv::Mat imgf(DST_SZ, DST_SZ, CV_32FC3, fp32.data());
                        Tensor t = CvMat2Tensor(imgf, vis_network, std::make_tuple(DST_SZ, DST_SZ, 3));
                        auto out = vis_session.forward({t});
                        for (auto& ot : out) ot.waitForReady(std::chrono::milliseconds(120000));
                        device.reset(1);

                        std::cerr << "[warmup] vision frame " << n
                                  << " resize=" << (rs_cycles/200.0) << "us" << std::endl;
                        warmup_done_flag.store(true);
                    }
                }
                // arm 下一次
                reg.write(0x80000400 + 0x114, imk_addr);
                std::vector<float> empty_vec;
                initImageMake(fpai_device, 0, NET_W, NET_H, 3, imk_addr, 8, empty_vec, empty_vec);
                reg.write(0x80000400 + 0x254, 0x4);
                imk_armed.store(true);
            }
        });
    da.bindInputQueue(&dq);
    ca.start(); da.start();
    std::cerr << "[warmup] camera+HDMI started, waiting for first vision frame..." << std::endl;

    // ============================================================
    // 6. 等待首帧视觉编码完成, 然后退出
    // ============================================================
    auto t_wait = system_clock::now();
    while (!warmup_done_flag.load()) {
        if (duration_cast<seconds>(system_clock::now() - t_wait).count() > 60) {
            std::cerr << "[warmup] timeout waiting for vision frame" << std::endl;
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    std::cerr << "[warmup] complete, shutting down (no Device::Close)..." << std::endl;
    std::cout << "[WEB] WARMUP_DONE" << std::endl;
    ca.stop(); da.stop();
    std::_Exit(0);
}

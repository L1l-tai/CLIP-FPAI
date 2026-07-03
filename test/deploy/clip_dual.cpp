/* CLIP Dual: 文本编码器 + 图像编码器联合调度 */

#include "icraft_utils.hpp"
#include <icraft-xrt/core/session.h>
#include <opencv2/opencv.hpp>
#include <chrono>
#include <iostream>
#include <fstream>
#include <vector>
#include <numeric>
#include <algorithm>
#include <cmath>
#include <string>
#include <tuple>
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

// ============================================================
// 通用工具
// ============================================================
static void l2norm(std::vector<float>& v) {
    double s = 0;
    for (float x : v) s += (double)x * x;
    s = std::sqrt(s);
    if (s > 1e-12) for (float& x : v) x = (float)(x / s);
}
static float cosine(const std::vector<float>& a, const std::vector<float>& b) {
    double dot = 0, na = 0, nb = 0;
    for (size_t i = 0; i < a.size(); ++i) { dot += a[i]*b[i]; na += a[i]*a[i]; nb += b[i]*b[i]; }
    if (na < 1e-12 || nb < 1e-12) return 0.f;
    return (float)(dot / (std::sqrt(na) * std::sqrt(nb)));
}

static std::vector<float> read_float_bin(const std::string& path, size_t count) {
    std::ifstream ifs(path, std::ios::binary);
    if (!ifs) { std::cerr << "[ERROR] open " << path << std::endl; return {}; }
    std::vector<float> buf(count);
    ifs.read((char*)buf.data(), count * sizeof(float));
    return buf;
}
static std::vector<int32_t> read_int32_bin(const std::string& path, size_t count) {
    std::ifstream ifs(path, std::ios::binary);
    std::vector<int32_t> buf(count);
    ifs.read((char*)buf.data(), count * sizeof(int32_t));
    return buf;
}

// ============================================================
// 文本编码器
// ============================================================
static std::vector<float> encode_text(
    const std::string& prompt, const std::string& data_dir,
    Device& device, Session& text_session,
    FPAIDevice& fpai_device, icraft::xrt::MemChunk& gather_chunk,
    uint32_t idx_addr, uint32_t src_addr, uint32_t dst_addr)
{
    const int VOCAB = 49408, SEQ = 77;
    const int DATA_WIDTH_BEATS = 32, INDICES_LEN = 1;
    int indices_beats = 1, indices_size = indices_beats * 64;
    int elem_size = DATA_WIDTH_BEATS * 64, src_data_size = SEQ * elem_size;

    // CPU 查表
    auto token_emb = read_float_bin(data_dir + "token_emb.bin", (size_t)VOCAB * DIM);
    auto pos_emb   = read_float_bin(data_dir + "pos_emb.bin",   (size_t)SEQ * DIM);
    auto input_ids = read_int32_bin(data_dir + "input_ids_" + prompt + ".bin", SEQ);
    if (token_emb.empty()) return {};

    std::vector<float> mid_in((size_t)SEQ * DIM);
    int eot_idx = 0; int32_t maxv = input_ids[0];
    for (int i = 0; i < SEQ; i++) {
        int id = input_ids[i];
        for (int j = 0; j < DIM; j++)
            mid_in[(size_t)i*DIM + j] = token_emb[(size_t)id*DIM + j] + pos_emb[(size_t)i*DIM + j];
        if (input_ids[i] > maxv) { maxv = input_ids[i]; eot_idx = i; }
    }

    // NPU 中间层
    Tensor in = data2Tensor(mid_in.data(), text_session->inputs[0]);
    auto out = text_session.forward({in});
    for (auto& t : out) t.waitForReady(std::chrono::milliseconds(5000));
    device.reset(1);

    auto out_host = out[0].to(HostDevice::MemRegion());
    const float* feat_seq = (const float*)out_host.data().cptr();
    std::vector<float> feat_seq_buf(feat_seq, feat_seq + (size_t)SEQ * DIM);

    // FPGA Gather
    auto& reg = fpai_device.defaultRegRegion();
    uint32_t REG_BASE = 0x400C0000;
    reg.write(REG_BASE + 0x1DC, 1, false); std::this_thread::sleep_for(std::chrono::milliseconds(10));
    reg.write(REG_BASE + 0x1DC, 0, false); std::this_thread::sleep_for(std::chrono::milliseconds(10));

    std::vector<int8_t> idx_buf(indices_size, 0);
    idx_buf[0] = eot_idx & 0xFF; idx_buf[1] = (eot_idx>>8)&0xFF;
    idx_buf[2] = (eot_idx>>16)&0xFF; idx_buf[3] = (eot_idx>>24)&0xFF;

    const int8_t* feat_bytes = (const int8_t*)feat_seq_buf.data();
    gather_chunk.write(0, (char*)idx_buf.data(), indices_size);
    gather_chunk.write(indices_size + 4096, (char*)feat_bytes, src_data_size);

    reg.write(REG_BASE + 0x14, INDICES_LEN, false);
    reg.write(REG_BASE + 0x18, DATA_WIDTH_BEATS, false);
    reg.write(REG_BASE + 0x04, (indices_beats<<16) | (idx_addr & 0xFFFF), false);
    reg.write(REG_BASE + 0x0C, src_addr, false);
    reg.write(REG_BASE + 0x08, dst_addr, false);
    reg.write(REG_BASE + 0x00, 1, false);

    auto t0 = system_clock::now();
    int done = 0;
    while (!done) {
        done = reg.read(REG_BASE + 0x80, false);
        if (duration_cast<milliseconds>(system_clock::now() - t0).count() > 10000) {
            std::cerr << "[TEXT] Gather timeout" << std::endl; return {};
        }
    }

    std::vector<float> eot_feat(DIM);
    gather_chunk.read((char*)eot_feat.data(), indices_size + 4096 + src_data_size + 4096, DIM * sizeof(float));

    // CPU 投影
    auto proj = read_float_bin(data_dir + "text_proj.bin", (size_t)DIM * DIM);
    std::vector<float> text_feat(DIM, 0.f);
    for (int i = 0; i < DIM; i++) {
        float s = 0;
        for (int k = 0; k < DIM; k++) s += eot_feat[k] * proj[(size_t)k*DIM + i];
        text_feat[i] = s;
    }
    std::cout << "[TEXT] prompt='" << prompt << "' feat[0..4]: ";
    for (int i=0;i<5;i++) std::cout << text_feat[i] << " ";
    std::cout << std::endl;
    return text_feat;
}

// ============================================================
// main
// ============================================================
int main(int argc, char* argv[])
{
    std::cerr << "=== CLIP Dual: text + vision ===" << std::endl;

    const std::string TEXT_FEAT_FILE = "configs/clip_text_features.bin";
    const std::string LABELS_FILE    = "configs/clip_labels.txt";
    const int NUM_TEXT = 5;

    // ---------- file 模式 ----------
    if (argc < 2 || std::string(argv[1]) != "dual") {
        std::cerr << "Usage: " << argv[0]
                  << " dual <config_yaml> <vis_json> <vis_raw> <text_json> <text_raw> <data_dir> [prompt]" << std::endl;
        return 1;
    }
    // dual <config_yaml> <vis_json> <vis_raw> <text_json> <text_raw> <data_dir> <labels_txt>
    if (argc < 9) { std::cerr << "Need 8 args" << std::endl; return 1; }
    std::string yaml_path  = argv[2];
    std::string VIS_JSON   = argv[3];
    std::string VIS_RAW    = argv[4];
    std::string TEXT_JSON  = argv[5];
    std::string TEXT_RAW   = argv[6];
    std::string DATA_DIR   = argv[7];
    std::string LABELS_FILE = argv[8];

    YAML::Node config;
    try { config = YAML::LoadFile(yaml_path); }
    catch (const YAML::BadFile& e) { std::cerr << "YAML fail" << std::endl; return -1; }

    // ---- 设备 ----
    const auto& sys_yaml = config["sys"];
    auto device = Device::Open(sys_yaml["device"].as<std::string>().c_str());
    auto fpai_device = device.cast<FPAIDevice>();

    // ---- 双模型加载 ----
    std::cerr << "[main] loading text model..." << std::endl;
    auto text_network = loadNetwork(TEXT_JSON, TEXT_RAW);
    auto text_session = initSession("zg330", text_network, device, 4, true, true, false);
    text_session.apply();

    std::cerr << "[main] loading vision model..." << std::endl;
    auto vis_network = loadNetwork(VIS_JSON, VIS_RAW);
    auto vis_session = initSession("zg330", vis_network, device, 4, true, true, false);
    vis_session.apply();

    // ---- 文本编码器 PL-DDR (提前分配, 抢占低地址) ----
    const int SEQ = 77;
    const int DATA_WIDTH_BEATS = 32, INDICES_LEN = 1;
    int indices_beats = 1, indices_size = indices_beats * 64;
    int elem_size = DATA_WIDTH_BEATS * 64, src_data_size = SEQ * elem_size;
    int dst_data_size = INDICES_LEN * elem_size;
    const int PAD = 4096;
    int idx_offset = 0;
    int src_offset = idx_offset + indices_size + PAD;
    int dst_offset = src_offset + src_data_size + PAD;
    int text_total = dst_offset + dst_data_size + PAD;
    auto gather_chunk = fpai_device.defaultMemRegion().malloc(text_total, 0, 64);
    uint32_t mem_base = gather_chunk->begin.addr();
    uint32_t idx_addr = mem_base + idx_offset;
    uint32_t src_addr = mem_base + src_offset;
    uint32_t dst_addr = mem_base + dst_offset;
    std::cerr << "[main] gather mem: base=0x" << std::hex << mem_base << std::dec << std::endl;

    // ---- 读取标签列表 + 批量文本编码 ----
    const std::string LABELS_FILE = "configs/clip_labels.txt";
    std::vector<std::string> labels;
    {
        std::ifstream ifs(LABELS_FILE);
        std::string line;
        while (std::getline(ifs, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (!line.empty()) labels.push_back(line);
        }
    }
    if (labels.empty()) { labels = {init_prompt}; }
    std::cerr << "[main] encoding " << labels.size() << " prompts..." << std::endl;

    std::vector<std::vector<float>> text_feats;
    for (const auto& prompt : labels) {
        std::cerr << "  encoding: " << prompt << std::endl;
        auto feat = encode_text(prompt, DATA_DIR, device, text_session,
                                fpai_device, gather_chunk, idx_addr, src_addr, dst_addr);
        if (!feat.empty()) text_feats.push_back(feat);
    }
    std::cerr << "[main] text features ready: " << text_feats.size() << std::endl;

    // ---- 相机 + HDMI (在 NPU 加载后, 但使用不同的 NPU session, 不影响) ----
    const auto& cam_y = config["pipeline"]["camera"];
    const auto& dsp_y = config["pipeline"]["display"];
    const int CW = cam_y["width"].as<int>(), CH = cam_y["height"].as<int>();
    const int DW = dsp_y["width"].as<int>(), DH = dsp_y["height"].as<int>();
    const bool VTC = cam_y["vtc"] ? cam_y["vtc"].as<bool>() : false;
    const size_t BC = 4;
    BufferManager bm(BC);
    ThreadSafeQueue<InputMessageForIcore> dq(BC);
    std::vector<Session> es;
    auto cam = std::make_unique<GenericSDICamera>(
        0, fpai_device, CW, CH, camera_fmt::RGB565,
        DW, DH, camera_fmt::RGB565, crop_position::center,
        640, 480, crop_position::center, 0x40080000, VTC);
    SDICameraInputActor<FPAIDevice, FPAIBackend> ca(
        cam->getSourceId(), std::move(cam), fpai_device, bm, es, 0x80000400);
    ca.bindOutputQueue(&dq);

    // ---- 视觉预处理参数 ----
    const float mean_c[3] = {0.48145466f, 0.4578275f, 0.40821073f};
    const float std_c[3]  = {0.26862954f, 0.26130258f, 0.27577711f};
    const int CLIP_INTV = 10, DST_SZ = 224, NET_W = 640, NET_H = 480;

    auto imk_mem = fpai_device.defaultMemRegion().malloc(NET_W*NET_H*3+4096, 0, 64);
    auto rs_src  = fpai_device.defaultMemRegion().malloc(NET_W*NET_H*4+4096, 0, 64);
    auto rs_dst  = fpai_device.defaultMemRegion().malloc(DST_SZ*DST_SZ*4+4096, 0, 64);
    uint64_t imk_addr   = imk_mem->begin.addr();
    uint64_t rs_src_addr = rs_src->begin.addr();
    uint64_t rs_dst_addr = rs_dst->begin.addr();
    const uint64_t IMK_BASE = 0x80000400;

    // 共享状态
    std::mutex label_mutex;
    std::string top1_label = labels.empty() ? "N/A" : labels[0];
    std::atomic<int> frame_cnt{0};
    std::atomic<bool> imk_armed{false};
    std::atomic<bool> new_text_pending{false};
    std::string new_prompt;

    auto hd = std::make_unique<RGB565HDMIDisplay<FPAIDevice>>(0, fpai_device, DW, DH);
    HDMIDisplayActor<FPAIDevice, InputMessageForIcore> da(
        hd->getSinkId(), std::move(hd), fpai_device, bm, ca.getChunkGroupId(),
        [&](const InputMessageForIcore&, cv::Mat& f) {
            int n = frame_cnt.fetch_add(1);

            // 检查新文本输入 (poll stdin, 非阻塞)
            if (!new_text_pending.load()) {
                // peek stdin without blocking (use select/fcntl approach)
                // For simplicity: check every CLIP cycle
            }
            if (new_text_pending.load()) {
                std::string prompt;
                {
                    prompt = new_prompt;
                    new_text_pending.store(false);
                }
                std::cerr << "[TEXT] encoding new prompt: " << prompt << std::endl;
                auto feat = encode_text(prompt, DATA_DIR, device, text_session,
                                        fpai_device, gather_chunk, idx_addr, src_addr, dst_addr);
                if (!feat.empty()) {
                    std::lock_guard<std::mutex> lk(label_mutex);
                    labels.push_back(prompt);
                    text_feats.push_back(feat);
                    std::cerr << "[TEXT] added '" << prompt << "', now " << labels.size() << " classes" << std::endl;
                }
            }

            if (n % CLIP_INTV == 0) {
                auto& reg = fpai_device.defaultRegRegion();

                if (imk_armed.load()) {
                    runImageMakeForward(fpai_device, 0, NET_W, NET_H, 3, imk_addr, 8);
                    std::vector<uint8_t> imk(NET_W*NET_H*3);
                    imk_mem.read((char*)imk.data(), 0, NET_W*NET_H*3);
                    std::vector<uint32_t> padded(NET_W*NET_H);
                    for (int i = 0; i < NET_W*NET_H; i++)
                        padded[i] = (uint32_t)imk[i*3+2]<<16 | (uint32_t)imk[i*3+1]<<8 | imk[i*3+0];
                    rs_src.write(0, (char*)padded.data(), NET_W*NET_H*4);

                    ResizeConfig rcfg;
                    rcfg.src_addr = (uint32_t)rs_src_addr; rcfg.dst_addr = (uint32_t)rs_dst_addr;
                    rcfg.src_w = NET_W; rcfg.src_h = NET_H;
                    rcfg.dst_w = DST_SZ; rcfg.dst_h = DST_SZ;
                    rcfg.crop_enable = 1;
                    if (op_resize_run(&fpai_device, 0x400C0000, rcfg, 2000)) {
                        std::vector<uint8_t> rs_out(DST_SZ*DST_SZ*4);
                        rs_dst.read((char*)rs_out.data(), 0, DST_SZ*DST_SZ*4);
                        std::vector<float> fp32_rgb(DST_SZ*DST_SZ*3);
                        for (int i = 0; i < DST_SZ*DST_SZ; i++) {
                            uint32_t w = ((uint32_t*)rs_out.data())[i];
                            fp32_rgb[i*3+0] = ((float)((w>>16)&0xFF)/255.f - mean_c[0]) / std_c[0];
                            fp32_rgb[i*3+1] = ((float)((w>>8)&0xFF)/255.f - mean_c[1]) / std_c[1];
                            fp32_rgb[i*3+2] = ((float)(w&0xFF)/255.f - mean_c[2]) / std_c[2];
                        }
                        cv::Mat imgf(DST_SZ, DST_SZ, CV_32FC3, fp32_rgb.data());
                        Tensor t = CvMat2Tensor(imgf, vis_network, std::make_tuple(DST_SZ, DST_SZ, 3));
                        auto out = vis_session.forward({t});
                        for (auto& ot : out) ot.waitForReady(std::chrono::milliseconds(5000));
                        auto emb_t = out[0].to(HostDevice::MemRegion());
                        std::vector<float> emb((const float*)emb_t.data().cptr(),
                                               (const float*)emb_t.data().cptr()+DIM);
                        l2norm(emb);
                        int best_i = 0; float best_s = -2.f;
                        {
                            std::lock_guard<std::mutex> lk(label_mutex);
                            for (int i = 0; i < (int)text_feats.size(); ++i) {
                                auto tf = text_feats[i]; l2norm(tf);
                                float s = cosine(emb, tf);
                                if (s > best_s) { best_s = s; best_i = i; }
                            }
                            if (best_i < (int)labels.size()) top1_label = labels[best_i];
                        }
                        std::cout << "[VIS] frame " << n << " top1=" << top1_label << std::endl;
                    }
                    device.reset(1);
                }

                reg.write(IMK_BASE + 0x114, imk_addr);
                std::vector<float> empty_vec;
                initImageMake(fpai_device, 0, NET_W, NET_H, 3, imk_addr, 8, empty_vec, empty_vec);
                reg.write(IMK_BASE + 0x254, 0x4);
                imk_armed.store(true);
            }
            {
                std::lock_guard<std::mutex> lk(label_mutex);
                cv::putText(f, top1_label, cv::Point(50, 100),
                            cv::FONT_HERSHEY_DUPLEX, 2.0, cv::Scalar(0, 255, 0), 3);
            }
        });
    da.bindInputQueue(&dq);
    ca.start(); da.start();
    std::cerr << "[main] dual encoder running" << std::endl;

    // 主线程: 处理 stdin 新文本输入
    std::cout << "\n=== Enter new prompt (or empty to quit) ===" << std::endl;
    std::string line;
    while (std::getline(std::cin, line)) {
        if (line.empty()) break;
        new_prompt = line;
        new_text_pending.store(true);
        std::cout << "[main] queued: " << line << std::endl;
    }

    ca.stop(); da.stop();
    Device::Close(device);
    return 0;
}

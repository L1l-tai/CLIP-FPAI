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

using namespace icraft::xrt;
using namespace icraft::xir;
using namespace std::chrono;
using namespace fpai;

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

static void print_matches(const std::vector<float>& img_emb,
                          const std::vector<std::vector<float>>& text_feats,
                          const std::vector<std::string>& labels,
                          const std::string& tag) {
    const int NUM_TEXT = (int)text_feats.size();
    const int DIM = 512;
    const float TEMP = 100.0f;

    auto emb = img_emb;
    l2norm(emb);
    std::vector<float> sims(NUM_TEXT);
    for (int i = 0; i < NUM_TEXT; ++i) {
        auto tf = text_feats[i];
        l2norm(tf);
        sims[i] = cosine(emb, tf);
    }
    std::vector<float> probs(NUM_TEXT);
    float maxs = *std::max_element(sims.begin(), sims.end());
    float sum = 0;
    for (int i = 0; i < NUM_TEXT; ++i) { probs[i] = std::exp((sims[i]-maxs)*TEMP); sum += probs[i]; }
    for (int i = 0; i < NUM_TEXT; ++i) probs[i] /= sum;

    std::vector<int> idx(NUM_TEXT);
    std::iota(idx.begin(), idx.end(), 0);
    std::sort(idx.begin(), idx.end(), [&](int a, int b){ return sims[a] > sims[b]; });

    std::cout << "\n==== [" << tag << "] 图文匹配结果 ====\n";
    for (int r = 0; r < NUM_TEXT; ++r) {
        int i = idx[r];
        std::string name = (i < (int)labels.size()) ? labels[i] : ("text" + std::to_string(i));
        printf("  %-12s  cos=%.4f   prob=%.4f%s\n",
               name.c_str(), sims[i], probs[i], (r==0 ? "   <== Top-1" : ""));
    }
}


// ============================================================
// main
// ============================================================
int main(int argc, char* argv[])
{
    std::cerr << "=== BUILD TAG: golden-v3 (cmdline) ===" << std::endl;

    const std::string TEXT_FEAT = "configs/clip_text_features.bin";
    const std::string LABELS    = "configs/clip_labels.txt";
    const int DIM = 512;
    const int NUM_TEXT = 5;

    // ---------- 模式分发 ----------
    if (argc >= 3 && std::string(argv[1]) == "camera") {
        std::cerr << "[main] camera mode selected" << std::endl;
        // camera <config_yaml> <json> <raw> <tag>
        if (argc < 6) {
            std::cerr << "用法: " << argv[0] << " camera <config_yaml> <json> <raw> <tag>" << std::endl;
            return 1;
        }
        std::string yaml_path = argv[2];
        std::string JSON = argv[3];
        std::string RAW  = argv[4];
        std::string tag   = argv[5];

        YAML::Node config;
        try { config = YAML::LoadFile(yaml_path); }
        catch (const YAML::BadFile& e) {
            std::cerr << "Failed to load: " << yaml_path << std::endl;
            return -1;
        }
        const auto& sys_yaml = config["sys"];
        std::cerr << "[main] opening device..." << std::endl;
        auto device = Device::Open(sys_yaml["device"].as<std::string>().c_str());
        std::cerr << "[main] device opened" << std::endl;
        auto fpai_device = device.cast<FPAIDevice>();
        std::cerr << "[main] fpai_device cast OK" << std::endl;

        // 先启动 camera+HDMI (在 NPU 加载前占据硬件通路，和 sdi_to_hdmi 一致)
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
        auto hd = std::make_unique<RGB565HDMIDisplay<FPAIDevice>>(0, fpai_device, DW, DH);
        // CLIP 预处理参数
        const float mean_c[3] = {0.48145466f, 0.4578275f, 0.40821073f};
        const float std_c[3]  = {0.26862954f, 0.26130258f, 0.27577711f};
        const int CLIP_INTV = 10;
        const int DST_SZ = 224;
        const int DIM = 512;
        const int NET_W = 640, NET_H = 480;

        // 加载 CLIP 网络 (必须在 camera start 之前, 因为 session 对象需要在 lambda 中引用)
        std::cerr << "[main] loading network: " << JSON << std::endl;
        auto network = loadNetwork(JSON, RAW);
        auto session = initSession("zg330", network, device, 4, true, true, false);
        session.apply();
        std::cerr << "[main] session ready, loading text features..." << std::endl;

        // 读文本特征
        std::vector<std::vector<float>> text_feats(NUM_TEXT, std::vector<float>(DIM));
        { std::ifstream ifs(TEXT_FEAT, std::ios::binary);
          for (int i = 0; i < NUM_TEXT; ++i) ifs.read((char*)text_feats[i].data(), DIM*sizeof(float)); }
        std::vector<std::string> labels;
        { std::ifstream ifs(LABELS); std::string line;
          while (std::getline(ifs, line)) { if (!line.empty() && line.back()=='\r') line.pop_back(); if (!line.empty()) labels.push_back(line); } }

        // IMK + Resize PL-DDR buffers
        auto imk_mem = fpai_device.defaultMemRegion().malloc(NET_W*NET_H*3+4096, 0, 64);
        auto rs_src  = fpai_device.defaultMemRegion().malloc(NET_W*NET_H*4+4096, 0, 64);
        auto rs_dst  = fpai_device.defaultMemRegion().malloc(DST_SZ*DST_SZ*4+4096, 0, 64);
        uint64_t imk_addr   = imk_mem->begin.addr();
        uint64_t rs_src_addr = rs_src->begin.addr();
        uint64_t rs_dst_addr = rs_dst->begin.addr();
        const uint64_t IMK_BASE = 0x80000400;

        // 共享状态
        std::mutex label_mutex;
        std::string top1_label = "CLIP...";
        std::atomic<int> frame_cnt{0};
        std::atomic<bool> imk_armed{false};  // IMK 已为下一帧配置好

        HDMIDisplayActor<FPAIDevice, InputMessageForIcore> da(
            hd->getSinkId(), std::move(hd), fpai_device, bm, ca.getChunkGroupId(),
            [&](const InputMessageForIcore&, cv::Mat& f) {
                int n = frame_cnt.fetch_add(1);
                if (n % CLIP_INTV == 0) {
                    auto& reg = fpai_device.defaultRegRegion();

                    // Step A: 收上一帧的 IMK 结果 (如果已配置)
                    if (imk_armed.load()) {
                        runImageMakeForward(fpai_device, 0, NET_W, NET_H, 3, imk_addr, 8);
                        // 读 IMK → padded
                        std::vector<uint8_t> imk(NET_W*NET_H*3);
                        imk_mem.read((char*)imk.data(), 0, NET_W*NET_H*3);
                        std::vector<uint32_t> padded(NET_W*NET_H);
                        for (int i = 0; i < NET_W*NET_H; i++)
                            padded[i] = (uint32_t)imk[i*3+2]<<16 | (uint32_t)imk[i*3+1]<<8 | imk[i*3+0];
                        rs_src.write(0, (char*)padded.data(), NET_W*NET_H*4);

                        // FPGA Resize
                        ResizeConfig rcfg;
                        rcfg.src_addr = (uint32_t)rs_src_addr; rcfg.dst_addr = (uint32_t)rs_dst_addr;
                        rcfg.src_w = NET_W; rcfg.src_h = NET_H;
                        rcfg.dst_w = DST_SZ; rcfg.dst_h = DST_SZ;
                        rcfg.crop_enable = 1;
                        if (op_resize_run(&fpai_device, 0x400C0000, rcfg, 2000)) {
                            // CLIP norm fp32
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
                            Tensor t = CvMat2Tensor(imgf, network, std::make_tuple(DST_SZ, DST_SZ, 3));
                            auto out = session.forward({t});
                            for (auto& ot : out) ot.waitForReady(std::chrono::milliseconds(5000));
                            auto emb_t = out[0].to(HostDevice::MemRegion());
                            std::vector<float> emb((const float*)emb_t.data().cptr(),
                                                   (const float*)emb_t.data().cptr()+DIM);
                            l2norm(emb);
                            int best_i = 0; float best_s = -2.f;
                            for (int i = 0; i < (int)text_feats.size(); ++i) {
                                auto tf = text_feats[i]; l2norm(tf);
                                float s = cosine(emb, tf);
                                if (s > best_s) { best_s = s; best_i = i; }
                            }
                            {
                                std::lock_guard<std::mutex> lk(label_mutex);
                                if (best_i < (int)labels.size()) top1_label = labels[best_i];
                            }
                            std::cout << "[CLIP] frame " << n << " top1=" << top1_label << std::endl;
                        }
                        device.reset(1);
                    }

                    // Step B: 为下一帧配置 IMK
                    reg.write(IMK_BASE + 0x114, imk_addr);
                    std::vector<float> empty_vec;
                    initImageMake(fpai_device, 0, NET_W, NET_H, 3, imk_addr, 8, empty_vec, empty_vec);
                    reg.write(IMK_BASE + 0x254, 0x4);  // bypass=1
                    imk_armed.store(true);
                }
                // 每帧画 Top-1
                {
                    std::lock_guard<std::mutex> lk(label_mutex);
                    cv::putText(f, top1_label, cv::Point(50, 100),
                                cv::FONT_HERSHEY_DUPLEX, 2.0, cv::Scalar(0, 255, 0), 3);
                }
            });
        da.bindInputQueue(&dq);
        ca.start(); da.start();
        std::cerr << "[main] camera+HDMI+CLIP running" << std::endl;

        std::cout << "Running... Press Enter to stop." << std::endl;
        std::cin.get();
        ca.stop(); da.stop();
        Device::Close(device);
        return 0;
    }

    // ---------- 原有 file 模式 ----------
    if (argc < 5) {
        std::cerr << "用法: " << argv[0]
                  << " <json> <raw> <图片路径> <版本名>\n"
                  << "或  : " << argv[0]
                  << " camera <config_yaml> <tag>" << std::endl;
        return 1;
    }
    std::string json_path = argv[1];
    std::string raw_path  = argv[2];
    std::string img_path  = argv[3];
    std::string tag       = argv[4];

    auto device = Device::Open("axi://zg330aiu?npu=0x40000000&dma=0x80000000");

    auto network = loadNetwork(json_path, raw_path);
    std::cout << "[2] network loaded: " << json_path << std::endl;

    auto session = initSession("zg330", network, device,
                               /*ocm*/4, /*mmu*/true, /*speed*/true, /*compress*/false);
    session.apply();
    session.enableTimeProfile(true);
    std::cout << "[3] session ready" << std::endl;

    cv::Mat raw = cv::imread(img_path);
    if (raw.empty()) { std::cerr << "读图失败: " << img_path << std::endl; return -1; }

    cv::cvtColor(raw, raw, cv::COLOR_BGR2RGB);

    const int TARGET = 224;
    int w = raw.cols, h = raw.rows;
    double scale = (double)TARGET / std::min(w, h);
    int new_w = (int)std::round(w * scale);
    int new_h = (int)std::round(h * scale);
    cv::Mat resized;
    cv::resize(raw, resized, cv::Size(new_w, new_h), 0, 0, cv::INTER_CUBIC);

    int left = (new_w - TARGET) / 2;
    int top  = (new_h - TARGET) / 2;
    cv::Mat cropped = resized(cv::Rect(left, top, TARGET, TARGET)).clone();

    cv::Mat imgf;
    cropped.convertTo(imgf, CV_32FC3, 1.0 / 255.0);
    const float mean[3] = {0.48145466f, 0.4578275f, 0.40821073f};
    const float std_[3] = {0.26862954f, 0.26130258f, 0.27577711f};
    std::vector<cv::Mat> ch(3);
    cv::split(imgf, ch);
    for (int c = 0; c < 3; ++c) ch[c] = (ch[c] - mean[c]) / std_[c];
    cv::merge(ch, imgf);

    Tensor input_tensor = CvMat2Tensor(imgf, network, std::make_tuple(224, 224, 3));
    std::vector<Tensor> inputs = { input_tensor };
    std::cout << "[input] " << img_path << " 预处理后 已归一化" << std::endl;

    for (int i = 0; i < 5; ++i) {
        auto out = session.forward(inputs);
        for (auto& t : out) t.waitForReady(std::chrono::milliseconds(5000));
        device.reset(1);
    }

    const int N = 100;
    std::vector<double> times_ms; times_ms.reserve(N);
    std::vector<Tensor> last_out;
    for (int i = 0; i < N; ++i) {
        auto t0 = steady_clock::now();
        auto out = session.forward(inputs);
        for (auto& t : out) t.waitForReady(std::chrono::milliseconds(5000));
        auto t1 = steady_clock::now();
        device.reset(1);
        times_ms.push_back(duration_cast<microseconds>(t1 - t0).count() / 1000.0);
        last_out = out;
    }
    double avg = std::accumulate(times_ms.begin(), times_ms.end(), 0.0) / N;
    double mn  = *std::min_element(times_ms.begin(), times_ms.end());
    double mx  = *std::max_element(times_ms.begin(), times_ms.end());
    std::cout << "\n==== [" << tag << "] 耗时 (n=" << N << ") ====\n";
    std::cout << "平均: " << avg << " ms,  最小: " << mn << " ms,  最大: " << mx << " ms,  吞吐: "
              << 1000.0/avg << " FPS" << std::endl;

    calctime_detail(session);

    auto emb_t = last_out[0].to(icraft::xrt::HostDevice::MemRegion());
    const float* ep = (const float*)emb_t.data().cptr();
    std::vector<float> img_emb(ep, ep + DIM);

    std::string emb_file = "emb_" + tag + ".txt";
    {
        std::ofstream ofs(emb_file);
        ofs << "dim: " << DIM << "\n";
        for (int i = 0; i < DIM; ++i) ofs << img_emb[i] << "\n";
    }
    std::cout << "\n[emb] 已保存到 " << emb_file << std::endl;
    std::cout << "[emb] 前 8 个值: ";
    for (int i = 0; i < 8; ++i) std::cout << img_emb[i] << " ";
    std::cout << std::endl;

    std::vector<std::string> labels;
    {
        std::ifstream ifs(LABELS);
        std::string line;
        while (std::getline(ifs, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (!line.empty()) labels.push_back(line);
        }
    }
    if ((int)labels.size() != NUM_TEXT)
        std::cerr << "[warn] 标签数 " << labels.size() << " != " << NUM_TEXT << std::endl;

    std::vector<std::vector<float>> text_feats(NUM_TEXT, std::vector<float>(DIM));
    {
        std::ifstream ifs(TEXT_FEAT, std::ios::binary);
        if (!ifs) { std::cerr << "打不开 " << TEXT_FEAT << std::endl; return -1; }
        for (int i = 0; i < NUM_TEXT; ++i)
            ifs.read((char*)text_feats[i].data(), DIM * sizeof(float));
    }

    print_matches(img_emb, text_feats, labels, tag);

    Device::Close(device);
    return 0;
}

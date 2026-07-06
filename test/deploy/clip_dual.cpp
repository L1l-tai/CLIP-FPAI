/* CLIP 方案三: 实时分类 (配置文件驱动 + 运行时增删标签)
 *
 * 基于 clip_dual_2 改造:
 *   1. 所有参数从一个配置文件读 (命令行只传 config 路径)
 *   2. 运行时命令: add <文本> / del <文本> / del #<序号> / list / 空行退出
 *   3. labels 与 text_feats 同步增删 (label_mutex 保护)
 *
 * 用法:
 *   ./clip_dual clip_config.yaml
 *
 * 数据流 (每 clip_interval 帧):
 *   SDI摄像头帧 → ImageMake(bypass,借前置hardResize→640×480) → 拼BGRX →
 *   resize硬算子(640→224) → CPU归一化FP32 → vis NPU → image emb →
 *   和文本库比余弦 → Top-1 → HDMI叠加显示
 * 文本: 启动时批量编码 labels_txt; 运行时 add/del 动态增删
 */

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
#include <iomanip>
#include <cstdlib>
#include <deque>

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
// 文本编码器 (与 clip_dual_2 一致)
// ============================================================
static std::vector<float> encode_text(
    const std::string& prompt, const std::string& data_dir,
    Device& device, Session& text_session, const icraft::xir::Network& text_network,
    FPAIDevice& fpai_device, icraft::xrt::MemChunk& gather_chunk,
    uint32_t idx_addr, uint32_t src_addr, uint32_t dst_addr)
{
    const int VOCAB = 49408, SEQ = 77;
    const int DATA_WIDTH_BEATS = 32, INDICES_LEN = 1;
    int indices_beats = 1, indices_size = indices_beats * 64;
    int elem_size = DATA_WIDTH_BEATS * 64, src_data_size = SEQ * elem_size;

    auto token_emb = read_float_bin(data_dir + "token_emb.bin", (size_t)VOCAB * DIM);
    auto pos_emb   = read_float_bin(data_dir + "pos_emb.bin",   (size_t)SEQ * DIM);
    auto input_ids = read_int32_bin(data_dir + "input_ids_" + prompt + ".bin", SEQ);
    if (token_emb.empty() || input_ids.empty()) return {};

    std::vector<float> mid_in((size_t)SEQ * DIM);
    int eot_idx = 0; int32_t maxv = input_ids[0];
    for (int i = 0; i < SEQ; i++) {
        int id = input_ids[i];
        for (int j = 0; j < DIM; j++)
            mid_in[(size_t)i*DIM + j] = token_emb[(size_t)id*DIM + j] + pos_emb[(size_t)i*DIM + j];
        if (input_ids[i] > maxv) { maxv = input_ids[i]; eot_idx = i; }
    }

    {
        Tensor in_warm = data2Tensor(mid_in.data(), text_network.inputs()[0]);
        auto warm = text_session.forward({in_warm});
        for (auto& t : warm) t.waitForReady(std::chrono::milliseconds(5000));
        device.reset(1);
    }
    Tensor in_real = data2Tensor(mid_in.data(), text_network.inputs()[0]);
    auto out = text_session.forward({in_real});
    for (auto& t : out) t.waitForReady(std::chrono::milliseconds(5000));
    device.reset(1);

    auto out_host = out[0].to(HostDevice::MemRegion());
    const float* feat_seq = (const float*)out_host.data().cptr();
    std::vector<float> feat_seq_buf(feat_seq, feat_seq + (size_t)SEQ * DIM);

    auto& reg = fpai_device.defaultRegRegion();
    uint32_t GATHER_BASE = 0x400C0000;
    reg.write(GATHER_BASE + 0x1DC, 1, false); std::this_thread::sleep_for(std::chrono::milliseconds(10));
    reg.write(GATHER_BASE + 0x1DC, 0, false); std::this_thread::sleep_for(std::chrono::milliseconds(10));

    std::vector<int8_t> idx_buf(indices_size, 0);
    idx_buf[0] = eot_idx & 0xFF; idx_buf[1] = (eot_idx>>8)&0xFF;
    idx_buf[2] = (eot_idx>>16)&0xFF; idx_buf[3] = (eot_idx>>24)&0xFF;

    const int8_t* feat_bytes = (const int8_t*)feat_seq_buf.data();
    gather_chunk.write(0, (char*)idx_buf.data(), indices_size);
    gather_chunk.write(indices_size + 4096, (char*)feat_bytes, src_data_size);

    reg.write(GATHER_BASE + 0x14, INDICES_LEN, false);
    reg.write(GATHER_BASE + 0x18, DATA_WIDTH_BEATS, false);
    reg.write(GATHER_BASE + 0x04, (indices_beats<<16) | (idx_addr & 0xFFFF), false);
    reg.write(GATHER_BASE + 0x0C, src_addr, false);
    reg.write(GATHER_BASE + 0x08, dst_addr, false);
    reg.write(GATHER_BASE + 0x00, 1, false);

    auto t0 = system_clock::now();
    int done = 0;
    while (!done) {
        done = reg.read(GATHER_BASE + 0x80, false);
        if (duration_cast<milliseconds>(system_clock::now() - t0).count() > 10000) {
            std::cerr << "[TEXT] Gather timeout" << std::endl; return {};
        }
    }

    std::vector<float> eot_feat(DIM);
    gather_chunk.read((char*)eot_feat.data(), indices_size + 4096 + src_data_size + 4096, DIM * sizeof(float));

    auto proj = read_float_bin(data_dir + "text_proj.bin", (size_t)DIM * DIM);
    if (proj.empty()) return {};
    std::vector<float> text_feat(DIM, 0.f);
    for (int i = 0; i < DIM; i++) {
        float s = 0;
        for (int k = 0; k < DIM; k++) s += eot_feat[k] * proj[(size_t)k*DIM + i];
        text_feat[i] = s;
    }
    l2norm(text_feat);   // 直接归一化好, 比对时省事
    return text_feat;
}

// 现场分词: 单个 prompt → gen_input_ids.py → input_ids bin
static bool tokenize_prompt(const std::string& prompt, const std::string& data_dir) {
    std::string tmp_labels = data_dir + "query_tmp.txt";
    { std::ofstream ofs(tmp_labels); if (!ofs) return false; ofs << prompt << "\n"; }
    std::string cmd = "python3 ./gen_input_ids.py \"" + tmp_labels + "\" \"" + data_dir + "\"";
    if (std::system(cmd.c_str()) != 0) { std::cerr << "[TEXT] gen_input_ids 失败" << std::endl; return false; }
    std::ifstream chk(data_dir + "input_ids_" + prompt + ".bin", std::ios::binary);
    return (bool)chk;
}

// ============================================================
// main
// ============================================================
int main(int argc, char* argv[])
{
    std::cerr << "=== CLIP 方案三: 实时分类 (配置文件 + 增删标签) ===" << std::endl;

    if (argc < 2) {
        std::cerr << "用法: " << argv[0] << " <clip_config.yaml>" << std::endl;
        return 1;
    }
    std::string cfg_path = argv[1];

    // ---------- 读配置文件 ----------
    YAML::Node cfg;
    try { cfg = YAML::LoadFile(cfg_path); }
    catch (const std::exception& e) { std::cerr << "配置文件加载失败: " << cfg_path << std::endl; return -1; }

    std::string CAMERA_YAML = cfg["camera_yaml"].as<std::string>();
    std::string VIS_JSON    = cfg["vis_json"].as<std::string>();
    std::string VIS_RAW     = cfg["vis_raw"].as<std::string>();
    std::string TEXT_JSON   = cfg["text_json"].as<std::string>();
    std::string TEXT_RAW    = cfg["text_raw"].as<std::string>();
    std::string DATA_DIR    = cfg["data_dir"].as<std::string>();
    std::string LABELS_TXT  = cfg["labels_txt"].as<std::string>();
    int CLIP_INTV = cfg["clip_interval"] ? cfg["clip_interval"].as<int>() : 10;
    if (!DATA_DIR.empty() && DATA_DIR.back() != '/') DATA_DIR += "/";

    std::cerr << "[cfg] camera_yaml = " << CAMERA_YAML << std::endl;
    std::cerr << "[cfg] vis  = " << VIS_JSON << std::endl;
    std::cerr << "[cfg] text = " << TEXT_JSON << std::endl;
    std::cerr << "[cfg] data_dir = " << DATA_DIR << ", clip_interval = " << CLIP_INTV << std::endl;

    // ---------- 相机 yaml (复旦微原配置) ----------
    YAML::Node config;
    try { config = YAML::LoadFile(CAMERA_YAML); }
    catch (const YAML::BadFile& e) { std::cerr << "相机 yaml 加载失败: " << CAMERA_YAML << std::endl; return -1; }

    // ---------- 设备 ----------
    const auto& sys_yaml = config["sys"];
    auto device = Device::Open(sys_yaml["device"].as<std::string>().c_str());
    auto fpai_device = device.cast<FPAIDevice>();

    // ---------- ★Gather PL-DDR 提前分配: 抢低地址★ ----------
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
    std::cerr << "[main] gather mem base=0x" << std::hex << mem_base
              << " idx high16=0x" << (idx_addr>>16) << std::dec << std::endl;
    if ((idx_addr >> 16) != 0)
        std::cerr << "[WARN] gather idx 未落低地址! Gather 会取垃圾!" << std::endl;

    // ---------- 双模型加载 ----------
    std::cerr << "[main] loading text model..." << std::endl;
    auto text_network = loadNetwork(TEXT_JSON, TEXT_RAW);
    auto text_session = initSession("zg330", text_network, device, 4, true, true, false);
    text_session.apply();

    std::cerr << "[main] loading vision model..." << std::endl;
    auto vis_network = loadNetwork(VIS_JSON, VIS_RAW);
    auto vis_session = initSession("zg330", vis_network, device, 4, true, true, false);
    vis_session.apply();

    // ============================================================
    // 标签库: labels 与 text_feats 一一对应, 增删同步, label_mutex 保护
    // ============================================================
    std::mutex label_mutex;
    std::vector<std::string>        labels;
    std::vector<std::vector<float>> text_feats;

    // 加标签 (编码 + 入库). 调用方不持锁; 内部编码耗时, 编完再锁入库
    auto add_label = [&](const std::string& prompt) -> bool {
        // 去重
        {
            std::lock_guard<std::mutex> lk(label_mutex);
            if (std::find(labels.begin(), labels.end(), prompt) != labels.end()) {
                std::cerr << "[LABEL] 已存在: " << prompt << std::endl; return false;
            }
        }
        if (!tokenize_prompt(prompt, DATA_DIR)) return false;
        auto feat = encode_text(prompt, DATA_DIR, device, text_session, text_network,
                                fpai_device, gather_chunk, idx_addr, src_addr, dst_addr);
        if (feat.empty()) { std::cerr << "[LABEL] 编码失败: " << prompt << std::endl; return false; }
        std::lock_guard<std::mutex> lk(label_mutex);
        labels.push_back(prompt);
        text_feats.push_back(feat);
        std::cerr << "[LABEL] + 添加 '" << prompt << "' (当前 " << labels.size() << " 类)" << std::endl;
        return true;
    };

    // ---------- 启动时批量加载初始标签 ----------
    {
        std::vector<std::string> init_labels;
        std::ifstream ifs(LABELS_TXT);
        if (!ifs) {
            std::cerr << "[main] 注意: 初始标签文件不存在 (" << LABELS_TXT
                      << "), 用默认标签, 可运行时 add 添加" << std::endl;
        } else {
            std::string line;
            while (std::getline(ifs, line)) {
                if (!line.empty() && line.back() == '\r') line.pop_back();
                if (!line.empty()) init_labels.push_back(line);
            }
        }
        if (init_labels.empty()) init_labels = {"a photo of a cat"};

        // 把初始标签写回一个规范文件, 再批量生成 input_ids (避免依赖外部 labels.txt 是否存在)
        std::string init_file = DATA_DIR + "init_labels.txt";
        { std::ofstream ofs(init_file);
          for (const auto& p : init_labels) ofs << p << "\n"; }
        std::string cmd = "python3 ./gen_input_ids.py \"" + init_file + "\" \"" + DATA_DIR + "\"";
        int ret = std::system(cmd.c_str());
        if (ret != 0) std::cerr << "[main] 警告: 初始分词可能失败" << std::endl;

        std::cerr << "[main] 初始编码 " << init_labels.size() << " 个标签..." << std::endl;
        for (const auto& p : init_labels) {
            auto feat = encode_text(p, DATA_DIR, device, text_session, text_network,
                                    fpai_device, gather_chunk, idx_addr, src_addr, dst_addr);
            if (!feat.empty()) { labels.push_back(p); text_feats.push_back(feat); }
        }
        std::cerr << "[main] 初始标签就绪: " << labels.size() << std::endl;
    }

    // ---------- 相机 + HDMI ----------
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

    // ---------- 视觉预处理 ----------
    const float mean_c[3] = {0.48145466f, 0.4578275f, 0.40821073f};
    const float std_c[3]  = {0.26862954f, 0.26130258f, 0.27577711f};
    const int DST_SZ = 224, NET_W = 640, NET_H = 480;

    auto imk_mem = fpai_device.defaultMemRegion().malloc(NET_W*NET_H*3+4096, 0, 64);
    auto rs_src  = fpai_device.defaultMemRegion().malloc(NET_W*NET_H*4+4096, 0, 64);
    auto rs_dst  = fpai_device.defaultMemRegion().malloc(DST_SZ*DST_SZ*4+4096, 0, 64);
    uint64_t imk_addr    = imk_mem->begin.addr();
    uint64_t rs_src_addr = rs_src->begin.addr();
    uint64_t rs_dst_addr = rs_dst->begin.addr();
    const uint64_t IMK_BASE = 0x80000400;

    // 共享状态
    std::mutex disp_mutex;
    std::string top1_label = labels.empty() ? "N/A" : labels[0];
    std::atomic<int> frame_cnt{0};
    std::atomic<bool> imk_armed{false};

    // 命令队列: 主线程解析 → 回调线程执行(用到NPU的add才需回调; del/list主线程直接做)
    std::mutex cmd_mutex;
    std::deque<std::string> add_queue;   // 待添加的标签
    std::atomic<bool> has_add{false};

    auto hd = std::make_unique<RGB565HDMIDisplay<FPAIDevice>>(0, fpai_device, DW, DH);
    HDMIDisplayActor<FPAIDevice, InputMessageForIcore> da(
        hd->getSinkId(), std::move(hd), fpai_device, bm, ca.getChunkGroupId(),
        [&](const InputMessageForIcore&, cv::Mat& f) {
            int n = frame_cnt.fetch_add(1);

            // 处理待添加标签 (add 用到 text NPU + Gather, 在回调线程执行避免与 vis 冲突)
            if (has_add.load()) {
                std::string prompt;
                bool got = false;
                { std::lock_guard<std::mutex> lk(cmd_mutex);
                  if (!add_queue.empty()) { prompt = add_queue.front(); add_queue.pop_front(); got = true; }
                  if (add_queue.empty()) has_add.store(false); }
                if (got) add_label(prompt);
            }

            if (n % CLIP_INTV == 0) {
                auto& reg = fpai_device.defaultRegRegion();

                if (imk_armed.load()) {
                    // ---- 图像编码链 ----
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
                    uint32_t rs_cycles;
                    if (op_resize_run(&fpai_device, 0x400C0000, rcfg, 2000, &rs_cycles)) {
                        std::vector<uint8_t> rs_out(DST_SZ*DST_SZ*4);
                        rs_dst.read((char*)rs_out.data(), 0, DST_SZ*DST_SZ*4);
                        std::vector<float> fp32_rgb(DST_SZ*DST_SZ*3);
                        for (int i = 0; i < DST_SZ*DST_SZ; i++) {
                            uint32_t w = ((uint32_t*)rs_out.data())[i];
                            fp32_rgb[i*3+0] = ((float)((w>>16)&0xFF)/255.f - mean_c[2]) / std_c[2];
                            fp32_rgb[i*3+1] = ((float)((w>>8)&0xFF)/255.f - mean_c[1]) / std_c[1];
                            fp32_rgb[i*3+2] = ((float)(w&0xFF)/255.f - mean_c[0]) / std_c[0];
                        }
                        cv::Mat imgf(DST_SZ, DST_SZ, CV_32FC3, fp32_rgb.data());
                        Tensor t = CvMat2Tensor(imgf, vis_network, std::make_tuple(DST_SZ, DST_SZ, 3));
                        auto out = vis_session.forward({t});
                        for (auto& ot : out) ot.waitForReady(std::chrono::milliseconds(5000));
                        auto emb_t = out[0].to(HostDevice::MemRegion());
                        std::vector<float> emb((const float*)emb_t.data().cptr(),
                                               (const float*)emb_t.data().cptr()+DIM);
                        l2norm(emb);

                        // ---- 和标签库比余弦 (锁住, 与增删互斥) ----
                        std::vector<std::pair<float,int>> scores;
                        std::string cur_top1;
                        float cur_cos = 0;
                        {
                            std::lock_guard<std::mutex> lk(label_mutex);
                            for (int i = 0; i < (int)text_feats.size(); ++i)
                                scores.push_back({ cosine(emb, text_feats[i]), i });  // text_feats已l2norm
                            std::sort(scores.begin(), scores.end(),
                                      [](auto& a, auto& b){ return a.first > b.first; });
                            if (!scores.empty()) {
                                cur_top1 = labels[scores[0].second];
                                cur_cos = scores[0].first;
                                char buf[80];
                                snprintf(buf, sizeof(buf), "%s %.3f", cur_top1.c_str(), cur_cos);
                                std::lock_guard<std::mutex> dlk(disp_mutex);
                                top1_label = buf;
                            }
                        }
                        // 仅当 Top-1 标签变化时打印一行 (避免刷屏)
                        static std::string last_top1 = "";
                        if (!cur_top1.empty() && cur_top1 != last_top1) {
                            std::cerr << "[VIS] Top-1 -> " << cur_top1
                                      << " (" << std::fixed << std::setprecision(3) << cur_cos << ")" << std::endl;
                            last_top1 = cur_top1;
                        }
                    }
                    device.reset(1);
                }

                // arm 下一次 ImageMake
                reg.write(IMK_BASE + 0x114, imk_addr);
                std::vector<float> empty_vec;
                initImageMake(fpai_device, 0, NET_W, NET_H, 3, imk_addr, 8, empty_vec, empty_vec);
                reg.write(IMK_BASE + 0x254, 0x4);
                imk_armed.store(true);
            }

            // HDMI 叠加 Top-1
            {
                std::lock_guard<std::mutex> dlk(disp_mutex);
                cv::putText(f, top1_label, cv::Point(50, 100),
                            cv::FONT_HERSHEY_DUPLEX, 2.0, cv::Scalar(0, 255, 0), 3);
            }
        });
    da.bindInputQueue(&dq);
    spdlog::set_level(spdlog::level::warn);
    ca.start(); da.start();

    // ---------- 命令帮助 ----------
    std::cout << "\n=== 实时分类运行中 ===" << std::endl;
    std::cout << "命令:" << std::endl;
    std::cout << "  add <文本>   增加标签 (例: add a red car)" << std::endl;
    std::cout << "  del <文本>   按文本删除 (例: del a red car)" << std::endl;
    std::cout << "  del #<序号>  按序号删除 (例: del #3)" << std::endl;
    std::cout << "  list         列出当前所有标签" << std::endl;
    std::cout << "  (空行)       退出" << std::endl;
    std::cout << "提示: 分类日志已改为仅 Top-1 变化时打印; 若仍嫌干扰可用 2>log.txt 重定向" << std::endl << std::endl;

    // ---------- 主线程: 命令解析 ----------
    std::string line;
    while (std::getline(std::cin, line)) {
        if (line.empty()) break;
        // 去首尾空格
        size_t s = line.find_first_not_of(" \t");
        size_t e = line.find_last_not_of(" \t\r");
        if (s == std::string::npos) continue;
        line = line.substr(s, e - s + 1);

        if (line == "list") {
            std::lock_guard<std::mutex> lk(label_mutex);
            std::cout << "当前标签 (" << labels.size() << "):" << std::endl;
            for (int i = 0; i < (int)labels.size(); i++)
                std::cout << "  #" << i << "  " << labels[i] << std::endl;
        }
        else if (line.rfind("add ", 0) == 0) {
            std::string prompt = line.substr(4);
            size_t ps = prompt.find_first_not_of(" \t");
            if (ps == std::string::npos) { std::cout << "[main] add 需要文本" << std::endl; continue; }
            prompt = prompt.substr(ps);
            { std::lock_guard<std::mutex> lk(cmd_mutex); add_queue.push_back(prompt); has_add.store(true); }
            std::cout << "[main] 已排队添加: " << prompt << std::endl;
        }
        else if (line.rfind("del ", 0) == 0) {
            std::string arg = line.substr(4);
            size_t as = arg.find_first_not_of(" \t");
            if (as == std::string::npos) { std::cout << "[main] del 需要参数" << std::endl; continue; }
            arg = arg.substr(as);
            std::lock_guard<std::mutex> lk(label_mutex);
            if (arg[0] == '#') {   // 按序号删
                int idx = std::atoi(arg.c_str() + 1);
                if (idx >= 0 && idx < (int)labels.size()) {
                    std::cout << "[main] - 删除 #" << idx << " '" << labels[idx] << "'" << std::endl;
                    labels.erase(labels.begin() + idx);
                    text_feats.erase(text_feats.begin() + idx);
                } else std::cout << "[main] 序号越界: " << idx << std::endl;
            } else {               // 按文本删
                auto it = std::find(labels.begin(), labels.end(), arg);
                if (it != labels.end()) {
                    int idx = it - labels.begin();
                    std::cout << "[main] - 删除 '" << arg << "'" << std::endl;
                    labels.erase(labels.begin() + idx);
                    text_feats.erase(text_feats.begin() + idx);
                } else std::cout << "[main] 未找到标签: " << arg << std::endl;
            }
            if (labels.empty()) std::cout << "[main] 警告: 标签已空!" << std::endl;
        }
        else {
            std::cout << "[main] 未知命令. 用 add/del/list, 空行退出" << std::endl;
        }
    }

    ca.stop(); da.stop();
    Device::Close(device);
    return 0;
}

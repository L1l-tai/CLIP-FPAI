/* CLIP 合并程序: 实时分类 + 查找 (采集/视频), 模型加载一次
 *
 * 两大功能, 共用 text+vis 模型和硬算子链, 用 mode 切换:
 *
 *   mode dual    实时分类:
 *       实时摄像头 → 每 clip_interval 帧分类 → HDMI 显示 Top-1 标签
 *       运行时增删标签: add <文本> / del <文本> / del #<序号> / list
 *
 *   mode search  查找:
 *       cap                       实时采集(按回车采1张, 满 gallery_size 张自动结束; done 提前结束)
 *       vid <dir> <fps> [stride]  导入 PC 抽好的 jpg 序列建库
 *       <文本>                    查询当前库 → Top-K + HDMI 显示 Top-1 帧
 *       play                      回到回放/实时(清除 Top-1)
 *
 * 通用命令: mode dual | mode search | status | help | 空行退出
 *
 * 图像编码链:
 *   - 摄像头帧: ImageMake(bypass,借前置hardResize→640×480) → 拼BGRX → resize硬算子 → CPU归一化 → vis
 *   - jpg帧:    cv::resize到640×480 → 拼BGRX → resize硬算子 → CPU归一化 → vis (接法1)
 * 文本编码: CPU查表 → text NPU → FPGA Gather(取EOT) → CPU投影 → l2norm
 *
 * 板上 OpenCV 无 videoio, 视频须 PC 端 ffmpeg/脚本抽成 jpg 序列.
 *
 * 用法: ./clip_app app_config.yaml
 */

#include "icraft_utils.hpp"
#include <icraft-xrt/core/session.h>
#include <opencv2/opencv.hpp>
#include <chrono>
#include <iostream>
#include <fstream>
#include <sstream>
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
#include <cstdio>
#include <deque>
#include <dirent.h>

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
#include "simple_tokenizer.hpp"

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
static std::vector<std::string> list_jpgs(const std::string& dir) {
    std::vector<std::string> files;
    DIR* d = opendir(dir.c_str());
    if (!d) { std::cerr << "[ERROR] 打不开目录 " << dir << std::endl; return files; }
    struct dirent* e;
    while ((e = readdir(d)) != nullptr) {
        std::string name = e->d_name;
        if (name.size() > 4) {
            std::string ext = name.substr(name.size()-4);
            if (ext == ".jpg" || ext == ".JPG" || ext == ".png" || ext == ".PNG")
                files.push_back(name);
        }
    }
    closedir(d);
    std::sort(files.begin(), files.end());
    return files;
}

// ============================================================
// 文本编码器 (CPU查表→text NPU→FPGA Gather→CPU投影→l2norm)
// ============================================================
static std::vector<float> encode_text(
    const std::vector<int32_t>& input_ids, const std::string& data_dir,
    Device& device, Session& text_session, const icraft::xir::Network& text_network,
    FPAIDevice& fpai_device, icraft::xrt::MemChunk& gather_chunk,
    uint32_t idx_addr, uint32_t src_addr, uint32_t dst_addr,
    double* out_gather_us = nullptr)
{
    const int VOCAB = 49408, SEQ = 77;
    const int DATA_WIDTH_BEATS = 32, INDICES_LEN = 1;
    int indices_beats = 1, indices_size = indices_beats * 64;
    int elem_size = DATA_WIDTH_BEATS * 64, src_data_size = SEQ * elem_size;

    auto token_emb = read_float_bin(data_dir + "token_emb.bin", (size_t)VOCAB * DIM);
    auto pos_emb   = read_float_bin(data_dir + "pos_emb.bin",   (size_t)SEQ * DIM);
    if (token_emb.empty() || input_ids.empty()) return {};

    std::cerr << "[TOK]";
    for (int i = 0; i < 10 && i < (int)input_ids.size(); i++)
        std::cerr << " " << input_ids[i];
    std::cerr << " ...";
    for (int i = 70; i < 77 && i < (int)input_ids.size(); i++)
        std::cerr << " " << input_ids[i];
    std::cerr << std::endl;

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
    if (out_gather_us) *out_gather_us = reg.read(GATHER_BASE + 0x84, false) / 200.0;

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
    l2norm(text_feat);
    return text_feat;
}


// ============================================================
// main
// ============================================================
int main(int argc, char* argv[])
{
    // subprocess 管道下 stdout 默认全缓冲, 会导致 [WEB] 行卡在缓冲里 server 收不到.
    // 设为行缓冲: 每遇 \n 立即 flush, printf 和 cout 都生效.
    setvbuf(stdout, NULL, _IOLBF, 0);

    if (argc < 2) { std::cerr << "用法: " << argv[0] << " <app_config.yaml>" << std::endl; return 1; }
    std::string cfg_path = argv[1];

    // ---------- 读配置 ----------
    YAML::Node cfg;
    try { cfg = YAML::LoadFile(cfg_path); }
    catch (const std::exception& e) { std::cerr << "配置文件加载失败: " << cfg_path << std::endl; return -1; }

    std::string CAMERA_YAML = cfg["camera_yaml"].as<std::string>();
    std::string VIS_JSON    = cfg["vis_json"].as<std::string>();
    std::string VIS_RAW     = cfg["vis_raw"].as<std::string>();
    std::string TEXT_JSON   = cfg["text_json"].as<std::string>();
    std::string TEXT_RAW    = cfg["text_raw"].as<std::string>();
    std::string DATA_DIR    = cfg["data_dir"].as<std::string>();
    std::string LABELS_TXT  = cfg["labels_txt"] ? cfg["labels_txt"].as<std::string>() : "";
    int CLIP_INTV    = cfg["clip_interval"] ? cfg["clip_interval"].as<int>() : 10;
    int GALLERY_SIZE = cfg["gallery_size"]  ? cfg["gallery_size"].as<int>()  : 20;
    // 实时采集(cap)时把每帧存成 jpg 的目录, 供 Web UI 通过文件名读取显示
    std::string CAP_FRAMES_DIR = cfg["cap_frames_dir"] ? cfg["cap_frames_dir"].as<std::string>() : "board_data/cap_frames/";
    if (!DATA_DIR.empty() && DATA_DIR.back() != '/') DATA_DIR += "/";
    if (!CAP_FRAMES_DIR.empty() && CAP_FRAMES_DIR.back() != '/') CAP_FRAMES_DIR += "/";
    // 确保 cap_frames 目录存在
    { std::string mk = "mkdir -p \"" + CAP_FRAMES_DIR + "\""; int r = std::system(mk.c_str()); (void)r; }

    YAML::Node config;
    try { config = YAML::LoadFile(CAMERA_YAML); }
    catch (const YAML::BadFile& e) { std::cerr << "相机 yaml 加载失败: " << CAMERA_YAML << std::endl; return -1; }

    // ---------- 设备 ----------
    const auto& sys_yaml = config["sys"];
    auto device = Device::Open(sys_yaml["device"].as<std::string>().c_str());
    auto fpai_device = device.cast<FPAIDevice>();

    // ---------- ★Gather 抢低地址★ ----------
    const int SEQ = 77;
    const int DATA_WIDTH_BEATS = 32, INDICES_LEN = 1;
    int indices_beats = 1, indices_size = indices_beats * 64;
    int elem_size = DATA_WIDTH_BEATS * 64, src_data_size = SEQ * elem_size;
    int dst_data_size = INDICES_LEN * elem_size;
    const int PAD = 4096;
    int idx_offset = 0, src_offset = idx_offset + indices_size + PAD;
    int dst_offset = src_offset + src_data_size + PAD;
    int text_total = dst_offset + dst_data_size + PAD;
    auto gather_chunk = fpai_device.defaultMemRegion().malloc(text_total, 0, 64);
    uint32_t mem_base = gather_chunk->begin.addr();
    uint32_t idx_addr = mem_base + idx_offset;
    uint32_t src_addr = mem_base + src_offset;
    uint32_t dst_addr = mem_base + dst_offset;
    std::cerr << "[main] gather idx high16=0x" << std::hex << (idx_addr>>16) << std::dec << std::endl;
    if ((idx_addr >> 16) != 0) std::cerr << "[WARN] gather idx 未落低地址!" << std::endl;

    // ---------- 双模型加载 (一次) ----------
    std::cerr << "[main] loading text model..." << std::endl;
    auto text_network = loadNetwork(TEXT_JSON, TEXT_RAW);
    auto text_session = initSession("zg330", text_network, device, 4, true, true, false);
    text_session.apply();
    std::cerr << "[main] loading vision model..." << std::endl;
    auto vis_network = loadNetwork(VIS_JSON, VIS_RAW);
    auto vis_session = initSession("zg330", vis_network, device, 4, true, true, false);
    vis_session.apply();

    // ---- 初始标签加载 (camera 前完成, 避免 text encode 的 reset 干扰管线) ----
    SimpleTokenizer tok(DATA_DIR + "merges.txt");
    std::mutex label_mutex;
    std::vector<std::string> labels;
    std::vector<std::vector<float>> label_feats;
    {
        std::vector<std::string> init;
        if (!LABELS_TXT.empty()) {
            std::ifstream ifs(LABELS_TXT);
            if (ifs) { std::string line;
                while (std::getline(ifs, line)) {
                    if (!line.empty() && line.back()=='\r') line.pop_back();
                    if (!line.empty()) init.push_back(line); } }
        }
        if (init.empty()) init = {"a photo of a cat"};
        std::cerr << "[main] 初始编码 " << init.size() << " 标签..." << std::endl;
        for (auto& p : init) {
            auto ids = tok.tokenize(p);
            auto feat = encode_text(ids, DATA_DIR, device, text_session, text_network,
                                    fpai_device, gather_chunk, idx_addr, src_addr, dst_addr);
            if (!feat.empty()) { labels.push_back(p); label_feats.push_back(feat); }
        }
        std::cerr << "[main] 初始标签就绪: " << labels.size() << std::endl;
    }
    // labels/label_feats/label_mutex/tok 在上面声明, 后续 lambda 通过 [&] 捕获

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

    // ---- FWHT 硬算子: 内存 + 测试数据 (对齐 fwht_test) ----
    const int FWHT_VEC = 768, FWHT_NUM = 30;
    const int FWHT_ELEMS = FWHT_VEC * FWHT_NUM;       // 23040
    const int FWHT_BLOCKS = FWHT_ELEMS / 32;           // 720
    auto fwht_mem = fpai_device.defaultMemRegion().malloc(FWHT_BLOCKS * 64 * 2 + 8192, 0, 64);
    uint64_t fwht_base = fwht_mem->begin.addr();
    uint32_t fwht_src = (uint32_t)(fwht_base + 4096);
    uint32_t fwht_dst = (uint32_t)(fwht_base + 4096 + FWHT_BLOCKS * 64 + 4096);

    // 生成 768×30 FP16 数据
    std::vector<uint8_t> fwht_src_data(FWHT_BLOCKS * 64);
    {
        auto f2h = [](float x) -> uint16_t {
            if (x == 0.0f) return 0;
            uint16_t sign = (x < 0) ? 0x8000 : 0;
            float ax = (x < 0) ? -x : x;
            if (ax < 6.0e-8f) return sign;
            if (ax > 65504.0f) return sign | 0x7C00;
            int exp; float mant = frexpf(ax, &exp);
            int e = exp + 14;
            if (e <= 0) { mant *= (1 << (-e+1)); return sign | ((uint16_t)mant & 0x3FF); }
            if (e >= 31) return sign | 0x7C00;
            int frac = (int)(mant * 2048.0f) & 0x7FF;
            frac = (frac + 1) >> 1;
            if (frac >= 1024) { e++; frac = 0; }
            return sign | ((e & 0x1F) << 10) | (frac & 0x3FF);
        };
        std::mt19937 rng(42);
        std::normal_distribution<float> nd(0.0f, 1.0f);
        std::uniform_real_distribution<float> om(10.0f, 100.0f);
        std::uniform_int_distribution<int> no(10, 20), pi(0, FWHT_VEC-1);
        std::uniform_real_distribution<float> coin(0.0f, 1.0f);
        for (int v = 0; v < FWHT_NUM; v++) {
            int base = v * FWHT_VEC;
            for (int i = 0; i < FWHT_VEC; i++) {
                float val = nd(rng);
                if (val > 2.0f) val = 2.0f; if (val < -2.0f) val = -2.0f;
                int blk = (base + i) / 32, off = (base + i) % 32;
                uint16_t fp16 = f2h(val);
                int hi = 62 - off * 2, lo = 63 - off * 2;
                fwht_src_data[blk * 64 + hi] = (fp16 >> 8) & 0xFF;
                fwht_src_data[blk * 64 + lo] = fp16 & 0xFF;
            }
            int n = no(rng);
            for (int k = 0; k < n; k++) {
                int idx = pi(rng);
                float mag = om(rng); if (coin(rng) > 0.5f) mag = -mag;
                int blk = (base + idx) / 32, off = (base + idx) % 32;
                uint16_t fp16 = f2h(mag);
                int hi = 62 - off * 2, lo = 63 - off * 2;
                fwht_src_data[blk * 64 + hi] = (fp16 >> 8) & 0xFF;
                fwht_src_data[blk * 64 + lo] = fp16 & 0xFF;
            }
        }
    }
    // 预写入 FWHT 源数据
    fwht_mem.write(4096, (char*)fwht_src_data.data(), FWHT_BLOCKS * 64);

    // FWHT 统计
    std::atomic<double> fwht_us_last{0};
    std::atomic<double> fwht_us_sum{0};

    // ---------- 编码器统计 (供 Web UI 显示 本次/平均 耗时) ----------
    // 文本编码器: 累计次数 + Gather 硬算子累计耗时(us)
    std::atomic<long> txt_enc_count{0};
    std::atomic<double> txt_gather_us_sum{0};
    std::atomic<double> txt_gather_us_last{0};
    // 图像编码器: 累计帧数 + Resize 硬算子累计耗时(us) + 单帧总耗时
    std::atomic<long> img_enc_count{0};
    std::atomic<double> img_resize_us_sum{0};
    std::atomic<double> img_resize_us_last{0};
    std::atomic<double> img_frame_ms_last{0};

    // FWHT 硬算子调用 (对齐 fwht_test)
    auto run_fwht = [&]() -> double {
        auto& reg = fpai_device.defaultRegRegion();
        const uint32_t CBASE = 0x400C0000;
        reg.write(CBASE + 0x1C, 2, false);
        reg.write(CBASE + 0x20, 1, false);
        reg.write(CBASE + 0xC8, fwht_src, false);
        reg.write(CBASE + 0xCC, fwht_dst, false);
        reg.write(CBASE + 0xD0, FWHT_BLOCKS, false);
        reg.write(CBASE + 0xC4, 1, false);
        auto t0 = system_clock::now();
        while (!reg.read(CBASE + 0x100, false)) {
            if (duration_cast<milliseconds>(system_clock::now()-t0).count() > 2000) break;
        }
        uint32_t cycles = reg.read(CBASE + 0x88, false);
        double us = cycles / 200.0;
        fwht_us_last.store(us);
        fwht_us_sum.store(fwht_us_sum.load() + us);
        return us;
    };
    // resize 输出 → CPU归一化 → vis NPU → emb (两来源共用后半段)
    // out_fwd_ms: 返回 vision forward 耗时(ms)
    auto resize_out_to_emb = [&](double* out_fwd_ms = nullptr) -> std::vector<float> {
        std::vector<uint8_t> rs_out(DST_SZ*DST_SZ*4);
        rs_dst.read((char*)rs_out.data(), 0, DST_SZ*DST_SZ*4);
        std::vector<float> fp32_rgb(DST_SZ*DST_SZ*3);
        for (int i = 0; i < DST_SZ*DST_SZ; i++) {
            uint32_t w = ((uint32_t*)rs_out.data())[i];
            fp32_rgb[i*3+0] = ((float)((w>>16)&0xFF)/255.f - mean_c[2]) / std_c[2];  // B
            fp32_rgb[i*3+1] = ((float)((w>>8)&0xFF)/255.f - mean_c[1]) / std_c[1];   // G
            fp32_rgb[i*3+2] = ((float)(w&0xFF)/255.f - mean_c[0]) / std_c[0];        // R
        }
        cv::Mat imgf(DST_SZ, DST_SZ, CV_32FC3, fp32_rgb.data());
        Tensor t = CvMat2Tensor(imgf, vis_network, std::make_tuple(DST_SZ, DST_SZ, 3));
        auto _t_fwd = system_clock::now();
        auto out = vis_session.forward({t});
        for (auto& ot : out) ot.waitForReady(std::chrono::milliseconds(5000));
        double fwd_ms = duration_cast<microseconds>(system_clock::now() - _t_fwd).count() / 1000.0;
        if (out_fwd_ms) *out_fwd_ms = fwd_ms;
        auto emb_t = out[0].to(HostDevice::MemRegion());
        std::vector<float> emb((const float*)emb_t.data().cptr(),
                               (const float*)emb_t.data().cptr()+DIM);
        l2norm(emb);
        run_fwht();
        return emb;
    };
    // 摄像头帧 → emb
    auto encode_camera_frame = [&]() -> std::vector<float> {
        auto _t_start = system_clock::now();
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
        uint32_t rs_cycles = 0;
        if (!op_resize_run(&fpai_device, 0x400C0000, rcfg, 2000, &rs_cycles)) return {};
        // Resize 硬算子耗时: 周期数 / 200MHz = us
        double rs_us = rs_cycles / 200.0;
        img_resize_us_last.store(rs_us);
        img_resize_us_sum.store(img_resize_us_sum.load() + rs_us);
        double fwd_ms = 0;
        auto emb = resize_out_to_emb(&fwd_ms);
        if (!emb.empty()) {
            img_enc_count.fetch_add(1);
            img_frame_ms_last.store(fwd_ms);
        }
        return emb;
    };
    // jpg帧 → emb (接法1)
    auto encode_cv_frame = [&](const cv::Mat& frame_bgr) -> std::vector<float> {
        auto _t_start = system_clock::now();
        cv::Mat img640;
        cv::resize(frame_bgr, img640, cv::Size(NET_W, NET_H), 0, 0, cv::INTER_LINEAR);
        std::vector<uint32_t> padded(NET_W*NET_H);
        for (int y = 0; y < NET_H; y++) {
            const cv::Vec3b* row = img640.ptr<cv::Vec3b>(y);
            for (int x = 0; x < NET_W; x++)
                padded[y*NET_W+x] = (uint32_t)row[x][2]<<16 | (uint32_t)row[x][1]<<8 | row[x][0];
        }
        rs_src.write(0, (char*)padded.data(), NET_W*NET_H*4);
        ResizeConfig rcfg;
        rcfg.src_addr=(uint32_t)rs_src_addr; rcfg.dst_addr=(uint32_t)rs_dst_addr;
        rcfg.src_w=NET_W; rcfg.src_h=NET_H; rcfg.dst_w=DST_SZ; rcfg.dst_h=DST_SZ; rcfg.crop_enable=1;
        uint32_t rs_cycles2 = 0;
        if (!op_resize_run(&fpai_device, 0x400C0000, rcfg, 2000, &rs_cycles2)) return {};
        double rs_us = rs_cycles2 / 200.0;
        img_resize_us_last.store(rs_us);
        img_resize_us_sum.store(img_resize_us_sum.load() + rs_us);
        double fwd_ms2 = 0;
        auto emb = resize_out_to_emb(&fwd_ms2);
        if (!emb.empty()) {
            img_enc_count.fetch_add(1);
            img_frame_ms_last.store(fwd_ms2);
        }
        return emb;
    };

    // ============================================================
    // 顶层模式
    // ============================================================
    enum AppMode { M_IDLE, M_DUAL, M_SEARCH };
    std::atomic<int> app_mode{ M_IDLE };
    std::atomic<int> frame_cnt{0};
    std::atomic<bool> imk_armed{false};


    // ---------- 分类(dual)状态 ----------
    std::mutex cls_disp_mutex;
    std::string cls_top1 = "N/A";
    std::mutex add_mutex;
    std::deque<std::string> add_queue;             // 待添加标签
    std::atomic<bool> has_add{false};

    // 加标签 (编码+入库). 内部编码耗时, 编完再锁入库
    auto emit_web_labels = [&]() { std::cout << "[WEB] LABELS "; for(size_t i=0;i<labels.size();i++){if(i)std::cout<<",";std::cout<<labels[i];} std::cout << std::endl; };
    // 文本编码器状态事件
    auto emit_txt_enc_start = [&](const std::string& p) {
        std::cout << "[WEB] ENC text start " << p << std::endl;
    };
    auto emit_txt_enc_done = [&](const std::string& p, double gus) {
        txt_enc_count.fetch_add(1);
        txt_gather_us_last.store(gus);
        txt_gather_us_sum.store(txt_gather_us_sum.load() + gus);
        long c = txt_enc_count.load();
        double avg = c > 0 ? txt_gather_us_sum.load() / c : 0;
        std::cout << "[WEB] ENC text done " << p
                  << " gather_us=" << std::fixed << std::setprecision(1) << gus
                  << " count=" << c
                  << " avg_us=" << std::fixed << std::setprecision(1) << avg << std::endl;
    };
    // 图像编码器状态事件 (在分类回调里调用)
    auto emit_img_enc = [&](int frame_id) {
        long c = img_enc_count.load();
        double avg_rs = c > 0 ? img_resize_us_sum.load() / c : 0;
        double avg_fw = c > 0 ? fwht_us_sum.load() / c : 0;
        std::cout << "[WEB] ENC image frame=" << frame_id
                  << " resize_hw_us=" << std::fixed << std::setprecision(1) << img_resize_us_last.load()
                  << " resize_avg_us=" << std::fixed << std::setprecision(1) << avg_rs
                  << " vis_fwd_ms=" << std::fixed << std::setprecision(1) << img_frame_ms_last.load()
                  << " fwht_us=" << std::fixed << std::setprecision(1) << fwht_us_last.load()
                  << " fwht_avg_us=" << std::fixed << std::setprecision(1) << avg_fw
                  << " count=" << c << std::endl;
    };
    auto add_label = [&](const std::string& prompt) -> bool {
        { std::lock_guard<std::mutex> lk(label_mutex);
          if (std::find(labels.begin(), labels.end(), prompt) != labels.end()) {
              std::cerr << "[LABEL] 已存在: " << prompt << std::endl; return false; } }
        auto ids = tok.tokenize(prompt);
        emit_txt_enc_start(prompt);
        double gus = 0;
        auto feat = encode_text(ids, DATA_DIR, device, text_session, text_network,
                                fpai_device, gather_chunk, idx_addr, src_addr, dst_addr, &gus);
        if (feat.empty()) { std::cerr << "[LABEL] 编码失败: " << prompt << std::endl; return false; }
        emit_txt_enc_done(prompt, gus);
        std::lock_guard<std::mutex> lk(label_mutex);
        labels.push_back(prompt); label_feats.push_back(feat);
        std::cerr << "[LABEL] + '" << prompt << "' (共 " << labels.size() << ")" << std::endl;
        emit_web_labels();
        return true;
    };

    // ---------- 查找(search)状态 ----------
    std::mutex db_mutex;
    std::vector<std::vector<float>> feat_db;   // 已 l2norm
    std::vector<cv::Mat>            db_frames;  // HDMI显示用 DW×DH
    std::vector<int>               db_ids;
    std::vector<double>            db_ts;
    std::vector<std::string>       db_paths;   // 每项对应的 jpg 文件路径 (供 Web UI 读图)
    std::string db_source = "none";
    std::atomic<int> sr_sub{0};                // search 子状态: 0待机 1采集中 2查找就绪
    std::atomic<bool> cap_trigger{false};
    std::atomic<bool> cap_finish{false};
    std::atomic<bool> query_pending{false};
    std::string query_text;
    std::mutex sr_disp_mutex;
    std::atomic<int> top1_idx{-1};
    std::string top1_text = "";
    auto clear_db = [&]() {
        std::lock_guard<std::mutex> lk(db_mutex);
        feat_db.clear(); db_frames.clear(); db_ids.clear(); db_ts.clear(); db_paths.clear(); db_source="none";
    };
    // ============================================================
    // HDMI 回调: 按 app_mode 分发
    // ============================================================
    auto hd = std::make_unique<RGB565HDMIDisplay<FPAIDevice>>(0, fpai_device, DW, DH);
    HDMIDisplayActor<FPAIDevice, InputMessageForIcore> da(
        hd->getSinkId(), std::move(hd), fpai_device, bm, ca.getChunkGroupId(),
        [&](const InputMessageForIcore&, cv::Mat& f) {
            int n = frame_cnt.fetch_add(1);
            int mode = app_mode.load();

            // ============================================================
            // 模式一: 实时分类
            // ============================================================
            if (mode == M_DUAL) {

                // 处理待添加标签 (add 用到 text NPU + Gather, 在回调线程执行避免与 vis 冲突)
                if (has_add.load()) {
                    std::string prompt;
                    bool got = false;
                    { std::lock_guard<std::mutex> lk(add_mutex);
                      if (!add_queue.empty()) { prompt = add_queue.front(); add_queue.pop_front(); got = true; }
                      if (add_queue.empty()) has_add.store(false); }
                    if (got) add_label(prompt);
                }

                if (n % CLIP_INTV == 0) {
                    auto& reg = fpai_device.defaultRegRegion();

                    if (imk_armed.load()) {
                        auto emb = encode_camera_frame();
                        if (!emb.empty()) {
                            std::vector<std::pair<float,int>> scores;
                            { std::lock_guard<std::mutex> lk(label_mutex);
                              for (int i=0;i<(int)label_feats.size();++i)
                                  scores.push_back({ cosine(emb, label_feats[i]), i });
                              std::sort(scores.begin(),scores.end(),
                                        [](auto&a,auto&b){return a.first>b.first;});
                              // 输出全部 Top-K 原始 cos (阈值判断交给前端)
                              if (!scores.empty()) {
                                  std::ostringstream os;
                                  os << "[WEB] RESULT topk=";
                                  for (size_t r=0; r<scores.size(); ++r) {
                                      if (r) os << ",";
                                      os << labels[scores[r].second] << ":"
                                         << std::fixed << std::setprecision(4) << scores[r].first;
                                  }
                                  std::cout << os.str() << std::endl;
                                  // HDMI 叠加: clip_app 自行按默认阈值判断
                                  const float HDMI_TH = 0.25f;
                                  float cc = scores[0].first;
                                  std::string ct = labels[scores[0].second];
                                  char buf[96];
                                  if (cc >= HDMI_TH) snprintf(buf,sizeof(buf),"%s %.3f",ct.c_str(),cc);
                                  else               snprintf(buf,sizeof(buf),"No match (%.3f)",cc);
                                  { std::lock_guard<std::mutex> dlk(cls_disp_mutex); cls_top1=buf; }
                                  static std::string last="";
                                  if (ct!=last) {
                                      std::cerr << "[DUAL] Top-1 -> " << ct << " ("
                                                << std::fixed << std::setprecision(3) << cc << ")" << std::endl;
                                      last = ct; }
                              } }
                            // 图像编码器状态事件
                            emit_img_enc(n);
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
                // HDMI 叠加分类结果
                { std::lock_guard<std::mutex> dlk(cls_disp_mutex);
                  cv::putText(f, cls_top1, cv::Point(50,100),
                              cv::FONT_HERSHEY_DUPLEX, 2.0, cv::Scalar(0,255,0), 3); }
                return;
            }

            // ============================================================
            // 模式二: 查找
            // ============================================================
            if (mode == M_SEARCH) {
                int sub = sr_sub.load();

                // ---- 采集子模式 ----
                if (sub == 1) {
                    if (!imk_armed.load()) {
                        auto& reg = fpai_device.defaultRegRegion();
                        reg.write(IMK_BASE + 0x114, imk_addr);
                        std::vector<float> empty_vec;
                        initImageMake(fpai_device, 0, NET_W, NET_H, 3, imk_addr, 8, empty_vec, empty_vec);
                        reg.write(IMK_BASE + 0x254, 0x4);
                        imk_armed.store(true);
                    }
                    if (cap_trigger.exchange(false)) {
                        auto emb = encode_camera_frame();
                        if (!emb.empty()) {
                            int newid;
                            { std::lock_guard<std::mutex> lk(db_mutex);
                              newid = (int)feat_db.size(); }
                            // 存 jpg 供 Web UI 读取显示 (f 可能是 RGB565/非标准格式, 需转 BGR 8UC3)
                            char fn[64]; snprintf(fn, sizeof(fn), "cap_%03d.jpg", newid);
                            std::string jpath = CAP_FRAMES_DIR + fn;
                            try {
                                cv::Mat save_img;
                                if (f.type() == CV_8UC3) {
                                    save_img = f;
                                } else if (f.type() == CV_8UC4) {
                                    cv::cvtColor(f, save_img, cv::COLOR_BGRA2BGR);
                                } else if (f.type() == CV_8UC2) {
                                    // RGB565 (2字节/像素) -> BGR
                                    cv::cvtColor(f, save_img, cv::COLOR_BGR5652BGR);
                                } else if (f.channels() == 1) {
                                    cv::cvtColor(f, save_img, cv::COLOR_GRAY2BGR);
                                } else {
                                    // 兜底: 强转 8U 3通道
                                    f.convertTo(save_img, CV_8U);
                                    if (save_img.channels() != 3 && save_img.channels() != 1 && save_img.channels() != 4) {
                                        std::cerr << "[CAP] WARN 无法保存 jpg, type=" << f.type()
                                                  << " ch=" << f.channels() << ", 跳过存图" << std::endl;
                                        save_img = cv::Mat();
                                    }
                                }
                                if (!save_img.empty()) cv::imwrite(jpath, save_img);
                                else jpath = "";  // 存图失败, 路径置空
                            } catch (const cv::Exception& e) {
                                std::cerr << "[CAP] imwrite 异常(已捕获, 不影响采集): " << e.what() << std::endl;
                                jpath = "";
                            }
                            std::lock_guard<std::mutex> lk(db_mutex);
                            feat_db.push_back(emb); db_frames.push_back(f.clone());
                            db_ids.push_back(newid); db_ts.push_back(-1.0);
                            db_paths.push_back(jpath);
                            std::cerr << "[CAP] " << feat_db.size() << "/" << GALLERY_SIZE
                                      << " saved " << (jpath.empty() ? "(存图失败)" : jpath) << std::endl;
                        }
                        {
                            auto& reg = fpai_device.defaultRegRegion();
                            reg.write(IMK_BASE + 0x114, imk_addr);
                            std::vector<float> empty_vec;
                            initImageMake(fpai_device, 0, NET_W, NET_H, 3, imk_addr, 8, empty_vec, empty_vec);
                            reg.write(IMK_BASE + 0x254, 0x4);
                        }
                    }
                    bool full; { std::lock_guard<std::mutex> lk(db_mutex);
                                 full = (int)feat_db.size() >= GALLERY_SIZE; }
                    if (full || cap_finish.exchange(false)) {
                        { std::lock_guard<std::mutex> lk(db_mutex); db_source="camera"; }
                        sr_sub.store(2);
                        std::cerr << "\n[main] === 采集结束, 可查询 ===" << std::endl;
                    }
                    int cnt; { std::lock_guard<std::mutex> lk(db_mutex); cnt=(int)feat_db.size(); }
                    char buf[64]; snprintf(buf,sizeof(buf),"Capturing %d/%d (Enter=snap)",cnt,GALLERY_SIZE);
                    cv::putText(f, buf, cv::Point(40,90),
                                cv::FONT_HERSHEY_DUPLEX, 1.5, cv::Scalar(0,255,255), 3);
                    return;
                }

                // ---- 处理查询 (回调线程编码文本) ----
                if (query_pending.load()) {
                    std::string prompt = query_text;
                    query_pending.store(false);
                    std::cerr << "[TEXT] 编码: " << prompt << std::endl;
                    {
                        auto ids = tok.tokenize(prompt);
                        emit_txt_enc_start(prompt);
                        double gus = 0;
                        auto tf = encode_text(ids, DATA_DIR, device, text_session, text_network,
                                              fpai_device, gather_chunk, idx_addr, src_addr, dst_addr, &gus);
                        if (!tf.empty()) {
                            emit_txt_enc_done(prompt, gus);
                            std::vector<std::pair<float,int>> scores;
                            { std::lock_guard<std::mutex> lk(db_mutex);
                              for (int i=0;i<(int)feat_db.size();++i)
                                  scores.push_back({ cosine(tf, feat_db[i]), i }); }
                            std::sort(scores.begin(),scores.end(),
                                      [](auto&a,auto&b){return a.first>b.first;});
                            std::cout << "\n=== 检索结果 (查询: " << prompt << ") ===" << std::endl;
                            int topk = std::min(5,(int)scores.size());
                            for (int r=0;r<topk;r++) {
                                int ki=scores[r].second;
                                std::lock_guard<std::mutex> lk(db_mutex);
                                if (db_source=="video")
                                    printf("  Top %-2d: 帧#%-3d 原帧#%-5d t=%6.2fs cos=%.4f%s\n",
                                           r+1,ki,db_ids[ki],db_ts[ki],scores[r].first,(r==0?" <==":""));
                                else
                                    printf("  Top %-2d: 第%-2d张 cos=%.4f%s\n",
                                           r+1,ki,scores[r].first,(r==0?" <==":""));
                            }
                            std::cout << std::endl;
                            fflush(stdout);   // 同步 C stdio 缓冲(上面 printf), 保证顺序
                            // [WEB] SEARCH: 输出全部项 path:cos (阈值筛选交给前端), query 放最后
                            {
                                std::ostringstream os;
                                os << "[WEB] SEARCH n=" << scores.size() << " results=";
                                { std::lock_guard<std::mutex> lk(db_mutex);
                                  for (size_t r=0; r<scores.size(); ++r) {
                                      int ki = scores[r].second;
                                      std::string p = (ki < (int)db_paths.size()) ? db_paths[ki] : "";
                                      if (r) os << ";";
                                      os << p << ":" << std::fixed << std::setprecision(4) << scores[r].first;
                                  } }
                                os << " query=" << prompt;
                                std::cout << os.str() << std::endl;
                                std::cout.flush();   // 立即发出, 不留缓冲
                            }
                            // HDMI 显示 Top-1
                            if (!scores.empty()) {
                                int ki=scores[0].second; char buf[96];
                                { std::lock_guard<std::mutex> lk(db_mutex);
                                  if (db_source=="video")
                                      snprintf(buf,sizeof(buf),"%s t=%.2fs cos=%.3f",
                                               prompt.c_str(),db_ts[ki],scores[0].first);
                                  else
                                      snprintf(buf,sizeof(buf),"%s cos=%.3f",prompt.c_str(),scores[0].first); }
                                std::lock_guard<std::mutex> dlk(sr_disp_mutex);
                                top1_idx.store(ki); top1_text=buf;
                            }
                        }
                    }
                }

                // ---- 显示: Top-1命中 / 回放 / 待机 ----
                int t1 = top1_idx.load();
                if (t1 >= 0) {
                    std::lock_guard<std::mutex> lk(db_mutex);
                    std::lock_guard<std::mutex> dlk(sr_disp_mutex);
                    if (t1 < (int)db_frames.size()) {
                        db_frames[t1].copyTo(f);
                        cv::putText(f, top1_text, cv::Point(40,80),
                                    cv::FONT_HERSHEY_DUPLEX, 1.3, cv::Scalar(0,255,0), 3);
                    }
                } else {
                    std::lock_guard<std::mutex> lk(db_mutex);
                    if (!db_frames.empty()) {
                        // 时间驱动回放
                        static auto play_t0 = system_clock::now();
                        int el = (int)duration_cast<milliseconds>(system_clock::now()-play_t0).count();
                        int pi = (el/150) % (int)db_frames.size();
                        db_frames[pi].copyTo(f);
                        char buf[64];
                        if (db_source=="video")
                            snprintf(buf,sizeof(buf),"Play #%d/%d t=%.2fs",pi,(int)db_frames.size(),db_ts[pi]);
                        else
                            snprintf(buf,sizeof(buf),"Gallery #%d/%d",pi,(int)db_frames.size());
                        cv::putText(f, buf, cv::Point(40,80),
                                    cv::FONT_HERSHEY_DUPLEX, 1.0, cv::Scalar(255,255,0), 2);
                    } else {
                        cv::putText(f, "SEARCH: cap / vid <dir> <fps>", cv::Point(40,80),
                                    cv::FONT_HERSHEY_DUPLEX, 1.0, cv::Scalar(255,255,255), 2);
                    }
                }
                return;
            }

            // ============================================================
            // 待机 (未选模式)
            // ============================================================
            cv::putText(f, "IDLE: mode dual / mode search", cv::Point(40,90),
                        cv::FONT_HERSHEY_DUPLEX, 1.2, cv::Scalar(255,255,255), 2);
        });
    da.bindInputQueue(&dq);
    spdlog::set_level(spdlog::level::off);
    ca.start(); da.start();

    // ---------- 帮助 ----------
    auto print_help = [&]() {
        std::cout << "\n================= CLIP 命令 =================" << std::endl;
        std::cout << "[切换]" << std::endl;
        std::cout << "  mode dual      进入实时分类" << std::endl;
        std::cout << "  mode search    进入查找" << std::endl;
        std::cout << "  status         当前状态" << std::endl;
        std::cout << "  help           帮助 / 空行退出" << std::endl;
        std::cout << "[实时分类 (mode dual)]" << std::endl;
        std::cout << "  add <文本>     增加标签    del <文本> / del #<序号>  删除    list  列出" << std::endl;
        std::cout << "[查找 (mode search)]" << std::endl;
        std::cout << "  cap                       实时采集(回车采1张,满" << GALLERY_SIZE << "自动结束,done提前结束)" << std::endl;
        std::cout << "  vid <dir> <fps> [stride]  导入jpg序列 (例: vid board_data/frames/ 2.366 1)" << std::endl;
        std::cout << "  <文本>                    查询当前库    play  回到回放" << std::endl;
        std::cout << "=============================================" << std::endl << std::endl;
    };
    print_help();
    std::cout << "[main] 就绪. 先 'mode dual' 或 'mode search'" << std::endl;
    std::cout << "[WEB] READY" << std::endl;

    // ---------- 主线程: 命令解析 ----------
    auto trim = [](std::string s) {
        size_t a=s.find_first_not_of(" \t"); size_t b=s.find_last_not_of(" \t\r");
        return (a==std::string::npos) ? std::string("") : s.substr(a,b-a+1);
    };

    std::string line;
    while (std::getline(std::cin, line)) {
        int mode = app_mode.load();

        // 采集子模式: 回车=采一张, done=结束; 但 mode 切换命令仍放行到下方解析
        if (mode == M_SEARCH && sr_sub.load() == 1) {
            std::string t = trim(line);
            if (t == "done") { cap_finish.store(true); std::cout << "[main] 结束采集" << std::endl; continue; }
            if (t != "mode dual" && t != "mode search" && t != "help" && t != "status") {
                cap_trigger.store(true);  // 空行或任意 = 采一张
                continue;
            }
            // 否则(切模式/help/status) 落到下方正常解析
        }

        {
            std::string cmd = trim(line);
            // Web subprocess 模式: 空行是 snap(采一张)信号, 绝不退出进程.
            // 采集子模式(sr_sub==1)的空行已在上方处理; 走到这里的空行说明采集已结束或非采集态, 直接忽略.
            if (cmd.empty()) continue;

            // ---- 通用 ----
            if (cmd == "help") { print_help(); continue; }
            if (cmd == "status") {
                std::cout << "[status] mode=" << (mode==M_DUAL?"dual":mode==M_SEARCH?"search":"idle");
                if (mode==M_DUAL) { std::lock_guard<std::mutex> lk(label_mutex);
                                    std::cout << " 标签数=" << labels.size(); }
                if (mode==M_SEARCH){ std::lock_guard<std::mutex> lk(db_mutex);
                                     std::cout << " 库source=" << db_source << " 帧数=" << feat_db.size()
                                               << " 子状态=" << sr_sub.load(); }
                std::cout << std::endl; continue;
            }
            if (cmd == "mode dual") {
                top1_idx.store(-1);
                // 标签已在启动时加载, 无需运行时编码
                imk_armed.store(false);
                app_mode.store(M_DUAL);
                std::cout << "[WEB] MODE dual" << std::endl;
                std::cout << "[main] === 实时分类模式 === (add/del/list)" << std::endl;
                continue;
            }
            if (cmd == "mode search") {
                app_mode.store(M_SEARCH);
                std::cout << "[WEB] MODE search" << std::endl;
                imk_armed.store(false);
                sr_sub.store(0);
                top1_idx.store(-1);
                std::cout << "[main] === 查找模式 === (cap / vid <dir> <fps>)" << std::endl;
                continue;
            }

            // ---- 分类模式命令 ----
            if (mode == M_DUAL) {
                if (cmd == "list") {
                    std::lock_guard<std::mutex> lk(label_mutex);
                    std::cout << "标签 (" << labels.size() << "):" << std::endl;
                    for (int i=0;i<(int)labels.size();i++)
                        std::cout << "  #" << i << "  " << labels[i] << std::endl;
                }
                else if (cmd.rfind("add ",0)==0) {
                    std::string p = trim(cmd.substr(4));
                    if (p.empty()) { std::cout << "[main] add 需要文本" << std::endl; continue; }
                    { std::lock_guard<std::mutex> lk(add_mutex); add_queue.push_back(p); has_add.store(true); }
                    std::cout << "[main] 已排队添加: " << p << std::endl;
                }
                else if (cmd.rfind("del ",0)==0) {
                    std::string arg = trim(cmd.substr(4));
                    if (arg.empty()) { std::cout << "[main] del 需要参数" << std::endl; continue; }
                    std::lock_guard<std::mutex> lk(label_mutex);
                    if (arg[0]=='#') {
                        int idx = std::atoi(arg.c_str()+1);
                        if (idx>=0 && idx<(int)labels.size()) {
                            std::cout << "[main] - 删除 #" << idx << " '" << labels[idx] << "'" << std::endl;
                            labels.erase(labels.begin()+idx); label_feats.erase(label_feats.begin()+idx);
                emit_web_labels();
                        } else std::cout << "[main] 序号越界" << std::endl;
                    } else {
                        auto it = std::find(labels.begin(),labels.end(),arg);
                        if (it!=labels.end()) { int idx=it-labels.begin();
                            std::cout << "[main] - 删除 '" << arg << "'" << std::endl;
                            labels.erase(labels.begin()+idx); label_feats.erase(label_feats.begin()+idx);
                emit_web_labels();
                        } else std::cout << "[main] 未找到: " << arg << std::endl;
                    }
                    if (labels.empty()) std::cout << "[main] 警告: 标签已空!" << std::endl;
                }
                else { std::cout << "[main] 分类模式命令: add/del/list, 或 mode search 切换" << std::endl; }
                continue;
            }

            // ---- 查找模式命令 ----
            if (mode == M_SEARCH) {
                if (cmd == "play") { top1_idx.store(-1); std::cout << "[main] 回到回放/实时" << std::endl; }
                else if (cmd == "cap") {
                    clear_db(); imk_armed.store(false); top1_idx.store(-1);
                    sr_sub.store(1);
                    std::cout << "[main] 采集模式: 回车采1张 (满" << GALLERY_SIZE << "自动结束, done提前结束)" << std::endl;
                }
                else if (cmd.rfind("vid",0)==0) {
                    std::istringstream iss(cmd);
                    std::string kw,dir; double fps=30; int stride=15;
                    iss >> kw >> dir >> fps >> stride;
                    if (dir.empty()) { std::cout << "[main] 用法: vid <dir> <fps> [stride]" << std::endl; continue; }
                    if (dir.back()!='/') dir+="/";
                    if (fps<1e-6) fps=30; if (stride<1) stride=15;
                    auto jpgs = list_jpgs(dir);
                    std::cout << "[main] " << dir << " 共 " << jpgs.size() << " 张, stride=" << stride << ", 建库中..." << std::endl;
                    if (jpgs.empty()) { std::cout << "[main] 无jpg" << std::endl; continue; }
                    clear_db(); top1_idx.store(-1); sr_sub.store(0);  // 建库时子状态待机
                    std::vector<std::vector<float>> tf; std::vector<cv::Mat> tfr;
                    std::vector<int> tid; std::vector<double> tts;
                    std::vector<std::string> tpath;
                    for (size_t i=0;i<jpgs.size();i+=stride) {
                        cv::Mat frame = cv::imread(dir+jpgs[i], cv::IMREAD_COLOR);
                        if (frame.empty()) continue;
                        auto emb = encode_cv_frame(frame);
                        if (emb.empty()) continue;
                        tf.push_back(emb);
                        cv::Mat disp; cv::resize(frame,disp,cv::Size(DW,DH),0,0,cv::INTER_LINEAR);
                        tfr.push_back(disp); tid.push_back((int)i); tts.push_back((double)i/fps);
                        tpath.push_back(dir+jpgs[i]);   // 记录原 jpg 路径供 Web UI 读图
                        if (tf.size()%5==0) std::cout << "  已编码 " << tf.size() << " 帧..." << std::endl;
                    }
                    { std::lock_guard<std::mutex> lk(db_mutex);
                      feat_db=std::move(tf); db_frames=std::move(tfr);
                      db_ids=std::move(tid); db_ts=std::move(tts);
                      db_paths=std::move(tpath); db_source="video"; }
                    sr_sub.store(2);
                    std::cout << "[main] 视频库建好: " << feat_db.size() << " 帧, HDMI回放中" << std::endl;
                }
                else {
                    // 查询文本
                    { std::lock_guard<std::mutex> lk(db_mutex);
                      if (feat_db.empty()) { std::cout << "[main] 库为空, 先 cap 或 vid" << std::endl; continue; } }
                    query_text = cmd; query_pending.store(true);
                    std::cout << "[main] 查询: " << cmd << std::endl;
                }
                continue;
            }

            // ---- IDLE ----
            std::cout << "[main] 请先 mode dual 或 mode search" << std::endl;
        }
    }

    ca.stop(); da.stop();
    Device::Close(device);
    return 0;
}

/* CLIP Search 合并版: 实时采集 + 视频序列导入, 文本查找帧
 *
 * 一个程序, 模型加载一次, 两种建库方式:
 *   - cap: 实时摄像头采集 (按回车采1张, 满 gallery_size 张自动结束, 或 done 提前结束)
 *   - vid: 导入 PC 预处理好的 jpg 序列建库
 * 库覆盖式 (一次一个库). 查询引擎共用 (文本→余弦→Top-K).
 *
 * 背景: 板上 OpenCV 无 videoio, 视频须在 PC 端用 ffmpeg 抽成 jpg 序列:
 *   ffmpeg -i battle.mp4 -q:v 2 board_data/frames/frame_%04d.jpg
 *
 * 图像编码 (两种来源统一走): 
 *   - cap:  摄像头帧 → ImageMake(bypass,借前置hardResize→640×480) → 拼BGRX → resize硬算子 → vis
 *   - vid:  jpg帧 → cv::resize到640×480 → 拼BGRX → resize硬算子 → vis  (接法1, 跳过ImageMake)
 *
 * 用法: ./clip_search search_config.yaml
 * 命令:
 *   cap                          进入实时采集 (按回车采1张, 满N张自动结束; done 提前结束)
 *   vid <dir> <fps> [stride]     导入 jpg 序列建库
 *   <文本>                       查询当前库 → Top-K + HDMI 显示 Top-1
 *   play                         回到回放/实时 (清除 Top-1 显示)
 *   list                         当前库信息
 *   空行                         退出
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
// 文本编码器 (CPU查表→text NPU→FPGA Gather→CPU投影, 末尾l2norm)
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
    // [诊断] 文本链各步 nan 检查
    {
        bool seq_nan=false, eot_nan=false, tf_nan=false;
        for (int i=0;i<SEQ*DIM;i++) if (std::isnan(feat_seq_buf[i])) { seq_nan=true; break; }
        for (int i=0;i<DIM;i++) if (std::isnan(eot_feat[i])) { eot_nan=true; break; }
        for (int i=0;i<DIM;i++) if (std::isnan(text_feat[i])) { tf_nan=true; break; }
        std::cerr << "[TEXT-DBG] eot_idx=" << eot_idx
                  << " feat_seq_nan=" << seq_nan
                  << " eot_feat_nan=" << eot_nan
                  << " text_feat_nan=" << tf_nan
                  << " | eot_feat[0..3]=" << eot_feat[0] << "," << eot_feat[1] << "," << eot_feat[2] << "," << eot_feat[3]
                  << " proj_size=" << proj.size() << std::endl;
    }
    l2norm(text_feat);
    return text_feat;
}

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
    std::cerr << "=== CLIP Search 合并版: 实时采集 + 视频序列导入 ===" << std::endl;

    if (argc < 2) { std::cerr << "用法: " << argv[0] << " <search_config.yaml>" << std::endl; return 1; }
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
    int GALLERY_SIZE = cfg["gallery_size"] ? cfg["gallery_size"].as<int>() : 20;
    if (!DATA_DIR.empty() && DATA_DIR.back() != '/') DATA_DIR += "/";

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

    // ---------- 视觉预处理参数 ----------
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

    // resize 输出 BGRX → CPU归一化 → vis NPU → emb  (两种来源共用后半段)
    auto resize_out_to_emb = [&]() -> std::vector<float> {
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
        auto out = vis_session.forward({t});
        for (auto& ot : out) ot.waitForReady(std::chrono::milliseconds(5000));
        auto emb_t = out[0].to(HostDevice::MemRegion());
        std::vector<float> emb((const float*)emb_t.data().cptr(),
                               (const float*)emb_t.data().cptr()+DIM);
        device.reset(1);
        {   // 诊断: 图像 emb (l2norm前)
            bool nan=false; double sum=0;
            for(int i=0;i<DIM;i++){ if(std::isnan(emb[i]))nan=true; sum+=emb[i]*emb[i]; }
            std::cerr << "[EMB-DBG] emb[0..3]=" << emb[0]<<","<<emb[1]<<","<<emb[2]<<","<<emb[3]
                      << " nan="<<nan<<" norm2="<<sum<<std::endl;
        }
        l2norm(emb);
        return emb;
    };

    // 摄像头帧 → emb (ImageMake + resize硬算子)
    auto encode_camera_frame = [&]() -> std::vector<float> {
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
        if (!op_resize_run(&fpai_device, 0x400C0000, rcfg, 2000, &rs_cycles)) return {};
        return resize_out_to_emb();
    };

    // jpg帧(cv::Mat BGR) → emb (cv::resize640 + resize硬算子, 接法1)
    auto encode_cv_frame = [&](const cv::Mat& frame_bgr) -> std::vector<float> {
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
                    uint32_t rs_cycles;
        if (!op_resize_run(&fpai_device, 0x400C0000, rcfg, 2000, &rs_cycles)) return {};
        return resize_out_to_emb();
    };

    // ========================================================
    // 库 (覆盖式): 采集/视频统一填这套
    // ========================================================
    std::mutex db_mutex;
    std::vector<std::vector<float>> feat_db;
    std::vector<cv::Mat>            db_frames;    // HDMI显示用 (DW×DH)
    std::vector<int>               db_ids;        // 帧号 (采集=序号; 视频=原始帧号)
    std::vector<double>            db_ts;         // 时间戳 (视频有; 采集为-1)
    std::string db_source = "none";               // "camera" / "video"

    // 视频回放帧 (全部帧, JPEG压缩存储, 30fps+ 流畅回放)
    std::vector<std::vector<uint8_t>> video_frames_jpg;

    auto clear_db = [&]() {
        std::lock_guard<std::mutex> lk(db_mutex);
        feat_db.clear(); db_frames.clear(); db_ids.clear(); db_ts.clear();
        video_frames_jpg.clear(); db_source = "none";
    };

    // ---------- 显示 / 交互 状态 ----------
    enum Mode { IDLE, CAPTURING, PLAYING };  // IDLE:待机  CAPTURING:采集中  PLAYING:视频回放/查询
    std::atomic<int> mode{ IDLE };
    std::atomic<int> frame_cnt{0};
    std::atomic<bool> imk_armed{false};

    // 采集: 定时自动采样 (4fps, 10秒, 共40帧)
    const int CAPTURE_DURATION_S = 10;
    const int SAMPLE_RATE_HZ = 4;
    const int SAMPLE_INTERVAL_MS = 1000 / SAMPLE_RATE_HZ;  // 250ms
    const int TOTAL_SAMPLES = CAPTURE_DURATION_S * SAMPLE_RATE_HZ; // 40
    steady_clock::time_point capture_start_time;
    steady_clock::time_point last_sample_time;
    int capture_sample_count = 0;
    std::atomic<bool> cap_finish{false};   // done 提前结束

    // 查询: 主线程置位 → 回调线程编码查询
    std::atomic<bool> query_pending{false};
    std::string query_text;

    std::mutex disp_mutex;
    std::atomic<int> top1_idx{-1};   // 查询命中的库索引 (-1=不显示命中)
    std::string top1_text = "";

    // ========================================================
    // HDMI 回调
    // ========================================================
    auto hd = std::make_unique<RGB565HDMIDisplay<FPAIDevice>>(0, fpai_device, DW, DH);
    HDMIDisplayActor<FPAIDevice, InputMessageForIcore> da(
        hd->getSinkId(), std::move(hd), fpai_device, bm, ca.getChunkGroupId(),
        [&](const InputMessageForIcore&, cv::Mat& f) {
            int n = frame_cnt.fetch_add(1);
            int m = mode.load();

            // ============ 采集模式 (定时自动采样 4fps × 10s) ============
            if (m == CAPTURING) {
                auto now = steady_clock::now();
                // arm ImageMake (首次)
                if (!imk_armed.load()) {
                    auto& reg = fpai_device.defaultRegRegion();
                    reg.write(IMK_BASE + 0x114, imk_addr);
                    std::vector<float> ev;
                    initImageMake(fpai_device, 0, NET_W, NET_H, 3, imk_addr, 8, ev, ev);
                    reg.write(IMK_BASE + 0x254, 0x4);
                    imk_armed.store(true);
                    last_sample_time = now;
                }
                // 保存全帧用于回放 (RGB565→BGR→JPEG压缩, ~100KB/帧, 1920×1080)
                {
                    cv::Mat bgr;
                    if (f.type() == CV_8UC2)
                        cv::cvtColor(f, bgr, cv::COLOR_BGR5652BGR);
                    else if (f.channels() == 4)
                        cv::cvtColor(f, bgr, cv::COLOR_BGRA2BGR);
                    else
                        bgr = f;
                    std::vector<uint8_t> jpg;
                    cv::imencode(".jpg", bgr, jpg, {cv::IMWRITE_JPEG_QUALITY, 60});
                    video_frames_jpg.push_back(std::move(jpg));
                }
                // 每 SAMPLE_INTERVAL_MS 采样一帧编码入库
                auto elapsed_since_sample = duration_cast<milliseconds>(now - last_sample_time).count();
                if (elapsed_since_sample >= SAMPLE_INTERVAL_MS) {
                    last_sample_time = now;
                    auto emb = encode_camera_frame();
                    if (!emb.empty()) {
                        std::lock_guard<std::mutex> lk(db_mutex);
                        feat_db.push_back(emb);
                        db_frames.push_back(f.clone());
                        db_ids.push_back(capture_sample_count);
                        db_ts.push_back(capture_sample_count * 0.25);  // 4fps → 0.25s间隔
                        capture_sample_count++;
                        std::cerr << "[CAP] 采样 " << capture_sample_count << "/" << TOTAL_SAMPLES << std::endl;
                    }
                    // re-arm ImageMake
                    auto& reg = fpai_device.defaultRegRegion();
                    reg.write(IMK_BASE + 0x114, imk_addr);
                    std::vector<float> ev;
                    initImageMake(fpai_device, 0, NET_W, NET_H, 3, imk_addr, 8, ev, ev);
                    reg.write(IMK_BASE + 0x254, 0x4);
                }
                // 10秒到 或 done → 结束采集
                auto elapsed_total = duration_cast<milliseconds>(now - capture_start_time).count();
                if (elapsed_total >= CAPTURE_DURATION_S * 1000 || cap_finish.exchange(false)) {
                    { std::lock_guard<std::mutex> lk(db_mutex); db_source = "camera"; }
                    mode.store(PLAYING);
                    std::cerr << "\n[main] === 采集结束 (" << feat_db.size()
                              << " 采样帧, " << video_frames_jpg.size() << " 回放帧) ===" << std::endl;
                }
                // 显示实时画面 + 进度 + 倒计时
                int remain_s = CAPTURE_DURATION_S - (int)(elapsed_total / 1000);
                if (remain_s < 0) remain_s = 0;
                char buf[96];
                snprintf(buf, sizeof(buf), "Capturing %d/%d  %ds left",
                         capture_sample_count, TOTAL_SAMPLES, remain_s);
                cv::putText(f, buf, cv::Point(40, 90),
                            cv::FONT_HERSHEY_DUPLEX, 1.5, cv::Scalar(0,255,255), 3);
                return;
            }

            // ============ 处理查询 (回调线程编码文本) ============
            if (query_pending.load()) {
                std::string prompt = query_text;
                query_pending.store(false);
                std::cerr << "[TEXT] 编码: " << prompt << std::endl;
                if (tokenize_prompt(prompt, DATA_DIR)) {
                    auto tf = encode_text(prompt, DATA_DIR, device, text_session, text_network,
                                          fpai_device, gather_chunk, idx_addr, src_addr, dst_addr);
                    if (!tf.empty()) {
                        std::vector<std::pair<float,int>> scores;
                        { std::lock_guard<std::mutex> lk(db_mutex);
                          for (int i = 0; i < (int)feat_db.size(); ++i)
                              scores.push_back({ cosine(tf, feat_db[i]), i }); }
                        std::sort(scores.begin(), scores.end(),
                                  [](auto& a, auto& b){ return a.first > b.first; });
                        std::cout << "\n=== 检索结果 (查询: " << prompt << ") ===" << std::endl;
                        int topk = std::min(5, (int)scores.size());
                        for (int r = 0; r < topk; r++) {
                            int ki = scores[r].second;
                            std::lock_guard<std::mutex> lk(db_mutex);
                            if (db_source == "video")
                                printf("  Top %-2d: 帧#%-3d 原帧#%-5d t=%6.2fs cos=%.4f%s\n",
                                       r+1, ki, db_ids[ki], db_ts[ki], scores[r].first, (r==0?" <==":""));
                            else
                                printf("  Top %-2d: 第%-2d张 cos=%.4f%s\n",
                                       r+1, ki, scores[r].first, (r==0?" <==":""));
                        }
                        std::cout << std::endl;
                        if (!scores.empty()) {
                            int ki = scores[0].second;
                            char buf[96];
                            { std::lock_guard<std::mutex> lk(db_mutex);
                              if (db_source == "video")
                                  snprintf(buf, sizeof(buf), "%s t=%.2fs cos=%.3f",
                                           prompt.c_str(), db_ts[ki], scores[0].first);
                              else
                                  snprintf(buf, sizeof(buf), "%s cos=%.3f", prompt.c_str(), scores[0].first); }
                            std::lock_guard<std::mutex> dlk(disp_mutex);
                            top1_idx.store(ki); top1_text = buf;
                        }
                    }
                }
            }

            // ============ 显示: Top-1命中帧 / 回放 / 待机 ============
            int t1 = top1_idx.load();
            if (t1 >= 0) {
                std::lock_guard<std::mutex> lk(db_mutex);
                std::lock_guard<std::mutex> dlk(disp_mutex);
                if (t1 < (int)db_frames.size()) {
                    db_frames[t1].copyTo(f);
                    cv::putText(f, top1_text, cv::Point(40, 80),
                                cv::FONT_HERSHEY_DUPLEX, 1.3, cv::Scalar(0,255,0), 3);
                }
            } else if (m == PLAYING) {
                std::lock_guard<std::mutex> lk(db_mutex);
                // cap 来源: 用 video_frames_jpg 全帧回放 (JPEG解码, 30fps+ 流畅)
                if (db_source == "camera" && !video_frames_jpg.empty()) {
                    auto now = steady_clock::now();
                    auto elapsed = duration_cast<milliseconds>(now - capture_start_time).count();
                    auto cycle_ms = elapsed % (CAPTURE_DURATION_S * 1000);
                    int idx = (int)(cycle_ms * video_frames_jpg.size() / (CAPTURE_DURATION_S * 1000));
                    if (idx >= (int)video_frames_jpg.size()) idx = (int)video_frames_jpg.size() - 1;
                    cv::Mat decoded = cv::imdecode(video_frames_jpg[idx], cv::IMREAD_COLOR);
                    if (!decoded.empty()) {
                        if (f.type() == CV_8UC2)
                            cv::cvtColor(decoded, f, cv::COLOR_BGR2BGR565);
                        else
                            decoded.copyTo(f);
                    }
                    char buf[96];
                    snprintf(buf, sizeof(buf), "Replay %.1fs  #%d/%d",
                             cycle_ms / 1000.0, idx, (int)video_frames_jpg.size());
                    cv::putText(f, buf, cv::Point(40, 80),
                                cv::FONT_HERSHEY_DUPLEX, 1.0, cv::Scalar(255,255,0), 2);
                } else if (!db_frames.empty()) {
                    // vid 来源: 原有回放逻辑
                    int play_idx = (n / 3) % (int)db_frames.size();
                    db_frames[play_idx].copyTo(f);
                    char buf[64];
                    snprintf(buf, sizeof(buf), "Play #%d/%d t=%.2fs",
                             play_idx, (int)db_frames.size(), db_ts[play_idx]);
                    cv::putText(f, buf, cv::Point(40, 80),
                                cv::FONT_HERSHEY_DUPLEX, 1.0, cv::Scalar(255,255,0), 2);
                }
            } else {
                // IDLE 待机: 实时画面 + 提示
                cv::putText(f, "IDLE: cap / vid <dir> <fps>", cv::Point(40, 80),
                            cv::FONT_HERSHEY_DUPLEX, 1.0, cv::Scalar(255,255,255), 2);
            }
        });
    da.bindInputQueue(&dq);
    spdlog::set_level(spdlog::level::warn);
    ca.start(); da.start();

    // ---------- 命令帮助 ----------
    auto print_help = [&]() {
        std::cout << "\n=== CLIP Search 命令 ===" << std::endl;
        std::cout << "  cap                        自动采集" << CAPTURE_DURATION_S << "s ("
                  << SAMPLE_RATE_HZ << "fps采样编码, 全帧回放, done提前结束)" << std::endl;
        std::cout << "  vid <dir> <fps> [stride]   导入jpg序列建库 (例: vid board_data/frames/ 30 15)" << std::endl;
        std::cout << "  <文本>                     查询当前库 → Top-K + HDMI显示Top-1" << std::endl;
        std::cout << "  play                       回到回放/实时(清除Top-1)" << std::endl;
        std::cout << "  list                       当前库信息" << std::endl;
        std::cout << "  help                       显示此帮助" << std::endl;
        std::cout << "  空行                       退出" << std::endl << std::endl;
    };
    print_help();

    // ---------- 主线程: 命令解析 ----------
    std::string line;
    while (std::getline(std::cin, line)) {
        // 采集模式下, done 提前结束
        if (mode.load() == CAPTURING) {
            std::string t = line;
            size_t s = t.find_first_not_of(" \t"); size_t e = t.find_last_not_of(" \t\r");
            if (s != std::string::npos) t = t.substr(s, e-s+1); else t = "";
            if (t == "done") { cap_finish.store(true); std::cout << "[main] 结束采集" << std::endl; }
            continue;
        }

        if (line.empty()) break;  // 非采集模式, 空行退出
        size_t s = line.find_first_not_of(" \t"); size_t e = line.find_last_not_of(" \t\r");
        if (s == std::string::npos) continue;
        line = line.substr(s, e-s+1);

        if (line == "help") { print_help(); }
        else if (line == "list") {
            std::lock_guard<std::mutex> lk(db_mutex);
            std::cout << "当前库: source=" << db_source << ", 帧数=" << feat_db.size() << std::endl;
        }
        else if (line == "play") { top1_idx.store(-1); std::cout << "[main] 回到回放/实时" << std::endl; }
        else if (line == "cap") {
            clear_db();
            imk_armed.store(false);
            top1_idx.store(-1);
            capture_start_time = steady_clock::now();
            last_sample_time = capture_start_time;
            capture_sample_count = 0;
            mode.store(CAPTURING);
            std::cout << "[main] 自动采集 " << CAPTURE_DURATION_S << "s, "
                      << SAMPLE_RATE_HZ << "fps 采样编码 (共" << TOTAL_SAMPLES << "帧)"
                      << ", 全帧回放" << std::endl;
        }
        else if (line.rfind("vid", 0) == 0) {
            std::istringstream iss(line);
            std::string kw, dir; double fps = 30; int stride = 15;
            iss >> kw >> dir >> fps >> stride;
            if (dir.empty()) { std::cout << "[main] 用法: vid <dir> <fps> [stride]" << std::endl; continue; }
            if (dir.back() != '/') dir += "/";
            if (fps < 1e-6) fps = 30;
            if (stride < 1) stride = 15;

            auto jpgs = list_jpgs(dir);
            std::cout << "[main] " << dir << " 共 " << jpgs.size() << " 张, stride=" << stride << ", 建库中..." << std::endl;
            if (jpgs.empty()) { std::cout << "[main] 无jpg" << std::endl; continue; }

            clear_db();
            top1_idx.store(-1);
            mode.store(IDLE);  // 建库时先待机, 避免回调抢 device
            // 主线程建库 (直接调 vis, 此时回调不会同时用 device: mode=IDLE且无query)
            std::vector<std::vector<float>> tmp_feat;
            std::vector<cv::Mat> tmp_frames;
            std::vector<int> tmp_ids; std::vector<double> tmp_ts;
            for (size_t i = 0; i < jpgs.size(); i += stride) {
                cv::Mat frame = cv::imread(dir + jpgs[i], cv::IMREAD_COLOR);
                if (frame.empty()) continue;
                auto emb = encode_cv_frame(frame);
                if (emb.empty()) continue;
                tmp_feat.push_back(emb);
                cv::Mat disp; cv::resize(frame, disp, cv::Size(DW, DH), 0, 0, cv::INTER_LINEAR);
                tmp_frames.push_back(disp);
                tmp_ids.push_back((int)i);
                tmp_ts.push_back((double)i / fps);
                if (tmp_feat.size() % 5 == 0)
                    std::cout << "  已编码 " << tmp_feat.size() << " 帧..." << std::endl;
            }
            {
                std::lock_guard<std::mutex> lk(db_mutex);
                feat_db = std::move(tmp_feat); db_frames = std::move(tmp_frames);
                db_ids = std::move(tmp_ids); db_ts = std::move(tmp_ts);
                db_source = "video";
            }
            mode.store(PLAYING);
            std::cout << "[main] 视频库建好: " << feat_db.size() << " 帧, HDMI回放中" << std::endl;
        }
        else {
            // 当作查询文本
            { std::lock_guard<std::mutex> lk(db_mutex);
              if (feat_db.empty()) { std::cout << "[main] 库为空, 先 cap 或 vid 建库" << std::endl; continue; } }
            query_text = line;
            query_pending.store(true);
            std::cout << "[main] 查询: " << line << std::endl;
        }
    }

    ca.stop(); da.stop();
    Device::Close(device);
    return 0;
}

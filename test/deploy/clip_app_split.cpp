/* CLIP 合并程序 (split 版): 实时分类 + 查找 (采集/视频), 模型加载一次
 *
 * 与 clip_app_web 的区别: 视觉编码器由"单模型 vis"改为
 *   seg_pre (NPU) → FWHT 硬算子 (FPGA) → seg_post (NPU) 三段切分链路
 *   (对齐 clip_vit_hadamard_split 板上验证版, cosine 0.990)
 *
 * 两大功能, 共用 text+pre+post 模型和硬算子链, 用 mode 切换:
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
 *   - 摄像头帧: ImageMake(bypass,借前置hardResize→640×480) → 拼BGRX → resize硬算子 → CPU归一化
 *               → seg_pre NPU → FWHT 硬算子 → seg_post NPU → emb
 *   - jpg帧:    cv::resize到640×480 → 拼BGRX → resize硬算子 → CPU归一化 → 同上
 * 文本编码: CPU查表 → text NPU → FPGA Gather(取EOT) → CPU投影 → l2norm
 *
 * 板上 OpenCV 无 videoio, 视频须 PC 端 ffmpeg/脚本抽成 jpg 序列.
 *
 * 用法: ./clip_app_split app_config_split.yaml
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
// ============================================================
// FP16 转换 + FWHT 一跳 (对齐 clip_vit_hadamard_split 验证版)
// ============================================================
// float -> FP16(round-to-nearest-even),与 hadamard_test / golden 一致
static uint16_t float_to_fp16(float x) {
    if (x == 0.0f) return 0;
    uint16_t sign = (x < 0) ? 0x8000 : 0;
    float abs_x = (x < 0) ? -x : x;
    if (abs_x < 6.0e-8f) return sign;
    if (abs_x > 65504.0f) return sign | 0x7C00;
    int exp; float mant = frexpf(abs_x, &exp);
    int e = exp + 14;
    if (e <= 0) { mant *= (1 << (-e + 1)); return sign | ((uint16_t)mant & 0x3FF); }
    if (e >= 31) return sign | 0x7C00;
    // frac = (2*mant - 1) * 1024, 10-bit 尾数; 不能用 (mant*2048)&0x7FF>>1 (缺 -1024 偏置)
    int frac = (int)(mant * 2048.0f + 0.5f) - 1024;   // round-to-nearest
    if (frac >= 1024) { e++; frac = 0; }
    return sign | ((e & 0x1F) << 10) | (frac & 0x3FF);
}
// FP16 -> float(补齐 hadamard_test 缺的反向,对齐 golden 的 fp16_to_float)
static float fp16_to_float(uint16_t h) {
    uint16_t s = (h >> 15) & 1, e = (h >> 10) & 0x1F, f = h & 0x3FF;
    float v;
    if (e == 0)         v = std::ldexp((float)f, -24);
    else if (e == 0x1F) v = f ? NAN : INFINITY;
    else                v = std::ldexp((float)(f | 0x400), (int)e - 25);
    return s ? -v : v;
}
// FWHT 一跳: in[num_vec*768] float -> out[num_vec*768] float
// 复用 main 预分配的 chunk (gather 之后低地址), 不内部 malloc
// 返回: FWHT 硬件执行耗时 us (= cycles/200.0, 不含 host 打包/DMA 开销)
static double run_hadamard_768(FPAIDevice& fpai_device, uint32_t reg_base,
                               MemChunk& chunk, uint32_t src_off, uint32_t dst_off,
                               const float* in, float* out, int num_vectors) {
    const uint32_t REG_START = reg_base + 0xC4, REG_DONE   = reg_base + 0x100,
                   REG_RESET = reg_base + 0x1DC, REG_DW    = reg_base + 0x1C,
                   REG_PREC  = reg_base + 0x20,  REG_RBASE = reg_base + 0xC8,
                   REG_WBASE = reg_base + 0xCC,  REG_WRSIZE= reg_base + 0xD0,
                   REG_CYCLE = reg_base + 0x88;
    const int TOTAL_BLOCKS = num_vectors * 768 / 32;   // 50*768/32 = 1200
    const int src_size = TOTAL_BLOCKS * 64, dst_size = src_size;
    uint32_t src_addr = (uint32_t)(chunk->begin.addr() + src_off);
    uint32_t dst_addr = (uint32_t)(chunk->begin.addr() + dst_off);

    // float -> FP16 -> 块内字节序(lane 逆序 + 高字节在前),照 pack_to_blocks
    std::vector<int8_t> src_buf(src_size, 0);
    for (int b = 0; b < TOTAL_BLOCKS; b++)
        for (int j = 0; j < 32; j++) {
            uint16_t hf = float_to_fp16(in[b*32 + j]);
            // 修复: 小端布局 (低字节在 2j), 与硬件 lane 提取 fwht_regs[i]=din[16i+15:16i] 匹配
            src_buf[b*64 + j*2]     =  hf       & 0xFF;
            src_buf[b*64 + j*2 + 1] = (hf >> 8) & 0xFF;
        }

    auto& reg = fpai_device.defaultRegRegion();
    // 复位: 寄存器顺序写, 写后读回作 AXI 同步屏障 (确保复位写已到达 FPGA 再 START,
    // 避免 START 与复位释放的时序竞争导致 DONE 偶发不置位)
    reg.write(REG_RESET, 1, false);   // FPGA 算子侧复位
    reg.write(REG_RESET, 0, false);
    reg.read(REG_RESET, false);       // 同步屏障: 读回等待前面的写完成

    chunk.write(src_off, (char*)src_buf.data(), src_size);

    reg.write(REG_DW,    2, false);
    reg.write(REG_PREC,  1, false);                  // FP16
    reg.write(REG_RBASE, src_addr, false);
    reg.write(REG_WBASE, dst_addr, false);
    reg.write(REG_WRSIZE, TOTAL_BLOCKS, false);      // 总 block 数
    reg.write(REG_START, 1, false);

    auto t0 = system_clock::now(); int done = 0;
    while (!done) {
        done = reg.read(REG_DONE, false);
        if (duration_cast<milliseconds>(system_clock::now() - t0).count() > 2000) {
            std::cerr << "[FWHT] timeout (2s)" << std::endl; return 0.0;
        }
    }

    std::vector<int8_t> dst_buf(dst_size);
    chunk.read((char*)dst_buf.data(), dst_off, dst_size);
    for (int b = 0; b < TOTAL_BLOCKS; b++)
        for (int j = 0; j < 32; j++) {
            uint16_t hf = ((uint8_t)dst_buf[b*64 + j*2 + 1] << 8) |
                           (uint8_t)dst_buf[b*64 + j*2];   // 小端解包, 与打包对称
            out[b*32 + j] = fp16_to_float(hf);
        }

    // 硬件执行耗时 = cycles / 200MHz (板上展示口径, 不含 host 打包/DMA)
    uint32_t cyc = reg.read(REG_CYCLE, false);
    double hw_us = cyc / 200.0;
    static int fwht_print_cnt = 0;   // 仅前 3 次打印, 避免每帧刷屏
    if (fwht_print_cnt < 3) {
        std::cout << "[FWHT] cycles = " << cyc << " (" << hw_us << " us @200MHz)" << std::endl;
        fwht_print_cnt++;
    }
    return hw_us;
}

// 调试打印 (stdout + 相对时间戳, 定位慢点/卡点用; 调试完删除)
static void dbg(const char* tag) {
    static auto t0 = system_clock::now();
    std::cout << "[DBG " << std::fixed << std::setprecision(1)
              << duration_cast<milliseconds>(system_clock::now() - t0).count() / 1000.0
              << "s] " << tag << std::endl;
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
    if (token_emb.empty() || input_ids.empty()) {
        std::cerr << "[TEXT] token_emb 读取失败或 input_ids 空: token_emb=" << token_emb.size()
                  << " ids=" << input_ids.size() << std::endl;
        return {};
    }

    std::cout << "[TOK]";
    for (int i = 0; i < 10 && i < (int)input_ids.size(); i++)
        std::cout << " " << input_ids[i];
    std::cout << " ...";
    for (int i = 70; i < 77 && i < (int)input_ids.size(); i++)
        std::cout << " " << input_ids[i];
    std::cout << std::endl;

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
        // ★测试A: 去掉 text 路径 device.reset(1) — 全局 reset 可能破坏 pre/post 会话上下文 (3会话)
    }
    Tensor in_real = data2Tensor(mid_in.data(), text_network.inputs()[0]);
    dbg("text fwd");
    auto out = text_session.forward({in_real});
    bool txt_ok = true;
    for (auto& t : out) txt_ok = txt_ok && t.waitForReady(std::chrono::milliseconds(2000));
    dbg("text fwd done");
    if (!txt_ok) {
        // NPU 偶发挂起自愈: 文本编码失败返回空, 调用方跳过该标签
        std::cout << "[WARN] text not ready, abort label" << std::endl;
        device.reset(1);
        return {};
    }
    // ★测试A: 去掉 text 路径 device.reset(1)

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
    dbg("gather start");

    auto t0 = system_clock::now();
    int done = 0;
    while (!done) {
        done = reg.read(GATHER_BASE + 0x80, false);
        if (duration_cast<milliseconds>(system_clock::now() - t0).count() > 10000) {
            std::cerr << "[TEXT] Gather timeout" << std::endl; return {};
        }
    }
    dbg("gather done");
    if (out_gather_us) *out_gather_us = reg.read(GATHER_BASE + 0x84, false) / 200.0;

    std::vector<float> eot_feat(DIM);
    gather_chunk.read((char*)eot_feat.data(), indices_size + 4096 + src_data_size + 4096, DIM * sizeof(float));

    auto proj = read_float_bin(data_dir + "text_proj.bin", (size_t)DIM * DIM);
    if (proj.empty()) {
        std::cerr << "[TEXT] text_proj.bin 读取失败" << std::endl;
        return {};
    }
    std::vector<float> text_feat(DIM, 0.f);
    for (int i = 0; i < DIM; i++) {
        float s = 0;
        for (int k = 0; k < DIM; k++) s += eot_feat[k] * proj[(size_t)k*DIM + i];
        text_feat[i] = s;
    }
    l2norm(text_feat);
    // 监测: 每次文本编码后输出前 5 个值 (stdout, 与 Web 日志同流)
    std::cout << "[TEXT] feat[:5] = " << std::fixed << std::setprecision(4)
              << text_feat[0] << " " << text_feat[1] << " " << text_feat[2] << " "
              << text_feat[3] << " " << text_feat[4] << std::endl;
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
    std::string PRE_JSON    = cfg["pre_json"].as<std::string>();
    std::string PRE_RAW     = cfg["pre_raw"].as<std::string>();
    std::string POST_JSON   = cfg["post_json"].as<std::string>();
    std::string POST_RAW    = cfg["post_raw"].as<std::string>();
    std::string TEXT_JSON   = cfg["text_json"].as<std::string>();
    std::string TEXT_RAW    = cfg["text_raw"].as<std::string>();
    std::string DATA_DIR    = cfg["data_dir"].as<std::string>();
    std::string LABELS_TXT  = cfg["labels_txt"] ? cfg["labels_txt"].as<std::string>() : "";
    int CLIP_INTV    = cfg["clip_interval"] ? cfg["clip_interval"].as<int>() : 5;
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
    // NPU 任务等待下限: 默认 10s, 偶发 NPU 挂起会让单帧卡 10s+, 缩到 2s
    // (waitForReady 超时返回 false 后走丢帧自愈, 不再卡 30s)
    device.setWaitTime(2000);
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

    // ---------- FWHT chunk: gather 之后、会话之前 malloc (不抢占 gather 低地址) ----------
    const int FWHT_VEC = 768, FWHT_NUM = 50;          // 50 向量 (49 patch + 1 cls)
    const int FWHT_ELEMS = FWHT_VEC * FWHT_NUM;       // 38400
    const int FWHT_BLOCKS = FWHT_ELEMS / 32;           // 1200
    const int FWHT_PAD = 4096;
    auto fwht_chunk = fpai_device.defaultMemRegion().malloc(
        FWHT_BLOCKS * 64 * 2 + FWHT_PAD * 3, 0, 64);
    uint64_t fwht_base = fwht_chunk->begin.addr();
    uint32_t fwht_src_off = FWHT_PAD;
    uint32_t fwht_dst_off = fwht_src_off + FWHT_BLOCKS * 64 + FWHT_PAD;
    std::cerr << "[main] FWHT chunk (gather 后): base=0x" << std::hex << fwht_base
              << " src=0x" << (fwht_base + fwht_src_off)
              << " dst=0x" << (fwht_base + fwht_dst_off) << std::dec << std::endl;

    // ---------- 双模型加载 (一次) ----------
    std::cerr << "[main] loading text model..." << std::endl;
    auto text_network = loadNetwork(TEXT_JSON, TEXT_RAW);
    auto text_session = initSession("zg330", text_network, device, 4, true, true, false);
    text_session.apply();
    std::cerr << "[main] loading seg_pre model..." << std::endl;
    auto pre_network = loadNetwork(PRE_JSON, PRE_RAW);
    auto pre_session = initSession("zg330", pre_network, device, 4, true, true, false);
    pre_session.apply();
    std::cerr << "[main] loading seg_post model..." << std::endl;
    auto post_network = loadNetwork(POST_JSON, POST_RAW);
    auto post_session = initSession("zg330", post_network, device, 4, true, true, false);
    post_session.apply();

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
        // 强制保证默认类别 a photo of a cat 存在 (与 clip_app_web 行为一致,
        // 即使 labels.txt 已有内容也插入; 已存在则跳过)
        bool has_cat = std::find(init.begin(), init.end(), "a photo of a cat") != init.end();
        if (!has_cat) init.insert(init.begin(), "a photo of a cat");
        if (init.empty()) init = {"a photo of a cat"};
        std::cout << "[main] 初始编码 " << init.size() << " 标签..." << std::endl;
        for (auto& p : init) {
            auto ids = tok.tokenize(p);
            auto feat = encode_text(ids, DATA_DIR, device, text_session, text_network,
                                    fpai_device, gather_chunk, idx_addr, src_addr, dst_addr);
            // label_feat 必须有限值: nan 会导致所有分类持续 nan (文本编码偶发异常兜底)
            if (!feat.empty()) {
                bool has_nan = false;
                for (auto& x : feat) if (!std::isfinite(x)) { has_nan = true; break; }
                if (has_nan) {
                    std::cout << "[main] 初始编码 nan, 重试: " << p << std::endl;
                    feat = encode_text(ids, DATA_DIR, device, text_session, text_network,
                                       fpai_device, gather_chunk, idx_addr, src_addr, dst_addr);
                }
            }
            if (!feat.empty()) { labels.push_back(p); label_feats.push_back(feat); }
            else std::cout << "[main] 初始编码失败(跳过): " << p << std::endl;
        }
        std::cout << "[main] 初始标签就绪: " << labels.size() << std::endl;
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
    // 图像编码全流程耗时 ms (ImageMake→resize→pre→FWHT→post→reset)
    // 供 add 窗口期精确控制 sleep (方案1)
    std::atomic<double> img_period_ms_last{0};
    // vision 全流程处理中标志 (方案2: add 等 vision 处理完再编码文本)
    std::atomic<bool> vision_busy{false};
    // FWHT 硬算子: 硬件执行耗时 us (cycles/200.0, 板上展示口径)
    std::atomic<double> fwht_us_last{0};
    std::atomic<double> fwht_us_sum{0};

    // resize 输出 → CPU归一化 → seg_pre NPU → FWHT 硬算子 → seg_post NPU → emb
    // out_fwd_ms: 返回 pre+post NPU forward 总耗时(ms)
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
        // ---- seg_pre: 224x224x3 -> [残差, LN1] (out[0]=残差, out[1]=LN1, 已验证) ----
        Tensor t = CvMat2Tensor(imgf, pre_network, std::make_tuple(DST_SZ, DST_SZ, 3));
        auto _t_fwd = system_clock::now();
        dbg("pre fwd");
        auto pre_out = pre_session.forward({t});
        bool pre_ok = true;
        for (auto& ot : pre_out) pre_ok = pre_ok && ot.waitForReady(std::chrono::milliseconds(2000));
        dbg("pre done");
        if (!pre_ok) {
            // NPU 偶发挂起自愈: 丢本帧, reset 后继续 (避免 30s 卡顿)
            std::cout << "[WARN] seg_pre not ready, skip frame" << std::endl;
            device.reset(1);
            return {};
        }
        auto res_host = pre_out[0].to(HostDevice::MemRegion());
        auto ln1_host = pre_out[1].to(HostDevice::MemRegion());
        std::vector<float> residual((const float*)res_host.data().cptr(),
                                    (const float*)res_host.data().cptr() + FWHT_ELEMS);
        std::vector<float> ln1((const float*)ln1_host.data().cptr(),
                               (const float*)ln1_host.data().cptr() + FWHT_ELEMS);
        // ---- FWHT 硬算子: LN1 -> rot (50 向量 = 1200 blocks) ----
        std::vector<float> rot(FWHT_ELEMS);
        dbg("fwht start");
        double fwht_hw_us = run_hadamard_768(fpai_device, 0x400C0000, fwht_chunk,
                                             fwht_src_off, fwht_dst_off,
                                             ln1.data(), rot.data(), FWHT_NUM);
        dbg("fwht done");
        fwht_us_last.store(fwht_hw_us);              // 展示口径 = 硬件执行耗时
        fwht_us_sum.store(fwht_us_sum.load() + fwht_hw_us);
        // ---- seg_post: [残差, rot, rot, rot] -> emb (残差在 inputs()[0], 已验证) ----
        Tensor t0 = data2Tensor(residual.data(), post_network.inputs()[0]);
        Tensor t1 = data2Tensor(rot.data(), post_network.inputs()[1]);
        Tensor t2 = data2Tensor(rot.data(), post_network.inputs()[2]);
        Tensor t3 = data2Tensor(rot.data(), post_network.inputs()[3]);
        dbg("post fwd");
        auto post_out = post_session.forward({t0, t1, t2, t3});
        bool post_ok = true;
        for (auto& ot : post_out) post_ok = post_ok && ot.waitForReady(std::chrono::milliseconds(2000));
        dbg("post done");
        if (!post_ok) {
            // NPU 偶发挂起自愈: 丢本帧, reset 后继续 (避免 30s 卡顿)
            std::cout << "[WARN] seg_post not ready, skip frame" << std::endl;
            device.reset(1);
            return {};
        }
        double fwd_ms = duration_cast<microseconds>(system_clock::now() - _t_fwd).count() / 1000.0;
        if (out_fwd_ms) *out_fwd_ms = fwd_ms;
        auto emb_t = post_out[0].to(HostDevice::MemRegion());
        std::vector<float> emb((const float*)emb_t.data().cptr(),
                               (const float*)emb_t.data().cptr()+DIM);
        l2norm(emb);
        dbg("reset");
        device.reset(1);
        dbg("reset done");
        return emb;
    };
    // 摄像头帧 → emb
    auto encode_camera_frame = [&]() -> std::vector<float> {
        auto _t_full = system_clock::now();
        vision_busy.store(true);
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
        if (!op_resize_run(&fpai_device, 0x400C0000, rcfg, 2000, &rs_cycles)) {
            img_period_ms_last.store(duration_cast<microseconds>(system_clock::now() - _t_full).count() / 1000.0);
            vision_busy.store(false);
            return {};
        }
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
        img_period_ms_last.store(duration_cast<microseconds>(system_clock::now() - _t_full).count() / 1000.0);
        vision_busy.store(false);
        return emb;
    };
    // jpg帧 → emb (接法1)
    auto encode_cv_frame = [&](const cv::Mat& frame_bgr) -> std::vector<float> {
        auto _t_full = system_clock::now();
        vision_busy.store(true);
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
        if (!op_resize_run(&fpai_device, 0x400C0000, rcfg, 2000, &rs_cycles2)) {
            img_period_ms_last.store(duration_cast<microseconds>(system_clock::now() - _t_full).count() / 1000.0);
            vision_busy.store(false);
            return {};
        }
        double rs_us = rs_cycles2 / 200.0;
        img_resize_us_last.store(rs_us);
        img_resize_us_sum.store(img_resize_us_sum.load() + rs_us);
        double fwd_ms2 = 0;
        auto emb = resize_out_to_emb(&fwd_ms2);
        if (!emb.empty()) {
            img_enc_count.fetch_add(1);
            img_frame_ms_last.store(fwd_ms2);
        }
        img_period_ms_last.store(duration_cast<microseconds>(system_clock::now() - _t_full).count() / 1000.0);
        vision_busy.store(false);
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
                  << " fwd_ms=" << std::fixed << std::setprecision(1) << img_frame_ms_last.load()
                  << " fwht_us=" << std::fixed << std::setprecision(1) << fwht_us_last.load()
                  << " fwht_avg_us=" << std::fixed << std::setprecision(1) << avg_fw
                  << " count=" << c << std::endl;
    };
    auto add_label = [&](const std::string& prompt) -> bool {
        { std::lock_guard<std::mutex> lk(label_mutex);
          if (std::find(labels.begin(), labels.end(), prompt) != labels.end()) {
              std::cerr << "[LABEL] 已存在: " << prompt << std::endl; return false; } }
        // ★测试A: 去掉窗口期 sleep, 验证根因是否在 text 路径 reset
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
    std::vector<std::vector<uint8_t>> video_frames_jpg;  // 回放帧 (JPEG压缩)
    std::atomic<int> sr_sub{0};                // search 子状态: 0待机 1采集中 2查找就绪
    // 定时采集参数
    const int CAPTURE_DURATION_S = 10, SAMPLE_RATE_HZ = 4;
    const int SAMPLE_INTERVAL_MS = 1000 / SAMPLE_RATE_HZ;  // 250ms
    const int TOTAL_SAMPLES = CAPTURE_DURATION_S * SAMPLE_RATE_HZ; // 40
    steady_clock::time_point capture_start_time, last_sample_time;
    int capture_sample_count = 0;
    std::atomic<bool> cap_finish{false};       // done 提前结束
    std::atomic<bool> query_pending{false};
    std::string query_text;
    std::mutex sr_disp_mutex;
    std::atomic<int> top1_idx{-1};
    std::string top1_text = "";
    auto clear_db = [&]() {
        std::lock_guard<std::mutex> lk(db_mutex);
        feat_db.clear(); db_frames.clear(); db_ids.clear(); db_ts.clear(); db_paths.clear(); video_frames_jpg.clear(); db_source="none";
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
                                  // nan 自愈: 偶发 nan (疑似 FPGA 时序违例) 用上次检测结果覆盖
                                  static float last_best = 0.0f;
                                  static std::string last_label = "";
                                  float cc = scores[0].first;
                                  std::string ct = labels[scores[0].second];
                                  if (std::isnan(cc)) {
                                      std::cout << "[NAN] score nan, reuse last result" << std::endl;
                                      if (!last_label.empty()) { cc = last_best; ct = last_label; }
                                  } else {
                                      last_best = cc; last_label = ct;
                                  }
                                  std::ostringstream os;
                                  os << "[WEB] RESULT topk=";
                                  for (size_t r=0; r<scores.size(); ++r) {
                                      if (r) os << ",";
                                      if (r == 0) os << ct << ":" << std::fixed << std::setprecision(4) << cc;
                                      else os << labels[scores[r].second] << ":"
                                              << std::fixed << std::setprecision(4)
                                              << (std::isnan(scores[r].first) ? cc : scores[r].first);
                                  }
                                  std::cout << os.str() << std::endl;
                                  // HDMI 叠加: clip_app 自行按默认阈值判断 (用覆盖后的 cc/ct)
                                  const float HDMI_TH = 0.25f;
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

                // ---- 采集子模式 (定时自动采样 4fps × 10s) ----
                if (sub == 1) {
                    auto now = steady_clock::now();
                    if (!imk_armed.load()) {
                        auto& reg = fpai_device.defaultRegRegion();
                        reg.write(IMK_BASE + 0x114, imk_addr);
                        std::vector<float> empty_vec;
                        initImageMake(fpai_device, 0, NET_W, NET_H, 3, imk_addr, 8, empty_vec, empty_vec);
                        reg.write(IMK_BASE + 0x254, 0x4);
                        imk_armed.store(true);
                        last_sample_time = now;
                    }
                    // 保存全帧用于回放 (RGB565→BGR→JPEG压缩)
                    {
                        cv::Mat bgr;
                        if (f.type() == CV_8UC2) cv::cvtColor(f, bgr, cv::COLOR_BGR5652BGR);
                        else if (f.channels() == 4) cv::cvtColor(f, bgr, cv::COLOR_BGRA2BGR);
                        else bgr = f;
                        std::vector<uint8_t> jpg;
                        cv::imencode(".jpg", bgr, jpg, {cv::IMWRITE_JPEG_QUALITY, 80});
                        video_frames_jpg.push_back(std::move(jpg));
                    }
                    // 每 SAMPLE_INTERVAL_MS 采样一帧编码入库
                    auto elapsed_since = duration_cast<milliseconds>(now - last_sample_time).count();
                    if (elapsed_since >= SAMPLE_INTERVAL_MS) {
                        last_sample_time = now;
                        auto emb = encode_camera_frame();
                        if (!emb.empty()) {
                            int newid = capture_sample_count;
                            char fn[64]; snprintf(fn, sizeof(fn), "cap_%03d.jpg", newid);
                            std::string jpath = CAP_FRAMES_DIR + fn;
                            {   // 存 jpg 供 Web UI 显示
                                cv::Mat bgr;
                                if (f.type() == CV_8UC2) cv::cvtColor(f, bgr, cv::COLOR_BGR5652BGR);
                                else if (f.channels() == 4) cv::cvtColor(f, bgr, cv::COLOR_BGRA2BGR);
                                else bgr = f;
                                if (!bgr.empty()) cv::imwrite(jpath, bgr);
                                else jpath = "";
                            }
                            std::lock_guard<std::mutex> lk(db_mutex);
                            feat_db.push_back(emb); db_frames.push_back(f.clone());
                            db_ids.push_back(newid); db_ts.push_back(newid * 0.25);
                            db_paths.push_back(jpath);
                            capture_sample_count++;
                            std::cerr << "[CAP] 采样 " << capture_sample_count << "/" << TOTAL_SAMPLES << std::endl;
                        }
                        // re-arm
                        auto& reg = fpai_device.defaultRegRegion();
                        reg.write(IMK_BASE + 0x114, imk_addr);
                        std::vector<float> empty_vec;
                        initImageMake(fpai_device, 0, NET_W, NET_H, 3, imk_addr, 8, empty_vec, empty_vec);
                        reg.write(IMK_BASE + 0x254, 0x4);
                    }
                    // 10s 到 或 done
                    auto elapsed_total = duration_cast<milliseconds>(now - capture_start_time).count();
                    if (elapsed_total >= CAPTURE_DURATION_S * 1000 || cap_finish.exchange(false)) {
                        { std::lock_guard<std::mutex> lk(db_mutex); db_source="camera"; }
                        sr_sub.store(2);
                        std::cout << "[WEB] CAP done samples=" << capture_sample_count
                                  << " replay_frames=" << video_frames_jpg.size() << std::endl;
                        std::cerr << "\n[main] === 采集结束 (" << feat_db.size()
                                  << " 采样帧, " << video_frames_jpg.size() << " 回放帧) ===" << std::endl;
                    }
                    int remain_s = CAPTURE_DURATION_S - (int)(elapsed_total / 1000);
                    if (remain_s < 0) remain_s = 0;
                    char buf[64]; snprintf(buf, sizeof(buf), "Capturing... %ds left", remain_s);
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
                    // cap 来源: 用 video_frames_jpg 全帧回放 (30fps+ 流畅)
                    if (db_source == "camera" && !video_frames_jpg.empty()) {
                        auto now = steady_clock::now();
                        auto elapsed = duration_cast<milliseconds>(now - capture_start_time).count();
                        auto cycle_ms = elapsed % (CAPTURE_DURATION_S * 1000);
                        int idx = (int)(cycle_ms * video_frames_jpg.size() / (CAPTURE_DURATION_S * 1000));
                        if (idx >= (int)video_frames_jpg.size()) idx = (int)video_frames_jpg.size() - 1;
                        cv::Mat decoded = cv::imdecode(video_frames_jpg[idx], cv::IMREAD_COLOR);
                        if (!decoded.empty()) {
                            if (f.type() == CV_8UC2) cv::cvtColor(decoded, f, cv::COLOR_BGR2BGR565);
                            else decoded.copyTo(f);
                        }
                        char buf[64];
                        snprintf(buf, sizeof(buf), "Replay %.1fs", cycle_ms / 1000.0);
                        cv::putText(f, buf, cv::Point(40,80),
                                    cv::FONT_HERSHEY_DUPLEX, 1.0, cv::Scalar(255,255,0), 2);
                    } else if (!db_frames.empty()) {
                        // vid 来源: 时间驱动回放
                        static auto play_t0 = system_clock::now();
                        int el = (int)duration_cast<milliseconds>(system_clock::now()-play_t0).count();
                        int pi = (el/150) % (int)db_frames.size();
                        db_frames[pi].copyTo(f);
                        char buf[64];
                        snprintf(buf,sizeof(buf),"Play #%d/%d t=%.2fs",pi,(int)db_frames.size(),db_ts[pi]);
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
        std::cout << "  cap                       自动采集" << CAPTURE_DURATION_S << "s ("
                  << SAMPLE_RATE_HZ << "fps采样, 全帧回放, done提前结束)" << std::endl;
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

        // 采集子模式: done=结束; 其它输入忽略
        if (mode == M_SEARCH && sr_sub.load() == 1) {
            std::string t = trim(line);
            if (t == "done") { cap_finish.store(true); std::cout << "[main] 结束采集" << std::endl; continue; }
            if (t != "mode dual" && t != "mode search" && t != "help" && t != "status")
                continue;
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
                    capture_start_time = steady_clock::now();
                    last_sample_time = capture_start_time;
                    capture_sample_count = 0;
                    sr_sub.store(1);
                    std::cout << "[WEB] CAP start " << CAPTURE_DURATION_S << "s" << std::endl;
                    std::cout << "[main] 自动采集 " << CAPTURE_DURATION_S << "s ("
                              << SAMPLE_RATE_HZ << "fps采样, 全帧回放)" << std::endl;
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

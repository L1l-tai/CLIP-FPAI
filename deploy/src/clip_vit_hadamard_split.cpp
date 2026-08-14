// =====================================================================
// clip_vit_hadamard_split.cpp
// 图像编码器三段主链:seg_pre(NPU) + FWHT(FPGA 硬算子) + seg_post(NPU)
//   —— 选择性替换:只在 layer 0 的 q/k/v 处把 Hadamard 换成硬件 FWHT,
//      其余注入点仍以 MatMul 留在 NPU 里(结果正确,不影响精度)。
//
// 数据流:
//   pixel(FP32 归一化 RGB) --CvMat2Tensor--> seg_pre(NPU)
//      -> out[0]=残差[50,768], out[1]=LN1[50,768]
//   LN1 --run_hadamard_768--> rot[50,768]
//   [残差, rot, rot, rot] --data2Tensor--> seg_post(NPU) -> image_embeds[512]
//
// 用法:
//   ./clip_vit_split <seg_pre.json> <seg_post.json> <input_rgb_fp32.bin> [ref_embeds.bin]
//   input_rgb_fp32.bin : 224*224*3 float,HWC,RGB,已做 (v/255-mean)/std
//                        (与 host pixel_values 同款预处理,便于 board==host 比对)
//   ref_embeds.bin     : 可选,512 float,host 整模型输出,用于比余弦
//
// ⚠️ 两处上板必须核实(编译后 I/O 顺序未必等于 extract_model 传入顺序):
//   (1) seg_pre 的 out[0]/out[1] 哪个是残差、哪个是 LN1 —— 见下方 SEGPRE_OUT 注释
//   (2) seg_post 的 inputs()[0..3] 哪个位置是残差 —— 见下方 SEGPOST_IN 注释
//   两者四个输入/两个输出 shape 都是 [50,768],无法靠 shape 区分,首跑务必打印核对。
// =====================================================================

#include "file_utils.hpp"
#include "et_device.hpp"
#include "vis_helper.hpp"
#include "icraft_utils.hpp"
#include "mem_file_utils.hpp"
#include <icraft-xrt/core/session.h>
#include "compile_fpai_target.hpp"
#include <opencv2/opencv.hpp>

#include <fstream>
#include <iostream>
#include <string>
#include <vector>
#include <cmath>
#include <chrono>
#include <thread>
#include <cstring>

using namespace icraft::xrt;
using namespace icraft::xir;
using namespace std::chrono;
using namespace std::chrono_literals;
using namespace fpai;

// ---------------------------------------------------------------- 维度常量
static const int N       = 50;       // 49 patch + 1 cls
static const int D       = 768;      // hidden
static const int LEN     = N * D;    // 38400
static const int OUT_DIM = 512;      // image_embeds 维度(seg_post 已含视觉投影)

// ---------------------------------------------------------------- 小工具
static std::vector<float> read_float_bin(const std::string& path, size_t count) {
    std::ifstream f(path, std::ios::binary);
    if (!f) { std::cerr << "cannot open " << path << std::endl; return {}; }
    std::vector<float> v(count);
    f.read((char*)v.data(), count * sizeof(float));
    if ((size_t)f.gcount() != count * sizeof(float)) {
        std::cerr << "short read " << path << std::endl; return {};
    }
    return v;
}
static void write_float_bin(const std::string& path, const float* p, size_t count) {
    std::ofstream f(path, std::ios::binary);
    f.write((const char*)p, count * sizeof(float));
}
static void l2norm(std::vector<float>& v) {
    double s = 0; for (float x : v) s += (double)x * x;
    float n = (float)std::sqrt(s) + 1e-12f;
    for (float& x : v) x /= n;
}
static float cosine(const std::vector<float>& a, const std::vector<float>& b) {
    double dot = 0, na = 0, nb = 0;
    for (size_t i = 0; i < a.size(); i++) { dot += (double)a[i]*b[i]; na += (double)a[i]*a[i]; nb += (double)b[i]*b[i]; }
    return (float)(dot / (std::sqrt(na)*std::sqrt(nb) + 1e-12));
}
// ---- 调试: 向量统计(定位 inf/NaN 来源) ----
static void dump_vec(const char* tag, const std::vector<float>& v, size_t nshow = 5) {
    size_t nonfinite = 0; float vmin = 1e30f, vmax = -1e30f; double mean = 0;
    size_t nmean = v.size() < 10000 ? v.size() : 10000;
    for (size_t i = 0; i < v.size(); i++) {
        float x = v[i];
        if (!std::isfinite(x)) nonfinite++;
        else { if (x < vmin) vmin = x; if (x > vmax) vmax = x; }
        if (i < nmean && std::isfinite(x)) mean += x;
    }
    if (nmean) mean /= nmean;
    std::cout << "[" << tag << "] n=" << v.size() << " first=";
    for (size_t i = 0; i < nshow && i < v.size(); i++) std::cout << v[i] << " ";
    std::cout << " min=" << (vmin > 1e29f ? -1.0f : vmin) << " max=" << (vmax < -1e29f ? 1.0f : vmax)
              << " mean(1e4)=" << mean << " nonfinite=" << nonfinite << std::endl;
}

// ---------------------------------------------------------------- FP16 转换
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

// ---------------------------------------------------------------- FWHT 一跳
// in[num_vec*768] float -> out[num_vec*768] float,复用同一 device / reg_base
static void run_hadamard_768(FPAIDevice& fpai_device, uint32_t reg_base,
                             const float* in, float* out, int num_vectors) {
    const int TOTAL_ELEMS  = num_vectors * D;
    const int TOTAL_BLOCKS = TOTAL_ELEMS / 32;      // 50*768/32 = 1200

    const uint32_t REG_START = reg_base + 0xC4, REG_DONE   = reg_base + 0x100,
                   REG_RESET = reg_base + 0x1DC, REG_DW    = reg_base + 0x1C,
                   REG_PREC  = reg_base + 0x20,  REG_RBASE = reg_base + 0xC8,
                   REG_WBASE = reg_base + 0xCC,  REG_WRSIZE= reg_base + 0xD0,
                   REG_CYCLE = reg_base + 0x88;

    const int PAD = 64 * 64;                          // 4096
    int src_size = TOTAL_BLOCKS * 64, dst_size = src_size;
    int src_off = PAD, dst_off = src_off + src_size + PAD, total = dst_off + dst_size + PAD;

    auto chunk = fpai_device.defaultMemRegion().malloc(total, 0, 64);
    uint32_t base = chunk->begin.addr();
    uint32_t src_addr = base + src_off, dst_addr = base + dst_off;

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
    reg.write(REG_RESET, 1, false); std::this_thread::sleep_for(10ms);   // FPGA 算子侧复位
    reg.write(REG_RESET, 0, false); std::this_thread::sleep_for(10ms);

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
        if (duration_cast<milliseconds>(system_clock::now() - t0).count() > 10000) {
            std::cerr << "[FWHT] timeout" << std::endl; return;
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

    // 论文效率对比的关键数字:FWHT 硬件周期数
    uint32_t cyc = reg.read(REG_CYCLE, false);
    std::cout << "[FWHT] cycles = " << cyc << " (" << cyc / 200.0 << " us @200MHz)" << std::endl;
}

// ================================================================ main
int main(int argc, char* argv[]) {
    if (argc < 4) {
        std::cerr << "usage: " << argv[0]
                  << " <seg_pre.json> <seg_post.json> <input_rgb_fp32.bin> [ref_embeds.bin]\n";
        return 1;
    }
    std::string PRE_JSON = argv[1], POST_JSON = argv[2], IN_BIN = argv[3];
    std::string REF_BIN  = (argc >= 5) ? argv[4] : "";
    // raw 权重路径由 json 路径推导 (vit_seg_pre_ZG.json -> vit_seg_pre_ZG.raw, 同目录);
    // 不能把 ".raw" 当文件路径直接传, 否则 lazyLoadParamsFromFile 加载失败。
    auto raw_path_of = [](const std::string& json_path) {
        std::string r = json_path;
        if (r.size() > 5 && r.compare(r.size() - 5, 5, ".json") == 0) r.erase(r.size() - 5);
        return r + ".raw";
    };

    // ---- device(seg_pre / FWHT / seg_post 共用)----
    auto device = Device::Open("axi://zg330aiu?npu=0x40000000&dma=0x80000000");
    auto fpai_device = device.cast<FPAIDevice>();
    uint32_t reg_base = 0x400C0000;

    // ---- 加载两段网络 + 建会话(参数照 clip_dual_cfg 实证)----
    auto pre_net  = loadNetwork(PRE_JSON.c_str(),  raw_path_of(PRE_JSON).c_str());
    auto pre_sess = initSession("zg330", pre_net,  device, 4, true, true, false);
    pre_sess.apply();          // 必须 apply 后才能 forward (照 clip_dual / clip_app_web)
    auto post_net = loadNetwork(POST_JSON.c_str(), raw_path_of(POST_JSON).c_str());
    auto post_sess= initSession("zg330", post_net, device, 4, true, true, false);
    post_sess.apply();         // 必须 apply 后才能 forward

    // ============================================================ seg_pre
    // 读入预处理好的图像(FP32,HWC,RGB),构造 cv::Mat 后喂网络
    auto rgb = read_float_bin(IN_BIN, (size_t)224 * 224 * 3);
    if (rgb.empty()) return 1;
    cv::Mat imgf(224, 224, CV_32FC3, rgb.data());
    Tensor in = CvMat2Tensor(imgf, pre_net, std::make_tuple(224, 224, 3));

    auto pre_out = pre_sess.forward({in});
    for (auto& t : pre_out) t.waitForReady(milliseconds(5000));
    device.reset(1);

    // SEGPRE_OUT:约定 out[0]=残差, out[1]=LN1(= extract_model 的 output_names 顺序)
    //   上板首跑请核实:LN1 过了 layer norm,应近似零均值单位方差;残差不是。
    //   若顺序反了,交换下面两行即可。
    std::cout << "[seg_pre] num outputs = " << pre_out.size() << std::endl;
    auto res_host = pre_out[0].to(HostDevice::MemRegion());
    auto ln1_host = pre_out[1].to(HostDevice::MemRegion());
    std::vector<float> residual((const float*)res_host.data().cptr(),
                                (const float*)res_host.data().cptr() + LEN);
    std::vector<float> ln1((const float*)ln1_host.data().cptr(),
                           (const float*)ln1_host.data().cptr() + LEN);

    // ============================================================ FWHT 一跳
    dump_vec("seg_pre.residual", residual);   // DEBUG: 残差应有限; 若 inf -> seg_pre host 导出 dtype 问题
    dump_vec("seg_pre.ln1", ln1);             // DEBUG: LN1 应 ~N(0,1); 若 inf -> seg_pre host 导出 dtype 问题
    std::vector<float> rot(LEN);
    // DATA_MOVE_DIAG: 1 -> 把 token 19 与 token 0 交换 (验证 FWHT 错误跟随数据还是位置)
    //   错误跟随数据 -> 该数据触发硬件 bug; 错误仍在 token 19 -> 位置相关 (DMA/地址)
    // FWHT_DIAG_VEC: 诊断开关。= 50 处理全部向量(1200 blocks); 临时改为 30 可验证
    // 720 blocks (fwht_test 已验证规模) 是否正常, 用于区分:
    //   30 正常 & 50 异常 -> 硬件单次 block 数限制;  30 也异常 -> 输入格式/pack 问题。
    const int FWHT_DIAG_VEC = 50;
    std::cout << "[FWHT] processing " << FWHT_DIAG_VEC << " vectors (" << FWHT_DIAG_VEC * D / 32 << " blocks)" << std::endl;
    run_hadamard_768(fpai_device, reg_base, ln1.data(), rot.data(), FWHT_DIAG_VEC);
    dump_vec("fwht.rot", rot);                // DEBUG: 若 inf -> FWHT 打包/读回问题; 若正常但后续 inf -> seg_post 输入问题

    // ============================================================ seg_post
    // SEGPOST_IN:四个输入按 extract_model 顺序 [残差, rot_q, rot_k, rot_v]
    //   假定编译后 inputs()[0]=残差,[1..3]=三份旋转(全喂同一个 rot)。
    //   四输入 shape 均 [50,768] 无法靠 shape 区分,首跑务必核实哪个位置是残差;
    //   若比对余弦异常,优先怀疑此处顺序,把残差换到正确 index 再试。
    std::cout << "[seg_post] num inputs = " << post_net.inputs().size() << std::endl;
    // SEGPOST_IN 调换测试: 第 5 个可选参数 = 残差在 post_net.inputs() 的位置 (0-3, 默认 0)。
    //   四输入 shape 全 [1,50,768] 无法靠 shape 区分; cosine 偏低时依次试 0/1/2/3, 取最高。
    int res_idx = 0;
    if (argc >= 6) {
        res_idx = atoi(argv[5]);
        if (res_idx < 0 || res_idx > 3) { std::cerr << "ERROR: res_idx must be 0-3" << std::endl; return -1; }
    }
    std::cout << "[seg_post] SEGPOST_RES_IDX = " << res_idx
              << " (残差在 inputs()[" << res_idx << "], 其余三个喂 rot)" << std::endl;
    Tensor t0 = data2Tensor((res_idx == 0 ? residual : rot).data(), post_net.inputs()[0]);
    Tensor t1 = data2Tensor((res_idx == 1 ? residual : rot).data(), post_net.inputs()[1]);
    Tensor t2 = data2Tensor((res_idx == 2 ? residual : rot).data(), post_net.inputs()[2]);
    Tensor t3 = data2Tensor((res_idx == 3 ? residual : rot).data(), post_net.inputs()[3]);

    auto post_out = post_sess.forward({t0, t1, t2, t3});
    for (auto& t : post_out) t.waitForReady(milliseconds(5000));
    device.reset(1);

    auto emb_host = post_out[0].to(HostDevice::MemRegion());
    std::vector<float> embeds((const float*)emb_host.data().cptr(),
                              (const float*)emb_host.data().cptr() + OUT_DIM);
    dump_vec("seg_post.embeds", embeds);      // DEBUG: 若 inf -> seg_post 输入绑定/四输入顺序问题

    // ============================================================ 输出 / 比对
    std::vector<float> embeds_norm = embeds;
    l2norm(embeds_norm);
    write_float_bin("vit_split_embeds.bin", embeds.data(), OUT_DIM);
    std::cout << "image_embeds[:5] = ";
    for (int i = 0; i < 5; i++) std::cout << embeds[i] << " ";
    std::cout << std::endl;

    if (!REF_BIN.empty()) {
        auto ref = read_float_bin(REF_BIN, OUT_DIM);
        if (!ref.empty()) {
            std::vector<float> ref_norm = ref; l2norm(ref_norm);
            std::cout << "cosine vs ref = " << cosine(embeds_norm, ref_norm) << std::endl;
        }
    }

    Device::Close(device);
    return 0;
}

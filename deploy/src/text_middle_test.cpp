#include "icraft_utils.hpp"
#include "et_device.hpp"
#include "compile_fpai_target.hpp"
#include <icraft-xrt/core/session.h>
#include <chrono>
#include <iostream>
#include <fstream>
#include <vector>
#include <cmath>
#include <string>
#include <cstdint>
#include <thread>

using namespace icraft::xrt;
using namespace icraft::xir;
using namespace std::chrono;
using namespace fpai;

static std::vector<float> read_float_bin(const std::string& path, size_t count) {
    std::ifstream ifs(path, std::ios::binary);
    if (!ifs) { std::cerr << "[ERROR] 打不开 " << path << std::endl; exit(-1); }
    std::vector<float> buf(count);
    ifs.read((char*)buf.data(), count * sizeof(float));
    return buf;
}

static std::vector<int32_t> read_int32_bin(const std::string& path, size_t count) {
    std::ifstream ifs(path, std::ios::binary);
    if (!ifs) { std::cerr << "[ERROR] 打不开 " << path << std::endl; exit(-1); }
    std::vector<int32_t> buf(count);
    ifs.read((char*)buf.data(), count * sizeof(int32_t));
    return buf;
}

static float cosine(const float* a, const float* b, size_t n) {
    double dot=0, na=0, nb=0;
    for (size_t i=0;i<n;i++){ dot+=(double)a[i]*b[i]; na+=(double)a[i]*a[i]; nb+=(double)b[i]*b[i]; }
    return (float)(dot / (std::sqrt(na)*std::sqrt(nb) + 1e-12));
}

int main(int argc, char* argv[])
{
    std::cout << "=== 验证档2: 完整链路 (malloc提前抢低地址) ===" << std::endl;

    std::string JSON = "imodel/ZG/text_middle_ZG.json";
    std::string RAW  = "imodel/ZG/text_middle_ZG.raw";
    std::string DATA = "board_data/";
    std::string prompt = (argc >= 2) ? argv[1] : "a_photo_of_a_cat";

    const int VOCAB = 49408, SEQ = 77, DIM = 512;

    // ---- 1. device ----
    auto device = Device::Open("axi://zg330aiu?npu=0x40000000&dma=0x80000000");
    auto fpai_device = device.cast<FPAIDevice>();
    std::cout << "[1] device opened" << std::endl;

    // ============================================================
    // ---- 关键：Gather 的 malloc 提前到最前面，抢占低地址 ----
    //      idx 地址必须高16位=0（< 0x10000），否则 idx_base 寄存器截断
    // ============================================================
    const int INDICES_LEN = 1;
    const int DATA_WIDTH_BEATS = 32;        // 2048B / 64
    int indices_beats = 1;
    int indices_size  = indices_beats * 64;          // 64
    int elem_size     = DATA_WIDTH_BEATS * 64;       // 2048
    int src_data_size = SEQ * elem_size;             // 157696
    int dst_data_size = INDICES_LEN * elem_size;     // 2048

    const int PAD_SIZE = 4096;
    int idx_offset = 0;
    int src_offset = idx_offset + indices_size + PAD_SIZE;
    int dst_offset = src_offset + src_data_size + PAD_SIZE;
    int total_size = dst_offset + dst_data_size + PAD_SIZE;

    auto mem_chunk = fpai_device.defaultMemRegion().malloc(total_size, 0, 64);
    uint32_t mem_addr = mem_chunk->begin.addr();
    uint32_t idx_addr = mem_addr + idx_offset;
    uint32_t src_addr = mem_addr + src_offset;
    uint32_t dst_addr = mem_addr + dst_offset;
    std::cout << "[malloc] Gather chunk 提前分配: base=0x" << std::hex << mem_addr
              << " idx:0x" << idx_addr << " src:0x" << src_addr << " dst:0x" << dst_addr << std::dec << std::endl;
    std::cout << "[malloc] idx 高16位 = 0x" << std::hex << (idx_addr >> 16) << std::dec
              << "  (必须为0才能正确寻址idx)" << std::endl;

    // ---- 2. 头部 CPU 查表 ----
    auto token_emb = read_float_bin(DATA + "token_emb.bin", (size_t)VOCAB * DIM);
    auto pos_emb   = read_float_bin(DATA + "pos_emb.bin",   (size_t)SEQ * DIM);
    auto input_ids = read_int32_bin(DATA + "input_ids_" + prompt + ".bin", SEQ);

    std::cout << "[2] prompt=" << prompt << std::endl;

    std::vector<float> mid_in((size_t)SEQ * DIM);
    for (int i=0;i<SEQ;i++) {
        int id = input_ids[i];
        for (int j=0;j<DIM;j++)
            mid_in[(size_t)i*DIM + j] = token_emb[(size_t)id*DIM + j] + pos_emb[(size_t)i*DIM + j];
    }

    int eot_idx = 0; int32_t maxv = input_ids[0];
    for (int i=1;i<SEQ;i++) if (input_ids[i] > maxv) { maxv = input_ids[i]; eot_idx = i; }
    std::cout << "[2] eot_idx = " << eot_idx << std::endl;

    // ---- 3. 中间 NPU ----
    auto network = loadNetwork(JSON, RAW);
    auto session = initSession("zg330", network, device, 4, true, true, false);
    session.apply();
    std::cout << "[3] session ready" << std::endl;

    Tensor in = data2Tensor(mid_in.data(), network.inputs()[0]);
    std::vector<Tensor> inputs = { in };

    {
        auto warm = session.forward(inputs);
        for (auto& t : warm) t.waitForReady(std::chrono::milliseconds(5000));
        device.reset(1);
    }
    auto out = session.forward(inputs);
    for (auto& t : out) t.waitForReady(std::chrono::milliseconds(5000));
    device.reset(1);

    auto out_host = out[0].to(icraft::xrt::HostDevice::MemRegion());
    const float* feat_seq = (const float*)out_host.data().cptr();
    std::cout << "[3] 中间NPU forward done, feat_seq[0..4]: ";
    for (int i=0;i<5;i++) std::cout << feat_seq[i] << " ";
    std::cout << std::endl;

    std::vector<float> feat_seq_buf(feat_seq, feat_seq + (size_t)SEQ * DIM);
    std::cout << "[3] feat_seq[eot_idx][0..4]: ";
    for (int i=0;i<5;i++) std::cout << feat_seq_buf[(size_t)eot_idx*DIM + i] << " ";
    std::cout << std::endl;

    // ============================================================
    // ---- 4. 尾部 FPGA Gather（chunk 已提前分配，这里只写数据+配寄存器）----
    // ============================================================
    std::cout << "\n[4] === 尾部 FPGA Gather ===" << std::endl;

    uint32_t reg_base = 0x400C0000;
    uint32_t REG_START      = reg_base + 0x00;
    uint32_t REG_DONE       = reg_base + 0x80;
    uint32_t REG_VERSION    = reg_base + 0xC0;
    uint32_t REG_RESET      = reg_base + 0x1DC;
    uint32_t REG_IDX_BASE   = reg_base + 0x04;
    uint32_t REG_WRITE_BASE = reg_base + 0x08;
    uint32_t REG_SRC_BASE   = reg_base + 0x0C;
    uint32_t REG_IDX_LEN    = reg_base + 0x14;
    uint32_t REG_DATA_WIDTH = reg_base + 0x18;

    uint32_t ver = fpai_device.defaultRegRegion().read(REG_VERSION, false);
    std::cout << "    Gather version: 0x" << std::hex << ver << std::dec << std::endl;

    // 索引 buffer：eot_idx int32 小端
    std::vector<int8_t> idx_buf(indices_size, 0);
    idx_buf[0] = eot_idx & 0xFF;
    idx_buf[1] = (eot_idx >> 8) & 0xFF;
    idx_buf[2] = (eot_idx >> 16) & 0xFF;
    idx_buf[3] = (eot_idx >> 24) & 0xFF;

    const int8_t* feat_bytes = (const int8_t*)feat_seq_buf.data();

    // 复位
    fpai_device.defaultRegRegion().write(REG_RESET, 1, false);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    fpai_device.defaultRegRegion().write(REG_RESET, 0, false);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));

    // 写索引和数据
    mem_chunk.write(idx_offset, (char*)idx_buf.data(), indices_size);
    mem_chunk.write(src_offset, (char*)feat_bytes, src_data_size);
    std::cout << "    已写入 idx + src" << std::endl;

    // 验证 src 写入
    {
        std::vector<float> src_check(DIM);
        mem_chunk.read((char*)src_check.data(), src_offset + (size_t)eot_idx * elem_size, DIM * sizeof(float));
        std::cout << "    [验证] src第eot_idx行[0..4]: ";
        for (int i=0;i<5;i++) std::cout << src_check[i] << " ";
        std::cout << std::endl;
    }

    // 配寄存器
    fpai_device.defaultRegRegion().write(REG_IDX_LEN, INDICES_LEN, false);
    fpai_device.defaultRegRegion().write(REG_DATA_WIDTH, DATA_WIDTH_BEATS, false);
    fpai_device.defaultRegRegion().write(REG_IDX_BASE, (indices_beats << 16) | (idx_addr & 0xFFFF), false);
    fpai_device.defaultRegRegion().write(REG_SRC_BASE, src_addr, false);
    fpai_device.defaultRegRegion().write(REG_WRITE_BASE, dst_addr, false);
    std::cout << "    寄存器: IDX_LEN=" << INDICES_LEN << " DATA_WIDTH=" << DATA_WIDTH_BEATS
              << " idx_base=0x" << std::hex << ((indices_beats<<16)|(idx_addr&0xFFFF))
              << " src=0x" << src_addr << " dst=0x" << dst_addr << std::dec << std::endl;

    // 启动 + 轮询
    fpai_device.defaultRegRegion().write(REG_START, 1, false);
    std::cout << "    Gather started..." << std::endl;
    auto gstart = system_clock::now();
    int done = 0;
    while (done == 0) {
        done = fpai_device.defaultRegRegion().read(REG_DONE, false);
        if (duration_cast<milliseconds>(system_clock::now() - gstart).count() > 10000) {
            std::cerr << "    [ERROR] Gather Time Out!" << std::endl; return -1;
        }
    }
    std::cout << "    Gather completed." << std::endl;

    // 读回 dst[512]
    std::vector<float> eot_feat(DIM);
    mem_chunk.read((char*)eot_feat.data(), dst_offset, dst_data_size);
    std::cout << "    Gather取出EOT行[0..4]: ";
    for (int i=0;i<5;i++) std::cout << eot_feat[i] << " ";
    std::cout << "  (应=feat_seq[eot_idx])" << std::endl;

    // ---- 5. CPU 投影 ----
    auto proj = read_float_bin(DATA + "text_proj.bin", (size_t)DIM * DIM);
    std::vector<float> text_feat(DIM, 0.f);
    for (int i=0;i<DIM;i++) {
        float s = 0;
        for (int k=0;k<DIM;k++) s += eot_feat[k] * proj[(size_t)k*DIM + i];
        text_feat[i] = s;
    }
    std::cout << "[5] 投影后 text_feat[0..4]: ";
    for (int i=0;i<5;i++) std::cout << text_feat[i] << " ";
    std::cout << std::endl;

    // ---- 6. 对比 ref_textfeat ----
    auto ref = read_float_bin(DATA + "ref_textfeat_" + prompt + ".bin", DIM);
    float cos = cosine(text_feat.data(), ref.data(), DIM);
    std::cout << "\n==== 完整链路 余弦相似度: " << cos << " ====" << std::endl;
    std::cout << "板上 [0..4]: ";
    for (int i=0;i<5;i++) std::cout << text_feat[i] << " ";
    std::cout << "\nhost [0..4]: ";
    for (int i=0;i<5;i++) std::cout << ref[i] << " ";
    std::cout << std::endl;

    if (cos > 0.99f) std::cout << "\n✓✓✓ 验证档2通过！完整文本编码器链路在板上跑通！" << std::endl;
    else             std::cout << "\n✗ 余弦偏低，需排查。" << std::endl;

    Device::Close(device);
    return 0;
}
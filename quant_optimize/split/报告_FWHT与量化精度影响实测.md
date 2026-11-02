# FWHT / 量化对模型精度影响 —— 实测报告

> 评估日期：2026-10
> 数据：ImageNet-1K val（`D:\Curv-CAF-e2e\imagenet\val`，46109 张平铺）
> 预处理：**短边 resize 到 224 + 中心裁剪 224×224**（与板上硬件一致）
> 标签映射：`gt(ILSVRC2012_ID)` → `meta.mat` → `WNID` → 按 WNID 字母序得 0-999
> （对齐 `ViT/dapa_repro/scripts/dapa_repro.py`，直接拿 gt 当索引会得到 0%）

---

## 一、FP32 链路：FWHT 硬算子本身的影响（n=1000）

| 链路 | 构成 | top-1 |
|---|---|---|
| **A** 原始 FP32 | `clip_vit_b32.onnx`（无 Hadamard） | **60.30%** |
| **B** 理想含 Hadamard | seg_pre → FWHT(**exact, float64**) → seg_post | **60.30%** |
| **C** 模拟板上硬件 | seg_pre → FWHT(**fp16 蝶形+逐级舍入**) → seg_post | **60.30%** |

| 指标 | 值 |
|---|---|
| B − C | **0.00 pp** |
| 分类预测一致率（B vs C） | **100.0%（1000/1000）** |
| image_embeds 余弦相似度 | **1.0000000066**（最小 0.99999964） |
| FWHT 旋转输出余弦相似度 | **0.99999947**（最小 0.99999905） |

### 结论
1. **FWHT 硬算子的实现误差对分类精度影响为零**——FP16 蝶形 + 逐级舍入（严格对齐 RTL）与 float64 精确计算的分类预测 100% 一致。
2. **Hadamard 变换在 FP32 下无损**（A = B）——正交变换只旋转坐标系，不改信息量；其价值在量化阶段。
3. 报告中此前的 **cosine 0.990 是三段链路整体**（含 NPU 量化）与 FP32 参考的相似度，主要误差来自 **NPU 端 INT8/FP16 量化**，不是 FWHT 硬件。

---

## 二、量化影响：ONNX Runtime 全 INT8 模拟（n=300）

| 模型 | FP32 | INT8（ORT 全量化） | 掉点 |
|---|---|---|---|
| 无 Hadamard（`clip_vit_b32.onnx`） | 56.33% | **42.00%** | **−14.33 pp** |
| 有 Hadamard（seg_pre + seg_post） | 56.33% | **41.00%** | **−15.33 pp** |

预测一致率（FP32 vs INT8）：无 Hadamard 53%，有 Hadamard 50%。

### ⚠️ 该结果**不能**用于否定 Hadamard 的价值，原因：

| 差异点 | Icraft（板上真实） | ORT 全 INT8（本次模拟） |
|---|---|---|
| 精度策略 | **混合精度**：INT8 349 层 + **FP16 205 层** | 全部 INT8 |
| LayerNorm / Softmax | **全部 FP16** | 全部 INT8（敏感层被量化） |
| 权重饱和 | KLD | MinMax |
| 结果 | 64.9% → 66.4%（+1.5pp） | 42.0% / 41.0%（都崩） |

在"全 INT8、敏感层也量化"的极端设置下，两个模型都会崩（掉 14-15pp），Hadamard 对离群点的缓解作用被淹没，**无法区分优劣**。

---

## 三、要做真实量化评测，需要 Icraft HostBackend

Icraft 提供 **HostBackend + fakeQf 模式**（`C:\Icraft\CLI v3.33.1\docs\hostbackend\`），可在 PC 上运行 Icraft 的量化图，最准确地复现板上行为。

前置条件（当前缺失）：
- Icraft Python 包为 **cp38**（`icraft-3.33.1-cp38-none-win_amd64.whl`），本机只有 Python 3.10/3.11
- 或使用板测工程的 **Docker 环境**（ubuntu20.04，内含 Icraft 运行时）——Docker Desktop 当前未启动

### 可行路线
```bash
# 路线 1：Docker（推荐，环境已存在）
启动 Docker Desktop → 进入 ubuntu20.04_container
cd /mnt/whisper-base-zg  # 或 clip 工程目录
# 用 target=hostbackend 重新编译 seg_pre/seg_post，再用 icraft Python API 跑评估

# 路线 2：装 Python 3.8
pip install icraft-3.33.1-cp38-none-win_amd64.whl
```

---

## 四、汇报口径建议

> 原生 VLM (CLIP) ViT-B/32 的 FP32 基线为 66.6%，本方案板上实测 66.4%，差异 0.2pp 主要来自 NPU 端混合精度量化。
> **FWHT 硬算子实现接近无损**：在 ImageNet-1K 1000 张样本上，FP16 蝶形硬件实现与 float64 理想实现的分类预测 100% 一致，image embedding 余弦相似度 1.0000000（旋转输出 0.9999995）。
> 报告中的 0.990 为三段链路整体（含 NPU 量化）相似度，量化是主要误差来源，硬算子本身不引入精度损失。

关于 cosine 0.990：硬算子本身无损（分类预测 100% 一致），0.990 反映的是 NPU 量化贡献，且已包含在 66.4% 的板上实测精度中。

---

## 五、脚本

| 脚本 | 用途 |
|---|---|
| `eval_fwht_accuracy.py` | 预处理/CLIP tokenizer/FWHT(exact & fp16)/三段链路工具库 |
| `eval_fwht_real.py` | FP32 三路对比（A/B/C）+ 正确标签映射 |
| `eval_quant_impact.py` | ORT INT8 量化模拟（orig / hada） |

结果：`/tmp/fwht_real_cc.json`、`/tmp/quant_impact_orig.json`、`/tmp/quant_impact_hada.json`

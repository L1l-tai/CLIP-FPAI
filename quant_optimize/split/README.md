# 模型切分工作区（Hadamard/FWHT 硬算子接入）

> 视觉编码器三段切分：`seg_pre(NPU) → FWHT 硬算子(FPGA) → seg_post(NPU)`。
> 详细技术背景（常见问题、验证栈、40 注入点分布）见同目录 [KB_增补_图像编码器Hadamard切分.md](./KB_增补_图像编码器Hadamard切分.md)。

---

## 一、为什么切分

**ZG330 NPU 不支持自定义算子注册**——FWHT 硬算子无法作为 NPU 算子嵌入，因此采用**"网络切分 + 手动编排"**：

- 把含 Hadamard 旋转的视觉编码器切成**两段独立 NPU 子网**（seg_pre / seg_post）
- 中间夹一次 **host 中转 + 硬件 FWHT**（替代原图 3 个旋转 MatMul）
- 与文本编码器 Gather 硬算子接入完全同构

---

## 二、切分流程（7 步）

### 步骤 0：准备模型

模型统一位于项目 `fmodel/vision/`（单一来源）：

```
fmodel/vision/                      # 大模型 (不入 git, 单独获取)
├── vision_model_hadamard_gs64.onnx     # 整模型 (Hadamard 注入, 446MB)
└── split/
    ├── vit_seg_pre_fixed.onnx          # seg_pre 固定 shape (9.6MB)
    └── vit_seg_post_fixed.onnx         # seg_post 固定 shape (429MB)
```

脚本/toml 默认路径已指向 `../../fmodel/vision/split/`（相对本目录），无需手动放置。

### 步骤 1：量化注入（Hadamard 旋转）

```bash
cd quant_optimize
python clip_hadamard.py      # 权重旋转 W'=H@W + 注入 MatMul(X,H^T), group_size=64
```

产物：`vision_model_hadamard_gs64.onnx` + `mix_config_hadamard.csv`（40 注入点配置）。

### 步骤 2：切分（onnx extract_model，按切点 tensor 名）

以 layer 0 q/k/v 为例：

```
seg_pre  : pixel_values → [残差, LN1]                     (双输出)
中间跳   : LN1 → FWHT 硬算子 → rot                        (替代 q/k/v 三个旋转 MatMul)
seg_post : [残差, rot, rot, rot] → image_embeds           (四输入)
```

切点 tensor 名（layer 0）：

| 角色            | tensor 名                                                          |
| --------------- | ------------------------------------------------------------------ |
| 残差旁路        | `/vision_model/pre_layrnorm/Add_1_output_0`                      |
| LN1（共享输入） | `/vision_model/encoder/layers.0/layer_norm1/Add_1_output_0`      |
| q/k/v 旋转输出  | `layers.0/self_attn/{q,k,v}_proj/MatMul_hadamard_rotated_output` |

> 三个 H 矩阵逐元素相同 → **一次 FWHT 产出可同时喂 q/k/v 三路**。
> fc1 类切点：LN2 输出单路 + MLP 残差（`layers.L/Add_output_0`）；注意力残差名随层号变（仅 layer 0 为 pre_layrnorm）。

### 步骤 3：固定 shape（_fixed.onnx，Icraft 静态编译必需）

```python
import onnx
from onnx import helper
# extract_model 切出的子网中间 tensor shape 为空 []、输入含动态维,
# onnxruntime 可运行但 Icraft 编译必须写死:
#   pixel_values → [1,3,224,224]; 残差/LN1/旋转 → [1,50,768]; image_embeds → [1,512]
```

产物：`vit_seg_pre_fixed.onnx`（9.6MB，已提供）/ `vit_seg_post_fixed.onnx`（429MB）。

### 步骤 4：编译（Icraft）

```bash
# 从 quant_optimize/split/ 目录执行 (toml 路径已适配本目录)
# 一条命令自动完成全部阶段: parse → optimize → quantize → adapt → generate
icraft compile -c compile_vit_seg_pre.toml
icraft compile -c compile_vit_seg_post.toml
```

产物输出到项目 `imodel/vit_seg_pre/`、`imodel/vit_seg_post/`：
`vit_seg_pre_ZG.{json,raw}`、`vit_seg_post_ZG.{json,raw}`

**toml 关键配置**（常见问题摘要）：

| 项                         | seg_pre                                        | seg_post                           |
| -------------------------- | ---------------------------------------------- | ---------------------------------- |
| inputs                     | `[1,224,224,3]`                              | `[[1,50,768]×4]`（列表的列表）  |
| inputs_layout              | `"NHWC"`（图像）                             | `"FD;FD;FD;FD"`（特征）          |
| inputs_dtype               | `"FP32"`                                     | `"FP32;FP32;FP32;FP32"`          |
| pre_method/scale/mean/swap | `"nop"`（不做 NPU 归一化）                   | `"nop;nop;nop;nop"`（分号四份）  |
| qdtype                     | `"bf16"`（CLIP 极端值，FP16 会 inf）         | `"bf16"`                         |
| network                    | `../../fmodel/vision/split/vit_seg_pre_fixed.onnx`（NCHW 原版） | `../../fmodel/vision/split/vit_seg_post_fixed.onnx` |

> ⚠️ parse 段所有逐输入参数必须数量一致、分号分隔，漏一个报 size not match。
> ⚠️ 勿手动在 onnx 加 Transpose 转 NHWC（Icraft 重复转换报错）。

### 步骤 5：host 验证（dryrun_vit_split.py）

```bash
cd quant_optimize/split
# 三段会话 + 整模型参考 + exact/FP16 两种 FWHT 模拟
python dryrun_vit_split.py --mode both --plot split_check
# --image <测试图> 用真实图片; --save-bins <目录> 导出板卡输入/参考 bin
```

**判读标准**：

- `exact`（float64 蝶形）vs 整模型 → cosine **1.0**（切分逻辑正确）
- `fp16`（golden FP16）vs 整模型 → cosine **~1.0**（FP16 精度代价 ~1e-4）
- LN1 统计应近似零均值单位方差（识别双输出顺序）

### 步骤 6：生成板卡输入/参考（gen_vit_board_io.py）

```bash
cd quant_optimize/split
python gen_vit_board_io.py <测试图>
# 产出 board_data/vit_pre_in.bin (cpp 输入, HWC RGB FP32)
#       board_data/vit_ref_embeds.bin (整模型 fp32 参考)
```

### 步骤 7：上板验证（clip_vit_hadamard_split）

```bash
# 编译产物在 compile/build/ZG/ (源: deploy/src/clip_vit_hadamard_split.cpp)
./clip_vit_hadamard_split \
    vit_seg_pre_ZG.json vit_seg_post_ZG.json \
    vit_pre_in.bin vit_ref_embeds.bin
```

**判读**：板上 vs 参考 cosine **~0.95 即成功**（bf16 NPU + FP16 硬件的预期降精度，主要来自 bf16）。
单算子 FWHT vs golden 应 ~0.999（证明 FWHT 本身无误）。FWHT 周期数 `reg_base+0x88 ÷ 200 = μs`（论文效率对比数据）。

---

## 三、本目录文件说明

| 文件                                  | 说明                                                                                                                     |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `KB_增补_图像编码器Hadamard切分.md` | **核心知识文档**：切分方案、40 注入点分布、常见问题（编译/字节序/INT8）、host 验证栈、交接清单                       |
| `dryrun_vit_split.py`               | 三段切分 host 验证：seg_pre→FWHT 模拟→seg_post vs 整模型，支持 exact/FP16 两种模拟精度、出图、导出 bin                 |
| `gen_vit_board_io.py`               | 生成板上 cpp 输入 bin（vit_pre_in.bin）与整模型参考 bin（vit_ref_embeds.bin）                                            |
| `split_vit_generalize.py`           | NHWC 输入适配参考（手动加 Transpose 版）——**已弃用**（问题 5：Icraft 重复转换报错），保留作数值一致性验证参考  |
| `compile_vit_seg_pre.toml`          | seg_pre 编译配置（单输入图像，双输出 [残差, LN1]）                                                                       |
| `compile_vit_seg_post.toml`         | seg_post 编译配置（四输入 [残差, rot×3]，分号多输入语法）                                                               |
| `fmodel/vision/split/vit_seg_pre_fixed.onnx` | seg_pre 固定 shape 模型（9.6MB，单一来源）                                                                                 |
| `fmodel/vision/`（大模型）          | `vision_model_hadamard_gs64.onnx`（446MB）、`vit_seg_post_fixed.onnx`（429MB）——不入 git，需单独获取                 |

---

## 四、quant_optimize/ 同目录文件介绍

| 文件                                 | 说明                                                                                                                                           |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `clip_hadamard.py`                 | **Hadamard 量化优化核心**：加载 ONNX → 校准激活 → 异常层检测 → 权重旋转 `W'=H@W` → 插入 `MatMul(X,H^T)` → 导出（group_size=64） |
| `mix_config_hadamard.csv`          | Hadamard 分组配置（40 个注入点：层号/目标 MatMul/权重名/离群率/H 矩阵名）                                                                      |
| `realtime_open_vocab_detection.py` | 实时开放词表检测（零样本分类）                                                                                                             |
| `zero_shot.py`                     | zero-shot 推理脚本（CLIP 图文匹配基础评测）                                                                                                    |
| `split/`                           | **本目录**：模型切分工作区（FWHT 硬算子接入）                                                                                            |

---

## 五、与部署的衔接

切分产物 `imodel/vit_seg_pre/vit_seg_pre_ZG.{json,raw}` + `vit_seg_post_ZG.{json,raw}` 是板上主程序
`clip_app_split`（deploy/src/）的 pre/post 模型来源，配置在 `configs/app_config_split.yaml`：

```yaml
pre_json:  ".../vit_seg_pre_ZG.json"
post_json: ".../vit_seg_post_ZG.json"
```

板上运行时编排（deploy/src/clip_app_split.cpp 的 resize_out_to_emb）：

```
seg_pre.forward → [残差, LN1] → host FP16 打包 → run_hadamard_768 → rot
→ seg_post.forward([残差, rot, rot, rot]) → emb
```

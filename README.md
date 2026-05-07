# CLIP ViT-B/32 FPGA 加速项目

本项目实现 CLIP (Contrastive Language-Image Pre-training) 模型在 FPGA 上的部署加速，采用 Vivado RTL 设计配合自定义算子，支持 INT8 \ FP16 量化推理。

---

## 目录结构

```
├── rtl/                    # RTL 设计（自定义算子硬件实现）
├── FPGA/                   # FPGA 工程与 IP 配置
├── deploy/                 # 模型部署（推理流程、配置文件）
├── quant_optimize/         # 量化优化工具链
├── op/                     # 自定义算子替换（ONNX Parser / Pass）
├── processor/              # CLIP 图像预处理器配置
├── fmodel/                 # ONNX 模型文件
├── configs/                # 部署配置文件
├── sim/                    # 仿真脚本
└── qtset/                  # 量化校准数据集
```

---

## 一、rtl — 自定义算子 RTL 设计

**路径**: `rtl/`

### 1.1 custom_op — 核心硬件算子

| 算子 | 路径 | 功能说明 |
|------|------|----------|
| **Gather** | `rtl/custom_op/gather/` | 索引聚集 — 根据索引表从 DDR 读取不规则位置数据，实现数据重排列（ViT 图像块重排） |
| **Hadamard** | `rtl/custom_op/hadamard/` | 快速沃尔什-哈达玛变换 (FWHT) — 6 级蝶形网络，支持 INT8/FP16，用于量化预处理 |
| **Resize** | `rtl/custom_op/resize_crop/` | 双线性插值缩放 — 三级流水线，支持任意比例上/下采样 |

### 1.2 公共模块

| 路径 | 说明 |
|------|------|
| `rtl/public/fifo/` | 同步 FIFO、公共组件 |
| `rtl/custom_op/AVR/` | AXI-Stream 寄存器切片（avr_rs/brs/frs） |
| `rtl/custom_op/arbiter.v` | DMA 仲裁器（优先级：Gather > Hadamard > Resize） |
| `rtl/custom_op/dma.v` | 通用 DMA 引擎 |
| `rtl/custom_op/reg_ctrl.v` | CPU (APB) 寄存器配置接口 |

### 1.3 顶层模块

- `rtl/ai7030_edif_top.v` — AI7030 顶层综合文件
- `rtl/ps_ai_wrap_demo.v` — PS-AI 封装示例

### 1.4 SDI 相关（参考）

- `rtl/sdi/` — 串行数据接口相关模块

RTL代码详细说明：[RTL代码介绍](./rtl/rtl_summary.md)

---

## 二、quant_optimize — 量化优化工具链

**路径**: `quant_optimize/`

### 文件说明

| 文件 | 说明 |
|------|------|
| `clip_hadamard.py` | **核心**：Hadamard 量化优化流程 — 加载 ONNX → 校准图像收集 → 异常值检测 → 插入 Hadamard 旋转层 → 导出优化模型 |
| `zero_shot.py` | Zero-shot 图像分类推理脚本 |
| `realtime_open_vocab_detection.py` | 实时开放词汇检测 |
| `mix_config_hadamard.csv` | Hadamard 分组配置 |

### Hadamard 量化流程

1. **加载 ONNX 模型**，分析 Linear 层结构
2. **收集校准图像**激活值统计（逐通道异常值检测）
3. **检测异常层**：超过阈值的层标记为需要旋转
4. **权重旋转**：离线完成 `W' = H @ W`
5. **激活值旋转**：在 ONNX 模型中插入 `MatMul(X, H^T)` 层
6. **验证一致性**后导出优化模型

---

## 三、deploy — 模型部署

**路径**: `deploy/`

### 目录结构

```
deploy/
├── Deps/modelzoo/          # 运行时依赖库（C++ / Python API）
├── modelzoo/clip/          # CLIP 部署推理代码
│   ├── pyrt/               # Python Runtime 推理脚本
│   │   ├── clip.py         # CLIP 主体推理
│   │   ├── clip_img_host.py
│   │   ├── clip_text_host.py
│   │   ├── clip_full_pipeline.py
│   │   └── clip_full_pipeline_camera.py
│   ├── io/                 # 输入输出测试数据
│   └── cfg/                # 部署配置文件
├── pyrt/                   # 推理输出结果
└── cfg/                    # 全局配置文件
```

### Deps/modelzoo — 运行时依赖

**C++ API** (`deploy/Deps/modelzoo/`)：
此处为复旦微提供，详见Icraft-doc

### CLIP 推理脚本

| 脚本 | 功能 |
|------|------|
| `clip.py` | CLIP 主推理流程 |
| `clip_img_host.py` | 图像特征提取 |
| `clip_text_host.py` | 文本特征提取 |
| `clip_full_pipeline.py` | 完整 pipeline（图像+文本+相似度计算） |
| `clip_full_pipeline_camera.py` | 摄像头实时推理 |
| `match_onnx.py` | ONNX 结果对比验证 |

---

## 四、op — 自定义算子替换

**路径**: `op/`

### Gather 算子

```
op/gather/          # Gather 原始实现
op/parser-gather/   # ONNX Gather 解析器
op/gather-pass/     # 算子替换 Pass（优化阶段）
```

**编译**（Windows MSVC）：
```shell
cd op/gather/build
rm ./*
cmake ..
cmake --build . --config Release
# 输出：build/Release/GatherOP.Gather.dll
```

**在 icraft 中使用**：
1. `icraft parse` 解析原始 ONNX → 生成 json & raw
2. 设置环境变量 `$env:ICRAFT_CUSTOM_DIR="path/to/op/custom_op"`
3. `icraft optimize` 完成算子替换

---

## 五、FPGA — 工程与 IP 配置

**路径**: `FPGA/`

### 主要内容

- `FPGA/30TAI-PRJ/` — FPGA 工程工程文件
- `ip_patch/` — IP 补丁与 edif 网表
  - `edif/` — 综合后的 EDIF 网表
  - `edif_transform/` — EDIF 转换脚本
  - `tools/` — bitstream 替换等工具
  - `process_control/` — Vivado 综合/实现流程控制脚本

### 仿真脚本

| 仿真 | 路径 |
|------|------|
| Hadamard INT8 | `FPGA/30TAI-PRJ.sim/hadamard_int8/` |
| Hadamard | `FPGA/30TAI-PRJ.sim/Hadamard_sim/` |
| Resize | `FPGA/30TAI-PRJ.sim/resize_sim/` |
| Gather | `FPGA/30TAI-PRJ.sim/sim_1/` |

---

## 六、其他目录

| 目录 | 说明 |
|------|------|
| `processor/` | CLIP 图像预处理器（HuggingFace 格式） |
| `fmodel/` | ONNX 模型文件（原始 + Hadamard 优化版） |
| `configs/` | YAML 配置文件（图像/文本任务配置） |
| `sim/` | rtl仿真相关脚本 |
| `qtset/` | 量化校准数据集 |
| `test/` | 测试脚本 |

---
# CLIP ViT-B/32 FPGA 加速项目

本项目实现 CLIP (Contrastive Language-Image Pre-training) 模型在 FPAI 上的部署加速，在30TAI开发板上设计自定义算子，配合NPU实现异构协同加速，支持CLIP模型INT8\FP16量化推理。

---

## 目录结构

```
├── rtl/custom_op/          # RTL 设计 (Gather/Hadamard/Resize + 公共模块)
├── sim/                    # 仿真脚本 (hadamard/resize/gather/fmt_cvt)
├── deploy/                 # Python 模型部署 (SDK API 参考)
├── test/
│   ├── deploy/             # C++ 部署程序 (clip_app_web/dual/search_all/warmup)
│   ├── on-board-test/      # 单算子 C++ 测试 (fwht/resize/gather)
│   ├── soft-verification/  # Python Golden 模型
│   ├── Visualization/      # Python 可视化脚本
│   ├── web_ui/             # Web 演示系统 (server_onboard.py + operator_analysis)
│   ├── input-data/         # 算子测试输入 .mem
│   └── output-data/        # 算子测试输出
├── op/                     # 自定义算子替换 (ONNX Parser / Pass)
├── quant_optimize/         # 量化优化工具链
├── processor/              # CLIP 图像预处理器配置
├── fmodel/                 # ONNX 模型文件 (PC 端)
├── imodel/                 # NPU 模型文件 (板端)
├── configs/                # YAML 配置文件
```

---

## 一、rtl — 自定义算子 RTL 设计

**路径**: `rtl/`

### 1.1 custom_op — 核心硬件算子

| 算子               | 路径                           | 功能说明                                                     |
| ------------------ | ------------------------------ | ------------------------------------------------------------ |
| **Gather**   | `rtl/custom_op/gather/`      | 索引聚集 — 根据索引表从 DDR 读取不规则位置数据              |
| **Hadamard** | `rtl/custom_op/hadamard/`    | 快速沃尔什-哈达玛变换 (FWHT) — 6 级蝶形网络，支持 INT8/FP16 |
| **Resize**   | `rtl/custom_op/resize_crop/` | 双线性插值缩放 + 中心裁剪                                    |
### 1.2 公共模块

| 路径                         | 说明                                    |
| ---------------------------- | --------------------------------------- |
| `rtl/public/fifo/`         | 同步 FIFO                               |
| `rtl/custom_op/AVR/`       | AXI-Stream 寄存器切片（avr_rs/brs/frs） |
| `rtl/custom_op/arbiter.v`  | DMA 仲裁器                              |
| `rtl/custom_op/dma.v`      | 通用 DMA 引擎                           |
| `rtl/custom_op/reg_ctrl.v` | 寄存器配置接口                          |

### 1.3 周期计数器

每个算子内置 32-bit 周期计数器（`comp_start` → `comp_done`），可读寄存器：

| 算子     | 地址              | AXI 偏移 | C++ 读取            |
| -------- | ----------------- | -------- | ------------------- |
| Gather   | RFU_RADDR0 (0x21) | `0x84` | `reg_base + 0x84` |
| Hadamard | RFU_RADDR1 (0x22) | `0x88` | `reg_base + 0x88` |
| Resize   | RFU_RADDR2 (0x23) | `0x8C` | `reg_base + 0x8C` |

### 1.4 顶层与参考

- `rtl/ai7030_edif_top.v` — AI7030 顶层综合文件
- `rtl/ps_ai_wrap_demo.v` — PS-AI 封装示例
- `rtl/sdi/` — 串行数据接口（参考）

RTL代码详细说明：[RTL代码介绍](./rtl/rtl_summary.md)

---

## 二、sim — 仿真

**路径**: `sim/`

| 仿真          | 文件                         | 测试规模                              |
| ------------- | ---------------------------- | ------------------------------------- |
| Hadamard      | `sim/hadamard_sim.sv`      | 768×30 FP16（720 块），AXI DDR 模型  |
| Hadamard INT8 | `sim/hadamard_int8_sim.sv` | INT8 模式                             |
| Resize        | `sim/resize_sim.sv`        | 640×480 → 224×224，CLIP 标准预处理 |
| Gather        | `sim/gather_sim.sv`        | 256×256 → 77×256                   |

仿真输入数据由 `test/input-data/` 下的生成脚本产生。

---

## 四、test/deploy — C++ 部署程序

**路径**: `test/deploy/`

| 程序 | 用途 | 配置文件 |
|------|------|---------|
| `clip_app_web` | **主程序**: 实时分类 + 搜图, 支持 Web UI (子进程 stdin/stdout) | `configs/app_config.yaml` |
| `clip_dual` | 独立实时分类 (命令行交互, 增删标签) | `configs/clip_config.yaml` |
| `clip_search_all` | 独立搜图 (10s 自动采集 + JPEG 回放 + 视频导入 + 查询) | `configs/search_config.yaml` |
| `clip_warmup` | 模型预热 (加载 text+vision 模型, 启动 camera+HDMI, 编译完成后退出) | `configs/clip_config.yaml` |

### 辅助模块

| 文件 | 说明 |
|------|------|
| `simple_tokenizer.hpp` | C++ CLIP BPE 分词器 (替代 Python gen_input_ids.py) |
| `op-func/op_resize.h` / `.cpp` | Resize 硬算子 C++ 封装 |
| `compile_fpai_target.hpp` | NPU 编译目标配置 |

### Python Runtime (参考)

**路径**: `deploy/modelzoo/clip/pyrt/`

| 脚本 | 功能 |
|------|------|
| `clip.py` | CLIP 主推理流程 |
| `clip_img_host.py` | 图像特征提取 |
| `clip_text_host.py` | 文本特征提取 |
| `clip_full_pipeline.py` | 完整 pipeline |
| `clip_full_pipeline_camera.py` | 摄像头实时推理 |

---

## 五、op — 自定义算子替换

**路径**: `op/`

```
op/gather/          # Gather 原始实现
op/parser-gather/   # ONNX Gather 解析器
op/gather-pass/     # 算子替换 Pass
```

**编译**（Windows MSVC）：

```shell
cd op/gather/build
cmake ..
cmake --build . --config Release
```

**使用**：`icraft parse` → 设置 `ICRAFT_CUSTOM_DIR` → `icraft optimize`

---

## 六、quant_optimize — 量化优化

**路径**: `quant_optimize/`

| 文件                        | 说明                                                            |
| --------------------------- | --------------------------------------------------------------- |
| `clip_hadamard.py`        | **核心**：Hadamard 量化优化 — 异常值检测 → 旋转 → 导出 |
| `mix_config_hadamard.csv` | Hadamard 分组配置                                               |

**流程**：加载 ONNX → 校准激活值 → 检测异常层 → 权重旋转 `W' = H@W` → 插入 `MatMul(X, H^T)` → 导出

---

## 七、test — 测试与可视化

**路径**: `test/`

### 7.1 板上测试

| 程序   | 路径                                   | 功能                                                                    |
| ------ | -------------------------------------- | ----------------------------------------------------------------------- |
| FWHT   | `test/on-board-test/fwht_test.cpp`   | 内联生成 768×30 离群值数据 → FPGA 计算 → 输出 .mem + 周期数 + 波形图 |
| Gather | `test/on-board-test/gather_test.cpp` | 内联生成 256×256 彩虹矩阵 + 77 索引 → FPGA 提取 → 输出 .mem + 周期数 |
| Resize | `test/on-board-test/resize_test.cpp` | 命令行传入图像 → FPGA 缩放裁剪 → 输出 .mem + .png                     |

输出文件统一命名 `test/output-data/hardware/xx-output-board.xx`。

### 7.2 Golden 模型

| 模型     | 路径                                         | 功能                                               |
| -------- | -------------------------------------------- | -------------------------------------------------- |
| FWHT     | `test/soft-verification/fwht_golden.py`    | 64-pt Walsh-Hadamard + 768×30 块对角 + 离群值分析 |
| Resize   | `test/soft-verification/resize_golden.py`  | 中心裁剪 + 双线性插值，与 RTL 逐位对齐             |
| Gather   | `test/soft-verification/gather_golden.py`  | Gather 参考模型                                    |
| 量化分析 | `test/soft-verification/quant_analysis.py` | FWHT 对 INT8/INT4 量化 SNR 影响                    |

Golden 模型用于仿真对比和 Web UI 分析。

### 7.3 可视化工具

| 工具        | 路径                                             | 功能                                  |
| ----------- | ------------------------------------------------ | ------------------------------------- |
| FWHT 多向量 | `test/Visualization/visualize_fwht.py`         | 输入/Golden/HW/全量 Hadamard 波形对比 |
| FWHT 单通道 | `test/Visualization/visualize_fwht_channel.py` | 随机通道输入/输出波形（C++ 调用）     |
| Gather      | `test/Visualization/visualize_gather.py`       | 输入矩阵 + 索引散点 + 输出矩阵热力图  |
| 通用        | `test/Visualization/visualize_data.py`         | .mem 像素数据 → RGB 图像             |
| 图像转换    | `test/soft-verification/img2mem.py`            | JPEG/PNG → RTL 兼容 .mem 格式        |

### 7.4 数据生成脚本

| 脚本        | 路径                                         | 功能                         |
| ----------- | -------------------------------------------- | ---------------------------- |
| FWHT 输入   | `test/input-data/generate_input.py`        | FP16/INT8/OUTLIER 模式       |
| Gather 输入 | `test/input-data/generate_gather_input.py` | 256×256 彩虹矩阵 + 随机索引 |
| Resize 输入 | `test/input-data/generate_resize_input.py` | 渐变/随机/外部图像           |

### 7.5 Web 演示系统

**路径**: `test/web_ui/`

基于 FastAPI + WebSocket，通过子进程控制板端 C++ 程序 (`clip_app_web`)，支持板端部署和 PC 浏览器访问。

**启动**：

```bash
cd test/web_ui
pip install fastapi uvicorn websockets numpy Pillow matplotlib
python server_onboard.py --host 0.0.0.0 --port 8888
```

**功能**：

- **模型预热** — 一键运行 `clip_warmup` 预编译模型
- **实时分类** — 摄像头 + CLIP 图文匹配，运行时增删标签
- **文本搜图** — 10s 自动采集 + JPEG 回放 + 以文找图
- **算子测试** — FWHT / Resize / Gather 硬件验证与可视化

**后端模块**：

| 文件 | 功能 |
|------|------|
| `server_onboard.py` | FastAPI + WebSocket 服务端, 管理 clip_app 子进程 |
| `inference_engine.py` | CLIP ONNX 推理 + HardOp 模拟 (PC 端) |
| `operator_analysis_onboard.py` | 板端算子分析 (C++ 硬件执行 + Python 可视化) |

部署文档：[DEPLOY.md](test/DEPLOY.md)

---

## 八、其他目录

| 目录           | 说明                                                |
| -------------- | --------------------------------------------------- |
| `processor/` | CLIP 图像预处理器                                   |
| `fmodel/`    | ONNX 模型文件 (PC 端)                               |
| `imodel/`    | NPU 模型文件 (板端, JSON+RAW)                       |
| `configs/`   | YAML 配置文件                                       |
| `board_data/`| 板端数据 (token_emb.bin, pos_emb.bin, text_proj.bin, merges.txt) |
| `qtset/`     | 量化校准数据集                                      |

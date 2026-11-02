# 项目结构与使用指引

> 本文档介绍 `clip-vit-base-patch32-zg` 项目的目录结构、编译、部署与测试操作。
> 技术实现方案（RTL 算子设计、量化协同、性能）见 [README.md](./README.md)。
> 环境搭建（硬件/SDK/Docker/编译链）见 [SETUP.md](./SETUP.md)。

---

## 一、目录结构

```
clip-vit-base-patch32-zg/
├── rtl/                      # RTL 设计 (项目核心, 详见 README 技术章节)
│   ├── custom_op/            #   Gather / Hadamard / Resize 硬算子 + 公共模块
│   │   ├── gather/           #   索引聚集算子
│   │   ├── hadamard/         #   FWHT 蝶形网络算子 (INT8/FP16)
│   │   ├── resize_crop/      #   双线性缩放 + 中心裁剪算子
│   │   ├── AVR/              #   AXI-Stream 寄存器切片
│   │   ├── arbiter.v         #   DMA 仲裁器
│   │   ├── dma.v             #   通用 DMA 引擎
│   │   └── reg_ctrl.v        #   寄存器配置接口
│   ├── sim/                  #   仿真 (RTL 验证)
│   │   ├── hadamard_sim.sv        #   FWHT 仿真 (768×30 FP16, AXI DDR 模型)
│   │   ├── hadamard_int8_sim.sv   #   FWHT INT8 模式仿真
│   │   ├── resize_sim.sv          #   Resize 仿真 (640×480→224×224)
│   │   ├── gather_sim.sv          #   Gather 仿真 (256×256→77×256)
│   │   └── adder_sim.sv           #   加法算子参考仿真
│   ├── public/fifo/          #   同步 FIFO
│   ├── ai7030_edif_top.v     #   AI7030 顶层综合文件
│   ├── ps_ai_wrap_demo.v     #   PS-AI 封装示例
│   ├── sdi/                  #   串行数据接口 (参考)
│   └── rtl_summary.md        # RTL 代码详细介绍
├── quant_optimize/           # 量化优化工具链
│   ├── clip_hadamard.py      #   Hadamard 旋转量化核心
│   └── mix_config_hadamard.csv
├── op/                       # 自定义算子替换 (Windows 端, ONNX Parser / Pass)
│   ├── gather/               #   Gather 原始实现
│   ├── parser-gather/        #   ONNX Gather 解析器
│   ├── gather-pass/          #   算子替换 Pass
│   ├── matmul/ + matmul-pass/#   MatMul 自定义算子 (探索)
│   ├── custom_op/            #   编译产物 dll (GatherOP.Gather.dll)
│   └── readme.md             #   说明
│   ├── gather/               #   原始实现
│   ├── parser-gather/        #   ONNX 解析器
│   └── gather-pass/          #   算子替换 Pass
├── deploy/
│   ├── README.md             # 测试/运行时程序说明 (硬算子测试逻辑 + clip_app_split)
│   ├── src/                  # ★ C++ 源文件唯一来源
│   │   ├── clip_app_split.cpp    # 主程序 (split 版, 三段切分链路)
│   │   ├── clip_app_web.cpp      # 主程序 (web 版, 单模型)
│   │   ├── clip_dual.cpp         # 独立实时分类
│   │   ├── clip_search_all.cpp   # 独立搜图
│   │   ├── clip_warmup.cpp       # 模型预热
│   │   ├── fwht_test.cpp         # FWHT 硬算子板上测试
│   │   ├── resize_test.cpp       # Resize 硬算子板上测试
│   │   ├── gather_test.cpp       # Gather 硬算子板上测试
│   │   ├── mem_file_utils.cpp/hpp # 算子测试公共内存工具
│   │   ├── adder_demo.cpp        # 加法算子参考
│   │   ├── sdicamera+yolov5+hdmi.cpp / sdi_to_hdmi.cpp / sdi_capture_640x480.cpp
│   │   ├── clip_vision.cpp / clip_app.cpp / text_middle_test.cpp
│   │   ├── simple_tokenizer.hpp  # BPE 分词器
│   │   └── op-func/              # 硬算子 host 驱动 (op_resize/op_fwht/op_gather)
│   ├── deps/                 # ★ SDK 依赖 (编译必需, 已并入项目)
│   │   ├── modelzoo_utils/   #   et_device.hpp / icraft_utils.hpp
│   │   └── thirdparty/       #   opencv / onnxruntime / yaml-cpp 等
│   └── modelzoo/             # Python 模型部署 (SDK API 参考)
│       └── clip/pyrt/        #   Python CLIP 推理参考
├── compile/                  # 编译环境
│   ├── CMakeLists.txt        #   源文件指向 ../deploy/src, 依赖 ../deploy/deps
│   └── build/                #   构建产物 (build/ZG 交叉编译)
├── web_ui/                   # Web 界面系统
│   ├── server_split.py       #   split 版服务 (启动 clip_app_split)
│   ├── server_onboard.py     #   web 版服务 (启动 clip_app_web)
│   ├── operator_analysis_onboard.py  # 算子分析后端
│   ├── inference_engine.py   #   CLIP ONNX 推理 + HardOp 模拟 (PC 端)
│   ├── static/               #   前端页面
│   ├── configs/              #   Web UI 配置
│   └── DEPLOY.md             #   Web 服务部署说明
├── test/                     # 验证数据与工具 (Web UI 依赖, 见 test/README.md)
│   ├── README.md             #   验证/可视化/上板流程说明
│   ├── soft-verification/    #   Python Golden 模型 (fwht/resize/gather/quant)
│   ├── Visualization/        #   Python 可视化脚本
│   ├── input-data/           #   算子测试输入 .mem + 生成脚本
│   ├── output-data/          #   算子测试输出 (hardware/ 供 Web UI 可视化)
│   └── board_data/           #   板端数据 (token_emb/pos_emb/text_proj/merges/labels.txt)
├── configs/                  # YAML 配置文件
│   ├── app_config.yaml       #   web 版主程序配置
│   ├── app_config_split.yaml #   split 版主程序配置
│   ├── clip_config.yaml      #   dual/warmup 配置
│   ├── search_config.yaml    #   搜图配置
│   ├── hada.toml / img.toml / text.toml   # 模型编译配置 (Hadamard/图像/文本)
│   ├── quant_autotune_config.toml         # 量化调优配置
│   └── ZG/sdicamera+yolov5+hdmi.yaml  # 相机/设备参数
├── processor/                # CLIP 文本 tokenizer 完整配置 (HF 格式)
│   ├── merges.txt            #   BPE 合并表 (板端用, gen_board_data.py 拷贝)
│   └── tokenizer.json / vocab.json / config.json 等  # 分词器全套
├── fmodel/                   # ONNX 模型文件 (PC 端)
│   ├── vision/               #   视觉模型 (clip_vit_b32 / hadamard_gs64 / split 切分模型)
│   └── text/                 #   文本模型 (text_model.onnx, gen_board_data 提取源)
├── imodel/                   # NPU 模型编译产物 (板端, JSON+RAW)
│   ├── vision/split/         #   seg_pre/seg_post 的 ZG 阶段产物
│   └── text_encoder/         #   text_middle_ZG 等各阶段产物
├── qtset/                    # 量化校准数据集 (coco/imagenet 子集)
├── constrs/                  # FPGA 约束文件 (ai7030.xdc / impl_constraints.xdc)
├── BOOT_Gen/                 # 板卡启动镜像 (BOOT.bin / bitstream / u-boot)
├── FPGA/                     # Vivado 工程 (30TAI-PRJ)
└── README.md                 # 技术栈说明
```

---

## 二、C++ 程序清单 (deploy/src/)

### 2.1 主程序

| 程序                | 用途                                                                                 | 配置文件                          |
| ------------------- | ------------------------------------------------------------------------------------ | --------------------------------- |
| `clip_app_split`  | **主程序 (split 版)**: seg_pre→FWHT→seg_post 三段链路, 实时分类+搜图, Web UI | `configs/app_config_split.yaml` |
| `clip_app_web`    | 主程序 (web 版): 单模型 vis 链路                                                     | `configs/app_config.yaml`       |
| `clip_dual`       | 独立实时分类 (命令行)                                                                | `configs/clip_config.yaml`      |
| `clip_search_all` | 独立搜图 (采集+视频导入+查询)                                                        | `configs/search_config.yaml`    |
| `clip_warmup`     | 模型预热                                                                             | `configs/clip_config.yaml`      |

### 2.2 单算子板上测试

| 程序            | 用途                                      |
| --------------- | ----------------------------------------- |
| `fwht_test`   | FWHT 硬算子功能测试, 输出 .mem + 周期计数 |
| `resize_test` | Resize 硬算子功能测试                     |
| `gather_test` | Gather 硬算子功能测试                     |

### 2.3 其他

| 程序                      | 用途                   |
| ------------------------- | ---------------------- |
| `sdicamera+yolov5+hdmi` | YOLOv5 目标检测参考    |
| `sdi_to_hdmi`           | SDI 摄像头直通 HDMI    |
| `sdi_capture_640x480`   | SDI 摄像头单帧采集测试 |
| `clip_vision`           | 视觉模型单独测试       |
| `clip_app`              | 早期版实时分类         |
| `text_middle_test`      | 文本编码器中间层测试   |

---

## 三、配置文件

### 3.1 split 版 (configs/app_config_split.yaml)

```yaml
camera_yaml: "/root/fpai_demo_app/examples/1/2/configs/ZG/sdicamera+yolov5+hdmi.yaml"
pre_json:  "/root/fpai_demo_app/examples/split/vit_seg_pre_ZG.json"
pre_raw:   "/root/fpai_demo_app/examples/split/vit_seg_pre_ZG.raw"
post_json: "/root/fpai_demo_app/examples/split/vit_seg_post_ZG.json"
post_raw:  "/root/fpai_demo_app/examples/split/vit_seg_post_ZG.raw"
text_json: "/root/fpai_demo_app/examples/1/2/imodel/ZG/text_middle_ZG.json"
text_raw:  "/root/fpai_demo_app/examples/1/2/imodel/ZG/text_middle_ZG.raw"
data_dir: "board_data/"
labels_txt: "board_data/labels.txt"
clip_interval: 5
gallery_size: 10
cap_frames_dir: "board_data/cap_frames/"
```

### 3.2 data_dir 所需文件

| 文件              | 说明                              |
| ----------------- | --------------------------------- |
| `token_emb.bin` | Token 嵌入表 (49408×512 float32) |
| `pos_emb.bin`   | 位置嵌入表 (77×512 float32)      |
| `text_proj.bin` | 文本投影矩阵 (512×512 float32)   |
| `merges.txt`    | BPE 合并表                        |

**生成方法**（一条命令，从 fmodel/text/text_model.onnx 提取 + processor/merges.txt 拷贝）：

```bash
python3 deploy/src/gen_board_data.py
# 产出: test/board_data/{token_emb,pos_emb,text_proj}.bin + merges.txt
# 部署时拷贝到板卡 data_dir
```

---

## 四、编译

```bash
cd compile
cmake -S . -B build/ZG -DTARGET_CHIP=ZG      # ZG330 后端交叉编译
cmake --build build/ZG --target clip_app_split -j4   # 指定目标
cmake --build build/ZG -j4                    # 全量编译
```

产出物在 `compile/build/ZG/` 下。

**源文件单一来源**：所有目标源文件位于 `deploy/src/`，CMake 自动引用。新增程序步骤：

1. 在 `deploy/src/` 放置 `xxx.cpp`
2. 在 `compile/CMakeLists.txt` 的 `TARGET_NAMES` 注册名字

---

## 五、部署与启动（板卡）

### 5.1 板卡目录结构

```
/root/fpai_demo_app/examples/1/2/
├── clip_app_split              # 主程序二进制
├── configs/app_config_split.yaml
├── imodel/ZG/                  # text_middle_ZG.{json,raw}
├── board_data/                 # token_emb/pos_emb/text_proj/merges/labels.txt
└── web_ui/                     # server_split.py + static/

/root/fpai_demo_app/examples/split/
├── vit_seg_pre_ZG.{json,raw}
└── vit_seg_post_ZG.{json,raw}
```

### 5.2 启动流程

```
1. 上电后: ./clip_warmup configs/clip_config.yaml (预编译模型, 自动退出)
2. cd web_ui && python3 server_split.py --host 0.0.0.0 --port 8888
3. PC 浏览器打开 http://192.168.137.10:8888 (上位机 192.168.137.1)
```

### 5.3 Web UI 功能

- 模型预热 (clip_warmup)
- 实时分类 mode dual: add/del 标签, HDMI 显示 Top-1
- 搜图 mode search: cap 采集 / vid 导入 / 文本查询
- 算子测试: FWHT/Resize/Gather 可视化

### 5.4 纯命令行

```bash
./clip_app_split configs/app_config_split.yaml
> mode dual
> add a photo of a cat
> add man
(空行退出)
```

---

## 六、测试与验证

### 6.1 单算子测试

```bash
cd compile/build/ZG
./fwht_test              # FWHT: 输出 .mem + 周期数
./resize_test image.jpg  # Resize: 硬件缩放
./gather_test            # Gather: 索引提取
```

输出在 `test/output-data/hardware/`，供 Web UI 可视化。

### 6.2 Golden 验证 (test/soft-verification/)

| 脚本                  | 功能                                    |
| --------------------- | --------------------------------------- |
| `fwht_golden.py`    | FWHT 参考模型 (64-pt + 块对角 + 离群值) |
| `resize_golden.py`  | Resize 参考 (与 RTL 逐位对齐)           |
| `gather_golden.py`  | Gather 参考                             |
| `quant_analysis.py` | 量化 SNR 分析                           |

### 6.3 可视化 (test/Visualization/)

| 脚本                    | 功能                    |
| ----------------------- | ----------------------- |
| `visualize_fwht.py`   | 输入/Golden/HW 波形对比 |
| `visualize_gather.py` | 矩阵热力图              |
| `visualize_data.py`   | .mem → RGB 图像        |

---

## 七、网络拓扑

```
PC (192.168.137.1) ──以太网── 板卡 (192.168.137.10)
     浏览器访问                  C++ 程序 + Python Web 服务
     http://192.168.137.10:8888
```

# CLIP 板端部署与使用指引

## 网络拓扑

```
PC (192.168.137.1) ──以太网── 板卡 (192.168.137.10)
     浏览器访问                  C++ 程序 + Python Web 服务
     http://192.168.137.10:8888
```

---

## 一、C++ 程序清单

### 1.1 部署程序 (test/deploy/)

| 程序 | 用途 | 配置文件 |
|------|------|---------|
| `clip_app_web` | **主程序**: 实时分类 + 搜图, 支持 Web UI 控制 | `configs/app_config.yaml` |
| `clip_dual` | 独立实时分类 (命令行交互) | `configs/clip_config.yaml` |
| `clip_search_all` | 独立搜图: 采集 + 视频导入 + 查询 | `configs/search_config.yaml` |
| `clip_warmup` | 模型预热 (开机后运行一次, 预编译 text+vision) | `configs/clip_config.yaml` |

### 1.2 单算子测试 (test/on-board-test/)

| 程序 | 用途 |
|------|------|
| `fwht_test` | FWHT (Hadamard) 硬算子功能测试, 输出 .mem + 周期计数 |
| `resize_test` | Resize 硬算子功能测试 |
| `gather_test` | Gather 硬算子功能测试 |
| `fmt_cvt_test` | 格式转换硬算子功能测试 |

### 1.3 其他

| 程序 | 用途 |
|------|------|
| `sdicamera+yolov5+hdmi` | YOLOv5 目标检测参考 |
| `sdi_to_hdmi` | SDI 摄像头直通 HDMI |
| `sdi_capture_640x480` | SDI 摄像头单帧采集测试 |
| `clip_vision` | 视觉模型单独测试 (预处理对比 + benchmark) |
| `clip_app` | 早期版实时分类 (无 Web UI) |
| `text_middle_test` | 文本编码器中间层测试 |

---

## 二、配置文件

所有配置为 YAML 格式，共享以下结构：

```yaml
camera_yaml: "configs/ZG/sdicamera+yolov5+hdmi.yaml"  # 设备 + 相机参数
vis_json:    "imodel/vit_b32/clip_vit_b32_ZG.json"     # 视觉模型 JSON
vis_raw:     "imodel/vit_b32/clip_vit_b32_ZG.raw"      # 视觉模型权重
text_json:   "imodel/ZG/text_middle_ZG.json"            # 文本模型 JSON
text_raw:    "imodel/ZG/text_middle_ZG.raw"             # 文本模型权重
data_dir:    "board_data/"                              # 数据文件目录
labels_txt:  "board_data/labels.txt"                    # 初始标签 (可选)
clip_interval: 10                                       # 每 N 帧推理一次
```

`data_dir` 下需要的文件：

| 文件 | 说明 |
|------|------|
| `token_emb.bin` | Token 嵌入表 (49408×512 float32) |
| `pos_emb.bin` | 位置嵌入表 (77×512 float32) |
| `text_proj.bin` | 文本投影矩阵 (512×512 float32) |
| `merges.txt` | BPE 合并表 (C++ 分词器用) |

---

## 三、编译

```bash
cd test/deploy
mkdir build && cd build
cmake .. && make -j4
```

产出物在 `test/` 目录下：`clip_app_web`, `clip_dual`, `clip_search_all`, `clip_warmup` 等。

---

## 四、部署与启动流程

### 4.1 推荐流程

```
1. 上电后运行: ./clip_warmup configs/clip_config.yaml
   → 预编译 text + vision 模型, 初始化 SDI PHY, 自动退出

2. 启动 Web 服务:
   cd test/web_ui
   python server_onboard.py --host 0.0.0.0 --port 8888
```

### 4.2 Web UI 操作流程

```
PC 浏览器打开 http://192.168.137.10:8888
    │
    ├─ [模型预热] 按钮     → 板端执行 clip_warmup, 完成后指示灯变绿
    │
    ├─ [启动 clip_app] 按钮 → 板端执行 clip_app_web, 加载模型
    │                         初始标签在 camera 启动前完成编码
    │
    ├─ mode dual (实时分类)
    │   ├─ add <文本> → 运行时增删标签
    │   └─ HDMI 显示 Top-1 分类结果
    │
    └─ mode search (搜图)
        ├─ cap → 10 秒自动采集 (4fps 采样编码, 全帧 JPEG 回放)
        ├─ vid <dir> <fps> → 导入 jpg 序列建库
        └─ <文本> → 查询, HDMI 显示 Top-1 命中帧
```

### 4.3 纯命令行模式 (无 Web UI)

```bash
# 实时分类
./clip_dual configs/clip_config.yaml
> mode dual
> add a photo of a cat
> add a red car
(空行退出)

# 搜图
./clip_search_all configs/search_config.yaml
> cap          # 自动采集 10 秒
> tank         # 查询
> play         # 回到回放
(空行退出)
```

---

## 五、单算子测试

```bash
cd test
./fwht_test              # FWHT: 生成 768×30 FP16 数据 → 硬件执行 → 输出 .mem
./resize_test image.jpg  # Resize: 输入图片 → 硬件缩放 → 输出 .mem
./gather_test            # Gather: 索引提取 → 硬件执行 → 输出 .mem
```

输出文件在 `test/output-data/hardware/` 下，供 Web UI 可视化使用。

---

## 六、图像编码数据流

```
SDI 摄像头 (RGB565)
    │
    ▼
ImageMake (硬件, bypass) → BGR888 → PL-DDR
    │
    ▼
CPU 读 BGR → 拼 BGRX → rs_src (PL-DDR)
    │
    ▼
Resize 硬算子 (640×480 → 224×224, 裁剪+双线性)
    │
    ▼
CPU 归一化 FP32 → CLIP 视觉模型 (NPU) → emb (512-dim)
    │
    ▼
cosine(emb, text_feats) → Top-K
```

## 七、FPGA 算子启动流程

```
1. 配置寄存器地址 (REG_BASE + offset, offset = reg_ctrl_index × 4)
2. GP 口写配置寄存器 (数据宽度/精度/源地址/目标地址/数据量)
3. 写 start 寄存器 (触发硬件)
4. 轮询 done 寄存器 (等待处理完毕)
5. 读周期计数器 (cycles / 200MHz = us)
```

## 八、目录结构

```
clip-vit-base-patch32-zg/
├── rtl/custom_op/           # RTL: gather, hadamard, resize, fmt_cvt
├── test/
│   ├── deploy/              # 部署 C++ 程序
│   ├── on-board-test/       # 单算子 C++ 测试
│   ├── input-data/          # 算子测试输入 .mem
│   ├── output-data/hardware/ # 算子测试输出 .mem
│   ├── soft-verification/   # Python golden model
│   ├── Visualization/       # Python 可视化脚本
│   ├── web_ui/              # Web 服务 (server_onboard.py + static/)
│   │   └── operator_analysis_onboard.py  # 算子分析后端
│   └── DEPLOY.md            # 本文件
├── configs/                 # YAML 配置文件
├── board_data/              # token_emb.bin, pos_emb.bin, text_proj.bin, merges.txt
├── imodel/                  # NPU 模型 (JSON + RAW)
└── fmodel/                  # ONNX 模型 (PC 端用)
```

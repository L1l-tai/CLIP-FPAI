# iCraft 算子演示系统 — 部署与使用指引

## 网络拓扑

```
PC (192.168.137.1) ──以太网── 板卡 (192.168.137.10)
     浏览器访问                 运行全部服务
     http://192.168.137.10:8888
```

---

## 一、板端环境安装

### 1.1 安装 Python 依赖

```bash
# 基础（算子演示必需）
pip install fastapi uvicorn websockets numpy Pillow matplotlib

# CLIP 推理（可选，需要时安装）
pip install onnxruntime transformers opencv-python
```

### 1.2 确认文件部署

板端项目目录结构：

```
clip-vit-base-patch32-zg/
├── fmodel/
│   ├── text_model.onnx            # CLIP 文本编码器
│   └── vision_model_hadamard.onnx # CLIP 图像编码器
├── test/
│   ├── input-data/
│   │   ├── fwht-input-768x30.mem      # FWHT 输入数据
│   │   ├── fwht-golden-768x30.mem     # FWHT golden 输出
│   │   └── resize-input-640x480.mem   # Resize 输入图像
│   ├── output-data/hardware/
│   │   ├── fwht-output-768x30.mem     # FWHT 硬件输出
│   │   └── resize-output-640x480.mem  # Resize 硬件输出
│   ├── soft-verification/             # Golden model 脚本
│   ├── Visualization/                 # 可视化脚本
│   └── web_ui/visualize_prj/          # Web 服务
│       ├── server.py
│       ├── operator_analysis.py
│       ├── inference_engine.py
│       ├── static/index.html
│       └── DEPLOY.md                  # 本文件
```

> **注意**：`fmodel/`、`test/input-data/`、`test/output-data/hardware/` 中的数据文件需提前生成或从仿真/硬件测试中拷贝。

---

## 二、板端启动

```bash
cd test/web_ui/visualize_prj
python server.py --host 0.0.0.0 --port 8888
```

启动成功后会显示：

```
INFO:     Uvicorn running on http://0.0.0.0:8888
```

> **防火墙提示**：如果 PC 无法访问，检查板端防火墙是否放行 8888 端口：
> ```bash
> sudo ufw allow 8888
> ```

---

## 三、PC 端使用

### 3.1 打开页面

浏览器输入 `http://192.168.137.10:8888`，看到以下界面：

```
┌─ 页眉：系统状态栏 ─────────────────────────────┐
│ 模式  板端连接  摄像头  模型加载                │
├──────────┬────────────────────┬────────────────┤
│ 控制面板  │   中央画面（摄像头） │   结果面板      │
│          │                    │  [实时推理]     │
│ Load     │                    │  [文本搜图]     │
│ Models   │                    │  [算子测试]     │
│          │                    │                │
│ 摄像头   │                    │                │
│ 候选标签 │                    │                │
│          │                    │                │
├──────────┴────────────────────┴────────────────┤
│ 运行日志                                        │
└────────────────────────────────────────────────┘
```

### 3.2 算子测试（无需模型）

1. 点击右侧 **⚙️ 算子测试** tab
2. 右侧出现三个算子卡片，点击对应按钮：

| 按钮 | 结果 |
|------|------|
| 运行 FWHT 分析 | 中央显示波形图 + 量化指标 |
| 运行 Resize 分析 | 中央显示 Input/Golden/Hardware 对比 + PSNR/Cosine |
| 运行 Gather 分析 | 中央显示输入/索引/输出热力图 |

### 3.3 CLIP 推理（需要模型）

1. 点击 **Load Models** 加载 ONNX 模型
2. 模型加载成功后自动初始化文本特征
3. 修改候选标签（默认 10 类），点击 **更新文本特征**
4. 启动摄像头 → 点击 **开始推理**

---

## 四、常见问题

| 问题 | 解决方法 |
|------|---------|
| 页面打不开 | `ping 192.168.137.10` 检查网络连通性 |
| WebSocket 断连 | 检查板端终端日志，确认 `uvicorn` 正常运行 |
| 算子分析报错 | 确认 `test/input-data/` 和 `test/output-data/hardware/` 中数据文件存在 |
| 模型加载失败 | 确认 `fmodel/` 中 ONNX 文件存在，`onnxruntime` 已安装 |
| 算子分析超时 | 首次运行较慢（golden model 计算），后续有缓存 |

# test/ — 验证数据与工具

> 本目录存放算子验证的输入/输出数据、Golden 模型、可视化脚本与板端数据。
> **⚠️ Web UI 强依赖本目录**（见第四节）——不可整体移动/删除。

---

## 一、目录结构

```
test/
├── board_data/           # 板端运行数据 (token_emb/pos_emb/text_proj/merges)
│                         #   ← 由 deploy/src/gen_board_data.py 生成
├── input-data/           # 算子测试输入 .mem + 生成脚本
│   ├── fwht-input-768x30.mem        # FWHT 输入 (FP16, 离群值)
│   ├── gather-input-data-256x256.mem  # Gather 输入 (彩虹矩阵)
│   ├── resize-input-640x480.mem     # Resize 输入图像
│   ├── generate_input.py            # FWHT 输入生成 (FP16/INT8/OUTLIER 模式)
│   ├── generate_gather_input.py     # Gather 输入生成 (彩虹矩阵+随机索引)
│   └── generate_resize_input.py     # Resize 输入生成 (渐变/随机/外部图)
├── output-data/          # 测试输出
│   ├── expect/           # Golden 期望值 (fwht-golden-768x30.mem 等, 供对比)
│   └── hardware/         # 板上执行输出 (.mem/.png, 供 Web UI 可视化)
├── soft-verification/    # Python Golden 模型与验证脚本
│   ├── fwht_golden.py    # FWHT 参考模型 (64-pt + 块对角 + 离群值)
│   ├── gather_golden.py  # Gather 参考
│   ├── resize_golden.py  # Resize 参考 (与 RTL 逐位对齐)
│   ├── verify_fwht.py / verify_gather.py / verify_resize.py  # 板上输出 vs Golden 对比
│   ├── quant_analysis.py # FWHT 对 INT8/INT4 量化 SNR 影响分析
│   └── img2mem.py        # JPEG/PNG → RTL 兼容 .mem
└── Visualization/        # 可视化脚本
    ├── visualize_fwht.py           # 输入/Golden/HW 波形对比
    ├── visualize_fwht_channel.py   # 随机通道波形 (C++ 测试调用)
    ├── visualize_gather.py         # 矩阵热力图
    └── visualize_data.py           # .mem → RGB 图像
```

---

## 二、验证程序（soft-verification/）

**验证闭环**：`板上输出 (.mem) ↔ Golden 模型` 对比，确认硬件正确性。

| 脚本 | 用途 | 用法 |
|------|------|------|
| `fwht_golden.py` | FWHT 参考模型（Sylvester 序、块对角 12×H₆₄） | 生成 fwht-golden-768x30.mem |
| `gather_golden.py` | Gather 参考（按索引取行） | 生成期望输出 |
| `resize_golden.py` | 双线性插值参考（与 RTL 逐位对齐） | 生成期望图像 |
| `verify_fwht.py` | 板上 FWHT 输出 vs Golden 对比（cosine/max-diff） | `python verify_fwht.py <板输出.mem>` |
| `verify_gather.py` / `verify_resize.py` | 同上（Gather/Resize） | 同上 |
| `quant_analysis.py` | 量化 SNR 分析（FWHT 对 INT8/INT4 的影响） | 精度论证用 |
| `img2mem.py` | 图片 → RTL 兼容 .mem | Resize 测试输入准备 |

---

## 三、可视化程序（Visualization/）

| 脚本 | 功能 | 调用方 |
|------|------|--------|
| `visualize_fwht.py` | 输入/Golden/硬件输出三路波形对比 | 命令行 / Web UI |
| `visualize_fwht_channel.py` | 随机通道输入/输出波形（含硬件周期标注） | **fwht_test（C++ 内部调用）** |
| `visualize_gather.py` | 输入矩阵 + 索引散点 + 输出热力图 | Web UI |
| `visualize_data.py` | 通用 .mem → RGB 图像 | Web UI / 调试 |

---

## 四、⚠️ Web UI 依赖关系（重要）

`web_ui/operator_analysis.py`（PC 端）与 `operator_analysis_onboard.py`（板端）
**硬编码引用本目录四个子目录**（相对项目根）：

```python
_SOFT_VERIFY = _PROJECT_ROOT / "test" / "soft-verification"   # Golden 脚本
_VISUALIZE   = _PROJECT_ROOT / "test" / "Visualization"       # 可视化脚本
_INPUT_DATA  = _PROJECT_ROOT / "test" / "input-data"          # 算子输入 .mem
_OUTPUT_DATA = _PROJECT_ROOT / "test" / "output-data" / "hardware"  # 板输出 .mem
```

**Web UI "算子测试"按钮的执行链**（板端 onboard 版）：

```
前端点击 [FWHT 测试]
  → operator_analysis_onboard.run_fwht_hardware()
      → subprocess 运行 fwht_test (C++ 板上执行)
      → 输出写 test/output-data/hardware/fwht-output-768x30.mem
  → run_fwht_visualize()
      → subprocess 运行 test/Visualization/visualize_fwht_channel.py
      → 读 hardware/*.mem 出波形图 → base64 回传前端显示
  → 可选对比: test/soft-verification/verify_fwht.py (vs Golden)
```

**部署要求**：`test/` 目录必须与 `web_ui/` 同级存在（项目根下），
且 `output-data/hardware/` 可写（板上测试输出落盘）。

---

## 五、上板验证流程

### 5.1 命令行方式（直接验证硬件）

```bash
# 1. 编译 (见 compile/README)
cd compile && cmake --build build/ZG --target fwht_test gather_test resize_test -j4

# 2. 板卡执行 (产物拷贝到板卡后)
./fwht_test              # 生成输入 .mem + 硬件执行 + 输出 .mem + 周期数
./resize_test image.jpg  # 图像缩放测试
./gather_test            # 索引提取测试

# 3. 结果对比 (上位机, 项目根目录)
python test/soft-verification/verify_fwht.py test/output-data/hardware/fwht-output-768x30.mem
python test/soft-verification/verify_gather.py test/output-data/hardware/gather-output-256x256.mem
```

### 5.2 Web UI 方式（一键测试 + 可视化）

```
1. 启动 server: cd web_ui && python3 server_split.py --host 0.0.0.0 --port 8888
2. 浏览器打开 http://192.168.137.10:8888
3. 进入"算子测试"页 → 点击 FWHT/Resize/Gather 按钮
   → 板端执行 C++ 测试 → 可视化脚本出图 → 页面显示波形/热力图
```

### 5.3 验证判读

| 算子 | 正确性判据 |
|------|-----------|
| FWHT | 输出 vs `fwht_golden.py`：cosine ≈ 1.0（FP16 模式 ~0.999） |
| Gather | 输出行 = 输入矩阵对应索引行（彩虹渐变肉眼可验） |
| Resize | 输出 .png 无锯齿/失真（双线性 vs 纯裁剪对比） |
| 周期数 | FWHT ~65,000 cycles (325μs) / Gather 18.2μs / Resize 3.10ms |

---

## 六、与 deploy/src/ 的对应

| test/ 工具 | 对应 C++ 测试 (deploy/src/) |
|-----------|---------------------------|
| soft-verification/fwht_golden.py | fwht_test.cpp |
| soft-verification/gather_golden.py | gather_test.cpp |
| soft-verification/resize_golden.py | resize_test.cpp |
| input-data/generate_*.py | 测试输入（也可由 C++ 内联生成） |
| Visualization/visualize_*.py | fwht_test 内部调用 / Web UI |

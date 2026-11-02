# deploy/ — C++ 测试与运行时程序

> 本目录包含板端 C++ 全部源码（唯一来源）与 SDK 依赖。
> 编译见 [compile/README](../compile/README.md)，整体项目见 [STRUCTURE.md](../STRUCTURE.md)。

---

## 一、目录结构

```
deploy/
├── src/                      # ★ C++ 源码唯一来源 (编译环境自动引用)
│   ├── ★ 运行时主程序
│   │   ├── clip_app_split.cpp     # 最终实现: 三段切分链路实时分类 + 搜图 (Web UI)
│   │   ├── clip_app_web.cpp       # web 版: 单模型 vis 链路 (早期方案)
│   │   ├── clip_dual.cpp          # 独立实时分类 (命令行)
│   │   ├── clip_search_all.cpp    # 独立搜图 (采集+视频导入+查询)
│   │   ├── clip_warmup.cpp        # 模型预热
│   │   └── clip_vit_hadamard_split.cpp  # 切分链路验证 (seg_pre+FWHT+seg_post vs 参考)
│   ├── ★ 单算子板上测试
│   │   ├── fwht_test.cpp          # FWHT (Hadamard) 硬算子功能测试
│   │   ├── gather_test.cpp        # Gather 硬算子功能测试
│   │   ├── resize_test.cpp        # Resize 硬算子功能测试
│   │   └── mem_file_utils.cpp/hpp # .mem 文件读写工具 (测试共用)
│   ├── ★ 其他
│   │   ├── adder_demo.cpp         # 加法算子参考
│   │   ├── sdi_to_hdmi.cpp / sdi_capture_640x480.cpp  # SDI/HDMI 参考
│   │   ├── sdicamera+yolov5+hdmi.cpp                   # YOLOv5 参考
│   │   ├── clip_vision.cpp / clip_app.cpp / text_middle_test.cpp
│   │   └── simple_tokenizer.hpp   # BPE 分词器
│   └── op-func/              # 硬算子 host 驱动 (被 src/*.cpp 相对 include)
│       ├── op_resize.cpp/h   # Resize 硬算子封装
│       ├── op_fwht.cpp/h     # FWHT 硬算子封装
│       └── op_gather.cpp/h   # Gather 硬算子封装
├── deps/                     # SDK 依赖 (modelzoo_utils + thirdparty, 编译必需)
└── modelzoo/                 # Python 模型部署参考

test/ (数据与验证工具, 非源码)
├── soft-verification/        # Python Golden 模型
├── Visualization/            # 可视化脚本
├── input-data/               # 算子测试输入 .mem
├── output-data/hardware/     # 算子测试输出 .mem (供 Web UI 可视化)
└── board_data/               # 板端数据 (token_emb/pos_emb/text_proj/merges/labels)
```

---

## 二、三个硬算子测试代码逻辑

三个测试程序共享同一套流程：**生成/加载输入 → 寄存器复位 → 写 PL DDR → 配置寄存器 → 启动 → 轮询完成 → 读回 → 输出 .mem + 周期数**。

### 2.1 fwht_test — FWHT (Hadamard) 算子测试

**目的**：验证 768×30 FP16 激活数据的 Hadamard 变换正确性与硬件周期数。

```
流程:
1. 打开设备 (axi://zg330aiu?npu=0x40000000&dma=0x80000000), 读 VERSION 寄存器
2. 生成测试数据 (内联):
   - 768×30 FP16, 正常分布 (±2 截断)
   - 随机注入 10~20 个离群值 (幅值 10~100, 验证量化域极端值处理)
   - 可选: argv[1] 指定 .mem 文件加载 (外部数据)
3. 写输入 .mem → test/input-data/fwht-input-768x30.mem (供 golden 对比)
4. 硬件执行:
   - malloc PL DDR chunk → 复位 (REG_RESET 1→0)
   - 打包: float→FP16 小端块布局 (32 元素/block, 512-bit 对齐)
   - 写 src → 配置: DATA_WIDTH=2 / PRECISION=1(FP16) / RBASE / WBASE / WRSIZE=720
   - START → 轮询 DONE
5. 读回 dst → 解包 → 写输出 .mem
6. 打印周期数 (REG_CYCLE ÷ 200MHz = μs)  ← 论文效率对比数据
```

**验证要点**：输出 .mem 与 `soft-verification/fwht_golden.py` 对比（cosine ≈ 1.0）。

### 2.2 gather_test — Gather 算子测试

**目的**：验证按索引从矩阵提取行的正确性与访存加速。

```
流程:
1. 打开设备, 寄存器基址 = reg_ctrl 索引 × 4
2. 生成测试数据 (内联):
   - 256×256 INT8 彩虹矩阵 (行/列渐变, 便于肉眼验证提取位置)
   - 77 个随机索引 (模拟文本编码器 token 序列的 EOT 位置提取)
3. 写输入 .mem (矩阵 + 索引两份)
4. 硬件执行:
   - malloc chunk → 复位 → 写 idx (低地址) / 写 src 矩阵
   - 配置: INDICES_LEN / DATA_WIDTH_BEATS / idx 地址(低16位) / src / dst
   - START → 轮询 DONE
5. 读回 dst → 写输出 .mem
6. 打印周期数
```

**验证要点**：输出行 = 输入矩阵对应索引的行（彩虹渐变可肉眼/程序比对）。

### 2.3 resize_test — 图像裁剪缩放算子测试

**目的**：验证双线性插值缩放 + 中心裁剪的视觉质量与硬件周期数。

```
流程:
1. image_to_mem: 读入图片 (cv::imread) → cv::resize 到目标尺寸 → BGR → .mem
   (支持外部图片 / 渐变 / 随机输入)
2. 硬件执行:
   - 配置 resize 寄存器: src/dst 地址, 源/目标宽高, crop 使能
   - 触发 → 轮询完成
3. mem_to_image: 读回 .mem → 还原为图片 → cv::imwrite 输出 .png
4. 打印周期数 (约 3.10ms @1080P→224×224)
```

**验证要点**：输出图片与输入对比——无锯齿/失真（双线性插值 vs 纯裁剪）。

---

## 三、clip_app_split — 最终实现程序逻辑

### 3.1 程序骨架（main 主循环 + HDMI 回调）

```
main:
  1. 读配置 (app_config_split.yaml) → 模型路径/参数
  2. 打开设备 (axi://zg330aiu?npu=0x40000000&dma=0x80000000)
  3. 内存规划:
     gather_chunk (低地址, Gather indices 必须低 16 位)
     fwht_chunk   (gather 之后, 不抢占; 1200 blocks = 50 向量)
     imk_mem / rs_src / rs_dst (相机/缩放 DMA 区)
  4. 加载三模型: text (中间段) + seg_pre + seg_post, 各 initSession + apply
  5. 初始标签编码 (同步): "a photo of a cat" 强制加入 + labels.txt
     (label_feat 含 nan 自动重试)
  6. 启动 text 工作线程 (独立 NPU 执行流)
  7. 相机 actor + HDMI 显示 actor (pipeline 框架, 独立线程)
  8. 主循环: stdin 命令 → mode dual / mode search 分发
     退出: 停 text 线程 → join → 停 actor → 关设备

HDMI 回调 (每帧, 按 app_mode 分发):
  M_DUAL:
    ① add 队列处理 → 提交 text 线程 (见 3.3)
    ② n % CLIP_INTV == 0 → 分类: encode_camera_frame → 推理 → cosine → 显示
  M_SEARCH:
    ① 采集子模式 (定时采样编码入库)
    ② 查询处理 → 提交 text 线程 → 结果算 cosine Top-K
```

**双线程总体架构**（解决三会话 NPU 冲突）：

```
┌──────────────────────────── 主线程 (HDMI 回调) ────────────────────────────┐
│  SDI 相机 → ImageMake → resize硬算子 → CPU归一化                            │
│    → seg_pre(NPU) → FWHT硬算子 → seg_post(NPU) → emb(512)                  │
│    → cosine(emb, text_feats) → Top-K → HDMI/Web UI                         │
└────────────────────────────────────────────────────────────────────────────┘
┌──────────────────────────── text 工作线程 ────────────────────────────────┐
│  请求队列 (add/查询) → tokenize → text中间段(NPU) → Gather硬算子            │
│    → text_proj → l2norm → 特征回传 (更新 labels)                            │
└────────────────────────────────────────────────────────────────────────────┘
```

**设计动机**：text 编码在独立线程执行，与主线程 seg_pre/seg_post 推理并行——
避免"text 插入 → NPU 会话交替切换"的冲突（三会话交替是板上卡死根因）。
两把互斥锁保证资源安全：
- `g_hw_mutex`：0x400C0000 寄存器区互斥（Gather vs FWHT/Resize）
- `g_reset_mutex`：device.reset 与 text forward 互斥（reset 是设备级）

### 3.2 图像编码链路（resize_out_to_emb）

```
1. resize 硬算子输出读回 (224×224 BGRX) → CPU 归一化 (CLIP mean/std)
2. seg_pre.forward → [残差, LN1] (双输出, out[0]=残差 / out[1]=LN1)
3. LN1 → FP16 打包 (小端块布局) → FWHT 硬算子 (1200 blocks, ~325μs) → rot
4. seg_post.forward([残差, rot, rot, rot]) → emb(512) → l2norm
   (三份 rot 对应 q/k/v 三个旋转输入, 因 H 矩阵逐元素相同)
5. cosine(emb, 所有标签特征) → 排序 → Top-K
```

### 3.3 文本编码链路（text 工作线程 + encode_text）

```
1. 请求入队 (add 标签 / search 查询)
2. tokenize (BPE) → token_emb + pos_emb 查表 (77×512)
3. text 中间段 forward (NPU) → 77×512 特征
4. Gather 硬算子: 按 eot_idx 取 EOT 行 → eot_feat(512)
5. text_proj 投影 → l2norm → 512-dim 文本特征 → 回传更新标签库
```

### 3.4 模式与运行

| 模式 | 功能 | 关键逻辑 |
|------|------|---------|
| **dual**（实时分类） | 每 clip_interval 帧分类一次, HDMI 显示 Top-1 | add/del 标签运行时可增删 |
| **search**（搜图） | cap 采集 / vid 导入 / 文本查询 | 采集帧编码入库, 查询算 cosine Top-K |

### 3.5 运行保护机制

| 机制 | 行为 |
|------|------|
| NPU 任务超时 | waitForReady 2s 超时 → 丢帧 + `[WARN]` 提示 → 下一帧恢复 |
| 文本编码超时 | text 线程 15s 看门狗 → add 失败返回, 程序继续 |
| 分类 nan | 检测到 nan → 用上一次检测结果覆盖 + `[NAN]` 提示 |
| 初始化标签 nan | label_feat 含 nan → 自动重试编码一次 |
| 三会话冲突规避 | text 独立线程 + 双互斥锁 + **去每帧 reset + 超时 apply**（见 3.6） |

### 3.6 关键运行机制细节

**FWHT 调用（run_hadamard_768）**：
```
1. LN1 (FP32) → FP16 转换 (round-to-nearest, 10-bit 尾数)
2. 小端块布局打包: 32 元素/block, buf[j*2]=低字节 (与硬件 lane 提取匹配)
3. chunk.write (PL DDR, 锁外 — DMA 阻塞不连带卡死)
4. [g_hw_mutex 锁内] 复位(REG_RESET 1→0 + AXI 读回屏障) → 配置
   (DW=2 / PREC=1 / RBASE / WBASE / WRSIZE=1200) → START → 轮询 DONE
5. 读 CYCLE (÷200MHz = μs) → 解锁 → chunk.read (锁外)
```

**reset 策略（板上验证 10000 帧 + 大量标签稳定）**：
- **正常路径无 `device.reset(1)`**——NPU 会话（pre/post）状态连续运行
- **异常路径**（pre/post 超时丢帧）→ `reset(1)` + `session.apply()` **重建会话**——下次 forward 恢复正常
- text forward 与 reset 经 g_reset_mutex 互斥

**add 流程（异步，零延迟）**：
```
回调: add 命令 → 查重 → tokenize → 请求入队 → 等待结果 (15s 看门狗)
text 线程: 取请求 → encode_text → 特征回传 → 回调更新 labels → 立即恢复 (无排空延迟)
```

### 3.6.1 三会话 NPU 协同

**运行状态**：图像端 37.4ms 前向推理；标签规模较大时 seg_pre 任务会延迟（waitForReady 2s 超时），由程序状态重置恢复。

**机制要点**：
1. 每帧 `device.reset(1)` 高频调用会劣化 NPU 会话状态（web 2 会话无此现象）——正常路径已去掉
2. 标签插入量是触发条件（文本编码本身处理时间一致）
3. 相机/缓冲不受影响（日志确认缓冲正常流动）

**处理方式**：
1. **正常路径仅 post 后 reset**（pre 不 reset，会话状态连续）+ text 每次 warm/real 后 reset
2. **程序状态重置**：pre/post 超时 → 保存状态（labels/帧数）→ exec 自重启 → 自动恢复并进入 dual mode，**十几秒恢复**
3. 周期排空（每 100 次编码 20ms）+ FWHT 超时重试 + 预分配复用（零堆碎片）

### 3.7 关键配置（configs/app_config_split.yaml）

```yaml
pre_json/post_json: seg_pre/seg_post 模型 (三段链路)
text_json:          text 中间段模型
clip_interval: 5    # 每 5 帧分类一次 (检测帧率)
```

---

## 四、clip_vit_hadamard_split — 切分链路离线验证程序

**定位**：clip_app_split 的三段链路（seg_pre→FWHT→seg_post）在**离线环境**的验证程序——
单张图片输入，与整模型参考比对 cosine，是"切分正确性"的权威验证。

```
用法: clip_vit_hadamard_split <seg_pre.json> <seg_post.json> <input_rgb_fp32.bin> [ref_embeds.bin] [res_idx]
```

### 4.1 流程

```
1. 参数: pre/post 模型 json (raw 由路径推导) + 输入 bin (224×224×3 HWC RGB FP32)
   + 可选参考 bin (整模型 fp32 输出) + 可选残差位置 (0-3)
2. 设备: axi://zg330aiu, reg_base=0x400C0000
3. 加载 seg_pre / seg_post → initSession + apply
4. 【seg_pre】读 bin → cv::Mat → CvMat2Tensor → forward → 双输出
   dump_vec 检查: 残差应有限 / LN1 应 ~N(0,1) (识别双输出顺序)
5. 【FWHT】run_hadamard_768(LN1 → rot, 50 向量 = 1200 blocks)
   dump_vec 检查: rot 无 inf
6. 【seg_post】四输入 [残差, rot, rot, rot] → forward → embeds(512)
7. 【比对】embeds → l2norm → 写 vit_split_embeds.bin
   cosine vs ref (整模型 fp32) → 预期 ~0.95 (bf16 NPU + FP16 硬件的正常降精度)
```

### 4.2 诊断开关（排错工具）

| 开关 | 作用 |
|------|------|
| `SEGPRE_OUT` 约定 | out[0]=残差 / out[1]=LN1——shape 相同无法区分，靠统计特征认（LN1 近零均值单位方差）；反了交换两行 |
| `FWHT_DIAG_VEC` | =50 处理全部向量(1200 blocks)；临时改 30 验证 720 blocks 规模——区分"硬件 block 数限制"与"输入格式问题" |
| `SEGPOST_IN` / res_idx | 残差在 inputs()[0..3] 的位置（默认 0）——四输入 shape 全 [1,50,768] 无法靠 shape 分；cosine 偏低时依次试 0/1/2/3 |
| `dump_vec` | 每段输出前 5 值 + min/max/mean/nonfinite——分段定位 inf/NaN 来源 |

### 4.3 判读标准（重要）

- **cosine ≈ 1.0**：切分逻辑错误或 FWHT 打包问题（应排查）
- **cosine ≈ 0.95（0.94~0.97）**：✅ 成功——bf16 NPU 段 + FP16 硬件 FWHT 的预期降精度（与文本编码器中间段 bf16 同源，非 FWHT 错误）
- **cosine < 0.9**：优先怀疑 seg_post 四输入顺序（res_idx）→ FWHT 字节序 → seg_pre 输出顺序

---

## 五、从测试到最终程序的演进

```
fwht_test / gather_test / resize_test      ← 单算子验证 (硬件正确性 + 周期数)
        ↓ 验证通过
clip_vit_hadamard_split                    ← 三段链路离线验证 (cosine ~0.95, 诊断开关)
        ↓ 集成
clip_app_split                             ← 最终程序 (实时推理 + 文本线程 + Web UI + 自愈)
```

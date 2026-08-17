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
pip install -r requirements.txt   # 全部 Web 服务依赖 (fastapi/uvicorn/opencv/matplotlib 等)

# CLIP 推理（若走 PC 端 ONNX 推理，需要时安装）
pip install onnxruntime transformers opencv-python
```

### 1.2 文件部署

板端项目目录结构：

```
clip-vit-base-patch32-zg/
├── web_ui/                     # Web 服务 (位于项目根目录)
│   ├── server_onboard.py       # web 版服务 (启动 clip_app_web)
│   ├── server_split.py         # split 版服务 (启动 clip_app_split) ★
│   ├── operator_analysis_onboard.py  # 算子分析后端
│   ├── inference_engine.py
│   ├── static/                 # 前端页面 (index.html 等)
│   └── configs/                # Web UI 自身配置
├── deploy/src/                 # C++ 源文件 (唯一来源)
├── compile/build/ZG/           # 编译产物 (clip_app_split 等)
├── configs/                    # app_config.yaml / app_config_split.yaml
├── test/
│   ├── input-data/             # 算子测试输入 .mem
│   ├── output-data/hardware/   # 算子测试输出 .mem (fwht-output-768x30.mem 等)
│   ├── soft-verification/      # Golden model 脚本
│   └── Visualization/          # 可视化脚本
```

> **注意**：`test/input-data/`、`test/output-data/hardware/` 中的数据文件需提前生成或从仿真/硬件测试中拷贝。
> **⚠️ 算子测试功能依赖 `test/` 目录**（soft-verification / Visualization / input-data / output-data）——
> 需与 web_ui 同级部署，详见 [test/README.md](../test/README.md)。

---

## 二、板端启动

### 2.1 split 版 (推荐, 三段切分链路)

```bash
cd web_ui
python3 server_split.py --host 0.0.0.0 --port 8888
```

子进程: `../clip_app_split ./configs/app_config_split.yaml`（exe 与 web_ui 平级部署）

### 2.2 web 版 (单模型 vis 链路)

```bash
cd web_ui
python3 server_onboard.py --host 0.0.0.0 --port 8888
```

启动成功后会显示：

```
板卡服务: http://192.168.137.10:8888  (上位机 192.168.137.1 浏览器访问)
```

---

## 三、可用功能

| 功能 | 说明 |
|------|------|
| 模型预热 | 板端执行 clip_warmup |
| 实时分类 | mode dual: add/del 标签, HDMI 显示 Top-1 |
| 搜图 | mode search: cap 采集 / vid 导入 / 文本查询 |
| 算子可视化 | fwht/resize/gather 输出 .mem 可视化 |

## 四、IP 配置

| 角色 | IP |
|------|-----|
| 板卡 | 192.168.137.10 |
| 上位机 | 192.168.137.1 |

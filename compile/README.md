# 编译环境说明（compile/）

> 板端 C++ 程序的交叉编译环境。目录与操作见 [STRUCTURE.md](../STRUCTURE.md)，环境搭建见 [SETUP.md](../SETUP.md)。

---

## 一、作用

将 `deploy/src/` 的 C++ 源文件交叉编译为板卡（FMQL30TAI / ZG330）可执行程序。

**源文件单一来源**：所有目标源文件位于 `../deploy/src/`（本项目唯一源码目录），CMake 自动引用——**不需要在本目录维护源码副本**。

---

## 二、编译方法

```bash
# 1. 配置 (ZG330 后端)
cmake -S . -B build/ZG -DTARGET_CHIP=ZG

# 2. 编译全部目标
cmake --build build/ZG -j4

# 3. 或编译指定目标 (推荐, 快)
cmake --build build/ZG --target clip_app_split -j4
```

产物：`build/ZG/<target>`（aarch64 可执行文件）。

### 支持的芯片后端

| TARGET_CHIP | 后端 | 说明 |
|-------------|------|------|
| `ZG` | zg330backend | **30TAI 板卡（本项目）** |
| `BY` | buyibackend | 100TAI 板卡（未使用） |

---

## 三、目标程序清单

| 目标 | 用途 | 配置 |
|------|------|------|
| `clip_app_split` | 主程序（split 版）：seg_pre→FWHT→seg_post 三段链路实时分类+搜图 | `../configs/app_config_split.yaml` |
| `clip_app_web` | 主程序（web 版）：单模型 vis 链路 | `../configs/app_config.yaml` |
| `clip_dual` / `clip_search_all` / `clip_warmup` | 独立分类 / 搜图 / 预热 | 见 STRUCTURE |
| `fwht_test` / `resize_test` / `gather_test` | 单算子板上测试 | — |
| `clip_vit_hadamard_split` | 切分链路验证（seg_pre+FWHT+seg_post vs 参考） | 命令行参数 |
| `clip_app_split_m17` ~ `m23` | add 窗口期 margin 标定版（WAIT_MARGIN_MS 宏） | 调试用 |

---

## 四、依赖

| 依赖 | 位置 | 说明 |
|------|------|------|
| SDK 头文件/库 | `../deploy/deps/modelzoo_utils` | et_device.hpp / icraft_utils.hpp |
| 第三方库 | `../deploy/deps/thirdparty` | opencv / onnxruntime / yaml-cpp / fmt / spdlog |
| icraft 运行库 | 容器内 `/usr/lib/aarch64-linux-gnu/` | libicraft_zg330backend.so 等 |

CMake 变量 `DEPS_DIR` 默认 `../deploy/deps`，可用环境变量覆盖。

---

## 五、新增目标步骤

1. 在 `../deploy/src/` 放置 `xxx.cpp`
2. 在 `CMakeLists.txt` 的 `TARGET_NAMES` 注册名字
3. 重新 cmake 配置 + 编译

---

## 六、构建产物部署

```bash
# 产物上传板卡
scp build/ZG/clip_app_split root@192.168.137.10:/root/fpai_demo_app/examples/1/2/
# 板卡启动 (web_ui 同目录)
cd web_ui && python3 server_split.py --host 0.0.0.0 --port 8888
```

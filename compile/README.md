# PLin+SingleNet+VPU

本例子展示在SDICamera输入的情况下，快速验证单网络AI计算，HDMI显示等功能。

## 对应位流

### 100TAI

* [单路PLIN+pHDMI显示参考实现/25060601](https://download.fdwxhb.com/data/04_FMSH-AI/100AI/02_Icraft/v3.31/%e5%8f%82%e8%80%83%e5%ae%9e%e7%8e%b0/%e6%82%9f%e7%a9%ba%e5%bc%80%e5%8f%91%e6%9d%bf/%e5%8d%95%e8%b7%afPLIN+pHDMI%e6%98%be%e7%a4%ba%e5%8f%82%e8%80%83%e5%ae%9e%e7%8e%b0/25060601/)

### 30TAI

TODO

## 如何编译

### 编译100TAI（BY）版本

这将是默认行为。构建产物会生成在 `build/BY` 目录。

```bash
# 1. 清理旧的构建目录（如果存在）
rm -rf build

# 2. 配置CMake，指定输出目录为 build/BY
#    TARGET_CHIP 默认为 BY，所以可以不显式指定
cmake -S . -B build/BY

# 3. 编译
cmake --build build/BY -j$(nproc)
```

### 编译30TAI（ZG）版本

您需要通过 `-DTARGET_CHIP=ZG` 来告诉CMake构建ZG330版本。构建产物会生成在 `build/ZG` 目录。

```bash
# 1. 清理旧的构建目录（如果存在）
rm -rf build

# 2. 配置CMake，指定输出目录为 build/ZG，并设置芯片类型
cmake -S . -B build/ZG -DTARGET_CHIP=ZG

# 3. 编译
cmake --build build/ZG -j$(nproc)
```
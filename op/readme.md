### 自定义算子使用

#### 文档结构

Gather算子包含三个文件夹，分别是

1. gather：原始代码文件
2. parser-gather：解析相关文件
3. gather-pass： Gather算子替换Pass，在优化阶段完成

#### 编译方式

在自己的Windows环境中编译时，进入某个子文件夹，运行如下指令：

```shell
cd ./build
rm ./*
cmake ..
cmake --build . --config Release
```

即可完成动态链接库的构建，得到的dll文件保存在`build\Release`中

#### 在icraft中使用

当前的算子替换在optimize阶段实现，parse阶段可能会产生Unsupport算子，因此在icraft工具中实现替换需要经过以下几步流程

1. 使用`icraft parse`命令解析原始ONNX模型，得到parse阶段生成的`json & raw`文件。
2. 设置环境变量`$env:ICRAFT_CUSTOM_DIR="C:\path\to\your\folder\op\custom_op`，使得icraft能够找到自定义算子库
3. 使用`icraft optimize`命令优化parse阶段生成的`json & raw`文件，完成算子替换
4. 后续编译流程(量化、适配)
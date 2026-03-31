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

即可完成动态链接库的构建，得到的dll文件保存在 build\Release 中
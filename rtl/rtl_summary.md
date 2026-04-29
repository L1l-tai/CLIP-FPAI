# RTL 代码目录结构

## 一、目录概览

```
rtl/
├── ai7030_edif_top.v        # AI7030 顶层综合文件
├── ps_ai_wrap_demo.v        # PS-AI 封装示例
├── ps_ai_wrap_demo.edf      # 企业提供的 EDF 网表
│
├── custom_op/               # 自定义硬算子
│
├── public/                  # 公共模块
│
└── sdi/                    # SDI 相关模块
```

## 二、各目录/文件说明

`custom_op/ - 自定义算子`

包含三个核心硬件算子的完整实现：
- **Gather**: 索引聚集算子
- **Hadamard**: 快速沃尔什-哈达玛变换 (FWHT)
- **Resize**: 双线性插值缩放

👉 详细说明请查看 [custom_op 算子介绍](./custom_op/custom_op_summary.md)

`ai7030_edif_top.v`

AI7030 的顶层综合文件。

`ps_ai_wrap_demo.v / ps_ai_wrap_demo.edf`

PS-AI 封装示例模块。

`public/`

公共模块目录，存放被多个模块共用的基础组件。

`sdi/`

SDI (Serial Data Interface) 相关模块目录。

---


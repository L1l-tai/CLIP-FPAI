# Python API reference

## 须知

请先参见[C++ API reference.md](../C++ API reference.md)

python api 大部分都是从仿照c++ api利用python语言编写的，用于python版本的runtime，所以大部分 python api 与c++ api 功能一致，可以在[C++ API reference.md](../C++ API reference.md)中找到api的解释说明，后续此readme会进行逐步完善。

下面所解释函数是与c++ api中不同的python api

## icraft_utils.py

### Function numpy2Tensor

- Defined in [icraft_utils.py](./icraft_utils.py)

`def numpy2Tensor(input_array: np.ndarray,message) -> Tensor:`

- 参数:

  **input_array: numpy.ndarray** – 构造tensor的指定buffer的数据，类型为numpy.ndarray

  **message** – 可以传入不同类型的数据，包括Network、NetworkView、Value

- 返回:

  Tensor

- 说明:

Tensor构造函数，传入一个numpy.ndarray作为构造tensor的指定buffer的数据，另外传入的message可以是Network、NetworkView、Value，当传入network 或者networkview时候适用于单输入的网络去构造输入tensor。当传入value时候常适用于构造网络中任意位置（即传入对应value）的tensor。根据输入数据的value的tensortype，通过tensortype中的数据存储类型将**输入数据的类型转换为对应的数据类型**，且根据value完成输入tensor的形状、layout、数据类型的定义。

注意：注意使用时候input_array的维度要与实际网络输入位置维度保持一致
## Netinfo.py

### Class Netinfo

用network去初始化该类，可以获得对应网络的输入输出维度信息，fpga算子使用个情况，网络输出的量化scale信息等。

注意：①Netinfo类中包含一个成员变量inp_shape_opid，这个特定的opid设计用来帮助获取输入网络数据的shape,并且拿来进行网络的view，在模型库中一般是将网络前的cpu算子去掉，这样上板运行时候只运行npu部分，前处理自行实现。而对于仿真模式，由于网络前处理的cpu部分算子设计情况各式各样过于复杂，且仿真下并不需要追求运行速度。因此Netinfo类对于指令生成阶段网络和非指令生成阶段网络采用不同的方式获取inp_shape_opid，前者会根据算子的compile_target将网络前处理的最后一个cpu算子id赋值作为inp_shape_opid，后者只需保证 inp_shape_opid 对应的输入shape是正确的即可，网络无reshape,则inp_shape_opid即为0，若又reshape算子则inp_shape_opid为reshape的opid。
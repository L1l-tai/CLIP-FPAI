# C++ API reference

## icraft_utils.hpp

### Function calctime_detail

- Defined in [icraft_utils.hpp](./icraft_utils.hpp)

`void calctime_detail(icraft::xrt::Session& session)`

- 参数:

  **session** – 需要进行耗时统计的session

- 返回:

  None

- 说明:

对输入session进行详细的耗时统计，输出包括该session前向中包含的各个算子的TotalTime、MemcpyTime、HardTime、OtherTime。另外该函数会自动合并并输出session中所有hardop的TotalTime之和、HardTime之和以及每一个customop的TotalTime和HardTime。完整耗时统计信息会被存放在log文件夹中，部分汇总信息会直接在命令窗口输出。额外增加输出网络耗时的统计分析结果，输出在了命令行窗口并写入log文件夹的txt中。示例如下：

```shell
Total_TotalTime: 259.51346 ms, Total_MemcpyTime : 4.8511996 ms, Total_HardTime : 23.2614 ms, Total_OtherTime : 231.40085 ms .
Hardop_TotalTime: 21.121988 ms, Hardop_HardTime : 20.161438 ms.
Customop: GridSample,TotalTime: 2.79673 ms, HardTime : 2.42822 ms.
******************************************************
统计分析结果如下(The analysis results are as follows):
数据传入耗时(Data input time consumption):
Time(ms):3.142     Device:cdma
icore[npu]耗时(Icore [npu] time-consuming):
Time(ms):23.9187     Device:GridSample
数据传出耗时(Data output time consumption):
Time(ms):1.7092     Device:cdma
cpu算子耗时(CPU operator time consumption):
Time(ms):230.744     Device:Null
******************************************************
```

注意：输入session必须已经开启了计时功能，另外若输入session进行了算子合并那么耗时信息log文件中op_name为空值，此为正常现象。

### Function getJrPath

Defined in [icraft_utils.hpp](./icraft_utils.hpp)

`std::string getJrPath(const std::string& run_backend, std::string& folderPath, std::string targetFileName)`

- 参数:

  **run_backend** – 是否是仿真(host)或运行至指定后端(buyi/zg330)

  **folderPath** – 指定模型文件所在的文件夹

  **targetFileName** – 指定模型的阶段

- 返回:

  指定文件夹中对应阶段的json文件路径

- 说明:

为了方便通过读入yaml的模型文件夹字段和stage字段找到对应的json文件路径，且保证在linux平台下指定为BY阶段的json.

### Function openDevice

Defined in [icraft_utils.hpp](./icraft_utils.hpp)

`Device openDevice(const std::string& run_backend, const std::string& ip, bool mmu_Mode = true, bool cuda_Mode = false, const std::string& npu_addr = "0x40000000", const std::string& dma_addr = "0x80000000")`

- 参数:

  **run_backend** – 是否是仿真(host)或运行至指定后端(buyi/zg330)

  **ip** – 设备的URL中的ip字段

  **mmu_Mode** – mmu模式开启与否

  **cuda_Mode** - 仿真模式下是否开启cudadevice

  **npu_addr** = 设备的URL中的npu_addr 字段

  **dma_addr** = 设备的URL中的dma_addr 字段

- 返回:

  打开的设备对象

- 说明:

通过指定是否运行仿真模式和选定的ip可以打开对应的HostDevice或者BuyiDevice，且根据mmu_Mode字段打开或者关闭设备的mmu模式。

### Function loadNetwork

Defined in [icraft_utils.hpp](./icraft_utils.hpp)

`Network loadNetwork(const std::string& JSON_PATH, const std::string& RAW_PATH)`

- 参数:

  **JSON_PATH** – Json文件路径

  **RAW_PATH** – 指定raw的文件路径


- 返回:

  创建得到的网络对象

- 说明:

通过json和raw文件初始化network

### Function initSession

Defined in [icraft_utils.hpp](./icraft_utils.hpp)

`Session initSession(const std::string& run_backend,  const icraft::xrt::NetworkView& network, icraft::xrt::Device& device, int ocm_option = 4, bool mmuMode = true,bool open_speedmode = true, bool open_compressFtmp = true)`

- 参数:

  **run_backend** – 是否是仿真(host)或运行至指定后端(buyi/zg330)

  **network** – 网络对象

  **device** – 设备对象

  **ocm_option** – ocm分配方案，支持配置0、1、2、3、4；0表示关闭ocm优化；1表示选择方案1，2表示选择方案2，3表示选择方案3，4表示遍历方案1和2选得分较高的方案

  **mmuMode** –  是否打开mmu，true为打开

  **open_speedmode** –  是否打开speedmode，true为打开

  **open_compressFtmp** –  是否打开compressFtmp，true为打开

- 返回:

  制定文件夹中对应阶段的json文件路径

- 说明:

通过指定是否运行仿真模式、network、device、在不同的后端上初始化session会话，而且通过指定mmu、open_compressFtmp、open_speedmode 选择是否开启对应优化功能。

注：若传入mmu为true 则该函数不会进行压缩ftmp和合并硬算子优化。

### Function CvMat2Tensor

Defined in [icraft_utils.hpp](./icraft_utils.hpp)

`Tensor CvMat2Tensor(cv::Mat& img, const Network& network)`

- 参数:

  **img** – mat对象

  **network** – 网络对象

- 返回:

  tensor对象

- 说明:

Tensor构造函数，输入是已经经过所需前处理的mat，network参数则是用于获取网络对应位置输入数据的value的tensortype，通过tensortype中的数据存储类型将输入mat转换为对应的数据类型，且根据value完成输入tensor的形状、layout、数据类型的定义，最后将已经转换类型的mat数据copy给输入tensor，完成tensor的构造。 

### Function data2Tensor

Defined in [icraft_utils.hpp](./icraft_utils.hpp)

`Tensor Data2Tensor(const T* input_data, const xir::Value& input_value)`

- 参数:

  **input_data** – 指向类型T的指针

  **Value** – Value对象


- 返回:

  tensor对象

- 说明:

Tensor构造函数，根据输入数据的value的tensortype，通过tensortype中的数据存储类型将输入数据的类型转换为对应的数据类型，且根据value完成输入tensor的形状、layout、数据类型的定义，最后将已经转换类型的数据copy给输入tensor，完成tensor的构造。 相对于[CvMat2Tensor](#Function CvMat2Tensor),该函数更加普适。

### Function getOutputNormratio

Defined in [icraft_utils.hpp](./icraft_utils.hpp)

`std::vector<float> getOutputNormratio(icraft::xir::NetworkView network)`

- 参数:

  **network** – 网络对象（可以是network也可以是networkview）

- 返回:

  对应传入网络的输出数据的Normratio

- 说明:

注意输入网络要为实际需要的结构，保证拿到正确位置的Normratio

### Function getInputNormratio

Defined in [icraft_utils.hpp](./icraft_utils.hpp)

`std::vector<float> getInputNormratio(icraft::xir::NetworkView network)`

- 参数:

  **network** – 网络对象（可以是network也可以是networkview）

- 返回:

  对应传入网络的输入数据的Normratio

- 说明:

注意输入网络要为实际需要的结构，保证拿到正确位置的Normratio

### Function removeOutputCast

Defined in [icraft_utils.hpp](./icraft_utils.hpp)

```
void removeOutputCast(icraft::xir::Network& network, bool mmu, Array<int> idx_list = {})
```

- 参数:

  **network** – 输入网络结构

  **mmu** – bool值，表示是否开启了MMU，如果开启MMU则传入true，未开启MMU传入false;

  **idx_list** – 指定需要删除指定pattern（cast&Pruneaxis）的输出分支的索引值数组；默认为空，将删除所有输出分支的指定pattern（cast&Pruneaxis）；也可配置idx_list={0} 表示删除第1个输出分支的指定pattern（cast&Pruneaxis），分支索引值从0开始计数。

- 返回:

  删除指定输出分支上的指定pattern（cast&Pruneaxis）的算子，并按照原来output算子的ifm顺序重连了hardop<->output后的网络结构。

- 说明:

  removeOutputCast()是用于删除指定输出分支上的指定pattern（cast&Pruneaxis）的一个函数，不仅能在特定分支上找出并删除pattern（cast&Pruneaxis），还能按照原来output算子的ifm顺序重新连接hardop<->output，返回一个新的Network。该网络前向后会按照框架下output顺序输出tensor

- 注意：

  如需使用该函数用于多个sessions的链接，必须关闭MMU，并将链接的输入输出端所有的cpu算子全部删除，即使用removeOutputCast(network1,false)&removeInputCast(network2,false)

### Function removeInputCast

Defined in [icraft_utils.hpp](./icraft_utils.hpp)

```
void removeInputCast(icraft::xir::Network& network, bool mmu, Array<int> idx_list = {})
```

- 参数:

  **network** – 输入网络结构

  **mmu** – bool值，表示是否开启了MMU，如果开启MMU则传入true，未开启MMU传入false;

  **idx_list** – 指定需要删除指定pattern（Alignaxis&cast）的输入分支的索引值数组；默认为空，将删除所有输入分支的指定pattern（Alignaxis&cast）；也可配置idx_list={0} 表示删除第1个输入分支的指定pattern（Alignaxis&cast），分支索引值从0开始计数。

- 返回:

  删除指定输入分支上的指定pattern（Alignaxis&cast）的算子，并按照原来input算子的ofm顺序重连了input<->hardop后的网络结构。

- 说明:

  removeInputCast()是用于删除指定输入分支上的cpu算子（Alignaxis&cast）的一个函数，不仅能在特定分支上找出并删除pattern（Alignaxis&cast），还能按照原来input算子的ofm顺序重新连接input<->hardop，返回一个新的Network

- 注意：

  如需使用该函数用于多个sessions的链接，必须关闭MMU，并将链接的输入输出端所有的cpu算子全部删除，即使用removeOutputCast(network1,false)&removeInputCast(network2,false)

### Function dumpOutputFtmp

Defined in [icraft_utils.hpp](./icraft_utils.hpp)

```
void dumpOutputFtmp(icraft::xir::NetworkView network, std::vector<Tensor>& output_tensors,std::string dump_format, std::string log_path)
```

- 参数:

  **network** – 输入网络的networkview结构

  **output_tensors** – 网络session.forward的结果

  **dump_format** – 指定dump特征图使用的格式；支持SFB/SFT/SQB/SQT/HQB/HQT等

  **log_path** – 指定的特征图存放路径

- 返回:

  将网络output_ftmp按输出顺序、指定的格式存放至指定路径

- 注意：

  如推理多张图片，则最终只会保存最后一次输入图片对应的输出结果

## netinfo.hpp

### Class Netinfo

用network去初始化该类，可以获得对应网络的输入输出维度信息，fpga算子使用个情况，网络输出的量化scale信息等。

## picpre.hpp

### Class PicPre

用图片路径或者cv::mat去初始化该类，通过PicPre类可以借助opencv完成多种方式的图片resieze、pad、crop，且可以返回变换前后图片的ratio和pad信息。

## modelzoo_utils.hpp

### Function nms_soft

Defined in [modelzoo_utils.hpp](./modelzoo_utils.hpp)

`std::vector<std::tuple<int, float, cv::Rect2f>> nms_soft(std::vector<int>& id_list, std::vector<float>& socre_list, std::vector<cv::Rect2f>& box_list, float IOU, int max_nms = 3000)`

- 参数:

  **id_list** – 与输入框对应的类别信息

  **score_list** – 与输入框对应的置信度信息

  **box_list** – 输入框信息，要求框的类型为cv::Rect2f

  **iou** – iou阈值

  **max_nms** – 进行非极大抑制前框的数量上限

- 返回:

  经过软件nms筛选之后的框的信息，包括类别、置信度、框的坐标。

- 说明:

  nms_soft是使用c++ stl函数在cpu上完成的非极大抑制功能的函数，在yolo类检测目标框数量较少的情况下，使用nms_soft会快于nms_hard

注意：确保送入该函数的框已在在外部进行了置信度阈值筛选

### Function coordTrans

Defined in [modelzoo_utils.hpp](./modelzoo_utils.hpp)

`std::vector<std::vector<float>> coordTrans(std::vector<std::tuple<int, float, cv::Rect2f>>& nms_res, PicPre& img, bool check_border = true)`

- 参数:

  **nms_res** –  筛选之后的框的信息，包括类别、置信度、框的坐标

  **img** – picpre对象

  **check_border** – 是否对超边界框进行约束

- 返回:

  检测框在原图上的类别、置信度、坐标信息。

- 说明:

  nms_res中包含的框的坐标是针对前处理之后的图片检测出来的，前处理相关的pad ratio信息记录在picpre对象中，根据前处理信息还原框在原图上的坐标。

### Function visualize

Defined in [modelzoo_utils.hpp](./modelzoo_utils.hpp)

`void visualize(std::vector<std::vector<float>>& output_res, const cv::Mat& img, const std::string resRoot, const std::string name, const std::vector<std::string>& names)`

- 参数:

  **output_res** – 检测框在原图上的类别、置信度、坐标信息

  **img** – 原图mat对象

  **resRoot** – 结果存放路径

  **name** – 图片名称

  **names** – 类别映射

- 返回:

  None

- 说明:

  根据检测框在原图上的类别、置信度、坐标信息，将其可视化在原图上，其中类别信息通过类别映射为实际标签，最终存储在resRoot中，存图名称根据图片名称决定存储结果名称

### Function saveRes

Defined in [modelzoo_utils.hpp](./modelzoo_utils.hpp)

`void saveRes(std::vector<std::vector<float>>& output_res, std::string resRoot, std::string name)`

- 参数:

  **output_res** – 检测框在原图上的类别、置信度、坐标信息

  **resRoot** – 结果存放路径

  **name** – 图片名称

- 返回:

  None

- 说明:

  将原图上检测出来框的类别、置信度、坐标信息，以txt的方式存储到resRoot中，目的是为了后续进行精度测试。

## et_device.hpp

### Function fpgaNms

Defined in [et_device.hpp](./et_device.hpp)

`std::vector<int> fpgaNms(icraft::xrt::Device& device,const std::vector<int16_t> & nms_pre_data, std::vector<int> nms_pre_idx,int bbox_num, const float& iou, uint64_t base_addr = 0x100001C00)`

- 参数:

  **Device** – 输入icraft::xrt::Device，对预设的寄存器进行读写需要device

  **nms_pre_data** – 一维数组包含多个框的位置信息和类别信息，按照框的置信度大小从高到低排序的,一个框的信息表示为{x1,y1,x2,y2,class}。

  **nms_pre_idx** – 所有的框按照置信度从高到低排列后,nms_pre_idx 记录了数组中排序后框在原未排序数组中的idx

  **bbox_num** – 框的个数

  **iou** – iou阈值

  **base_addr** – fpgaNms的寄存器基地址，默认配置为当前版本下正确基地址。

- 返回:

  筛选出的框在原未排序数组中的idx

- 说明:

按照函数参数说明配置输入参数即可启动硬件nms模块，另外输入框的信息要预先经过置信度阈值筛选。

### Function fpgaDma

Defined in [et_device.hpp](./et_device.hpp)

`void fpgaDma(Tensor& img_tensor, Device& device, uint64_t imk_write_addr = std::numeric_limits<uint64_t>::max(), uint64_t imk_base_addr = 0x100000400, uint64_t dma_base_addr = 0x1000C0000)`

- 参数:

  **img_tensor** – imagemake的输入tensor

  **device** – 输入icraft::xrt::Device，对预设的寄存器进行读写需要device

  **imk_write_addr**   –  ImageMake写入PLDDR的基地址，默认如果不传入该参数，将在ImageMake forward时配置该地址

  **imk_base_addr**  – ImageMake的寄存器基地址，默认为0x100000400，即input_port = 0对应的寄存器基地址

  **dma_base_addr** – fpgaDma的寄存器基地址，默认配置为当前版本下input_port = 0对应的寄存器基地址。

- 返回:

  None

- 说明:

用于初始化imk和dma模块的寄存器地址，并启动imk数据搬移的一个函数，通过device对预设的寄存器进行读写配置完成启动。

注意：

- 该函数并未进行imagemake 硬算子的初始化，因此要部署不同网络，且输入数据量不同，需要调用initOp接口对imagemake进行初始化，例如[dma_imk_Init](#Function dma_imk_Init)。
- 在多线程psin的情况下，建议提前配置好imk硬件相关imk_write_addr、imk_base_addr的参数，来避免在imk forward时才进行初始化配置，没有留足够的时间，容易导致多线程之间结果错位。

### Function fpgaWarpaffine

Defined in [et_device.hpp](./et_device.hpp)

```
void fpgaWarpaffine(std::vector<std::vector<float>>& M_inversed, Device& device,uint64_t base_addr = 0x100002800)
```

- 参数:

  **M_inversed** –仿射变换中变换矩阵的逆矩阵，尺寸为2x3的浮点数组;

  **device**– 设备对象；

  **base_addr** – fpgaWarpaffine的寄存器基地址，默认配置为当前版本下正确基地址。

- 返回:

  无返回值。

- 说明:

  该函数是用于配置WarpAffine硬算子寄存器参数的一个函数；用户自行计算得到变换矩阵的逆矩阵之后，可在运行时通过该函数配置WarpAffine硬算子寄存器，通过不同的变换矩阵可以在WarpAffine硬算子前向时实现对输入数据不同的仿射变化操作，目前支持平移、放缩、裁剪等，不支持旋转。

- 注意：

  必须先带WarpAffine硬算子完成编译，否则无法使用该函数。

### Function fpgaArgmax2d

Defined in [et_device.hpp](./et_device.hpp)

```
Tensor fpgaArgmax2d(Device& dev, int wsize, int hsize, int valid_csize, int csize,uint64_t arbase,uint64_t last_araddr,uint64_t base_addr = 0x100003000)
```

- 参数:

  **dev** – 输入icraft::xrt::Device

   **wsize** - ftmp的width

  **hsize** - ftmp的height

  **valid_csize** - ftmp的(有效)channel数

  **arbase** - ftmp 在plddr的初始地址

  **last_araddr** - ftmp 在plddr的结束地址

  **img_tensor** – imagemake的输入tensor

  **base_addr** – fpgaArgmax2d的寄存器基地址，默认配置为当前版本下正确基地址。

- 返回:

  经过硬件argmax2d筛选之后的最值。

- 说明:

  fpgaArgmax2d是用于启动硬件fpga模块argmax2d的一个函数，通过dev对预设的寄存器进行读写配置完成启动。若ftmp尺寸为320x320x22，fpga_argmax2d耗时约0.13ms

  注意：fpga_argmax2d的输出结果在plddr，需要手动搬运至ps端接后续处理



### Function nms_hard

Defined in [et_device.hpp](./et_device.hpp)

`std::vector<std::tuple<int, float, cv::Rect2f>> nms_hard(std::vector<cv::Rect2f>& box_list, std::vector<float>& score_list, std::vector<int>& id_list, const float& iou, icraft::xrt::Device& device, int max_nms = 3000)`

- 参数:

  **box_list** – 输入框信息，要求框的类型为cv::Rect2f

  **score_list** – 与输入框对应的置信度信息

  **id_list** – 与输入框对应的类别信息

  **iou** – iou阈值

  **device** – 输入icraft::xrt::Device

  **max_nms** – 进行非极大抑制前框的数量上限

- 返回:

  经过硬件nms筛选之后的框的信息，包括类别、置信度、框的坐标。

- 说明:

  nms_hard是用于启动硬件fpga模块nms的一个函数，通过device对预设的寄存器进行读写配置完成启动。

   \*   若最终输出检测数量为500个，nms_hard耗时约0.638ms

   \*   若最终输出检测数量为100个，nms_hard耗时约0.297ms

   \*   当最终检测数量小于30个的情况下，采用nms_soft会比nms_hard速度快。

注意：确保送入该函数的框已在在外部进行了置信度阈值筛选，该函数适配大部分yolo系列模型后处理的hard nms函数，其调用了FPGA_NMS模块

### Function dmaInit

Defined in [et_device.hpp](./et_device.hpp)

`void dmaInit(const std::string& runBackend, const bool& has_ImageMake, Tensor& img_tensor, Device& device)`

- 参数:

  **runBackend** – 是否是仿真(host)或运行至指定后端(buyi/zg330)

  **has_ImageMake** – 网络中是否有imagemake 硬算子

  **img_tensor** – imagemake的输入tensor

  **device** – 输入icraft::xrt::Device，对预设的寄存器进行读写需要device

- 返回:

  None

- 说明:

通过是否是仿真运行时网络中是否有imagemake 硬算子判断是否需要调用setFpgaDma进行配置imk模块并启动imk数据搬移。

### Function dma_imk_Init

Defined in [et_device.hpp](./et_device.hpp)

`void dma_imk_Init(const std::string& run_backend, const bool& has_ImageMake, Operation& ImageMake_ ,Tensor& img_tensor, Device& device,Session &session)`

- 参数:

  **run_backend** – 是否是仿真(host)或运行至指定后端(buyi/zg330)

  **has_ImageMake** – 网络中是否有imagemake 硬算子

  **ImageMake_** – 对应网络中的imagemake 硬算子

  **img_tensor** – imagemake的输入tensor

  **device** – 输入icraft::xrt::Device，对预设的寄存器进行读写需要device

  **session** – 网络对应session

- 返回:

  None

- 说明:

上述[dmaInit](#Function dmaInit)函数中是不去初始化imk算子的，如果要部署不同网络，且输入数据量不同，则要重新初始化imk；如果在前向工程中部署的是相同的网络，那么则不需要初始化，但是即便初始化了也无妨。若必须要初始化可调用dma_imk_Init函数。

### Function updateDetpost

Defined in [et_device.hpp](./et_device.hpp)

`void updateDetpost(NetInfo& netinfo, float conf)`

- 参数:

  **netinfo** – 输入根据network构建的NetInfo

  **conf** – 对应cfg/yaml中的框筛选阈值conf

- 返回:

  空

- 说明:

此函数作用为 如果配置文件cfg/yaml中conf值与compile/custom_op中DetPost算子预设的conf值不一致，则更新Detpost的筛选阈值为cfg/yaml中的筛选阈值。

- 注意事项：
  需要位于创建Netinfo后，initSession前。
### Function hardResizePL

Defined in [et_device.hpp](./et_device.hpp)

`void hardResizePL(BuyiDevice device, int x0, int y0, int x1, int y1, int RATIO_W, int RATIO_H, int CAMERA_WIDTH, int CAMERA_HEIGHT,uint64_t base_addr = 0x40080000)`

- 参数:

  **device** – 输入icraft::xrt::Device，对预设的寄存器进行读写需要device

  **x0** – 起始x0 坐标位置 （0~FRAME_W）

  **y0** – 起始y0 坐标位置 （0~FRAME_H）

  **x1** – 终止x1 坐标位置 （0~FRAME_W）

  **y1** – 终止y1 坐标位置 （0~FRAME_H）

  **RATIO_W** – x方向行步长

  **RATIO_H** – y方向列步长

  **CAMERA_WIDTH** – 图像X方向总长度 （FRAME_W）

  **CAMERA_HEIGHT** –  图像y方向总长度 （FRAME_H）

  **base_addr ** – 配置寄存器的默认基地址

- 返回:

  None

- 说明:

hardResizePL是位于plin数据流上面的一个fpga模块，可以完成plin端输入图片（常用从摄像头取帧）的裁剪下采样前处理，hardResizePL函数即是配置hardResizePL模块如何对输入图片进行处理的一个函数。

注意：hardResizePL是plin数据流上的一个必要环节，plin模型下必须进行初始化，另外目前hardResizePL只支持裁剪图片和整数倍下采样。

### Function preprocess_plin

Defined in [et_device.hpp](./et_device.hpp)

`std::tuple<int, int, int, int > preprocess_plin(BuyiDevice device,const int CAMERA_WIDTH,const int CAMERA_HEIGHT,const int NET_W, const int NET_H,crop_position crop,uint64_t base_addr = 0x40080000)`

- 参数:

  **device** – 输入icraft::xrt::Device，对预设的寄存器进行读写需要device

  **CAMERA_WIDTH** – 原始输入（摄像头）图像X方向总长度 

  **CAMERA_HEIGHT** –  原始输入（摄像头）图像y方向总长度 

  **NET_W** – 实际输入网络图像的X方向总长度

  **NET_H** –  实际输入网络图像的X方向总长度

  **crop** – 图片裁剪方式

  **base_addr** – 配置寄存器的默认基地址

- 返回:

  根据指定的图片裁剪方式和原图尺寸及目标图尺寸裁剪后得到的新的图片相对于原图的偏移和采样步长，常用于在原图上进行可视化。

- 说明:

通过输入原始输入（摄像头）图像和实际输入网络图像的尺寸，确定图片裁剪方式，该函数会自动计算hardResizePL所需要的参数并进行寄存器配置和模块启动。

### Function PLDDRMemRegion::Plddr_memcpy

Defined in [et_device.hpp](./et_device.hpp)

`void Plddr_memcpy(uint64_t read_bottom, uint64_t read_top, uint64_t write_bottom, uint64_t write_top, icraft::xrt::Device& device)`

- 参数:

  **read_bottom** –PLDDR上src的起始地址;

  **read_top** –PLDDR上src的结束地址;

  **write_bottom**–PLDDR上dest的起始地址;

  **write_top** –PLDDR上dest的结束地址;

  **device**– 设备对象；

- 返回:

  无返回值。

- 说明:

  PLDDRMemRegion::Plddr_memcpy()是将PLDDR上src的数据拷贝给PLDDR上dst的一个函数；需用户给定src存储在PLDDR上的起始&结束地址，以及需要将src拷贝到dest在PLDDR上的起始&结束地址。

- 注意：

  src和dest地址长度需一致，且必须是64整数倍

### Class Camera

摄像头类，plin数据流下，一般模型的输入都是从摄像头传入，需要用到该类

- 初始化方法：`Camera(BuyiDevice device, uint64_t buffer_size, uint64_t base_addr = 0x40080000)`

  **device** – 设备对象

  **buffer_size** – 摄像头传入数据大小 （若为1K分辨率的RGB565输入，则为1920x1080x2 ）

- 成员函数:

  - `void take(const MemChunk& memchunk)`

    抓取一帧，传到psddr-udmabuf空间上camera_buf处,同时启动imk，将PL_resize处理后图像送入PLDDR中,用于前向推理

  - `bool wait(int wait_time_ms = 100)`

    等待cam的1帧数据写入ps ddr（udmabuf）

  - `void get(int8_t* frame, const MemChunk& memchunk)`

    将psddr-udmabuf空间camera_buf上数据搬到PSDDR

### Class Display_pHDMI_RGB565

Hdmi显示抽象类，plin数据流下，显示需要用到该类

- 初始化方法：`Display_pHDMI_RGB565(BuyiDevice device, uint64_t buffer_size, MemChunk chunck)`

  **device** – 设备对象

  **buffer_size** – 显示数据量大小 （若输出1K分辨率的RGB565，则为1920x1080x2 ）

- 成员函数:

  - `void show(int8_t* frame)`

    将处理后的图片数据显示

## task_queue.hpp

### struct InputMessageForIcore

- 结构体变量:

  **buffer_index** – 缓存区id

  **image_tensor** – Tensor对象

  **error_frame** – 该帧是否为错帧，默认为false

- 说明:

  该结构体常在多线程任务队列的plin工程中用于初始化icore的输入信息任务队列，例如：`auto icore_task_queue = std::make_shared<Queue<InputMessageForIcore>>(thread_num);`

  buffer_index用于在InputMessageForIcore和IcoreMessageForPost传递 缓存区id信息，来表明改结构体变量中的tensor对象是来自哪一个`camera_buf_group`

  error_frame：若在前向推理中出错，那么该变量将被置为true，后续信息传递到IcoreMessageForPost中，则跳过针对该IcoreMessage的后处理操作。

### struct IcoreMessageForPost

- 结构体变量:

  **buffer_index** – 缓存区id

  **image_tensor** – Tensor对象

  **error_frame** – 该帧是否为错帧，默认为false

- 说明:

  该结构体常在多线程任务队列的plin工程中用于初始化icore的输出信息任务队列，例如：`auto post_task_queue = std::make_shared<Queue<IcoreMessageForPost>>(thread_num);`

  buffer_index用于在InputMessageForIcore和IcoreMessageForPost传递 缓存区id信息，后处理线程会通过`camera.get(display_data, camera_buf_group[post_msg.buffer_index]);`将对应的输入数据从psddr-udmabuf空间上camera_buf处拿到psddr上的display_data中用于后处理

  error_frame：若在前向推理中出错，那么该变量将被置为true，并且传递到IcoreMessageForPost中，跳过针对该IcoreMessage的后处理操作。
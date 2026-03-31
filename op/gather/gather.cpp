#include "gather.h"

    #include <icraft-xir/core/functor.h>
    #include <icraft-xrt/dev/host_device.h>
    #include <icraft-backends/hostbackend/backend.h>


    namespace GatherOP {

            using namespace icraft::xrt;
            // HostBackend中定义了各个算子在CPU/GPU上前向的过程
            // 下面向HostBackend中注册GroupNorm算子的前向过程
            // 一个算子的前向实现包含init和forward两个接口，分别用于初始化以及前向过程
            ICRAFT_ADD_OP_TO_BACKEND(Gather, HostBackend)
                    // 初始化过程的实现
                    // 该算子不需要初始化什么，因此该函数为空
                    .set_init([](const Gather& op, HostBackend backend) {})
                    // 前向实现，根据Softplus的计算公式实现计算过程
                    .set_forward([](const Gather& op, const std::vector<Tensor>& inputs, const std::vector<Tensor>& outputs, HostBackend backend) -> std::vector<Tensor> {
                    //Step1：获取运算中用到的变量
                    auto axis = op->axis;
                    auto& data = inputs[0];
                    auto& data_dtype = data.dtype();
                    auto& indices = inputs[1];
                    auto& indices_dtype = indices.dtype();                    

                    //Step2：获取维度信息
                    auto data_shape = data_dtype->shape;
                    auto indices_shape = indices_dtype->shape;

                    //Step3:获取并验证axis
                    axis = axis % data_dtype.dimSize();
                    ICRAFT_CHECK(axis <= data_shape.size() && axis >= 0).append("Axis out of bond supported!");
                
                    //step4:获取输出形状
                    Array<int64_t> output_shape;
                    for (int i = 0; i < data_shape.size(); i++) {
                        if (i == axis) {
                            output_shape.push_back(indices_shape[1]);  // axis 维变为 indices 的长度,且为indice的第1维
                        } 
                        else {
                            output_shape.push_back(data_shape[i]);
                        }
                    }
                    TensorType output_dtype = data_dtype.clone();
                    output_dtype.setShape(output_shape);

                    //step5:确定indeces类型
                    int64_t indices_total = 1;
                    for (int64_t i = 0; i < indices_shape.size(); i++) {
                        indices_total *= indices_shape[i];
                    }

                    //step5:创建输入输出数据
                    auto data_data = (float*)data.data().cptr();
                    auto indices_data = (int64_t*)indices.data().cptr();
                    auto output_tensor = Tensor(output_dtype);
                    output_tensor.mallocOn(HostDevice::MemRegion());
                    auto output_data = (float*)output_tensor.data().cptr();
                    
                    //step6:逐元素gather
                    //tensor在内存中顺序排布，需要根据shape查找
                    int64_t pre_shape;
                    int64_t post_shape;
                    pre_shape = 1;
                    post_shape = 1;
                    //根据pre_shape和post_shape，定位data_Tensor中需要取出的数据
                    for (int m = 0; m < axis; m++){
                        pre_shape = pre_shape * data_shape[m];
                    }
                    for (int n = axis+1; n < data_shape.size(); n++){
                        post_shape = post_shape * data_shape[n];
                    }
                    //遍历所有维度
                    for (int64_t pre_idx = 0; pre_idx < pre_shape; pre_idx++) {
                        for (int64_t idx_idx = 0; idx_idx < indices_total; idx_idx++) {
                            int64_t gather_idx = indices_data[idx_idx];
                            ICRAFT_CHECK(gather_idx >= 0 && gather_idx < axis)
                                .append("Gather index {} out of range [0, {})!", 
                                gather_idx, axis);
                            for (int64_t post_idx = 0; post_idx < post_shape; post_idx++) {

            
                                // 计算输入位置
                                int64_t src_idx = pre_idx * (data_shape[axis] * post_shape) 
                                        + gather_idx * post_shape 
                                        + post_idx;
            
                                // 计算输出位置
                                int64_t dst_idx = pre_idx * (indices_shape[1] * post_shape) 
                                        + idx_idx * post_shape 
                                        + post_idx;
            
                                output_data[dst_idx] = data_data[src_idx];
                            }
                        }
                    }
                    ICRAFT_CHECK(false).append("output_shape:{},indices_shape{}",output_shape[0],indices_shape[1]);

                    return { output_tensor };
                            
                    });
    }
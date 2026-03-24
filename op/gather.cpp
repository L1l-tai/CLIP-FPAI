#include "gather.h"

    #include <icraft-xir/core/functor.h>
    #include <icraft-xrt/dev/host_device.h>
    #include <icraft-backends/hostbackend/backend.h>


    namespace GatherOP {
            using namespace icraft::xrt;
            // 计算均值
            float mean(const std::vector<float>& data) {
                    float sum = 0.0;
                    for (const auto& value : data) {
                            sum += value;
                    }
                    return sum / data.size();
            }

            // 计算方差
            float variance(const std::vector<float>& data, float mean) {
                    float sum_squared_diff = 0.0;
                    for (const auto& value : data) {
                            float diff = value - mean;
                            sum_squared_diff += diff * diff;
                    }
                    return sum_squared_diff / data.size();
            }


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
                    ICRAFT_CHECK(axis < data_dtype.dimSize()).append("Only fp32 is supported!");

                    auto data_data = (float*)data.data().cptr();
                    auto indices_data = (int*)indices.data().cptr();
                    auto output_tensor = Tensor(indices_dtype).mallocOn(HostDevice::MemRegion());
                    auto output_data = (float*)output_tensor.data().cptr();
                    //output_data = indices_data;

                    return { output_tensor };
                            
                    });
    }
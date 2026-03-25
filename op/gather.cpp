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

                    //Step3:获取并验证axis,支持[0,2],不支持负数
                    //axis = axis % data_dtype.dimSize();
                    ICRAFT_CHECK(axis <= 2 && axis >= 0).append("Only axis in [0,2] is supported!");
                
                    //step4:获取输出形状
                    Array<int64_t> output_shape;
                    for (int i = 0; i < data_shape.size(); i++) {
                        if (i == axis) {
                             output_shape.push_back(indices_shape[0]);  // axis 维变为 indices 的长度
                        } else {
                             output_shape.push_back(data_shape[i]);
                        }
                    }
                    TensorType output_dtype = data_dtype.clone();
                    output_dtype.setShape(output_shape);

                    //step5:创建输入输出数据
                    auto data_data = (float*)data.data().cptr();
                    auto indices_data = (int64_t*)indices.data().cptr();
                    auto output_tensor = Tensor(output_dtype).mallocOn(HostDevice::MemRegion());
                    auto output_data = (float*)output_tensor.data().cptr();
                    
                    //step6:逐元素gather
                    //tensor在内存中顺序排布，需要根据shape查找
                    int64_t pre_shape;
                    int64_t post_shape;
                    int64_t indice; 
                    for (int64_t i = 0; i < indices_shape[0]; i++){
                        indice = indices_data[i];
                        pre_shape = 1;
                        post_shape = 1;
                        //根据pre_shape和post_shape，定位data_Tensor中需要取出的数据
                        for (int m = 0; m < axis; m++){
                            pre_shape = pre_shape * data_shape[m];
                        }
                        for (int n = axis+1; n < data_shape.size(); n++){
                            post_shape = post_shape * data_shape[n];
                        }
                        for (int64_t j = 0; j < post_shape; j++){
                            output_data[i * post_shape + j * pre_shape] = data_data[indice * post_shape + j * pre_shape];
                        }
                                                
                    }

                    return { output_tensor };
                            
                    });
    }
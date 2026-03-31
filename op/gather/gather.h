#include <icraft-xir/core/operation.h>
#include <icraft-utils/logging.h>
#include <icraft-xrt/core/tensor.h>
#include <icraft-xrt/dev/host_device.h>
#include <icraft-backends/hostbackend/decode_custom.h>
#include <icraft-xir/core/functor.h>
#include <icraft-xrt/dev/host_device.h>
#include <icraft-backends/hostbackend/backend.h>

namespace GatherOP {
    using namespace icraft::xir;
    class GatherNode : public OpNodeBase<GatherNode> {
    public:
            int64_t axis;

            ICRAFT_DECLARE_ATTRS(GatherNode) {
                ICRAFT_ATTR_FIELD(axis);
            }
    };

    class Gather : public OpBase<Gather, GatherNode> {
    public:
            Gather() = default;

            // 构造函数也可以不提供
            Gather(Value indices, Value data, int64_t axis = 0) {
                    auto node = make_object<GatherNode>();
                    node->axis = axis; 
                    data_ = std::move(node);
                    this->setInputs({ indices, data });
            }
    };

    // 调用算子注册宏将算子注册到XIR
    // 注册时可以使用set_tinfer为该算子添加类型推断函数
    // 类型推断函数主要描述给定输入的类型，如何确定输出的类型
    // 对于该算子，输出的类型和输入相同
    ICRAFT_REGISTER_OP_NODE(GatherNode)
            .set_tinfer<GatherNode, HostTarget>([](const auto* op) {
            op->validate();

            auto data_dtype = op->inputs[1].tensorType();
            auto indices_dtype = op->inputs[0].tensorType();
            auto data_shape = data_dtype->shape;
            auto indices_shape = indices_dtype->shape;
            
            int64_t axis = 0;
            //auto attr_val = op->getAttr("axis");
            //axis = attr_val;  // 解引用指针
                
            Array<int64_t> output_shape;
            for (int i = 0; i < data_shape.size(); i++) {
                if (i == axis) {
                     output_shape.push_back(indices_shape[1]);  // axis 维变为 indices 的长度,且为indice的第1维
                } 
                else {
                     output_shape.push_back(data_shape[i]);
                }
            }

            auto output_dtype = data_dtype.clone();
            output_dtype.setShape(output_shape);
            return Array<TensorType>{ output_dtype };
        });
}
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
            Gather(Value data, Value indices, int axis = 0) {
                    auto node = make_object<GatherNode>();
                    node->axis = axis; 
                    data_ = std::move(node);
                    this->setInputs({ data, indices });
            }
    };

    // 调用算子注册宏将算子注册到XIR
    // 注册时可以使用set_tinfer为该算子添加类型推断函数
    // 类型推断函数主要描述给定输入的类型，如何确定输出的类型
    // 对于该算子，输出的类型和输入相同
    ICRAFT_REGISTER_OP_NODE(GatherNode)
            .set_tinfer<GatherNode, HostTarget>([](const auto* op) {
            op->validate();
            return Array<TensorType>{ op->inputs[0].tensorType().clone() };
                    });
}
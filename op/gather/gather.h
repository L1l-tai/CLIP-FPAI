#pragma once

#include <icraft-xir/core/operation.h>
#include <icraft-utils/logging.h>
#include <icraft-xrt/core/tensor.h>
#include <icraft-xrt/dev/host_device.h>
#include <icraft-backends/hostbackend/decode_custom.h>
#include <icraft-xir/core/functor.h>
#include <icraft-backends/hostbackend/backend.h>

namespace GatherOP {

using namespace icraft::xir;

class GatherNode : public OpNodeBase<GatherNode> {
public:
    int64_t axis = 0;

    ICRAFT_DECLARE_ATTRS(GatherNode) {
        ICRAFT_ATTR_FIELD(axis);
    }
};

class Gather : public OpBase<Gather, GatherNode> {
public:
    Gather() = default;

    // 当前约定：
    // inputs[0] = indices (Value)
    // inputs[1] = data    (Params)
    Gather(Value indices, Value data, int64_t axis = 0) {
        auto node = make_object<GatherNode>();
        node->axis = axis;
        data_ = std::move(node);
        this->setInputs({indices, data});
    }
};

ICRAFT_REGISTER_OP_NODE(GatherNode)
    .set_tinfer<GatherNode, HostTarget>([](const auto* op) {
        op->validate();

        // 当前输入顺序：
        // input[0] = indices
        // input[1] = data
        auto indices_dtype = op->inputs[0].tensorType();
        auto data_dtype = op->inputs[1].tensorType();

        auto indices_shape = indices_dtype->shape;
        auto data_shape = data_dtype->shape;

        ICRAFT_CHECK(data_shape.size() > 0)
            .append("Gather data rank must be > 0.");

        ICRAFT_CHECK(indices_shape.size() == 2)
            .append("Current Gather tinfer only supports 2D indices, but got rank {}.",
                    indices_shape.size());

        int64_t axis = op->axis;
        int64_t data_rank = static_cast<int64_t>(data_shape.size());

        if (axis < 0) {
            axis += data_rank;
        }

        ICRAFT_CHECK(axis >= 0 && axis < data_rank)
            .append("Gather axis {} out of range for rank {}.", axis, data_rank);

        Array<int64_t> output_shape;
        for (int64_t i = 0; i < data_rank; i++) {
            if (i == axis) {
                // 当前仅支持 indices 为 [1, N]
                output_shape.push_back(indices_shape[1]);
            } else {
                output_shape.push_back(data_shape[i]);
            }
        }

        auto output_dtype = data_dtype.clone();
        output_dtype.setShape(output_shape);

        return Array<TensorType>{output_dtype};
    });

} // namespace GatherOP
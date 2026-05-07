#pragma once

#include <icraft-xir/core/operation.h>
#include <icraft-utils/logging.h>
#include <icraft-xrt/core/tensor.h>
#include <icraft-xrt/dev/host_device.h>
#include <icraft-backends/hostbackend/backend.h>

namespace CustomMatMulOP {

using namespace icraft::xir;

class CustomMatMulNode : public OpNodeBase<CustomMatMulNode> {
public:
    bool trans_a = false;
    bool trans_b = false;

    ICRAFT_DECLARE_ATTRS(CustomMatMulNode) {
        ICRAFT_ATTR_FIELD(trans_a);
        ICRAFT_ATTR_FIELD(trans_b);
    }
};

class CustomMatMul : public OpBase<CustomMatMul, CustomMatMulNode> {
public:
    CustomMatMul() = default;

    CustomMatMul(Value a, Value b, bool trans_a = false, bool trans_b = false) {
        auto node = make_object<CustomMatMulNode>();
        node->trans_a = trans_a;
        node->trans_b = trans_b;
        data_ = std::move(node);
        this->setInputs({a, b});
    }
};

ICRAFT_REGISTER_OP_NODE(CustomMatMulNode)
    .set_tinfer<CustomMatMulNode, HostTarget>([](const auto* op) {
        op->validate();

        auto a_dtype = op->inputs[0].tensorType();
        auto b_dtype = op->inputs[1].tensorType();

        auto a_shape = a_dtype->shape;
        auto b_shape = b_dtype->shape;

        ICRAFT_CHECK(a_shape.size() == 2)
            .append("CustomMatMul only supports 2D lhs now.");
        ICRAFT_CHECK(b_shape.size() == 2)
            .append("CustomMatMul only supports 2D rhs now.");

        int64_t M = op->trans_a ? a_shape[1] : a_shape[0];
        int64_t K1 = op->trans_a ? a_shape[0] : a_shape[1];
        int64_t K2 = op->trans_b ? b_shape[1] : b_shape[0];
        int64_t N = op->trans_b ? b_shape[0] : b_shape[1];

        ICRAFT_CHECK(K1 == K2)
            .append("CustomMatMul K mismatch: {} vs {}.", K1, K2);

        Array<int64_t> output_shape{M, N};

        auto output_dtype = a_dtype.clone();
        output_dtype.setShape(output_shape);

        return Array<TensorType>{output_dtype};
    });

} // namespace CustomMatMulOP
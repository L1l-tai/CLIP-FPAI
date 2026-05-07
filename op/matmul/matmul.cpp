#include "matmul.h"

#include <icraft-xir/core/functor.h>
#include <icraft-xrt/dev/host_device.h>
#include <icraft-backends/hostbackend/backend.h>

#include <vector>
#include <iostream>

namespace CustomMatMulOP {

using namespace icraft::xrt;
using namespace icraft::xir;

ICRAFT_ADD_OP_TO_BACKEND(CustomMatMul, HostBackend)
    .set_init([](const CustomMatMul& op, HostBackend backend) {})
    .set_forward([](const CustomMatMul& op,
                    const std::vector<Tensor>& inputs,
                    const std::vector<Tensor>& outputs,
                    HostBackend backend) -> std::vector<Tensor> {
        ICRAFT_CHECK(inputs.size() >= 2)
            .append("CustomMatMul expects 2 inputs, but got {}.", inputs.size());

        auto& A = inputs[0];
        auto& B = inputs[1];

        auto a_dtype = A.dtype();
        auto b_dtype = B.dtype();

        auto a_shape = a_dtype->shape;
        auto b_shape = b_dtype->shape;

        ICRAFT_CHECK(a_shape.size() == 2)
            .append("CustomMatMul only supports 2D lhs now.");
        ICRAFT_CHECK(b_shape.size() == 2)
            .append("CustomMatMul only supports 2D rhs now.");

        bool trans_a = op->trans_a;
        bool trans_b = op->trans_b;

        int64_t M = trans_a ? a_shape[1] : a_shape[0];
        int64_t K1 = trans_a ? a_shape[0] : a_shape[1];
        int64_t K2 = trans_b ? b_shape[1] : b_shape[0];
        int64_t N = trans_b ? b_shape[0] : b_shape[1];

        ICRAFT_CHECK(K1 == K2)
            .append("CustomMatMul K mismatch: {} vs {}.", K1, K2);

        auto a_data = reinterpret_cast<const float*>(A.data().cptr());
        auto b_data = reinterpret_cast<const float*>(B.data().cptr());

        ICRAFT_CHECK(a_data != nullptr).append("CustomMatMul lhs pointer is null.");
        ICRAFT_CHECK(b_data != nullptr).append("CustomMatMul rhs pointer is null.");

        Array<int64_t> output_shape{M, N};

        TensorType output_dtype = a_dtype.clone();
        output_dtype.setShape(output_shape);

        Tensor output_tensor(output_dtype);
        output_tensor.mallocOn(HostDevice::MemRegion());

        auto c_data = reinterpret_cast<float*>(output_tensor.data().cptr());

        auto getA = [&](int64_t m, int64_t k) -> float {
            if (!trans_a) {
                return a_data[m * a_shape[1] + k];
            } else {
                return a_data[k * a_shape[1] + m];
            }
        };

        auto getB = [&](int64_t k, int64_t n) -> float {
            if (!trans_b) {
                return b_data[k * b_shape[1] + n];
            } else {
                return b_data[n * b_shape[1] + k];
            }
        };

        for (int64_t m = 0; m < M; ++m) {
            for (int64_t n = 0; n < N; ++n) {
                float sum = 0.0f;
                for (int64_t k = 0; k < K1; ++k) {
                    sum += getA(m, k) * getB(k, n);
                }
                c_data[m * N + n] = sum;
            }
        }

        return {output_tensor};
    });

} // namespace CustomMatMulOP
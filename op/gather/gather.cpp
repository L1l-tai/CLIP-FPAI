#include "gather.h"

#include <icraft-xir/core/functor.h>
#include <icraft-xrt/dev/host_device.h>
#include <icraft-backends/hostbackend/backend.h>

#include <cstdint>
#include <vector>
#include <iostream>

namespace GatherOP {

using namespace icraft::xrt;
using namespace icraft::xir;

ICRAFT_ADD_OP_TO_BACKEND(Gather, HostBackend)
    .set_init([](const Gather& op, HostBackend backend) {})
    .set_forward([](const Gather& op,
                    const std::vector<Tensor>& inputs,
                    const std::vector<Tensor>& outputs,
                    HostBackend backend) -> std::vector<Tensor> {
        ICRAFT_CHECK(inputs.size() >= 1)
            .append("Gather expects at least 1 runtime input, but got {}.", inputs.size());

        int64_t axis = op->axis;

        // ============================================================
        // 模式 1: Embedding Gather
        // 图结构:
        //   inputs[0] = runtime indices, shape [1,77], dtype fp32
        //   op->inputs[1] = Params data, shape [49408,512], dtype fp32
        //   output = [77,512]
        // ============================================================
        if (inputs.size() == 1) {
            auto& indices = inputs[0];
            auto indices_dtype = indices.dtype();
            auto indices_shape = indices_dtype->shape;

            ICRAFT_CHECK(indices_shape.size() == 2)
                .append("Embedding Gather expects 2D indices, but got rank {}.",
                        indices_shape.size());

            auto data_param = op->inputs[1].cast<Params>();
            auto data_dtype = data_param.tensorType();
            auto data_shape = data_dtype->shape;

            auto data_ptr = data_param.data<float>();
            auto data_data = data_ptr.get();

            ICRAFT_CHECK(data_data != nullptr)
                .append("Embedding Gather params data pointer is null.");

            int64_t data_rank = static_cast<int64_t>(data_shape.size());
            if (axis < 0) axis += data_rank;

            ICRAFT_CHECK(axis >= 0 && axis < data_rank)
                .append("Gather axis {} out of range for rank {}.", axis, data_rank);

            Array<int64_t> output_shape;
            for (int64_t i = 0; i < data_rank; i++) {
                if (i == axis) {
                    output_shape.push_back(indices_shape[1]);
                } else {
                    output_shape.push_back(data_shape[i]);
                }
            }

            TensorType output_dtype = data_dtype.clone();
            output_dtype.setShape(output_shape);

            int64_t indices_total = 1;
            for (int64_t i = 0; i < static_cast<int64_t>(indices_shape.size()); i++) {
                indices_total *= indices_shape[i];
            }

            auto indices_data = reinterpret_cast<const float*>(indices.data().cptr());
            ICRAFT_CHECK(indices_data != nullptr)
                .append("Embedding Gather indices pointer is null.");

            Tensor output_tensor(output_dtype);
            output_tensor.mallocOn(HostDevice::MemRegion());
            auto output_data = reinterpret_cast<float*>(output_tensor.data().cptr());

            int64_t pre_shape = 1;
            int64_t post_shape = 1;

            for (int64_t m = 0; m < axis; m++) pre_shape *= data_shape[m];
            for (int64_t n = axis + 1; n < data_rank; n++) post_shape *= data_shape[n];

            std::cout << "[Gather Host][Embedding] inputs.size() = " << inputs.size() << std::endl;
            std::cout << "[Gather Host][Embedding] data_shape = [";
            for (size_t i = 0; i < data_shape.size(); ++i) {
                std::cout << data_shape[i] << (i + 1 == data_shape.size() ? "" : ", ");
            }
            std::cout << "]" << std::endl;

            std::cout << "[Gather Host][Embedding] indices_shape = [";
            for (size_t i = 0; i < indices_shape.size(); ++i) {
                std::cout << indices_shape[i] << (i + 1 == indices_shape.size() ? "" : ", ");
            }
            std::cout << "]" << std::endl;

            std::cout << "[Gather Host][Embedding] first 10 indices: ";
            for (int i = 0; i < 10 && i < indices_total; ++i) {
                std::cout << static_cast<int64_t>(indices_data[i]) << " ";
            }
            std::cout << std::endl;

            for (int64_t pre_idx = 0; pre_idx < pre_shape; pre_idx++) {
                for (int64_t idx_idx = 0; idx_idx < indices_total; idx_idx++) {
                    int64_t gather_idx = static_cast<int64_t>(indices_data[idx_idx]);

                    ICRAFT_CHECK(gather_idx >= 0 && gather_idx < data_shape[axis])
                        .append("Embedding Gather index {} out of range [0, {}).",
                                gather_idx, data_shape[axis]);

                    for (int64_t post_idx = 0; post_idx < post_shape; post_idx++) {
                        int64_t src_idx =
                            pre_idx * (data_shape[axis] * post_shape) +
                            gather_idx * post_shape +
                            post_idx;

                        int64_t dst_idx =
                            pre_idx * (indices_total * post_shape) +
                            idx_idx * post_shape +
                            post_idx;

                        output_data[dst_idx] = data_data[src_idx];
                    }
                }
            }

            return { output_tensor };
        }

        // ============================================================
        // 模式 2: Token Select Gather
        // 图结构:
        //   inputs[0] = data,    shape [77,512], dtype fp32
        //   inputs[1] = indices, shape [1],      dtype fp32
        //   output = [1,512]
        // ============================================================
        if (inputs.size() >= 2) {
            auto& data = inputs[0];
            auto data_dtype = data.dtype();
            auto data_shape = data_dtype->shape;

            auto& indices = inputs[1];
            auto indices_dtype = indices.dtype();
            auto indices_shape = indices_dtype->shape;

            int64_t data_rank = static_cast<int64_t>(data_shape.size());
            if (axis < 0) axis += data_rank;

            ICRAFT_CHECK(axis >= 0 && axis < data_rank)
                .append("Gather axis {} out of range for rank {}.", axis, data_rank);

            ICRAFT_CHECK(indices_shape.size() == 1)
                .append("Token Select Gather expects 1D scalar-like indices, but got rank {}.",
                        indices_shape.size());

            auto data_data = reinterpret_cast<const float*>(data.data().cptr());
            auto indices_data = reinterpret_cast<const float*>(indices.data().cptr());

            ICRAFT_CHECK(data_data != nullptr)
                .append("Token Select Gather data pointer is null.");
            ICRAFT_CHECK(indices_data != nullptr)
                .append("Token Select Gather indices pointer is null.");

            Array<int64_t> output_shape;
            for (int64_t i = 0; i < data_rank; i++) {
                if (i == axis) {
                    output_shape.push_back(indices_shape[0]);
                } else {
                    output_shape.push_back(data_shape[i]);
                }
            }

            TensorType output_dtype = data_dtype.clone();
            output_dtype.setShape(output_shape);

            int64_t indices_total = 1;
            for (int64_t i = 0; i < static_cast<int64_t>(indices_shape.size()); i++) {
                indices_total *= indices_shape[i];
            }

            Tensor output_tensor(output_dtype);
            output_tensor.mallocOn(HostDevice::MemRegion());
            auto output_data = reinterpret_cast<float*>(output_tensor.data().cptr());

            int64_t pre_shape = 1;
            int64_t post_shape = 1;

            for (int64_t m = 0; m < axis; m++) pre_shape *= data_shape[m];
            for (int64_t n = axis + 1; n < data_rank; n++) post_shape *= data_shape[n];

            std::cout << "[Gather Host][TokenSelect] inputs.size() = " << inputs.size() << std::endl;
            std::cout << "[Gather Host][TokenSelect] data_shape = [";
            for (size_t i = 0; i < data_shape.size(); ++i) {
                std::cout << data_shape[i] << (i + 1 == data_shape.size() ? "" : ", ");
            }
            std::cout << "]" << std::endl;

            std::cout << "[Gather Host][TokenSelect] indices_shape = [";
            for (size_t i = 0; i < indices_shape.size(); ++i) {
                std::cout << indices_shape[i] << (i + 1 == indices_shape.size() ? "" : ", ");
            }
            std::cout << "]" << std::endl;

            std::cout << "[Gather Host][TokenSelect] first 10 indices: ";
            for (int i = 0; i < 10 && i < indices_total; ++i) {
                std::cout << static_cast<int64_t>(indices_data[i]) << " ";
            }
            std::cout << std::endl;

            for (int64_t pre_idx = 0; pre_idx < pre_shape; pre_idx++) {
                for (int64_t idx_idx = 0; idx_idx < indices_total; idx_idx++) {
                    int64_t gather_idx = static_cast<int64_t>(indices_data[idx_idx]);

                    ICRAFT_CHECK(gather_idx >= 0 && gather_idx < data_shape[axis])
                        .append("Token Select Gather index {} out of range [0, {}).",
                                gather_idx, data_shape[axis]);

                    for (int64_t post_idx = 0; post_idx < post_shape; post_idx++) {
                        int64_t src_idx =
                            pre_idx * (data_shape[axis] * post_shape) +
                            gather_idx * post_shape +
                            post_idx;

                        int64_t dst_idx =
                            pre_idx * (indices_total * post_shape) +
                            idx_idx * post_shape +
                            post_idx;

                        output_data[dst_idx] = data_data[src_idx];
                    }
                }
            }

            return { output_tensor };
        }

        ICRAFT_CHECK(false)
            .append("Unsupported Gather runtime input pattern, inputs.size()={}.", inputs.size());

        return {};
    });

} // namespace GatherOP
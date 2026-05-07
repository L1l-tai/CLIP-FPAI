#include <icraft-xir/core/pass.h>
#include <icraft-xir/core/pattern.h>
#include <icraft-xir/core/functor.h>
#include <icraft-xir/core/network.h>
#include <icraft-xir/ops/matmul.h>

#include "matmul.h"

#include <iostream>
#include <Windows.h>

namespace CustomMatMulOP {

using namespace icraft::xir;

static Pass ReplaceMatMulWithCustomMatMul() {
    auto pass_func = [](Network network_, const PassContext& pass_ctx) {
        OutputDebugStringA("[MatMulPlugin] ReplaceMatMulWithCustomMatMul Loaded!\n");

        auto Matmul_p = IsOp<Matmul>(Wildcard(), Wildcard())
            .setConstraint([](auto& op) {
                auto x_shape = op->inputs[0].tensorType()->shape;
                auto k_shape = op->inputs[1].tensorType()->shape;

                // 先只替换 2D Matmul
                if (x_shape.size() != 2 || k_shape.size() != 2) {
                    return false;
                }

                // x[M, K] * k[K, N]
                if (x_shape[1] != k_shape[0]) {
                    return false;
                }

                // 如果暂时不支持 bias，遇到 3 输入就不替换
                if (op->inputs.size() > 2) {
                    return false;
                }

                return true;
            });

        auto results = network_.search(Matmul_p);

        for (auto&& result : results) {
            auto matmul_node = result.at(Matmul_p).cast<Matmul>();

            bool trans_a = false;
            bool trans_b = false;

            auto custom_matmul = CustomMatMul(
                matmul_node->inputs[0],
                matmul_node->inputs[1],
                trans_a,
                trans_b
            );

            auto output_info = network_.getUsesInfo(matmul_node[0]);

            network_.insertOpById(matmul_node->op_id, custom_matmul);
            network_.removeOpById(matmul_node->op_id);
            network_.connect(custom_matmul[0], output_info);

            custom_matmul.setCompileTarget(HostTarget::Init());
        }

        return network_;
    };

    Array<String> required_pass;
    return NetworkPass(
        pass_func,
        PassInfo("ReplaceMatMulWithCustomMatMul", 1, required_pass)
    );
}

ICRAFT_REGISTER_PASS("MatMulOP.ReplaceMatMulWithCustomMatMul")
    .set_creator(ReplaceMatMulWithCustomMatMul);

} // namespace CustomMatMulOP
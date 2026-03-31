#include <icraft-xir/core/pass.h>
#include <icraft-xir/core/pattern.h>
#include <icraft-xir/core/functor.h>
#include <icraft-xir/core/network.h>
#include <icraft-xir/ops/add.h>
#include <icraft-xir/ops/unsupport.h>

#include "../gather/gather.h"
#include <iostream>

namespace  GatherOP
{
        using namespace icraft::xir;

        static Pass ReplaceUnsupportWithGather() {
                auto pass_func = [](Network network_, const PassContext& pass_ctx){
                        // 模式匹配
                        // 匹配Unsupport算子：IsOp<Unsupport>
                        // 匹配两输入的add算子：IsOp<Unsupport>(Wildcard(), Wildcard())
                        // 匹配其他限制条件：.setConstraint([](auto& op)
                        OutputDebugStringA("[GatherPlugin] DLL Loaded Successfully!\n");
                        auto Unsupport_p = IsOp<Unsupport>(Wildcard(), Wildcard()).setConstraint([](auto& op) {
                                    return true;        //改变所有Unsupported算子
                                    });
                        auto results = network_.search(Unsupport_p);
                        for (auto&& result : results) {
                                auto gather_node = result.at(Unsupport_p).cast<Unsupport>();
                                int64_t axis = 0;       //默认axis = 0
                                auto gather = Gather(gather_node->inputs[0], gather_node->inputs[1], axis);
                                auto output_info = network_.getUsesInfo(gather_node[0]);
                                network_.insertOpById(gather_node->op_id, gather);
                                network_.removeOpById(gather_node->op_id);
                                network_.connect(gather[0], output_info);
                                gather.setCompileTarget(HostTarget::Init());
                        }
                        return network_;
                };
                Array<String> required_pass;
                return NetworkPass(pass_func, PassInfo("ReplaceUnsupportWithGather",1,required_pass));
        }

        ICRAFT_REGISTER_PASS("GatherOP.ReplaceUnsupportWithGather").set_creator(ReplaceUnsupportWithGather);

} // namespace  GatherOP


    
    


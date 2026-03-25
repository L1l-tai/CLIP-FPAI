#include <icraft-xir/ops/transpose.h>
#include <icraft-onnx/ox_pattern_factory.h>
#include "../gather/gather.h"

using namespace icraft::parser::ox;
using namespace icraft::xir;

static auto parse = [](
            std::vector<onnx::NodeProto>& pattern_nodes,              //  算子 node 序列
            std::map<std::string, onnx::TensorProto>& tensors,        //  Tensor
            std::map<std::string, xir::Value>& tensor_map,            //  输入输出 Value 映射
            std::map<std::string, onnx::ValueInfoProto>& value_infos, //  ValueInfoProto
            int64_t& node_idx,                                        //  当前节点索引
            int64_t& graph_idx                                        //  当前子图索引
            ) -> std::vector<Operation> {                             //  明确返回类型
     


                std::vector<icraft::xir::Operation> ops;
                 // Gather node 信息
                auto data_name = pattern_nodes[0].input(0);
                auto indices_name = pattern_nodes[0].input(1);
                auto output_name = pattern_nodes[0].output(0);
                auto gather_node = pattern_nodes[0];

                int64_t axis = 0;
                for (auto attr : gather_node.attribute()) {
                        if (attr.name() == "axis") axis = attr.i();
                }

                auto data = tensor_map.at(data_name);
                auto indices = tensor_map.at(indices_name);
                //input的layout分为：NHWC和框架原始排布，GroupNorm要求input的layout为框架排布
                //当input.tensorType()->layout == Layout::NHWC()时，需要添加transpose算子将input的layout调整为框架排布
                
                //if (input.tensorType()->layout == Layout::NHWC()) {
                //        auto transpose_name = output_name + "_transpose";
                //        auto transpose = Transpose(input.clone(), {0,3,1,2}, Layout("***C"));
                //        ops.push_back(transpose);
                //        input = transpose[0];
                //}
                auto gather = GatherOP::Gather(data, indices, axis);
                //auto gamma_data_tmp = group_norm->gamma.value().data<float>();
                //group_norm.inferResults({ input.tensorType().clone() });
                //group_norm[0].setName(output_name);
                ops.push_back(gather);

                return ops;
        };

static auto check = [](std::vector<onnx::NodeProto>& nodes,
           std::map<std::string, onnx::TensorProto>& tensors,
           std::map<std::string, onnx::ValueInfoProto>& value_infos,
           std::vector<std::string>& errors,
           int64_t& node_idx,
           int64_t& graph_idx,
           Target& target) {
            
                const auto& node = nodes[node_idx];
                
                // 快速检查
                if (node.input_size() < 2) {
                        errors.push_back("Gather needs 2+ inputs");
                        return;
                }
                if (node.output_size() != 1) {
                        errors.push_back("Gather needs 1 output");
                        return;
                }
                
                // 检查 axis 属性
                for (const auto& attr : node.attribute()) {
                        if (attr.name() == "axis" && attr.i() < 0) {
                        errors.push_back("Negative axis not supported");
                        return;
                        }
                }
        };

        ICRAFT_ADD_PATTERN_TO_PARSER("Gather",17).set_parse(parse,check);
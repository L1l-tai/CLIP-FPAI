#pragma once

#include <icraft-xir/core/network.h>
#include <vector>
#include <string>
#include "opencv2/opencv.hpp"
#include <unordered_set>
#include <spdlog/spdlog.h>

struct Cubic {
    int h = 0;
    int w = 0;
    int c = 0;
};

class  NetInfo {

public:
    icraft::xir::Network network;
    std::vector<std::vector<int>> i_shape;
    std::vector<std::vector<int>> o_shape;
    std::vector<std::vector<int>> head_hardop_i_shape;
    std::vector<float> o_scale;
    std::unordered_set<std::string> fpga_op;
    std::vector<Cubic> i_cubic;
    std::vector<Cubic> o_cubic;
    std::vector<Cubic> head_hardop_i_shape_cubic;
    int inp_shape_opid = 0;
    int Imk_op_idx = -1;
    int WarpAffine_op_idx = -1;
    int First_cast_op_idx = -1;
    int bit = 8;
    int detpost_bit = 8;
    bool resize_on = false;
    bool swaporder_on = false;
    bool ImageMake_on = false;
    bool DetPost_on = false;
    bool WarpAffine_on = false;
    Operation ImageMake_;
    Operation DetPost_;
    Operation WarpAffine_;
    bool mmu = true;
    float thr_f;
    std::vector<int64_t>  data_thr;
    NetInfo() = default;

    NetInfo(const icraft::xir::Network &network) {
        this->network = network;
        this->fpga_op = fpgaOPlist(this->network);
        if (network.getTag("speedmode").has_value()) {
            auto _speedmode = Downcast<Bool>(network.getTag("speedmode").value())->value;
            auto _compressFtmp = Downcast<Bool>(network.getTag("compressFtmp").value())->value;
            this->mmu = _speedmode || _compressFtmp;
        }
        auto oplist = network->ops;

        for (auto i : oplist[this->inp_shape_opid]->outputs) {
            this->i_shape.push_back(i.tensorType()->shape);
        }
        // 选择距离第一个hardop最近的
        if (this->WarpAffine_on) {
            for (auto i : oplist[this->WarpAffine_op_idx]->outputs) {
                this->head_hardop_i_shape.push_back(i.tensorType()->shape);
            }
        }
        else if(this->ImageMake_on) {
            for (auto i : oplist[this->Imk_op_idx]->outputs) {
                this->head_hardop_i_shape.push_back(i.tensorType()->shape);
            }
        }
        else if(this->First_cast_op_idx != -1) {
            for (auto i : oplist[this->First_cast_op_idx]->outputs) {
                this->head_hardop_i_shape.push_back(i.tensorType()->shape);
            }
        }

        for (auto i : oplist[-1]->inputs) {
            this->o_shape.push_back(i.tensorType()->shape);

        }
        if (this->DetPost_on) {
            this->detpost_bit = this->DetPost_->outputs[0]->dtype.getStorageType().bits();
            // get original thr_f & thr_q(data_thr)
            thr_f = this->DetPost_->getAttr("thr_f").cast<FloatImm>();
            //auto data_thr_bool = this->DetPost_->getAttr("data_thr").has_value();
            data_thr = this->DetPost_->getAttr("data_thr").cast<Array<int64_t>>();
 
            for (auto i : this->DetPost_->inputs) {
                //std::cout << i->dtype.getNormratio().value() << std::endl;
                this->o_scale.emplace_back(i->dtype.getNormratio().value()[0]);

            }
        }

        for (int op_idx = 0; op_idx < oplist.size(); op_idx++) {
            if (oplist[op_idx]->compile_target->typeKey().find("BuyiTargetNode") != std::string::npos || oplist[op_idx]->compile_target->typeKey().find("FPGATargetNode") != std::string::npos) {
                this->bit = oplist[op_idx]->outputs[0]->dtype.getStorageType().bits();
                break;

            }
        }
        Cubic temp_cubic;
        for (auto i : this->i_shape) {
            if (i.size() == 4) {
                temp_cubic.h = i[1];
                temp_cubic.w = i[2];
                temp_cubic.c = i[3];
                this->i_cubic.emplace_back(temp_cubic);
            }
        }
        for (auto i : this->head_hardop_i_shape) {
            if (i.size() == 5) {
                temp_cubic.h = i[2];
                temp_cubic.w = i[3];
                temp_cubic.c = i[4];
                this->head_hardop_i_shape_cubic.emplace_back(temp_cubic);
            }
        }
        for (auto i : this->o_shape) {
            if (i.size() == 4) {
                temp_cubic.h = i[1];
                temp_cubic.w = i[2];
                temp_cubic.c = i[3];
                this->o_cubic.emplace_back(temp_cubic);
            }
        }
        spdlog::info("NetInfo init done");
        //if (this->mmu) {
        //    spdlog::info("The speedmode or compressFtmp of input model is enabled, The device must enable mmu mode.");
        //}
        //else {
        //    spdlog::info("Neither speedmode nor compressFtmp of input model is enabled, You can decide whether to enable the mmu mode of the device by using the configuration item mmu in the yaml file");

        //}
    }

    
    virtual std::unordered_set<std::string> fpgaOPlist(icraft::xir::Network& network) {
        std::unordered_set<std::string> customop_set;
        auto oplist = network->ops;
        int op_idx = 0;
        for (; op_idx < oplist.size();op_idx++) {
            // std::cout << op_idx<< ":" << oplist[op_idx]->typeKey() << std::endl;
            if (oplist[op_idx]->typeKey().find("Resize") != std::string::npos) {
                this->resize_on = true;
            }
            if (oplist[op_idx]->typeKey().find("SwapOrder") != std::string::npos) {
                this->swaporder_on = true;
            }
            if (oplist[op_idx]->typeKey().find("ImageMakeNode") != std::string::npos) {
                this->ImageMake_on = true;
                this->ImageMake_ = oplist[op_idx];
                this->Imk_op_idx = op_idx;

            }
            if (oplist[op_idx]->typeKey().find("DetPostNode") != std::string::npos) {
                this->DetPost_on = true;
                this->DetPost_ = oplist[op_idx];
            }
            if (oplist[op_idx]->typeKey().find("WarpAffineNode") != std::string::npos) {
                this->WarpAffine_on = true;
                this->WarpAffine_ = oplist[op_idx];
                this->WarpAffine_op_idx = op_idx;

            }
            if (oplist[op_idx]->typeKey().find("CastNode") != std::string::npos) {
                if(this->First_cast_op_idx == -1)
                    this->First_cast_op_idx = op_idx;

            }
            if (oplist[op_idx]->typeKey().find("customop") != std::string::npos) {
                customop_set.insert(std::string(oplist[op_idx]->typeKey()));
            }
        }


        if (this->resize_on) this->inp_shape_opid++;
        // if (this->swaporder_on) this->inp_shape_opid++;
        return customop_set;
    }



};

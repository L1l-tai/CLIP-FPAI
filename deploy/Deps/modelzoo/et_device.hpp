
#pragma once
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>

#include <random>
#include <vector>
#include <fstream>
#include <random>
#ifdef __linux__
#include <unistd.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <linux/fb.h>
#endif
#include "opencv2/opencv.hpp"
#include <spdlog/spdlog.h>

#include "icraft-xir/core/network.h"
#include "icraft-xir/core/data.h"
#include <icraft-xrt/core/session.h>
#include <icraft-xrt/dev/host_device.h>
#include <icraft-xrt/dev/buyi_device.h> 
#include <icraft-xrt/dev/zg330_device.h>
#include <icraft-backends/hostbackend/utils.h>
#include <icraft-backends/hostbackend/backend.h>
#include <icraft-backends/buyibackend/buyibackend.h>
#include <icraft-backends/zg330backend/zg330backend.h>


#include "modelzoo_utils.hpp"
using namespace icraft::xrt;
using namespace icraft::xrt::zg330;
using namespace icraft::xir;
using namespace std::string_literals;
using namespace std::chrono;
using namespace std::chrono_literals;
// 枚举类
// 表示摄像头输入的图像格式
enum camera_fmt {
    RGB565,
    RGB,
    RGBA,
    YUV422,
};

// 枚举类
// 表示plresize模块的剪裁区域
enum crop_position {
    top_left,
    top_right,
    bottom_left,
    bottom_right,
    center,
};


// nms_pre_data 一维数组包含多个框的位置信息和类别信息，按照框的置信度大小从高到低排序的,一个框的信息表示为{x1,y1,x2,y2,class}。
// nms_pre_idx 所有的框按照置信度从高到低排列后,nms_pre_idx 记录了数组中排序后框在原未排序数组中的idx
// bbox_num 为框的个数
// iou阈值
// 该模块限制最多输入框个数为5000个
std::vector<int> fpgaNms(icraft::xrt::Device& device,const std::vector<int16_t> & nms_pre_data, std::vector<int> nms_pre_idx,int bbox_num, const float& iou, uint64_t base_addr = 0x100001C00){
    if (nms_pre_data.size() != bbox_num * 5 || nms_pre_idx.size() != bbox_num) {
        std::cout << "ERROR in FpgaNms :: The data for FpgaNms is error, Please check it!" <<std::endl;
        throw std::runtime_error("ERROR in FpgaNms :: The data for FpgaNms is error, Please check it!");
    }
    std::vector<int> nms_indices;

    auto nms_data_cptr = nms_pre_data.data();
    auto uregion_ = device.getMemRegion("udma");
    auto udma_chunk_ = uregion_.malloc(10e6);
    auto mapped_base = udma_chunk_->begin.addr();
    udma_chunk_.write(0, (char*)nms_data_cptr, bbox_num * 10);
    //hard nms config
    float threshold_f = iou;
    uint64_t arbase = mapped_base;
    uint64_t awbase = mapped_base;
    //检查硬件的版本信息是否正确，不正确会抛出错误
    if (device.defaultRegRegion().read(base_addr + 0x008, true) != 0x23110200) {
        std::cout << "ERROR in FpgaNms :: No NMS HardWare" <<std::endl;
        throw std::runtime_error("ERROR in FpgaNms :: No NMS HardWare");
    }
    auto group_num = (uint64_t)ceilf((float)bbox_num / 16.f);
    if (group_num == 0) 
    {
        std::cout << "ERROR in FpgaNms :: group_num == 0" <<std::endl;
        throw std::runtime_error("ERROR in FpgaNms :: group_num == 0");
    }
    auto last_araddr = arbase + group_num * 160 - 8;
    if (last_araddr < arbase) 
    {
        std::cout << "ERROR in FpgaNms :: last_araddr < arbase" <<std::endl;
        throw std::runtime_error("ERROR in FpgaNms :: last_araddr < arbase");
    }
    auto anchor_hpsize = (uint64_t)ceilf((float)bbox_num / 64.f);
    if (anchor_hpsize == 0) 
    {
        std::cout << "ERROR in FpgaNms :: anchor_hpsize == 0" <<std::endl;
        throw std::runtime_error("ERROR in FpgaNms :: anchor_hpsize == 0");
    }
    auto last_awaddr = awbase + anchor_hpsize * 8 - 8;
    if (last_awaddr < awbase) 
    {
        std::cout << "ERROR in FpgaNms :: last_awaddr < awbase" <<std::endl;
        throw std::runtime_error("ERROR in FpgaNms :: last_awaddr < awbase");
    }

    auto threshold = (uint16_t)(threshold_f * pow(2, 15));
    //config reg
    device.defaultRegRegion().write(base_addr + 0x014, 1, true);
    device.defaultRegRegion().write(base_addr + 0x014, 0, true);
    device.defaultRegRegion().write(base_addr + 0x01C, arbase, true);
    device.defaultRegRegion().write(base_addr + 0x020, awbase, true);
    device.defaultRegRegion().write(base_addr + 0x024, last_araddr, true);
    device.defaultRegRegion().write(base_addr + 0x028, last_awaddr, true);
    device.defaultRegRegion().write(base_addr + 0x02C, group_num, true);
    device.defaultRegRegion().write(base_addr + 0x030, 0, true); //mode: 0同类之间筛选、1所有类之间筛选 
    device.defaultRegRegion().write(base_addr + 0x034, threshold, true);
    device.defaultRegRegion().write(base_addr + 0x038, anchor_hpsize, true);

    device.defaultRegRegion().write(base_addr + 0x0, 1, true);  //start
    uint64_t reg_done;
    auto start = std::chrono::steady_clock::now();
    do {
        reg_done = device.defaultRegRegion().read(base_addr + 0x004, true);
        std::chrono::duration<double, std::milli> duration = std::chrono::steady_clock::now() - start;
        if (duration.count() > 1000) {
            std::cout << "ERROR in FpgaNms :: NMS Timeout!!!" <<std::endl;
            throw std::runtime_error("ERROR in FpgaNms :: NMS Timeout!!!");
        }
    } while (reg_done == 0);
    uint64_t mask_size = (uint64_t)(ceilf((float)bbox_num / 8.f));
    char* mask = new char[64000];
    udma_chunk_.read(mask, 0, mask_size);

    for (int i = 0; i < bbox_num; ++i) {
        const int idx = nms_pre_idx[i];
        int mask_index = i / 8;
        if (i % 8 == 0 && ((mask[mask_index] & (uint8_t)1) != 0))
            nms_indices.emplace_back(idx);
        else if (i % 8 == 1 && ((mask[mask_index] & (uint8_t)2) != 0))
            nms_indices.emplace_back(idx);
        else if (i % 8 == 2 && ((mask[mask_index] & (uint8_t)4) != 0))
            nms_indices.emplace_back(idx);
        else if (i % 8 == 3 && ((mask[mask_index] & (uint8_t)8) != 0))
            nms_indices.emplace_back(idx);
        else if (i % 8 == 4 && ((mask[mask_index] & (uint8_t)16) != 0))
            nms_indices.emplace_back(idx);
        else if (i % 8 == 5 && ((mask[mask_index] & (uint8_t)32) != 0))
            nms_indices.emplace_back(idx);
        else if (i % 8 == 6 && ((mask[mask_index] & (uint8_t)64) != 0))
            nms_indices.emplace_back(idx);
        else if (i % 8 == 7 && ((mask[mask_index] & (uint8_t)128) != 0))
            nms_indices.emplace_back(idx);
    }
    delete mask;
    return nms_indices;
}


// Dma&ImageMake硬件模块配置
// 参数说明:
// img_tensor – imagemake的输入tensor
// device – 输入icraft::xrt::Device，对预设的寄存器进行读写需要device
// imk_write_addr  –  ImageMake写入PLDDR的基地址，默认如果不传入该参数，将在ImageMake forward时配置该地址
// imk_base_addr  – ImageMake的寄存器基地址，默认为0x100000400，即input_port = 0对应的寄存器基地址
// dma_base_addr – fpgaDma的寄存器基地址，默认配置为当前版本下input_port = 0对应的基地址。
void fpgaDma(Tensor& img_tensor, Device& device, uint64_t imk_write_addr = std::numeric_limits<uint64_t>::max(), uint64_t imk_base_addr = 0x100000400, uint64_t dma_base_addr = 0x1000C0000) {
    auto ImageMakeChannel = img_tensor.dtype()->shape[-1];
    auto ImageMakeWidth = img_tensor.dtype()->shape[-2];
    auto ImageMakeHeight = img_tensor.dtype()->shape[-3];
    //获取umda的memRegion
    auto uregion_ = device.getMemRegion("udma");
    //将host上的输出复制到udma上，并返回对应的tensor 包含了内存管理机制
    auto utensor = img_tensor.to(uregion_);
    //获取在udma上对应的物理指针
    auto ImageMakeRddrBase = utensor.data().addr();

    //获取input_dtype
    bool flag_8 = img_tensor.dtype()->element_dtype.getStorageType().isUInt8();
    bool flag_16 = img_tensor.dtype()->element_dtype.getStorageType().isSInt16();

    uint32_t ImageMakeRlen;
    uint32_t ImageMakeLastSft;

    // dma_imk_Init
    if (!(flag_8 || flag_16)) {
        throw std::runtime_error("DMA only supports uint8 and int16");
    }
    if (flag_16) {
        auto totalBytes = ImageMakeChannel * ImageMakeWidth * ImageMakeHeight * 2;
        auto minBlocks = (totalBytes + 7) / 8;
        ImageMakeRlen = ((minBlocks + 2) / 3) * 3;
        auto pixelsPer24Bytes = 24 / (2 * ImageMakeChannel);
        auto totalPixels = ImageMakeWidth * ImageMakeHeight;
        ImageMakeLastSft = totalPixels - (ImageMakeRlen / 3 - 1) * pixelsPer24Bytes;
        device.defaultRegRegion().write(dma_base_addr + 0x20, 0x2, true);
    }
    else {
        ImageMakeRlen = ((ImageMakeWidth * ImageMakeHeight - 1) / (24 / ImageMakeChannel) + 1) * 3;
        ImageMakeLastSft = ImageMakeWidth * ImageMakeHeight - (ImageMakeRlen - 3) / 3 * (24 / ImageMakeChannel);
        device.defaultRegRegion().write(dma_base_addr + 0x20, 0, true);
    }

    if (imk_write_addr != std::numeric_limits<uint64_t>::max()) {
        // 多线程psin时，需要提前配置ImageMake写入PLDDR的基地址，避免结果错位
        device.defaultRegRegion().write(imk_base_addr + 0x114, imk_write_addr, true);
    }
    device.defaultRegRegion().write(dma_base_addr + 0x4, ImageMakeRddrBase, true);
    device.defaultRegRegion().write(dma_base_addr + 0x8, ImageMakeRlen, true);
    device.defaultRegRegion().write(dma_base_addr + 0xC, ImageMakeLastSft, true);
    device.defaultRegRegion().write(dma_base_addr + 0x10, ImageMakeChannel, true);
    device.defaultRegRegion().write(dma_base_addr + 0x1C, 1, true);
    device.defaultRegRegion().write(dma_base_addr, 1, true);
}

// warpaffine寄存器配置，M_inversed: 2x3变换矩阵的逆矩阵
void fpgaWarpaffine(std::vector<std::vector<float>>& M_inversed, Device& device,uint64_t base_addr = 0x100002800) {
    // 配置warpaffine寄存器
    auto coef_a = int64_t(M_inversed[0][0] * pow(2, 15));
    auto coef_b = int64_t(M_inversed[0][1] * pow(2, 15));
    auto coef_c = int64_t(M_inversed[0][2] * 2);
    auto coef_d = int64_t(M_inversed[1][0] * pow(2, 15));
    auto coef_e = int64_t(M_inversed[1][1] * pow(2, 15));
    auto coef_f = int64_t(M_inversed[1][2] * 2);

    device.defaultRegRegion().write(base_addr + 0x030, coef_a, true);
    device.defaultRegRegion().write(base_addr + 0x034, coef_c, true);
    device.defaultRegRegion().write(base_addr + 0x038, coef_e, true);
    device.defaultRegRegion().write(base_addr + 0x03C, coef_f, true);
    device.defaultRegRegion().write(base_addr + 0x044, coef_b, true);
    device.defaultRegRegion().write(base_addr + 0x048, coef_d, true);
}


Tensor fpgaArgmax2d(Device& dev, int wsize, int hsize, int valid_csize, int csize,uint64_t arbase,uint64_t last_araddr,uint64_t base_addr = 0x100003000){
	// 参数说明
    //arbase -  - 初始地址
	//last_araddr - 最后一层 ftmp 在plddr的地址
	
	int w = wsize;
	int h = hsize;
	int c = valid_csize;
	
	int csize_cal = (c > 32) ? ((c / 32 + 1) * 32) : static_cast<int>(std::pow(2,static_cast<uint32_t>(std::ceil(std::log2(c)))));
	int cu = (csize > 32) ? 32 : csize;
	int ct = csize / cu;
	
	int cu_araddr_num = ((w*h*cu)%64==0)?((w * h * cu) / 64 - 1):(w * h * cu) / 64;
	int cu_flag = std::log2(cu);
	int last_vld_cu = (c % cu == 0) ? (cu - 1) : (c % cu - 1);
	int cu_size = w*h*cu;
	
	const uint64_t ARGMAX2D_START = base_addr + 0x000;
	const uint64_t ARGMAX2D_DONE = base_addr + 0x004;
	const uint64_t ARGMAX2D_VER = base_addr + 0x008;
	const uint64_t ARGMAX2D_TEST = base_addr + 0x00c;
	const uint64_t ARGMAX2D_TIME_CNT = base_addr + 0x010;
	const uint64_t ARGMAX2D_SOFT_RST = base_addr + 0x014;
	const uint64_t ARGMAX2D_STATUS = base_addr + 0x018;
	const uint64_t ARGMAX2D_ARBASE = base_addr + 0x01c;
	const uint64_t ARGMAX2D_AWBASE = base_addr + 0x020;
	const uint64_t ARGMAX2D_LAST_ARADDR = base_addr + 0x024;
	const uint64_t ARGMAX2D_LAST_AWADDR = base_addr + 0x028;
	const uint64_t ARGMAX2D_CU_ARADDR_NUM = base_addr + 0x02c;
	const uint64_t ARGMAX2D_CU_FLAG = base_addr + 0x030;
	const uint64_t ARGMAX2D_LAST_VLD_CU = base_addr + 0x034;
	const uint64_t ARGMAX2D_CU_SIZE = base_addr + 0x038;
	const uint64_t ARGMAX2D_SLEEPTIME = 50;
	// 在udmabuf上申请argmax2d的缓存区,获取缓存的首尾物理地址
	const uint64_t argmax2d_psbuf_size = valid_csize * 8;
	auto argmax2d_pschunck = dev.getMemRegion("udma").malloc(argmax2d_psbuf_size, true);// auto free chunk 
	auto awbase = argmax2d_pschunck->begin.addr();
	auto last_awaddr = awbase + argmax2d_psbuf_size;
	//参数合法性检查
	uint32_t argmax_ver_rd = dev.defaultRegRegion().read(ARGMAX2D_VER, true);
	// uint32_t argmax_ver_rt = 0x24051200;
	// uint32_t argmax_ver_rt = 0x24071800;
	uint32_t argmax_ver_rt = 0x24073000;
	if (argmax_ver_rd != argmax_ver_rt) {
		std::cout << "Error in FpgaArgma2d: Argmax2d HardWare Version Mismatch! Read Version is " << argmax_ver_rd << ", Right version is" << argmax_ver_rt << std::endl;
		ICRAFT_LOG(EXCEPT) << "Error in FpgaArgma2d :: No Argmax2d HardWare Or Version mismatch";
	}
	if (csize_cal != csize) {
		std::cout << "Error in FpgaArgma2d: csize input is" << csize << "calculated csize is " << csize_cal << std::endl;
		ICRAFT_LOG(EXCEPT) << "Error in FpgaArgma2d: csize input err";
	}
	if ((w * h * cu) % 64 != 0) {
		std::cout << "Error in FpgaArgma2d: (w * h * cu) % 64 != 0, argmax2d hardop not support!" << std::endl;
		ICRAFT_LOG(EXCEPT) << "Error in FpgaArgma2d: (w * h * cu) % 64 != 0, argmax2d hardop not support";
	}
	// 调试用
	// std::cout<<"csize_cal ="<<csize_cal<<" cu ="<<cu<<" cu_araddr_num ="<<cu_araddr_num<<" last_vld_cu ="<<last_vld_cu<<" cu_size ="<<cu_size<<" cu_flag ="<<cu_flag<<std::endl;
	//配置寄存器
	dev.defaultRegRegion().write(ARGMAX2D_ARBASE, arbase, true);
	dev.defaultRegRegion().write(ARGMAX2D_LAST_ARADDR, last_araddr, true);
	dev.defaultRegRegion().write(ARGMAX2D_AWBASE, awbase, true);
	dev.defaultRegRegion().write(ARGMAX2D_LAST_AWADDR, last_awaddr, true);
	dev.defaultRegRegion().write(ARGMAX2D_CU_ARADDR_NUM, cu_araddr_num, true);
	dev.defaultRegRegion().write(ARGMAX2D_CU_FLAG, cu_flag, true);
	dev.defaultRegRegion().write(ARGMAX2D_LAST_VLD_CU, last_vld_cu, true);
	dev.defaultRegRegion().write(ARGMAX2D_CU_SIZE, cu_size, true);
	dev.defaultRegRegion().write(ARGMAX2D_START, 1, true);
    
	//轮询done信号
	unsigned int argmax2d_done = 0;
	auto start = std::chrono::steady_clock::now();
		do {
            #ifndef _WIN32
		usleep(ARGMAX2D_SLEEPTIME);
        #endif
		argmax2d_done = dev.defaultRegRegion().read(ARGMAX2D_DONE, true);
		std::chrono::duration<double, std::milli> duration = std::chrono::steady_clock::now() - start;
		if (duration.count() > 1000) {
		    std::cout << "Error in FpgaArgma2d :: Argmax2d Timeout" << std::endl;
			ICRAFT_LOG(EXCEPT) << "Error in FpgaArgma2d :: Argmax2d Timeout";
		}
	    } while (argmax2d_done == 0);
	//获取FPGA计时
	unsigned int argmax2d_time_cnt = dev.defaultRegRegion().read(ARGMAX2D_TIME_CNT, true);
	double argmax2d_hard_time = (argmax2d_time_cnt * 5) / 1000000.0; //单位ms
	// std::cout << "argmax2d_hard_time = " << argmax2d_hard_time << std::endl;
	
	// 获取各通道最大值的坐标,构造输出的tensor
	auto ofm_layout = Layout::NHWC();
	icraft::xir::TensorType output_type;
	// icraft::xir::Array<int64_t> output_dim = { 1,1,c,8 };
	icraft::xir::Array<IntImm> output_dim = { 1,1,c,8 };
	//auto data = std::shared_ptr<uint8_t[]>(new uint8_t[c*8]);
	//argmax2d_pschunck.read((char*)data.get(), 0, c * 8);
	output_type = TensorType(xir::IntegerType::UInt8(), output_dim, ofm_layout);
	auto output_tensor = Tensor(output_type, argmax2d_pschunck, 0);//udma buffer 获取结果 
	return output_tensor;   
}	

/**
 *   nms_hard,使用说明
 *   若最终输出检测数量为500个，nms_hard耗时约0.638ms
 *   若最终输出检测数量为100个，nms_hard耗时约0.297ms
 *   当最终检测数量小于30个的情况下，采用nms_soft会比nms_hard速度快。
 *   确保送入该函数的框的置信度以及在外部进行了阈值筛选
 *   注：该函数适配大部分yolo系列模型后处理的hard nms函数，其调用了setFpgaNms模块
 */
std::vector<std::tuple<int, float, cv::Rect2f>> nms_hard(std::vector<cv::Rect2f>& box_list, std::vector<float>& score_list, std::vector<int>& id_list, const float& iou, icraft::xrt::Device& device, int max_nms = 3000) {
    
    std::vector<std::pair<float, int> > score_index_vec;
    std::vector<std::tuple<int, float, cv::Rect2f>> num_res;
    std::vector<int> after_id_list;
    if (box_list.size() == 0) return num_res;
    for (size_t i = 0; i < score_list.size(); ++i) {
        score_index_vec.emplace_back(std::make_pair(score_list[i], i));
        after_id_list.push_back(id_list[i]);
    }
    std::stable_sort(score_index_vec.begin(), score_index_vec.end(),
        [](const std::pair<float, int>& pair1, const std::pair<float, int>& pair2) {return pair1.first > pair2.first; });
    // 重新排列 after_id_list
    std::vector<int> resort_idx;
    std::vector<int> nms_pre_idx;
    std::vector<int> sorted_after_id_list(after_id_list.size());
    for (size_t i = 0; i < score_index_vec.size(); ++i) {
        sorted_after_id_list[i] = after_id_list[score_index_vec[i].second];
        resort_idx.push_back(score_index_vec[i].second);
    }

    // 更新 after_id_list
    after_id_list = sorted_after_id_list;

    std::vector<int16_t> nms_pre_data;

    int box_num = score_index_vec.size();
    if (box_num > max_nms) {
        box_num = max_nms;
    }

    for (int i = 0; i < box_num; ++i) {
        const int idx = score_index_vec[i].second;
        auto x1 = box_list[idx].tl().x;
        if (x1 < 0) x1 = 0;
        auto y1 = box_list[idx].tl().y;
        if (y1 < 0) y1 = 0;
        auto x2 = box_list[idx].br().x;
        auto y2 = box_list[idx].br().y;
        nms_pre_data.push_back((int16_t)x1);
        nms_pre_data.push_back((int16_t)y1);
        nms_pre_data.push_back((int16_t)x2);
        nms_pre_data.push_back((int16_t)y2);
        nms_pre_data.push_back((int16_t)after_id_list[i]);
        nms_pre_idx.push_back(resort_idx[i]);
    }

    std::vector<int> nms_indices = fpgaNms(device, nms_pre_data, nms_pre_idx, box_num, iou);
    for (auto idx : nms_indices) {
        num_res.push_back({ id_list[idx],score_list[idx],box_list[idx] });
    }
    return num_res;
}

void dmaInit(const std::string& runBackend, const bool& has_ImageMake, Tensor& img_tensor, Device& device) {
    //#ifdef _WIN32
    //if (runBackend.compare("buyi") != 0 || !has_ImageMake) {
    //    return;
    //}
    //#endif
    //if (has_ImageMake) {
    //    fpgaDma(img_tensor, device);

    //}
    if (has_ImageMake && runBackend.compare("buyi") == 0) {
        fpgaDma(img_tensor, device);

    }
}

void dma_imk_Init(const std::string& run_backend, const bool& has_ImageMake, Operation& ImageMake_ ,Tensor& img_tensor, Device& device,Session &session) {
    #ifdef _WIN32
    if (run_backend.compare("host") == 0 || !has_ImageMake) {
        return;
    }
    #endif
    if (has_ImageMake) {
        //session->backends[0].cast<icraft::xrt::BuyiBackend>().initOp(ImageMake_);
        session->backends[0].cast<icraft::xrt::BuyiBackend>().initOp(ImageMake_);
        fpgaDma(img_tensor, device);

    }

}
float calculate_scale(double thr_f1, double thr_f2) {
    // 检查thr_f1和thr_f2是否在[0, 1)范围内
    if (thr_f1 <= 0 || thr_f1 >= 1 || thr_f2 <= 0 || thr_f2 >= 1) {
        throw std::invalid_argument("Both thr_f1 and thr_f2 must be in the range (0, 1) to avoid division by zero.");
    }
    // 计算scale的值
    float scale = log(1 / thr_f1 - 1) / log(1 / thr_f2 - 1);
    //return static_cast<int64_t>(scale);
    return scale;
}
void updateDetpost(NetInfo& netinfo, float conf) {
    //获取detpost op
    Operation det = netinfo.DetPost_;
    //如果yaml.conf与detpost的conf不一致，则更新detpost的data_thr
    if (netinfo.thr_f != conf) {
        //获取detpost原始的data_thr
        Array<int64_t> data_thr = det->getAttr("data_thr").cast<Array<int64_t>>();
        //计算缩放scale
        float thr_f1 = conf;//new conf
        float thr_f2 = netinfo.thr_f;//original conf
        float scale = calculate_scale(thr_f1, thr_f2);
        netinfo.thr_f = conf;//更新netinfo.thr_f
        //计算new thr_q(data_thr)
        try {
            for (int i = 0; i < data_thr.size(); i++) {
                netinfo.data_thr[i] *= scale;
                data_thr.set(i, static_cast<int64_t>(netinfo.data_thr[i]));// calculate new data_thr
                //std::cout << netinfo.data_thr[i] << std::endl;
            }
            det.setAttr("data_thr", data_thr);//set Attr
        }
        catch (const std::exception& e) {
            std::cerr << "Error: " << e.what() << std::endl;
        }
    }
}

//-------------------------------------//
//       PLin 
//-------------------------------------//

void hardResizePS(BuyiDevice dev, const int CAMERA_WIDTH, const int CAMERA_HEIGHT,
    const int FRAME_WIDTH, const int FRAME_HEIGHT,
    camera_fmt fmt, crop_position crop, uint64_t base_addr = 0x40080000)
{

    int ws = CAMERA_WIDTH / FRAME_WIDTH;
    int hs = CAMERA_HEIGHT / FRAME_HEIGHT;
    int IMG_W = ws * FRAME_WIDTH;
    int IMG_H = hs * FRAME_HEIGHT;
    int x0, y0, x1, y1;

    switch (crop)
    {
    case crop_position::center:
        x0 = (CAMERA_WIDTH - IMG_W) / 2;
        y0 = (CAMERA_HEIGHT - IMG_H) / 2;
        x1 = CAMERA_WIDTH - x0 - 1;
        y1 = CAMERA_HEIGHT - y0 - 1;
        break;

    case crop_position::top_left:
        x0 = 0;
        y0 = 0;
        x1 = IMG_W - 1;
        y1 = IMG_H - 1;
        break;

    case crop_position::top_right:
        x0 = CAMERA_WIDTH - IMG_W;
        y0 = 0;
        x1 = CAMERA_WIDTH - 1;
        y1 = IMG_H - 1;
        break;

    case crop_position::bottom_left:
        x0 = 0;
        y0 = CAMERA_HEIGHT - IMG_H;
        x1 = IMG_W - 1;
        y1 = CAMERA_HEIGHT - 1;
        break;

    case crop_position::bottom_right:
        x0 = CAMERA_WIDTH - IMG_W;
        y0 = CAMERA_HEIGHT - IMG_H;
        x1 = CAMERA_WIDTH - 1;
        y1 = CAMERA_HEIGHT - 1;
        break;

    }

    dev.defaultRegRegion().write(base_addr + 0x18, 1);
    dev.defaultRegRegion().write(base_addr + 0x5c, x0 << 16 | x1);
    dev.defaultRegRegion().write(base_addr + 0x60, y0 << 16 | y1);
    dev.defaultRegRegion().write(base_addr + 0x64, CAMERA_WIDTH << 16 | CAMERA_HEIGHT);
    dev.defaultRegRegion().write(base_addr + 0x68, ws << 4 | hs);

    int image_fmt_channel = 4;
    switch (fmt)
    {
    case camera_fmt::RGB565:
        dev.defaultRegRegion().write(base_addr + 0x78, 0);
        image_fmt_channel = 2;
        break;

    case camera_fmt::RGB:
        image_fmt_channel = 3;
        break;

    case camera_fmt::RGBA:
        dev.defaultRegRegion().write(base_addr + 0x78, 0);
        image_fmt_channel = 4;
        break;

    case camera_fmt::YUV422:
        image_fmt_channel = 2;
        dev.defaultRegRegion().write(base_addr + 0x7c, FRAME_WIDTH);
        dev.defaultRegRegion().write(base_addr + 0x78, 1);
        break;

    default:
        break;
    }
    // spdlog::info("Hard Resize PS, x0={}, y0={}, x1={}, y1={}, stride x={}, stride y={}, resize channel={}",
    //     x0, y0, x1, y1, ws, hs, image_fmt_channel);
    std::cout << "Hard Resize PS, x0={"<< x0 <<"}, y0={"<< y0 <<"}, x1={"<< x1 <<"}, y1={"<< y1 <<
        "}, stride x={"<< ws <<"}, stride y={"<< hs <<"}, resize channel={"<< image_fmt_channel <<"}" <<std::endl;
    dev.defaultRegRegion().write(base_addr + 0x6c, FRAME_WIDTH * FRAME_HEIGHT * image_fmt_channel / 8);
}


void hardResizePL(BuyiDevice device, int x0, int y0, int x1, int y1, int RATIO_W, int RATIO_H, int CAMERA_WIDTH, int CAMERA_HEIGHT,
    uint64_t base_addr = 0x40080000)

{

    device.defaultRegRegion().write(base_addr + 0x18, 1);
    device.defaultRegRegion().write(base_addr + 0x20, RATIO_W);			// x方向行步长
    device.defaultRegRegion().write(base_addr + 0x24, RATIO_H);			// y方向列步长
    device.defaultRegRegion().write(base_addr + 0x28, x0);			// 起始x0 坐标位置 （0~FRAME_W）
    device.defaultRegRegion().write(base_addr + 0x2C, y0);			// 起始y0 坐标位置 （0~FRAME_H）
    device.defaultRegRegion().write(base_addr + 0x30, x1);	    // 终止x1 坐标位置 （0~FRAME_W）
    device.defaultRegRegion().write(base_addr + 0x34, y1);		// 终止y1 坐标位置 （0~FRAME_H）
    device.defaultRegRegion().write(base_addr + 0x38, CAMERA_WIDTH);	    // 图像X方向总长度 （FRAME_W）
    device.defaultRegRegion().write(base_addr + 0x3C, CAMERA_HEIGHT);	    // 图像y方向总长度 （FRAME_H）
    // spdlog::info("Hard Resize PL, x0={}, y0={}, x1={}, y1={}, stride x={}, stride y={}",
    //     x0, y0, x1, y1, RATIO_W, RATIO_H);
    std::cout << "Hard Resize PL, x0={"<< x0 <<"}, y0={"<< y0 <<"}, x1={"<< x1 <<"}, y1={"<< y1 <<"},stride x={"<< RATIO_W <<"}, stride y={"<< RATIO_H <<"}" <<std::endl;
}
std::tuple<int, int, int, int > preprocess_plin(BuyiDevice device,
    const int CAMERA_WIDTH, const int CAMERA_HEIGHT,
    const int NET_W, const int NET_H,
    crop_position crop,
    uint64_t base_addr = 0x40080000)

{
    int RATIO_W = CAMERA_WIDTH / NET_W;
    int RATIO_H = CAMERA_HEIGHT / NET_H;
    int IMG_W = RATIO_W * NET_W;
    int IMG_H = RATIO_H * NET_H;
    int BIAS_W = (CAMERA_WIDTH - IMG_W) / 2;
    int BIAS_H = (CAMERA_HEIGHT - IMG_H) / 2;
    int x0, y0, x1, y1;

    switch (crop)
    {
    case crop_position::center:
        x0 = (CAMERA_WIDTH - IMG_W) / 2;
        y0 = (CAMERA_HEIGHT - IMG_H) / 2;
        x1 = CAMERA_WIDTH - x0 - 1;
        y1 = CAMERA_HEIGHT - y0 - 1;
        break;

    case crop_position::top_left:
        x0 = 0;
        y0 = 0;
        x1 = IMG_W - 1;
        y1 = IMG_H - 1;
        break;

    case crop_position::top_right:
        x0 = CAMERA_WIDTH - IMG_W;
        y0 = 0;
        x1 = CAMERA_WIDTH - 1;
        y1 = IMG_H - 1;
        break;

    case crop_position::bottom_left:
        x0 = 0;
        y0 = CAMERA_HEIGHT - IMG_H;
        x1 = IMG_W - 1;
        y1 = CAMERA_HEIGHT - 1;
        break;

    case crop_position::bottom_right:
        x0 = CAMERA_WIDTH - IMG_W;
        y0 = CAMERA_HEIGHT - IMG_H;
        x1 = CAMERA_WIDTH - 1;
        y1 = CAMERA_HEIGHT - 1;
        break;

    }
    hardResizePL(device, x0, y0, x1, y1, RATIO_W, RATIO_H, CAMERA_WIDTH, CAMERA_HEIGHT, base_addr);
    return { RATIO_W, RATIO_H, BIAS_W,BIAS_H };
}

namespace PLDDRMemRegion {

    // pl_ddr dma 
    const uint64_t PLDDR_DMA_BASE = 0x100041000;
    const uint64_t PLDDR_DMA_START = 0x04 + PLDDR_DMA_BASE;
    const uint64_t PLDDR_DMA_READ_BOTTOM = 0x18 + PLDDR_DMA_BASE;
    const uint64_t PLDDR_DMA_READ_TOP = 0x1C + PLDDR_DMA_BASE;
    const uint64_t PLDDR_DMA_WRITE_BOTTOM = 0x20 + PLDDR_DMA_BASE;
    const uint64_t PLDDR_DMA_WRITE_TOP = 0x24 + PLDDR_DMA_BASE;
    const uint64_t PLDDR_DMA_STATUS = 0x84 + PLDDR_DMA_BASE;

    const uint32_t PLDDR_DMA_ST_MASK_1 = 0b0000;    // success
    const uint32_t PLDDR_DMA_ST_MASK_2 = 0b0011;    // rdma err
    const uint32_t PLDDR_DMA_ST_MASK_3 = 0b1100;    // wdma err
    const uint32_t PLDDR_DMA_ST_MASK_4 = 0b1111;    // both wdma and rdma err
    const uint32_t PLDDR_DMA_ST_MASK_5 = 0b0001;    // rdma un-done
    const uint32_t PLDDR_DMA_ST_MASK_6 = 0b0100;    // wdma un-done
    const uint32_t PLDDR_DMA_ST_MASK_7 = 0b0101;    // both wdma and rdma un-done
    const uint32_t PLDDR_DMA_ST_MASK_8 = 0b1101;    // wdma err, rdma un-done
    const uint32_t PLDDR_DMA_ST_MASK_9 = 0b0111;    // wdma un-done, rdma err
    const uint32_t PLDDR_DMA_ST_HIT = 0b1111;



    //bool statusHit(uint32_t status, uint32_t mask);
    bool statusHit(uint32_t status, uint32_t mask) {
        return status == mask;
    }
    //std::tuple<bool, uint64_t, int64_t> waitPLDMADone(int timeout_ms, const std::chrono::steady_clock::time_point& start, icraft::xrt::Device device);
    std::tuple<bool, uint64_t, int64_t> waitPLDMADone(int timeout_ms, const std::chrono::steady_clock::time_point& start, icraft::xrt::Device device) {
        uint64_t status = device.defaultRegRegion().read(PLDDR_DMA_STATUS, true);
        int64_t duration = -1;
        bool ret = utils::WaitUntil([&status, &start, &duration, &device]() {
            status = device.defaultRegRegion().read(PLDDR_DMA_STATUS, true);
            //ICRAFT_LOG(INFO).append("internal status: {:#x}", status);
            if (statusHit(status, PLDDR_DMA_ST_MASK_1)) {
                auto finish = std::chrono::steady_clock::now();
                duration = (finish - start).count();
                return true;
            }
            return false;
            }, milliseconds(timeout_ms)
                );
        //ICRAFT_LOG(INFO).append("return status: {:#x}, duration: {}", status, duration);
        return { ret, status, duration };
    }

    void Plddr_memcpy(uint64_t read_bottom, uint64_t read_top, uint64_t write_bottom, uint64_t write_top, icraft::xrt::Device& device) {
        // 作用：将PLDDR上src的数据拷贝给PLDDR上dest

        ICRAFT_LOG(INFO).append("Begin plddr memcpy...");

        //自行在外部对齐数据
        //uint64_t read_bottom = src_begin_addr;
        //uint64_t read_top = read_bottom + byte_size - 64; //对齐64byte整数倍
        //uint64_t write_bottom = dest_addr;
        //uint64_t write_top = write_bottom + byte_size - 64;//对齐64byte整数倍

        std::mutex plddr_dma_mutex_;
        // lock
        std::unique_lock<std::mutex> plddr_dma_lock(plddr_dma_mutex_);
        // write reg: [r_b, r_t] -> [w_b, w_t]
        device.defaultRegRegion().write(PLDDR_DMA_READ_BOTTOM, read_bottom, true);//输入数据的base地址
        device.defaultRegRegion().write(PLDDR_DMA_READ_TOP, read_top, true); //输入数据的结束地址
        device.defaultRegRegion().write(PLDDR_DMA_WRITE_BOTTOM, write_bottom, true);//输出数据的base地址
        device.defaultRegRegion().write(PLDDR_DMA_WRITE_TOP, write_top, true);//输出数据的结束地址

        uint64_t aa = device.defaultRegRegion().read(PLDDR_DMA_READ_BOTTOM, true);
        uint64_t bb = device.defaultRegRegion().read(PLDDR_DMA_READ_TOP, true);
        uint64_t cc = device.defaultRegRegion().read(PLDDR_DMA_WRITE_BOTTOM, true);
        uint64_t dd = device.defaultRegRegion().read(PLDDR_DMA_WRITE_TOP, true);
        ICRAFT_LOG(INFO)
            .append("read_form: {}, read_to: {}, write_from: {}, write_to: {}",
                aa, bb, cc, dd);


        // launch plddr dma
        auto start = std::chrono::steady_clock::now();
        uint64_t ee = device.defaultRegRegion().read(PLDDR_DMA_STATUS, true);//启动后轮询，全0表示done
        ICRAFT_LOG(INFO).append("begin status: {:#x}", ee);
        // 启动数据传输
        device.defaultRegRegion().write(PLDDR_DMA_START, 1, true);
        device.defaultRegRegion().write(PLDDR_DMA_START, 0, true);
        auto [done, status, duration] = waitPLDMADone(1000, start, device);

        ICRAFT_LOG(INFO).append("(inner) PLDDR_PLDDR DMA time cost: {}ns", duration);

        if (!done) {
            if (statusHit(status, PLDDR_DMA_ST_MASK_2))
                ICRAFT_LOG(EXCEPT, 1301).append("Unexpected launch of RDMA when RDMA is running, while WDMA is running well.");
            else if (statusHit(status, PLDDR_DMA_ST_MASK_3))
                ICRAFT_LOG(EXCEPT, 1302).append("Unexpected launch of WDMA when WDMA is running, while RDMA is running well.");
            else if (statusHit(status, PLDDR_DMA_ST_MASK_4))
                ICRAFT_LOG(EXCEPT, 1303).append("Unexpected launches of both WDMA and RDMA when they are running.");
            else if (statusHit(status, PLDDR_DMA_ST_MASK_5))
                ICRAFT_LOG(EXCEPT, 1304).append("RDMA is un-done, while WDMA running well.");
            else if (statusHit(status, PLDDR_DMA_ST_MASK_6))
                ICRAFT_LOG(EXCEPT, 1305).append("WDMA is un-done, while RDMA running well.");
            else if (statusHit(status, PLDDR_DMA_ST_MASK_7))
                ICRAFT_LOG(EXCEPT, 1306).append("Both WDMA and RDMA are un-done.");
            else if (statusHit(status, PLDDR_DMA_ST_MASK_8))
                ICRAFT_LOG(EXCEPT, 1307).append("Unexpected launch of WDMA and RDMA is un-done.");
            else if (statusHit(status, PLDDR_DMA_ST_MASK_9))
                ICRAFT_LOG(EXCEPT, 1308).append("Unexpected launch of RDMA and WDMA is un-done.");
            else
                ICRAFT_LOG(EXCEPT, 1309).append("Unkown status of PLDDR DMA, which is {:#x}.", status);
        }

    }

}







#ifdef __linux__

template<typename predicate, typename Rep, typename Period>
bool WaitUntil(predicate check, std::chrono::duration<Rep, Period> timeout) {
    auto start = std::chrono::steady_clock::now();
    while (!check()) {
        usleep(50);
        if (timeout > 0ms && std::chrono::steady_clock::now() - start > timeout) { return false; }
    }
    return true;
}


class Camera {
public:
    Camera() = default;

    Camera(BuyiDevice device, uint64_t buffer_size, uint64_t base_addr = 0x40080000)
        : device_(device), buffer_size_(buffer_size), base_addr_(base_addr)
    {
        take_addr_ = base_addr_ + 0x04;
        write_addr_ = base_addr_ + 0x50;
        done_addr_ = base_addr_ + 0x58;
    }

    void get(int8_t* frame, const MemChunk& memchunk) const {
        memchunk.read((char*)frame, 0, buffer_size_);
    }

    void take(const MemChunk& memchunk) const {
        // 取帧到MemChunk处
        device_.defaultRegRegion().write(write_addr_, memchunk->begin.addr() >> 3);
        device_.defaultRegRegion().write(take_addr_, 1);
    }

    bool wait(int wait_time_ms = 100) const {
        bool error = false;
        bool done = false;
        WaitUntil(
            [&]() -> bool {
                auto camera_done = device_.defaultRegRegion().read(done_addr_);
                error = camera_done & 0x4;
                done = camera_done & 0x1;
                return done;
            },
            // std::chrono::duration<int, std::milli>(wait_time_ms)
                100ms
                );
        return !error && done;
    }

private:
    BuyiDevice device_;
    uint64_t buffer_size_ = 0;
    uint64_t base_addr_;
    uint64_t take_addr_;
    uint64_t write_addr_;
    uint64_t done_addr_;
};

/**
 *   Hdmi显示抽象类
 *   用于wukong板
 *   输入的数据为 RGB565
 *   尺寸是1920*1080
 */
class Display_pHDMI_RGB565 {
public:
    Display_pHDMI_RGB565() = default;

    Display_pHDMI_RGB565(BuyiDevice device, uint64_t buffer_size, MemChunk chunck)
        :device_(device), buffer_size_(buffer_size), chunck_(chunck) {
    }

    void show(int8_t* frame) const {
        chunck_.write(0, (char*)frame, buffer_size_);
        device_.defaultRegRegion().write(DISPLAY_READ_ADDR, chunck_->begin.addr() >> 3);
    }

private:
    BuyiDevice device_;
    uint64_t buffer_size_ = 0;
    MemChunk chunck_;
    const static auto DISPLAY_READ_ADDR = 0x40080054;
};

/**
 *   Hdmi显示抽象类
 *   用于demov1板子， 做成framebuffer驱动，
 *   输入的数据为 RGBA
 *   尺寸是1920*1080
 */
class Display_sHDMI_RGBA {
public:
    Display_sHDMI_RGBA() = default;

    Display_sHDMI_RGBA(const char* dev)
    {
        int ret = 0;
        fd_ = open(dev, O_RDWR);
        if (fd_ < 0) {
            printf("open device [%s] failed:%s\n", dev, strerror(errno));
        }

        ret = ioctl(fd_, FBIOGET_FSCREENINFO, &fix);
        if (ret < 0) {
            printf("read fb device fscreeninfo failed:%s\n", strerror(errno));
            close(fd_);
        }

        ret = ioctl(fd_, FBIOGET_VSCREENINFO, &var);
        if (ret < 0) {
            printf("read fb device vscreeninfo failed:%s\n", strerror(errno));
            close(fd_);
        }

        mem_size_ = var.xres * var.yres * var.bits_per_pixel / 8;	/* 计算内存 */
        ptr_buf = (uint8_t*)mmap(NULL, mem_size_, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, 0);
        if (ptr_buf == NULL) {
            printf("fb device mmap failed:%s\n", strerror(errno));
            close(fd_);
        }

        memset(ptr_buf, 0, mem_size_);  // 清除屏幕
    }

    ~Display_sHDMI_RGBA() {

        munmap(ptr_buf, mem_size_);
        close(fd_);
    }

    void show(int8_t* frame) const {
        memcpy(ptr_buf, frame, mem_size_);
    }


    void draw_top_left(int8_t* frame) {
        uint8_t* poffset_buf = ptr_buf;
        for (int col = 0; col < var.yres; ++col) {
            memcpy(poffset_buf, frame, var.xres / 2);
            poffset_buf += var.xres;
            frame += var.xres / 2;
        }
    }

    void draw_top_right(int8_t* frame) {
        uint8_t* poffset_buf = ptr_buf + var.xres / 2;
        for (int col = 0; col < var.yres; ++col) {
            memcpy(poffset_buf, frame, var.xres / 2);
            poffset_buf += var.xres;
            frame += var.xres / 2;
        }
    }

    void draw_bottom_left(int8_t* frame) {
        uint8_t* poffset_buf = ptr_buf + var.yres * var.xres / 2;
        for (int col = 0; col < var.yres; ++col) {
            memcpy(poffset_buf, frame, var.xres / 2);
            poffset_buf += var.xres;
            frame += var.xres / 2;
        }
    }

    void draw_bottom_right(int8_t* frame) {
        uint8_t* poffset_buf = ptr_buf + var.yres * var.xres / 2 + var.xres / 2;
        for (int col = 0; col < var.yres; ++col) {
            memcpy(poffset_buf, frame, var.xres / 2);
            poffset_buf += var.xres;
            frame += var.xres / 2;
        }
    }

    void draw_pixel(int x, int y, uint32_t color)
    {
        uint8_t* poffset_buf = NULL;

        poffset_buf = ptr_buf + (x * var.bits_per_pixel / 8)
            + (y * var.xres * var.bits_per_pixel / 8);	/* 计算内存偏移地址 */
        *(uint32_t*)poffset_buf = color;	/* ARGB32格式 */

    }

    void fill_pixel(uint32_t color)
    {
        int i, j;

        for (i = 0; i < var.xres; i++)
        {
            for (j = 0; j < var.yres; j++)
            {
                draw_pixel(i, j, color);
            }
        }
    }

    uint8_t* getPtr() const { return ptr_buf; }

private:
    uint8_t* ptr_buf;
    int fd_;
    int mem_size_;
    struct fb_fix_screeninfo fix;
    struct fb_var_screeninfo var;/* framebuffer设备信息*/

};


class DisplayRange {
public:
    DisplayRange(int startrow, int endrow, int startcol, int endcol, const cv::Mat& mat)
        :startrow_(startrow), endrow_(endrow), startcol_(startcol), endcol_(endcol) {
        mat_ = mat.rowRange(startrow, endrow).colRange(startcol, endcol);
    }

    const cv::Mat& mat() const { return mat_; }

    const int startrow() const { return startrow_; }
    const int endrow() const { return endrow_; }
    const int startcol() const { return startcol_; }
    const int endcol() const { return endcol_; }

private:
    int startrow_;
    int endrow_;
    int startcol_;
    int endcol_;
    cv::Mat mat_;
};



class ProgressPrinter {
public:
    ProgressPrinter(int line = 0) : line_(line) {
        this->lines_ = std::vector<std::string>(line);
    }

    void print(int line_index, int progress, int total_n, std::string pre_info, std::string last_info) {
        if (line_index > this->lines_.size()) return;
        auto full_info = pre_info + " " + std::to_string(progress) + "/" + std::to_string(total_n) + "[";

        for (int i = 0; i < 50; ++i) {
            int prog = float(progress) / float(total_n) * 100.0 / 2.0;
            if (i < prog)
                full_info += "=";
            if (i == prog)
                full_info += ">";
            if (i > prog)
                full_info += " ";
        }
        full_info += +"]";
        full_info += fmt::format(" {:.2f}% ", float(progress) / float(total_n) * 100.0);
        full_info += last_info;

        this->lines_[line_index] = full_info;
        std::string to_topline = "\033[" + std::to_string(line_) + "A";
        std::unique_lock<std::mutex> prt_lock(prt_mutex_);
        std::cout << "\033[?25l" << "\033[K" << to_topline << "\033[0m" << "\r";
        for (auto&& line : this->lines_) {
            std::cout << "\033[K" << line << '\n';
        }
        prt_lock.unlock();
    }

private:
    int line_;
    std::vector<std::string> lines_;
    std::mutex prt_mutex_;
    bool first_print_ = true;
};
#endif
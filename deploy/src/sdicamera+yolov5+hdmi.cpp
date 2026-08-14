/* README:

    This is an example of using single plin sdicameras as input source, a single Yolov5 NPU for inference,
    and 1 HDMI display.

    Pipeline拓扑结构:
                                     +---+     +---------+    +-----------------+  Q
                                     |   |     |         |    |                 |
                                     | q |     |         |    |                 |
                                     | u |     |   NPU   |  Q |    MsgRouter    |                  +---------------------+
    [SDI Camera 0] -- Msg(id=0) -->  | e | --> |         | -->|  (with routing  | -- Msg(id=0) --> | RGB565 HDMI DISPLAY |
                                     | u |     |  Actor  |    |      table)     |                  +---------------------+
                                     | e |     |         |    |                 |
                                     |   |     |         |    |                 |
                                     +---+     +---------+    +-----------------+

    说明:
    1. 单路 PLin-SDICamera 通过 SDICameraInputActor 采集图像后，发送消息到同一个 message queue.
    2. NPU Actor 读取唯一的 message queue ，不区分source_id处理AI前向。
    3. NPU Actor 处理后的消息通过 MessageRouter，根据 source_id 路由到对应的 HDMI Display Actor。
    4. 每个摄像头和每个显示接收器都有唯一的 source_id (0)，确保消息正确路由。
    5. 这种设计允许系统灵活扩展，添加更多摄像头或处理节点，只需更新路由表。


    准备：
    1. 下载对应位流：https://download.fdwxhb.com/data/04_FMSH-AI/100AI/02_Icraft/v3.31/%e5%8f%82%e8%80%83%e5%ae%9e%e7%8e%b0/%e6%82%9f%e7%a9%ba%e5%bc%80%e5%8f%91%e6%9d%bf/%e5%8d%95%e8%b7%afPLIN+pHDMI%e6%98%be%e7%a4%ba%e5%8f%82%e8%80%83%e5%ae%9e%e7%8e%b0/25060601/
    2. 将 BOOT.bin 放到 /root/bits 下，重启板子
    3. 确保两个网络摄像头开启，配置正确的编码格式和 URL 地址，在 examples/1_single_input+ai/PLin+SingleNet+HDMI/configs 目录下的文件中配置。
*/

// application includes
#include "ai_example/postprocesses.hpp"
#include "ai_example/yolov5_npu_actor.hpp"

// pipeline includes
#include "pipeline/actor/message_router.hpp"
#include "pipeline/actor/sdicamera_input_actor.hpp"
#include "pipeline/actor/hdmi_display_actor.hpp"
#include "pipeline/io/input/sdicamera.hpp"
#include "pipeline/memory/buffer_manager.hpp"
// modelzoo_utils includes
#include "file_utils.hpp"
#include "et_device.hpp"
#include "fps_calculator.hpp"
#include "vis_helper.hpp"
#include "icraft_utils.hpp"
// icraft includes
#include <icraft-xrt/core/session.h>
#include "compile_fpai_target.hpp"
// 3rd-party dependency includes
#include <opencv2/opencv.hpp>
#include "yaml-cpp/yaml.h"
// system libs
#include <fstream>
#include <iostream>
#include <string>
#include <vector>
#include <memory>
#include <condition_variable>
#include <atomic>
#include <thread>
#include <functional>
#include <filesystem>

using namespace icraft::xrt;
using namespace icraft::xir;
using namespace std::chrono;
using namespace std::chrono_literals;
namespace fs = std::filesystem;

using namespace fpai;

const std::string DEMO_NAME = "sdicamera+yolov5+hdmi";

const size_t BUFFER_COUNT = 4;
const size_t CAMERA_COUNT = 1;

int main(int argc, char *argv[])
{
    if (argc < 2)
    {
        std::cerr << "Usage: " << argv[0] << " <config yaml>" << std::endl;
        return 1;
    }
    // ----------------- Load system configuration from YAML file -----------------
    YAML::Node config;
    try
    {
        config = YAML::LoadFile(argv[1]);
    }
    catch (const YAML::BadFile &e)
    {
        spdlog::error("Failed to load config file {}: {}", argv[1], e.what());
        return -1;
    }

    // ----------------- 设置 spdlog 日志级别（默认级别为 info） -----------------
    auto log_level = spdlog::level::debug;
    spdlog::set_level(log_level);
    spdlog::info("Log level set to '{}'", spdlog::level::to_string_view(log_level));
    // --- 日志级别设置完毕 ---

    // ---------------------------- 加载各个Pipeline的配置 -----------------------------------
    const auto &sys_yaml = config["sys"];
    const auto &icore_yaml = config["pipeline"]["icore"];
    const auto &display_yaml = config["pipeline"]["display"];
    const auto &camera_yaml = config["pipeline"]["camera"];
    // Parse system configuration
    FPAIConfig fpai_cfg;
    fpai_cfg.device_url = sys_yaml["device"].as<std::string>();
    fpai_cfg.speed_mode = sys_yaml["speedMode"] ? sys_yaml["speedMode"].as<bool>() : false;
    fpai_cfg.compress_ftmp = sys_yaml["compressFtmp"] ? sys_yaml["compressFtmp"].as<bool>() : false;
    fpai_cfg.mmu_mode = sys_yaml["mmuMode"] ? sys_yaml["mmuMode"].as<bool>() : true;
    fpai_cfg.ocm_option = sys_yaml["ocm_option"] ? sys_yaml["ocm_option"].as<int>() : 4;
    fpai_cfg.run_backend = sys_yaml["run_backend"] ? sys_yaml["run_backend"].as<std::string>() : "buyi";
    fpai_cfg.enable_profile = sys_yaml["profile"] ? sys_yaml["profile"].as<bool>() : false;

    // Parse PLin configuration
    const int CAMERA_W = camera_yaml["width"].as<int>();
    const int CAMERA_H = camera_yaml["height"].as<int>();
    const int CAMERA_FPS = camera_yaml["fps"].as<int>();
    const bool VTC_ON = camera_yaml["vtc"] ? camera_yaml["vtc"].as<bool>() : false;

    // Parse encoder configuration
    const int FRAME_W = display_yaml["width"].as<int>();
    const int FRAME_H = display_yaml["height"].as<int>(); // PLin SDICamera推荐使用UYVY

    // Parse icore configuration
    Yolov5Config yolov5_cfg;
    if (icore_yaml["conf"])
        yolov5_cfg.CONF = icore_yaml["conf"].as<float>();
    if (icore_yaml["iou_thresh"])
        yolov5_cfg.IOU_THRESHOLD = icore_yaml["iou_thresh"].as<float>();
    if (icore_yaml["names"])
        yolov5_cfg.NAMES_PATH = icore_yaml["names"].as<std::string>();
    if (fs::exists(yolov5_cfg.NAMES_PATH))
    {
        yolov5_cfg.LABELS = toVector(yolov5_cfg.NAMES_PATH);
        yolov5_cfg.N_CLASS = yolov5_cfg.LABELS.size();
        spdlog::info("Loaded {} class names from {}", yolov5_cfg.N_CLASS, yolov5_cfg.NAMES_PATH);
    }
    else
    {
        spdlog::warn("Names file {} does not exist. No class names loaded.", yolov5_cfg.NAMES_PATH);
    }
    if (icore_yaml["number_of_class"])
        yolov5_cfg.N_CLASS = icore_yaml["number_of_class"].as<int>();
    if (icore_yaml["fpga_nms"])
        yolov5_cfg.FPGA_NMS = icore_yaml["fpga_nms"].as<bool>();
    if (icore_yaml["detpost"])
        yolov5_cfg.DETPOST = icore_yaml["detpost"].as<bool>();
    if (icore_yaml["net_w"])
        yolov5_cfg.NET_W = icore_yaml["net_w"].as<int>();
    if (icore_yaml["net_h"])
        yolov5_cfg.NET_H = icore_yaml["net_h"].as<int>();
    yolov5_cfg.FRAME_W = FRAME_W;
    yolov5_cfg.FRAME_H = FRAME_H;
    if (icore_yaml["jsons"])
        read_node_urls(icore_yaml, "jsons", yolov5_cfg.JSON_PATHS);
    if (icore_yaml["raws"])
        read_node_urls(icore_yaml, "raws", yolov5_cfg.RAW_PATHS);
    if (icore_yaml["anchors"])
        yolov5_cfg.ANCHORS = icore_yaml["anchors"].as<std::vector<std::vector<std::vector<float>>>>();

    std::tuple<int, int, int, int> ratio_bias;
    int RATIO_W = CAMERA_W / yolov5_cfg.NET_W;
    int RATIO_H = CAMERA_H / yolov5_cfg.NET_H;
    int IMG_W = RATIO_W * yolov5_cfg.NET_W;
    int IMG_H = RATIO_H * yolov5_cfg.NET_H;
    int BIAS_W = (FRAME_W - IMG_W) / 2;
    int BIAS_H = (FRAME_H - IMG_H) / 2;
    ratio_bias = std::make_tuple(RATIO_W, BIAS_W, RATIO_H, BIAS_H);

    // ---------------------------- 正式开始配置pipeline和加载网络 -----------------------------------
    // 1. FPAI设备初始化
    auto device = Device::Open(fpai_cfg.device_url.c_str());
    auto fpai_device = device.cast<FPAIDevice>();

#if defined(USE_BUYI_BACKEND)
    fpai_device.mmuModeSwitch(fpai_cfg.mmu_mode); // 关闭MMU
#endif
    // 多个摄像头输入，多个寄存器组
    std::vector<uint64_t> sdicamera_base_addr_group = {
        0x40080000,
        0x40080400,
        0x40080800,
        0x40080C00};
    std::vector<uint64_t> image_make_base_addr_group = {
        0x80000400,
        0x80040000,
        0x80040400,
        0x80040800};

    // 2. 构建 ICORE Actor 的输入、输出队列

    ThreadSafeQueue<InputMessageForIcore> icore_input_queue(BUFFER_COUNT); // WebcamDecoders -> Icore
    ThreadSafeQueue<IcoreMessageForPost> icore_output_queue(BUFFER_COUNT); // Icore -> HDMI Display

    // 3. 使用 std::vector 存储 Actors 和相关对象
    // XXXActor 这类包含线程、锁或引用的对象是不可移动、不可拷贝的。
    // 不能将它们的对象本身直接存储在 std::vector 中, 必须将它们也改为存储 std::unique_ptr
    std::unique_ptr<SDICameraInputActor<FPAIDevice, FPAIBackend>> camera_actor;

    BufferManager buffer_manager(BUFFER_COUNT);

    // 6. 配置NPU Actor
    int icore_id = 0;
    MultiYolov5IcoreActor<FPAIDevice, FPAIBackend> icore_actor(icore_id,
                                                               fpai_device,
                                                               buffer_manager,
                                                               CAMERA_COUNT,
                                                               yolov5_cfg,
                                                               fpai_cfg);
    icore_actor.bindInputQueue(&icore_input_queue);
    icore_actor.bindOutputQueue(&icore_output_queue);
    // ----------------- 为每个流创建独立的后处理状态 -----------------
    // Define the YOLOv5 post-processing function as a lambda.
    std::vector<YoloPostResult> last_results_group(CAMERA_COUNT); // Store last results for each camera
    auto netinfos = icore_actor.getNetInfos();
    std::vector<FPSCalculator> fps_calculators(CAMERA_COUNT); // 为每个流创建一个FPS计算器

    // 7. 配置单路流水线的输入和输出
    int i = 0;
    // 配置摄像头输入，为每个编码器创建独立的配置副本
    // 配置摄像头
    int camera_id = i;
    auto camera = std::make_unique<GenericSDICamera>(camera_id, fpai_device, CAMERA_W, CAMERA_H, camera_fmt::RGB565,
                                                     FRAME_W, FRAME_H, camera_fmt::RGB565, crop_position::center, // RGB565格式用于hdmi显示
                                                     yolov5_cfg.NET_W, yolov5_cfg.NET_H, crop_position::center,   // PL端输入必须经过hardResizePL
                                                     sdicamera_base_addr_group[i], VTC_ON);
#if defined(USE_BUYI_BACKEND)
    camera_actor = std::make_unique<SDICameraInputActor<FPAIDevice, FPAIBackend>>(
        camera->getSourceId(),
        std::move(camera),
        fpai_device,
        buffer_manager,
        icore_actor.getImkSessionGroups()[i],
        image_make_base_addr_group[i]);
#elif defined(USE_ZG330_BACKEND)
    camera_actor = std::make_unique<SDICameraInputActor<FPAIDevice, FPAIBackend>>(
        camera->getSourceId(),
        std::move(camera),
        fpai_device,
        buffer_manager,
        icore_actor.getIcoreSessionGroups()[i], // pass ref of whole icore sessions
        image_make_base_addr_group[i]);
#endif
    camera_actor->bindOutputQueue(&icore_input_queue);

    // 创建用于yolov5的后处理函数“适配器”lambda， 签名完美匹配 PostProcessingFunc
    HDMIDisplayActor<FPAIDevice, IcoreMessageForPost>::PostProcessingFunc yolov5_post_processor =
        // 捕获所有“实现”需要的额外变量
        // 注意：这里的参数列表必须与 PostProcessingFunc 定义完全匹配
        // 使用[&]可以简化捕获列表
        [&](const IcoreMessageForPost &post_msg, cv::Mat &cvmat_to_draw)
    {
        if (post_msg.icore_tensors.empty())
        {
            LOG_WARN("[PostProcessor]", "Icore tensors are empty, cannot perform post-processing.");
            return;
        }
        // 从消息中获取source_id，这是查找正确上下文的关键
        int source_id = post_msg.meta.source_id;

        // 检查source_id的有效性，防止越界
        if (source_id < 0 || source_id >= 4)
        {
            LOG_ERROR("[PostProcessor]", "Invalid source_id {} received.", source_id);
            return;
        }
        // 调用真正的实现，并传入所有捕获的参数
        auto &netinfo = netinfos[source_id];
        auto &last_results = last_results_group[source_id];
        auto &fps_calc = fps_calculators[source_id];

        fps_calc.tick();

        if (VTC_ON)
        {
            auto bgr_color = cv::Scalar(0, 0, 0);
            drawTextOnTwoCorners(cvmat_to_draw, fmt::format("FPS: {:.1f}", fps_calc.getFPS()), DEMO_NAME, bgr_color);
            return;
        }

        LOG_DEBUG("[AI POST]", "[{}] Before post_detpost_plin, last_results size: {}", source_id, std::get<0>(last_results).size());
        YoloPostResult post_results;
        if (netinfo.DetPost_on)
        {
            post_results = post_detpost_plin(
                post_msg.icore_tensors, last_results, netinfo,
                yolov5_cfg.CONF, yolov5_cfg.IOU_THRESHOLD, yolov5_cfg.MULTILABEL, yolov5_cfg.FPGA_NMS, yolov5_cfg.N_CLASS, yolov5_cfg.ANCHORS,
                device);
        }
        else
        {
            post_results = post_detpost_soft(
                post_msg.icore_tensors, last_results, yolov5_cfg.LABELS, yolov5_cfg.ANCHORS, netinfo,
                yolov5_cfg.N_CLASS, yolov5_cfg.CONF, yolov5_cfg.IOU_THRESHOLD);
        }
        // Update last_results after the call
        last_results = post_results;

        std::vector<int> id_list = std::get<0>(post_results);
        std::vector<float> score_list = std::get<1>(post_results);
        std::vector<cv::Rect2f> box_list = std::get<2>(post_results);
        LOG_DEBUG("[AI POST]", "[{}] After post_detpost_plin, last_results size: {}", source_id, std::get<0>(last_results).size());

        std::tuple<bool, float, float, int, int> ratio_bias = camera_actor->getRatioBias();
        bool is_hw_resize = std::get<0>(ratio_bias);
        float RATIO_W = std::get<1>(ratio_bias);
        float RATIO_H = std::get<2>(ratio_bias);
        int BIAS_W = std::get<3>(ratio_bias);
        int BIAS_H = std::get<4>(ratio_bias);
        for (int index = 0; index < box_list.size(); ++index)
        {
            float x1, y1, w, h;
            if (is_hw_resize) // 先crop再resize
            {
                // std::cout << "hardware resize=" << is_hw_resize << ", RATIO_W=" << RATIO_W << ", RATIO_H=" << RATIO_H << ", BIAS_W=" << BIAS_W << ", BIAS_H=" << BIAS_H << std::endl;
                // std::cout << "Original box(xywh): [" << box_list[index].tl().x << "," << box_list[index].tl().y << "," << box_list[index].width << "," << box_list[index].height << "]" << std::endl;
                x1 = box_list[index].tl().x * RATIO_W + BIAS_W;
                y1 = box_list[index].tl().y * RATIO_H + BIAS_H;
                w = box_list[index].width * RATIO_W;
                h = box_list[index].height * RATIO_H;
            }
            else // 先resize再pad
            {
                x1 = (box_list[index].tl().x - BIAS_W) / RATIO_W;
                y1 = (box_list[index].tl().y - BIAS_H) / RATIO_H;
                w = box_list[index].width / RATIO_W;
                h = box_list[index].height / RATIO_H;
            }
            int id = id_list[index];
            cv::Scalar color = classColor(id);
            double font_scale = 1;
            int thickness = 1;
            cv::rectangle(cvmat_to_draw, cv::Rect2f(x1, y1, w, h), color, 2, cv::LINE_8, 0);
            // std::cout << "Draw box(xywh): [" << x1 << "," << y1 << "," << w << "," << h << "] for class " << yolov5_cfg.LABELS[id] << std::endl;
            std::string s = yolov5_cfg.LABELS[id_list[index]] + ":" + std::to_string(int(round(score_list[index] * 100))) + "%";
            cv::Size s_size = cv::getTextSize(s, cv::FONT_HERSHEY_COMPLEX, font_scale, thickness, 0);
            cv::putText(cvmat_to_draw, s, cv::Point(x1, y1 - 5), cv::FONT_HERSHEY_DUPLEX, font_scale, cv::Scalar(255, 255, 255), thickness);
        }

        // DEBUG code, should be removed later
        // cv::imwrite("output_source_" + std::to_string(source_id) + "_" + get_timestamp_string() + ".jpg", cvmat_to_draw);
    };

    // 配置HDMI输出
    int hdmi_id = 0;
    auto hdmi_display = std::make_unique<RGB565HDMIDisplay<FPAIDevice>>(hdmi_id, fpai_device, FRAME_W, FRAME_H);

    HDMIDisplayActor<FPAIDevice, IcoreMessageForPost> display_actor(hdmi_display->getSinkId(),
                                                                    std::move(hdmi_display),
                                                                    fpai_device,
                                                                    buffer_manager,
                                                                    camera_actor->getChunkGroupId(),
                                                                    yolov5_post_processor);
    display_actor.bindInputQueue(&icore_output_queue);

    // 9. 启动所有Actors

    camera_actor->start();
    display_actor.start();
    icore_actor.start();

    spdlog::info("All actors started...");

    // Blocking loop that waits for the stop signal
    std::cin.get(); // Press Enter to stop

    camera_actor->stop();
    icore_actor.stop();
    display_actor.stop();

    spdlog::info("All actors stopped...");
    Device::Close(device);

    return 0;
}
/* SDI Camera → HDMI Display (无 NPU，纯显示) */

#include "pipeline/actor/sdicamera_input_actor.hpp"
#include "pipeline/actor/hdmi_display_actor.hpp"
#include "pipeline/io/input/sdicamera.hpp"
#include "pipeline/memory/buffer_manager.hpp"
#include "pipeline/base/messages.hpp"
#include "pipeline/base/thread_safe_queue.hpp"

#include "file_utils.hpp"
#include "et_device.hpp"
#include "fps_calculator.hpp"
#include "vis_helper.hpp"
#include "icraft_utils.hpp"

#include <icraft-xrt/core/session.h>
#include "compile_fpai_target.hpp"

#include <opencv2/opencv.hpp>
#include "yaml-cpp/yaml.h"

#include <iostream>
#include <string>
#include <vector>
#include <memory>
#include <thread>
#include <chrono>
#include <filesystem>

using namespace icraft::xrt;
using namespace icraft::xir;
using namespace fpai;
namespace fs = std::filesystem;

int main(int argc, char *argv[])
{
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0] << " <config yaml>" << std::endl;
        return 1;
    }

    YAML::Node config;
    try {
        config = YAML::LoadFile(argv[1]);
    } catch (const YAML::BadFile &e) {
        std::cerr << "Failed to load config: " << e.what() << std::endl;
        return -1;
    }

    auto log_level = spdlog::level::info;
    spdlog::set_level(log_level);

    const auto &sys_yaml = config["sys"];
    const auto &display_yaml = config["pipeline"]["display"];
    const auto &camera_yaml = config["pipeline"]["camera"];

    FPAIConfig fpai_cfg;
    fpai_cfg.device_url = sys_yaml["device"].as<std::string>();
    fpai_cfg.speed_mode = sys_yaml["speedMode"] ? sys_yaml["speedMode"].as<bool>() : false;
    fpai_cfg.compress_ftmp = sys_yaml["compressFtmp"] ? sys_yaml["compressFtmp"].as<bool>() : false;
    fpai_cfg.mmu_mode = sys_yaml["mmuMode"] ? sys_yaml["mmuMode"].as<bool>() : true;
    fpai_cfg.ocm_option = sys_yaml["ocm_option"] ? sys_yaml["ocm_option"].as<int>() : 4;
    fpai_cfg.run_backend = sys_yaml["run_backend"] ? sys_yaml["run_backend"].as<std::string>() : "buyi";
    fpai_cfg.enable_profile = sys_yaml["profile"] ? sys_yaml["profile"].as<bool>() : false;

    const int CAMERA_W = camera_yaml["width"].as<int>();       // 1920
    const int CAMERA_H = camera_yaml["height"].as<int>();      // 1080
    const bool VTC_ON = camera_yaml["vtc"] ? camera_yaml["vtc"].as<bool>() : false;

    const int FRAME_W = display_yaml["width"].as<int>();       // 1920
    const int FRAME_H = display_yaml["height"].as<int>();      // 1080

    // 设备和 BufferManager
    auto device = Device::Open(fpai_cfg.device_url.c_str());
    auto fpai_device = device.cast<FPAIDevice>();

    const size_t BUFFER_COUNT = 4;
    BufferManager buffer_manager(BUFFER_COUNT);

    // 队列：相机 → 显示
    ThreadSafeQueue<InputMessageForIcore> display_queue(BUFFER_COUNT);

    // SDI 相机（1:1 PS 直通, PL=640x352 给 IMK）
    std::vector<uint64_t> camera_base = {0x40080000};
    auto camera = std::make_unique<GenericSDICamera>(
        0, fpai_device,
        CAMERA_W, CAMERA_H, camera_fmt::RGB565,
        FRAME_W, FRAME_H, camera_fmt::RGB565, crop_position::center,
        640, 352, crop_position::center,
        camera_base[0], VTC_ON);

    // 相机 Actor（无 IMK session）
    std::vector<uint64_t> imk_base = {0x80000400};
    std::vector<Session> empty_sessions;
    SDICameraInputActor<FPAIDevice, FPAIBackend> camera_actor(
        camera->getSourceId(), std::move(camera), fpai_device,
        buffer_manager, empty_sessions, imk_base[0]);
    camera_actor.bindOutputQueue(&display_queue);

    // HDMI 显示（no post-processor = 直接显示原始画面）
    auto hdmi_display = std::make_unique<RGB565HDMIDisplay<FPAIDevice>>(
        0, fpai_device, FRAME_W, FRAME_H);

    HDMIDisplayActor<FPAIDevice, InputMessageForIcore> display_actor(
        hdmi_display->getSinkId(),
        std::move(hdmi_display),
        fpai_device,
        buffer_manager,
        camera_actor.getChunkGroupId(),
        nullptr);  // 无后处理，直接显示

    display_actor.bindInputQueue(&display_queue);

    // 启动
    camera_actor.start();
    display_actor.start();
    spdlog::info("Camera → HDMI pipeline started. Press Enter to stop...");

    std::cin.get();

    camera_actor.stop();
    display_actor.stop();
    spdlog::info("Stopped.");
    Device::Close(device);
    return 0;
}
